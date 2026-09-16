# Optional-data application checkpoint

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/python-optionals.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node-optionals.json
zig build benchmark -Dbenchmarks=true -Doptimize=ReleaseSafe > /tmp/zig-optionals.json
```

The suite now contains 33 complete decisions across seven workloads. The new authorization policy handles missing and null principals, missing roles, inactive users, and deleted resources. Every timed decision is checked, with five warmups and 30 samples. The changed mixture is not directly comparable with earlier 27-decision aggregates.

| API | Cold, us/decision | Warm, us/decision | Cold / warm relative IQR |
| --- | ---: | ---: | ---: |
| Python | 9.61 | 1.23 | 0.5% / 0.7% |
| Node | 12.22 | 2.43 | 0.5% / 0.4% |
| Zig native values | 8.66 | 0.64 | 0.2% / 0.8% |

All runs satisfy the existing 5% relative-IQR criterion. Zig starts with native values; Python and Node include binding conversion. No cross-API or historical speedup is claimed.

## Competitor coverage and contrary evidence

The `cel-js` adapter now enables the documented `enableOptionalTypes` option. Its full-suite run still fails because `optional.ofNonZeroValue(dyn)` has no matching overload. `cel-js.log` retains that result, and `cel-js-disabled-optionals.log` retains the initial configuration attempt.

`bufbuild.log` records a parser failure on the optional policy. Its parser exposes no optional-syntax configuration. `cel-python.log` records the pure-Python parser failure. No baseline receives a full-suite timing after a failed correctness/compilation check, and the policy is not weakened to obtain one.

A separate original-authorization run still strongly favors `cel-js`: 0.303 us versus 2.439 us for the Node candidate, about an 8x gap. Both runs have relative IQR below 2%. `cel-python-temporal.log` separately confirms its existing one-nanosecond deadline correctness failure.

These results demonstrate feature coverage and current workload costs, not performance leadership.
