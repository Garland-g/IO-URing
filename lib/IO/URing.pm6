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
    has int $.opcode = 0;
    has int $.flags = 0;
    has uint $.ioprio = 0;
    has int $.fd = -1;
    has uint $.off = 0;
    has uint $.addr = 0;
    has uint $.len = 0;
    has uint $.union-flags = 0;
    has uint $.buf_index = 0;
    has uint $.personality = 0;
    has $.data;
    has &.then;
  }

  my \tweak-flags = IORING_SETUP_CLAMP;

  has io_uring $!ring .= new;
  has io_uring_params $!params .= new;
  has Lock::Async $!ring-lock .= new;
  has Lock::Async $!storage-lock .= new;
  has @!storage is default(STORAGE::EMPTY);

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
        io_uring_queue_exit($!ring)
      }
    }
  }

  method close() {
    $!ring-lock.protect: {
      if $!ring ~~ io_uring:D {
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
    my Int $slot = 0;
    $!storage-lock.protect: {
      until @!storage[$slot] ~~ STORAGE::EMPTY { $slot++ }
      @!storage[$slot] = ($vow, $sqe, $user_data);
    };
    $slot;
  }

  method !retrieve(Int $slot) {
    my $tmp;
    $!storage-lock.protect: {
      $tmp = @!storage[$slot];
      @!storage[$slot] = STORAGE::EMPTY;
    };
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
    $flags;
  }

  method prep-nop(:$data, :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                         :opcode(IORING_OP_NOP),
                         :$flags,
                         :$ioprio,
                         :fd(-1),
                         :off(0),
                         :addr(0),
                         :len(0),
                         :$data);
  }

  method nop(:$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_nop($sqe);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  multi method prep-readv($fd, *@bufs, Int :$offset = 0, :$data,
                         Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-readv($fd, @bufs, :$offset, :$ioprio, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-readv($fd, @bufs, Int :$offset = 0, :$data,
                          Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self!prep-readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$ioprio, :$drain, :$link, :$hard-link, :$force-async);
  }

  method !prep-readv($fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async) {
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
                          :opcode(IORING_OP_READV),
                          :$flags,
                          :$ioprio,
                          :fd($fd.native-descriptor),
                          :off($offset),
                          :addr(+nativecast(Pointer, $iovecs)),
                          :$len,
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

  multi method readv($fd, *@bufs, Int :$offset = 0, :$data = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.readv($fd, @bufs, :$offset, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method readv($fd, @bufs, Int :$offset = 0, :$data = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self!readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  method !readv($fd, @bufs, Int :$offset = 0, :$data = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $num_vr = @bufs.elems;
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
    my Handle $promise .= new;
    my Handle $p = $promise.then(-> $val {
      for ^@bufs.elems -> $i {
        @bufs[$i] = @iovecs[$i].Blob;
        @iovecs[$i].free;
      }
      $val.result;
    });
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_readv($sqe, $fd.native-descriptor, nativecast(Pointer[size_t], $iovecs), $num_vr, $offset);
      $sqe.user_data = self!store($promise.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p
  }

  multi method prep-writev($fd, *@bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-writev($fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self!prep-writev($fd, to-write-bufs(@bufs, :$enc), :$offset, :$ioprio, :$data, :$link);
  }

  method !prep-writev($fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
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
                          :opcode(IORING_OP_WRITEV),
                          :$flags,
                          :$ioprio,
                          :fd($fd.native-descriptor),
                          :off($offset),
                          :addr(+nativecast(Pointer, $iovecs)),
                          :$len,
                          :$data,
                          :then(-> $val {
                            for @iovecs -> $iov {
                              $iov.free;
                            }
                            $val.result;
                          }),
                         );
  }

  multi method writev($fd, *@bufs, Int :$offset = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method writev($fd, @bufs, Int :$offset = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self!writev($fd, to-write-bufs(@bufs, :$enc), :$offset, :$data, :$link);
  }

  method !writev($fd, @bufs, Int :$offset, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $num_vr = @bufs.elems;
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
    my Handle $promise .= new;
    my Handle $p = $promise.then( -> $val {
      for @iovecs -> $iov {
        $iov.free;
      }
      $val.result;
    });
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_writev($sqe, $fd.native-descriptor, nativecast(Pointer[size_t], $iovecs), $num_vr, $offset);
      $sqe.user_data = self!store($promise.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  method prep-fsync($fd, UInt $union-flags, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                  :opcode(IORING_OP_FSYNC),
                  :$flags,
                  :$ioprio,
                  :fd($fd.native-descriptor),
                  :off(0),
                  :addr(0),
                  :len(0),
                  :union-flags($union-flags +& 0xFFFFFFFF),
                  :$data,
                  );
  }

  method fsync($fd, UInt $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_fsync($sqe, $fd.native-descriptor, $flags);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  method prep-poll-add($fd, UInt $poll-mask, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :opcode(IORING_OP_POLL_ADD),
                          :$flags,
                          :$ioprio,
                          :fd($fd.native-descriptor),
                          :off(0),
                          :addr(0),
                          :len(0),
                          :$data,
                         );
  }

  method poll-add($fd, UInt $poll-mask, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $user_data;
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_poll_add($sqe, $fd, $poll-mask);
      $user_data = self!store($p.vow, $sqe, $data // Nil);
      $sqe.user_data = $user_data;
      $p!Handle::slot = $user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  method prep-poll-remove(Handle $slot, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :opcode(IORING_OP_POLL_REMOVE),
                          :$flags,
                          :$ioprio,
                          :fd(-1),
                          :off(0),
                          :addr($slot!Handle::slot),
                          :len(0),
                          :$data,
                          );
  }

  method poll-remove(Handle $slot, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      my Int $user_data = self!store($p.vow, $sqe, $data // Nil);
      io_uring_prep_poll_remove($sqe, $slot!Handle::slot);
      $sqe.user_data = $user_data;
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  multi method prep-sendto($fd, Str $str, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async, :$enc = 'utf-8' --> Submission) {
    self.prep-sendto($fd, $str.encode($enc), $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-sendto($fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission ) {
    my msghdr $msg .= new;
    $msg.msg_name = 0;
    $msg.msg_controllen = 0;
    $msg.msg_namelen = 0;
    $msg.msg_iovlen = 1;
    $msg.msg_iov[0] = +nativecast(Pointer, $blob);
    $msg.msg_iov[1] = $blob.bytes;
    with $addr {
      $msg.msg_name = nativecast(Pointer, $addr);
      $msg.msg_namelen = $len;
    }
    self.prep-sendmsg($fd, $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method sendto($fd, Str $str, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async, :$enc = 'utf-8' --> Handle) {
    self.sendto($fd, $str.encode($enc), $union-flags, $addr, $len, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method sendto($fd, Blob $blob, Int $union-flags, sockaddr_role $addr, Int $len, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle ) {
    my msghdr $msg .= new;
    $msg.msg_name = 0;
    $msg.msg_controllen = 0;
    $msg.msg_namelen = 0;
    $msg.msg_iovlen = 1;
    $msg.msg_iov[0] = +nativecast(Pointer, $blob);
    $msg.msg_iov[1] = $blob.bytes;
    with $addr {
      $msg.msg_name = nativecast(Pointer, $addr);
      $msg.msg_namelen = $len;
    }
    self.sendmsg($fd, $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-sendmsg(Int $fd, msghdr:D $msg, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                          :opcode(IORING_OP_SENDMSG),
                          :$flags,
                          :ioprio(0),
                          :$fd,
                          :off(0),
                          :$union-flags,
                          :addr(+nativecast(Pointer, $msg)),
                          :len(0),
                          :$data
                          )
  }

  method sendmsg($fd, msghdr:D $msg, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_sendmsg($sqe, $fd, nativecast(Pointer, $msg), $flags);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  method recvfrom($fd, Blob $buf, uint32 $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my msghdr $msg .= new;
    $msg.msg_controllen = 0;
    $msg.msg_name = $addr.defined ?? +nativecast(Pointer, $addr) !! 0;
    $msg.msg_namelen = $addr.defined ?? $addr.bytes !! 0;
    $msg.msg_iovlen = 1;
    $msg.msg_iov[0] = +nativecast(Pointer, $buf);
    $msg.msg_iov[1] = $buf.bytes;
    self.recvmsg($fd, $msg,  $flags, :$data, :$link, :$drain, :$link, :$hard-link, :$force-async);
  }

  method recvmsg($fd, msghdr:D $msg is rw, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_recvmsg($sqe, $fd, nativecast(Pointer, $msg), $flags);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  method cancel(Handle $slot, UInt :$flags = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      my Int $user_data = $slot!Handle::slot;
      io_uring_prep_cancel($sqe, $flags, $user_data);
      $sqe.user_data = $user_data;
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p
  }

  method accept($fd, $sockaddr?, Int :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_accept($sqe, $fd, $flags, $sockaddr);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  method connect($fd, $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_connect($sqe, $fd, $sockaddr);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  multi method send($fd, Str $str, Int :$flags = 0, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.send($fd, $str.encode($enc), :$flags, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method send($fd, Blob $buf, Int :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_send($sqe, $fd, nativecast(Pointer[void], $buf), $buf.bytes, $flags);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
  }

  multi method recv($fd, Blob $buf, Int :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe := io_uring_get_sqe($!ring);
      io_uring_prep_recv($sqe, $fd, nativecast(Pointer[void], $buf), $buf.bytes, $flags);
      $sqe.user_data = self!store($p, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link, :$hard-link, :$force-async);
    }
    $p;
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
