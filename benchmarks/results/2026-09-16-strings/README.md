# String-extension application measurements

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 500 --warm-iterations 2500 --output /tmp/python-strings.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 500 --warm-iterations 2500 --output /tmp/node-strings.json
zig build benchmark -Dbenchmarks=true -Doptimize=ReleaseSafe \
  -Dbenchmark-cold-iterations=500 -Dbenchmark-warm-iterations=5000 -j4
```

The suite now has 51 complete decisions across ten workloads. Text ingestion normalizes a name, validates the resulting slug, splits/normalizes/joins permission labels, checks revision bounds, and verifies a formatted canonical key. It contains both accepted and rejected requests. Every timed decision is checked against its expected result.

## Results

| SDK | Cold, us/decision | Warm, us/decision | Relative IQR, cold/warm |
| --- | ---: | ---: | ---: |
| Python | 8.277 | 1.442 | 0.6% / 0.5% |
| Node | 11.056 | 2.547 | 2.7% / 0.4% |
| Native Zig | 7.344 | 0.807 | 0.8% / 0.5% |

All runs retain 30 samples after five warmups and satisfy the 5% relative-IQR criterion. Python and Node include binding conversion; native Zig starts with native values. The changed workload mixture cannot be compared directly with earlier aggregate timings. No optimization or performance-leadership claim is made from this table.

## Contrary competitor evidence

Fresh authorization measurements still favor `@marcbachmann/cel-js@8.0.0`: 0.304 us warm versus 2.107 us for the candidate, about 6.9 times faster. Cold medians are 3.247 us versus 4.176 us.

The `cel-js` text-policy run fails at a missing `string.replace(string, string)` overload. `@bufbuild/cel@0.6.1` fails at an unbound `bind` function. Both logs are retained. Neither failure is represented as a successful full-suite timing.

## Scope

Measurements use macOS arm64, Node 24.14.1, Zig 0.16.0, ReleaseSafe, and baseline CPU settings. No unrelated host processes were stopped. [Validation records](../../../validation/2026-09-16-strings/) include public tests, independent formatting/search checks, resource limits, and retained implementation failures. Complete native memory accounting, other-platform performance, and representative native Python competition remain open.
