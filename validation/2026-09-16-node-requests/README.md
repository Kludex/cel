# Alpha.14 Node request validation

## Public behavior

```sh
npm test --prefix bindings/typescript
./scripts/test
./scripts/check
```

The Node suite now has 75 tests. New public cases cover altered Map prototypes, proxy traps, mutable `Symbol.hasInstance`, optional subclasses, reentrant optional getters, key order, late property additions, enumerable symbols, captured property intrinsics, and inherited array setters.

`red-map-brand.txt` records two failures before the change: a real Map could be misclassified as an optional, and a proxy prototype trap ran before rejection. `property-contract-before.txt` establishes existing enumeration behavior before replacing its implementation. The tests drive `Program.evaluate()` and checked environments, not private converter functions.

Map/plain-object classification now precedes optional-wrapper `instanceof`. This intentionally stops custom optional instance hooks from intercepting ordinary records and Maps. Key enumeration uses captured JavaScript intrinsics through one native callback. Enumerable symbols remain ordered after string keys, so preceding getter effects and exception identity remain intact. Appended symbol keys use a null-prototype array to avoid inherited setters.

## Gates

| Check | Result |
| --- | --- |
| macOS core, Debug and ReleaseSafe | 87 core tests plus one complete-application workload test pass |
| macOS Python wrapper | 86 tests, 100% wrapper/test line and branch coverage |
| macOS Node wrapper | 75 tests, 100% wrapper line/branch/function coverage |
| Audit CLI | 47 tests pass |
| Full corpus, all three SDKs | 2,100 passed, four failed, 404 unsupported |
| Evaluation-only corpus, all three SDKs | 2,075 passed, four failed, 429 unsupported |
| Formatting, lint, strict typing | Pass |
| macOS installed npm archive, Node 24.14.1 | 75 tests and explicit installed-wrapper coverage pass |
| Linux installed npm archive, Node 22.14.0 / glibc 2.31 | 75 tests and wrapper coverage pass |
| Same Linux archive, Node 24.14.1 / glibc 2.28 | 75 tests and wrapper coverage pass |
| Linux Node full/evaluation audits, glibc 2.28 | Every report field matches macOS |
| macOS sdist-built wheel | 86 tests pass on Python 3.10, 3.12, 3.13, 3.14 |
| Linux sdist-built wheel, Python 3.10.20 / glibc 2.28 | 86 tests and wrapper/test coverage pass |
| Python ABI gates | Strict `abi3audit` passes for both wheels; Linux wheel passes the manylinux 2.28 policy |

The four preexisting numeric disagreements and all unsupported cases remain visible. Shared-core parity does not establish independent correctness. Wrapper percentages exclude Zig, C++, and FFI native code. No new native fuzz-coverage claim is made for this pass.

## Package and runtime reproduction

```sh
uv build --project bindings/python --out-dir /tmp/cel-packages
(cd bindings/typescript && npm pack --pack-destination /tmp/cel-packages)
```

Build the addon with the Node test command first. The archives remain unpublished and contain platform-specific binaries. The Linux addon was built from an immutable source snapshot inside the pinned Node 24 image. Tests copied the public suite and fixtures around the installed payload without rebuilding it. Coverage explicitly includes `**/cel/dist/index.js`, because Node otherwise excludes `node_modules`.

Linux setup reuses the pinned compiler, dependency archives, Python runtimes, and complete timezone data documented in [the Linux validation record](../2026-09-15-linux/). Node 24 uses `node@sha256:b506e7321f176aae77317f99d67a24b272c1f09f1d10f1761f2773447d8da26c`; Node 22 uses `node@sha256:73a9dfbb6c761aebdf4666cce2627635a30d1d4c20f67ff642d01b8f09e709a3`. Minimum-libc execution uses `almalinux@sha256:9f355ae942d6a6c0561f0771dc053a2cfae9580fc45fa4252756db7c7e80c09f`.

Build and runtime containers disable networking and mount the project read-only. Builds use two CPUs and 4 GiB; tests use two CPUs and 1 GiB. The container limits do not prove SDK memory accounting. Current x86-64 addon execution, Windows/browser support, multi-platform npm installation, older macOS support, and remote CI remain open.

## Performance evidence

[The benchmark checkpoint](../../benchmarks/results/2026-09-16-node-requests/) retains profiles, raw samples, the baseline restoration patch, and the rejected fused-transport experiment. Complete authorization requests improve by 13-15% in stable paired runs; the 39-decision mix improves by 10.7-11.5%. A clean-build reproduction confirms a 14.7% authorization reduction. The first clean-build run was unstable and remains recorded separately.

The pinned `cel-js` baseline still evaluates authorization about 6.9 times faster. These results are progress on conversion cost, not performance leadership or a claim covering every workload and platform.
