use NativeCall;
use Universal::errno;

constant LIB = "uring";

constant IORING_OP_NOP = 0;

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
constant IORING_FEAT_SINGLE_MMAP is export = 1;
constant IORING_FEAT_NODROP is export = 2;
constant IORING_FEAT_SUBMIT_STABLE is export = 4;
constant IORING_FEAT_RW_CUR_POS is export = 8;
constant IORING_FEAT_CUR_PERSONALITY is export = 16;

# io_uring_register opcodes and arguments
constant IORING_REGISTER_BUFFERS = 0;
constant IORING_UNREGISTER_BUFFERS = 1;
constant IORING_REGISTER_FILES = 2;
constant IORING_UNREGISTER_FILES = 3;
constant IORING_REGISTER_EVENTFD = 4;
constant IORING_UNREGISTER_EVENTFD = 5;
constant IORING_REGISTER_FILES_UPDATE = 6;
constant IORING_REGISTER_EVENTFD_ASYNC = 7;
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

sub io_uring_wait_cqe_timeout(io_uring, Pointer[io_uring_cqe] is rw, kernel_timespec) is native(LIB) is export { ... }

sub io_uring_get_sqe(io_uring) returns io_uring_sqe is native(LIB) is export { ... }

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

sub io_uring_prep_nop(io_uring_sqe $sqe, $user_data) is export {
  io_uring_prep_rw(IORING_OP_NOP, $sqe, -1, Pointer, 0, 0);
  $sqe.user_data = $user_data;
}

sub io_uring_cqe_get_data(io_uring_cqe $cqe --> Pointer) is export { Pointer[void].new(+$cqe.user_data) }
