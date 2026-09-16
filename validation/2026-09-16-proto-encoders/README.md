# Alpha.19 protobuf-helper and encoder validation

## Public API and corpus checks

```sh
./scripts/test
./scripts/check
zig build test -Dbenchmarks=true -Doptimize=ReleaseFast -j4
bindings/python/.venv/bin/python -m pytest \
  -c bindings/python/pyproject.toml conformance/test_proto_encoders.py
```

`proto.hasExt` and `proto.getExt` capture qualified extension syntax and lower to the existing presence/selection operations. Descriptor lookup validates the containing message and preserves scalar/default/repeated/enum behavior. Base64 operations use Zig's standard codecs with bounded output/work and compatibility handling for CR/LF and unused tail bits.

All 18 pinned protobuf-helper and four encoder cases pass through Zig, Python, and Node in both modes. Only those two files were removed from the unsupported manifest. URL-safe encode/decode operations also pass public tests, but unrelated encoder APIs such as JSON conversion are not implied.

| Gate | Result |
| --- | --- |
| Zig Debug, ReleaseSafe, ReleaseFast | 116 core tests plus one complete-workload test pass |
| Python | 125 tests; wrapper/test line and branch coverage 100% |
| Node | 91 tests; wrapper line/branch/function coverage 100% |
| Audit and benchmark CLI | 65 tests pass |
| Full corpus | 2,435 passed, four failed, 69 unsupported |
| Evaluation-only corpus | 2,410 passed, four failed, 94 unsupported |
| Successfully checked result types | 2,295 recorded |
| Linux arm64/glibc 2.28 | Core, installed bindings, and all six audits pass corresponding gates |
| Emulated Linux x86-64 | All 116 core tests pass |
| Formatting, lint, strict typing | Pass |

The remaining unsupported corpus file is the network extension. Unknown/error values, untested language/library behavior, native coverage, and broader compatibility remain open. Shared-core report parity is not independent semantic proof.

## TDD and independent evidence

`red-python.txt`, `red-node.txt`, and `red-audit.txt` record missing functionality. `red-field-budget.txt` exposed uncharged qualified protobuf field-name work; the shared selection path now charges it before lookup.

The [CEL-Go probe](../../conformance/reference/proto-encoders.go) uses the pinned reference commit and public generated proto APIs. [Its output](../../conformance/reference/proto-encoders.txt) confirms presence/defaults, explicit zero presence, repeated emptiness, containing-message errors, map receivers, quoted components, literal name capture, macro precedence, CR/LF handling, alphabet separation, and permissive tail-bit decoding. Python's independent Base64 encoder is checked across 128 generated binary payload lengths.

Protobuf names are syntax, not activation lookups. Leading-dot or relative extension paths remain literal field names rather than being container-expanded. Map receivers are accepted because the reference macro lowers to ordinary selection/presence. Base64 decoders preserve CEL-Go's acceptance of nonzero unused tail bits; encoders emit canonical padding and bits. Spaces, tabs, interior/excess padding, and mismatched alphabets fail.

## Resource and ownership evidence

Public tests exercise malformed inputs, output/work caps, descriptor ownership, strong enums, explicit-default presence, and every Zig allocation failure through a combined protobuf/Base64 policy. Binary round-trip fuzzing completed 100,046 executions, malformed-text fuzzing 122,242, checked-source fuzzing 103,498, and source fuzzing 101,653.

A focused read-only review found no concrete issue. An earlier review exceeded the agent output limit and is not counted as completed evidence. Wrapper percentages and fuzzer edge counts do not establish native coverage, foreign allocator injection, or exact native resource ceilings.

## Distribution checks

Python `0.1.0a19` wheels were built from source distributions on macOS and Linux. All 125 tests pass on macOS CPython 3.10/3.12/3.13/3.14 and Linux CPython 3.10.20 with glibc 2.28. Strict stable-ABI audits pass; the Linux wheel meets the manylinux 2.28 policy.

Node `0.1.0-alpha.19` installed archives pass all 91 tests with explicit wrapper coverage on macOS Node 24, Linux Node 22/glibc 2.31, and Linux Node 24/glibc 2.28. Packages remain unpublished and platform-specific. Linux uses the pinned images, read-only mounts, disabled runtime networking, and complete timezone data recorded in [the earlier Linux validation](../2026-09-15-linux/).

## Complete-policy measurements

[Raw samples](../../benchmarks/results/2026-09-16-proto-encoders/) cover 57 complete decisions across eleven workloads. The new attachment policy is transport/content validation, not cryptographic authentication. The changed mixture cannot establish a speedup over earlier aggregates. Both pinned JavaScript competitors fail the new policy on missing operations; `cel-js` still evaluates authorization about 6.9 times faster.

Network values, unknown/error propagation, broader libraries, independent compatibility, native coverage/resource accounting, platform-aware distribution, Windows/browser support, remote CI, and performance leadership remain unfinished.
