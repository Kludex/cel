# Direct-Zig audit iteration: application checkpoint

```sh
zig build benchmark -Dbenchmarks=true -Doptimize=ReleaseSafe > /tmp/zig.json
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/python.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node.json
```

Each runner evaluates all 27 application decisions, with five warmups, 30 samples, and correctness checks on timed results. These are existing product entry points, not timings of the new JSON audit transport.

| API | Cold, us/decision | Warm, us/decision | Cold / warm relative IQR |
| --- | ---: | ---: | ---: |
| Zig native values | 10.12 | 0.67 | 0.8% / 1.2% |
| Python ordinary dictionaries | 10.98 | 1.24 | 1.2% / 1.4% |
| Node ordinary objects | 13.92 | 2.42 | 1.7% / 1.6% |

All runs meet the existing 5% relative-IQR criterion. No product runtime change was made in this pass, so these are validation checkpoints, not controlled speedup evidence. Zig starts with native values; Python and Node include binding conversion, so their medians are not interchangeable.

Competitors were not retimed in this tooling pass. Earlier faster JavaScript authorization/customer-format results and the pure-Python nanosecond correctness failure remain visible in the [map checkpoint](../2026-09-15-maps/) and [conversion experiments](../../profiling/results/2026-09-15-strings/). Performance leadership remains unproven.
