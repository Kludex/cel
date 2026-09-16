# Callback-backed application policies

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate-functions \
  --cold-iterations 400 --warm-iterations 5000 --output /tmp/python-callbacks.json
node benchmarks/typescript.mjs --engine candidate-functions \
  --cold-iterations 400 --warm-iterations 5000 --output /tmp/node-callbacks.json
zig build benchmark -Dbenchmarks=true -Dbenchmark-functions=true -Doptimize=ReleaseSafe \
  > /tmp/zig-callbacks.json
```

All three runners verify the same 27 complete request decisions. The authorization policy delegates its role/ownership check to the trusted `is_allowed(role, owner, user)` callback. Method, route, authentication, argument conversion, return conversion, and the rest of the policy stay in the measured request. This is not a benchmark of an isolated callback.

The callback mode uses checked environments. Environment setup is outside timing, while cold samples include parsing, checking, compilation, and evaluation. Warm samples reuse programs. Every timed decision is checked, with five warmups and 30 samples. The other five workloads remain ordinary CEL expressions.

| Path | Cold, us/decision | Warm, us/decision | Cold / warm relative IQR |
| --- | ---: | ---: | ---: |
| Python, callback mode | 15.69 | 1.28 | 0.4% / 0.5% |
| Node, callback mode | 19.03 | 2.45 | 0.8% / 0.6% |
| Zig native values, callback mode | 13.89 | 0.65 | 0.4% / 0.5% |
| Python, default unchecked policies | 11.21 | 1.31 | 0.6% / 0.6% |
| Node, default unchecked policies | 13.86 | 2.43 | 1.9% / 0.6% |

All runs meet the 5% relative-IQR criterion. These modes differ in checking and policy implementation, so their differences do not isolate callback overhead or establish a speedup. The Zig path starts with native values and cannot be compared directly with host binding conversion.

The callback workload is synchronous and in-memory. It does not establish latency or cancellation guarantees for callbacks that perform I/O or block. Host callbacks are trusted code and can exceed CEL's engine-work budget in external work.

Competitors were not retimed for custom callbacks in this pass. Earlier faster JavaScript authorization results and the pure-Python nanosecond failure remain visible in prior checkpoints. No overall performance-leadership claim is made.
