use v6;
use Hash::int;
use IO::URing::Raw;
use IO::URing::Socket::Raw :ALL;
use IO::URing::LogTimelineSchema;
use Universal::errno::Constants;

use Log::Timeline;

use NativeCall;

=begin pod

=head1 NAME

IO::URing - Access the io_uring interface from Raku

=head1 SYNOPSIS

Sample NOP call

=begin code :lang<raku>

use IO::URing;

my IO::URing $ring .= new(:8entries, :0flags);
my $data = await $ring.nop(1);
# or
react whenever $ring.nop(1) -> $data {
    say "data: {$data.raku}";
  }
}
$ring.close; # free the ring

=end code

=head1 DESCRIPTION

IO::URing is a binding to the new io_uring interface in the Linux kernel.

It will only work on Linux 5.6 and above. Use 5.10 or higher for best results.
See the io_uring documentation for which operations are supported on your kernel version.

See the included IO::URing::Socket libraries for an example of IO::URing in action.

Some knowledge of io_uring and liburing is a pre-requisite for using this library.
This code uses liburing to set up and submit requests to the ring.

=head1 IO::URing internal classes

=end pod


# Atomic ints and cas are used for synchronization.
# Here be Dragons
class IO::URing:ver<0.2.0>:auth<cpan:GARLANDG> {
  my enum STORAGE <EMPTY>;

  #| A Completion is returned from an awaited Handle.
  #| The completion contains the result of the operation.
  my class Completion {
    #| The user data passed into the submission.
    has $.data;
    #| The request passed into the IO::URing.
    has io_uring_sqe $.request;
    #| The result of the operation.
    has int $.result;
    has int $.flags;
  }

  #| A Handle is a Promise that can be used to cancel an IO::URing operation.
  #| Every call to submit or any non-prep operation will return a Handle.
  my class Handle is Promise {
    trusts IO::URing;
    has Int $!slot;
    method !slot(--> Int) is rw {
      $!slot
    }
  }

  my sub lock-int(atomicint $int is rw) is inlinable {
    loop {
      last if cas($int, 0, 1) == 0;
      sleep(0.000125);
    }
  }

  my sub unlock-int(atomicint $int is rw) is inlinable {
    atomic-assign($int, 0);
  }

=begin pod

=head1 IO::URing

=head2 IO::URing methods

=end pod

  my \tweak-flags = IORING_SETUP_CLAMP;

  has $!close-promise;
  has $!close-vow;
  has $!ring;
  has int $.entries;
  has io_uring_params $!params .= new;
  # The number of threads currently preparing an sqe.
  has atomicint $!prepare-threads = 0;
  # SQE ringbuffer lock
  has atomicint $!sqe-lock = 0;
  # Hash storage lock
  has atomicint $!storage-lock = 0;
  # Submitting thread lock
  has atomicint $!submitting = 0;
  has %!storage is Hash::int;
  has %!supported-ops;
  has int $.cqe-entries;
  has int $.sqe-entries;

  submethod TWEAK(UInt :$!entries!, UInt :$flags = tweak-flags, Int :$cq-size) {
    $!close-promise = Promise.new;
    $!close-vow = $!close-promise.vow;
    $!params.flags = $flags;
    $!entries = 8 if $!entries < 8;
    if $cq-size.defined && $cq-size >= $!entries {
      given log2($cq-size) {
        $cq-size = 2 ** ($_ + 1) unless $_ ~~ Int;
      }
      $!params.flags +|= IORING_SETUP_CQSIZE;
      $!params.cq_entries = $cq-size;
    }
    $!ring = io_uring.new(:$!entries, :$!params);
    $!cqe-entries = $!params.cq_entries;
    $!sqe-entries = $!params.sq_entries;
    start {
      my Pointer[io_uring_cqe] $cqe_ptr .= new;
      my $vow;
      my int $result;
      my int $flags;
      my $data;
      my $request;
      loop {
        my $ret = io_uring_wait_cqe($!ring, $cqe_ptr);
        $!close-vow.break($ret.Exception) if $ret ~~ Failure;
        # Something has gone very wrong
        if +$cqe_ptr != 0 {
          my io_uring_cqe $temp := $cqe_ptr.deref;
          if $temp.user_data {
            ($vow, $request, $data) = self!retrieve($temp.user_data);
            $result = $temp.res;
            $flags = $temp.flags;
            io_uring_cqe_seen($!ring, $cqe_ptr.deref);
            if $result < 0 {
              $vow.keep(Failure.new("{ IORING_OP($request.opcode) } returned result { Errno(-$result) }"));
            }
            else {
              my $cmp = Completion.new(:$data, :$request, :$result, :$flags);
              $vow.keep($cmp);
            }
          }
        }
        else {
          die "Got a NULL Pointer from the completion queue";
        }
      }
      $!close-vow.keep(True);
      CATCH {
        default {
          die $_;
        }
      }
    }
  }

  my sub get-sqe(atomicint $lock is rw, atomicint $threads is rw, $ring is rw, $entries --> io_uring_sqe) is inlinable {
    my $sqe;
    loop {
      lock-int($lock);
      last if atomic-fetch($threads) < $entries;
      unlock-int($lock);
      sleep(0.000125);
    }
    $sqe = $ring.get-sqe;
    atomic-inc-fetch($threads);
    unlock-int($lock);
    return $sqe;
  }

  method !get-handle(io_uring_sqe $sqe, $data, &then?) {
    my Handle $p .= new;
    $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
    my $return;
    with &then {
      my $promise = $p.then(&then);
      $promise!Handle::slot = $sqe.user_data;
      $return = $promise;
    }
    else {
      $p!Handle::slot = $sqe.user_data;
      $return = $p;
    }
    atomic-dec-fetch($!prepare-threads);
    return $return;
  }

  #| Close the IO::URing object and shut down event processing.
  method close() {
    if $!ring ~~ io_uring:D {
      ($!ring, my $temp) = (Failure.new("Tried to use a closed IO::URing"), $!ring);
      io_uring_queue_exit($temp);
      $!close-vow.keep(True);
    }
  }

  #| Get the enabled features on this IO::URing.
  method features() {
    do for IORING_FEAT.enums { .key if $!params.features +& .value }
  }

  my sub to-read-buf($item is rw, :$enc) is inlinable {
    return $item if $item ~~ Blob;
    die "Must pass a Blob";
  }

  my sub to-read-bufs(@items, :$enc) is inlinable {
    @items .= map(&to-read-buf, :$enc);
  }

  my sub to-write-buf($item, :$enc) is inlinable {
    return $item if $item ~~ Blob;
    return $item.encode($enc) if $item ~~ Str;
    return $item.Blob // fail "Don't know how to make $item.^name into a Blob";
  }

  my sub to-write-bufs(@items, :$enc) is inlinable {
    @items.map(&to-write-buf, :$enc);
  }

  method !store($vow, io_uring_sqe $sqe, $user_data --> Int) {
    my size_t $ptr = +malloc(1);
    my $started-task = opcode-to-operation(0xFFFF +& $sqe.opcode).start;
    lock-int($!storage-lock);
    %!storage{$ptr} = ($vow, $sqe, $user_data, $started-task);
    unlock-int($!storage-lock);
    $ptr;
  }

  method !retrieve(Int $slot) {
    my $tmp;
    lock-int($!storage-lock);
    $tmp = %!storage{$slot}:delete;
    unlock-int($!storage-lock);
    $tmp[*-1].end;
    free(Pointer.new($slot));
    return $tmp;
  }

  sub set-flags(:$drain, :$link, :$hard-link, :$force-async --> int) is inlinable {
    my int $flags = 0;
    $flags +|= IOSQE_IO_LINK if $link;
    $flags +|= IOSQE_IO_DRAIN if $drain;
    $flags +|= IOSQE_IO_HARDLINK if $hard-link;
    $flags +|= IOSQE_ASYNC if $force-async;
    $flags;
  }

  method submit() {
    IO::URing::LogTimelineSchema::Submit.log: {
      # If you are the thread that is submitting,
      # Else, some other thread is submitting: Do nothing.
      if cas($!submitting, 0, -1) == 0 {
        # Prevent any threads from getting more SQEs.
        lock-int($!sqe-lock);
        loop {
          last if atomic-fetch($!prepare-threads) == 0;
        }

        io_uring_submit_retry($!ring);
        unlock-int($!sqe-lock);
        atomic-assign($!submitting, 0);
      }
    }
  }

  #| Prepare a no-op operation.
  method prep-nop(Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_nop($sqe);
    $sqe.flags = $flags;
    $sqe.ioprio = $ioprio;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a no-op operation.
  method nop(|c --> Handle) {
    my $handle = self.prep-nop(|c);
    self.submit;
    return $handle;
  }

  multi method prep-readv($fd, |c --> Handle) {
    self.prep-readv($fd.native-descriptor, |c)
  }

  multi method prep-readv(Int $fd, *@bufs, Int :$offset = 0, :$data,
                         Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.prep-readv($fd, @bufs, :$offset, :$ioprio, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare a readv operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  #| A multi with a @bufs slurpy is provided.
  multi method prep-readv(Int $fd, @bufs, Int :$offset = 0, :$data,
                          Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self!prep-readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$ioprio, :$drain, :$link, :$hard-link, :$force-async);
  }

  method !prep-readv(Int $fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my uint $len = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my $pos = 0;
    my @iovecs;
    IO::URing::LogTimelineSchema::MemCpy.log: -> {
      for @bufs -> $buf {
        my IOVec $iov .= new($buf);
        $iovecs[$pos] = +$iov.Pointer;
        $iovecs[$pos + 1] = $iov.elems;
        @iovecs.push($iov);
        $pos += 2;
      }
    }
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_readv($sqe, $fd, nativecast(Pointer[void], $iovecs), $len, $offset);
    $sqe.flags = $flags;
    $sqe.ioprio = $ioprio;
    my &then = -> $val {
      IO::URing::LogTimelineSchema::MemCpy.log: -> {
        for ^@bufs.elems -> $i {
          @bufs[$i] = @iovecs[$i].Blob;
          @iovecs[$i].free;
        }
      }
      $val.result;
    };
    return self!get-handle($sqe, $data, &then)
  }

  #| Prepare and submit a readv operation.
  #| See prep-readv for details.
  method readv(|c --> Handle) {
    my $handle = self.prep-readv(|c);
    self.submit;
    $handle;
  }

  multi method prep-writev($fd, |c --> Handle) {
    self.prep-writev($fd.native-descriptor, |c)
  }

  multi method prep-writev(Int $fd, *@bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.prep-writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare a writev operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  #| A multi with a @bufs slurpy is provided.
  multi method prep-writev(Int $fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self!prep-writev($fd, to-write-bufs(@bufs, :$enc), :$offset, :$ioprio, :$data, :$link);
  }

  method !prep-writev(Int $fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my uint $len = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my @iovecs;
    my $pos = 0;
    IO::URing::LogTimelineSchema::MemCpy.log: -> {
      for @bufs -> $buf {
        my IOVec $iov .= new($buf);
        $iovecs[$pos] = +$iov.Pointer;
        $iovecs[$pos + 1] = $iov.elems;
        @iovecs.push($iov);
        $pos += 2;
      }
    }
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_writev($sqe, $fd, nativecast(Pointer[void], $iovecs), $len, $offset);
    $sqe.flags = $flags;
    $sqe.ioprio = $ioprio;
    my &then = -> $val {
      for @iovecs -> $iov {
        $iov.free;
      }
      $val.result;
    }
    return self!get-handle($sqe, $data, &then);
  }

  #| Prepare and submit a writev operation.
  #| See prep-writev for details.
  method writev(|c --> Handle) {
    my $handle = self.prep-writev(|c);
    self.submit;
    return $handle;
  }

  multi method prep-fsync($fd, |c --> Handle) {
    self.prep-fsync($fd.native-descriptor, |c)
  }

  #| Prepare an fsync operation.
  #| fsync-flags can be set to IORING_FSYNC_DATASYNC to use fdatasync(2) instead. Defaults to fsync(2).
  multi method prep-fsync(Int $fd, UInt $fsync-flags = 0, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_fsync($sqe, $fd, $fsync-flags +& 0xFFFFFFFF);
    $sqe.flags = $flags;
    $sqe.ioprio = $ioprio;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit an fsync operation.
  #| See prep-fsync for details.
  method fsync($fd, UInt $fsync-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-fsync($fd, $fsync-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-poll-add($fd, |c --> Handle) {
    self.prep-poll-add($fd.native-descriptor, |c)
  }

  #| Prepare a poll-add operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-poll-add(Int $fd, UInt $poll-mask, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_poll_add($sqe, $fd, $poll-mask);
    $sqe.flags = $flags;
    $sqe.ioprio = 0;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a poll-add operation.
  #| See prep-poll-add for details.
  method poll-add($fd, UInt $poll-mask, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-poll-add($fd, $poll-mask, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  #| Prepare a poll-remove operation.
  #| The provided Handle must be the Handle returned by the poll-add operation that should be cancelled.
  method prep-poll-remove(Handle $slot, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_poll_remove($sqe, $slot!Handle::slot);
    $sqe.flags = $flags;
    $sqe.ioprio = 0;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a poll-remove operation.
  method poll-remove(Handle $slot, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-poll-remove($slot, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  #| Prepare a sendmsg operation, mimicking sendto(2).
  #| A multi is provided that takes Blobs.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-sendto(Int $fd, Str $str, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async, :$enc = 'utf-8' --> Handle) {
    self.prep-sendto($fd, $str.encode($enc), $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-sendto(Int $fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle ) {
    my msghdr $msg .= new;
    $msg.msg_iov[0] = +nativecast(Pointer, $blob);
    $msg.msg_iov[1] = $blob.bytes;
    with $addr {
      $msg.msg_name = +nativecast(Pointer, $addr);
      $msg.msg_namelen = $len;
    }
    self.prep-sendmsg($fd, $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method sendto(Int $fd, Str $str, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async, :$enc = 'utf-8' --> Handle) {
    self.sendto($fd, $str.encode($enc), $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-sendto($fd, |c --> Handle ) {
    samewith($fd.native-descriptor, |c);
  }

  #| Prepare and submit a sendmsg operation, mimicking sendto(2).
  multi method sendto(Int $fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle ) {
    my $handle = self.prep-sendto($fd, $blob, $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-sendmsg($fd, |c --> Handle) {
    samewith($fd.native-descriptor, |c);
  }

  #| Prepare a sendmsg operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-sendmsg(Int $fd, msghdr:D $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_sendmsg($sqe, $fd, nativecast(Pointer, $msg), $union-flags);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a sendmsg operation.
  method sendmsg($fd, msghdr:D $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-sendmsg($fd, $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-recvfrom($fd, |c --> Handle) {
    self.prep-recvfrom($fd.native-descriptor, |c);
  }

  #| Prepare a recvmsg operation, mimicking recvfrom(2).
  #| A multi is provided that takes Blobs.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-recvfrom(Int $fd, Blob $buf, $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my msghdr $msg .= new;
    $msg.msg_controllen = 0;
    $msg.msg_name = $addr.defined ?? +nativecast(Pointer, $addr) !! 0;
    $msg.msg_namelen = $addr.defined ?? $addr.bytes !! 0;
    $msg.msg_iovlen = 1;
    $msg.msg_iov[0] = +nativecast(Pointer, $buf);
    $msg.msg_iov[1] = $buf.bytes;
    self.prep-recvmsg($fd, $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare and submit a recvmsg operation, mimicking recvfrom(2).
  method recvfrom($fd, Blob $buf, $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-recvfrom($fd, $buf, $flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-recvmsg($fd, msghdr:D $msg is rw, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.prep-recvmsg($fd.native-descriptor, $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare a recvmsg operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-recvmsg(Int $fd, msghdr:D $msg is rw, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_recvmsg($sqe, $fd, nativecast(Pointer, $msg), $union-flags);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  multi method recvmsg($fd, |c --> Handle) {
    samewith($fd.native-descriptor, |c);
  }

  #| Prepare and submit a recvmsg operation
  multi method recvmsg(Int $fd, msghdr:D $msg is rw, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-recvmsg($fd, $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  #| Prepare a cancel operation to cancel a previously submitted operation.
  #| Note that this chases an in-flight operation, meaning it may or maybe not be successful in cancelling the operation.
  #| This means that both cases must be handled.
  method prep-cancel(Handle $slot, UInt $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_cancel($sqe, $union-flags, $slot!Handle::slot);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a cancel operation
  method cancel(Handle $slot, UInt :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-cancel($slot, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-accept($fd, |c --> Handle) {
    self.prep-accept($fd.native-descriptor, |c);
  }

  #| Prepare an accept operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-accept(Int $fd, $sockaddr = Str, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_accept($sqe, $fd, $union-flags, $sockaddr);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit an accept operation.
  method accept($fd, $sockaddr?, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-accept($fd, $sockaddr // Pointer, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-connect($fd, |c) {
    self.prep-connect($fd.native-descriptor, |c);
  }

  #| Prepare a connect operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-connect(Int $fd, sockaddr_role $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_connect($sqe, $fd, $sockaddr);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a connect operation.
  method connect($fd, sockaddr_role $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-connect($fd, $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-send($fd, |c --> Handle) {
    self.prep-send($fd.native-descriptor, |c);
  }

  multi method prep-send(Int $fd, Str $str, :$enc = 'utf-8', |c --> Handle) {
    self.prep-send($fd, $str.encode($enc), |c);
  }

  #| Prepare a send operation.
  #| A multi will handle a Str submission., which takes a named parameter :$enc = 'utf-8'.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-send(Int $fd, Blob $buf, $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_send($sqe, $fd, nativecast(Pointer[void], $buf), $buf.bytes, $union-flags);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a send operation.
  multi method send($fd, $buf, Int $flags = 0, :$enc = 'utf-8', :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-send($fd, $buf, $flags, :$enc, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-recv($fd, |c --> Handle) {
    self.prep-recv($fd.native-descriptor, |c);
  }

  #| Prepare a recv operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-recv(Int $fd, Blob $buf, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_recv($sqe, $fd, nativecast(Pointer[void], $buf), $buf.bytes, $union-flags);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a recv operation.
  multi method recv($fd, Blob $buf, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-recv($fd, $buf, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  multi method prep-close-fd(IO::URing:D: $fd, |c) {
    self.prep-close-fd($fd.native-descriptor, |c);
  }

  #| Prepare a close operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-close-fd(IO::URing:D: Int $fd, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my $sqe = get-sqe($!sqe-lock, $!prepare-threads, $!ring, $!sqe-entries);
    io_uring_prep_close($sqe, $fd);
    $sqe.flags = $flags;
    return self!get-handle($sqe, $data);
  }

  #| Prepare and submit a close operation.
  method close-fd(IO::URing:D: Int $fd, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $handle = self.prep-close-fd($fd, :$data, :$drain, :$link, :$hard-link, :$force-async);
    self.submit();
    return $handle;
  }

  #| Get the supported operations on an IO::URing instance.
  multi method supported-ops(IO::URing:D: --> Hash) {
    return %!supported-ops // do {
      my $probe = io_uring_get_probe_ring($!ring);
      %!supported-ops = $probe.supported-ops();
      $probe.free;
      %!supported-ops;
    }
  }

  #| Get the supported operations without an IO::URing instance.
  multi method supported-ops(IO::URing:U: --> Hash) {
    my $probe = io_uring_get_probe();
    my %supported-ops = $probe.supported-ops();
    $probe.free;
    return %supported-ops;
  }
}

sub EXPORT() {
  my %export = %(
    'IO::URing' => IO::URing,
  );
  %export.append(%IO_URING_RAW_EXPORT);
  %export
}

=begin pod

=head1 AUTHOR

Travis Gibson <TGib.Travis@protonmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

Some of the subs in this library were translated from liburing into Raku.
Liburing is licensed under a dual LGPL and MIT license. Thank you Axboe for this
library and interface.

=end pod
