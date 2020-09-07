use v6;
use Test;
use IO::URing::Raw;
use NativeCall;

my io_uring $ring .= new(:4entries);

my Int $num-tests = 3;

my @test-val = (^1000).pick($num-tests);

for @test-val -> $test {

  my $sqe = $ring.get-sqe.prep-nop;
  my Pointer[io_uring_cqe] $cqe_arr .= new;
  $sqe.user_data = $test;
}

$ring.submit-and-wait($num-tests);

my Pointer[io_uring_cqe] $cqe-ptr .= new;

io_uring_peek_batch_cqe($ring, $cqe-ptr, $num-tests);

for @test-val -> $test {
  my $cqe := $cqe-ptr.deref;
  is $cqe.user_data, $test, "Get val {$cqe.user_data} back from kernel";
  $cqe-ptr = $cqe-ptr.succ;
}

$ring.close;

done-testing;
