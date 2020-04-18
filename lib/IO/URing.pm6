use v6;
use IO::URing::Raw;
use NativeCall;

class IO::URing:ver<0.0.1>:auth<cpan:GARLANDG> {
  my enum STORAGE <EMPTY>;

  my class Completion {
    has $.data;
    has io_uring_sqe $.request;
    has Int $.result;
    has Int $.flags;
  }

  my class Handle is Promise {
    trusts IO::URing;
    has Int $!slot;
    method !slot(--> Int) is rw { $!slot }
  }

  my class Submission {
    has int $.opcode = 0;
    has int $.flags = 0;
    has uint $.ioprio = 0;
    has int $.fd = -1;
    has uint $.off = 0;
    has uint $.addr = 0;
    has uint $.len = 0;
    has uint $.union-flags = 0;
    has uint $.buf_index = 0;
    has uint $.personality = 0;
    has $.data;
    has &.then;
  }

  my \tweak-flags = IORING_SETUP_CLAMP;

  has io_uring $!ring .= new;
  has io_uring_params $!params .= new;
  has Lock::Async $!ring-lock .= new;
  has Lock::Async $!storage-lock .= new;
  has @!storage is default(STORAGE::EMPTY);

  submethod TWEAK(UInt :$entries!, UInt :$flags = tweak-flags, Int :$cq-size, Int :$at-once = 1) {
    $!params.flags = $flags;
    if $cq-size.defined && $cq-size >= $entries {
      given log2($cq-size) {
        $cq-size = 2^($_ + 1) unless $_ ~~ Int;
      }
      $!params.flags +|= IORING_SETUP_CQSIZE;
      $!params.cq_entries = $cq-size;
    }
    my $result = io_uring_queue_init_params($entries, $!ring, $!params);
    start {
      loop {
        my Pointer[io_uring_cqe] $cqe_ptr .= new;
        my $completed := io_uring_peek_batch_cqe($!ring, $cqe_ptr, $at-once);
        unless +$cqe_ptr {
          Thread.yield;
          next;
        }
        my io_uring_cqe $temp := $cqe_ptr.deref;
        my ($vow, $request, $data) = self!retrieve($temp.user_data);
        my $flags = $temp.flags;
        my $result = $temp.res;
        io_uring_cqe_seen($!ring, $cqe_ptr.deref);
        my $cmp = Completion.new(:$data, :$request, :$result, :$flags);
        $vow.keep($cmp);
      }
      CATCH {
        default {
          die $_;
        }
      }
    }
  }

  submethod DESTROY() {
    if $!ring ~~ io_uring:D {
      $!ring-lock.protect: { io_uring_queue_exit($!ring) };
    }
  }

  method close() {
    if $!ring ~~ io_uring:D {
      $!ring-lock.protect: { io_uring_queue_exit($!ring) };
      $!ring = io_uring;
    }
  }

  method features() {
    do for IORING_FEAT.enums { .key if $!params.features +& .value }
  }

  my sub to-read-buf($item is rw, :$enc) {
    return $item if $item ~~ Blob;
    die "Must pass a Blob";
  }

  my sub to-read-bufs(@items, :$enc) {
    @items .= map(&to-read-buf, :$enc);
  }

  my sub to-write-buf($item, :$enc) {
    return $item if $item ~~ Blob;
    return $item.encode($enc) if $item ~~ Str;
    return $item.Blob // fail "Don't know how to make $item.^name into a Blob";
  }

  my sub to-write-bufs(@items, :$enc) {
    @items.map(&to-write-buf, :$enc);
  }

  method !store($vow, io_uring_sqe $sqe, $user_data --> Int) {
    my Int $slot = 0;
    $!storage-lock.protect: {
      until @!storage[$slot] ~~ STORAGE::EMPTY { $slot++ }
      @!storage[$slot] = ($vow, $sqe, $user_data);
    };
    $slot;
  }

  method !retrieve(Int $slot) {
    my $tmp;
    $!storage-lock.protect: {
      $tmp = @!storage[$slot];
      @!storage[$slot] = STORAGE::EMPTY;
    };
    return $tmp;
  }

  method !submit(io_uring_sqe $sqe is rw, :$drain, :$link, :$hard-link, :$force-async) {
    $sqe.flags +|= IOSQE_IO_LINK if $link;
    $sqe.flags +|= IOSQE_IO_DRAIN if $drain;
    $sqe.flags +|= IOSQE_IO_HARDLINK if $hard-link;
    $sqe.flags +|= IOSQE_ASYNC if $force-async;
    io_uring_submit($!ring);
  }

  multi method submit(*@submissions --> Array[Handle]) {
    self.submit(@submissions);
  }

  multi method submit(@submissions --> Array[Handle]) {
    my Handle @handles;
    $!ring-lock.protect: {
      @handles = do for @submissions -> Submission $sub {
        my Handle $p .= new;
        my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
        $p.break(Failure.new("No more room in ring")) unless $sqe.defined;
        $sqe.opcode = $sub.opcode;
        $sqe.flags = $sub.flags;
        $sqe.ioprio = $sub.ioprio;
        $sqe.fd = $sub.fd;
        $sqe.off = $sub.off;
        $sqe.addr = $sub.addr;
        $sqe.len = $sub.len;
        $sqe.union-flags = $sub.union-flags;
        $sqe.user_data = self!store($p.vow, $sqe, $sub.data // Nil);
        $sqe.pad0 = $sqe.pad1 = $sqe.pad2 = 0;
        $sub.then.defined ?? $p.then($sub.then) !! $p;
      }
      io_uring_submit($!ring);
    }
    @handles
  }

  sub set-flags(:$drain, :$link, :$hard-link, :$force-async --> int) {
    my int $flags = 0;
    $flags +|= IOSQE_IO_LINK if $link;
    $flags +|= IOSQE_IO_DRAIN if $drain;
    $flags +|= IOSQE_IO_HARDLINK if $hard-link;
    $flags;
  }

  method prep-nop(:$data, :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    return Submission.new(
                         :opcode(IORING_OP_NOP),
                         :$flags,
                         :$ioprio,
                         :fd(-1),
                         :off(0),
                         :addr(0),
                         :len(0),
                         :$data);
  }

  method nop(:$data, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_nop($sqe);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link);
    }
    $p;
  }

  multi method prep-readv($fd, *@bufs, Int :$offset = 0, :$data,
                         Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-readv($fd, @bufs, :$offset, :$ioprio, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-readv($fd, @bufs, Int :$offset = 0, :$data,
                          Int :$ioprio = 0, :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self!prep-readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$ioprio, :$drain, :$link, :$hard-link, :$force-async);
  }

  method !prep-readv($fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$drain, :$link, :$hard-link, :$force-async) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my uint $len = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my $pos = 0;
    my @iovecs;
    for @bufs -> $buf {
      my iovec $iov .= new($buf);
      $iovecs[$pos] = +$iov.Pointer;
      $iovecs[$pos + 1] = $iov.elems;
      @iovecs.push($iov);
      $pos += 2;
    }
    return Submission.new(
                          :opcode(IORING_OP_READV),
                          :$flags,
                          :$ioprio,
                          :fd($fd.native-descriptor),
                          :off($offset),
                          :addr(+nativecast(Pointer, $iovecs)),
                          :$len,
                          :$data,
                          :then(-> $val {
                            for ^@bufs.elems -> $i {
                              @bufs[$i] = @iovecs[$i].Blob;
                              @iovecs[$i].free;
                            }
                            $val.result;
                          }),
                         );
  }

  multi method readv($fd, *@bufs, Int :$offset = 0, :$data = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.readv($fd, @bufs, :$offset, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method readv($fd, @bufs, Int :$offset = 0, :$data = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self!readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$drain, :$link, :$hard-link, :$force-async);
  }

  method !readv($fd, @bufs, Int :$offset = 0, :$data = 0, :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    my $num_vr = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my $pos = 0;
    my @iovecs;
    for @bufs -> $buf {
      my iovec $iov .= new($buf);
      $iovecs[$pos] = +$iov.Pointer;
      $iovecs[$pos + 1] = $iov.elems;
      @iovecs.push($iov);
      $pos += 2;
    }
    my Handle $promise .= new;
    my Handle $p = $promise.then(-> $val {
      for ^@bufs.elems -> $i {
        @bufs[$i] = @iovecs[$i].Blob;
        @iovecs[$i].free;
      }
      $val.result;
    });
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_readv($sqe, $fd.native-descriptor, nativecast(Pointer[size_t], $iovecs), $num_vr, $offset);
      $sqe.user_data = self!store($promise.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link);
    }
    $p
  }

  multi method prep-writev($fd, *@bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self.prep-writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method prep-writev($fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    self!prep-writev($fd, to-write-bufs(@bufs, :$enc), :$offset, :$ioprio, :$data, :$link);
  }

  method !prep-writev($fd, @bufs, Int :$offset = 0, Int :$ioprio = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Submission) {
    my int $flags = set-flags(:$drain, :$link, :$hard-link, :$force-async);
    my uint $len = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my @iovecs;
    my $pos = 0;
    for @bufs -> $buf {
      my iovec $iov .= new($buf);
      $iovecs[$pos] = +$iov.Pointer;
      $iovecs[$pos + 1] = $iov.elems;
      @iovecs.push($iov);
      $pos += 2;
    }
    return Submission.new(
                          :opcode(IORING_OP_WRITEV),
                          :$flags,
                          :$ioprio,
                          :fd($fd.native-descriptor),
                          :off($offset),
                          :addr(+nativecast(Pointer, $iovecs)),
                          :$len,
                          :$data,
                          :then(-> $val {
                            for @iovecs -> $iov {
                              $iov.free;
                            }
                            $val.result;
                          }),
                         );
  }

  multi method writev($fd, *@bufs, Int :$offset = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self.writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link, :$hard-link, :$force-async);
  }

  multi method writev($fd, @bufs, Int :$offset = 0, :$data, :$enc = 'utf-8', :$drain, :$link, :$hard-link, :$force-async --> Handle) {
    self!writev($fd, to-write-bufs(@bufs, :$enc), :$offset, :$data, :$link);
  }

  method !writev($fd, @bufs, Int :$offset, :$data, :$drain, :$link --> Handle) {
    my $num_vr = @bufs.elems;
    my CArray[size_t] $iovecs .= new;
    my @iovecs;
    my $pos = 0;
    for @bufs -> $buf {
      my iovec $iov .= new($buf);
      $iovecs[$pos] = +$iov.Pointer;
      $iovecs[$pos + 1] = $iov.elems;
      @iovecs.push($iov);
      $pos += 2;
    }
    my Handle $promise .= new;
    my Handle $p = $promise.then( -> $val {
      for @iovecs -> $iov {
        $iov.free;
      }
      $val.result;
    });
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_writev($sqe, $fd.native-descriptor, nativecast(Pointer[size_t], $iovecs), $num_vr, $offset);
      $sqe.user_data = self!store($promise.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link);
    }
    $p;
  }

  method fsync($fd, UInt $flags, :$data, :$drain, :$link --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_fsync($sqe, $fd.native-descriptor, $flags);
      $sqe.user_data = self!store($p.vow, $sqe, $data // Nil);
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link);
    }
    $p;
  }

  method poll-add($fd, UInt $poll-mask, :$data, :$drain, :$link --> Handle) {
    my $user_data;
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_poll_add($sqe, $fd, $poll-mask);
      $user_data = self!store($p.vow, $sqe, $data // Nil);
      $sqe.user_data = $user_data;
      $p!Handle::slot = $user_data;
      self!submit($sqe, :$drain, :$link);
    }
    $p;
  }

  method poll-remove(Handle $slot, :$data, :$drain, :$link --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      my Int $user_data = self!store($p.vow, $sqe, $data // Nil);
      io_uring_prep_poll_remove($sqe, $slot!Handle::slot);
      $sqe.user_data = $user_data;
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link);
    }
    $p;
  }

  method cancel(Handle $slot, UInt :$flags = 0, :$drain, :$link --> Handle) {
    my Handle $p .= new;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      my Int $user_data = $slot!Handle::slot;
      io_uring_prep_cancel($sqe, $flags, $user_data);
      $sqe.user_data = $user_data;
      $p!Handle::slot = $sqe.user_data;
      self!submit($sqe, :$drain, :$link);
    }
    $p
  }

}

sub EXPORT() {
  my %export = %(
    'IO::URing' => IO::URing,
  );
  %export.append(%IO_URING_RAW_EXPORT);
  %export
}

=begin pod

=head1 NAME

IO::URing - Access the io_uring interface from Raku

=head1 SYNOPSIS

Sample NOP call

=begin code :lang<raku>

use IO::URing;

my IO::URing $ring .= new(:8entries, :0flags);
my $data = await $ring.nop(1);
# or
react whenever $ring.nop(1) -> $data {
    say "data: {$data.raku}";
  }
}
$ring.close; # free the ring

=end code

=head1 DESCRIPTION

IO::URing is a binding to the new io_uring interface in the Linux kernel.

=head1 AUTHOR

Travis Gibson <TGib.Travis@protonmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2020 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

Some of the subs in this library were translated from liburing into Raku.
Liburing is licensed under a dual LGPL and MIT license. Thank you Axboe for this
library and interface.

=end pod
