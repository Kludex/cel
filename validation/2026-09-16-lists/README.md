# Alpha.15 list-extension validation

## Public tests and conformance

```sh
./scripts/test
./scripts/check
zig build test -Dbenchmarks=true -Doptimize=ReleaseFast -j4
bindings/python/.venv/bin/python -m pytest \
  -c bindings/python/pyproject.toml conformance/test_lists.py
```

The shared engine now implements `slice`, `flatten`, `distinct`, `lists.range`, `reverse`, `sort`, and `sortBy`. All 52 pinned list-extension cases pass through Zig, Python, and Node in both full and evaluation modes. No other unsupported file was removed from the manifest.

| Gate | Result |
| --- | --- |
| macOS Zig Debug, ReleaseSafe, ReleaseFast | 95 core tests plus one complete-workload test pass |
| Python | 95 tests; wrapper/test line and branch coverage 100% |
| Node | 78 tests; wrapper line/branch/function coverage 100% |
| Audit CLI | 50 tests pass |
| Full corpus, every SDK | 2,152 passed, four failed, 352 unsupported |
| Evaluation-only corpus, every SDK | 2,127 passed, four failed, 377 unsupported |
| Checked result types | 2,056 recorded, not inferred from evaluation success |
| Linux arm64 core, glibc 2.28 | All 95 core tests pass |
| Emulated Linux x86-64 core | All 95 core tests pass |
| Linux arm64 audits, glibc 2.28 | All six reports match macOS field-for-field |
| Formatting, lint, strict typing | Pass |

Wrapper coverage does not measure Zig or C++ coverage. Fuzzer edge counts do not establish complete native coverage.

## Regressions established before correction

`red-python.txt`, `red-node.txt`, and `red-audit.txt` record missing operations before implementation. Additional public failures caught invalid `sortBy` receiver syntax, missing container lookup for `range`, nested protobuf wrappers comparing unequal to their scalar values, checked sorting rejecting scalar wrappers, and protobuf equality bypassing CEL byte-work accounting.

A complete policy over 3,000 IDs exhausted the default work budget with quadratic deduplication. `red-large-policy.txt` records that failure. Larger scalar lists now use hash buckets; collisions still call CEL equality and preserve the first value. Tests force the signed `-1` / unsigned maximum hash collision and exercise exact mixed-numeric aliases, signed zero, temporal values, enums, strings, bytes, types, nulls, and compound values.

Small lists use linear scanning. Compound values share a fallback bucket because serialized message bytes are not semantic equality keys. Their comparisons can remain quadratic but consume evaluation work. Protobuf equality now charges cached encoded-size and reflected-field estimates, including nested messages and unknown bytes. This is a work proxy, not exact native instruction or allocation accounting; first-time cost construction and protobuf-internal resource behavior still require broader verification.

## Independent reference evidence

```sh
(cd /tmp/cel-go-reference && \
  go run /Users/marcelotryle/dev/pydantic/cel/conformance/reference/lists.go)
```

The reference checkout is pinned at `16c2ebb13679d18704cee890f3fdc861fe2ca7b1`. The [portable reproduction instructions](../../conformance/reference/README.md#list-extension) explain how to create it elsewhere. `lists.txt` records receiver/key counts, error order, namespaces, scopes, invalid macro forms, numeric aliases, and inferred types.

Differences remain explicit:

- This SDK preserves equal-key order. CEL-Go's sort can reorder equal-key groups.
- This SDK rejects NaN keys in multi-element sorts. CEL-Go currently discards NaN comparison errors; a singleton NaN succeeds in both implementations.
- This SDK preserves known list types with dynamic elements. CEL-Go can infer `dyn`, or `list(int)` for an empty literal, through overload ordering.

Pinned corpus agreement does not settle these broader compatibility questions. The four existing mixed-numeric corpus disagreements also remain visible.

## Resource and fuzz checks

Public Zig tests inject every Zig allocation failure in a checked flatten/deduplicate/sort/slice policy, including hash-table allocation. Other cases exercise collection limits, cyclic nested lists, string-comparison work exhaustion, and unsuppressible protobuf comparison cost failures. Callback tests verify single receiver/key evaluation, lexical shadowing, error identity, and stopping at the first failed key.

The numeric hashing fuzzer compares `Program.evaluate()` results against public `Value.eql` behavior across mixed scalar types. The sorting fuzzer checks preservation, uniqueness, order, and input immutability. `fuzz-*.txt` retains execution counts and earlier attempts. Native protobuf allocation failure injection and exact memory ceilings remain open.

## Packages and platforms

Python `0.1.0a15` wheels were built from the source distribution on macOS and Linux. All 95 tests pass on CPython 3.10/3.12/3.13/3.14 on macOS and CPython 3.10.20 with glibc 2.28 on Linux. Strict `abi3audit` passes for both wheels; `auditwheel` accepts the Linux manylinux 2.28 policy.

Node `0.1.0-alpha.15` archives pass all 78 installed-package tests on macOS Node 24, Linux Node 22/glibc 2.31, and Linux Node 24/glibc 2.28. Installed-wrapper coverage explicitly includes `**/cel/dist/index.js`. Archives remain unpublished and platform-specific.

Linux uses the pinned images, compiler, and complete timezone data documented in [the earlier Linux validation](../2026-09-15-linux/). Builds and tests disable networking and use read-only project mounts. Native arm64 execution and emulated x86 execution are recorded separately; neither proves native x86 performance or every Linux kernel's behavior.

## Application performance

The ordinary benchmark suite contains 45 complete decisions across nine workloads. A separate 500-job dispatch fixture executes the same policy, including input conversion, flattening, ID deduplication, priority sorting, selection, readiness/cost checks, and node availability.

[Raw measurements and reproduction](../../benchmarks/results/2026-09-16-lists/) show about 53% lower Node elapsed time for that larger policy in three stable paired runs and a clean-build comparison. The ordinary mix is unchanged by the hashing optimization. Both pinned JavaScript competitors fail the batch policy at missing `flatten` support; the original authorization workload still favors `cel-js` by about 6.8 times. Performance leadership, compound-value scaling, native memory accounting, remaining language libraries, other platforms, and remote CI remain unfinished.
