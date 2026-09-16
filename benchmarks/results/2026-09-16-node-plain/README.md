# Node plain-data transport benchmark checkpoint

Complete request decisions through public SDK APIs on macOS arm64 with Node 24.14.1, CPython 3.14.6, and Zig 0.16.0. Commands ran from the repository root.

## Paired before/after comparison

```sh
node benchmarks/profiling/paired.mjs --before /tmp/cel-plain-before/dist/index.js \
  --after "$PWD/bindings/typescript/dist/index.js" --iterations 5000 --workload request_authorization
node benchmarks/profiling/paired.mjs --before /tmp/cel-plain-before/dist/index.js \
  --after "$PWD/bindings/typescript/dist/index.js" --iterations 800
```

The before module is the alpha.20 network build (`validation/2026-09-16-node-plain/before-native.sha256`). The after module contains the flattened plain-data transport and the qualified-name scan skip, including the two review fixes.

| Workload | Run | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: |
| Authorization | 1 | 2,145 ns (1.1%) | 1,194 ns (0.9%) | 1.79x |
| Authorization | 2 | 2,152 ns (1.3%) | 1,196 ns (1.3%) | 1.80x |
| Authorization | 3 | 2,175 ns (1.0%) | 1,204 ns (1.0%) | 1.80x |
| 64-decision mix | 1 | 2,608 ns (0.8%) | 1,693 ns (0.5%) | 1.54x |
| 64-decision mix | 2 | 2,593 ns (0.8%) | 1,698 ns (0.5%) | 1.52x |

Parentheses show relative IQR. Every run satisfies the stability threshold and the meaningful-effect threshold.

## Full 64-decision mix

| Engine | Cold median | Warm median |
| --- | ---: | ---: |
| Python | 7.322 us (0.5%) | 1.420 us (0.6%) |
| Node | 9.483 us (2.9%) | 1.713 us (0.7%) |
| Native Zig | 6.415 us (0.4%) | 0.762 us (0.5%) |

Python and Zig received only the evaluator change. Their warm medians moved from 1.471 to 1.420 us and 0.815 to 0.762 us relative to the network checkpoint; those are unpaired runs and below the meaningful-effect threshold, so no Python or Zig speedup is claimed.

## Competitor

| Engine | Authorization cold | Authorization warm |
| --- | ---: | ---: |
| This SDK (Node) | 3.312 us (3.8%) | 1.209 us (1.6%) |
| `@marcbachmann/cel-js@8.0.0` | 3.191 us (1.0%) | 0.303 us (1.3%) |

`cel-js` remains about four times faster on warm authorization; cold times are now within 4%. Performance leadership is not established.
