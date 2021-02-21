use v6;
use Test;
use IO::URing;
use IO::URing::Socket::UNIX;

my $server-socket-string = "\0/tmp/test.socket";

my $test-string = "Send me";

my IO::URing $ring .= new(:128entries);

my $promise = start {
  react {
    whenever IO::URing::Socket::UNIX.listen($server-socket-string, :$ring) -> $conn {
      whenever $conn.Supply.lines -> $line {
        $conn.print: "$line" ~ "\n";
        $conn.close;
        done;
      }
    }
  }
}

sleep 0.1;

await IO::URing::Socket::UNIX.connect($server-socket-string, :$ring).then( -> $promise {
  given $promise.result -> $conn {
    $conn.print($test-string ~ "\n");

    react {
      whenever $conn.Supply.lines -> $v {
        is $v, $test-string;
        done-testing;
        done;
      }
    }
    $conn.close;
  }
});

await $promise;
