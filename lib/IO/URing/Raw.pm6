my $version = Version.new($*KERNEL.release);

die "Must be loaded on Linux 5.1 or higher"
  unless $*KERNEL ~~ 'linux' && $version ~~ v5.1+;

use NativeCall;
use NativeHelpers::iovec;
use IO::URing::Socket::Raw :ALL;
use Universal::errno;

constant \LIB = 'uring';

# specified by iBCS2
my constant POLLIN =   0x0001;
my constant POLLPRI =  0x0002;
my constant POLLOUT =  0x0004;
my constant POLLERR =  0x0008;
my constant POLLHUP =  0x0010;
my constant POLLNVAL = 0x0020;

sub eventfd(uint32 $initval, int32 $flags) returns int32 is native { ... }

sub eventfd_read(int32 $fd, uint64 $value is rw) returns int32 is native { ... }

sub eventfd_write(int32 $fd, uint64 $value) returns int32 is native { ... }

enum IORING_SETUP (
# linux 5.1
  IORING_SETUP_IOPOLL => 1,     # (1U << 0)
  IORING_SETUP_SQPOLL => 2,     # (1U << 1)
  IORING_SETUP_SQ_AFF => 4,     # (1U << 2)
# linux 5.5
  IORING_SETUP_CQSIZE => 8,     # (1U << 3)
# linux 5.6
  IORING_SETUP_CLAMP => 16,     # (1U << 4)
  IORING_SETUP_ATTACH_WQ => 32, # (1U << 5)
);
#linux 5.1
my constant IORING_FSYNC_DATASYNC = 1; #fsync_flags

#linux 5.5
my constant IORING_TIMEOUT_ABS = 1; #timeout_flags

#linux 5.1
my constant IORING_OFF_SQ_RING = 0;
my constant IORING_OFF_CQ_RING = 0x8000000;
my constant IORING_OFF_SQES    = 0x10000000;

#linux 5.1
my constant IORING_SQ_NEED_WAKEUP = 1;

enum IOSQE (
# linux 5.1
  IOSQE_FIXED_FILE => 1,  # (1U << IOSQE_FIXED_FILE_BIT)
# linux 5.2
  IOSQE_IO_DRAIN => 2,   # (1U << IOSQE_IO_DRAIN_BIT)
# linux 5.3
  IOSQE_IO_LINK => 4,     # (1U << IOSQE_IO_LINK_BIT)
# linux 5.5
  IOSQE_IO_HARDLINK => 8, # (1U << IOSQE_IO_HARDLINK_BIT)
# linux 5.6
  IOSQE_ASYNC => 16,      # (1U << IOSQE_ASYNC_BIT)
);

#linux 5.6
enum IOSQE_BIT (
  IOSQE_FIXED_FILE_BIT => 0,
  IOSQE_IO_DRAIN_BIT => 1,
  IOSQE_IO_LINK_BIT => 2,
  IOSQE_IO_HARDLINK_BIT => 3,
  IOSQE_ASYNC_BIT => 4,
);

enum IORING_OP (
# linux 5.1
  "IORING_OP_NOP",
  "IORING_OP_READV",
  "IORING_OP_WRITEV",
  "IORING_OP_FSYNC",
  "IORING_OP_READ_FIXED",
  "IORING_OP_WRITE_FIXED",
  "IORING_OP_POLL_ADD",
  "IORING_OP_POLL_REMOVE",
# linux 5.2
  "IORING_OP_SYNC_FILE_RANGE",
# linux 5.3
  "IORING_OP_SENDMSG",
  "IORING_OP_RECVMSG",
# linux 5.4
  "IORING_OP_TIMEOUT",
# linux 5.5
  "IORING_OP_TIMEOUT_REMOVE",
  "IORING_OP_ACCEPT",
  "IORING_OP_ASYNC_CANCEL",
  "IORING_OP_LINK_TIMEOUT",
  "IORING_OP_CONNECT",
# linux 5.6
  "IORING_OP_FALLOCATE",
  "IORING_OP_OPENAT",
  "IORING_OP_CLOSE",
  "IORING_OP_FILES_UPDATE",
  "IORING_OP_STATX",
  "IORING_OP_READ",
  "IORING_OP_WRITE",
  "IORING_OP_FADVISE",
  "IORING_OP_MADVISE",
  "IORING_OP_SEND",
  "IORING_OP_RECV",
  "IORING_OP_OPENAT2",
  "IORING_OP_EPOLL_CTL",
#linux 5.7
  "IORING_OP_SPLICE",
  "IORING_OP_PROVIDE_BUFFERS",
  "IORING_OP_REMOVE_BUFFERS",
#linux 5.9
  "IORING_OP_TEE",
# end
  "IORING_OP_LAST",
);

enum IORING_ENTER (
  IORING_ENTER_GETEVENTS => 1,
  IORING_ENTER_SQ_WAKEUP => 2,
);

# linux 5.6
my constant IO_URING_OP_SUPPORTED = 1; # (1U << 0)

class kernel_timespec is repr('CStruct') is rw {
  has uint64 $tv_sec;
  has uint64 $tv_nsec;
}

class sigset_t is repr('CPointer') {
  method empty(--> Int) {
    sigemptyset(self);
  }
  method fill(--> Int) {
    sigfillset(self);
  }
  my sub sigemptyset(sigset_t) returns int32 is native { ... }
  my sub sigfillset(sigset_t) returns int32 is native { ... }
}

class io_uring_probe_op is repr('CStruct') {
  has uint8 $.op;
  has uint8 $.resv;
  has uint16 $.flags;
  has uint32 $.resv2;
}

class io_uring_probe is repr('CStruct') {
  has uint8 $.last-op;
  has uint8 $.ops-len;
  has uint16 $.resv;
  HAS uint32 @.resv2[3] is CArray;

  method supported-ops(--> Hash) {
    my %ops;
    my $ptr = Pointer[int64].new(nativesizeof(self) + nativecast(Pointer[int64], self));

    my sub parse-probe-op(io_uring_probe_op $probe-op --> Bool) {
      return ($probe-op.flags +& IO_URING_OP_SUPPORTED).Bool;
    }

    for ^$!last-op -> $opcode {
      my $name = IORING_OP($opcode);
      last if $name == IORING_OP_LAST;
      %ops{IORING_OP($name)} = parse-probe-op(nativecast(io_uring_probe_op, $ptr));
      $ptr = Pointer[int64].new(8 + $ptr);
    }
    return %ops;
  }

  method free(\SELF: --> Nil) {
    free(nativecast(Pointer, SELF));
    SELF = Nil;
  }
}

class io_sqring_offsets is repr('CStruct') {
  has uint32 $.head;
  has uint32 $.tail;
  has uint32 $.ring_mask;
  has uint32 $.ring_entries;
  has uint32 $.flags;
  has uint32 $.dropped;
  has uint32 $.array;
  has uint32 $.resv1;
  has uint64 $.resv2;
}

class io_cqring_offsets is repr('CStruct') {
  has uint32 $.head;
  has uint32 $.tail;
  has uint32 $.ring_mask;
  has uint32 $.ring_entries;
  has uint32 $.overflow;
  has uint32 $.cqes;
  has uint64 $.resv1;
  has uint64 $.resv2;
}

class io_uring_params is repr('CStruct') {
  has uint32 $.sq_entries;
  has uint32 $.cq_entries is rw;
  has uint32 $.flags is rw;
  has uint32 $.sq_thread_cpu;
  has uint32 $.sq_thread_idle;
  has uint32 $.features;
  has uint32 $.wq_fd;
  has uint32 $.resv0;
  has uint32 $.resv1;
  has uint32 $.resv2;
  HAS io_sqring_offsets $.sq_off;
  HAS io_cqring_offsets $.cq_off;
}

# io_uring_params features flags
enum IORING_FEAT (
  SINGLE_MMAP => 1,      #5.4  1U << 0
  NODROP => 2,           #5.5  1U << 1
  SUBMIT_STABLE => 4,    #5.5  1U << 2
  RW_CUR_POS => 8,       #5.6  1U << 3
  CUR_PERSONALITY => 16, #5.6  1U << 4
  FAST_POLL => 32,       #5.7  1U << 5
);

class io_uring_sqe is repr('CStruct') is rw {
  has uint8 $.opcode;   # type of operation
  has uint8 $.flags;    # IOSQE_ flags
  has uint16 $.ioprio;  # ioprio for the request
  has int32 $.fd;       # file descriptor to do IO on
  has uint64 $.off;     # offset into file
  has uint64 $.addr;    # pointer to buffer or iovecs
  has uint32 $.len;     # buffer size or number of iovecs

  # union {
    # __kernel_rwf_t rw_flags; (int32)
    # __u32          fsync_flags;
    # __u16          poll_events;
    # __u32          sync_range_flags;
    # __u32          msg_flags;
    # __u32          timeout_flags;
    # __u32          accept_flags;
    # __u32          cancel_flags;
    # __u32          open_flags;
    # __u32          statx_flags;
    # __u32          fadvise_advice;
  # }
  has uint32 $.union-flags;
  has uint64 $.user_data; # data to be passed back at completion time

  # union {
    # struct {
      # __u16 buf_index;
      # __u16 personality;
    # }
    # __u64 __pad2[3];
  # }
  has uint16 $.buf_index; #index into fixed buffers, if used
  has uint16 $.personality; #personality to use, if used
  has uint32 $.pad0 = 0;
  has uint64 $.pad1 = 0;
  has uint64 $.pad2 = 0;

  multi method addr2(io_uring_sqe:D: ) { self.off }

  multi method rw_flags(io_uring_sqe:D: ) {
    nativecast(int32, self.union-flags);
  }
  multi method rw_flags(io_uring_sqe:D: Int $flags) {
    self.union-flags = $flags;
  }
  method fsync_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method poll_events(io_uring_sqe:D: ) {
    return self.union-flags +& 0x0000FFFF;
  }
  method sync_range_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method msg_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method timeout_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method accept_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method cancel_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method open_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method statx_flags(io_uring_sqe:D: ) {
    return self.union-flags;
  }
  method fadvise_advice(io_uring_sqe:D: ) {
    return self.union-flags;
  }

  method prep(io_uring_sqe:D: Int \op, Int \fd, $addr, Int \len, Int \offset) {
    self.opcode = op;
    self.flags = 0;
    self.ioprio = 0;
    self.fd = fd;
    self.off = offset;
    self.addr = $addr.defined ?? +$addr !! 0;
    self.len = len;
    self.rw_flags: 0;
    self.user_data = 0;
    self.pad0 = self.pad1 = self.pad2 = 0;
  }

  method prep-nop(io_uring_sqe:D: ) {
    self.prep(IORING_OP_NOP, -1, Pointer, 0, 0);
    self
  }

  method prep-readv(io_uring_sqe:D: $fd,  $iovecs, UInt $nr_vecs, Int $offset) {
    self.prep(IORING_OP_READV, $fd, $iovecs, $nr_vecs, $offset);
    self
  }

  method prep-writev(io_uring_sqe:D: $fd,  $iovecs, UInt $nr_vecs, Int $offset) {
    self.prep(IORING_OP_WRITEV, $fd, $iovecs, $nr_vecs, $offset);
    self
  }

  method prep-fsync(io_uring_sqe:D: $fd, UInt $fsync-flags) {
    self.prep(IORING_OP_FSYNC, $fd, Str, 0, 0);
    $!union-flags = $fsync-flags +& 0xFFFFFFFF;
    self
  }

  method prep-poll-add(io_uring_sqe:D: $fd, Int $poll-mask) {
    self.prep(IORING_OP_POLL_ADD, $fd, Str, 0, 0);
    $!union-flags = $poll-mask +& 0xFFFF;
    self
  }

  method prep-poll-remove(io_uring_sqe:D: Int $user-data) {
    self.prep(IORING_OP_POLL_REMOVE, -1, $user-data, 0, 0);
    self
  }

  method prep-recvmsg(io_uring_sqe:D: $fd, Pointer $msg, uint32 $flags) {
    self.prep(IORING_OP_RECVMSG, $fd, $msg, 1, 0);
    $!union-flags = $flags;
    self
  }

  method prep-sendmsg(io_uring_sqe:D: $fd, Pointer $msg, uint32 $flags) {
    self.prep(IORING_OP_SENDMSG, $fd, $msg, 1, 0);
    $!union-flags = $flags;
    self
  }

  method prep-cancel(io_uring_sqe:D: UInt $flags, Int $user-data) {
    self.prep(IORING_OP_ASYNC_CANCEL, -1, $user-data, 0, 0);
    $!union-flags = $flags;
  }

  method prep-accept(io_uring_sqe:D: $fd, $flags, $addr = Any) {
    my $size = $addr.defined ?? $addr.size !! 0;
    my $address = $addr.defined ?? nativecast(Pointer, $addr) !! Str;
    self.prep(IORING_OP_ACCEPT, $fd, $address, 0, $size);
    $!union-flags = $flags;
    self
  }

  method prep-connect(io_uring_sqe:D: $fd, sockaddr() $addr) {
    self.prep(IORING_OP_CONNECT, $fd, nativecast(Pointer, $addr), 0, $addr.size);
    self
  }

  method prep-send(io_uring_sqe:D: $fd, Pointer[void] $buf, Int $len, Int $flags) {
    self.prep(IORING_OP_SEND, $fd, $buf, $len, 0);
    $!union-flags = $flags;
    self
  }

  method prep-recv(io_uring_sqe:D: $fd, Pointer[void] $buf, Int $len, Int $flags) {
    self.prep(IORING_OP_RECV, $fd, $buf, $len, 0);
    $!union-flags = $flags;
    self
  }
}

class io_uring_cqe is repr('CStruct') is rw {
  has uint64 $.user_data; # data submission passed back
  has int32 $.res;        # result code for this event
  has uint32 $.flags;

  method clone(io_uring_cqe:D: --> io_uring_cqe) {
    return self.new(:$!user_data, :$!res, :$!flags);
  }
}

class io_uring_sq is repr('CStruct') {
  has Pointer[uint32] $.khead;
  has Pointer[uint32] $.ktail;
  has Pointer[uint32] $.kring_mask;
  has Pointer[uint32] $.kring_entries;
  has Pointer[uint32] $.kflags;
  has Pointer[uint32] $.kdropped;
  has Pointer[uint32] $.array;
  has io_uring_sqe $.sqes;
  has uint32 $.sqe_head;
  has uint32 $.sqe_tail;

  has size_t $.ring_sz;
  has Pointer $.ring_ptr;
}

class io_uring_cq is repr('CStruct') {
  has Pointer[uint32] $.khead;
  has Pointer[uint32] $.ktail;
  has Pointer[uint32] $.kring_mask;
  has Pointer[uint32] $.kring_entries;
  has Pointer[uint32] $.koverflow;
  has io_uring_cqe $.cqes;

  has size_t $.ring_sz;
  has Pointer $.ring_ptr;
}

class io_uring is repr('CStruct') {
  HAS io_uring_sq $.sq;
  HAS io_uring_cq $.cq;
  has uint32 $.flags;
  has int32 $.ring_fd;
  submethod TWEAK(:$entries!, :$flags, :$params) {
    $!sq := io_uring_sq.new;
    $!cq := io_uring_cq.new;
    if $params.defined {
      io_uring_queue_init_params($entries, self, $params);
    }
    else {
      io_uring_queue_init($entries, self, $flags);
    }
  }

  multi method new(io_uring:U: UInt :$entries = 128, :$flags = 0, io_uring_params :$params) {
    self.bless(:$entries, :$flags, :$params);
  }

  method close(\SELF: ) {
    io_uring_queue_exit(SELF);
    SELF = io_uring;
  }

  method submit(io_uring:D: ) {
    io_uring_submit(self);
  }

  method submit-and-wait(io_uring:D: uint32 $wait_nr) {
    io_uring_submit_and_wait(self, $wait_nr);
  }

  method wait(io_uring:D: ) {
    my Pointer[io_uring_cqe] $ptr .= new;
    my \ret = io_uring_wait_cqe(self, $ptr);
    if ret < 0 {
      my $failure = fail errno.symbol;
      set_errno(0);
      return $failure;
    }
    return $ptr;
  }

  method arm(io_uring:D: $eventfd) {
    my $sqe := io_uring_get_sqe(self);
    without $sqe {
      # If people are batching to the limit...
      io_uring_submit(self);
      $sqe := io_uring_get_sqe(self);
    }
    io_uring_prep_poll_add($sqe, $eventfd, POLLIN);
    $sqe.user_data = 0;
    self.submit-and-wait(1);
  }
}

# io_uring_register opcodes and arguments
enum IORING_REGISTER (
# linux 5.1
  IORING_REGISTER_BUFFERS => 0,
  IORING_UNREGISTER_BUFFERS => 1,
  IORING_REGISTER_FILES => 2,
  IORING_UNREGISTER_FILES => 3,
# linux 5.2
  IORING_REGISTER_EVENTFD => 4,
  IORING_UNREGISTER_EVENTFD => 5,
# linux 5.5
  IORING_REGISTER_FILES_UPDATE => 6,
  IORING_REGISTER_EVENTFD_ASYNC => 7,
# linux 5.6
  IORING_REGISTER_PROBE => 8,
  IORING_REGISTER_PERSONALITY => 9,
  IORING_UNREGISTER_PERSONALITY => 10,
);

sub _io_uring_queue_init_params(uint32 $entries, io_uring:D, io_uring_params:D) returns int32 is native(LIB) is symbol('io_uring_queue_init_params') { ... }

sub io_uring_queue_init_params(UInt $entries, io_uring:D $ring, io_uring_params:D $params) returns int32 {
  my uint32 $entries-u32 = $entries;
  my int32 $result = _io_uring_queue_init_params($entries-u32, $ring, $params);
  return $result < 0
  ?? do {
    fail "ring setup failed";
  }
  !! $result;
}

sub io_uring_queue_init(UInt $entries, io_uring:D $ring, UInt $flags) returns int32 {
  my uint32 $entries-u32 = $entries;
  my uint32 $flags-u32 = $flags;
  my int32 $result = _io_uring_queue_init($entries-u32, $ring, $flags-u32);
  return $result < 0
  ?? do {
    fail "ring setup failed";
  }
  !! $result;
}

sub _io_uring_queue_init(uint32 $entries, io_uring:D, uint32 $flags) returns int32
  is native(LIB) is symbol('io_uring_queue_init') { ... }

#sub io_uring_queue_mmap(int32 $fd, io_uring_params:D, io_uring:D) is native(LIB) { ... }

#sub io_uring_ring_dontfork(io_uring:D) is native(LIB) { ... }
sub io_uring_queue_exit(io_uring:D) is native(LIB) { ... }

sub io_uring_submit(|c) returns int32 {
  my int32 $result = _io_uring_submit(|c);
  return $result < 0
  ?? do {
    fail "sqe submit failed: $result";
  }
  !! $result
}

sub _io_uring_submit(io_uring:D --> int32) is native(LIB) is symbol('io_uring_submit') { ... }

sub _io_uring_submit_and_wait(io_uring:D, uint32 $wait_nr) is native(LIB) returns int32 is symbol('io_uring_submit_and_wait') { ... }

sub io_uring_submit_and_wait(|c) {
  my int32 $result = _io_uring_submit_and_wait(|c);
  return $result < 0
  ?? do {
    fail "sqe submit and wait failed: $result";
  }
  !! $result
}

sub io_uring_peek_batch_cqe(io_uring:D, Pointer[io_uring_cqe] is rw, uint32) returns uint32 is native(LIB) { ... }

#multi sub io_uring_wait_cqes(io_uring:D, io_uring_cqe is rw, kernel_timespec, sigset_t --> int32) is native(LIB) { ... }

#multi sub io_uring_wait_cqes(io_uring:D $ring, io_uring_cqe $sqe is rw, kernel_timespec $ts --> int32) {
#  my sigset_t $set .= new;
#  $set.fill;
#  io_uring_wait_cqes($ring, $sqe, $ts, $set);
#}

sub __io_uring_get_cqe(io_uring:D, Pointer[io_uring_cqe] is rw, uint32, uint32, Pointer) returns int32
  is native(LIB) { ... }

sub io_uring_wait_cqe_nr(io_uring:D \ring, Pointer[io_uring_cqe] $cqe-ptr is rw, uint32 \wait-nr) returns int32 {
  return __io_uring_get_cqe(ring, $cqe-ptr, 0, wait-nr, Pointer);
}

sub _io_uring_wait_cqe_timeout(io_uring:D, Pointer[io_uring_cqe] is rw, kernel_timespec) returns int32
  is native(LIB) is symbol('io_uring_wait_cqe_timeout') { ... }

sub io_uring_wait_cqe_timeout(|c) returns int32 {
  my int32 $result = _io_uring_wait_cqe_timeout(|c);
  return $result != 0
  ?? do {
    fail "io_uring_wait_cqe_timout=$result"
  }
  !! $result
}

sub _io_uring_get_sqe(io_uring:D) returns io_uring_sqe is native(LIB) is symbol('io_uring_get_sqe') { ... }

sub io_uring_get_sqe(io_uring:D $ring) returns io_uring_sqe {
  my $sqe := _io_uring_get_sqe($ring);
  $sqe.defined ?? $sqe !! Failure.new("Submission ring is out of room");
}

sub io_uring_wait_cqe(|c) {
  return io_uring_wait_cqe_timeout(|c, kernel_timespec);
}

sub io_uring_cqe_seen(io_uring:D $ring, io_uring_cqe:D $cqe) is native(%?RESOURCES<libraries/uringraku>) is symbol('io_uring_cqe_seen_wrapper') { ... }

sub io_uring_prep_rw(Int \op, io_uring_sqe:D $sqe, Int \fd, $addr, Int \len, Int \offset) {
  $sqe.opcode = op;
  $sqe.flags = 0;
  $sqe.ioprio = 0;
  $sqe.fd = fd;
  $sqe.off = offset;
  $sqe.addr = $addr.defined ?? +$addr !! 0;
  $sqe.len = len;
  $sqe.rw_flags: 0;
  $sqe.user_data = 0;
  $sqe.pad0 = $sqe.pad1 = $sqe.pad2 = 0;
}

sub io_uring_prep_nop(io_uring_sqe:D $sqe --> Nil) {
  io_uring_prep_rw(IORING_OP_NOP, $sqe, -1, Pointer, 0, 0);
}

sub io_uring_prep_readv(io_uring_sqe:D $sqe, $fd, Pointer $iovecs, UInt $nr_vecs, Int $offset --> Nil) {
  io_uring_prep_rw(IORING_OP_READV, $sqe, $fd, $iovecs, $nr_vecs, $offset);
}

sub io_uring_prep_writev(io_uring_sqe:D $sqe, $fd, Pointer $iovecs, UInt $nr_vecs, Int $offset --> Nil) {
  io_uring_prep_rw(IORING_OP_WRITEV, $sqe, $fd, $iovecs, $nr_vecs, $offset);
}

sub io_uring_prep_fsync(io_uring_sqe:D $sqe, $fd, UInt $fsync_flags --> Nil) {
  io_uring_prep_rw(IORING_OP_FSYNC, $sqe, $fd, Str, 0, 0);
  $sqe.union-flags = $fsync_flags +& 0xFFFFFFFF;
}

sub io_uring_prep_poll_add(io_uring_sqe:D $sqe, $fd, Int $poll_mask --> Nil) {
  io_uring_prep_rw(IORING_OP_POLL_ADD, $sqe, $fd, Str, 0, 0);
  $sqe.union-flags = $poll_mask +& 0xFFFF;
}

sub io_uring_prep_poll_remove(io_uring_sqe:D $sqe, Int $user_data --> Nil) {
  io_uring_prep_rw(IORING_OP_POLL_REMOVE, $sqe, -1, $user_data, 0, 0);
}

sub io_uring_prep_recvmsg(io_uring_sqe:D $sqe, $fd, Pointer $msg, uint32 $flags --> Nil) {
  io_uring_prep_rw(IORING_OP_RECVMSG, $sqe, $fd, $msg, 1, 0);
  $sqe.union-flags = $flags;
}

sub io_uring_prep_sendmsg(io_uring_sqe:D $sqe, $fd, Pointer $msg, uint32 $flags --> Nil) {
  io_uring_prep_rw(IORING_OP_SENDMSG, $sqe, $fd, $msg, 1, 0);
  $sqe.union-flags = $flags;
}

sub io_uring_prep_cancel(io_uring_sqe:D $sqe, UInt $flags, Int $user_data --> Nil) {
  io_uring_prep_rw(IORING_OP_ASYNC_CANCEL, $sqe, -1, $user_data, 0, 0);
  $sqe.union-flags = $flags;
}

sub io_uring_prep_accept(io_uring_sqe:D $sqe, $fd, $flags, $addr --> Nil) {
  my $size = $addr.defined ?? $addr.size !! 0;
  my $address = $addr.defined ?? nativecast(Pointer, $addr) !! Str;
  io_uring_prep_rw(IORING_OP_ACCEPT, $sqe, $fd, $address, 0, $size);
  $sqe.union-flags = $flags;
}

sub io_uring_prep_connect(io_uring_sqe:D $sqe, $fd, sockaddr() $addr --> Nil) {
  io_uring_prep_rw(IORING_OP_CONNECT, $sqe, $fd, nativecast(Pointer, $addr), 0, $addr.size);
}

sub io_uring_prep_send(io_uring_sqe:D $sqe, $fd, Pointer[void] $buf, Int $len, Int $flags ) {
  io_uring_prep_rw(IORING_OP_SEND, $sqe, $fd, $buf, $len, 0);
  $sqe.union-flags = $flags;
}

sub io_uring_prep_recv(io_uring_sqe:D $sqe, $fd, Pointer[void] $buf, Int $len, Int $flags ) {
  io_uring_prep_rw(IORING_OP_RECV, $sqe, $fd, $buf, $len, 0);
  $sqe.union-flags = $flags;
}

#multi sub io_uring_register_files(io_uring:D, Pointer[int32] $files, uint32 $num_files) returns int32 is native(LIB) { ... }

#multi sub io_uring_register_files(io_uring $ring, @files where .all.^can("native-descriptor"), uint32 $num_files) returns int32 {
#  my $arr = CArray[int32].new;
#  my $count = @files.elems;
#  for @files Z ^Inf -> $file, $i {
#    $arr[$i] = $file.native-descriptor;
#  }
#  io_uring_register_files($ring, nativecast(Pointer[int32], $arr), $count);
#}

sub io_uring_cqe_get_data(io_uring_cqe:D $cqe --> Pointer) { Pointer[void].new(+$cqe.user_data) }

sub io_uring_get_probe_ring(io_uring:D --> io_uring_probe) is native(LIB) { ... }

sub io_uring_get_probe( --> io_uring_probe) is native(LIB) { ... }

sub EXPORT() {
  my %constants = %(
    'IORING_SETUP' => IORING_SETUP,
    'IORING_FSYNC_DATASYNC' => IORING_FSYNC_DATASYNC,
    'IORING_SQ_NEED_WAKEUP' => IORING_SQ_NEED_WAKEUP,
    'IORING_OP' => IORING_OP,
    'IORING_FEAT' => IORING_FEAT,
    'IORING_REGISTER' => IORING_REGISTER,
    'IORING_TIMEOUT_ABS' => IORING_TIMEOUT_ABS,
    'IOSQE_BIT' => IOSQE_BIT,
    'IOSQE' => IOSQE,
    'POLLIN' => POLLIN,
    'POLLPRI' => POLLPRI,
    'POLLOUT' => POLLOUT,
    'POLLERR' => POLLERR,
    'POLLHUP' => POLLHUP,
    'POLLNVAL' => POLLNVAL,
  );
  my %export-types = %(
    'io_uring' => io_uring,
    'io_uring_cqe' => io_uring_cqe,
    'io_uring_sqe' => io_uring_sqe,
  );
  my %subs = %(
    '&io_uring_queue_init' => &io_uring_queue_init,
    '&io_uring_queue_init_params' => &io_uring_queue_init_params,
    '&io_uring_queue_exit' => &io_uring_queue_exit,
    '&io_uring_get_sqe' => &io_uring_get_sqe,
    '&io_uring_cqe_seen' => &io_uring_cqe_seen,
    '&io_uring_submit' => &io_uring_submit,
    '&io_uring_submit_and_wait' => &io_uring_submit_and_wait,
    '&io_uring_peek_batch_cqe' => &io_uring_peek_batch_cqe,
    '&io_uring_wait_cqe_timeout' => &io_uring_wait_cqe_timeout,
    '&io_uring_wait_cqe' => &io_uring_wait_cqe,
    '&io_uring_wait_cqe_nr' => &io_uring_wait_cqe_nr,
    '&io_uring_prep_nop' => &io_uring_prep_nop,
    '&io_uring_prep_readv' => &io_uring_prep_readv,
    '&io_uring_prep_writev' => &io_uring_prep_writev,
    '&io_uring_prep_fsync' => &io_uring_prep_fsync,
    '&io_uring_prep_poll_add' => &io_uring_prep_poll_add,
    '&io_uring_prep_poll_remove' => &io_uring_prep_poll_remove,
    '&io_uring_prep_sendmsg' => &io_uring_prep_sendmsg,
    '&io_uring_prep_recvmsg' => &io_uring_prep_recvmsg,
    '&io_uring_prep_cancel' => &io_uring_prep_cancel,
    '&io_uring_prep_accept' => &io_uring_prep_accept,
    '&io_uring_prep_connect' => &io_uring_prep_connect,
    '&io_uring_prep_send' => &io_uring_prep_send,
    '&io_uring_prep_recv' => &io_uring_prep_recv,
    '&io_uring_get_probe_ring' => &io_uring_get_probe_ring,
    '&io_uring_get_probe' => &io_uring_get_probe,
    '&eventfd' => &eventfd,
    '&eventfd_read' => &eventfd_read,
    '&eventfd_write' => &eventfd_write,
  );
  my %base = %(|%constants, |%subs, |%export-types);
  %base<%IO_URING_RAW_EXPORT> = %(|%constants, |%export-types);
  %base;
}
