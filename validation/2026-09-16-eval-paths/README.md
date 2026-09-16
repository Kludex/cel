# Evaluator paths, borrowed Python inputs, and Node fixed-cost validation

## Change

Three shared-core and binding changes, each guarded by public tests:

1. `src/eval.zig`: map field lookup compares string keys directly instead of routing every entry through generic CEL equality; bare identifiers resolve by exact name when no container or dotted name exists; `contains`/`startsWith`/`endsWith` on a string receiver dispatch before the extension cascade. Semantics are unchanged; every branch falls back to the general path when its precondition fails.
2. `src/python.zig`: string and bytes inputs borrow the Python object's buffer for the duration of `evaluate` while a per-call list holds strong references. Environment construction still copies, because that storage outlives the call.
3. `bindings/typescript/index.ts`: the plain-data encoder no longer allocates a deferred array or grows through `push` for every string, and nested calls still receive their own encoder.

## Gates

| Gate | Result |
| --- | --- |
| Zig Debug, ReleaseSafe, ReleaseFast | 133 tests pass (`release-fast.txt`) |
| Python | 134 tests; wrapper/test line and branch coverage 100% |
| Node | 102 tests; wrapper line/branch/function coverage 100% |
| Audit and benchmark CLI | 71 tests pass |
| Six audits (`audits.txt`) | 2,501 / 7 / 0 full and 2,477 / 6 / 25 evaluation, unchanged |
| Source and checked-source fuzzing | 102,219 and 103,613 runs (`fuzz-source.txt`, `fuzz-checked.txt`) |
| Formatting, lint, strict typing | Pass (`check.txt`) |

## TDD record

`red-borrow-without-incref.txt` records the new Python test failing when the strong reference is removed: a callback drops the bindings dictionary, collects garbage, and allocates replacement strings, after which the borrowed input reads back corrupted data. With the reference held the test passes. The first version of that test passed even without the reference because CPython reused the freed memory harmlessly; it was rewritten to allocate large replacements before it counted as evidence.

The evaluator change is guarded by the existing qualified-name and extension tests plus the earlier `qualified resolution stays exact` test, which fails when the fast path is forced on for dotted constants.

A read-only review of the fast paths found two observable differences in the first string-key `lookup`: it restarted the general scan from the first entry on the first non-string key (charging the scanned prefix twice, so a mixed-key map could report `CostLimitExceeded` where the general path returned `false`), and it skipped the depth check that `equal` performs. `red-review-lookup-before.txt` reproduces both through the Python API; `review-lookup-after.txt` shows the corrected results, and `test_string_key_lookup_matches_general_equality_charges_and_depth` pins them. Custom-function precedence over the string predicates, absolute identifiers, constants-before-bindings order, and borrowed inputs across mutating callbacks were checked and found unchanged.

## Distribution

Artifacts were rebuilt from a snapshot of the final sources (`linux-source.sha256`, `packages.sha256`).

| Check | Result |
| --- | --- |
| Core tests, arm64, glibc 2.28 | 132 pass |
| Core tests, emulated x86-64 | 132 pass |
| Wheel from source inside Linux, `auditwheel`, strict `abi3audit` | `manylinux_2_28_aarch64`; 0 mismatches, 0 violations |
| Installed wheel, CPython 3.10.20, glibc 2.28 | 134 pass, 100% coverage |
| Installed npm archive, Node 24, glibc 2.28 | 102 pass, 100% coverage |
| Installed npm archive, Node 22, glibc 2.31 | 102 pass, 100% coverage |
| Six audits on glibc 2.28 (`linux-parity.txt`) | Every field matches macOS |

The Linux core binary reports 132 tests because the benchmark-only workload test is not part of `test-install`.

## Measurements

See [the benchmark checkpoint](../../benchmarks/results/2026-09-16-eval-paths/). Node authorization improved 1.10-1.11x and the mix 1.08x in paired runs after the review fix (one run with 7% IQR is retained as unstable). Python authorization improved about 5% and the mix about 2.5% in alternating unpaired runs; only the authorization change clears the meaningful-effect threshold, and neither is a paired measurement. Pure Zig evaluation of the authorization policy fell from about 455 ns to about 313 ns in a native probe. `cel-js` remains roughly 3.5-4x faster on warm authorization.

A `ReleaseFast` addon build measured about 18% faster on complete requests. Shipped artifacts stay `ReleaseSafe` so bounds and overflow checks remain active for untrusted expressions; that result is recorded, not adopted.
