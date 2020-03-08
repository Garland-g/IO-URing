use v6;
use IO::URing::Raw;
use NativeCall;

my $version = Version.new($*KERNEL.release);

class IO::URing:ver<0.0.1>:auth<cpan:GARLANDG> {
  my enum STORAGE <EMPTY>;

  has io_uring $!ring .= new;
  has Lock::Async $!storage-lock .= new;
  has @!storage is default(STORAGE::EMPTY);

  submethod TWEAK(UInt :$entries,
    UInt :$flags = INIT { 0
      +| ($version ~~ v5.4+ ?? $::('IORING_FEAT_SINGLE_MMAP') !! 0)
      +| ($version ~~ v5.5+ ?? $::('IORING_FEAT_NODROP') +| $::('IORING_FEAT_SUBMIT_STABLE') !! 0)
    }
  ) {
    $!storage-lock.protect: { @!storage[$entries * 2 - 1] = Nil }
    io_uring_queue_init($entries, $!ring, $flags);
    #start {
      #  loop {
        #  my Pointer[io_uring_cqe] $cqe_ptr .= new;
        #io_uring_wait_cqe($!ring, $cqe_ptr);
        #my io_uring_cqe $temp = $cqe_ptr.deref.clone;
        #$!supplier.emit($temp);
        #io_uring_cqe_seen($!ring, $cqe_ptr.deref);
        #}
        #}
  }

  submethod DESTROY() {
    io_uring_queue_exit($!ring);
  }

  my sub to-read-buf($item is rw) {
    return $item if $item ~~ Blob;
    return $item.=encode if $item ~~ Str;
    $item = $item.Blob // fail "Don't know how to make $item.^name into a Blob";
  }

  my sub to-read-bufs(@items) {
    @items.=map(&to-read-buf);
  }

  my sub to-write-buf($item) {
    return $item if $item ~~ Blob;
    return $item.encode if $item ~~ Str;
    return $item.Blob // fail "Don't know how to make $item.^name into a Blob";
  }

  my sub to-write-bufs(@items) {
    @items.map(&to-write-buf);
  }

  method !store($user_data --> Int) {
    my $slot;
    $!storage-lock.protect: {
      for 0..^@!storage.elems -> Int $i {
        if @!storage[$i] ~~ STORAGE::EMPTY {
          @!storage[$i] = $user_data;
          $slot = $i;
          last;
        }
      }
    };
    $slot // fail "Could not store data";
  }

  method !retrieve(Int $slot) {
    my $tmp;
    $!storage-lock.protect: {
      $tmp = @!storage[$slot];
      @!storage[$slot] = STORAGE::EMPTY;
    };
    return $tmp;
  }

  method !submit(io_uring_sqe $sqe is rw, :$chain = False) {
    $sqe.flags +|= INIT {
      $version ~~ v5.3+ && $chain
        ?? $::('IOSQE_IO_LINK')
        !! ($chain ?? fail "Cannot chain with kernel release < 5.3" !! 0)
    };
    io_uring_submit($!ring);
  }

  my class Completion {
    has $.data;
    has Int $.result;
    has Int $.flags;
  }

  method !Promise(:$chain = False --> Promise) {
    start {
      if $chain {
        self;
      }
      else {
        my Pointer[io_uring_cqe] $cqe_ptr .= new;
        io_uring_wait_cqe($!ring, $cqe_ptr);
        my io_uring_cqe $temp := $cqe_ptr.deref;
        my $data = self!retrieve($temp.user_data);
        my $ret = Completion.new(
          :data($data),
          :result($temp.res),
          :flags($temp.flags)
        );
        io_uring_cqe_seen($!ring, $cqe_ptr.deref);
        $ret;
      }
    }
  }

  method nop(:$data = 0, :$chain = False --> Promise) {
    my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
    my $user_data = self!store($data);
    io_uring_prep_nop($sqe, $user_data);
    self!submit($sqe, :$chain);
    self!Promise(:$chain);
  }

  multi method readv($fd, *@bufs, Int :$offset = 0, :$data = 0, :$chain = False --> Promise) {
    self.readv($fd, @bufs, :$offset, :$data, :$chain);
  }

  multi method readv($fd, @bufs, Int :$offset = 0, :$data = 0, :$chain = False --> Promise) {
    self!readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$chain);
  }

  method !readv($fd, @bufs, Int :$offset = 0, :$data, :$chain = False --> Promise) {
    my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
    my $num_vr = @bufs.elems;
    my buf8 $iovecs .= new;
    my $pos = 0;
    for ^$num_vr -> $num {
      #TODO Fix when nativecall gets better.
      # Hack together array of struct iovec from definition
      $iovecs.write-uint64($pos, +nativecast(Pointer, @bufs[$num]));
      $pos += 8;
      $iovecs.write-uint64($pos, @bufs[$num].elems);
      $pos += 8;
    }
    my $user_data = self!store($data);
    io_uring_prep_readv($sqe, $fd.native-descriptor, nativecast(iovec, $iovecs), $num_vr, $offset, $user_data);
    self!submit($sqe, :$chain);
    self!Promise(:$chain);
  }

  multi method writev($fd, *@bufs, Int :$offset = 0, :$data = 0, :$chain = False --> Promise) {
    self.writev($fd, @bufs, :$offset, :$data, :$chain);
  }

  multi method writev($fd, @bufs, Int :$offset = 0, :$data = 0, :$chain = False --> Promise) {
    self!writev($fd, to-write-bufs(@bufs), :$offset, :$data, :$chain);
  }

  method !writev($fd, @bufs, Int :$offset = 0, :$data = 0, :$chain = False --> Promise) {
    my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
    my $num_vr = @bufs.elems;
    my buf8 $iovecs .= new;
    my $pos = 0;
    for ^$num_vr -> $num {
      #TODO Fix when nativecall gets better.
      # Hack together array of struct iovec from definition
      $iovecs.write-uint64($pos, +nativecast(Pointer, @bufs[$num]));
      $pos += 8;
      $iovecs.write-uint64($pos, @bufs[$num].elems);
      $pos += 8;
    }
    my $user_data = self!store($data);
    io_uring_prep_writev($sqe, $fd.native-descriptor, nativecast(iovec, $iovecs), $num_vr, $offset, $user_data);
    self!submit($sqe, :$chain);
    self!Promise(:$chain);
  }

  method fsync($fd, Int $flags, :$data = 0, :$chain = False --> Promise) {
    my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
    my $user_data = self!store($data) if $data;
    io_uring_prep_fsync($sqe, $fd.native-descriptor, $flags, $user_data);
    self!submit($sqe, :$chain);
    self!Promise;
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
my $cqe = await $ring.nop(1);
say $cqe.user_data;
}

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
