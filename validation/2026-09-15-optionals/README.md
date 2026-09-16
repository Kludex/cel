# Optional-value validation

```sh
./scripts/test
./scripts/check
zig build test -Dtest-filter='optional source' --fuzz=100000 -j4
zig build example-optionals -Dexamples=true
```

The verified macOS state has 81 Zig core/application tests, 83 Python tests, 65 Node tests, and 44 audit CLI tests. Python wrapper line/branch coverage and Node wrapper line/branch/function coverage remain 100%. Native coverage is not included.

## Conformance

All three SDK reports agree in full mode: 1,901 passed, four failed, and 603 unsupported, with 1,805 successfully checked types. All 1,905 core corpus cases now execute. The four remaining failures are the documented mixed-numeric disagreements; all unsupported cases belong to extension files.

All 70 pinned optional cases and the six previously failing optional checker cases pass. Evaluation-only mode reports 1,876 passed, four failed, and 628 unsupported, including 25 check-only core cases. The pinned corpus was not edited, and no failing case was reclassified to improve these results.

## Public behavior checks

- Absent optionals remain distinct from present null values, including nested values and typed audit transport.
- Optional field/index access preserves absence. Invalid keys on present values remain errors instead of becoming absence.
- `or`/`orValue` skip unused defaults, and `optMap`/`optFlatMap` evaluate their receiver once with lexical scope.
- Optional list/map/message initializers omit absent entries and unwrap present values once.
- Protobuf selection follows presence rather than default-field values.
- Zero-value conversion, list helpers, optional equality, callback transport, static return types, constants, and independent result ownership are tested.
- Native wrappers reject spoofed metadata, cycles, and excessive values, bytes, or depth.

Public Zig allocation-failure tests exercise optional compilation and evaluation cleanup. The new optional-source/activation fuzzer completed 118,795 executions; the checked-source fuzzer completed another 102,663 executions. Zig tests pass in Debug, ReleaseSafe, and ReleaseFast, including the shared callback workload path.

The CEL-Go probe in `conformance/reference/optionals.go` informed targeted edge tests. In particular, absent receivers skip index-expression evaluation; an optional wrapper itself is not a zero value; zero timestamp is year 1 rather than the epoch; and fractional list indexes are errors. A newly added failing test caught fractional optional indexes being mistaken for absence before that behavior was corrected.

The delegated read-only review did not finish: its output exceeded the agent transport limit. It is not counted as completed review evidence.

## Packages and portability

Alpha.11's wheel was built from its sdist and passes all 83 tests on CPython 3.10, 3.12, 3.13, and 3.14. The same addon passes all 65 tests on Node 22.14.0 and 24.14.1. A separately installed npm archive exercises present-null and missing-field behavior. Neither package was published.

Core binaries cross-link for Linux x86-64/arm64, and both bindings cross-link for Linux arm64. Docker remains unavailable, so current Linux execution is not claimed. Earlier Linux results are historical evidence, not a substitute for running these artifacts.

## Performance and remaining scope

[Application results](../../benchmarks/results/2026-09-15-optionals/) cover 33 decisions and retain baseline compilation failures. The JavaScript baseline's documented optional-types option is enabled, but a required overload is still missing. Original authorization remains about eight times faster in `cel-js` than in the Node candidate.

Passing all optional cases does not prove full CEL support or performance leadership. Unknown/error values, remaining extension libraries, arbitrary runtime extension values, native coverage and foreign allocation-failure injection, current platform execution, portable distributions, and comparative performance work remain open.
