[![Build Status](https://travis-ci.org/travis/IO-URing.svg?branch=master)](https://travis-ci.org/travis/IO-URing)

NAME
====

IO::URing - Access the io_uring interface from Raku

SYNOPSIS
========

Sample NOP call

```raku
use IO::URing;

my IO::URing $ring .= new(:8entries, :0flags);
my $data = await $ring.nop(1);
# or
react whenever $ring.nop(1) -> $data {
    say "data: {$data.raku}";
  }
}
$ring.close; # free the ring
```

DESCRIPTION
===========

IO::URing is a binding to the new io_uring interface in the Linux kernel. As such, it will only work on Linux.

See the included IO::URing::Socket libraries for an example of IO::URing in action.

Some knowledge of io_uring and liburing is a pre-requisite for using this library. This code uses liburing to set up and submit requests to the ring.

IO::URing internal classes
==========================

class IO::URing::Completion
---------------------------

A Completion is returned from an awaited Handle. The completion contains the result of the operation.

### has Mu $.data

The user data passed into the Submission.

### has io_uring_sqe $.request

The request passed into the IO::URing.

### has int $.result

The result of the operation.

class IO::URing::Handle
-----------------------

A Handle is a Promise that can be used to cancel an IO::URing operation. Every call to submit or any non-prep operation will return a Handle.

class IO::URing::Submission
---------------------------

A Submission holds a request for an operation. Every call to a "prep" method will return a Submission. A Submission can be passed into the submit method.

IO::URing
=========

IO::URing methods
-----------------

### method close

```perl6
method close() returns Mu
```

Close the IO::URing object and shut down event processing.

### method features

```perl6
method features() returns Mu
```

Get the enabled features on this IO::URing.

### multi method submit

```perl6
multi method submit(
    @submissions
) returns Array[IO::URing::Handle]
```

Submit multiple Submissions to the IO::URing. A slurpy variant is provided. Returns an Array of Handles.

### multi method submit

```perl6
multi method submit(
    IO::URing::Submission $sub
) returns IO::URing::Handle
```

Submit a single Submission to the IO::URing. Returns a Handle.

### method prep-nop

```perl6
method prep-nop(
    :$data,
    :$ioprio = 0,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a no-op operation.

### method nop

```perl6
method nop(
    |c
) returns IO::URing::Handle
```

Prepare and submit a no-op operation.

### multi method prep-readv

```perl6
multi method prep-readv(
    Int $fd,
    @bufs,
    Int :$offset = 0,
    :$data,
    Int :$ioprio = 0,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a readv operation. A multi will handle a non-Int $fd by calling native-descriptor. A multi with a @bufs slurpy is provided.

### method readv

```perl6
method readv(
    |c
) returns IO::URing::Handle
```

Prepare and submit a readv operation. See prep-readv for details.

### multi method prep-writev

```perl6
multi method prep-writev(
    Int $fd,
    @bufs,
    Int :$offset = 0,
    Int :$ioprio = 0,
    :$data,
    :$enc = "utf-8",
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a writev operation. A multi will handle a non-Int $fd by calling native-descriptor. A multi with a @bufs slurpy is provided.

### method writev

```perl6
method writev(
    |c
) returns IO::URing::Handle
```

Prepare and submit a writev operation. See prep-writev for details.

### multi method prep-fsync

```perl6
multi method prep-fsync(
    Int $fd,
    Int $fsync-flags where { ... } = 0,
    Int :$ioprio = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare an fsync operation. fsync-flags can be set to IORING_FSYNC_DATASYNC to use fdatasync(2) instead. Defaults to fsync(2).

### method fsync

```perl6
method fsync(
    $fd,
    Int $fsync-flags where { ... } = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit an fsync operation. See prep-fsync for details.

### multi method prep-poll-add

```perl6
multi method prep-poll-add(
    Int $fd,
    Int $poll-mask where { ... },
    Int :$ioprio = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a poll-add operation. A multi will handle a non-Int $fd by calling native-descriptor.

### method poll-add

```perl6
method poll-add(
    $fd,
    Int $poll-mask where { ... },
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a poll-add operation. See prep-poll-add for details.

### method prep-poll-remove

```perl6
method prep-poll-remove(
    IO::URing::Handle $slot,
    Int :$ioprio = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a poll-remove operation. The provided Handle must be the Handle returned by the poll-add operation that should be cancelled.

### method poll-remove

```perl6
method poll-remove(
    IO::URing::Handle $slot,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a poll-remove operation.

### multi method prep-sendto

```perl6
multi method prep-sendto(
    Int $fd,
    Str $str,
    Int $union-flags,
    sockaddr_role $addr,
    Int $len,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async,
    :$enc = "utf-8"
) returns IO::URing::Submission
```

Prepare a sendto operation. This is a wrapper around the sendmsg call for ease of use. A multi is provided that takes Blobs. A multi will handle a non-Int $fd by calling native-descriptor.

### multi method sendto

```perl6
multi method sendto(
    $fd,
    Blob $blob,
    Int $union-flags,
    sockaddr_role $addr,
    Int $len,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a sendto operation

### multi method prep-sendmsg

```perl6
multi method prep-sendmsg(
    Int $fd,
    msghdr:D $msg,
    $union-flags,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a sendmsg operation. A multi will handle a non-Int $fd by calling native-descriptor.

### method sendmsg

```perl6
method sendmsg(
    $fd,
    msghdr:D $msg,
    $flags,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a sendmsg operation.

### multi method prep-recvfrom

```perl6
multi method prep-recvfrom(
    Int $fd,
    Blob $buf,
    $flags,
    Blob $addr,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a recvfrom operation. This is a wrapper around the recvmsg call for ease of use. A multi is provided that takes Blobs. A multi will handle a non-Int $fd by calling native-descriptor.

### method recvfrom

```perl6
method recvfrom(
    $fd,
    Blob $buf,
    $flags,
    Blob $addr,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a recvfrom operation.

### multi method prep-recvmsg

```perl6
multi method prep-recvmsg(
    Int $fd,
    msghdr:D $msg is rw,
    $union-flags,
    $addr,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a recvmsg operation. A multi will handle a non-Int $fd by calling native-descriptor.

### multi method recvmsg

```perl6
multi method recvmsg(
    Int $fd,
    msghdr:D $msg is rw,
    $flags,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a recvmsg operation

### method prep-cancel

```perl6
method prep-cancel(
    IO::URing::Handle $slot,
    Int $union-flags where { ... } = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a cancel operation to cancel a previously submitted operation. Note that this chases an in-flight operation, meaning it may or maybe not be successful in cancelling the operation. This means that both cases must be handled.

### method cancel

```perl6
method cancel(
    IO::URing::Handle $slot,
    Int :$flags where { ... } = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a cancel operation

### multi method prep-accept

```perl6
multi method prep-accept(
    Int $fd,
    $sockaddr?,
    Int $union-flags = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare an accept operation. A multi will handle a non-Int $fd by calling native-descriptor.

### method accept

```perl6
method accept(
    $fd,
    $sockaddr?,
    Int $union-flags = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit an accept operation.

### multi method prep-connect

```perl6
multi method prep-connect(
    Int $fd,
    sockaddr_role $sockaddr,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a connect operation. A multi will handle a non-Int $fd by calling native-descriptor.

### method connect

```perl6
method connect(
    $fd,
    sockaddr_role $sockaddr,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a connect operation.

### multi method prep-send

```perl6
multi method prep-send(
    Int $fd,
    Blob $buf,
    $union-flags = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a send operation. A multi will handle a Str submission., which takes a named parameter :$enc = 'utf-8'. A multi will handle a non-Int $fd by calling native-descriptor.

### multi method send

```perl6
multi method send(
    $fd,
    $buf,
    Int $flags = 0,
    :$enc = "utf-8",
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a send operation.

### multi method prep-recv

```perl6
multi method prep-recv(
    Int $fd,
    Blob $buf,
    Int $union-flags = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Submission
```

Prepare a recv operation. A multi will handle a non-Int $fd by calling native-descriptor.

### multi method recv

```perl6
multi method recv(
    $fd,
    Blob $buf,
    Int $union-flags = 0,
    :$data,
    :$drain,
    :$link,
    :$hard-link,
    :$force-async
) returns IO::URing::Handle
```

Prepare and submit a recv operation.

### method close-fd

```perl6
method close-fd(
    Int $fd
) returns IO::URing::Handle
```

Prepare a submit a close-fd operation. This is a fake operation which will be used until linux kernels older than 5.6 are unsupported.

### multi method supported-ops

```perl6
multi method supported-ops() returns Hash
```

Get the supported operations on an IO::URing instance.

### multi method supported-ops

```perl6
multi method supported-ops() returns Hash
```

Get the supported operations without an IO::URing instance.

AUTHOR
======

Travis Gibson <TGib.Travis@protonmail.com>

COPYRIGHT AND LICENSE
=====================

Copyright 2020 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

Some of the subs in this library were translated from liburing into Raku. Liburing is licensed under a dual LGPL and MIT license. Thank you Axboe for this library and interface.

