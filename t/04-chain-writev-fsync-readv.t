use v6;
use Test;
use IO::URing;

plan 2;

unless Version.new($*KERNEL.release) ~~ v5.3+ {
  skip-rest "Cannot test on Linux 5.2 or lower";
  exit;
}

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
$ring.writev($handle, ($wbuf1, $wbuf2), :$data, :link);
$ring.fsync($handle, 0, :$data, :link);
react whenever $ring.readv($handle, ($rbuf1, $rbuf2), :$data) -> $cqe {
  is $cqe.data, $data, "Get val {$cqe.data} back from kernel";
  is $rbuf1.decode ~ $rbuf2.decode, $val, "Get temp data back from file";
  done;
}
$handle.close;
unlink($*TMPDIR.add($val).IO);
done-testing;

