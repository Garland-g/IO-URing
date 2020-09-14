use v6;
use IO::URing::Raw;
use IO::URing::Socket::Raw :ALL;
use Universal::errno::Constants;

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
        $!close-vow.break(Errno(-$ret)) if $ret < 0; # Something has gone very wrong
        if +$cqe_ptr > 0 {
          my io_uring_cqe $temp := $cqe_ptr.deref;
          if $temp.user_data {
            ($vow, $request, $data) = self!retrieve($temp.user_data);
            $result = $temp.res;
            $flags = $temp.flags;
            io_uring_cqe_seen($!ring, $cqe_ptr.deref);
            my $cmp = Completion.new(:$data, :$request, :$result, :$flags);
            if $result < 0 {
              $vow.keep(Failure.new(Errno(-$result)));
            }
            else {
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
          my $sqe := io_uring_get_sqe($!ring);
          without $sqe {
            io_uring_submit($!ring);
            $sqe := io_uring_get_sqe($!ring);
          }
          $p.break(Failure.new("No more room in ring")) unless $sqe.defined;
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
        $v.keep(@handles.elems > 1 ?? @handles !! @handles[0]);
      }
      else { last }
    }
    CATCH {
      default { die $_ }
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

  method close() {
    eventfd_write($!eventfd, $!entries + 1);
    await $!close-promise;
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

  multi method submit(*@submissions --> Array[Handle]) {
    self.submit(@submissions);
  }

  multi method submit(@submissions --> Array[Handle]) {
    my Handle $handles-promise .= new;
    $!queue.send($handles-promise.vow => @submissions);
    eventfd_write($!eventfd, @submissions.elems);
    $handles-promise.result;
  }

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

  multi method prep-recvfrom($fd, |c --> Submission) {
    self.prep-recvfrom($fd.native-descriptor, |c);
  }

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

  method recvfrom($fd, Blob $buf, $flags, Blob $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-recvfrom($fd, $buf, $flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-recvmsg($fd, msghdr:D $msg is rw, $union-flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-recvmsg($fd.native-descriptor, $msg, $union-flags, $addr, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

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

  method cancel(Handle $slot, UInt :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
      self.submit(self.prep-cancel($slot, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  method !cancel(Int $slot, UInt :$flags = 0, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self!prep-cancel($slot, $flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
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

  method connect($fd, sockaddr_role $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.submit(self.prep-connect($fd, $sockaddr, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method prep-send($fd, Str $str,  |c --> Submission) {
    self.prep-send($fd.native-descriptor, $str, |c);
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
    self.submit(self.prep-recv($fd, $buf, $union-flags, :$data, :$drain, :$link, :$hard-link, :$force-async));
  }

  multi method supported-ops(IO::URing:D: --> Hash) {
    return %!supported-ops // do {
      my $probe = io_uring_get_probe_ring($!ring);
      %!supported-ops = $probe.supported-ops();
      $probe.free;
      %!supported-ops;
    }
  }

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
