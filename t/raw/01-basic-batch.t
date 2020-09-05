use v6;
use Test;
use IO::URing::Raw;
use NativeCall;

my io_uring $ring .= new(:4entries);

my $num-tests = 3;

my @test-val = (^1000).pick($num-tests);

for @test-val -> $test {

  my $sqe = $ring.get-sqe.prep_nop;
  my Pointer[io_uring_cqe] $cqe_arr .= new;
  $sqe.user_data = $test;
}

io_uring
