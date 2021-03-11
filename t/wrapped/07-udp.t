use v6;
use IO::URing;
use IO::URing::Socket::INET;

use Test;

constant TEST_PORT = 31316;

my $ring = IO::URing.new(:128entries);

my $test-string = "Send me";
my $server = IO::URing::Socket::INET.bind-udp('127.0.0.1', TEST_PORT, :$ring, :reuseaddr);
my $client = IO::URing::Socket::INET.udp(:$ring);

# All testing must be done inside this start block.
my $promise = start react whenever $server.Supply(:datagram) -> $v {
  is $v.data, "Send me", <Got the data from the socket>;
  done-testing;
  done;
}

sleep 0.1;

$client.print-to('127.0.0.1', TEST_PORT, $test-string);

await $promise;
