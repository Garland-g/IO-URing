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

method nop(Int $user_data) {
  my io_uring_sqe $sqe = io_uring_get_sqe($!ring);
  io_uring_prep_nop($sqe, $user_data);
  io_uring_submit($!ring);
}

method readv() {
  my CArray[io_uring_sqe] $arr .= new;
  $arr[0] = io_uring_sqe.new;
  my $p_sqe := nativecast(Pointer[io_uring_sqe], $arr);
  my $sqe := $p_sqe.deref;
  is $p_sqe.deref, $sqe;
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
