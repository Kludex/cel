# Protobuf-helper and encoder application measurements

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 500 --warm-iterations 2500 --output /tmp/python-encoders.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 500 --warm-iterations 2500 --output /tmp/node-encoders.json
zig build benchmark -Dbenchmarks=true -Doptimize=ReleaseSafe \
  -Dbenchmark-cold-iterations=500 -Dbenchmark-warm-iterations=5000 -j4
```

The suite now contains 57 complete decisions across eleven workloads. Attachment ingestion checks enablement and media type, decodes the payload, enforces a byte quota, compares expected content, and verifies canonical Base64 representation. Cases include allowed, unpadded, oversized, wrong-content, wrong-media, and disabled requests. Base64 is not treated as authentication or encryption.

## Results

| SDK | Cold, us/decision | Warm, us/decision |
| --- | ---: | ---: |
| Python | 7.730 | 1.394 |
| Node | 10.400 | 2.477 |
| Native Zig | 6.783 | 0.776 |

All runs use five warmups and 30 retained samples. Relative IQRs are below 1.8%. Python and Node include input/output conversion; native Zig begins with native values. The changed workload mixture cannot establish an improvement over earlier aggregates. No unrelated host processes were stopped.

## Contrary competitor evidence

The original authorization workload still favors `@marcbachmann/cel-js@8.0.0`: about 0.304 us warm versus 2.110 us for the candidate, approximately 6.9 times faster. Cold medians are 3.245 us versus 4.247 us.

The `cel-js` attachment run fails on the namespace decoder. Its separate `bytes.base64()` method does not supply that decoder. `@bufbuild/cel@0.6.1` fails on the unbound `bind` function. Error logs are retained; neither failure is reported as a complete-suite timing.

Measurements use macOS arm64, Node 24.14.1, Zig 0.16.0, ReleaseSafe, and baseline CPU settings. Protobuf helpers are exercised through public descriptor-backed policies and conformance tests; this checkpoint does not isolate or claim a protobuf-helper speedup. [Validation records](../../../validation/2026-09-16-proto-encoders/) identify correctness, resource, package, and platform checks.
