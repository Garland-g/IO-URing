use v6;
use Test;
use IO::URing;

my IO::URing $ring .= new(:2entries, :0flags);

# Random values to prove that no cheating is happening
my @test-val = (^1000).pick(3);
my @promises;

for @test-val -> $val {
  @promises.push($ring.nop(:data($val)));
}
my @results = await Promise.allof(@promises);

for @promises>>.result Z @test-val -> ($val, $test-val) {
  is $val.data, $test-val, "Get val {$val.data} back from kernel";
}


done-testing;
