use v6.c;
use IO::URing::Raw;
use NativeCall;
use Test;

unit class IO::URing:ver<0.0.1>:auth<cpan:GARLANDG>;
has io_uring $!ring .= new;
has Supplier $!supplier .= new;
has Supply $!supply;

submethod TWEAK(UInt :$entries, UInt :$flags = IORING_FEAT_SINGLE_MMAP +| IORING_FEAT_NODROP +| IORING_FEAT_SUBMIT_STABLE) {
  io_uring_queue_init($entries, $!ring, $flags);
  start {
    loop {
      my Pointer[io_uring_cqe] $cqe_ptr .= new;
      io_uring_wait_cqe($!ring, $cqe_ptr);
      my io_uring_cqe $temp = $cqe_ptr.deref;
      $!supplier.emit($temp);
      io_uring_cqe_seen($!ring, $cqe_ptr.deref.clone);
    }
    CATCH {
      default {
        die $_;
      }
    }
  }
}

submethod DESTROY() {
  io_uring_queue_exit($!ring);
}

method Supply {
  $!supply //= do {
    supply {
      whenever $!supplier -> $cqe {
        emit $cqe;
      }
    }
  };
}

method nop(Int $user_data = 0) {
  my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
  io_uring_prep_nop($sqe, $user_data);
  io_uring_submit($!ring);
}

method readv($fd, @bufs, Int :$offset = 0, Int :$user_data = 0) {
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
  io_uring_prep_readv($sqe, $fd.native-descriptor, nativecast(iovec, $iovecs), $num_vr, $offset, $user_data);
  io_uring_submit($!ring);
}

method writev($fd, @bufs, Int :$offset = 0, Int :$user_data = 0) {
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
  io_uring_prep_writev($sqe, $fd.native-descriptor, nativecast(iovec, $iovecs), $num_vr, $offset, $user_data);
  io_uring_submit($!ring);
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
  sleep 0.1
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
