=begin pod

=head1 NAME

IO::URing::Socket - A socket interface on top of IO::URing.

=head1 SYNOPSIS

Sample INET Socket usage

=begin code :lang<raku>

# Server
use IO::URing::Socket::INET;

react {
  whenever IO::URing::Socket::INET.listen('127.0.0.1', 3333, :reuseaddr, :reuseport) -> $conn {
    whenever $conn.Supply.lines -> $line {
      $conn.print: "$line" ~ "\n";
      $conn.close;
    }
  }
  CATCH {
    default {
      say .^name, ': ', .Str;
      say "handled in $?LINE";
    }
  }
}

# Client

use IO::URing::Socket::INET;

await IO::URing::Socket::INET.connect('127.0.0.1', 3333).then( -> $promise {
  given $promise.result -> $conn {

    $conn.print("Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n");
    react {
      whenever $conn.Supply().lines -> $v {
        $v.say;
        done;
      }
    }
    $conn.close;
  }
});

=end code

=head1 DESCRIPTION

IO::URing::Socket is a role that contains code common to all IO::URing sockets.
It implements the same interface as IO::Socket::Async.

Any method that creates a socket (connect, listen, dgram, bind-dgram, udp, bind-udp) can be passed its own
IO::URing object. The caller is responsible for closing any IO::URing objects passed into socket creation methods.

=head2 IO::URing::Socket methods

=end pod


use IO::URing;
use IO::URing::Socket::Raw :ALL;
use Universal::errno;
use Net::IP :ip-get-version;
$Net::IP::DEBUG = False;
use NativeCall;

use Constants::Sys::Socket :ALL;
use Constants::Netinet::In :ALL;

role IO::URing::Socket is export {
  has $!socket;
  has int $!dgram;
  has $!datagram;
  has $.enc;
  has $!encoder;
  has $!close-promise;
  has $!close-vow;
  has $!ring;
  has $!domain;
  has $!ipproto;
  has $!managed = 1;

  method new() {
    die "Cannot directly instantiate an IO::URing::Socket. Please use\n" ~
        "a socket class that implements IO::URing::Socket instead."
  }

  #| Send a Str over the socket connection
  method print(IO::URing::Socket:D: Str(Cool) $str) {
    self.write($!encoder.encode-chars($str));
  }

  #| Send a Blob over the socket connection
  method write(IO::URing::Socket:D: Blob:D $buf) {
    my $p := Promise.new;
    my $v := $p.vow;
    $!ring.send($!socket, $buf).then: -> $cmp {
      if $cmp.result.result < 0 {
        $v.break(strerror(-$cmp.result.result));
      }
      else {
        $v.keep($cmp.result.result);
      }
    };
    $p;
  }

  my class SocketReaderTappable does Tappable {
    has $!socket;
    has $!scheduler;
    has $!ring;
    has $!close-promise;
    has $!close-vow;
    has $!dgram;
    has $!datagram;
    has $!buf;
    has $!domain;

    method new(sockfd :$socket!, :$scheduler!, IO::URing :$ring!, :$close-promise!, :$dgram!, :$datagram!, :$domain!) {
      self.CREATE!SET-SELF($socket, $ring, $scheduler, $close-promise, $dgram, $datagram, $domain)
    }

    method !SET-SELF(sockfd $!socket, $!ring, $!scheduler, $!close-promise, $!dgram, $!datagram, $!domain) { self }

    method tap(&emit, &done, &quit, &tap) {
      my $buffer := buf8.allocate(1024 * 60, 0); # Size of largest UDP packet
      my $sockaddr; # Size of largest sockaddr
      $sockaddr := buf8.allocate(nativesizeof(sockaddr_un)) if $!dgram;
      my int $buffer-start-seq = 0;
      my int $done-target = -1;
      my int $finished = 0;

      my $lock = Lock::Async.new;
      my $tap;
      my $handle;
      my $cancellation;
      my int $count = 0;
      $lock.protect: {
        $cancellation := $!scheduler.cue: -> {
          if $!dgram {
            # UDP
            loop {
              $handle = $!ring.recvfrom($!socket, $buffer, 0, $sockaddr).then: -> $cmp {
                $lock.protect: {
                  unless $finished {
                    if $cmp ~~ Exception {
                      quit(X::AdHoc.new(payload => strerror($cmp)));
                      $finished = 1;
                    }
                    elsif $cmp.result.result > 0 {
                      my \bytes = $cmp.result.result;
                      Any ~~ $!datagram
                        ?? emit($buffer.subbuf(^bytes))
                        !! emit($!datagram.new(:data($buffer.subbuf(^bytes)), :$sockaddr, :$!domain));
                    }
                    else {
                    }
                  }
                }
              };
              await $handle;
            }
          }
          else {
            #TCP
            $handle = $!ring.recv($!socket, $buffer);
            await $handle.then: -> $cmp {
              $lock.protect: {
                unless $finished {
                  if $cmp ~~ Exception {
                    quit(x::AdHoc.new(payload => strerror(-$cmp.result.result)));
                    $finished = 1;
                  }
                  else {
                    my \bytes := $cmp.result.result;
                    if bytes > 0 {
                      emit($buffer.subbuf(^bytes));
                    }
                    else {
                      $finished = 1;
                      done();
                    }
                  }
                }
              }
            }
            my $result = await $handle;
          }
        }
        $tap := Tap.new({ $cancellation.cancel(); });
        tap($tap);
      }
      $!close-promise.then: {
        $lock.protect: {
          unless $finished {
            done();
            $finished = 1;
          }
        }
      }
    }

    method live(--> False) {}
    method sane(--> True) {}
    method serial(--> True) {}
  }

  #| Get a Supply for the socket. Will emit values whenever a message is received.
  method Supply(IO::URing::Socket:D: :$bin, :$datagram, :$enc = 'utf-8', :$scheduler = $*SCHEDULER) {
    my $dgram = $datagram ?? $!datagram !! Any;
    if $bin {
      Supply.new: SocketReaderTappable.new:
        :$!socket, :$!ring, :$scheduler, :$!close-promise, :$!dgram, :datagram($dgram), :$!domain;
    }
    else {
      my $bin-supply = self.Supply(:bin, :$datagram, :$!domain);
      if $!dgram {
        supply {
          whenever $bin-supply {
            emit .decode($enc // $!socket.enc);
          }
        }
      }
      else {
        Rakudo::Internals.BYTE_SUPPLY_DECODER($bin-supply, $enc // $!socket.enc)
      }
    }
  }

  #| Close the socket.
  method close(IO::URing::Socket:D: --> True) {
    $!ring.close-fd($!socket) unless $!dgram;
    # Close the ring if it was created by the library
    $!ring.close if $!managed;
    try $!close-vow.keep(True);
  }

  #| Connect this socket to a peer.
  #| See specific socket type for details.
  method connect(IO::URing::Socket:U: Str $host, |c) { ... }

  #| Get the underlying descriptor for the socket.
  method native-descriptor(--> Int) {
    $!socket;
  }

  sub setup-close(\socket --> Nil) {
    use nqp;
    my $p := Promise.new;
    nqp::bindattr(socket, IO::URing::Socket, '$!close-promise', $p);
    nqp::bindattr(socket, IO::URing::Socket, '$!close-vow', $p.vow);
  }

  #| Listen for incoming connections.
  #| See specific socket type for details.
  method listen(IO::URing::Socket:U: Str $host, $port?, |c) { ... }

  #| Send a Str on a dgram socket.
  #| See specific socket type for details.
  method print-to() { ... }

  #| Send a Blob on a dgram socket.
  #| See specific socket type for details.
  method write-to() { ... }

#################################################
#                SOL_SOCKET LEVEL               #
#################################################

  method !reuseaddr(IO::URing::Socket:D: Bool $reuseaddr --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, $reuseaddr ?? 1 !! 0);
    setsockopt(
      $!socket,
      SOL::SOCKET,
      SO::REUSEADDR,
      nativecast(Pointer[void], $opt),
      nativesizeof(uint32)
    )
  }

  #| Get the current value of SO_REUSEADDR.
  #| SO_REUSEADDR allows re-binding to the socket without
  #| waiting for the TIME_WAIT period.
  method reuseaddr(IO::URing::Socket:D: --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::REUSEADDR,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-uint32(0).Bool;
  }

  method !reuseport(IO::URing::Socket:D: Bool $reuseport --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, $reuseport ?? 1 !! 0);
    setsockopt(
      $!socket,
      SOL::SOCKET,
      SO::REUSEPORT,
      nativecast(Pointer[void], $opt),
      nativesizeof(uint32)
    )
  }

  #| Get the current value of SO_REUSEPORT.
  #| SO_REUSEPORT allows multiple sockets to bind to the same port.
  method reuseport(IO::URing::Socket:D: --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::REUSEPORT,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-uint32(0).Bool;
  }

  #| Get the current value of SO_ACCEPTCONN.
  #| SO_ACCEPTCONN returns true if the socket is listening.
  method acceptconn(IO::URing::Socket:D: --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::ACCEPTCONN,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-uint32(0).Bool;
  }

 method !bindtodevice(IO::URing::Socket:D: Str $device where .chars < 16 --> Bool(Int)) {
    return Bool unless $!domain ~~ AF::INET | AF::INET6;
    my $opt = $device.encode('ascii');
    setsockopt(
      $!socket,
      SOL::SOCKET,
      SO::BINDTODEVICE,
      nativecast(Pointer[void], $opt),
      $opt.bytes
    )
  }

  #| Get the current device that the socket is bound to.
  #| SO_BINDTODEVICE only allows the socket to communicate over
  #| the named device.
  multi method bindtodevice(IO::URing::Socket:D: --> Str) {
    my buf8 $opt .= allocate(16);
    my buf8 $len .= new;
    $len.write-uint32(0, 16);
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::BINDTODEVICE,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.subbuf(0..$len.read-uint32(0)).decode('ascii')
  }

  method !broadcast(IO::URing::Socket:D: Bool $broadcast --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, $broadcast ?? 1 !! 0);
    setsockopt(
      $!socket,
      SOL::SOCKET,
      SO::BROADCAST,
      nativecast(Pointer[void], $opt),
      nativesizeof(uint32)
    );
  }

  #| Get the current value of SO_BROADCAST on the socket.
  #| SO_BROADCAST determines whether or not the socket can
  #| send messages to the broadcast address.
  multi method broadcast(IO::URing::Socket:D: --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::BROADCAST,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-uint32(0).Bool;
  }

  #| Get the domain of the socket.
  method domain(IO::URing::Socket:D: --> AF) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::DOMAIN,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    AF($opt.read-uint32(0));
  }

  #| Get the protocol of the socket.
  method protocol(IO::URing::Socket:D: --> IPPROTO) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::PROTOCOL,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    IPPROTO($opt.read-uint32(0));
  }

  method !dontroute(IO::URing::Socket:D: Bool $dontroute --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, $dontroute ?? 1 !! 0);
    setsockopt(
      $!socket,
      SOL::SOCKET,
      SO::BROADCAST,
      nativecast(Pointer[void], $opt),
      nativesizeof(uint32)
    )
  }

  #| Get the current value of SO_DONTROUTE.
  #| SO_DONTROUTE determines whether or not to bypass the routing
  #| table and send messages to the network interface directly.
  method dontroute(IO::URing::Socket:D: --> Bool(Int)) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      SOL::SOCKET,
      SO::DONTROUTE,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-uint32(0).Bool;
  }
}

=begin pod

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
