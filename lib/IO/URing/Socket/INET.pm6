use IO::URing;
use IO::URing::Socket;
use IO::URing::Socket::Raw :ALL;
use Universal::errno;
use NativeCall;
use Constants::Sys::Socket :ALL;
use Constants::Netinet::In;
use nqp;

class IO::URing::Socket::INET does IO::URing::Socket is export {

  has Str $!peer-host;
  has Str $!socket-host;
  has Int $!peer-port;
  has Int $!socket-port;

  method socket-host(--> Str) {
    $!socket-host //= do {
      my int32 $len = sockaddr_in.size;
      my sockaddr_in $sockaddr = nativecast(sockaddr_in, blob8.allocate($len, 0));
      getsockname($!socket, $sockaddr, $len);
      $!socket-port //= $sockaddr.port;
      $sockaddr.addr.Str;
    }
  }
  method socket-port(--> Int) {
    $!socket-port //= do {
      my int32 $len = sockaddr_in.size;
      my sockaddr_in $sockaddr = nativecast(sockaddr_in, blob8.allocate($len, 0));
      getsockname($!socket, $sockaddr, $len);
      $!socket-host //= $sockaddr.addr.Str;
      $sockaddr.port;
    }
  }
  method peer-host(--> Str) {
    $!peer-host //= do {
      my int32 $len = sockaddr_in.size;
      my sockaddr_in $sockaddr = nativecast(sockaddr_in, blob8.allocate($len, 0));
      getpeername($!socket, $sockaddr, $len);
      $!peer-port //= $sockaddr.port;
      $sockaddr.addr.Str;
    }
   }
  method peer-port(--> Int) {
    $!peer-port //= do {
      my int32 $len = sockaddr_in.size;
      my sockaddr_in $sockaddr = nativecast(sockaddr_in, blob8.allocate($len, 0));
      getpeername($!socket, $sockaddr, $len);
      $!peer-host //= $sockaddr.addr.Str;
      $sockaddr.port;
    }
  }

  method connect(IO::URing::Socket::INET:U: Str $address, Int $port where IO::Socket::Async::Port-Number, :$enc = 'utf-8') {
    my $p = Promise.new;
    my $v = $p.vow;
    my $ring = IO::URing.new(:4entries);
    my $encoding = Encoding::Registry.find($enc);
    my $socket = socket(AF::INET, SOCK::STREAM, 0);
    my $addr = sockaddr_in.new($address, $port);
    $ring.connect($socket, $addr).then: -> $cmp {
      use nqp;
      my $client_socket := nqp::create(self);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!socket', $socket);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!ring', $ring);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!enc', $encoding.name);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!encoder', $encoding.encoder());
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!domain', AF::INET);
      setup-close($client_socket);
      $v.keep($client_socket);
    };
    return $p;
  }

  method native-descriptor(--> Int) {
    $!socket;
  }

  sub setup-close(\socket --> Nil) {
    use nqp;
    my $p := Promise.new;
    nqp::bindattr(socket, IO::URing::Socket::INET, '$!close-promise', $p);
    nqp::bindattr(socket, IO::URing::Socket::INET, '$!close-vow', $p.vow);
  }

  class ListenSocket is Tap {
    has Promise $!socket-tobe;
    has Promise $.socket-host;
    has Promise $.socket-port;

    submethod TWEAK(Promise :$!socket-tobe, Promise :$!socket-host, Promise :$!socket-port) {}

    method new(&on-close, Promise :$socket-tobe, Promise :$socket-host, Promise :$socket-port) {
      self.bless(:&on-close, :$socket-tobe, :$socket-host, :$socket-port);
    }

    method native-descriptor(--> Int) {
      await $!socket-tobe;
    }
  }

  my class SocketListenerTappable does Tappable {
    has $!host;
    has $!port;
    has $!backlog;
    has $!encoding;
    has $!scheduler;
    has $!reuseport;
    has $!reuseaddr;
    has $!ring;

    method new(:$host!, :$port!, :$backlog!, :$encoding!, :$scheduler!, :$ring!, :$reuseaddr, :$reuseport) {
      self.CREATE!SET-SELF($host, $port, $backlog, $encoding, $scheduler, $ring, $reuseaddr, $reuseport)
    }

    method !SET-SELF($!host, $!port, $!backlog, $!encoding, $!scheduler, $!ring, $!reuseaddr?, $!reuseport?) { self }

    my sub reuseaddr($socket, $reuseaddr) {
      my buf8 $opt .= new;
      $opt.write-uint32(0, $reuseaddr ?? 1 !! 0);
      setsockopt(
              $socket,
              SOL::SOCKET,
              SO::REUSEADDR,
              nativecast(Pointer[void], $opt),
              nativesizeof(uint32)
              )
    }

    my sub reuseport($socket, $reuseport) {
      my buf8 $opt .= new;
      $opt.write-uint32(0, $reuseport ?? 1 !! 0);
      setsockopt(
              $socket,
              SOL::SOCKET,
              SO::REUSEPORT,
              nativecast(Pointer[void], $opt),
              nativesizeof(uint32)
              )
    }

    method tap(&emit, &done, &quit, &tap) {
      my $lock := Lock::Async.new;
      my $tap;
      my int $finished = 0;
      my Promise $socket-tobe .= new;
      my Promise $socket-host .= new;
      my Promise $socket-port .= new;
      my $socket-vow = $socket-tobe.vow;
      my $host-vow = $socket-host.vow;
      my $port-vow = $socket-port.vow;
      my $socket = socket(AF::INET, SOCK::STREAM, 0);
      reuseaddr($socket, $!reuseaddr) if $!reuseaddr;
      reuseport($socket, $!reuseport) if $!reuseport;
      my $addr = sockaddr_in.new(:addr($!host), :$!port);
      bind($socket, $addr, $addr.size);
      listen($socket, $!backlog);
      $socket-vow.keep($socket);
      $host-vow.keep(~$!host);
      $port-vow.keep(+$!port);
      $lock.protect: {
        my $cancellation := $!scheduler.cue: -> {
          loop {
            my $handle = $!ring.accept($socket);
            await $handle.then: -> $cmp {
              if $finished {
                # do nothing
              }
              elsif $cmp ~~ Exception {
                my $exc = X::AdHoc.new(payload => strerror($cmp));
                quit($exc);
                $host-vow.break($exc) unless $host-vow.promise;
                $port-vow.break($exc) unless $port-vow.promise;
                $finished = 1;
              }
              else {
                my \fd = $cmp.result.result;
                my $client_socket := nqp::create(IO::URing::Socket::INET);
                nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!socket', fd);
                nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!ring',
                        IO::URing.new(:4entries));
                nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!enc',
                        $!encoding.name);
                nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!encoder',
                        $!encoding.encoder());
                nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!domain', AF::INET);
                setup-close($client_socket);
                emit($client_socket);
              }
            };
            last if $finished;
          }
        };
        $tap = ListenSocket.new: {
          my $p = Promise.new;
          my $v = $p.vow;
          $cancellation.cancel();
          $v.keep(True);
          $p
        }, :$socket-tobe, :$socket-host, :$socket-port;
        tap($tap);
        CATCH {
          default {
            tap($tap = ListenSocket.new({ Nil },
                :$socket-tobe, :$socket-host, :$socket-port)) unless $tap;
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

  method listen(IO::URing::Socket::INET:U: Str $host, Int $port where IO::Socket::Async::Port-Number,
                Int() $backlog = 128, :REUSEADDR(:$reuseaddr), :REUSEPORT(:$reuseport),
                :$enc = 'utf-8', :$scheduler = $*SCHEDULER) {
    my $encoding = Encoding::Registry.find($enc);
    my $ring = IO::URing.new(:4entries);
    Supply.new: SocketListenerTappable.new:
      :$host, :$port, :$ring, :$backlog, :$encoding, :$scheduler, :$reuseport, :$reuseaddr
  }


#################################################
#                IPPROTO_IP LEVEL               #
#################################################

  multi method add-ip-membership(IO::URing::Socket::INET:D: ip_mreqn $ip-mreqn --> Bool) {
    setsockopt(
      $!socket,
      IPPROTO::IP,
      IP::ADD_MEMBERSHIP,
      nativecast(Pointer[void], $ip-mreqn),
      nativesizeof(ip_mreqn)
    );
  }

  multi method add-ip-membership(IO::URing::Socket::INET:D: $multi-addr, $address = '0.0.0.0', $ifindex = 0 --> Bool) {
    self.add-ip-membership(ip_mreqn.new(:$multi-addr, :$address, :$ifindex));
  }

  multi method drop-ip-membership(IO::URing::Socket::INET:D: ip_mreqn $ip-mreqn --> Bool) {
    setsockopt(
      $!socket,
      IPPROTO::IP,
      IP::DROP_MEMBERSHIP,
      nativecast(Pointer[void], $ip-mreqn),
      nativesizeof(ip_mreqn)
    );
  }

  multi method drop-ip-membership(IO::URing::Socket::INET:D: $multi-addr, $address = '0.0.0.0', $ifindex = 0 --> Bool) {
    self.drop-ip-membership(ip_mreqn.new(:$multi-addr, :$address, :$ifindex));
  }

  multi method multicast-loopback(IO::URing::Socket::INET:D: Bool $loopback --> Bool) {
    my buf8 $opt .= new;
    $opt.write-uint8(0, $loopback ?? 1 !! 0);
    setsockopt(
      $!socket,
      IPPROTO::IP,
      IP::MULTICAST_LOOP,
      nativecast(Pointer[void], $opt),
      nativesizeof(uint8)
    );
  }

  multi method multicast-loopback(IO::URing::Socket::INET:D: --> Bool) {
    my buf8 $opt .= new;
    $opt.write-uint32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      IPPROTO::IP,
      IP::MULTICAST_LOOP,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-uint32(0).Bool;
  }

  multi method ttl(IO::URing::Socket::INET:D: Int $ttl --> Bool) {
    my buf8 $opt .= new;
    $opt.write-int32(0, $ttl);
    setsockopt(
      $!socket,
      IPPROTO::IP,
      IP::TTL,
      nativecast(Pointer[void], $opt),
      nativesizeof(int32)
    );
  }

  multi method ttl(IO::URing::Socket::INET:D: --> Int) {
    my buf8 $opt .= new;
    $opt.write-int32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      IPPROTO::IP,
      IP::TTL,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-int32(0);
  }

  multi method multicast-ttl(IO::URing::Socket::INET:D: Int $ttl --> Bool) {
    my buf8 $opt .= new;
    $opt.write-int32(0, $ttl);
    setsockopt(
      $!socket,
      IPPROTO::IP,
      IP::MULTICAST_TTL,
      nativecast(Pointer[void], $opt),
      nativesizeof(int32)
    );
  }

  multi method multicast-ttl(IO::URing::Socket::INET:D: --> Int) {
    my buf8 $opt .= new;
    $opt.write-int32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      IPPROTO::IP,
      IP::MULTICAST_TTL,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-int32(0);
  }
}
