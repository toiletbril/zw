# zw

Extracts count of each word from a file. A word is consists of either ASCII or
Unicode. Binary is ignored.

A rewrite of an old little
[haskell program](https://gist.github.com/toiletbril/aa79905b858c8b29a2f34e1d70045aa5)
in a ~~faster~~ better language.

This version is about 60 times faster due Zig's wonderful allocator and SIMD
APIs. It's definetely not flawless, but right now, the speed seems to be almost
exclusively limited by Zig's implementation of `std.HashMap` and the absense of
multithreading.
