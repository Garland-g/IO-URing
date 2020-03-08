use v6;
use Test;
use IO::URing;

my IO::URing $ring .= new(:2entries, :0flags);

# Random values to prove that no cheating is happening
my $val = ('A'..'Z').pick(10).join('');
my $data = (^1000).pick;
my $handle = open $*TMPDIR.add($val).IO, :r, :w;

my ($wbuf1, $wbuf2, $rbuf1, $rbuf2);

$wbuf1 = $val.encode.subbuf(^5);
$wbuf2 = $val.encode.subbuf(5..^10);

$rbuf1 = blob8.allocate(5);
$rbuf2 = blob8.allocate(5);
start {
  $ring.writev($handle, ($wbuf1, $wbuf2), :$data, :chain);
  $ring.fsync($handle, 0, :$data, :chain);
  $ring.readv($handle, ($rbuf1, $rbuf2), :$data);
}

react whenever $ring.Supply -> $cqe {
  is $cqe.data, $data, "Get val {$cqe.data} back from kernel";
  is $rbuf1.decode ~ $rbuf2.decode, $val, "Get temp data back from file";
  done;
}
$handle.close;
unlink($*TMPDIR.add($val).IO);
done-testing;

