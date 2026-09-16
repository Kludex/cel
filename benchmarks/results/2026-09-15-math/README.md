# Math-extension application checkpoint

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/python-math.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node-math.json
zig build benchmark -Dbenchmarks=true -Doptimize=ReleaseSafe \
  -Dbenchmark-cold-iterations=1000 -Dbenchmark-warm-iterations=10000 > /tmp/zig-math.json
```

The suite now has 39 decisions across eight workloads. The new policy checks permission bits, positive unit requests, finite CPU estimates, rounded CPU consumption, cumulative quota, and absolute adjustment limits. All timed decisions are checked, with five warmups and 30 samples. The mixture differs from earlier 33- and 27-decision suites.

| API | Cold, us/decision | Warm, us/decision | Cold / warm relative IQR |
| --- | ---: | ---: | ---: |
| Python | 8.62 | 1.25 | 0.3% / 0.6% |
| Node | 11.45 | 2.56 | 0.5% / 0.5% |
| Zig native values | 7.83 | 0.64 | 0.9% / 1.7% |

All final runs meet the 5% relative-IQR criterion. Zig uses native inputs, unlike the binding-inclusive Python/Node measurements. No cross-API speedup or historical aggregate improvement is claimed.

Two longer Zig command attempts timed out without producing reports. `zig-timeout.json` retains the empty first output. A smaller diagnostic run completed, and the final configurable-iteration run kept every sample above 100 ms: at least 301 ms cold and 244 ms warm. The timeout cause was not established, so those attempts are not treated as successful measurements.

## Contrary results and unsupported paths

The original authorization policy remains much faster in `cel-js`: 0.304 us versus 2.433 us for the Node candidate, about an 8x gap. Both separate runs have relative IQR below 2%.

`cel-js-quota.log` records a missing `bitAnd` overload. `bufbuild-quota.log` records unbound math functions. No complete quota-workload baseline timing is reported after these failures. Existing optional-policy failures also prevent a full-suite competitor comparison; the math expression is not rewritten to hide unsupported operations.

`protobuf-quota.log` records a different limitation: protobuf `Struct` encodes numeric inputs as doubles, so its existing round-trip adapter cannot supply integer permission masks. That is a transport mismatch, not permission to relax the math overload. Use a descriptor-backed integer field for this kind of application. The older protobuf workload measurements remain historical, not evidence that this new path succeeds.

These are feature and cost checkpoints. Performance leadership, representative native Python competition, and allocation/memory evidence remain open.
