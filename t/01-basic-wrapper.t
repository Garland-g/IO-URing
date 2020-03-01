use v6;
use Test;
use io_uring;

my io-uring $ring .= new(:2entries, :0flags);

# Random values to prove that no cheating is happening
my @test-val = (^1000).pick(3);

start {
  sleep 0.05;
  for @test-val -> $val {
    $ring.nop($val);
  }
}

my $count = 0;

react {
  whenever $ring.Supply -> $cqe {
    is $cqe.user_data, @test-val[$count], "Get val {$cqe.user_data} back from kernel";

    $count++;
    done if $count == @test-val.elems;
  }
}


done-testing;
