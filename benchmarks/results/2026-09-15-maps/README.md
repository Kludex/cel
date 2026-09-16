# Typed-map application checkpoint

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate-maps \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/python-maps.json
node benchmarks/typescript.mjs --engine candidate-maps \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node-maps.json
```

Run these commands after building both SDKs. Each request converts its nested input objects into Python `CELMap` or JavaScript `Map`, then evaluates the complete policy. Map construction stays inside the timer. These are the same 27 decisions across six workloads, with five warmups, 30 samples, and correctness checks on every timed result.

The current workload keys are strings. This path measures the typed-map representation cost on complete requests, not numeric-key throughput. Mixed numeric/boolean key behavior is verified separately through the SDK and audit CLI tests.

| Path | Cold, us/decision | Warm, us/decision | Cold / warm relative IQR |
| --- | ---: | ---: | ---: |
| Python ordinary dictionaries | 11.11 | 1.25 | 0.8% / 0.8% |
| Python `CELMap` construction + evaluation | 14.75 | 4.60 | 0.7% / 0.7% |
| Node ordinary objects | 14.00 | 2.43 | 1.2% / 1.5% |
| Node `Map` construction + evaluation | 15.12 | 3.34 | 1.7% / 0.8% |
| `cel-js`, ordinary objects | 15.94 | 9.12 | 2.5% / 0.8% |

All runs satisfy the 5% relative-IQR criterion. Different input representations include different preparation costs; do not present the typed-map rows as native evaluator-only timings.

## Regressions and limits

`paired-node-default.json` alternates alpha.8 and alpha.9 on identical ordinary-object requests. Median times were 2.26 us before and 2.41 us after, a 6.5% increase. The effect is below the existing 10% meaningful-effect threshold, but the observed regression remains visible. Recognizing maps by their actual runtime type adds work even for ordinary objects.

The favorable aggregate against `cel-js` is not performance leadership. Earlier per-workload measurements show the JavaScript competitor substantially faster on authorization and customer-format validation. Those contrary results remain in the [conversion checkpoint](../../profiling/results/2026-09-15-strings/).

Files ending in `before-review.json` retain the initial implementation measurements. `node-maps-descriptors.json` records an intermediate snapshot implementation using per-entry property descriptors. It measured 4.85 us warm; a null-prototype snapshot array avoids that extra allocation while retaining prototype-pollution protections. This was a sequential exploration, not a controlled speedup claim.

Full conformance, native Python competitors, numeric-key application benchmarks, allocation/memory measurements, and performance leadership remain open.
