my $version = Version.new($*KERNEL.release);

die "Must be loaded on Linux 5.1 or higher"
  unless $*KERNEL ~~ 'linux' && $version ~~ v5.1+;

use NativeCall;
#use Universal::errno;

my constant LIB = "uring";

# linux 5.1
my constant IORING_SETUP_IOPOLL = 1;     # (1U << 0)
my constant IORING_SETUP_SQPOLL = 2;     # (1U << 1)
my constant IORING_SETUP_SQ_AFF = 4;     # (1U << 2)
# linux 5.5
my constant IORING_SETUP_CQSIZE = 8;     # (1U << 3)
# linux 5.6
my constant IORING_SETUP_CLAMP = 16;     # (1U << 4)
my constant IORING_SETUP_ATTACH_WQ = 32; # (1U << 5)

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

# linux 5.1
my constant IOSQE_FIXED_FILE = 1;  # (1U << IOSQE_FIXED_FILE_BIT)
# linux 5.2
my constant IOSQE_IO_DRAIN = 2;   # (1U << IOSQE_IO_DRAIN_BIT)
# linux 5.3
my constant IOSQE_IO_LINK = 4;     # (1U << IOSQE_IO_LINK_BIT)
# linux 5.5
my constant IOSQE_IO_HARDLINK = 8; # (1U << IOSQE_IO_HARDLINK_BIT)
# linux 5.6
my constant IOSQE_ASYNC = 16;      # (1U << IOSQE_ASYNC_BIT)

#linux 5.6
my constant IOSQE_FIXED_FILE_BIT = 0;
my constant IOSQE_IO_DRAIN_BIT = 1;
my constant IOSQE_IO_LINK_BIT = 2;
my constant IOSQE_IO_HARDLINK_BIT = 3;
my constant IOSQE_ASYNC_BIT = 4;

# linux 5.1
my constant IORING_OP_NOP = 0;
my constant IORING_OP_READV = 1;
my constant IORING_OP_WRITEV = 2;
my constant IORING_OP_FSYNC = 3;
my constant IORING_OP_READ_FIXED = 4;
my constant IORING_OP_WRITE_FIXED = 5;
my constant IORING_OP_POLL_ADD = 6;
my constant IORING_OP_POLL_REMOVE = 7;
# linux 5.2
my constant IORING_OP_SYNC_FILE_RANGE = 8;
# linux 5.3
my constant IORING_OP_SENDMSG = 9;
my constant IORING_OP_RECVMSG = 10;
# linux 5.4
my constant IORING_OP_TIMEOUT = 11;
# linux 5.5
my constant IORING_OP_TIMEOUT_REMOVE = 12;
my constant IORING_OP_ACCEPT = 13;
my constant IORING_OP_ASYNC_CANCEL = 14;
my constant IORING_OP_LINK_TIMEOUT = 15;
my constant IORING_OP_CONNECT = 16;
# linux 5.6
my constant IORING_OP_FALLOCATE = 17;
my constant IORING_OP_OPENAT = 18;
my constant IORING_OP_CLOSE = 19;
my constant IORING_OP_FILES_UPDATE = 20;
my constant IORING_OP_STATX = 21;
my constant IORING_OP_READ = 22;
my constant IORING_OP_WRITE = 23;
my constant IORING_OP_FADVISE = 24;
my constant IORING_OP_MADVISE = 25;
my constant IORING_OP_SEND = 26;
my constant IORING_OP_RECV = 27;
my constant IORING_OP_OPENAT2 = 28;
my constant IORING_OP_EPOLL_CTL = 29;
# end

my constant IORING_ENTER_GETEVENTS = 1;
my constant IORING_ENTER_SQ_WAKEUP = 2;

sub free(Pointer) is native is export { ... }

sub memcpy(Pointer[void], Pointer[void], size_t) returns Pointer[void] is native is export {...}

sub malloc(size_t $size) returns Pointer[void] is native { ... }

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
  has uint32 $.pad0;
  has uint64 $.pad1;
  has uint64 $.pad2;

  multi method addr2() { self.off }

  multi method rw_flags() {
    nativecast(int32, self.union-flags);
  }
  multi method rw_flags(Int $flags) {
    self.union-flags = $flags;
  }
  method fsync_flags() {
    return self.union-flags;
  }
  method poll_events() {
    return self.union-flags +& 0x0000FFFF;
  }
  method sync_range_flags {
    return self.union-flags;
  }
  method msg_flags {
    return self.union-flags;
  }
  method timeout_flags {
    return self.union-flags;
  }
  method accept_flags {
    return self.union-flags;
  }
  method cancel_flags {
    return self.union-flags;
  }
  method open_flags {
    return self.union-flags;
  }
  method statx_flags {
    return self.union-flags;
  }
  method fadvise_advice {
    return self.union-flags;
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
  submethod TWEAK() {
    $!sq := io_uring_sq.new;
    $!cq := io_uring_cq.new;
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

# io_uring_register opcodes and arguments
# linux 5.1
my constant IORING_REGISTER_BUFFERS = 0;
my constant IORING_UNREGISTER_BUFFERS = 1;
my constant IORING_REGISTER_FILES = 2;
my constant IORING_UNREGISTER_FILES = 3;
# linux 5.2
my constant IORING_REGISTER_EVENTFD = 4;
my constant IORING_UNREGISTER_EVENTFD = 5;
# linux 5.5
my constant IORING_REGISTER_FILES_UPDATE = 6;
my constant IORING_REGISTER_EVENTFD_ASYNC = 7;
# linux 5.6
my constant IORING_REGISTER_PROBE = 8;
my constant IORING_REGISTER_PERSONALITY = 9;
my constant IORING_UNREGISTER_PERSONALITY = 10;

#linux 5.6
my constant IO_URING_OP_SUPPORTED = 1; # 1U << 0

sub _io_uring_queue_init_params(uint32 $entries, io_uring, io_uring_params) returns int32 is native(LIB) is symbol('io_uring_queue_init_params') { ... }

sub io_uring_queue_init_params(UInt $entries, io_uring $ring, io_uring_params $params) returns int32 {
  my uint32 $entries-u32 = $entries;
  my int32 $result = _io_uring_queue_init_params($entries-u32, $ring, $params);;
  return $result < 0
  ?? do {
    fail "ring setup failed";
  }
  !! $result;
}

sub io_uring_queue_init(UInt $entries, io_uring $ring, UInt $flags) returns int32 {
  my uint32 $entries-u32 = $entries;
  my uint32 $flags-u32 = $flags;
  my int32 $result = _io_uring_queue_init($entries-u32, $ring, $flags-u32);
  return $result < 0
  ?? do {
    fail "ring setup failed";
  }
  !! $result;
}

sub _io_uring_queue_init(uint32 $entries, io_uring, uint32 $flags) returns int32
  is native(LIB) is symbol('io_uring_queue_init') { ... }

#sub io_uring_queue_mmap(int32 $fd, io_uring_params, io_uring) is native(LIB) { ... }

#sub io_uring_ring_dontfork(io_uring) is native(LIB) { ... }
sub io_uring_queue_exit(io_uring) is native(LIB) { ... }

sub io_uring_submit(|c) returns int32 {
  my int32 $result = _io_uring_submit(|c);
  return $result != 1
  ?? do {
    fail "sqe submit failed: $result";
  }
  !! $result
}

sub _io_uring_submit(io_uring --> int32) is native(LIB) is symbol('io_uring_submit') { ... }

sub _io_uring_submit_and_wait(io_uring, uint32 $wait_nr) is native(LIB) is symbol('io_uring_submit_and_wait') { ... }

sub io_uring_submit_and_wait(|c) {
  my int32 $result = _io_uring_submit_and_wait(|c);
  return $result < 0
  ?? do {
    fail "sqe submit and wait failed: $result";
  }
  !! $result
}

sub io_uring_peek_batch_cqe(io_uring, Pointer[io_uring_cqe] is rw, uint32) returns uint32 is native(LIB) { ... }

#multi sub io_uring_wait_cqes(io_uring, io_uring_cqe is rw, kernel_timespec, sigset_t --> int32) is native(LIB) { ... }

#multi sub io_uring_wait_cqes(io_uring $ring, io_uring_cqe $sqe is rw, kernel_timespec $ts --> int32) {
#  my sigset_t $set .= new;
#  $set.fill;
#  io_uring_wait_cqes($ring, $sqe, $ts, $set);
#}

sub _io_uring_wait_cqe_timeout(io_uring, Pointer[io_uring_cqe] is rw, kernel_timespec) returns int32
  is native(LIB) is symbol('io_uring_wait_cqe_timeout') { ... }

sub io_uring_wait_cqe_timeout(|c) returns int32 {
  my int32 $result = _io_uring_wait_cqe_timeout(|c);
  return $result != 0
  ?? do {
    fail "io_uring_wait_cqe_timout=$result"
  }
  !! $result
}

sub io_uring_get_sqe(io_uring) returns io_uring_sqe is native(LIB) { ... }

sub io_uring_wait_cqe(|c) {
  return io_uring_wait_cqe_timeout(|c, kernel_timespec);
}

sub io_uring_advance(io_uring $ring, uint32 $nr) {
  if ($nr) {
    my io_uring_cq $cq = $ring.cq;
    repeat {
      my $arr = nativecast(CArray[uint32], $cq.khead);
      full-barrier();
      $arr[0] = $cq.khead.deref + $nr;
    } while (0);
  }
}

sub io_uring_cqe_seen(io_uring $ring, io_uring_cqe $cqe) {
  io_uring_advance($ring, 1) if ($cqe);
}

sub io_uring_prep_rw(Int \op, io_uring_sqe $sqe, Int \fd, $addr, Int \len, Int \offset) {
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

sub io_uring_prep_nop(io_uring_sqe $sqe --> Nil) {
  io_uring_prep_rw(IORING_OP_NOP, $sqe, -1, Pointer, 0, 0);
}

sub io_uring_prep_readv(io_uring_sqe $sqe, $fd, Pointer[size_t] $iovecs, UInt $nr_vecs, Int $offset --> Nil) {
  io_uring_prep_rw(IORING_OP_READV, $sqe, $fd, $iovecs, $nr_vecs, $offset);
}

sub io_uring_prep_writev(io_uring_sqe $sqe, $fd, Pointer[size_t] $iovecs, UInt $nr_vecs, Int $offset --> Nil) {
  io_uring_prep_rw(IORING_OP_WRITEV, $sqe, $fd, $iovecs, $nr_vecs, $offset);
}

sub io_uring_prep_fsync(io_uring_sqe $sqe, $fd, UInt $fsync_flags --> Nil) {
  io_uring_prep_rw(IORING_OP_FSYNC, $sqe, $fd, Str, 0, 0);
  $sqe.union-flags = $fsync_flags +& 0xFFFFFFFF;
}

# specified by iBCS2
my constant POLLIN =   0x0001;
my constant POLLPRI =  0x0002;
my constant POLLOUT =  0x0004;
my constant POLLERR =  0x0008;
my constant POLLHUP =  0x0010;
my constant POLLNVAL = 0x0020;

sub io_uring_prep_poll_add(io_uring_sqe $sqe, $fd, Int $poll_mask --> Nil) {
  io_uring_prep_rw(IORING_OP_POLL_ADD, $sqe, $fd, Str, 0, 0);
  $sqe.union-flags = $poll_mask +& 0xFFFF;
}

sub io_uring_prep_poll_remove(io_uring_sqe $sqe, Int $user_data --> Nil) {
  io_uring_prep_rw(IORING_OP_POLL_REMOVE, $sqe, -1, $user_data, 0, 0);
}

sub io_uring_prep_cancel(io_uring_sqe $sqe, UInt $flags, Int $user_data --> Nil) {
  io_uring_prep_rw(IORING_OP_ASYNC_CANCEL, $sqe, -1, $user_data, 0, 0);
  $sqe.union-flags = $flags;
}

#multi sub io_uring_register_files(io_uring, Pointer[int32] $files, uint32 $num_files) returns int32 is native(LIB) { ... }

#multi sub io_uring_register_files(io_uring $ring, @files where .all.^can("native-descriptor"), uint32 $num_files) returns int32 {
#  my $arr = CArray[int32].new;
#  my $count = @files.elems;
#  for @files Z ^Inf -> $file, $i {
#    $arr[$i] = $file.native-descriptor;
#  }
#  io_uring_register_files($ring, nativecast(Pointer[int32], $arr), $count);
#}

sub io_uring_cqe_get_data(io_uring_cqe $cqe --> Pointer) { Pointer[void].new(+$cqe.user_data) }

# Older versions of the kernel can crash when attempting to use features
# that are from later versions. Control EXPORT to prevent that.
sub EXPORT() {
  my %constants = %(
    'IORING_SETUP_IOPOLL' => IORING_SETUP_IOPOLL,
    'IORING_SETUP_SQPOLL' => IORING_SETUP_SQPOLL,
    'IORING_SETUP_SQ_AFF' => IORING_SETUP_SQ_AFF,
    'IORING_SETUP_CQSIZE' => IORING_SETUP_CQSIZE,
    'IORING_SETUP_CLAMP' => IORING_SETUP_CLAMP,
    'IORING_SETUP_ATTACH_WQ' => IORING_SETUP_ATTACH_WQ,
    'IORING_FSYNC_DATASYNC' => IORING_FSYNC_DATASYNC,
    'IORING_SQ_NEED_WAKEUP' => IORING_SQ_NEED_WAKEUP,
    'IORING_OP_NOP' => IORING_OP_NOP,
    'IORING_OP_READV' => IORING_OP_READV,
    'IORING_OP_WRITEV' => IORING_OP_WRITEV,
    'IORING_OP_FSYNC' => IORING_OP_FSYNC,
    'IORING_OP_READ_FIXED' => IORING_OP_READ_FIXED,
    'IORING_OP_WRITE_FIXED' => IORING_OP_WRITE_FIXED,
    'IORING_OP_POLL_ADD' => IORING_OP_POLL_ADD,
    'IORING_OP_POLL_REMOVE' => IORING_OP_POLL_REMOVE,
    'IORING_OP_TIMEOUT' => IORING_OP_TIMEOUT,
    'IORING_OP_SYNC_FILE_RANGE' => IORING_OP_SYNC_FILE_RANGE,
    'IORING_OP_SENDMSG' => IORING_OP_SENDMSG,
    'IORING_OP_RECVMSG' => IORING_OP_RECVMSG,
    'IORING_OP_TIMEOUT_REMOVE' => IORING_OP_TIMEOUT_REMOVE,
    'IORING_OP_ACCEPT' => IORING_OP_ACCEPT,
    'IORING_OP_ASYNC_CANCEL' => IORING_OP_ASYNC_CANCEL,
    'IORING_OP_LINK_TIMEOUT' => IORING_OP_LINK_TIMEOUT,
    'IORING_OP_CONNECT' => IORING_OP_CONNECT,
    'IORING_OP_FALLOCATE' => IORING_OP_FALLOCATE,
    'IORING_OP_OPENAT' => IORING_OP_OPENAT,
    'IORING_OP_CLOSE' => IORING_OP_CLOSE,
    'IORING_OP_FILES_UPDATE' => IORING_OP_FILES_UPDATE,
    'IORING_OP_STATX' => IORING_OP_STATX,
    'IORING_OP_READ' => IORING_OP_READ,
    'IORING_OP_WRITE' => IORING_OP_WRITE,
    'IORING_OP_FADVISE' => IORING_OP_FADVISE,
    'IORING_OP_MADVISE' => IORING_OP_MADVISE,
    'IORING_OP_SEND' => IORING_OP_SEND,
    'IORING_OP_RECV' => IORING_OP_RECV,
    'IORING_OP_OPENAT2' => IORING_OP_OPENAT2,
    'IORING_OP_EPOLL_CTL' => IORING_OP_EPOLL_CTL,
    'IOSQE_IO_DRAIN' => IOSQE_IO_DRAIN,
    'IOSQE_IO_LINK' => IOSQE_IO_LINK,
    'IOSQE_IO_HARDLINK' => IOSQE_IO_HARDLINK,
    'IOSQE_ASYNC' => IOSQE_ASYNC,
    'IORING_FEAT' => IORING_FEAT,
    'IORING_FEAT_SINGLE_MMAP' => IORING_FEAT::SINGLE_MMAP,
    'IORING_FEAT_NODROP' => IORING_FEAT::NODROP,
    'IORING_FEAT_SUBMIT_STABLE' => IORING_FEAT::SUBMIT_STABLE,
    'IORING_REGISTER_BUFFERS' => IORING_REGISTER_BUFFERS,
    'IORING_UNREGISTER_BUFFERS' => IORING_UNREGISTER_BUFFERS,
    'IORING_REGISTER_FILES' => IORING_REGISTER_FILES,
    'IORING_UNREGISTER_FILES' => IORING_UNREGISTER_FILES,
    'IORING_REGISTER_FILES_UPDATE' => IORING_REGISTER_FILES_UPDATE,
    'IORING_REGISTER_EVENTFD_ASYNC' => IORING_REGISTER_EVENTFD_ASYNC,
    'IORING_REGISTER_EVENTFD' => IORING_REGISTER_EVENTFD,
    'IORING_UNREGISTER_EVENTFD' => IORING_UNREGISTER_EVENTFD,
    'IORING_TIMEOUT_ABS' => IORING_TIMEOUT_ABS,
    'IOSQE_FIXED_FILE' => IOSQE_FIXED_FILE,
    'IOSQE_ASYNC' => IOSQE_ASYNC,
    'IOSQE_FIXED_FILE_BIT' => IOSQE_FIXED_FILE_BIT,
    'IOSQE_IO_DRAIN_BIT' => IOSQE_IO_DRAIN_BIT,
    'IOSQE_IO_LINK_BIT' => IOSQE_IO_LINK_BIT,
    'IOSQE_IO_HARDLINK_BIT' => IOSQE_IO_HARDLINK_BIT,
    'IOSQE_ASYNC_BIT' => IOSQE_ASYNC_BIT,
    'POLLIN' => POLLIN,
    'POLLPRI' => POLLPRI,
    'POLLOUT' => POLLOUT,
    'POLLERR' => POLLERR,
    'POLLHUP' => POLLHUP,
    'POLLNVAL' => POLLNVAL,
  );
  my %types = %(
    'iovec' => iovec,
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
    '&io_uring_peek_batch_cqe' => &io_uring_peek_batch_cqe,
    '&io_uring_wait_cqe_timeout' => &io_uring_wait_cqe_timeout,
    '&io_uring_wait_cqe' => &io_uring_wait_cqe,
    '&io_uring_prep_nop' => &io_uring_prep_nop,
    '&io_uring_prep_readv' => &io_uring_prep_readv,
    '&io_uring_prep_writev' => &io_uring_prep_writev,
    '&io_uring_prep_fsync' => &io_uring_prep_fsync,
    '&io_uring_prep_poll_add' => &io_uring_prep_poll_add,
    '&io_uring_prep_poll_remove' => &io_uring_prep_poll_remove,
    '&io_uring_prep_cancel' => &io_uring_prep_cancel,
  );
  my %base = %(|%constants, |%types, |%subs, |%export-types);
  %base<%IO_URING_RAW_EXPORT> = %(|%constants, |%export-types);
  %base;
}
