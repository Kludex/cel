# Node plain-data fast path checkpoint

Complete request decisions through the public Node API, macOS arm64, Node 24.14.1, Zig 0.16.0 `ReleaseSafe`. Same build for both columns; `--after-options '{"plainData":true}'` selects the fast path.

```sh
node benchmarks/profiling/paired.mjs --before "$PWD/bindings/typescript/dist/index.js" \
  --after "$PWD/bindings/typescript/dist/index.js" --after-options '{"plainData":true}' \
  --iterations 5000 --workload request_authorization
node benchmarks/typescript.mjs --engine candidate-plain --workload request_authorization --output /tmp/plain.json
```

## Paired: default engine path versus plain-data mode

| Workload | Run | Default | `plainData: true` | Speedup |
| --- | --- | ---: | ---: | ---: |
| Authorization | 1 | 955 ns (1.1%) | 138 ns (3.3%) | 6.92x |
| Authorization | 2 | 959 ns (1.4%) | 137 ns (3.6%) | 7.00x |
| Authorization | 3 | 950 ns (1.5%) | 135 ns (3.9%) | 7.05x |
| Routing | 1 | 629 ns (1.2%) | 92 ns (1.8%) | 6.86x |
| Routing | 2 | 625 ns (0.9%) | 93 ns (2.2%) | 6.74x |
| 64-decision mix | 1 | 1,377 ns (0.4%) | 1,280 ns (0.8%) | 1.08x |

Authorization and routing are inside the compiled subset (the second after adding string conditionals and string-literal indexing); the other ten workloads fall back to the engine, which is why the mix moves 8%. The authorization runs include the lone-surrogate guard added after review; before it the fast path measured about 107 ns (8.7-8.9x).

## Against `@marcbachmann/cel-js@8.0.0`

| Workload | Engine | Cold | Warm |
| --- | --- | ---: | ---: |
| Authorization | This SDK, default | 2,677 ns (2.6%) | 966 ns (1.0%) |
| Authorization | This SDK, `plainData: true` | 9,415 ns (1.4%) | 141 ns (3.0%) |
| Authorization | `cel-js` | 3,198 ns (1.7%) | 304 ns (1.8%) |
| Routing | This SDK, `plainData: true` | 7,616 ns (1.5%) | 100 ns (1.9%) |
| Routing | `cel-js` | 3,254 ns (2.0%) | 254 ns (1.5%) |

Warm plain-data authorization is about 2.2x faster than `cel-js` and routing about 2.5x; these are the first workloads where the Node binding leads that competitor. Cold plain-data time is higher because the benchmark compiles a fresh program per iteration and the fast path adds a `new Function` compilation (about 6 us) on first plain-data use; programs that never opt in pay nothing (default cold is unchanged at about 2.7 us).

## Honesty

This is one workload, one competitor, and an opt-in mode with documented behavioral differences from the default path (unused getters are not read, repeated reads are not snapshotted, non-enumerable properties are visible). The default path remains 3.2x behind `cel-js` on this workload. It is evidence of a viable route to leadership on plain-data policies, not leadership across the suite.

## Python counterpart

`evaluate(bindings, plain_data=True)` compiles the same plan to a Python function (`cel/plain.py`, `exec`-generated straight-line code with `type(...) is` guards, root reads hoisted, object reads cached per block, dotted-key shadowing checked with one `frozenset.isdisjoint`). Alternating runs on CPython 3.14.6; two runs taken while a concurrent command was aborted have IQR over 10% and are kept as `-unstable`.

| Workload | Default warm | `plain_data=True` warm | Speedup |
| --- | ---: | ---: | ---: |
| Authorization | 825 ns (3.2%) | 546 / 548 ns (0.7-2.8%) | 1.5x |
| Routing | 632 / 622 ns (1.3-1.7%) | 415 ns (1.4%) | 1.5x |

Cold plain-data time is about 165 us for authorization because `compile()` of the generated source runs on first plain-data use; programs that never opt in pay nothing. The Python interpreter itself bounds this mode: an unguarded hand-written Python expression for the same policy measures about 170 ns, so a guarded generated function cannot approach the Node fast path's 137 ns.
