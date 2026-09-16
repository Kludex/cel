# Node plain-data transport validation

## Change

`Program.evaluate` in the Node wrapper flattens plain request data into a `Float64Array` tag stream and a UTF-8 `Uint8Array`, and the native addon decodes them in one boundary crossing. Wrapper classes, `Map`, and byte inputs remain deferred to the per-value native converter together with their plain ancestor chain, so cycle detection and read order stay exact. The shared evaluator skips the qualified-name activation scan when no binding, constant, container, or descriptor registry can supply a dotted name; `net.*` and `google.*` roots still resolve.

## Gates

```sh
./scripts/check
./scripts/test
zig build test -Dbenchmarks=true -Doptimize=ReleaseFast -j4
```

| Gate | Result |
| --- | --- |
| Zig Debug, ReleaseSafe, ReleaseFast | 132 core tests plus one complete-workload test pass |
| Python | 132 tests; wrapper/test line and branch coverage 100% |
| Node | 102 tests; wrapper line/branch/function coverage 100% |
| Audit and benchmark CLI | 71 tests pass |
| Six audits (`audits.txt`) | 2,501 / 7 / 0 full and 2,477 / 6 / 25 evaluation, unchanged |
| Formatting, lint, strict typing | Pass |

## TDD record

`baseline-current-path.txt` pins eight public behaviors on the per-value path before the change: once-only getter reads in enumeration order, earlier-getter effects and error identity before unsupported values, exact numeric/string/byte semantics, wrapper and `Map` interoperability, and cycle/depth/collection/byte limits. `tests-first.txt` records the first flattened build failing five existing public tests: proxy checks ran after prototype traps, `Map` brands were classified after a prototype lookup, byte inputs were read after later getters, and the encoder's arrays hit a poisoned `Array.prototype` setter. Each was corrected and the suite re-run (`tests-second.txt`).

A focused read-only review reproduced two further regressions: deferred `Map` values were snapshotted after later plain getters had run, and the collection budget was enforced only after JavaScript traversal read every element. `red-review-findings.txt` records the failing tests; the encoder now snapshots `Map` entries when reached and mirrors the native value budget. A reentrancy test drives nested `evaluate` calls from a deferred getter. `core-qualified.txt` records the evaluator change with a public Zig test that fails when the skip is forced on for dotted constants.

## Distribution

Linux artifacts were rebuilt from a snapshot with the final `src/node.zig`, `src/eval.zig`, and wrapper (`linux-source.sha256`).

| Check | Result |
| --- | --- |
| Core tests, arm64, glibc 2.28 (`linux-core-arm64.txt`) | 132 pass |
| Core tests, emulated x86-64 (`linux-x86-core.txt`) | 132 pass |
| Wheel from source inside Linux, `auditwheel`, strict `abi3audit` | `manylinux_2_28_aarch64`; 0 mismatches, 0 violations |
| Installed wheel, CPython 3.10.20, glibc 2.28 (`linux-python310.txt`) | 132 pass, 100% coverage |
| Installed npm archive, Node 24, glibc 2.28 | 102 pass, 100% coverage |
| Installed npm archive, Node 22, glibc 2.31 | 102 pass, 100% coverage |
| Six audits on glibc 2.28 (`linux-parity.txt`) | Every field matches macOS |
| macOS installed npm archive (`mac-node-installed.txt`) | 102 pass, 100% coverage |

The first Linux wheel `auditwheel` attempt ran on macOS and failed building `patchelf`; the Linux container run is the recorded result. The first installed-wheel test lacked the Python 3.10 pytest backports and then hit a read-only coverage file; both are recorded in the final log's history, not as test failures. The Linux core binaries and x86 run predate the two review fixes, which touched only `src/node.zig` and the wrapper; the Node package and audits were rebuilt afterward.

Versions were bumped to Python `0.1.0a21` and npm `0.1.0-alpha.21` after these artifacts were built; the recorded packages carry the alpha.20 labels with the alpha.21 native and wrapper contents (`packages.sha256`). The wrapper-to-native argument contract changed, so mixing an older wrapper with this addon is rejected by the native argument-count check.

## Measurements

See [the benchmark checkpoint](../../benchmarks/results/2026-09-16-node-plain/). Warm authorization improved 1.79-1.80x and the 64-decision mix 1.52-1.54x in paired runs. `cel-js` remains about four times faster on warm authorization.
