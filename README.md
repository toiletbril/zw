# zw

Extracts count of each word from a file. A word is consists of either ASCII or
Unicode. Binary is ignored.

A rewrite of an old little
[haskell program](https://gist.github.com/toiletbril/aa79905b858c8b29a2f34e1d70045aa5)
in a language that works something like 100x times faster.

The Haskell version was inherently multithreaded, but functional pussies prefer
safety, while Zig chads abuse their fast and furious segmentation faults.

Single-threaded, this version is about 60 times faster. SIMD processes 8-64
bytes at once (depending on AVX512/AVX2/SSE4.2) instead of byte-by-byte:

$$O\left(\frac{n}{w}\right) \text{ vs } O(n) \text{ where } w \in [8, 64]$$

Hash maps do O(1) insertions vs Haskell's tree-based `Data.Map`:

$$O(1) \text{ vs } O(\log u) \approx 13 \text{ ops when } u = 10000$$

For files over 100MB it uses `mmap()` and uses a separate thread for each 512MB
chunk, maxing out with 80% of your cores:

$$O\left(\frac{n}{w \cdot t}\right) + O(k \cdot u \cdot w_{avg})$$

where $t$ is threads, $k \approx 2\text{-}3$ is word duplication across chunks,
$w_{avg}$ is average word length.

On a 4-core system that's the base 60x multiplied by 3 threads = ~180x total.
On 8-core ~360x. On 16-core ~720x and so on. With some inacurracies, because I
wanted to leave an impression.

tl;dr zig go brrrrr
