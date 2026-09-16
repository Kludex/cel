# Numeric comparison benchmark checkpoint

Complete request decisions through the public Node API on macOS arm64 with Node 24.14.1 and Zig 0.16.0 `ReleaseSafe`.

## Paired comparison, `Value.order` change only

The before module is the current source tree with only `src/value.zig`'s `order` reverted to the exact `f128` comparison, built the same way. The after module is the current tree.

| Workload | Run | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: |
| 64-decision mix | 1 | 1,553 ns (1.3%) | 1,366 ns (1.1%) | 1.13x |
| 64-decision mix | 2 | 1,569 ns (0.7%) | 1,365 ns (1.3%) | 1.15x |
| 64-decision mix | 3 | 1,554 ns (0.4%) | 1,375 ns (0.6%) | 1.13x |
| Authorization | 1 | 1,102 ns (0.9%) | 956 ns (2.2%) | 1.15x |

Every run satisfies the stability and meaningful-effect thresholds. The mechanism is not the semantic change itself: `Value.eql` and ordering route every numeric pair, including `int == int`, through `order`, and the previous implementation converted both operands to `f128` and compared in software-emulated 128-bit arithmetic. The reference algorithm compares same-type integers natively and only converts for genuine cross-type pairs.

## Cumulative comparison against the evaluator-path checkpoint

`paired-all-1.json` and `paired-all-2.json` compare against the pre-evaluator-path module (`/tmp/cel-eval-before`), covering the evaluator fast paths, encoder trims, and this change together: 1,703 -> 1,373 ns and 1,699 -> 1,369 ns (1.24x), IQR under 1%. Two earlier attempts during a host load spike (IQR 10-15%) are retained as `paired-all-*-unstable.json` and excluded.

Warm authorization is now about 0.96 us against `cel-js`'s 0.30 us, roughly 3.2x. Performance leadership on that workload is not established.

## Full 64-decision mix, all three SDKs

Unpaired runs on the current build, for the record; the evaluator-path checkpoint's figures are the previous baseline.

| Engine | Cold median | Warm median | Previous warm |
| --- | ---: | ---: | ---: |
| Python | 6.480 us (1.0%) | 1.169 us (0.6%) | 1.429 us |
| Node | 8.140 us (1.3%) | 1.356 us (0.6%) | 1.562 us |
| Native Zig | 5.695 us (0.5%) | 0.642 us (1.1%) | 0.706 us |

These are consistent with the paired Node result; the shared-core change reaches every SDK.
