unit module IO::URing::LogTimelineSchema;

use Log::Timeline;

use IO::URing::Raw;

class RingClose does Log::Timeline::Event['IO::URing', 'Ring', 'RingClose'] {}

class RingSubmit does Log::Timeline::Event['IO::URing', 'Ring', 'RingSubmit'] {}

class Submit does Log::Timeline::Task['IO::URing', 'Submission', 'Submit'] {}

class Receive does Log::Timeline::Task['IO::URing', 'Submission', 'Receive'] {}

class Arm does Log::Timeline::Task['IO::URing', 'Submission', 'Arm'] {}

module Op {

  class NoOp does Log::Timeline::Task['IO::URing', 'Operation', 'NoOp'] {}

  class ReadV does Log::Timeline::Task['IO::URing', 'Operation', 'ReadV'] {}

  class WriteV does Log::Timeline::Task['IO::URing', 'Operation', 'WriteV'] {}

  class FSync does Log::Timeline::Task['IO::URing', 'Operation', 'FSync'] {}

  class ReadFixed does Log::Timeline::Task['IO::URing', 'Operation', 'ReadFixed'] {}

  class WriteFixed does Log::Timeline::Task['IO::URing', 'Operation', 'WriteFixed'] {}

  class PollAdd does Log::Timeline::Task['IO::URing', 'Operation', 'PollAdd'] {}

  class PollRemove does Log::Timeline::Task['IO::URing', 'Operation', 'PollRemove'] {}

  class SyncFileRange does Log::Timeline::Task['IO::URing', 'Operation', 'SyncFileRange'] {}

  class SendMsg does Log::Timeline::Task['IO::URing', 'Operation', 'SendMsg'] {}

  class RecvMsg does Log::Timeline::Task['IO::URing', 'Operation', 'RecvMsg'] {}

  class Timeout does Log::Timeline::Task['IO::URing', 'Operation', 'Timeout'] {}

  class TimeoutRemove does Log::Timeline::Task['IO::URing', 'Operation', 'TimeoutRemove'] {}

  class Accept does Log::Timeline::Task['IO::URing', 'Operation', 'Accept'] {}

  class AsyncCancel does Log::Timeline::Task['IO::URing', 'Operation', 'AsyncCancel'] {}

  class LinkTimeout does Log::Timeline::Task['IO::URing', 'Operation', 'LinkTimeout'] {}

  class Connect does Log::Timeline::Task['IO::URing', 'Operation', 'Connect'] {}

  class FAllocate does Log::Timeline::Task['IO::URing', 'Operation', 'FAllocate'] {}

  class OpenAt does Log::Timeline::Task['IO::URing', 'Operation', 'OpenAt'] {}

  class Close does Log::Timeline::Task['IO::URing', 'Operation', 'Close'] {}

  class FilesUpdate does Log::Timeline::Task['IO::URing', 'Operation', 'FilesUpdate'] {}

  class StatX does Log::Timeline::Task['IO::URing', 'Operation', 'StatX'] {}

  class Read does Log::Timeline::Task['IO::URing', 'Operation', 'Read'] {}

  class Write does Log::Timeline::Task['IO::URing', 'Operation', 'Write'] {}

  class FAdvise does Log::Timeline::Task['IO::URing', 'Operation', 'FAdvise'] {}

  class MAdvise does Log::Timeline::Task['IO::URing', 'Operation', 'MAdvise'] {}

  class Send does Log::Timeline::Task['IO::URing', 'Operation', 'Send'] {}

  class Recv does Log::Timeline::Task['IO::URing', 'Operation', 'Recv'] {}

  class OpenAt2 does Log::Timeline::Task['IO::URing', 'Operation', 'OpenAt2'] {}

  class EpollCtl does Log::Timeline::Task['IO::URing', 'Operation', 'EpollCtl'] {}

  class Splice does Log::Timeline::Task['IO::URing', 'Operation', 'Splice'] {}

  class ProvideBuffers does Log::Timeline::Task['IO::URing', 'Operation', 'ProvideBuffers'] {}

  class RemoveBuffers does Log::Timeline::Task['IO::URing', 'Operation', 'RemoveBuffers'] {}

  class Tee does Log::Timeline::Task['IO::URing', 'Operation', 'Tee'] {}

  class Shutdown does Log::Timeline::Task['IO::URing', 'Operation', 'Shutdown'] {}

  class RenameAt does Log::Timeline::Task['IO::URing', 'Operation', 'RenameAt'] {}

  class UnlinkAt does Log::Timeline::Task['IO::URing', 'Operation', 'RenameAt'] {}

  class MkdirAt does Log::Timeline::Task['IO::URing', 'Operation', 'MkdirAt'] {}
}

my constant op-hash = %{
  IORING_OP_NOP.Int => IO::URing::LogTimelineSchema::Op::NoOp,
  IORING_OP_READV.Int => IO::URing::LogTimelineSchema::Op::ReadV,
  IORING_OP_WRITEV.Int => IO::URing::LogTimelineSchema::Op::WriteV,
  IORING_OP_FSYNC.Int => IO::URing::LogTimelineSchema::Op::FSync,
  IORING_OP_READ_FIXED.Int => IO::URing::LogTimelineSchema::Op::ReadFixed,
  IORING_OP_WRITE_FIXED.Int => IO::URing::LogTimelineSchema::Op::WriteFixed,
  IORING_OP_POLL_ADD.Int => IO::URing::LogTimelineSchema::Op::PollAdd,
  IORING_OP_POLL_REMOVE.Int => IO::URing::LogTimelineSchema::Op::PollRemove,
  IORING_OP_SYNC_FILE_RANGE.Int => IO::URing::LogTimelineSchema::Op::SyncFileRange,
  IORING_OP_SENDMSG.Int => IO::URing::LogTimelineSchema::Op::SendMsg,
  IORING_OP_RECVMSG.Int => IO::URing::LogTimelineSchema::Op::RecvMsg,
  IORING_OP_TIMEOUT.Int => IO::URing::LogTimelineSchema::Op::Timeout,
  IORING_OP_TIMEOUT_REMOVE.Int => IO::URing::LogTimelineSchema::Op::TimeoutRemove,
  IORING_OP_ACCEPT.Int => IO::URing::LogTimelineSchema::Op::Accept,
  IORING_OP_ASYNC_CANCEL.Int => IO::URing::LogTimelineSchema::Op::AsyncCancel,
  IORING_OP_LINK_TIMEOUT.Int => IO::URing::LogTimelineSchema::Op::LinkTimeout,
  IORING_OP_CONNECT.Int => IO::URing::LogTimelineSchema::Op::Connect,
  IORING_OP_FALLOCATE.Int => IO::URing::LogTimelineSchema::Op::FAllocate,
  IORING_OP_OPENAT.Int => IO::URing::LogTimelineSchema::Op::OpenAt,
  IORING_OP_CLOSE.Int => IO::URing::LogTimelineSchema::Op::Close,
  IORING_OP_FILES_UPDATE.Int => IO::URing::LogTimelineSchema::Op::FilesUpdate,
  IORING_OP_STATX.Int => IO::URing::LogTimelineSchema::Op::StatX,
  IORING_OP_READ.Int => IO::URing::LogTimelineSchema::Op::Read,
  IORING_OP_WRITE.Int => IO::URing::LogTimelineSchema::Op::Write,
  IORING_OP_FADVISE.Int => IO::URing::LogTimelineSchema::Op::FAdvise,
  IORING_OP_MADVISE.Int => IO::URing::LogTimelineSchema::Op::MAdvise,
  IORING_OP_SEND.Int => IO::URing::LogTimelineSchema::Op::Send,
  IORING_OP_RECV.Int => IO::URing::LogTimelineSchema::Op::Recv,
  IORING_OP_OPENAT2.Int => IO::URing::LogTimelineSchema::Op::OpenAt2,
  IORING_OP_EPOLL_CTL.Int => IO::URing::LogTimelineSchema::Op::EpollCtl,
}

sub opcode-to-operation(Int $opcode) is export {
  return op-hash{$opcode};
}

