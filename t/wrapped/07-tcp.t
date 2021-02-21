use v6;
use Test;
use IO::URing;
use IO::URing::Socket::INET;

my $test-string = "Send me";

my IO::URing $ring .= new(:128entries);

constant TEST_PORT = 31316;

my $promise = start {
  react {
    whenever IO::URing::Socket::INET.listen('127.0.0.1', TEST_PORT, :$ring, :reuseaddr) -> $conn {
      whenever $conn.Supply.lines -> $line {
        $conn.print: "$line" ~ "\n";
        $conn.close;
        done;
      }
    }
  }
}

sleep 0.5;

await IO::URing::Socket::INET.connect('127.0.0.1', TEST_PORT, :$ring).then( -> $promise {
  given $promise.result -> $conn {
    $conn.print($test-string ~ "\n");

    react {
      whenever $conn.Supply.lines -> $v {
        is $v, $test-string, <String was sent and received across the socket>;
        done-testing;
        done;
      }
    }
    $conn.close;
  }
});

await $promise;
