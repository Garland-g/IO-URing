use v6;
use Test;
use IO::URing;

my IO::URing $ring .= new(:4entries, :0flags);

# Random values to prove that no cheating is happening
my @test-val = (^1000).pick(3);

my @submissions;
for @test-val -> $val {
  @submissions.push: $ring.prep-nop(:data($val));
}

my @handles = $ring.submit(@submissions);

my $count = 0;

await Promise.allof(@handles);

for @handles>>.result -> $compl {
  is $compl.data, @test-val[$count++], "Get val {$compl.data} back from kernel";
}


done-testing;
