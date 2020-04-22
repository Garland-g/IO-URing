use IO::URing;
use IO::URing::Socket::Raw :ALL;
use Universal::errno;
use NativeCall;

use Constants::Sys::Socket :ALL;
use Constants::Netinet::In :ALL;

role IO::URing::Socket is export {
  has $!socket;
  has int $!dgram;
  has $.enc;
  has $!encoder;
  has $!close-promise;
  has $!close-vow;
  has $!ring;
  has $!domain;

  method new() {
    die "Cannot directly instantiate an IO::URing::Socket. Please use\n" ~
        "IO::URing::Socket.connect, IO::URing::Socket.listen,\n" ~
        "IO::URing::Socket.dgram, or IO::URing::Socket.bind-dgram.";
  }

  method print(IO::URing::Socket:D: Str() $str) {
    self.write($!encoder.encode-chars($str));
  }

  method write(IO::URing::Socket:D: Blob:D $buf) {
    my $p := Promise.new;
    my $v := $p.vow;
    $!ring.send($!socket, $buf).then: -> Mu \cmp {
      if cmp.result < 0 {
        $v.break(strerror(cmp.result));
      }
      else {
        $v.keep(cmp.result);
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

    method new(sockfd :$socket!, :$scheduler!, IO::URing :$ring!, :$close-promise!, :$dgram!, :$datagram!) {
      self.CREATE!SET-SELF($socket, $ring, $scheduler, $close-promise, $dgram, $datagram)
    }

    method !SET-SELF(sockfd $!socket, $!ring, $!scheduler, $!close-promise, $!dgram, $!datagram) { self }

    method tap(&emit, &done, &quit, &tap) {
      my $buffer := buf8.allocate(1024 * 60, 0); # Size of largest UDP packet
      my int $buffer-start-seq = 0;
      my int $done-target = -1;
      my int $finished = 0;

      my $lock = Lock::Async.new;
      my $tap;
      my $handle;
      $lock.protect: {
        #`{
        # UDP
          $handle = $!ring.recvmsg($!socket, $buffer).then: -> $cmp {
            $lock.protect: {
              my \err := $cmp.result;
              my \data := $cmp.request.data;
              unless $finished {
                if err <= 0 {
                  quit(X::AdHoc.new(payload => err));
                  $finished = 1;
                }
                elsif err >= 0 {
                  emit-events();
                }
                else {
                  emit-events();
                }
              }
            }
          };
          #}
        my $cancellation := $!scheduler.cue: -> {
          loop {
            $handle = $!ring.recv($!socket, $buffer);
            await $handle.then: -> $cmp {
              $lock.protect: {
                my \err := $cmp.result.result;
                unless $finished {
                  if err < 0 {
                    quit(X::AdHoc.new(payload => err));
                    $finished = 1;
                  }
                  elsif err > 0 {
                    emit($buffer.subbuf(^err));
                  }
                  else {
                    $finished = 1;
                    done();
                  }
                }
              }
            }
            last if $finished;
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

  multi method Supply(IO::URing::Socket:D: :$bin, :$datagram, :$enc = 'utf-8', :$scheduler = $*SCHEDULER) {
    if $bin {
      Supply.new: SocketReaderTappable.new:
        :$!socket, :$!ring, :$scheduler, :$!close-promise, :$!dgram, :$datagram
    }
    else {
      my $bin-supply = self.Supply(:bin, :$datagram);
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

  method close(IO::URing::Socket:D: --> True) {
    shutdown($!socket, 2) unless $!dgram;
    close($!socket);
    try $!close-vow.keep(True);
  }

  method native-descriptor(--> Int) {
    $!socket;
  }

  sub setup-close(\socket --> Nil) {
    use nqp;
    my $p := Promise.new;
    nqp::bindattr(socket, IO::URing::Socket, '$!close-promise', $p);
    nqp::bindattr(socket, IO::URing::Socket, '$!close-vow', $p.vow);
  }

#################################################
#                SOL_SOCKET LEVEL               #
#################################################

  multi method reuseaddr(IO::URing::Socket:D: Bool $reuseaddr --> Bool) {
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

  multi method reuseaddr(IO::URing::Socket:D: --> Bool) {
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

  multi method reuseport(IO::URing::Socket:D: Bool $reuseport --> Bool) {
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

  multi method reuseport(IO::URing::Socket:D: --> Bool) {
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

  method acceptconn(IO::URing::Socket:D: --> Bool) {
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

 multi method bindtodevice(IO::URing::Socket:D: Str $device where .chars < 16 --> Bool) {
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

  multi method broadcast(IO::URing::Socket:D: Bool $broadcast --> Bool) {
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

  multi method broadcast(IO::URing::Socket:D: --> Bool) {
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

  multi method dontroute(IO::URing::Socket:D: Bool $dontroute --> Bool) {
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

  multi method dontroute(IO::URing::Socket:D: --> Bool) {
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
