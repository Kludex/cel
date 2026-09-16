# Alpha.7 application benchmark checkpoint

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/python-candidate.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node-candidate.json
node benchmarks/typescript.mjs --engine cel-js \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node-cel-js.json
node benchmarks/typescript.mjs --engine bufbuild \
  --cold-iterations 100 --warm-iterations 2000 --output /tmp/node-bufbuild.json
```

Run these commands after building both bindings in `ReleaseSafe`. Each run uses five warmups, 30 samples, and all 27 application decisions. Every timed decision is checked. These runs exercise the unchanged default SDK mode, not enum-specific policies.

| Engine | Cold, us/decision | Warm, us/decision | Cold / warm relative IQR |
| --- | ---: | ---: | ---: |
| Python candidate | 11.07 | 1.33 | 1.2% / 1.2% |
| Node candidate | 13.82 | 2.51 | 1.9% / 1.8% |
| `@marcbachmann/cel-js` | 15.89 | 9.39 | 2.7% / 3.6% |
| `@bufbuild/cel` | 109.68 | 17.40 | 2.2% / 2.0% |

All runs meet the existing 5% relative-IQR criterion. Candidate warm differences from the previous temporal checkpoint are below the 10% meaningful-effect threshold. This is not a controlled speedup experiment or proof of performance leadership. `host-load.txt` records concurrent host activity; no unrelated process was stopped.

## Contrary workload result

```sh
node benchmarks/typescript.mjs --engine candidate --workload request_authorization \
  --cold-iterations 20000 --warm-iterations 100000 --output /tmp/node-authorization.json
node benchmarks/typescript.mjs --engine cel-js --workload request_authorization \
  --cold-iterations 20000 --warm-iterations 100000 --output /tmp/node-cel-js-authorization.json
```

On the original authorization workload, Node candidate warm requests take 2.28 us versus 0.30 us for `cel-js`. Both warm relative IQRs are about 1%. The candidate remains roughly 7.6 times slower on this workload despite its favorable full-suite aggregate.

`cel-python==0.5.0` still accepts a request exceeding its deadline by one nanosecond. `python-cel-python-failure.txt` retains the failed correctness check; no complete-suite timing is reported for it. A native Python competitor remains necessary before making a Python performance-leadership claim.

`artifacts.sha256` identifies the timed native binaries and wrapper code. `source.sha256` records the source checkpoint after a subsequent change confined to test-only checked-source fuzz generation. No production behavior changed between timing and that source checkpoint.
