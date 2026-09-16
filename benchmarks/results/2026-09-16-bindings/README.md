# Lazy local-binding policy measurements

```sh
node benchmarks/profiling/paired.mjs \
  --before bindings/typescript/dist/index.js \
  --after bindings/typescript/dist/index.js \
  --workloads benchmarks/results/2026-09-16-lists/large-workloads.json \
  --after-workloads benchmarks/results/2026-09-16-bindings/bound-large-workloads.json \
  --iterations 300 > /tmp/bound-dispatch.json
```

Both variants use the current SDK. The before policy repeats `request.batches.flatten()`; the after policy binds that value once with `cel.bind`. The helper verifies identical workload names, case names, inputs, and expected decisions before loading either engine. It records both source expressions. CLI regression tests reject mismatched pairs.

## Results

| Comparison | Before, us/decision | After, us/decision | Relative IQR, before/after |
| --- | ---: | ---: | ---: |
| 500-job dispatch, 1 | 737.406 | 720.155 | 0.57% / 0.76% |
| 500-job dispatch, 2 | 727.044 | 713.247 | 0.94% / 0.58% |
| All 45 decisions, bound versus repeated policy | 2.707 | 2.669 | 0.87% / 0.96% |
| Unchanged policies, alpha.15 versus current SDK | 2.620 | 2.640 | 0.62% / 0.76% |

Each comparison uses five warmups, 30 retained paired samples, and alternating execution order. All requests include binding conversion and result verification. The large policy still converts 500 jobs, verifies IDs, sorts/selects jobs, checks readiness/cost, and checks node availability.

All relative IQRs satisfy the 5% stability criterion. None of the elapsed changes exceeds the required 10% meaningful-effect threshold. There is no demonstrated general performance win or regression here. The binding adds language support, lazy evaluation, and per-request memoization; those semantics are tested separately.

The alpha.15 addon used in the unchanged-policy comparison came from its previously tested macOS archive. Artifact and source hashes identify the snapshots. No unrelated processes were stopped.

## Full SDK and competitor records

`python.json`, `node.json`, and `zig.json` retain complete 45-decision cold/warm runs. Their workload mixture is unchanged from alpha.15. Native Zig excludes host binding conversion costs.

Fresh authorization timing still favors `@marcbachmann/cel-js@8.0.0`: about 0.303 us warm versus 2.147 us for the candidate, roughly 7.1 times faster. The earlier list checkpoint retains the competitors' missing-`flatten` failures on batch dispatch. No full-suite competitor timing is invented from those failures.

All timings use macOS arm64, Node 24.14.1, Zig 0.16.0, ReleaseSafe, and baseline CPU settings. They do not prove effects on other platforms, native memory accounting, or overall SDK performance leadership.
