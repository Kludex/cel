# Strong enum validation

## Linux core reproduction

```sh
zig build test-install -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe \
  --prefix /tmp/cel-linux-enums/arm64 -j4
zig build test-install -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe \
  --prefix /tmp/cel-linux-enums/amd64 -j4

docker run --rm --network none --read-only --tmpfs /tmp --cpus=2 --memory=1g \
  -v /tmp/cel-linux-enums/arm64/bin/cel-test:/cel-test:ro \
  python@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6 \
  sh -c 'mkdir /tmp/zig-cache; /cel-test --cache-dir=/tmp/zig-cache'

docker run --rm --platform linux/amd64 --network none --read-only --tmpfs /tmp \
  --cpus=2 --memory=1g \
  -v /tmp/cel-linux-enums/amd64/bin/cel-test:/cel-test:ro \
  python@sha256:810da6270e43d30a1f3e0e1eabbeb6fbd9d78ad9dd2e754d5297a3d6cb42df46 \
  sh -c 'mkdir /tmp/zig-cache; /cel-test --cache-dir=/tmp/zig-cache'
```

Run these commands from the repository root with Zig 0.16.0 and Docker available. Both executables pass all 54 core tests. Docker Desktop runs the arm64 executable in its Linux VM. The x86-64 run uses emulation, not native x86 hardware. These are correctness checks, not performance measurements.

## Runtime and package evidence

| Check | Result |
| --- | --- |
| macOS Zig Debug, ReleaseSafe, ReleaseFast | 54 core tests and one application-workload test pass |
| Python macOS wheel | 45 tests pass on CPython 3.10, 3.12, 3.13, 3.14 |
| Node macOS addon | 24 tests pass on Node 22.14.0 and 24.14.1 |
| Linux arm64 Python | 45 tests pass on CPython 3.14.7 |
| Linux arm64 Node | 24 tests pass on Node 24.14.1 |
| Wrapper coverage | Python line/branch and Node line/branch/function gates pass at 100% |
| Conformance CLI | Six self-tests pass on macOS and Linux arm64 |
| Full conformance | Both bindings pass 1,820, fail four, and leave 684 unsupported |
| Evaluation-only conformance | Both bindings pass 1,806, fail four, and leave 698 unsupported |

The Python alpha.7 wheel was built from its source distribution. The alpha.7 npm archive was installed into a separate directory and exercised through its public enum API. Neither package was published. Linux binding tests load cross-compiled native libraries with the source-tree wrappers; they do not establish Linux wheel or npm-distribution portability.

Linux Python headers came from the pinned Python image above. The Node runtime came from `node@sha256:b506e7321f176aae77317f99d67a24b272c1f09f1d10f1761f2773447d8da26c`. Actual tests ran with networking disabled, a read-only project mount, two CPUs, and a 1 GiB container limit. That container limit is not an SDK memory-accounting guarantee.

Each of the six fuzz targets completed another 100,000 or more executions. `fuzz-*.txt` records the runs. The checked-source target now varies strong-enum mode and seeds enum constructors and references. Fuzzer edge counts and wrapper coverage do not establish complete native coverage.

## Timezone dependency

```sh
apt-get update
apt-get install --no-install-recommends -y tzdata tzdata-legacy
```

Run these commands as root on Debian 13. The base Python image has `tzdata` 2026b but lacks `tzdata-legacy`. Its full audit has two additional failures because `US/Central` is absent. `linux-without-legacy-failures.json` and `conformance-linux-arm64-without-legacy.txt` retain that attempt.

The repeated audits used Debian `tzdata` and `tzdata-legacy` 2026c, mounted read-only at `/usr/share/zoneinfo`. `tzdata.txt` records package versions and SHA-256 checksums. All four Linux reports then matched the corresponding macOS reports byte-for-byte. `linux-conformance.sha256` records the Linux outputs. The SDK continues to use host timezone data; it does not bundle these packages or replace missing zones with UTC.

## Review and rebuild checks

Public tests reject enum constants claiming primitive, message, or unregistered type names, including nested constants. Native Python input conversion also rejects spoofed non-integer enum metadata rather than invoking arbitrary `__index__` callbacks. The public constructor still normalizes integer-like inputs.

Enum conversion functions use CEL's function namespace independently of local variables. This follows the pinned language definition's Evaluation Environment section and CEL-Go's qualified-function resolution in `checker.checkCall`. Public tests cover local variables sharing constructor prefixes.

An in-place native-library rebuild triggered macOS `SIGKILL (Code Signature Invalid)`, with termination namespace `CODESIGNING` and indicator `Invalid Page`. Python, Node, and wheel build paths now replace the destination inode instead of overwriting a loaded library. Repeated builds and subsequent public-API tests pass. The failure was not a CEL evaluation error or a memory-pressure result.

Native allocator failure injection, complete native coverage, Windows/browser support, native x86 performance, and remote CI verification remain open.
