# Evaluator-path benchmark checkpoint

Complete request decisions through public SDK APIs on macOS arm64 with Node 24.14.1, CPython 3.14.6, and Zig 0.16.0. The host carried unrelated load during parts of this session; runs that failed the 5% relative-IQR threshold are kept with an `-unstable` suffix and excluded from the tables.

## Paired Node comparison

The before module is the plain-data transport build (`validation/2026-09-16-node-plain`). The after module adds the evaluator fast paths and the encoder fixed-cost trims.

| Workload | Run | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: |
| Authorization | 2 | 1,219 ns (3.0%) | 1,099 ns (3.4%) | 1.11x |
| Authorization | 3 | 1,217 ns (4.4%) | 1,118 ns (3.7%) | 1.10x |
| 64-decision mix | 1 | 1,742 ns (4.5%) | 1,599 ns (3.3%) | 1.08x |
| 64-decision mix | 2 | 1,721 ns (2.4%) | 1,598 ns (2.7%) | 1.08x |

These are the final-source runs after the review fix to `lookup`; `paired-authorization-1-unstable.json` (7% IQR) is excluded. An earlier set before the fix measured 1.10-1.12x and 1.08-1.10x with IQR at or below 1.5%.

## Alternating Python comparison

`python-before-*` used the alpha.20 wheel in an isolated interpreter; `python-after-*` used the current build. Runs alternated before/after but are not paired samples.

| Workload | Before warm | After warm |
| --- | ---: | ---: |
| Authorization | 1,037 / 1,034 ns | 978 / 987 ns |
| 64-decision mix | 1,465 / 1,465 ns | 1,432 / 1,425 ns |

The authorization change (about 5%) clears the meaningful-effect threshold only marginally; the mix change (about 2.5%) does not. Neither is claimed as a paired speedup.

## Full 64-decision mix

| Engine | Cold median | Warm median |
| --- | ---: | ---: |
| Python | 7.302 us (0.4%) | 1.429 us (1.0%) |
| Node | 9.203 us (2.8%) | 1.562 us (0.4%) |
| Native Zig | 6.360 us (1.1%) | 0.706 us (0.9%) |

## Competitor

| Engine | Authorization cold | Authorization warm |
| --- | ---: | ---: |
| This SDK (Node) | 3.196 us (3.6%) | 1.117 us (0.9%) |
| `@marcbachmann/cel-js@8.0.0` | 3.273 us (3.5%) | 0.304 us (1.7%) |

Two earlier `cel-js` runs with 8.9% and 55% relative IQR are retained as `cel-js-authorization-unstable*.json`. `cel-js` remains about 3.7x faster on warm authorization; cold times are equivalent within noise. Performance leadership is not established.
