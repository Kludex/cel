# List-extension application measurements

```sh
CONVERTER_PATCH=benchmarks/results/2026-09-16-lists/restore-linear-distinct.patch \
  benchmarks/profiling/compare-converters \
  --workloads benchmarks/results/2026-09-16-lists/large-workloads.json \
  --iterations 300 > /tmp/large-list-pair.json
```

The before addon implements the list extension with linear-scan deduplication. The after addon uses scalar hash buckets above 16 elements, with semantic equality for collisions and compound values. `restore-linear-distinct.patch` can reconstruct the earlier evaluator from this source snapshot. Both versions use the same public SDK, policy, and activation data.

## Complete 500-job dispatch

The supplemental fixture uses the same batch-dispatch policy as the ordinary suite. Each decision converts 500 job records, flattens batches, verifies unique job IDs, sorts by priority, selects two jobs, checks readiness/cost, and verifies node availability. Expected results are checked on every iteration. This is not an isolated hash-table timing.

| Paired run | Before, ms/decision | After, ms/decision | Reduction | Relative IQR, before/after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1.563 | 0.726 | 53.6% | 0.52% / 0.44% |
| 2 | 1.551 | 0.719 | 53.7% | 0.82% / 1.34% |
| 3 | 1.564 | 0.732 | 53.2% | 0.62% / 1.32% |
| Clean rebuild | 1.555 | 0.727 | 53.2% | 0.38% / 0.58% |

Each pair uses five warmups and 30 retained samples in alternating order. The first uses 1,000 decisions per sample; subsequent runs use 300. All runs meet the 5% relative-IQR threshold and exceed both the 10% effect threshold and twice the larger relative IQR. No unrelated processes were stopped.

The 45-decision ordinary suite is unchanged by the hashing optimization: 2.612 us before versus 2.614 us after, both below 0.7% relative IQR. The larger-case improvement is not represented as a general SDK speedup. Compound values share a fallback bucket and can still require quadratic semantic comparisons within the work budget.

## Whole-suite and competitor evidence

The ordinary suite now contains 45 decisions across nine workloads. Its changed mixture cannot be compared directly with earlier aggregate timings. `python.json`, `node.json`, and `zig.json` retain final whole-suite samples; the `*-initial.json` files retain the earlier implementation checkpoint.

| SDK | Cold, us/decision | Warm, us/decision |
| --- | ---: | ---: |
| Python | 8.274 | 1.445 |
| Node | 11.154 | 2.623 |
| Native Zig | 7.337 | 0.790 |

All final relative IQRs are below 1.3%. Native Zig excludes binding conversion costs.

Fresh authorization measurements still favor `cel-js`: 0.311 us warm versus 2.129 us for the candidate, approximately 6.8 times faster. Both pinned JavaScript baselines fail the batch policy at `flatten`; `cel-js-batch.log` and `bufbuild-batch.log` retain their errors. No incomplete competitor run is reported as a complete-suite timing.

## Environment and scope

Measurements use macOS arm64, Node 24.14.1, Zig 0.16.0, ReleaseSafe, and baseline CPU settings. They establish this measured same-host improvement, not cross-platform performance leadership, native Python superiority, or complete memory accounting. [Validation](../../../validation/2026-09-16-lists/) records correctness, reference differences, allocation failures, fuzzing, and package checks.
