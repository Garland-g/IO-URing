use NativeCall;
#use Universal::errno;

constant LIB = "uring";

constant __NR_io_uring_setup = 535;
constant __NR_io_uring_enter = 536;
constant __NR_io_uring_register = 537;

# linux 5.1
constant IORING_SETUP_IOPOLL = 1;     # (1U << 0)
constant IORING_SETUP_SQPOLL = 2;     # (1U << 1)
constant IORING_SETUP_SQ_AFF = 4;     # (1U << 2)
# linux 5.5
constant IORING_SETUP_CQSIZE = 8;     # (1U << 3)
# linux 5.6
constant IORING_SETUP_CLAMP = 16;     # (1U << 4)
constant IORING_SETUP_ATTACH_WQ = 32; # (1U << 5)

#linux 5.1
constant IORING_FSYNC_DATASYNC = 1; #fsync_flags

#linux 5.5
constant IORING_TIMEOUT_ABS = 1; #timeout_flags

#linux 5.1
constant IORING_OFF_SQ_RING = 0;
constant IORING_OFF_CQ_RING = 0x8000000;
constant IORING_OFF_SQES    = 0x10000000;

#linux 5.1
constant IORING_SQ_NEED_WAKEUP = 1;

# linux 5.1
constant IOSQE_FIXED_FILE = 1;  # (1U << IOSQE_FIXED_FILE_BIT)
# linux 5.2
constant IOSQE_IO_DRAIN = 2;    # (1U << IOSQE_IO_DRAIN_BIT)
# linux 5.3
constant IOSQE_IO_LINK = 4;     # (1U << IOSQE_IO_LINK_BIT)
# linux 5.5
constant IOSQE_IO_HARDLINK = 8; # (1U << IOSQE_IO_HARDLINK_BIT)
# linux 5.6
constant IOSQE_ASYNC = 16;      # (1U << IOSQE_ASYNC_BIT)

#linux 5.6
constant IOSQE_FIXED_FILE_BIT = 0;
constant IOSQE_IO_DRAIN_BIT = 1;
constant IOSQE_IO_LINK_BIT = 2;
constant IOSQE_IO_HARDLINK_BIT = 3;
constant IOSQE_ASYNC_BIT = 4;

# linux 5.1
constant IORING_OP_NOP = 0;
constant IORING_OP_READV = 1;
constant IORING_OP_WRITEV = 2;
constant IORING_OP_FSYNC = 3;
constant IORING_OP_READ_FIXED = 4;
constant IORING_OP_WRITE_FIXED = 5;
constant IORING_OP_POLL_ADD = 6;
constant IORING_OP_POLL_REMOVE = 7;
# linux 5.2
constant IORING_OP_SYNC_FILE_RANGE = 8;
# linux 5.3
constant IORING_OP_SENDMSG = 9;
constant IORING_OP_RECVMSG = 10;
# linux 5.4
constant IORING_OP_TIMEOUT = 11;
# linux 5.5
constant IORING_OP_TIMEOUT_REMOVE = 12;
constant IORING_OP_ACCEPT = 13;
constant IORING_OP_ASYNC_CANCEL = 14;
constant IORING_OP_LINK_TIMEOUT = 15;
constant IORING_OP_CONNECT = 16;
# linux 5.6
constant IORING_OP_FALLOCATE = 17;
constant IORING_OP_OPENAT = 18;
constant IORING_OP_CLOSE = 19;
constant IORING_OP_FILES_UPDATE = 20;
constant IORING_OP_STATX = 21;
constant IORING_OP_READ = 22;
constant IORING_OP_WRITE = 23;
constant IORING_OP_FADVISE = 24;
constant IORING_OP_MADVISE = 25;
constant IORING_OP_SEND = 26;
constant IORING_OP_RECV = 27;
constant IORING_OP_OPENAT2 = 28;
constant IORING_OP_EPOLL_CTL = 29;
constant IORING_OP_LAST = 30;
# end

constant IORING_ENTER_GETEVENTS = 1;
constant IORING_ENTER_SQ_WAKEUP = 2;

sub free(Pointer) is native is export { ... }

#TODO This class is here for type-safety purposes, but does not function
# properly. Currently is only being used as a nativecast type target.
class iovec is repr('CStruct') is rw is export {
  has Pointer $.iov_base;
  has size_t $.iov_len;

  submethod BUILD(Pointer:D :$iov_base, Int:D :$iov_len) {
    $!iov_base := $iov_base;
    $!iov_len = $iov_len;
  }

  multi method new(Buf $buf --> iovec) {
    self.bless(iov_base => nativecast(Pointer, $buf), iov_len => $buf.bytes);
  }

  multi method new(Pointer:D :$iov_base, Int:D :$iov_len) {
    self.bless(:$iov_base, :$iov_len);
  }

  method Buf {
    my buf8 $buf .= new;
    my $arr = nativecast(Pointer[CArray[int8]], self);
    for ^$!iov_len {
      $buf.write-int8($_, $arr[$_]);
    }
    $buf;
  }

  method Numeric {
    return +nativecast(Pointer, self);
  }
}

class kernel_timespec is repr('CStruct') is rw is export {
  has uint64 $tv_sec;
  has uint64 $tv_nsec;
}

class io_uring_sqe is repr('CStruct') is rw is export {
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

class io_uring_cqe is repr('CStruct') is rw is export {
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

class io_uring is repr('CStruct') is export {
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
  has uint32 $.cq_entries;
  has uint32 $.flags;
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
# linux 5.4
constant IORING_FEAT_SINGLE_MMAP is export = 1;      # 1U << 0
# linux 5.5
constant IORING_FEAT_NODROP is export = 2;           # 1U << 1
constant IORING_FEAT_SUBMIT_STABLE is export = 4;    # 1U << 2
# linux 5.6
constant IORING_FEAT_RW_CUR_POS is export = 8;       # 1U << 3
constant IORING_FEAT_CUR_PERSONALITY is export = 16; # 1U << 4
#TODO # linux 5.7?
constant IORING_FEAT_FAST_POLL is export = 32;       # 1U << 5

# io_uring_register opcodes and arguments
# linux 5.4
constant IORING_REGISTER_BUFFERS = 0;
constant IORING_UNREGISTER_BUFFERS = 1;
constant IORING_REGISTER_FILES = 2;
constant IORING_UNREGISTER_FILES = 3;
constant IORING_REGISTER_EVENTFD = 4;
constant IORING_UNREGISTER_EVENTFD = 5;
# linux 5.5
constant IORING_REGISTER_FILES_UPDATE = 6;
constant IORING_REGISTER_EVENTFD_ASYNC = 7;
# linux 5.6
constant IORING_REGISTER_PROBE = 8;
constant IORING_REGISTER_PERSONALITY = 9;
constant IORING_UNREGISTER_PERSONALITY = 10;

multi sub io_uring_queue_init(UInt $entries, io_uring $ring, UInt $flags) returns int32 is export {
  my uint32 $entries-u32 = $entries;
  my uint32 $flags-u32 = $flags;
  my int32 $result = _io_uring_queue_init($entries-u32, $ring, $flags-u32);
  return $result < 0
  ?? do {
    fail "ring setup failed";
  }
  !! $result;
}

multi sub _io_uring_queue_init(uint32 $entries, io_uring, uint32 $flags) returns int32 is native(LIB) is symbol('io_uring_queue_init') is export(:_io_uring_queue_init) { ... }

sub io_uring_queue_exit(io_uring) is native(LIB) is export { ... }

multi sub io_uring_submit(|c) returns int32 is export {
  my int32 $result = _io_uring_submit(|c);
  return $result != 1
  ?? do {
    fail "sqe submit failed: $result";
  }
  !! $result
}

multi sub _io_uring_submit(io_uring --> int32) is native(LIB) is symbol('io_uring_submit') is export(:_io_uring_queue_init) { ... }

multi sub _io_uring_submit_and_wait(io_uring, uint32 $wait_nr) is native(LIB) is symbol('io_uring_submit_and_wait') { ... }

multi sub io_uring_submit_and_wait(|c) is export {
  my int32 $result = _io_uring_submit_and_wait(|c);
  return $result < 0
  ?? do {
    fail "sqe submit and wait failed: $result";
  }
  !! $result
}

multi sub _io_uring_wait_cqe_timeout(io_uring, Pointer[io_uring_cqe] is rw, kernel_timespec) returns int32 is native(LIB) is symbol('io_uring_wait_cqe_timeout') is export(:_io_uring_wait_cqe_timeout) { ... }

multi sub io_uring_wait_cqe_timeout(|c) returns int32 is export {
  my int32 $result = _io_uring_wait_cqe_timeout(|c);
  return $result != 0
  ?? do {
    fail "io_uring_wait_cqe_timout=$result"
  }
  !! $result
}

sub io_uring_get_sqe(io_uring) returns io_uring_sqe is native(LIB) is symbol('io_uring_get_sqe') is export { ... }

sub io_uring_wait_cqe(|c) is export {
  return io_uring_wait_cqe_timeout(|c, kernel_timespec);
}

sub io_uring_advance(io_uring $ring, uint32 $nr) is export {
  if ($nr) {
    my io_uring_cq $cq = $ring.cq;
    repeat {
      my $arr = nativecast(CArray[uint32], $cq.khead);
      $arr[0] = $cq.khead.deref + $nr;
    } while (0);
  }
}

sub io_uring_cqe_seen(io_uring $ring, io_uring_cqe $cqe) is export {
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

sub io_uring_prep_nop(io_uring_sqe $sqe, $user_data = 0) is export {
  io_uring_prep_rw(IORING_OP_NOP, $sqe, -1, Pointer, 0, 0);
  $sqe.user_data = $user_data if $user_data;
}

sub io_uring_prep_readv(io_uring_sqe $sqe, $fd, iovec $iovecs, UInt $nr_vecs, Int $offset, Int $user_data = 0) is export {
  io_uring_prep_rw(IORING_OP_READV, $sqe, $fd, $iovecs, $nr_vecs, $offset);
  $sqe.user_data = $user_data if $user_data;
}

sub io_uring_prep_writev(io_uring_sqe $sqe, $fd, iovec $iovecs, UInt $nr_vecs, Int $offset, Int $user_data = 0) is export {
  io_uring_prep_rw(IORING_OP_WRITEV, $sqe, $fd, $iovecs, $nr_vecs, $offset);
  $sqe.user_data = $user_data if $user_data;
}

sub io_uring_cqe_get_data(io_uring_cqe $cqe --> Pointer) is export { Pointer[void].new(+$cqe.user_data) }

