# Network-extension benchmark checkpoint

All measurements use complete request decisions through public SDK APIs, including binding conversion where applicable. Commands ran from the repository root on macOS arm64 with Node 24.14.1, CPython 3.14.6, and Zig 0.16.0.

## Full 64-decision mix

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate \
  --cold-iterations 300 --warm-iterations 3000 --output python.json
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 300 --warm-iterations 3000 --output node.json
zig build benchmark -Dbenchmarks=true -Doptimize=ReleaseSafe \
  -Dbenchmark-cold-iterations=1000 -Dbenchmark-warm-iterations=3000 > zig.json
```

| Engine | Cold median | Warm median |
| --- | ---: | ---: |
| Python | 7.359 us | 1.471 us |
| Node | 10.149 us | 2.594 us |
| Native Zig | 6.460 us | 0.815 us |

`zig-unstable-first.json` had 5.9% cold relative IQR and is excluded from the table. The seven added gateway decisions change the mixture, so this is not a controlled comparison with alpha.19.

## Paired network hashing comparison

```sh
node benchmarks/profiling/paired.mjs --before /tmp/cel-network-before/dist/index.js \
  --after "$PWD/bindings/typescript/dist/index.js" --iterations 100 \
  --workloads large-workloads.json
```

`large-workloads.json` normalizes and deduplicates 600 prefixes before containment. The before module is the same source tree built before scalar IP/CIDR hashing. Three pairs measured 1,265.5/215.4, 1,265.8/214.9, and 1,271.7/215.4 us per decision, about 5.8-5.9x faster, with relative IQR at or below 4.4%. The ordinary mix (`paired-all-*.json`, 1,000 iterations) changed 0.0-2.5%, below the meaningful-effect threshold.

## Competitors

`cel-js-network.log` and `bufbuild-network.log` record that both pinned JavaScript baselines fail the gateway policy. Original authorization remains their strength: `cel-js-authorization.json` measures 0.309 us warm versus 2.174 us for `node-authorization.json`, about seven times faster. Performance leadership is not established.
