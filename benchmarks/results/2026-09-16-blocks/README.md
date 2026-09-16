# Indexed-block policy measurements

```sh
node benchmarks/profiling/paired.mjs \
  --before bindings/typescript/dist/index.js \
  --after bindings/typescript/dist/index.js \
  --workloads benchmarks/results/2026-09-16-lists/large-workloads.json \
  --after-workloads benchmarks/results/2026-09-16-blocks/block-large-workloads.json \
  --iterations 300 > /tmp/indexed-dispatch.json
```

The after policy uses three lazy slots for flattened jobs, unique-ID count, and selected priority jobs. Both policies use identical named inputs and expected decisions. The driver checks that equivalence before timing and records both expressions. Each request includes conversion, evaluation, and result verification.

## Paired results

| Comparison | Before, us/decision | After, us/decision | Relative IQR, before/after |
| --- | ---: | ---: | ---: |
| Complete 500-job dispatch, 1 | 727.497 | 713.393 | 0.81% / 0.78% |
| Complete 500-job dispatch, 2 | 726.826 | 712.845 | 0.65% / 0.74% |
| Ordinary 45-decision suite, original versus block policies | 2.585 | 2.559 | 0.58% / 0.66% |
| Unchanged policies, alpha.16 versus current SDK | 2.641 | 2.587 | 0.53% / 0.52% |

Every pair has five warmups, 30 samples, and alternating execution order. The large fixture still processes 500 jobs, validates IDs, sorts/selects jobs, and checks readiness, cost, and node availability.

All relative IQRs satisfy the 5% stability criterion. The roughly 2% elapsed changes are below the 10% meaningful-effect threshold. No speedup or regression is claimed. No unrelated host processes were stopped.

## Full SDK and competitor records

The ordinary suite remains 45 decisions across nine workloads. Standalone final medians are:

| SDK | Cold, us/decision | Warm, us/decision |
| --- | ---: | ---: |
| Python | 8.225 | 1.396 |
| Node | 11.034 | 2.583 |
| Native Zig | 7.274 | 0.756 |

Native Zig excludes binding conversion costs. Raw samples and variance are retained in the corresponding JSON files.

The original authorization workload still favors `@marcbachmann/cel-js@8.0.0`: about 0.301 us warm versus 2.102 us for the candidate, roughly seven times faster. Earlier checkpoints retain competitor failures on unsupported batch-policy functions. Those failures are not complete-suite timings.

Measurements use macOS arm64, Node 24.14.1, Zig 0.16.0, ReleaseSafe, and baseline CPU settings. Indexed blocks add an optimizer/conformance input format; these results do not establish general performance leadership, memory accounting, or the same effect on other platforms.
