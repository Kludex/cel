# Alpha.8 application measurements

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/python-candidate.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node-candidate.json
```

Both runs use all 27 complete application decisions, five warmups, and 30 samples. Every timed decision is checked.

| SDK | Cold, us/decision | Warm, us/decision | Cold / warm relative IQR |
| --- | ---: | ---: | ---: |
| Python | 11.05 | 1.21 | 2.8% / 1.0% |
| Node | 13.51 | 2.26 | 3.6% / 2.4% |

These are current absolute measurements, not a controlled comparison with the previous release. [Paired converter experiments](../../profiling/results/2026-09-15-strings/) isolate the Node changes and retain the slower alternatives. Customer-format validation improves by about 10-15%, while the full-mix effect is below the 10% meaningful elapsed-effect threshold.

The separate authorization comparison still favors `cel-js`, roughly 0.31 us versus 2.04 us for the candidate. Its customer-format median is also faster, about 0.55 us versus 1.31 us. The candidate is not claimed to be the fastest SDK.

`python-cel-python-failure.txt` records the pure-Python baseline accepting a request that exceeds its deadline by one nanosecond. Its complete-suite run stops before timing. Native Python competition and allocation/memory measurements remain necessary.
