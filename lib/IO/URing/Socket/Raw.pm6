use NativeCall;
use NativeHelpers::Blob;
use Constants::Sys::Socket :AF, :SOCK;

subset Port of Int where 0 <= * <= 65535;

use Universal::errno;

constant INADDR_ANY is export(:INADDR_ANY) = "0.0.0.0";

constant INET_ADDRSTRLEN = 16;
constant INET6_ADDRSTRLEN = 46;
constant IFNAMSIZ = 16;

=begin pod

=head2 Unix::Socket::Raw

=end pod

=begin pod

=head3 Class in_addr

=head4 Members

$!s-addr

=head4 Methods

new(Str :$addr!)

new(UInt :$s-addr!) (Takes a uint32 in Network Byte Order)

Str(--> Str) (returns the string form of the IP address)

raw(--> uint32) (returns in Network Byte Order)

=end pod

class in_addr is repr('CStruct') is export(:in_addr) {
  has uint32 $.s-addr is rw; # In Network Byte Order

  multi submethod BUILD(UInt :$s-addr!) {
    $!s-addr = $s-addr;
  }

  multi submethod BUILD(Str :$addr!) {}

  multi submethod TWEAK(Str :$addr!) {
    $!s-addr = 0;
    unless inet-pton(AF::INET, $addr, nativecast(Pointer[void], self)) {
      die "invalid address \"$addr\"";
    }
  }

  multi submethod TWEAK(UInt :$s-addr) {}

  method raw() {
    my uint32 $tmp = $!s-addr;
    return $tmp;
  }

  method Str(in_addr:D: --> Str) {
    my buf8 $buf .= new;
    $buf.write-uint8(INET_ADDRSTRLEN, 0);
    my buf8 $self .= new;
    $self.write-uint32(0, $!s-addr, NativeEndian);
    return inet-ntop(AF::INET, nativecast(Pointer[void], $self), nativecast(Pointer, $buf), INET_ADDRSTRLEN).clone;
  }
}

=begin pod

=head3 Class in6_addr

=head4 Members

uint8 @!s-addr

=head4 Methods

new(Str :$addr!)

Str(--> Str) (returns the string form of the IP address)

raw(--> Array[UInt])

=end pod

class in6_addr is repr('CStruct') is export(:in6_addr) does Positional is rw {
  my constant \size = 16;

  # 64-bit integers give unbox errors
  has uint8 $.addr0;
  has uint8 $.addr1;
  has uint8 $.addr2;
  has uint8 $.addr3;
  has uint8 $.addr4;
  has uint8 $.addr5;
  has uint8 $.addr6;
  has uint8 $.addr7;
  has uint8 $.addr8;
  has uint8 $.addr9;
  has uint8 $.addr10;
  has uint8 $.addr11;
  has uint8 $.addr12;
  has uint8 $.addr13;
  has uint8 $.addr14;
  has uint8 $.addr15;

  submethod TWEAK(Str :$addr) {
    my buf8 $buf .= new;
    $buf.write-uint128(size, 0);
    unless inet-pton(AF::INET6, $addr, nativecast(Pointer[void], self)) {
      die "invalid address \"$addr\"";
    }
  }
  method raw() {
    my UInt @arr;
    my Pointer[uint8] $ptr = nativecast(Pointer[uint8], self);
    for ^size {
      @arr.append: $ptr[$_];
    }
    return @arr;
  }

  method Str {
    my $ptr = nativecast(Pointer[uint8], self);
    my buf8 $buf .= new;
    $buf.write-uint8(INET6_ADDRSTRLEN, 0);
    return inet-ntop(AF::INET6, $ptr, nativecast(Pointer[void], $buf), INET6_ADDRSTRLEN).clone;
  }

  method AT-POS(int $pos) {
    my $method = self.^lookup("addr$pos");
    return-rw $method(self) if $method;
    Nil
  }
}


# This is a do-nothing role for type-checking sockaddr
# classes without breaking their functionality
role sockaddr_role is export(:sockaddr_role) {}

=begin pod

=head3 Class sockaddr

=head4 Members

int16 $.family

=head4 Methods

new(int16 :$family!)

sockaddr_<type>() return this sockaddr casted to the sockaddr_<type>

example: sockaddr_in() returns sockaddr cast to the sockaddr_in type

size(--> Int) convenience method for nativesizeof(self)

=end pod

class sockaddr is repr('CStruct') is export {
  also does sockaddr_role;
  has int16 $.family is rw;
  has uint8 $.data0;
  has uint8 $.data1;
  has uint8 $.data2;
  has uint8 $.data3;
  has uint8 $.data4;
  has uint8 $.data5;
  has uint8 $.data6;
  has uint8 $.data7;
  has uint8 $.data8;
  has uint8 $.data9;
  has uint8 $.data10;
  has uint8 $.data11;
  has uint8 $.data12;
  has uint8 $.data13;

  method sockaddr_in6 {
    fail "Not an AF_INET6 sockaddr" unless $!family ~~ AF::INET6;
    return nativecast(::("sockaddr_in6"), self);
  }

  method sockaddr_in {
    fail "Not an AF_INET sockaddr" unless $!family ~~ AF::INET;
    return nativecast(::("sockaddr_in"), self);
  }

  method sockaddr_un {
    fail "Not an AF_LOCAL sockaddr" unless $!family ~~ AF::LOCAL;
    return nativecast(::("sockaddr_un"), self);
  }

  method size {
    nativesizeof(self);
  }
}

=begin pod

=head3 Class sockaddr_in

=head4 Members

int16 $.family

HAS in_addr $.addr

=head4 Methods

size(--> Int)

=end pod

class sockaddr_in is repr('CStruct') is export is rw {
  also does sockaddr_role;
  has int16 $.family;
  has uint16 $.port;
  HAS in_addr $.addr;
  has uint64 $!zero = 0;

  submethod BUILD(:$addr, :$port) {}

  submethod TWEAK(:$addr, :$port) {
    memset(nativecast(Pointer[void], self), 0, nativesizeof(self));
    my $temp = in_addr.new(:$addr);
    my \offset = BEGIN { nativesizeof(int16) + nativesizeof(uint16) };
    memcpy(
      Pointer[void].new( offset + nativecast(Pointer[void], self)),
      nativecast(Pointer[void], $temp),
      nativesizeof($temp)
    );
    $!family = AF::INET;
    $!port = htons($port);
    my $blob = blob8.allocate(nativesizeof(self), 0);
    memcpy(nativecast(Pointer[void], $blob), nativecast(Pointer[void], self), nativesizeof(self));
  }

  multi method new(Str :$addr, Port :$port) {
    self.bless(:$addr, :$port)
  }

  multi method new(Str $addr, Port $port) {
    self.bless(:$addr, :$port)
  }

  method port(--> Port) {
    # Work around bug where $!port is being treated as a 32-bit integer
    ntohs($!port) +& 0xFFFF;
  }

  method addr(--> Str) {
    $!addr.Str;
  }

  method Str(--> Str) {
    self.addr ~ ':' ~ self.port;
  }

  method sockaddr(sockaddr_in:D:--> sockaddr) {
    nativecast(sockaddr, self);
  }

  method size {
    nativesizeof(self);
  }
}

=begin pod

=head3 Class sockaddr_in6

=head4 Members

int16 $.family

uint16 $.port

uint32 $.flowinfo

HAS in6_addr $.addr

uint32 $.scope-id

=head4 Methods

size(--> Int)

=end pod

class sockaddr_in6 is repr('CStruct') is export {
  also does sockaddr_role;
  has int16 $.family;
  has uint16 $.port;
  has uint32 $.flowinfo;
  HAS in6_addr $.addr;
  has uint32 $.scope-id;

  submethod BUILD(:$port, :$flowinfo, :$addr, :$scope-id) {}

  submethod TWEAK(:$port, :$flowinfo, :$addr, :$scope-id) {
    $!port = htons($port);
    $!flowinfo = htonl($flowinfo);
    $!scope-id = htonl($scope-id);
    my $temp = in6_addr.new(:addr($addr));
    my \offset = BEGIN { nativesizeof(int16) + nativesizeof(uint16) + nativesizeof(uint32) };
    memcpy(
      Pointer[void].new(offset + nativecast(Pointer[void], self)),
      nativecast(Pointer[void], $temp),
      nativesizeof($temp)
    );
    $!family = AF::INET6;
  }

  multi method new(Str :$addr, Port :$port, :$flowinfo = 0, :$scope-id = 0) {
    self.bless(:$addr, :$port, :$flowinfo, :$scope-id)
  }

  multi method new(Str $addr, Port $port) {
    self.new(:$addr, :$port)
  }


  method flowinfo(sockaddr_in6:D: --> uint32) {
    ntohl: $!flowinfo
  }

  method scope-id(sockaddr_in6:D: --> uint32) {
    nothl: $!scope-id
  }

  method addr(sockaddr_in6:D: --> Str) {
    $!addr.Str;
  }

  method port(sockaddr_in6:D: --> Port) {
    # Work around bug where $!port is being treated as a 32-bit integer
    ntohs($!port) +& 0xFFFF;
  }

  method sockaddr(sockaddr_in6:D: --> sockaddr) {
    nativecast(sockaddr, self);
  }

  method size {
    nativesizeof(self);
  }
}

constant \UNIX_PATH_MAX = 108;

# Ugly hack because embedding arrays in a CStruct is not implemented yet.
class path-struct is repr('CStruct') is rw {
    has uint8 (
      $.p0, $.p1, $.p2, $.p3, $.p4, $.p5, $.p6, $.p7, $.p8,
      $.p9, $.p10, $.p11, $.p12, $.p13, $.p14, $.p15, $.p16,
      $.p17, $.p18, $.p19, $.p20, $.p21, $.p22, $.p23, $.p24,
      $.p25, $.p26, $.p27, $.p28, $.p29, $.p30, $.p31, $.p32,
      $.p33, $.p34, $.p35, $.p36, $.p37, $.p38, $.p39, $.p40,
      $.p41, $.p42, $.p43, $.p44, $.p45, $.p46, $.p47, $.p48,
      $.p49, $.p50, $.p51, $.p52, $.p53, $.p54, $.p55, $.p56,
      $.p57, $.p58, $.p59, $.p60, $.p61, $.p62, $.p63, $.p64,
      $.p65, $.p66, $.p67, $.p68, $.p69, $.p70, $.p71, $.p72,
      $.p73, $.p74, $.p75, $.p76, $.p77, $.p78, $.p79, $.p80,
      $.p81, $.p82, $.p83, $.p84, $.p85, $.p86, $.p87, $.p88,
      $.p89, $.p90, $.p91, $.p92, $.p93, $.p94, $.p95, $.p96,
      $.p97, $.p98, $.p99, $.p100, $.p101, $.p102, $.p103, $.p104,
      $.p105, $.p106, $.p107, $.p108
    );
}

=begin pod

=head3 Class sockaddr_un

=head4 Members

int16 $.family

uint8 $!pad1

HAS path-struct $!path # Ugly internal representation, working around NativeCall limitations

=head4 Methods

new(Str(Cool) $path --> sockaddr_un)

new(Str(Cool) :$path! --> sockaddr_un)

Str(Int $size = sockaddr_un.size --> Str) returns socket path

size(--> Int)

=end pod

class sockaddr_un is repr('CStruct') is export {
  also does sockaddr_role;
  has int16 $.family;
  HAS path-struct $!path;

  submethod TWEAK(Str :$path!) {
    memset(nativecast(Pointer[void], self), 0, nativesizeof(self));
    my blob8 $encoded = $path.encode;
    my $size = $encoded.bytes >= UNIX_PATH_MAX ?? UNIX_PATH_MAX !! $encoded.bytes;
    my $ptr = Pointer[void].new(+nativesizeof(int16) + nativecast(Pointer[void], self));
    memcpy($ptr, nativecast(Pointer[void], $encoded), $size);
    $!family = AF::UNIX;
  }

  multi method new(Str(Cool) $path) {
    self.bless(:$path);
  }

  multi method new(Str(Cool) :$path!) {
    self.bless(:$path);
  }

  method Str(sockaddr_un:D: UInt $size = sockaddr_un.size --> Str) {
    my blob8 $blob .= allocate($size - nativesizeof(int16), 0);
    memcpy(nativecast(Pointer[void], $blob), Pointer[void].new(nativesizeof(int16) + nativecast(Pointer[void], self)), $size - nativesizeof(int16));
    $blob.decode.trans("\0"=>"");
  }

  method size(--> Int) {
    return nativesizeof(int16) + UNIX_PATH_MAX;
  }

  method sockaddr(sockaddr_un:D: --> sockaddr) {
    nativecast(sockaddr, self);
  }
}

=begin pod

=head3 Class ip_mreqn

=head4 Members

HAS in_addr $.imr-multiaddr

HAS in_addr $.imr-address

int32 $.imr-ifindex

=head4 Methods

size(--> Int) size of self

=end pod

class ip_mreqn is repr('CStruct') is export(:ip_mreqn) {
  HAS in_addr $.imr-multiaddr; # IP multicast address of group
  HAS in_addr $.imr-address; # IP multicast address of interface
  has int32   $.imr-ifindex;   # Interface index
  submethod TWEAK(:$multi-addr, :$address, Int :$ifindex = 0) {
    # Workaround for putting one CStruct into another CStruct repr {
    my $temp = in_addr.new(:addr($multi-addr));
    memcpy(nativecast(Pointer[void], self), nativecast(Pointer[void], $temp), nativesizeof($temp));
    $temp = in_addr.new(:addr($address));
    memcpy(Pointer[void].new(nativesizeof($temp) + nativecast(Pointer[void], self)), nativecast(Pointer[void], $temp), nativesizeof($temp));
    # }

    $!imr-ifindex = $ifindex;
  }
  method size() returns size_t {
    return nativesizeof(self);
  }
}

=begin pod

=head3 Class ipv6_mreq

=head4 Members

HAS in6_addr $.ipv6mr-multiaddr

int32 $.ipv6mr-interface

=head4 Methods

new(Str :$multi-addr, Int :$ifindex = 0)

=end pod

class ipv6_mreq is repr('CStruct') is export(:ipv6_mreq) {
  HAS in6_addr $.ipv6mr-multiaddr;
  has uint32 $.ipv6mr-interface;

  submethod TWEAK(Str :$multi-addr, Int :$ifindex = 0) {
    my $temp = in6_addr.new(:addr($multi-addr));
    memcpy(nativecast(Pointer[void], self), nativecast(Pointer[void], $temp), nativesizeof($temp));

    $!ipv6mr-interface = $ifindex;
  }
}

sub free(Pointer) is native is export { ... }

sub memcpy(Pointer[void], Pointer[void], size_t) returns Pointer[void] is native is export {...}

sub malloc(size_t $size) returns Pointer[void] is native is export { ... }

class iovec is repr('CStruct') is rw {
  has Pointer[void] $.iov_base;
  has size_t $.iov_len;

  submethod BUILD(Pointer:D :$iov_base, Int:D :$iov_len) {
    $!iov_base := $iov_base;
    $!iov_len = $iov_len;
  }

  method free(iovec:D:) {
    free(nativecast(Pointer[void], self));
  }

  multi method new(Str $str --> iovec) {
    self.new($str.encode);
  }

  multi method new(Blob $blob --> iovec) {
    my $ptr = malloc($blob.bytes);
    memcpy($ptr, nativecast(Pointer[void], $blob), $blob.bytes);
    self.bless(:iov_base($ptr), :iov_len($blob.bytes));
  }

  multi method new(CArray[size_t] $arr, UInt $pos) {
    self.bless(:iov_base($arr[$pos]), :iov_len($arr[$pos + 1]));
  }

  multi method new(size_t :$ptr, size_t :$len) {
    self.bless(:iov_base($ptr), :iov_len($len))
  }

  method Blob {
    my buf8 $buf .= allocate($!iov_len);
    memcpy(nativecast(Pointer[void], $buf), $!iov_base, $!iov_len);
    $buf;
  }

  method elems {
    $!iov_len
  }

  method Pointer {
    $!iov_base;
  }
}

enum AddrInfo-Flags (
        AI_PASSIVE                  => 0x0001;
        AI_CANONNAME                => 0x0002;
        AI_NUMERICHOST              => 0x0004;
        AI_V4MAPPED                 => 0x0008;
        AI_ALL                      => 0x0010;
        AI_ADDRCONFIG               => 0x0020;
        AI_IDN                      => 0x0040;
        AI_CANONIDN                 => 0x0080;
        AI_IDN_ALLOW_UNASSIGNED     => 0x0100;
        AI_IDN_USE_STD3_ASCII_RULES => 0x0200;
        AI_NUMERICSERV              => 0x0400;
        );

class Addrinfo is repr('CStruct') {
  has int32 $.ai_flags;
  has int32 $.ai_family;
  has int32 $.ai_socktype;
  has int32 $.ai_protocol;
  has int32 $.ai_addrlen;
  has sockaddr $.ai_addr is rw;
  has Str $.ai_cannonname is rw;
  has Addrinfo $.ai_next is rw;

  method flags {
    do for AddrInfo-Flags.enums { .key if $!ai_flags +& .value }
  }

  method family {
    AF($!ai_family)
  }

  method socktype {
    SOCK($!ai_socktype)
  }

  method address {
    given $.family {
      when AF::INET {
        ~nativecast(in_addr, $!ai_addr)
      }
      when AF::INET6 {
        ~nativecast(in6_addr, $!ai_addr)
      }
    }
  }
}

# TCP is done through IORING_OP_SEND and IORING_OP_RECV so
# only make helpers for UDP/datagram sockets with msghdr
class msghdr is repr('CStruct') is rw is export(:msghdr) {
  has size_t $.msg_name;
  has int32 $.msg_namelen;
  has CArray[size_t] $.msg_iov; # Budget iovec
  has size_t $.msg_iovlen;
  has Pointer $.msg_control;
  has size_t $.msg_controllen;
  has int32 $.msg_flags;

  submethod BUILD(size_t :$iovlen = 1) {
    $!msg_iov := CArray[size_t].new(0 xx (2 * $iovlen));
    $!msg_iovlen = $iovlen;
  }

  multi method prep-send(Addrinfo $info, @msg where Str ~~ any(*), Str $name? = Str, :$enc = 'utf-8') {
    for @msg -> $msg is rw {
      $msg = $msg.encode($enc) if $msg ~~ Str;
    }
    self.fill($info, @msg, $name);
  }

  multi method prep-send(Addrinfo $info, @msg, Str $name? = Str) {
    my $iov_cnt = 1;
    for @msg -> $msg {
      fail "Too many iovs for this msghdr" unless $iov_cnt <= $!msg_iovlen;
      $!msg_iov[2 * $iov_cnt] = +nativecast(Pointer, $msg);
      $!msg_iov[2 * $iov_cnt + 1] = $msg.bytes;
    }
    fail "Need a destination" without $name;
  }

  method prep-recv(Addrinfo $info, @msg, Blob $name? = Blob) {
    my $iov_cnt = 1;
    for @msg -> $msg {
      fail "Too many iovs for this msghdr" unless $iov_cnt <= $!msg_iovlen;
      $!msg_iov[2 * $iov_cnt] = +nativecast(Pointer, $msg);
      $!msg_iov[2 * $iov_cnt + 1] = $msg.bytes;
    }
    with $name {

    }
    else {
      $!msg_name = Pointer.new;
      $!msg_namelen = 0;
    }
  }
}

sub getaddrinfo( Str $node, Str $service, Addrinfo $hints, Pointer $res is rw ) returns int32 is native { ... }

sub freeaddrinfo(Pointer) is native {}

constant sockfd is export(:socket) = int32;


sub memcpy(Pointer[void], Pointer[void], size_t) returns Pointer[void] is native {...}

sub memset(Pointer[void], int32, size_t) returns Pointer[void] is native {...}

sub ntohs(uint16) returns uint16 is native { ... }

sub htons(uint16) returns uint16 is native { ... }

sub ntohl(uint32) returns uint32 is native { ... }

sub htonl(uint32) returns uint32 is native { ... }

sub setsockopt(|c) returns Bool is export(:setsockopt) {
  my int32 $result = _setsockopt(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! True;
}

sub _setsockopt(sockfd $sockfd, int32 $level, int32 $optname, Pointer[void], uint32 $optlen) returns int32 is native is symbol('setsockopt') is export(:_setsockopt) {...}

sub getsockopt(|c) returns Bool is export(:getsockopt) {
  my int32 $result = _getsockopt(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! True;
}

sub _getsockopt(sockfd $sockfd, int32 $level, int32 $optname, Pointer[void] $optval, Pointer[uint32] $optlen) returns int32 is native is symbol('getsockopt') is export(:_getsockopt) {...}

sub shutdown(|c) returns Bool is export(:shutdown) {
  my int32 $result = _shutdown(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! True;
}

sub _shutdown(sockfd $sockfd, int32 $how) returns int32 is native is symbol('shutdown') is export(:_shutdown) {...}

sub inet-pton(|c) returns Bool is export(:inet-pton) {
  my int32 $result = _inet-pton(|c);
  return True if $result == 1;
  return fail "Invalid address" if $result == 0;
  my $failure = fail errno.symbol;
  set_errno(0);
  $failure;
}

sub _inet-pton(int32, Str, Pointer[void]) returns int32 is native is symbol('inet_pton') is export(:_inet-pton) {...}

sub inet-ntop(int32, Pointer[void], Pointer[uint8], int32) returns Str is native is symbol('inet_ntop') is export(:inet-ntop) {...}

sub socket(|c) returns sockfd is export(:socket) {
  my sockfd $result = _socket(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! $result;
}

sub _socket(int32 $domain, int32 $type, int32 $protocol) returns sockfd is native is symbol('socket') is export(:_socket) {...}

sub close(|c) returns int32 is export(:close) {
  my int32 $result = _close(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! True;
}

sub get-close(--> Str) {
  return "closesocket" if $*DISTRO.is-win();
  return "close";
}

sub _close(sockfd $sockfd) returns int32 is native is symbol(get-close) is export(:_close) {...}

sub bind(|c) returns Bool is export(:bind) {
  my int32 $result = _bind(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! True;
}

sub _bind(sockfd $sockfd, sockaddr $my-addr, int32 $addrlen) returns int32 is native is symbol('bind') is export(:_bind) {...}

sub listen(|c) returns Bool is export(:listen) {
  my int32 $result = _listen(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! True;
}

sub _listen(sockfd $sockfd, int32 $backlog) returns int32 is native is symbol('listen') is export(:_listen) {...}

sub getpeername(|c) returns int32 is export(:getpeername) {
  my int32 $result = _getpeername(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! $result;
}

sub _getpeername(sockfd, sockaddr $address, int32 is rw) returns int32 is native is symbol('getpeername') is export(:_getpeername) { ... }

sub getsockname(|c) returns int32 is export(:getsockname) {
  my int32 $result = _getsockname(|c);
  return $result < 0
  ?? do {
    my $failure = fail errno.symbol;
    set_errno(0);
    $failure;
  }
  !! $result;
}

sub _getsockname(sockfd, sockaddr, int32 is rw) returns int32 is native is symbol('getsockname') is export(:_getsockname) { ... }

=begin pod

=head3 Subroutines

inet-pton(int32, Str, Pointer[void]) returns int32

inet-ntop(int32, Pointer[void], Pointer[uint8], int32) returns Str

All of the functions below are wrapped by default. If something goes wrong, the
function will return a Failure containing C<errno.symbol> *see Unix::errno*

To use the unwrapped version, put an underscore before the function name:
e.g. C<_bind>

setsockopt(socket $sockfd, int32 $level, int32 $optname, Pointer[void], uint32 $optlen) returns int32

getsockopt(socket $sockfd, int32 $level, int32 $optname, Pointer[void] $optval) returns int32

shutdown(sockfd $socket, int32 $how) returns int32

socket(int32 $domain, int32 $type, int32 $protocol) returns int32

close(sockfd $socket) returns int32

bind(sockfd $socket, sockaddr $addr, int32 $addrlen) returns int32

listen(sockfd $socket, int32 $backlog) returns int32

=head1 AUTHOR

Travis Gibson <TGib.Travis@protonmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2019 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
