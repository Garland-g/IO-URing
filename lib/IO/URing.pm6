use v6;
use IO::URing::Raw;
use NativeCall;

my $version = Version.new($*KERNEL.release);

class IO::URing:ver<0.0.1>:auth<cpan:GARLANDG> {
  my enum STORAGE <EMPTY>;

  my class Completion {
    has $.data;
    has $.request;
    has Int $.result;
    has Int $.flags;
  }

  my class Handle {
    trusts IO::URing;
    has Int $!slot;
    method !slot(--> Int) { $!slot }
    submethod BUILD(:$!slot) {}
  }

  my \tweak-flags = IORING_SETUP_CLAMP;
#  my \features = IORING_FEAT_SINGLE_MMAP
#  +| IORING_FEAT_NO_DROP
#  +| IORING_FEAT_SUBMIT_STABLE;

  my \link-flag = IOSQE_IO_LINK;
  my \drain-flag = IOSQE_IO_DRAIN;

  has io_uring $!ring .= new;
  has io_uring_params $!params .= new;
  has Lock::Async $!ring-lock .= new;
  has Lock::Async $!storage-lock .= new;
  has @!storage is default(STORAGE::EMPTY);
  has Supplier::Preserving $!supplier .= new;

  submethod TWEAK(UInt :$entries, UInt :$flags = tweak-flags, Int :$at-once = 1) {
    $!params.flags = $flags;
    my $result = io_uring_queue_init_params($entries, $!ring, $!params);
    start {
      loop {
        my Pointer[io_uring_cqe] $cqe_ptr .= new;
        io_uring_wait_cqe($!ring, $cqe_ptr);
        my io_uring_cqe $temp := $cqe_ptr.deref;
        my ($request, $data) = self!retrieve($temp.user_data);
        my $flags = $temp.flags;
        my $result = $temp.res;
        io_uring_cqe_seen($!ring, $cqe_ptr.deref);
        my $cmp = Completion.new(:$data, :$request, :$result, :$flags);
        $!supplier.emit($cmp);
      }
      CATCH {
        default {
          die $_;
        }
      }
    }
  }

  submethod DESTROY() {
    $!ring-lock.protect: {io_uring_queue_exit($!ring) };
  }

  multi method Supply {
    $!supplier.Supply;
  }

  # Filter by IORING_OP_XXXX
  multi method Supply(@ops) {
    self.Supply.grep({$_.request.opcode (elem) @ops});
  }

  multi method Supply(*@ops) {
    self.Supply.grep({$_.request.opcode (elem) @ops});
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

  method !store(io_uring_sqe $sqe, $user_data --> Int) {
    # Skip the first slot to have a "slot" for Nil user data
    my Int $slot = 1;
    $!storage-lock.protect: {
      until @!storage[$slot] ~~ STORAGE::EMPTY { $slot++; }
      @!storage[$slot] = ($sqe, $user_data);
    };
    $slot
  }

  method !retrieve(Int $slot) {
    my $tmp;
    $!storage-lock.protect: {
      $tmp = @!storage[$slot];
      @!storage[$slot] = STORAGE::EMPTY;
    };
    return $tmp;
  }

  method !submit(io_uring_sqe $sqe is rw, :$drain, :$link) {
    $sqe.flags +|= link-flag if $link;
    $sqe.flags +|= drain-flag if $drain;
    io_uring_submit($!ring);
  }

  method nop(:$data = 0, :$drain, :$link) {
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_nop($sqe);
      $sqe.user_data = self!store($sqe, $data // Nil);
      self!submit($sqe, :$drain, :$link);
    }
  }

  multi method readv($fd, *@bufs, Int :$offset = 0, :$data = 0, :$drain, :$link) {
    self.readv($fd, @bufs, :$offset, :$data, :$drain, :$link);
  }

  multi method readv($fd, @bufs, Int :$offset = 0, :$data = 0, :$drain, :$link) {
    self!readv($fd, to-read-bufs(@bufs), :$offset, :$data, :$drain, :$link);
  }

  method !readv($fd, @bufs, Int :$offset = 0, :$data = 0, :$drain, :$link) {
    $!ring-lock.protect: {
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
      io_uring_prep_readv($sqe, $fd.native-descriptor, nativecast(iovec, $iovecs), $num_vr, $offset);
      $sqe.user_data = self!store($sqe, $data // Nil);
      self!submit($sqe, :$drain, :$link);
    }
  }

  multi method writev($fd, *@bufs, Int :$offset = 0, :$data = 0, :$enc = 'utf-8', :$drain, :$link) {
    self.writev($fd, @bufs, :$offset, :$data, :$enc, :$drain, :$link);
  }

  multi method writev($fd, @bufs, Int :$offset = 0, :$data = 0, :$enc = 'utf-8', :$drain, :$link) {
    self!writev($fd, to-write-bufs(@bufs, :$enc), :$offset, :$data, :$link);
  }

  method !writev($fd, @bufs, Int :$offset, :$data, :$drain, :$link) {
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      my $num_vr = @bufs.elems;
      my buf8 $iovecs .= new;
      my $pos = 0;
      for ^$num_vr -> $num {
        #TODO Fix when nativecall gets better.
        # Hack together array of struct iovec from definition
        $iovecs.write-uint64($pos, +nativecast(Pointer, @bufs[$num])); $pos += 8;
        $iovecs.write-uint64($pos, @bufs[$num].elems); $pos += 8;
      }
      io_uring_prep_writev($sqe, $fd.native-descriptor, nativecast(iovec, $iovecs), $num_vr, $offset);
      $sqe.user_data = self!store($sqe, $data // Nil);
      self!submit($sqe, :$drain, :$link);
    }
  }

  method fsync($fd, UInt $flags, :$data, :$drain, :$link) {
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_fsync($sqe, $fd.native-descriptor, $flags);
      $sqe.user_data = self!store($sqe, $data // Nil);
      self!submit($sqe, :$drain, :$link);
    }
  }

  method poll-add($fd, UInt $poll-mask, :$data!, :$drain, :$link --> Handle) {
    my $user_data;
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      io_uring_prep_poll_add($sqe, $fd, $poll-mask);
      $user_data = self!store($sqe, $data // Nil);
      $sqe.user_data = $user_data;
      self!submit($sqe, :$drain, :$link);
    }
    return Handle.new(:slot($user_data));
  }

  method poll-remove(Handle $slot, :$drain, :$link) {
    $!ring-lock.protect: {
      my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
      my Int $user_data = $slot!Handle::slot;
      io_uring_prep_poll_remove($sqe, $user_data);
      $sqe.user_data = $user_data;
      self!submit($sqe, :$drain, :$link);
    }
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
start {
  $ring.nop(1);
}
react {
  whenever signal(SIGINT) {
    say "done"; exit;
  }
  whenever $ring.Supply -> $data {
    say "data: {$data.raku}";
  }
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
