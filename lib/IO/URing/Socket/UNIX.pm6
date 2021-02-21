use IO::URing;
use IO::URing::Socket;
use IO::URing::Socket::Raw :ALL;
use Universal::errno;
use NativeCall;
use Constants::Sys::Socket :ALL;
use Constants::Netinet::In;
use nqp;

=begin pod

=head1 NAME

IO::URing::Socket::UNIX - A UNIX-specific socket class on top of IO::URing::Socket

=head1 SYNOPSIS

Sample UNIX Socket usage

=begin code :lang<raku>

# Server
use IO::URing::Socket::UNIX;

react {
  whenever IO::URing::Socket::UNIX.listen("\0/tmp/test.socket") -> $conn {
    whenever $conn.Supply.lines -> $line {
      $conn.print("$line\n");
      $conn.close;
    }
  }
  CATCH {
    default {
      say .^name, ': ', .Str;
      say "handled in $?LINE";
    }
  }
  whenever signal(SIGINT) {
    done;
  }
}


# Client
use IO::URing::Socket::UNIX;
await IO::URing::Socket::UNIX.connect("\0/tmp/test.socket").then( -> $promise {
  given $promise.result -> $conn {
    $conn.print("Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n");

    react whenever $conn.Supply.lines -> $v {
      $v.say;
      done;
    }
    $conn.close;
  }
});

=end code

=head1 DESCRIPTION

IO::URing::Socket::UNIX is a UNIX socket implementation that uses a similar interface to IO::Socket::Async.
It does the IO::URing::Socket role.

=head2 IO::URing::Socket::UNIX methods

=end pod

class IO::URing::Socket::UNIX does IO::URing::Socket is export {

  method new() {
    die "Cannot directly instantiate an IO::URing::Socket::UNIX. Please use\n" ~
        "IO::URing::Socket::UNIX.connect, IO::URing::Socket::UNIX.listen,\n" ~
        "IO::URing::Socket::UNIX.dgram, or IO::URing::Socket;:UNIX.bind-dgram.";
  }

  my class UNIX-Datagram {
    has str $.host;
    has $.data;

    method new(:$data, :$sockaddr) {
      my $addr = nativecast(sockaddr_un, $sockaddr);
      self.bless(:$data, :host($addr.Str));
    }

    method decode(|c) {
      $!data ~~ Str
              ?? X::AdHoc.new(payload => "Cannot decode a datagram with Str data").throw
              !! self.clone(data => $!data.decode(|c));
    }

    method encode(|c) {
      $!data ~~ Blob
              ?? X::AdHoc.new(payload => "Cannot encode a datagram with Blob data").throw
              !! self.clone(data => $!data.encode(|c));
    }
  }

  has Str $!peer-host;
  has Str $!socket-host;

  #| Get the host of the local socket.
  method socket-host(--> Str) {
    $!socket-host //= do {
      my int32 $len = sockaddr_un.size;
      my sockaddr_un $sockaddr = nativecast(sockaddr_un, blob8.allocate($len, 0));
      getsockname($!socket, $sockaddr, $len);
      $sockaddr.addr.Str;
    }
  }

  #| Get the host of the peer socket.
  method peer-host(--> Str) {
    $!peer-host //= do {
      my int32 $len = sockaddr_un.size;
      my sockaddr_un $sockaddr = nativecast(sockaddr_un, blob8.allocate($len, 0));
      getpeername($!socket, $sockaddr, $len);
      $sockaddr.addr.Str;
    }
  }

  #| Connect to an AF_UNIX socket.
  method connect(IO::URing::Socket::UNIX:U: Str $address, :$enc = 'utf-8', IO::URing:D :$ring = IO::URing.new(:128entries)) {
    my $p = Promise.new;
    my $v = $p.vow;
    my $encoding = Encoding::Registry.find($enc);
    my $domain = AF::UNIX;
    my $socket = socket($domain, SOCK::STREAM, 0);
    my $addr = sockaddr_un.new($address);
    $ring.connect($socket, $addr).then: -> $cmp {
      use nqp;
      my $client_socket := nqp::create(self);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!socket', $socket);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!ring', $ring);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!enc', $encoding.name);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!encoder', $encoding.encoder());
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!domain', $domain);
      setup-close($client_socket);
      $v.keep($client_socket);
    };
    return $p;
  }

  #| Get a native descriptor for the socket suitable for use with setsockopt.
  method native-descriptor(--> Int) {
    $!socket;
  }

  sub setup-close(\socket --> Nil) {
    use nqp;
    my $p := Promise.new;
    nqp::bindattr(socket, IO::URing::Socket::UNIX, '$!close-promise', $p);
    nqp::bindattr(socket, IO::URing::Socket::UNIX, '$!close-vow', $p.vow);
  }

  class ListenSocket is Tap {
    has Promise $!socket-tobe;
    has Promise $.socket-host;

    submethod TWEAK(Promise :$!socket-tobe, Promise :$!socket-host) {}

    method new(&on-close, Promise :$socket-tobe, Promise :$socket-host) {
      self.bless(:&on-close, :$socket-tobe, :$socket-host);
    }

    method native-descriptor(--> Int) {
      await $!socket-tobe;
    }
  }

  my class SocketListenerTappable does Tappable {
    has $!host;
    has $!backlog;
    has $!encoding;
    has $!scheduler;
    has $!ring;

    method new(:$host!, :$backlog!, :$encoding!, :$scheduler!, :$ring!) {
      self.CREATE!SET-SELF($host, $backlog, $encoding, $scheduler, $ring)
    }

    method !SET-SELF($!host, $!backlog, $!encoding, $!scheduler, $!ring) { self }

    method tap(&emit, &done, &quit, &tap) {
      my $lock := Lock::Async.new;
      my $tap;
      my int $finished = 0;
      my Promise $socket-tobe .= new;
      my Promise $socket-host .= new;
      my $socket-vow = $socket-tobe.vow;
      my $host-vow = $socket-host.vow;
      my $socket = socket(AF::UNIX, SOCK::STREAM, 0);
      my $addr = sockaddr_un.new($!host);
      my $ret = bind($socket, $addr, $addr.size);
      listen($socket, $!backlog);
      $socket-vow.keep($socket);
      $host-vow.keep(~$!host);
      $lock.protect: {
        my $cancellation := $!scheduler.cue: -> {
          loop {
            my $handle = $!ring.accept($socket);
            $handle.then: -> $cmp {
              if $finished {
                # do nothing
              }
              elsif $cmp.status ~~ Broken {
                $host-vow.break($cmp.cause) unless $host-vow.promise;
                $finished = 1;
                quit($cmp.cause);
              }
              else {
                my \fd = $cmp.result.result;
                my $client_socket := nqp::create(IO::URing::Socket::UNIX);
                nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!socket', fd);
                nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!ring', IO::URing.new(:16entries));
                nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!enc',
                        $!encoding.name);
                nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!encoder',
                        $!encoding.encoder());
                nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!domain', AF::UNIX);
                setup-close($client_socket);
                emit($client_socket);
              }
            };
            await $handle;
            last if $finished;
          }
        };
        $tap = ListenSocket.new: {
          my $p = Promise.new;
          my $v = $p.vow;
          $cancellation.cancel();
          $!scheduler.cue({ $v.keep(True) });
          $p
        }, :$socket-tobe, :$socket-host;
        tap($tap);
        CATCH {
          default {
            tap($tap = ListenSocket.new({ Nil },
                    :$socket-tobe, :$socket-host)) unless $tap;
            quit($_);
          }
        }
      }
      $tap
    }

    method live(--> False) { }
    method sane(--> True) { }
    method serial(--> True) { }
  }

  #| Listen for incoming connections.
  method listen(IO::URing::Socket::UNIX:U: Str $host, Int() $backlog = 128,
          :$enc = 'utf-8', :$scheduler = $*SCHEDULER, IO::URing:D :$ring = IO::URing.new(:128entries)) {
    my $domain = AF::UNIX;
    my $encoding = Encoding::Registry.find($enc);
    Supply.new: SocketListenerTappable.new:
            :$host, :$ring, :$backlog, :$encoding, :$scheduler
  }

  #| Set up a socket to send datagrams.
  method dgram(IO::URing::Socket::UNIX:U: :$enc = 'utf-8', :$scheduler = $*SCHEDULER,
                    :$ring = IO::URing.new(:128entries)) {
    my $p = Promise.new;
    $scheduler.cue: -> {
      my $socket = socket(AF::UNIX, SOCK::DGRAM, 0);
      my $encoding = Encoding::Registry.find($enc);
      my $client_socket := nqp::create(self);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!socket', $socket);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!domain', AF::UNIX);
      nqp::bindattr_i($client_socket, IO::URing::Socket::UNIX, '$!dgram', 1);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!datagram', UNIX-Datagram);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!ring', $ring);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!enc', $encoding.name);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!encoder',
              $encoding.encoder());
      setup-close($client_socket);
      $p.keep($client_socket);
    };
    await $p;
  }

  #| Set up a socket to listen for datagrams
  method bind-dgram(IO::URing::Socket::UNIX:U: Str() $host, :$enc = 'utf-8', :$scheduler = $*SCHEDULER,
                    IO::URing:D :$ring = IO::URing.new(:128entries)) {
    my $p = Promise.new;
    $scheduler.cue: -> {
      my $socket = socket(AF::UNIX, SOCK::DGRAM, 0);
      my $encoding = Encoding::Registry.find($enc);
      my $client_socket := nqp::create(self);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!socket', $socket);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!domain', AF::UNIX);
      nqp::bindattr_i($client_socket, IO::URing::Socket::UNIX, '$!dgram', 1);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!datagram', UNIX-Datagram);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!ring', $ring);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!enc', $encoding.name);
      nqp::bindattr($client_socket, IO::URing::Socket::UNIX, '$!encoder',
              $encoding.encoder());
      setup-close($client_socket);
      my $addr = sockaddr_un.new($host);
      bind($socket, $addr, $addr.size);
      $p.keep($client_socket);
    }
    await $p
  }

  #| Send a Str to a remote socket in a datagram.
  method print-to(IO::URing::Socket::UNIX:D: Str() $host, Str() $str, :$scheduler = $*SCHEDULER) {
    self.write-to($host, $!encoder.encode-chars($str), :$scheduler)
  }

  #| Send a Blob to a remote socket in a datagram.
  method write-to(IO::URing::Socket::UNIX:D: Str() $host, Blob $b, :$scheduler = $*SCHEDULER) {
    my $p = Promise.new;
    my $v = $p.vow;
    my sockaddr_un $addr .= new($host);
    $!ring.sendto($!socket, $b, 0, $addr, sockaddr_un.size).then: -> $cmp {
      if $cmp ~~ Exception {
        $v.break(strerror($cmp));
      }
      else {
        $v.keep($cmp.result.result);
      }
    };
    $p;
  }
}

=begin pod

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
