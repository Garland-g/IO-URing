use v6;
use IO::URing::Raw;
use IO::URing::Socket::Raw :ALL;
use Universal::errno;

use NativeCall;

class IO::URing:ver<0.0.1>:auth<cpan:GARLANDG> {
  my enum STORAGE <EMPTY>;

  my class Completion {
    has $.data;
    has io_uring_sqe $.request;
    has int $.result;
    has int $.flags;
  }

  my class Handle is Promise {
    trusts IO::URing;
    has Int $!slot;
    method !slot(--> Int) is rw { $!slot }
  }

  my class Submission {
    has io_uring_sqe $.sqe is rw;
    has $.addr;
    has $.data;
    has &.then;
  }

  my \tweak-flags = IORING_SETUP_CLAMP;

  has io_uring $!ring .= new;
  has io_uring_params $!params .= new;
  has Lock::Async $!ring-lock .= new;
  has Lock::Async $!storage-lock .= new;
  has %!storage is default(STORAGE::EMPTY);

  submethod TWEAK(UInt :$entries!, UInt :$flags = tweak-flags, Int :$cq-size) {
    $!params.flags = $flags;
    if $cq-size.defined && $cq-size >= $entries {
      given log2($cq-size) {
        $cq-size = 2^($_ + 1) unless $_ ~~ Int;
      }
      $!params.flags +|= IORING_SETUP_CQSIZE;
      $!params.cq_entries = $cq-size;
    }
    my $result = io_uring_queue_init_params($entries, $!ring, $!params);
    start {
      loop {
        my Pointer[io_uring_cqe] $cqe_ptr .= new;
        my $completed := io_uring_wait_cqe($!ring, $cqe_ptr);
        if +$cqe_ptr > 0 {
          my io_uring_cqe $temp := $cqe_ptr.deref;
          my ($vow, $request, $data) = self!retrieve($temp.user_data);
          my $result = $temp.res;
          my $flags = $temp.flags;
          io_uring_cqe_seen($!ring, $cqe_ptr.deref);
          my $cmp = Completion.new(:$data, :$request, :$result, :$flags);
          if $result < 0 {
            set_errno(-$result);
            $vow.break(errno);
            set_errno(0);
          }
          else {
            $vow.keep($cmp);
          }
        }
      }
      CATCH {
        default {
          die $_;
        }
      }
    }
  }

  submethod DESTROY() {
    $!ring-lock.protect: {
      if $!ring ~~ io_uring:D {
        $!storage-lock.protect: {
          for %!storage.keys -> $ptr {
            free(Pointer[void].new(+$ptr));
          }
        }
        io_uring_queue_exit($!ring)
      }
    }
  }

  method close() {
    $!ring-lock.protect: {
      if $!ring ~~ io_uring:D {
        $!storage-lock.protect: {
          for %!storage.keys -> $ptr {
            free(Pointer[void].new(+$ptr));
          }
        }
        io_uring_queue_exit($!ring);
        $!ring = io_uring;
      }
    };
  }

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

  method !submit(io_uring_sqe \sqe, :$drain, :$link, :$hard-link, :$force-async) {
    sqe.flags +|= IOSQE_IO_LINK if $link;
    sqe.flags +|= IOSQE_IO_DRAIN if $drain;
    sqe.flags +|= IOSQE_IO_HARDLINK if $hard-link;
    sqe.flags +|= IOSQE_ASYNC if $force-async;
    io_uring_submit($!ring);
  }

  multi method submit(*@submissions --> Array[Handle]) {
    self.submit(@submissions);
  }

  multi method submit(@submissions --> Array[Handle]) {
    my Handle @handles;
    $!ring-lock.protect: {
      @handles = do for @submissions -> Submission $sub {
        my Handle $p .= new;
        my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
        $p.break(Failure.new("No more room in ring")) unless $sqe.defined;
        $sqe.opcode = $sub.opcode;
        $sqe.flags = $sub.flags;
        $sqe.ioprio = $sub.ioprio;
        $sqe.fd = $sub.fd;
        $sqe.off = $sub.off;
        $sqe.addr = $sub.addr;
        $sqe.len = $sub.len;
        $sqe.union-flags = $sub.union-flags;
        $sqe.user_data = self!store($p.vow, $sqe, $sub.data // Nil);
        $sqe.pad0 = $sqe.pad1 = $sqe.pad2 = 0;
        $sub.then.defined ?? $p.then($sub.then) !! $p;
      }
      io_uring_submit($!ring);
    }
    @handles
  }

  sub set-flags(:$drain, :$link, :$hard-link, :$force-async --> int) {
    my int $flags = 0;
    $flags +|= IOSQE_IO_LINK if $link;
    $flags +|= IOSQE_IO_DRAIN if $drain;
    $flags +|= IOSQE_IO_HARDLINK if $hard-link;
    $flags +|= IOSQE_ASYNC if $force-async;
    $flags;
  }

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
      my iovec $iov .= new($buf);
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

  method readv(|c --> Handle) {
    self.submit(self.prep-readv(|c));
  }

  multi method prep-writev($fd, |c --> Submission) {
    self.prep-writev($fd.native-descriptor, |c)
  }

  multi method prep-writev(Int $fd, *@bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link, :$hard-link, :$force-async);
  }

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
      my iovec $iov .= new($buf);
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

  method writev(|c --> Handle) {
    self.submit(self.prep-writev(|c));
  }

  multi method prep-fsync($fd, |c --> Submission) {
    self.prep-fsync($fd.native-descriptor, |c)
  }

  multi method prep-fsync(Int $fd, UInt $union-flags, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
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
                    :union-flags($union-flags +& 0xFFFFFFFF),
                  ),
                  :$data,
                  );
  }

  method fsync($fd, UInt $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-fsync($fd, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-poll-add($fd, |c --> Submission) {
    self.prep-poll-add($fd.native-descriptor, |c)
  }

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

  method poll-add($fd, UInt $poll-mask, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-poll-add($fd, $poll-mask, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

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

  method poll-remove(Handle $slot, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-poll-remove($slot, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-sendto($fd, Str $str, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async, :$enc = 'utf-8' --> Submission) {
    self.prep-sendto($fd, $str.encode($enc), $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-sendto($fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission ) {
    my msghdr $msg .= new;
    $msg.msg_iov[0] = +nativecast(Pointer, $blob);
    $msg.msg_iov[1] = $blob.bytes;
    with $addr {
      $msg.msg_name = +nativecast(Pointer, $addr);
      $msg.msg_namelen = $len;
    }
    self.prep-sendmsg($fd, $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method sendto($fd, Str $str, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async, :$enc = 'utf-8' --> Handle) {
    self.sendto($fd, $str.encode($enc), $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method sendto($fd, |c --> Handle ) {
    samewith($fd.native-descriptor, |c);
  }

  multi method sendto(Int $fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle ) {
    self.submit(self.prep-sendto($fd, $blob, $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-sendmsg($fd, |c --> Submission) {
    samewith($fd.native-descriptor, |c);
  }

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

  method sendmsg($fd, msghdr:D $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-sendmsg($fd, $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  method prep-recvfrom($fd, Blob $buf, $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my msghdr $msg .= new;
    $msg.msg_controllen = 0;
    $msg.msg_name = $addr.defined ?? +nativecast(Pointer, $addr) !! 0;
    $msg.msg_namelen = $addr.defined ?? $addr.bytes !! 0;
    $msg.msg_iovlen = 1;
    $msg.msg_iov[0] = +nativecast(Pointer, $buf);
    $msg.msg_iov[1] = $buf.bytes;
    self.prep-recvmsg($fd, $msg, $flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  method recvfrom($fd, Blob $buf, $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-recvfrom($fd, $buf, $flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-recvmsg($fd, |c) {
    self.prep-recvmsg($fd.native-descriptor, |c);
  }

  multi method prep-recvmsg(Int $fd, msghdr:D $msg is rw, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
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

  multi method recvmsg(Int $fd, msghdr:D $msg is rw, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-recvmsg($fd, $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

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

  method cancel(Handle $slot, UInt :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-cancel($slot, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-accept($fd, |c --> Submission) {
    self.prep-accept($fd.native-descriptor, |c);
  }

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

  method accept($fd, $sockaddr?, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-accept($fd, $sockaddr // Pointer));
  }

  multi method prep-connect($fd, |c) {
    self.prep-connect($fd.native-descriptor, |c);
  }

  multi method prep-connect(Int $fd, $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :sqe(io_uring_sqe.new:
                            :opcode(IORING_OP_CONNECT),
                            :$flags,
                            :ioprio(0),
                            :$fd,
                            :off(0),
                            :union-flags(0),
                            :len($sockaddr.size),
                          ),
                          :addr($sockaddr),
                          :$data
                          )
  }

  method connect($fd, $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-connect($fd, $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-send($fd, |c --> Submission) {
    self.prep-send($fd.native-descriptor, |c);
  }

  multi method prep-send(Int $fd, Str $str, :$enc = 'utf-8', |c --> Submission) {
    self.prep-send($fd, $str.encode($enc), |c);
  }

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

  multi method send($fd, $buf, Int $flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-send($fd, $buf, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-recv($fd, |c --> Submission) {
    self.prep-recv($fd.native-descriptor, |c);
  }

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

  multi method recv($fd, Blob $buf, Int $union-flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.recv($fd, $buf, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
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

=head1 AUTHOR

Travis Gibson <TGib.Travis@protonmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2020 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

Some of the subs in this library were translated from liburing into Raku.
Liburing is licensed under a dual LGPL and MIT license. Thank you Axboe for this
library and interface.

=end pod
