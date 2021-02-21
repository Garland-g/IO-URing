use v6;
use IO::URing;
use IO::URing::Socket::UNIX;

use Test;

my $ring = IO::URing.new(:128entries);

my $test-string = "Send me";
my $server-string = "\0/tmp/test.socket";
my $client-string = "\0/tmp/send.socket";
my $server = IO::URing::Socket::UNIX.bind-dgram($server-string, :$ring);
my $client = IO::URing::Socket::UNIX.bind-dgram($client-string, :$ring);

# All testing must be done inside this start block.
my $promise = start react whenever $server.Supply(:datagram) -> $v {
  is $v.data, "Send me", <Got the data from the socket>;
  done-testing;
  done;
}

$client.print-to($server-string, $test-string);

await $promise;
