use v6;
use Test;
use IO::URing;

my IO::URing $ring .= new(:4entries, :0flags);

# Random values to prove that no cheating is happening
my $val = ('A'..'Z').pick(10).join('');
my @data = (^1000).pick(4);

my $handle = open $*TMPDIR.add($val).IO, :r, :w;

my ($wbuf1, $wbuf2, $rbuf1, $rbuf2);

$wbuf1 = $val.encode.subbuf(^5);
$wbuf2 = $val.encode.subbuf(5..^10);

$rbuf1 = blob8.allocate(5);
$rbuf2 = blob8.allocate(5);
my @handles =
  $ring.prep-writev($handle, ($wbuf1, $wbuf2), :data(@data[0]), :link),
  $ring.prep-fsync($handle, 0, :data(@data[1]), :link),
  $ring.prep-poll-add($handle, POLLIN, :data(@data[2]), :link);
$ring.submit();
await Promise.allof(@handles);
react whenever $ring.readv($handle, ($rbuf1, $rbuf2), :data(@data[3])) -> $cqe {
  is $cqe.data, @data[3], "Get val {@data[3]} back from kernel";
  is $rbuf1.decode ~ $rbuf2.decode, $val, "Get temp data back from file";
  done;
}
$handle.close;
unlink($*TMPDIR.add($val).IO);
done-testing;

