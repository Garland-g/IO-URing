use v6;
use Test;
use IO::URing;

my IO::URing $ring .= new(:4entries, :0flags);

# Random values to prove that no cheating is happening
my $val = ('A'..'Z').pick(10).join('');
my $data = (^1000).pick;
my $handle = open $*TMPDIR.add($val).IO, :r, :w;

my ($wbuf1, $wbuf2, $rbuf1, $rbuf2);

$wbuf1 = $val.encode.subbuf(^5);
$wbuf2 = $val.encode.subbuf(5..^10);

$rbuf1 = blob8.allocate(5);
$rbuf2 = blob8.allocate(5);

my @promises =
  $ring.prep-writev($handle, ($wbuf1, $wbuf2), :$data, :link),
  $ring.prep-fsync($handle, 0, :$data, :link),
  $ring.prep-readv($handle, ($rbuf1, $rbuf2), :$data);
$ring.submit();
my $write = await @promises[0];
my $sync = await @promises[1];
my $read = await @promises[2];
is $read.data, $data, "Get val {$read.data} back from kernel";
is $rbuf1.decode ~ $rbuf2.decode, $val, "Get temp data back from file";

$handle.close;
unlink($*TMPDIR.add($val).IO);
done-testing;

