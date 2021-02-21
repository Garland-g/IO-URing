use v6;
use IO::URing::Raw;
use IO::URing::Socket::Raw :ALL;
use Constants::Sys::Socket :AF, :SOCK;
use Universal::errno;
use NativeCall;
use Test;

sub blob-to-msghdr(Blob:D $blob, $sockaddr?) {
  my msghdr $msg .= new;
  $msg.msg_controllen = 0;
  $msg.msg_name = $sockaddr.defined ?? +nativecast(Pointer, $sockaddr) !! 0;
  $msg.msg_namelen = $sockaddr.defined ?? $sockaddr.size !! 0;
  $msg.msg_iovlen = 1;
  $msg.msg_iov[0] = +nativecast(Pointer, $blob);
  $msg.msg_iov[1] = $blob.bytes;
  return nativecast(Pointer, $msg);
}

sub cqe-no-error(io_uring_cqe:D $cqe) is error-model<neg-errno> {
  return True if $cqe.res >= 0;
  $cqe.res;
}

my $test-string = "Send me";
my $recv-buffer = blob8.allocate(20);
my $send-sockaddr = sockaddr_un.new("\0/tmp/send.socket");
my $recv-msg = blob-to-msghdr($recv-buffer);

my $send-socket = socket(AF::UNIX, SOCK::DGRAM, 0);
bind($send-socket, $send-sockaddr, $send-sockaddr.size);

my $recv-socket = socket(AF::UNIX, SOCK::DGRAM, 0);

my $recv-sockaddr = sockaddr_un.new("\0/tmp/test.socket");
bind($recv-socket, $recv-sockaddr, $recv-sockaddr.size);
my $send-msg = blob-to-msghdr($test-string.encode, $recv-sockaddr);

my io_uring $ring .= new(:8entries);

my Pointer[io_uring_cqe] $cqe_arr .= new;

my io_uring_sqe $sqe = io_uring_get_sqe($ring);
$sqe.prep-recvmsg($recv-socket, $recv-msg, 0);
$sqe.user_data = 1;
io_uring_submit($ring);

$sqe = io_uring_get_sqe($ring);
$sqe.prep-sendmsg($send-socket, $send-msg, 0);
$sqe.user_data = 2;

io_uring_submit($ring);

for ^2 {
  io_uring_wait_cqe_timeout($ring, $cqe_arr, kernel_timespec);
  my $cqe = $cqe_arr.deref;
  ok $cqe.user_data.defined, "Got user_data back from kernel";
  if $cqe.user_data == 1 {
    # Recvmsg
    cqe-no-error($cqe);
    ok $cqe.res > 0, <Got a message>;
    is $cqe.res, $test-string.encode.bytes, <Received the right number of bytes>;
    ok $recv-buffer.subbuf(^$cqe.res).decode eq $test-string, <Got msg from send socket>;
  }
  elsif $cqe.user_data == 2 {
    # Sendmsg
    cqe-no-error($cqe);
    ok $cqe.res > 0, <Sent a message>;
    is $cqe.res, $test-string.encode.bytes, <Sent the right number of bytes>;
  }
  else {
    flunk "Should not be possible";
  }
  io_uring_cqe_seen($ring, $cqe_arr.deref);
}

done-testing;
