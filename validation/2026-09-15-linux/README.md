# Alpha.13 Linux validation

## Results

| Check | Evidence |
| --- | --- |
| Linux arm64 core, glibc 2.28 and 2.41 | All 87 core tests pass |
| Emulated Linux x86-64 core | All 87 core tests pass; not native x86 performance evidence |
| Linux arm64 wheel, Python 3.10.20 / glibc 2.28 | 86 tests pass, 100% wrapper/test line and branch coverage |
| Same wheel, Python 3.10.18 / glibc 2.31 | 86 tests pass, 100% wrapper/test line and branch coverage |
| Same wheel, Python 3.14.7 / glibc 2.41 | 86 tests pass, 100% wrapper/test line and branch coverage |
| Linux arm64 npm archive, Node 22.14.0 / glibc 2.31 | 68 tests pass, 100% wrapper line/branch/function coverage |
| Same archive, Node 24.14.1 / glibc 2.28, 2.31, 2.41 | 68 tests pass on each, 100% wrapper coverage |
| Installed npm archive application checks | All 39 decisions pass through both unchecked and checked public APIs |
| Full conformance, every SDK, glibc 2.28 and 2.41 | 2,100 passed, four failed, 404 unsupported |
| Evaluation-only conformance, every SDK, both libc versions | 2,075 passed, four failed, 429 unsupported |
| Conformance CLI tests, Linux Python 3.14 | 47 passed using installed binding packages |
| Wheel ABI tools | `auditwheel` accepts `manylinux_2_28_aarch64`; strict `abi3audit` reports no mismatches or violations |
| macOS SDK gates | 88 Zig tests including the application workload; 86 Python, 68 Node, 47 audit CLI tests; coverage, formatting, lint, typing pass |
| macOS sdist-built wheel | All 86 tests pass on Python 3.10, 3.12, 3.13, 3.14; strict stable-ABI audit passes |

The Linux wheel was built from the source distribution inside Linux with Python 3.14.7 headers. The npm archive was built inside Linux, installed with npm into a separate directory, and exercised through its public API. Later runtime-matrix checks unpack the same archive and copy only the public test files and fixtures around it. They do not rebuild its native library.

`parity.json` compares every report field against macOS. `alma-parity.json` repeats that comparison on glibc 2.28. The four preexisting numeric disagreements remain failures; unsupported extension cases remain counted. Wrapper coverage is not native-code coverage. A 1 GiB container limit is not proof of an SDK memory ceiling.

## Regressions reproduced before correction

1. A native Linux build inherited glibc 2.41 from the host and emitted symbols requiring glibc 2.36. The resulting wheel failed to import on glibc 2.31. `red-old-glibc-wheel.txt` records the public import failure. `wheel-policy-gate.txt` records `auditwheel` rejecting that artifact for the 2.28 policy. GNU targets now default to 2.28 unless you supply an explicit version.
2. With that correction, the wheel still failed to load on Python 3.10 because it imported `Py_TYPE`, a Python 3.14 ABI symbol. Zig's C importer selected that declaration instead of the older compatibility macro. Both direct calls and translated `*_Check` macros were affected. `red-python310-abi.txt`, `red-stable-abi.txt`, and `intermediate-macro-abi.txt` retain the failures. Exact comparisons now use `Py_IS_TYPE`; flag checks use the stable `PyObject.ob_type` field and `PyType_HasFeature`.

The workflow now enforces the manylinux policy, runs strict `abi3audit`, and tests each wheel on Python 3.10. Remote CI has not executed. A focused independent review found no semantic or stable-ABI regression and requested exact-floor runtime evidence; the subsequent AlmaLinux checks supply local glibc 2.28 evidence. CI still needs execution and an exact-floor runtime job before it provides equivalent evidence remotely.

## Reproduce core execution

```sh
zig build test-install -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe \
  --prefix /tmp/cel-linux-current/arm64 -j4

docker run --rm --network none --read-only --tmpfs /tmp --cpus=2 --memory=1g \
  -v /tmp/cel-linux-current/arm64/bin/cel-test:/cel-test:ro \
  almalinux@sha256:9f355ae942d6a6c0561f0771dc053a2cfae9580fc45fa4252756db7c7e80c09f \
  sh -c 'mkdir /tmp/zig-cache; /cel-test --cache-dir=/tmp/zig-cache'
```

Run this on an arm64 Docker host with Zig 0.16.0. The compiler can cross-link on macOS; the container executes the Linux binary. The x86-64 check uses `-Dtarget=x86_64-linux-gnu`, `--platform linux/amd64`, and the pinned x86 Python image below. Its execution is emulated on this host.

## Reproduce the wheel ABI gates

```sh
uv build --project bindings/python --out-dir /tmp/cel-wheel
uvx --from auditwheel==6.5.0 --with patchelf==0.18.0.0 auditwheel repair \
  --plat manylinux_2_28_$(uname -m) --only-plat \
  --wheel-dir /tmp/cel-manylinux /tmp/cel-wheel/*.whl
uvx abi3audit==0.0.26 --strict /tmp/cel-manylinux/*.whl
```

Run these commands on GNU/Linux with the documented SDK toolchains. The recorded offline source build used `python -m build --wheel --no-isolation` inside the pinned Python image, with Zig 0.16.0, build 1.3.0, hatchling 1.29.0, and the dependency wheels in `dependencies.sha256`. Zig 0.16's global package cache needs the three hash-named `.tar.gz` archives, not just expanded source directories. `final-source-wheel-build.txt` records the successful build and manylinux conversion.

For the minimum-libc Python check, `uv python install cpython-3.10.20-linux-aarch64-gnu --install-dir /tmp/cel-linux-current/python310 --no-bin` supplied a standalone interpreter. Its download URL is recorded in `python-downloads.json`. Tests installed the wheel and pytest dependencies offline into `/tmp/site`; `PYTHONPATH` pointed only there. The installed `cel.__file__` path was checked before running the suite.

## Runtime images

| Purpose | Pinned image |
| --- | --- |
| Native Python build, glibc 2.41 | `python@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6` |
| Older Python runtime, glibc 2.31 | `python@sha256:f1fb49e4d5501ac93d0ca519fb7ee6250842245aba8612926a46a0832a1ed089` |
| Exact glibc 2.28 floor | `almalinux@sha256:9f355ae942d6a6c0561f0771dc053a2cfae9580fc45fa4252756db7c7e80c09f` |
| Native Node 24 build, glibc 2.36 | `node@sha256:b506e7321f176aae77317f99d67a24b272c1f09f1d10f1761f2773447d8da26c` |
| Node 22, glibc 2.31 | `node@sha256:73a9dfbb6c761aebdf4666cce2627635a30d1d4c20f67ff642d01b8f09e709a3` |
| Emulated x86 core | `python@sha256:810da6270e43d30a1f3e0e1eabbeb6fbd9d78ad9dd2e754d5297a3d6cb42df46` |

Dependency downloads ran separately. Builds and runtime checks disabled networking. Containers used a read-only project mount and root filesystem, with an executable temporary filesystem for installed native modules. Builds had four CPUs and 4 GiB; tests had two CPUs and 1 GiB. The timezone mount contains the complete Debian 2026c data recorded in the earlier strong-enum validation. The SDK still depends on host timezone data.

## Retained setup failures

The logs retain a no-exec temporary mount failure, missing Python 3.10-only pytest dependencies, an initially missing `patchelf`, and the expanded-versus-archived Zig cache mistake. One source-copy Node build reported a truncated `build.zig`; rebuilding from an immutable source archive with matching source hashes succeeded. Its root cause is not established. These attempts are not counted as successful builds.

Node excludes `node_modules` from default coverage. The first installed-package runs therefore displayed an empty coverage report. The final `node-coverage-*`, `node22-package.txt`, and `alma-core-and-node.txt` runs explicitly include `**/cel/dist/index.js`, and show the actual wrapper at 100%.

## Performance and remaining scope

[Whole-application before/after measurements](../../benchmarks/results/2026-09-15-linux-abi/) use all 39 decisions and show no meaningful performance change. The [native Python competitor probe](../../benchmarks/results/2026-09-15-linux-python-native/) passes 22 decisions but cannot execute the remaining workloads. Its adapter was corrected to call `Program.execute(Context)`; `native-competitor-adapter-smoke.json` is a one-sample CLI correctness check, not a performance result.

These packages remain unpublished. Current x86-64 binding runtime checks, Windows/browser support, multi-platform npm distribution, older macOS versions, native coverage, foreign allocator failure injection, memory accounting, and performance leadership remain open. Container execution does not establish behavior on every Linux kernel or on physical x86 hardware.
