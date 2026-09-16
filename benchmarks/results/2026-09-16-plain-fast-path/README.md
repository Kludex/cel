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
| 64-decision mix | 1 | 1,382 ns (1.1%) | 1,320 ns (0.8%) | 1.04x |

Only the authorization policy is inside the compiled subset; the other eleven workloads fall back to the engine, which is why the mix moves 4%. These runs include the lone-surrogate guard added after review; before it the fast path measured about 107 ns (8.7-8.9x).

## Against `@marcbachmann/cel-js@8.0.0` on authorization

| Engine | Cold | Warm |
| --- | ---: | ---: |
| This SDK, default (`node-default-authorization.json`) | 2,677 ns (2.6%) | 966 ns (1.0%) |
| This SDK, `plainData: true` (`node-plain-authorization.json`) | 9,415 ns (1.4%) | 141 ns (3.0%) |
| `cel-js` (`cel-js-authorization.json`) | 3,198 ns (1.7%) | 304 ns (1.8%) |

Warm plain-data authorization is about 2.2x faster than `cel-js`; this is the first workload where the Node binding leads that competitor. Cold plain-data time is higher because the benchmark compiles a fresh program per iteration and the fast path adds a `new Function` compilation (about 6 us) on first plain-data use; programs that never opt in pay nothing (default cold is unchanged at about 2.7 us).

## Honesty

This is one workload, one competitor, and an opt-in mode with documented behavioral differences from the default path (unused getters are not read, repeated reads are not snapshotted, non-enumerable properties are visible). The default path remains 3.2x behind `cel-js` on this workload. It is evidence of a viable route to leadership on plain-data policies, not leadership across the suite.
