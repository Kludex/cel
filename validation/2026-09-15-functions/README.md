# Custom-function validation

```sh
./scripts/test
./scripts/check
zig build test -Dbenchmarks=true -Dbenchmark-functions=true -Doptimize=ReleaseSafe
zig build test -Dtest-filter='custom function source' --fuzz=100000 -j4
```

The pass adds typed function declarations and trusted synchronous callbacks through Zig, Python, and TypeScript. Namespaces, receiver-style calls, scalar overloads, fresh generic parameters, abstract type descriptions, missing implementations, and inferred checked return contracts are tested through public APIs.

## Results

| Gate | Evidence |
| --- | --- |
| Zig core and shared application test | 71 tests pass in Debug, ReleaseSafe, and ReleaseFast |
| Python wrappers | 74 tests pass; line/branch coverage remains 100% |
| Node wrappers | 56 tests pass; line/branch/function coverage remains 100% |
| Audit CLI | 38 tests pass, including the five pinned function/generic cases through all three SDKs |
| Python sdist-built wheel | All 74 tests pass on CPython 3.10, 3.12, 3.13, and 3.14 |
| Node runtime/package | All 56 tests pass on Node 22/24; separately installed alpha.10 archive executes a callback policy |
| Function/source fuzzing | 106,127 custom-function and 105,511 checked-source executions |
| Audit transport fuzzing | 191,100 ReleaseSafe executions |

A Debug audit-fuzzer attempt exceeded the command timeout without producing a completion report. It is not counted as a successful run; the optimized safe run is recorded separately. Linux core and binding binaries cross-link, but Docker remains unavailable, so execution of the updated artifacts is not claimed. Packages remain unpublished.

## Review and boundary findings

- Callback collection results now obey `max_collection_size`, including nested materialization. A public test reproduced the earlier bypass.
- Alpha-equivalent and erased overlapping signatures are rejected during environment creation. Validation includes a work budget rather than unbounded pairwise checking.
- Checked generic callback returns are validated against their final inferred type. A callback claiming `T -> T` cannot return a string for a statically inferred integer call.
- Node creates typed compile/evaluation exceptions at the native boundary. Host exceptions with `CEL_COMPILE_` or `CEL_EVALUATE_`-looking codes retain their original identity instead of being mistaken for engine errors.
- Python callback frames are thread-local. A deterministic two-thread test reproduced corruption when a callback released the GIL; per-environment active pointers were replaced with scoped thread-local frames.
- Callback ownership remains visible to the host garbage collector. Tests cover callback/program cycles, reentrancy, retained message arguments, result ownership, and environments outliving caller references.

A review proposed rejecting mixed runtime values for shared generic parameters even when the source uses `dyn`. That proposal was not adopted: the pinned specification describes erasure, and the independent CEL-Go probe in `conformance/reference/function-generics.go` accepts `same(dyn(1), 'x')` while rejecting `same(1, 'x')` during checking. The matching public Zig regression test preserves this distinction.

## Conformance scope

All three full-mode reports agree: 1,825 passed, 10 failed, and 673 unsupported, with 1,729 successfully checked types. The five function-declaration cases moved from unsupported to passing.

Removing the generic-type admission filter also exposes six optional-library cases in `type_deduction`. They fail because optional operations are not implemented. Those failures remain visible alongside the four mixed-numeric disagreements; they were not reclassified to obtain a green report. Evaluation-only counts remain 1,806 passed, four failed, and 698 unsupported because these new declaration cases are check-only.

Abstract type descriptions support checking but do not create arbitrary runtime extension values. Unchecked generic contracts and explicitly dynamic types remain trusted implementation contracts. Engine budgets cannot preempt blocking callbacks or bound their external effects.

## Performance and remaining scope

[Complete policy benchmarks](../../benchmarks/results/2026-09-15-functions/) include callback-backed authorization through every SDK. They check all 27 decisions and include callback argument/result conversion. No callback microbenchmark or performance-leadership claim is used.

Optional values, unknown/error values, remaining extensions, native coverage, foreign allocator failure injection, broader independent differential tests, current Linux execution, portable distributions, and comparative performance leadership remain open.
