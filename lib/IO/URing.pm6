use v6;
use IO::URing::Raw;
use IO::URing::Socket::Raw :ALL;
use Universal::errno::Constants;

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

It will only work on Linux 5.1 and above. Use with 5.6 or above for best results.
See the io_uring documentation for which operations are supported on your kernel version.

See the included IO::URing::Socket libraries for an example of IO::URing in action.

Some knowledge of io_uring and liburing is a pre-requisite for using this library.
This code uses liburing to set up and submit requests to the ring.

=head1 IO::URing internal classes

=end pod

class IO::URing:ver<0.0.3>:auth<cpan:GARLANDG> {
  my enum STORAGE <EMPTY>;

  #| A Completion is returned from an awaited Handle.
  #| The completion contains the result of the operation.
  my class Completion {
    #| The user data passed into the Submission.
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
    method !slot(--> Int) is rw { $!slot }
  }

  #| A Submission holds a request for an operation.
  #| Every call to a "prep" method will return a Submission.
  #| A Submission can be passed into the submit method.
  my class Submission {
    has io_uring_sqe $.sqe is rw;
    has $.addr;
    has $.data;
    has &.then;
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
  has int32 $!eventfd;
  has io_uring_params $!params .= new;
  has Lock::Async $!storage-lock .= new;
  has %!storage is default(STORAGE::EMPTY);
  has Channel $!queue .= new;
  has %!supported-ops;

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
    $!eventfd = eventfd(1, 0);
    start {
        self!arm();
        io_uring_submit($!ring);
        my Pointer[io_uring_cqe] $cqe_ptr .= new;
        my $vow;
        my int $result;
        my int $flags;
        my $data;
        my $request;
        my uint64 $jobs;
      loop {
        my $ret = io_uring_wait_cqe($!ring, $cqe_ptr);
        $!close-vow.break($ret.Exception) if $ret ~~ Failure; # Something has gone very wrong
        if +$cqe_ptr != 0 {
          my io_uring_cqe $temp := $cqe_ptr.deref;
          if $temp.user_data {
            ($vow, $request, $data) = self!retrieve($temp.user_data);
            $result = $temp.res;
            $flags = $temp.flags;
            io_uring_cqe_seen($!ring, $cqe_ptr.deref);
            if $result < 0 {
              $vow.keep(Failure.new("{IORING_OP($request.opcode)} returned result {Errno(-$result)}"));
            }
            else {
              my $cmp = Completion.new(:$data, :$request, :$result, :$flags);
              $vow.keep($cmp);
            }
          }
          else {
            io_uring_cqe_seen($!ring, $cqe_ptr.deref);
            eventfd_read($!eventfd, $jobs);
            if $jobs > $!entries {
              self!close();
              last;
            }
            self!empty-queue();
            self!arm();
            io_uring_submit($!ring);
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

  method !arm() {
    # This only runs on the submission thread
    my $sqe := io_uring_get_sqe($!ring);
    without $sqe {
      # If people are batching to the limit...
      io_uring_submit($!ring);
      $sqe := io_uring_get_sqe($!ring);
    }
    io_uring_prep_poll_add($sqe, $!eventfd, POLLIN);
    $sqe.user_data = 0;
  }

  method !empty-queue() {
    # This only runs on the submission thread
    my $v;
    my $subs;
    my Handle @handles;
    loop {
      if $!queue.poll -> (:key($v), :value($subs)) {
        @handles = do for @$subs -> Submission $sub {
          my Handle $p .= new;
          with $sub.sqe {
            my $sqe := io_uring_get_sqe($!ring);
            without $sqe {
                io_uring_submit($!ring);
                $sqe := io_uring_get_sqe($!ring);
            }
            $p.break("No more room in ring") unless $sqe.defined;
            memcpy(nativecast(Pointer, $sqe), nativecast(Pointer, $sub.sqe), nativesizeof($sqe));
            with $sub.addr {
                $sqe.addr = $sub.addr ~~ Int ?? $sub.addr !! +nativecast(Pointer, $_);
            }
            $sqe.user_data = self!store($p.vow, $sqe, $sub.data // Nil);
            with $sub.then {
                my $promise = $p.then($sub.then);
                $promise!Handle::slot = $sqe.user_data;
                $promise
            }
            else {
                $p!Handle::slot = $sqe.user_data;
                $p
            }
          }
          else {
            self!pseudo-op-handler($sub);
            $p
          }
        }
        $v.keep(@handles.elems > 1 ?? @handles !! @handles[0]);
      }
      else { last }
    }
    CATCH {
      default { die $_ }
    }
  }

  method !pseudo-op-handler(Submission $sub) {
    io_uring_submit($!ring);
    if $sub.data ~~ "close-fd" {
      shutdown($sub.addr, SHUT_RDWR);
      close($sub.addr);
    }
  }

  method !close() {
    if $!ring ~~ io_uring:D {
      my @promises;
      $!storage-lock.protect: {
        for %!storage.keys -> $ptr {
          @promises.push($!ring!cancel(+$ptr));
          free(Pointer[void].new(+$ptr));
        }
      }
      ($!ring, my $temp) = (Failure.new("Tried to use a closed IO::URing"), $!ring);
      await @promises;
      io_uring_queue_exit($temp);
      $!close-vow.keep(True);
    }
  }

  #| Close the IO::URing object and shut down event processing.
  method close() {
    eventfd_write($!eventfd, $!entries + 1);
    await $!close-promise;
  }

  #| Get the enabled features on this IO::URing.
  method features() {
    do for IORING_FEAT.enums { .key if $!params.features +& .value }
  }

  my sub to-read-buf($item is rw, :$enc) {
    return $item if $item ~~ Blob;
    die "Must pass a Blob";
  }

  my sub to-read-bufs(@items, :$enc) {
    @items .= map(&to-read-buf, :$enc);
  }

  my sub to-write-buf($item, :$enc) {
    return $item if $item ~~ Blob;
    return $item.encode($enc) if $item ~~ Str;
    return $item.Blob // fail "Don't know how to make $item.^name into a Blob";
  }

  my sub to-write-bufs(@items, :$enc) {
    @items.map(&to-write-buf, :$enc);
  }

  method !store($vow, io_uring_sqe $sqe, $user_data --> Int) {
    my size_t $ptr = +malloc(1);
    $!storage-lock.protect: {
      %!storage{$ptr} = ($vow, $sqe, $user_data);
    };
    $ptr;
  }

  method !retrieve(Int $slot) {
    my $tmp;
    $!storage-lock.protect: {
      $tmp = %!storage{$slot}:delete;
    };
    free(Pointer.new($slot));
    return $tmp;
  }

  multi method submit(*@submissions --> Array[Handle]) {
    self.submit(@submissions);
  }

  #| Submit multiple Submissions to the IO::URing. A slurpy variant is provided.
  #| Returns an Array of Handles.
  multi method submit(@submissions --> Array[Handle]) {
    my Handle $handles-promise .= new;
    $!queue.send($handles-promise.vow => @submissions);
    eventfd_write($!eventfd, @submissions.elems);
    $handles-promise.result;
  }

  #| Submit a single Submission to the IO::URing.
  #| Returns a Handle.
  multi method submit(Submission $sub --> Handle) {
    my Handle $handle-promise .= new;
    $!queue.send($handle-promise.vow => $sub);
    eventfd_write($!eventfd, 1);
    $handle-promise.result;
  }

  sub set-flags(:$drain, :$link, :$hard-link, :$force-async --> int) {
    my int $flags = 0;
    $flags +|= IOSQE_IO_LINK if $link;
    $flags +|= IOSQE_IO_DRAIN if $drain;
    $flags +|= IOSQE_IO_HARDLINK if $hard-link;
    $flags +|= IOSQE_ASYNC if $force-async;
    $flags;
  }

  #| Prepare a no-op operation.
  method prep-nop(:$data, :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                         :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_NOP),
                            :$flags,
                            :$ioprio,
                            :fd(-1),
                            :off(0),
                            :len(0),
                         ),
                         :$data);
  }

  #| Prepare and submit a no-op operation.
  method nop(|c --> Handle) {
    self.submit(self.prep-nop(|c));
  }

  multi method prep-readv($fd, |c --> Submission) {
    self.prep-readv($fd.native-descriptor, |c)
  }

  multi method prep-readv(Int $fd, *@bufs, Int :$offset = 0, :$data,
                         Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-readv($fd, @bufs, :$offset, :$ioprio, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare a readv operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  #| A multi with a @bufs slurpy is provided.
  multi method prep-readv(Int $fd, @bufs, Int :$offset = 0, :$data,
                          Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self!prep-readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$ioprio, :$drain, :$link, :$hard-link, :$force-async);
  }

  method !prep-readv(Int $fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my uint $len = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my $pos = 0;
    my @iovecs;
    for @bufs -> $buf {
      my IOVec $iov .= new($buf);
      $iovecs[$pos] = +$iov.Pointer;
      $iovecs[$pos + 1] = $iov.elems;
      @iovecs.push($iov);
      $pos += 2;
    }
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_READV),
                            :$flags,
                            :$ioprio,
                            :$fd,
                            :off($offset),
                            :$len,
                          ),
                          :addr($iovecs),
                          :$data,
                          :then(-> $val {
                            for ^@bufs.elems -> $i {
                              @bufs[$i] = @iovecs[$i].Blob;
                              @iovecs[$i].free;
                            }
                            $val.result;
                          }),
                         );
  }

  #| Prepare and submit a readv operation.
  #| See prep-readv for details.
  method readv(|c --> Handle) {
    self.submit(self.prep-readv(|c));
  }

  multi method prep-writev($fd, |c --> Submission) {
    self.prep-writev($fd.native-descriptor, |c)
  }

  multi method prep-writev(Int $fd, *@bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare a writev operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  #| A multi with a @bufs slurpy is provided.
  multi method prep-writev(Int $fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self!prep-writev($fd, to-write-bufs(@bufs, :$enc), :$offset, :$ioprio, :$data, :$link);
  }

  method !prep-writev(Int $fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my uint $len = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my @iovecs;
    my $pos = 0;
    for @bufs -> $buf {
      my IOVec $iov .= new($buf);
      $iovecs[$pos] = +$iov.Pointer;
      $iovecs[$pos + 1] = $iov.elems;
      @iovecs.push($iov);
      $pos += 2;
    }
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_WRITEV),
                            :$flags,
                            :$ioprio,
                            :$fd,
                            :off($offset),
                            :$len,
                          ),
                          :addr($iovecs),
                          :$data,
                          :then(-> $val {
                            for @iovecs -> $iov {
                              $iov.free;
                            }
                            $val.result;
                          }),
                         );
  }

  #| Prepare and submit a writev operation.
  #| See prep-writev for details.
  method writev(|c --> Handle) {
    self.submit(self.prep-writev(|c));
  }

  multi method prep-fsync($fd, |c --> Submission) {
    self.prep-fsync($fd.native-descriptor, |c)
  }

  #| Prepare an fsync operation.
  #| fsync-flags can be set to IORING_FSYNC_DATASYNC to use fdatasync(2) instead. Defaults to fsync(2).
  multi method prep-fsync(Int $fd, UInt $fsync-flags = 0, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                  :sqe(io_uring_sqe.new:
                    :opcode(IORING_OP_FSYNC),
                    :$flags,
                    :$ioprio,
                    :$fd,
                    :off(0),
                    :addr(0),
                    :len(0),
                    :union-flags($fsync-flags +& 0xFFFFFFFF),
                  ),
                  :$data,
                  );
  }

  #| Prepare and submit an fsync operation.
  #| See prep-fsync for details.
  method fsync($fd, UInt $fsync-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-fsync($fd, $fsync-flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-poll-add($fd, |c --> Submission) {
    self.prep-poll-add($fd.native-descriptor, |c)
  }

  #| Prepare a poll-add operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-poll-add(Int $fd, UInt $poll-mask, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_POLL_ADD),
                            :$flags,
                            :$ioprio,
                            :$fd,
                            :off(0),
                            :addr(0),
                            :len(0),
                            :union-flags($poll-mask +& 0xFFFF),
                          ),
                          :$data,
                         );
  }

  #| Prepare and submit a poll-add operation.
  #| See prep-poll-add for details.
  method poll-add($fd, UInt $poll-mask, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-poll-add($fd, $poll-mask, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  #| Prepare a poll-remove operation.
  #| The provided Handle must be the Handle returned by the poll-add operation that should be cancelled.
  method prep-poll-remove(Handle $slot, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_POLL_REMOVE),
                            :$flags,
                            :$ioprio,
                            :fd(-1),
                            :off(0),
                            :addr($slot!Handle::slot),
                            :len(0),
                          ),
                          :$data,
                          );
  }

  #| Prepare and submit a poll-remove operation.
  method poll-remove(Handle $slot, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-poll-remove($slot, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  #| Prepare a sendto operation.
  #| This is a wrapper around the sendmsg call for ease of use.
  #| A multi is provided that takes Blobs.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-sendto(Int $fd, Str $str, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async, :$enc = 'utf-8' --> Submission) {
    self.prep-sendto($fd, $str.encode($enc), $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-sendto(Int $fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission ) {
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

  #| Prepare and submit a sendto operation
  multi method sendto($fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle ) {
    self.submit(self.prep-sendto($fd, $blob, $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-sendmsg($fd, |c --> Submission) {
    samewith($fd.native-descriptor, |c);
  }

  #| Prepare a sendmsg operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-sendmsg(Int $fd, msghdr:D $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_SENDMSG),
                            :$flags,
                            :ioprio(0),
                            :$fd,
                            :off(0),
                            :$union-flags,
                            :len(1),
                          ),
                          :addr($msg),
                          :$data
                          )
  }

  #| Prepare and submit a sendmsg operation.
  method sendmsg($fd, msghdr:D $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-sendmsg($fd, $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-recvfrom($fd, |c --> Submission) {
    self.prep-recvfrom($fd.native-descriptor, |c);
  }

  #| Prepare a recvfrom operation.
  #| This is a wrapper around the recvmsg call for ease of use.
  #| A multi is provided that takes Blobs.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-recvfrom(Int $fd, Blob $buf, $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my msghdr $msg .= new;
    $msg.msg_controllen = 0;
    $msg.msg_name = $addr.defined ?? +nativecast(Pointer, $addr) !! 0;
    $msg.msg_namelen = $addr.defined ?? $addr.bytes !! 0;
    $msg.msg_iovlen = 1;
    $msg.msg_iov[0] = +nativecast(Pointer, $buf);
    $msg.msg_iov[1] = $buf.bytes;
    self.prep-recvmsg($fd, $msg, $flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare and submit a recvfrom operation.
  method recvfrom($fd, Blob $buf, $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-recvfrom($fd, $buf, $flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-recvmsg($fd, msghdr:D $msg is rw, $union-flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-recvmsg($fd.native-descriptor, $msg, $union-flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  #| Prepare a recvmsg operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-recvmsg(Int $fd, msghdr:D $msg is rw, $union-flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_RECVMSG),
                            :$flags,
                            :ioprio(0),
                            :$fd,
                            :off(0),
                            :$union-flags,
                            :len(1),
                          ),
                          :addr($msg),
                          :$data
                          )
  }

  multi method recvmsg($fd, |c --> Handle) {
    samewith($fd.native-descriptor, |c);
  }

  #| Prepare and submit a recvmsg operation
  multi method recvmsg(Int $fd, msghdr:D $msg is rw, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-recvmsg($fd, $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  #| Prepare a cancel operation to cancel a previously submitted operation.
  #| Note that this chases an in-flight operation, meaning it may or maybe not be successful in cancelling the operation.
  #| This means that both cases must be handled.
  method prep-cancel(Handle $slot, UInt $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_ASYNC_CANCEL),
                            :$flags,
                            :ioprio(0),
                            :fd(-1),
                            :off(0),
                            :$union-flags,
                            :addr($slot!Handle::slot)
                            :len(0),
                          ),
                          :$data
                          )
  }

  method !prep-cancel(Int $slot, UInt $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
      my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
      return Submission.new(
              :sqe(io_uring_sqe.new:
                      :opcode(IORING_OP_ASYNC_CANCEL),
                      :$flags,
                      :ioprio(0),
                      :fd(-1),
                      :off(0),
                      :$union-flags,
                      :addr($slot)
                      :len(0),
              ),
              :$data
              )
  }

  #| Prepare and submit a cancel operation
  method cancel(Handle $slot, UInt :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
      self.submit(self.prep-cancel($slot, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  method !cancel(Int $slot, UInt :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self!prep-cancel($slot, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-accept($fd, |c --> Submission) {
    self.prep-accept($fd.native-descriptor, |c);
  }

  #| Prepare an accept operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-accept(Int $fd, $sockaddr?, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_ACCEPT),
                            :$flags,
                            :ioprio(0),
                            :$fd,
                            :off(0),
                            :$union-flags,
                            :len($sockaddr.defined ?? $sockaddr.size !! 0),
                          ),
                          :addr($sockaddr.defined ?? $sockaddr !! Any),
                          :$data
                          )
  }

  #| Prepare and submit an accept operation.
  method accept($fd, $sockaddr?, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-accept($fd, $sockaddr // Pointer));
  }

  multi method prep-connect($fd, |c) {
    self.prep-connect($fd.native-descriptor, |c);
  }

  #| Prepare a connect operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-connect(Int $fd, sockaddr_role $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_CONNECT),
                            :$flags,
                            :ioprio(0),
                            :$fd,
                            :off($sockaddr.size), # Not a bug. This is how connect is done.
                            :union-flags(0),
                            :len(0),
                          ),
                          :addr($sockaddr),
                          :$data
                          )
  }

  #| Prepare and submit a connect operation.
  method connect($fd, sockaddr_role $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-connect($fd, $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-send($fd, |c --> Submission) {
    self.prep-send($fd.native-descriptor, |c);
  }

  multi method prep-send(Int $fd, Str $str, :$enc = 'utf-8', |c --> Submission) {
    self.prep-send($fd, $str.encode($enc), |c);
  }

  #| Prepare a send operation.
  #| A multi will handle a Str submission., which takes a named parameter :$enc = 'utf-8'.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-send(Int $fd, Blob $buf, $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_SEND),
                            :$flags,
                            :ioprio(0),
                            :$fd,
                            :off(0),
                            :$union-flags,
                            :len($buf.bytes),
                          ),
                          :addr($buf),
                          :$data
                          )
  }

  #| Prepare and submit a send operation.
  multi method send($fd, $buf, Int $flags = 0, :$enc = 'utf-8', :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-send($fd, $buf, $flags, :$enc, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-recv($fd, |c --> Submission) {
    self.prep-recv($fd.native-descriptor, |c);
  }

  #| Prepare a recv operation.
  #| A multi will handle a non-Int $fd by calling native-descriptor.
  multi method prep-recv(Int $fd, Blob $buf, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_RECV),
                            :$flags,
                            :ioprio(0),
                            :$fd,
                            :off(0),
                            :$union-flags,
                            :len($buf.bytes),
                          ),
                          :addr($buf),
                          :$data
                          )
  }

  #| Prepare and submit a recv operation.
  multi method recv($fd, Blob $buf, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-recv($fd, $buf, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  #| Prepare a submit a close-fd operation.
  #| This is a fake operation which will be used until linux kernels older than 5.6 are unsupported.
  method close-fd(IO::URing:D: Int $fd --> Handle) {
    self.submit(
      Submission.new(
                      :sqe(io_uring_sqe:U)
                      :addr($fd),
                      :data("close-fd"),
                     )
    )
  # This method mitigates a race condition where a socket could be closed before any final send operation started.
  # Once the send operation has started, close can be called safely, as the kernel will make sure the data is sent from the socket before it closes it.
  #TODO: This should be replaced by IORING_OP_CLOSE once linux kernel 5.6 goes out of date.
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
