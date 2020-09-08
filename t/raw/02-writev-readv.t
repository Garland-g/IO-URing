use v6;
use Test;
use IO::URing::Raw;
use NativeCall;
my io_uring $ring .= new(:2entries);

my $val = ('A'..'Z').pick(10).join('');
my $data = (^1000).pick;
my $handle = open $*TMPDIR.add($val).IO, :r, :w;

my ($wbuf1, $wbuf2, $rbuf1, $rbuf2);

$wbuf1 = $val.encode.subbuf(0..^5);
$wbuf2 = $val.encode.subbuf(5..^10);

$rbuf1 = blob8.allocate(5);
$rbuf2 = blob8.allocate(5);

my io_uring_sqe $sqe := $ring.get-sqe;
my Pointer[io_uring_cqe] $cqe-ptr;
my io_uring_cqe $cqe;

my CArray[size_t] $arr .= new;
$arr[0] = nativecast(Pointer[void], $wbuf1);
$arr[1] = $wbuf1.elems;
$arr[2] = nativecast(Pointer[void], $wbuf2);
$arr[3] = $wbuf2.elems;
$arr[4] = nativecast(Pointer[void], $rbuf1);
$arr[5] = $rbuf1.elems;
$arr[6] = nativecast(Pointer[void], $rbuf2);
$arr[7] = $rbuf2.elems;


$sqe.prep-writev($handle.native-descriptor, nativecast(Pointer[size_t], $arr), 2, 0);
$sqe.user_data = $data;

$ring.submit;

$cqe-ptr := $ring.wait;
$cqe := $cqe-ptr.deref;

is $cqe.user_data, $data, "Get val {$cqe.user_data} back from kernel";
is $handle.lines[0], $val, "Wrote temp data to file";

$sqe := $ring.get-sqe;
$sqe.prep-readv($handle.native-descriptor, nativecast(Pointer[size_t], $arr).add(2 * 2), 2, 0);
$sqe.user_data = $data;

$ring.submit;

$cqe-ptr := $ring.wait;
$cqe := $cqe-ptr.deref;
is $cqe.user_data, $data, "Get val {$cqe.user_data} back from kernel";
is $rbuf1.decode ~ $rbuf2.decode, $val, "Get temp data back from file";

$handle.close;
unlink($*TMPDIR.add($val).IO);
done-testing;
