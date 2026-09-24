# File search behavior baseline

`matcher-baseline.json` records outputs from the original matcher at commit
`5d111f6`, before the score-only and prepared-candidate optimizations. Each query
contains ordered candidate indices, scores, Character ranges, and UTF-16 ranges.
An omitted candidate did not match. Do not regenerate expectations from the
optimized implementation merely to make a failing regression test pass.

`FileSearchRegressionTests` checks these outputs, including reversed input order,
ASCII/Unicode folding, grapheme clusters, filename/path queries, and ranking ties.
The existing matcher/index tests also cover cancellation and enumeration limits.

For timing and peak process memory, compile and run
`scripts/bench/file-search-benchmark.swift` using its header instructions. Use the
same compiler, optimization mode, inputs, and machine for both revisions. Timing
is informational rather than an absolute CI threshold, since runner speed varies.

## Local benchmark evidence

On 2026-09-24, an optimized build on the same Mac compared `5d111f6` with the
optimized matcher using the 20,000-file synthetic inputs in the benchmark.
Times below are milliseconds; ranking is the median of five warmed passes.
These are matcher measurements, excluding the unchanged 100 ms debounce,
filesystem enumeration, icon loading, and UI rendering.

| Input | Query | Before | After |
| --- | --- | ---: | ---: |
| ASCII | `md` | 85.52 | 32.01 |
| ASCII | `document-123` | 9.61 | 1.22 |
| ASCII | `docs/sec` | 131.78 | 40.72 |
| ASCII | `zzzz` | 6.61 | 0.19 |
| Unicode | `md` | 194.28 | 161.11 |
| Unicode | `document-123` | 21.17 | 19.27 |
| Unicode | `docs/sec` | 234.27 | 195.14 |
| Unicode | `zzzz` | 14.14 | 14.04 |

The cache trades some preparation work and memory for repeated-query speed.
ASCII candidate preparation increased from about 19 to 45 ms, and peak benchmark
process footprint from 7.7 to 13.8 MB. Unicode preparation was about 25 versus
28 ms, with peak footprint 7.9 versus 9.2 MB. Unicode strings deliberately retain
no expanded Character cache. Measurements vary with machine load; no absolute
performance threshold is asserted by the tests.
