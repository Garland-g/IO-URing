[![Build Status](https://travis-ci.org/travis/IO-URing.svg?branch=master)](https://travis-ci.org/travis/IO-URing)

NAME
====

io_uring - Access the io_uring interface from Raku

SYNOPSIS
========

```raku
use io_uring;
```

DESCRIPTION
===========

IO::URing is a binding to the new io_uring interface in the Linux kernel.

AUTHOR
======

Travis Gibson <TGib.Travis@protonmail.com>

COPYRIGHT AND LICENSE
=====================

Copyright 2020 Travis Gibson

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

Some of the subs in this library were translated from liburing into Raku. Liburing is licensed under a dual LGPL and MIT license. Thank you Axboe for this library and interface.

