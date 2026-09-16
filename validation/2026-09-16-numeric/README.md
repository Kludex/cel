# Mixed numeric comparison validation

## Decision

The four long-standing corpus failures (`comparisons/lt_literal/not_lt_dyn_int_big_lossy_double`, `gt_literal/not_gt_dyn_big_double_int`, `lte_literal/lte_dyn_big_double_int`, `gte_literal/gte_dyn_int_big_lossy_double`) were not corpus errors. Their descriptions say the int-to-double conversion is lossy and the values compare equal. Both reference implementations agree:

- CEL-Go `common/types/compare.go`: `compareDoubleInt` returns -1 when `d < math.MinInt64`, 1 when `d > math.MaxInt64`, otherwise `compareDouble(d, Double(i))`.
- CEL-C++ `internal/number.h` (commit `8d22c5b66f28dc5f72b99b5c70fabd7587a592f2`): `DoubleCompareVisitor::operator()(int64_t)` compares against `kDoubleToIntMax`/`kDoubleToIntMin` (the bounds cast to double), then `DoubleCompare(v, static_cast<double>(other))`; the `uint64_t` overload uses `kDoubleToUintMax` and `0`.

This SDK previously compared in `f128`, which is exact and therefore disagreed. `Value.order` now implements the shared algorithm. `eql` derives from `order`, so map keys, `in`, `distinct`, `==`, and extrema all follow it.

## TDD record

`red-before.txt`: the new public test `mixed numeric comparison follows the reference clamp-then-double algorithm` failing on the exact implementation. One expectation in the first draft (`18446744073709551615u == 18446744073709551616.0` as false) was itself wrong: 2^64 - 1 rounds to 2^64 as a double, so both references return true; CEL-Go was queried before the expectation was corrected. Three older tests encoded the exact stance (`9007199254740993 != 9007199254740992.0`, `18446744073709551615u < 18446744073709551616.0`, and the Python/Node `math.greatest(INT_MAX, 2^63.0)` expectation); each replacement value was confirmed against CEL-Go before the assertion changed. Extrema keep the first argument on a tie, as CEL-Go does.

## Independent verification

`expressions.json` holds 4,000 comparisons sampled from all six operators over boundary and random `int`, `uint`, and `double` literals (2^53 neighborhood, both int64 bounds, uint64 bound, values beyond every bound, infinities, NaN via `0.0/0.0` in the unit test, and 30 random values per type).

| Oracle | Compared | Mismatches |
| --- | ---: | ---: |
| CEL-Go runtime at the pinned commit (`conformance/reference/numeric.go`, `cel-go-results.json`) | 4,000 | 0 |
| From-source Python transcription of CEL-C++'s three comparison visitors (`differential-cel-cpp-transcription.json`) | 4,000 | 0 |

The C++ oracle is a transcription, not the compiled library; it is independent of this SDK's code but shares the author's reading of `number.h`.

## Gates

| Gate | Result |
| --- | --- |
| Zig Debug/ReleaseSafe/ReleaseFast | 138 tests pass |
| Python | 134 tests, 100% wrapper coverage |
| Node | 102 tests, 100% wrapper coverage |
| Audit/benchmark CLI | 71 tests pass |
| Six audits (`audits.txt`) | 2,505 / 3 / 0 full; 2,481 / 2 / 25 evaluation; identical across Python, Node, direct Zig |
| Source and math fuzzers | 101,982 and 100,036 runs |

The three remaining full-mode failures are the network-extension disagreements documented in `validation/2026-09-16-network/`; nothing was excluded from the corpus.

## Linux matrix

The artifact matrix was rebuilt from a snapshot of these sources (`linux-source.sha256`; the two later test-only additions to `src/program.zig` postdate the snapshot and change no product code). `linux-summary.txt` and the `linux-*.txt` logs record:

| Check | Result |
| --- | --- |
| Core arm64 glibc 2.28 / emulated x86-64 | 137 tests pass on each |
| Node addon build | first attempt OOM at 1 GiB container memory (`linux-node-build-oom.txt`), succeeded at 4 GiB |
| Installed npm archive, Node 24 glibc 2.28 and Node 22 glibc 2.31 | 102 pass, 100% wrapper coverage |
| Wheel from source, `auditwheel`, strict `abi3audit` | `cp310-abi3-manylinux_2_28_aarch64`, 0 mismatches |
| Installed wheel, CPython 3.10.20 glibc 2.28 | 134 pass, 100% coverage |
| Six audits (`linux-parity.txt`) | 2,505/3/0 and 2,481/2/25; every field including implementation labels equal to macOS |

## What this does not claim

Passing the pinned corpus is not full conformance: unknown/error values, checker type families outside the corpus, and untested library surfaces remain open.
