use v6;
use Test;
use IO::URing;
use IO::URing::Socket::Raw :ALL;
use Constants::Sys::Socket :ALL;

my IO::URing $ring .= new(:2entries, :0flags);

# Random values to prove that no cheating is happening
my $val = ('A'..'Z').pick(10).join('');
my $data = (^1000).pick;

my $socket = socket(AF::UNIX, SOCK::STREAM, 0);
my $addr = sockaddr_un.new($*TMPDIR.add($val).Str);
bind($socket, $addr.sockaddr, $addr.size);
listen($socket, 20);
plan 1;
react {
  my $handle = $ring.poll-add($socket, POLLOUT, :$data);
  whenever $ring.poll-remove($handle, :$data) -> $cqe {
  CATCH {
    default { close($socket); $ring.close; die .payload }
  }
    is $cqe.data, $data, "Get val {$cqe.data} back from kernel";
    done;
  }
}
close($socket);
$ring.close;
done-testing;

