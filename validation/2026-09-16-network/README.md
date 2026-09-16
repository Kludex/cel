# Alpha.20 network-extension validation

## Public API and corpus checks

```sh
./scripts/test
./scripts/check
zig build test -Dbenchmarks=true -Doptimize=ReleaseFast -j4
bindings/python/.venv/bin/python -m pytest \
  -c bindings/python/pyproject.toml conformance/test_network.py
```

`ip`, `cidr`, `isIP`, `isCIDR`, `ip.isCanonical`, IP classification methods, CIDR accessors, masking, and containment run through the shared Zig engine. Python `IPAddress`/`CIDR` and TypeScript `IPAddress`/`CIDR` normalize text through the native parser, so no host-language parser can disagree with CEL evaluation. Checked programs use parameter-free abstract types `net.IP` and `net.CIDR`.

| Gate | Result |
| --- | --- |
| Zig Debug, ReleaseSafe, ReleaseFast | 131 core tests plus one complete-workload test pass |
| Python | 132 tests; wrapper/test line and branch coverage 100% |
| Node | 94 tests; wrapper line/branch/function coverage 100% |
| Audit and benchmark CLI | 71 tests pass |
| Full corpus | 2,501 passed, seven failed, zero unsupported |
| Evaluation-only corpus | 2,477 passed, six failed, 25 check-only cases omitted |
| Successfully checked result types | 2,363 recorded |
| Formatting, lint, strict typing | Pass after two recorded fixes |

`sdk-tests-final.txt` is a partial log from a run interrupted by a concurrent fuzz command; `sdk-tests-complete.txt` is the sequential complete run. `check-unformatted-seeds.txt` and `check-list-invariance.txt` record formatting and typing failures fixed before the final check.

## Corpus disagreements

All 69 pinned network cases execute in every SDK. Full mode has three visible failures and evaluation mode has two:

| Case | Corpus expectation | SDK and CEL-Go behavior |
| --- | --- | --- |
| `ipv4/ipv4_equals_ipv6` | `::ffff:c0a8:1` equals `192.168.0.1` | Every IPv4-mapped IPv6 form is rejected |
| `ipv4/ipv4_not_equals_ipv6` | Mapped hexadecimal compares as IPv4 | Rejected consistently with the dotted mapped case |
| `ip_type/is_ip_cidr_compile_error` | `evalError` | Overload rejection during checking |

[The CEL-Go probe](../../conformance/reference/network.txt) reproduces these outcomes at the pinned commit. `conformance/test_network.py` pins the exact failure set so a silent change in either direction fails the CLI tests. Corpus files were not edited or excluded.

## TDD and independent evidence

`red-python.txt`, `red-node.txt`, and `red-zones.txt` record the missing wrappers and parser gaps. `core-network-first.txt` records a public Zig test exposing nested invalid metadata escaping materialization. `red-network-deduplication.txt` records 3,000 distinct addresses exhausting the default work budget before scalar network hashing.

Python's standard `ipaddress` module independently checks canonical spelling, masking, and containment across 300 generated IPv4/IPv6 cases plus fixed boundary prefixes. Zig fuzzing compared parsing consistency (104,164 runs) and byte-mask containment against an independent oracle (100,053 runs). Checked-source fuzzing completed 104,761 runs and source fuzzing 102,215 runs with network seeds.

A focused read-only review found no concrete issue. An earlier broad review failed with an output-limit error and is not counted.

## Distribution checks

Python `0.1.0a20` was built from the source distribution on macOS. All 132 tests pass with 100% wrapper coverage on CPython 3.10, 3.12, 3.13, and 3.14 using the installed wheel; `abi3audit --strict` passes. The first attempt lacked `pytest-cov` in the isolated interpreters and is retained as `mac-python-*-missing-coverage.txt`.

The packed Node archive installs with scripts disabled and passes all 94 tests with explicit 100% wrapper coverage on Node 24.

### Linux

A snapshot of the source tree (`linux-source.txt` records its hashes) was built for Linux. The snapshot predates three later edits: line wrapping in `src/network_functions.zig`, moving the appended tests in `src/program.zig` through `zig fmt`, and a `list[Value]` annotation in `bindings/python/tests/test_network.py`. None changes behavior; the macOS gates above ran on the final sources.

| Check | Result |
| --- | --- |
| Core tests, arm64, glibc 2.28 (`linux-core-arm64.txt`) | 131 pass |
| Core tests, emulated x86-64 (`linux-x86-core.txt`) | 131 pass |
| Wheel built from the source distribution inside Linux (`linux-python-build.txt`) | `cp310-abi3-linux_aarch64` |
| `auditwheel repair --only-plat` (`linux-wheel-audits.txt`) | Accepted as `manylinux_2_28_aarch64` |
| `abi3audit --strict` (`linux-abi3audit.txt`) | 0 mismatches, 0 violations |
| Installed wheel, CPython 3.10.20, glibc 2.28 (`linux-python310.txt`) | 132 tests pass, 100% wrapper coverage |
| Node addon built inside Node 24/glibc 2.36 (`linux-node-build-retry.txt`) | ELF aarch64 |
| Installed npm archive, Node 24, glibc 2.28 (`linux-node-24-glibc228.txt`) | 94 tests pass, 100% wrapper coverage |
| Installed npm archive, Node 22, glibc 2.31 (`linux-node-22-glibc231.txt`) | 94 tests pass, 100% wrapper coverage |
| Six audits, glibc 2.28 (`linux-audits-glibc228.txt`, `linux-parity.json`) | Every field matches macOS |

The delegated Linux run exceeded its time limit after the Python steps (`linux-node-build.txt` shows its first Node build succeeded but its output was never staged). The Node package, conformance binary, audits, and x86-64 run above were completed afterward from the same snapshot. `linux-packages.sha256` lists the resulting artifacts. Runtime containers used no network, a read-only root, a read-only project mount, `--tmpfs /tmp:exec`, and a complete timezone database. The first Node runtime attempts failed on host-side glob expansion inside the container command and are recorded in the final logs' history, not as test failures.

## Complete-policy measurements

[Raw samples](../../benchmarks/results/2026-09-16-network/) add seven gateway decisions, making 64 across twelve workloads. Cold/warm medians are 7.359/1.471 us for Python, 10.149/2.594 us for Node, and 6.460/0.815 us for native Zig, all under 5% relative IQR. The first Zig run had 5.9% cold IQR and is retained separately.

A complete 600-prefix gateway policy improved about 83% in three stable paired runs after scalar IP/CIDR hashing. The ordinary 64-decision mix changed 0.0-2.5%, below the meaningful-effect threshold. Both pinned JavaScript competitors fail the network policy; `cel-js` remains about seven times faster on original authorization (0.309 us versus 2.174 us warm).
