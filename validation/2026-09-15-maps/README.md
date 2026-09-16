# Alpha.9 typed-map validation

```sh
./scripts/test
./scripts/check
zig build test -Dtest-filter='typed map key validation' --fuzz=100000 -j4
npm exec --yes --package=node@22.14.0 -- \
  node --expose-gc --test bindings/typescript/dist/test/*.test.js
```

Run from the repository root. The verified macOS state has 59 Zig tests, 51 Python tests, 44 Node tests, and eight conformance CLI self-tests. Python wrapper line/branch coverage and Node wrapper line/branch/function coverage remain 100%. Native coverage is not included.

## Behavior and ownership

Python `CELMap` preserves typed entry pairs. Results remain ordinary dictionaries unless boolean/integer keys would collapse. Native validation rejects duplicate CEL keys even when Python considers their wrapper keys distinct. Wrapper equality is entry-ordered and preserves key types; CEL expression equality remains order-independent.

Node accepts native maps and map subclasses, including maps with altered prototypes. It captures built-in map operations and snapshots entries before value conversion. Numeric aliases such as `1`, `1n`, and `UInt(1n)` are rejected as duplicate CEL keys. Boolean `true` and integer `1` remain distinct. Public TypeScript tests pass outputs back as inputs without casts.

Map keys and values both count toward the 100,000-value budget in both SDKs. Tests verify that 49,999 scalar entries fit and 50,000 exceed the value budget. Separate byte and nesting limits still apply. Native hashing is skipped only where the host representation and lossless conversion already guarantee uniqueness.

Public tests cover malformed tuple pairs, invalid keys, duplicate keys, unsigned bounds, nested results, checked declarations, constants, mutations during conversion, reentrant calls, cycles, shared noncyclic values, garbage collection, and independent ownership.

## Review findings

A review found that a `Proxy(Map)` could spoof its prototype and be mistaken for an empty record. Proxy values, map keys, and binding records are now rejected. Proxies were not a documented supported representation; this stricter boundary is documented explicitly.

The review also found inherited `get`/`set` fields could corrupt JavaScript property descriptors used for snapshots. Snapshots now use a null-prototype array with ordinary own entries. Tests poison object and array prototypes to verify the snapshot remains correct without invoking inherited setters.

## Native validation

Map constants use shared hash-based key validation instead of quadratic duplicate scans. A public test with 2,049 entries failed under the earlier work budget and now succeeds. Signed/unsigned equality and boolean/integer distinctions are checked through the public API, including allocation-failure injection.

The new map-key fuzzer completed 109,982 executions and compares accepted maps against public CEL equality. Zig tests pass in Debug, ReleaseSafe, and ReleaseFast. Linux x86-64/arm64 core binaries and Linux arm64 bindings cross-link. Docker remains unavailable, so this iteration does not claim execution of those updated Linux artifacts.

## Packages and conformance

The alpha.9 Python wheel was built from its sdist and passes all 51 tests on CPython 3.10, 3.12, 3.13, and 3.14. The addon passes all 44 tests on Node 22.14.0 and 24.14.1. The npm archive was installed separately and exercised with mixed-key round trips and proxy rejection. Neither package was published.

Full audits remain at 1,820 passed, four failed, and 684 unsupported. Evaluation-only audits remain at 1,806 passed, four failed, and 698 unsupported. New CLI tests explicitly cover mixed-key transport; the pinned corpus and admission policy were not changed to improve counts.

[Application measurements](../../benchmarks/results/2026-09-15-maps/) retain typed-map construction costs, an observed ordinary-object slowdown, intermediate implementations, and contrary competitor evidence. Full language support, direct Zig conformance, native coverage, foreign allocation-failure injection, Linux runtime revalidation, distribution portability, and performance leadership remain open.
