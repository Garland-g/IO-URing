use v6;
use Test;
use IO::URing::Raw;
use NativeCall;

my io_uring $ring .= new;

# Random values to prove that no cheating is happening
my @test-val = (^1000).pick(3);

io_uring_queue_init(2, $ring, 0);

for @test-val -> $test {

  my io_uring_sqe $sqe = io_uring_get_sqe($ring);
  my Pointer[io_uring_cqe] $cqe_arr .= new;
  io_uring_prep_nop($sqe, $test);
  io_uring_submit($ring);

  io_uring_wait_cqe_timeout($ring, $cqe_arr, kernel_timespec);
  is $cqe_arr.deref.user_data, $test, "Got user_data $test back from kernel";
  io_uring_cqe_seen($ring, $cqe_arr.deref);
}

io_uring_queue_exit($ring);

done-testing;
