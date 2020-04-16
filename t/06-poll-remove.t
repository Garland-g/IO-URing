use v6;
use Test;
use IO::URing;

my IO::URing $ring .= new(:2entries, :0flags);

# Random values to prove that no cheating is happening
my $val = ('A'..'Z').pick(10).join('');
my $data = (^1000).pick;
my $file = open "$?FILE".IO, :r;

my ($wbuf1, $wbuf2, $rbuf1, $rbuf2);

$wbuf1 = $val.encode.subbuf(^5);
$wbuf2 = $val.encode.subbuf(5..^10);

$rbuf1 = blob8.allocate(5);
$rbuf2 = blob8.allocate(5);
react {
  my $handle = $ring.poll-add($file.native-descriptor, POLLOUT, :$data);
  whenever $ring.poll-remove($handle, :$data) -> $cqe {
    is $cqe.data, $data, "Get val {$cqe.data} back from kernel";
    done;
  }
}

$file.close;
unlink($*TMPDIR.add($val).IO);
done-testing;

