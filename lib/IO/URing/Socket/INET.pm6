use IO::URing;
use IO::URing::Socket;
use IO::URing::Socket::Raw :ALL;
use Universal::errno;
use NativeCall;
use Constants::Sys::Socket :ALL;
use Constants::Netinet::In :ALL;
use nqp;

class IO::URing::Socket::INET does IO::URing::Socket is export {
  my class INET-Datagram {
    has str $.host;
    has int $.port;
    has $.data;

    method new(:$data, :$sockaddr, :$domain) {
      my $addr = $domain ~~ AF::INET6 ?? nativecast(sockaddr_in6, $sockaddr) !! nativecast(sockaddr_in, $sockaddr);
      self.bless(:$data, :host($addr.addr), :port($addr.port));
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

  method connect(IO::URing::Socket::INET:U: Str $address, Int $port where IO::Socket::Async::Port-Number, :$ip6,
                :$enc = 'utf-8', IO::URing :$ring) {
    my $p = Promise.new;
    my $v = $p.vow;
    my $io-uring = $ring // IO::URing.new(:4entries);
    my $encoding = Encoding::Registry.find($enc);
    my $domain = $ip6 ?? AF::INET6 !! AF::INET;
    my $ipproto = $ip6 ?? IPPROTO::IPV6 !! IPPROTO::IP;
    my $socket = socket($domain, SOCK::STREAM, 0);
    my $addr = $domain ~~ AF::INET6
      ?? sockaddr_in6.new($address, $port)
      !! sockaddr_in.new($address, $port);
    $ring.connect($socket, $addr).then: -> $cmp {
      use nqp;
      my $client_socket := nqp::create(self);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!socket', $socket);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!ring', $io-uring);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!enc', $encoding.name);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!encoder', $encoding.encoder());
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!domain', $domain);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!ipproto', $ipproto);
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
    has $!reusering;
    has $!domain;

    method new(:$host!, :$port!, :$backlog!, :$encoding!, :$scheduler!, :$ring!, :$domain!, :$reuseaddr, :$reuseport, :$reusering) {
      self.CREATE!SET-SELF($host, $port, $backlog, $encoding, $scheduler, $ring, $domain, $reuseaddr, $reuseport, $reusering)
    }

    method !SET-SELF($!host, $!port, $!backlog, $!encoding, $!scheduler, $!ring, $!domain, $!reuseaddr?, $!reuseport?, $!reusering?) { self }

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
      my $socket = socket($!domain, SOCK::STREAM, 0);
      reuseaddr($socket, $!reuseaddr) if $!reuseaddr;
      reuseport($socket, $!reuseport) if $!reuseport;
      my $addr = $!domain ~~ AF::INET6
        ?? sockaddr_in6.new(:addr($!host), $!port)
        !! sockaddr_in.new(:addr($!host), :$!port);
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
                        $!reusering ?? $!ring !! IO::URing.new(:4entries));
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
                Int() $backlog = 128, :$ip6, :REUSEADDR(:$reuseaddr), :REUSEPORT(:$reuseport),
                :$enc = 'utf-8', :$scheduler = $*SCHEDULER, IO::URing :$ring, :$reusering) {
    my $domain = $ip6 ?? AF::INET6 !! AF::INET;
    my $encoding = Encoding::Registry.find($enc);
    my $io-uring = $ring // IO::URing.new(:4entries);
    Supply.new: SocketListenerTappable.new:
      :$host, :$port, :$ring, :$backlog, :$encoding, :$scheduler, :$domain :$reuseport, :$reuseaddr, :$reusering
  }

  method dgram(IO::URing::Socket::INET:U: :$broadcast, :$ip6, :$enc = 'utf-8', :$scheduler = $*SCHEDULER) {
    my $p = Promise.new;
    $scheduler.cue: -> {
      my $domain = $ip6 ?? AF::INET6 !! AF::INET;
      my $socket = socket(AF::INET, SOCK::DGRAM, 0);
      my $encoding = Encoding::Registry.find($enc);
      my $client_socket := nqp::create(self);
      my $ring = IO::URing.new(:4entries);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!socket', $socket);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!domain', $domain);
      nqp::bindattr_i($client_socket, IO::URing::Socket::INET, '$!dgram', 1);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!datagram', INET-Datagram);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!ring', $ring);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!enc', $encoding.name);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!encoder',
              $encoding.encoder());
      setup-close($client_socket);
      $client_socket.broadcast(True) if $broadcast;
      $p.keep($client_socket);
    };
    await $p;
  }

  method udp(IO::URing::Socket::INET:U: |c) {
    self.dgram(|c);
  }

  method bind-dgram(IO::URing::Socket::INET:U: Str() $host, Int() $port where IO::Socket::Async::Port-Number, :$ip6,
                   :REUSEADDR(:$reuseaddr), :REUSEPORT(:$reuseport), :$enc = 'utf-8', :$scheduler = $*SCHEDULER, IO::URing :$ring) {
    my $p = Promise.new;
    $scheduler.cue: -> {
      my $domain = $ip6 ?? AF::INET6 !! AF::INET;
      my $socket = socket($domain, SOCK::DGRAM, 0);
      my $io-uring = $ring // IO::URing.new(:4entries);
      my $encoding = Encoding::Registry.find($enc);
      my $client_socket := nqp::create(self);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!socket', $socket);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!domain', $domain);
      nqp::bindattr_i($client_socket, IO::URing::Socket::INET, '$!dgram', 1);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!datagram', INET-Datagram);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!ring', $io-uring);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!enc', $encoding.name);
      nqp::bindattr($client_socket, IO::URing::Socket::INET, '$!encoder',
              $encoding.encoder());
      setup-close($client_socket);
      $client_socket.reuseport(True) if $reuseport;
      $client_socket.reuseaddr(True) if $reuseaddr;
      my $addr = $domain ~~ AF::INET6 ?? sockaddr_in6.new($host, $port) !! sockaddr_in.new($host, $port);
      bind($socket, $addr, $addr.size);
      $p.keep($client_socket);
    }
    await $p
  }

  method bind-udp(IO::URing::Socket::INET:U: |c) {
    self.bind-dgram(|c);
  }

  method print-to(IO::URing::Socket::INET:D: Str() $host, Int() $port where IO::Socket::Async::Port-Number,
                  Str() $str, :$scheduler = $*SCHEDULER) {
    self.write-to($host, $port, $!encoder.encode-chars($str), :$scheduler)
  }

  method write-to(IO::URing::Socket::INET:D: Str() $host, Int() $port where IO::Socket::Async::Port-Number,
                  Blob $b, :$scheduler = $*SCHEDULER) {
    my $p = Promise.new;
    my $v = $p.vow;
    my sockaddr_in $addr .= new($host, $port);
    $!ring.sendto($!socket, $b, 0, $addr, sockaddr_in.size).then: -> $cmp {
      if $cmp ~~ Exception {
        $v.break(strerror($cmp));
      }
      else {
        $v.keep($cmp.result.result);
      }
    };
    $p;
  }

#################################################
#                IPPROTO_IP LEVEL               #
#################################################

  multi method add-ip-membership(IO::URing::Socket::INET:D: ip_mreqn $ip-mreqn --> Bool) {
    setsockopt(
      $!socket,
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::ADD_MEMBERSHIP !! IPV6::ADD_MEMBERSHIP,
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
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::DROP_MEMBERSHIP !! IPV6::DROP_MEMBERSHIP,
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
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::MULTICAST_LOOP !! IPV6::MULTICAST_LOOP,
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
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::MULTICAST_LOOP !! IPV6::MULTICAST_LOOP,
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
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::TTL !! IPV6::UNICAST_HOPS,
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
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::TTL !! IPV6::UNICAST_HOPS,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-int32(0);
  }

  multi method multicast-hops(IO::URing::Socket::INET:D: Int $ttl --> Bool) {
    my buf8 $opt .= new;
    $opt.write-int32(0, $ttl);
    setsockopt(
      $!socket,
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::MULTICAST_TTL !! IPV6::MULTICAST_HOPS,
      nativecast(Pointer[void], $opt),
      nativesizeof(int32)
    );
  }

  multi method multicast-hops(IO::URing::Socket::INET:D: --> Int) {
    my buf8 $opt .= new;
    $opt.write-int32(0, 0);
    my buf8 $len .= new;
    $len.write-uint32(0, nativesizeof(uint32));
    getsockopt(
      $!socket,
      $!ipproto,
      $!domain ~~ AF::INET ?? IP::MULTICAST_TTL !! IPV6::MULTICAST_HOPS,
      nativecast(Pointer[void], $opt),
      nativecast(Pointer[uint32], $len)
    );
    $opt.read-int32(0);
  }
}
