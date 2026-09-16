# Math-extension validation

```sh
./scripts/test
./scripts/check
zig build test -Dtest-filter='math shifts and extrema' --fuzz=100000 -j4
```

The math extension now covers all 199 pinned cases through Python, Node, and direct Zig execution. Full audits agree at 2,100 passed, four failed, and 404 unsupported. Evaluation-only audits agree at 2,075 passed, four failed, and 429 unsupported. The remaining four failures are the existing mixed-numeric disagreements; the admission policy was changed only to enable the implemented math file.

## Public behavior

- Extrema preserve the winning numeric type and the first value on ties.
- Dynamic arguments can change the winner's type, so their result is inferred as dynamic.
- Rounding, sign, absolute value, and finite/NaN/infinity predicates retain their declared numeric behavior.
- Minimum signed-integer absolute value reports overflow.
- Bit operations preserve signed/unsigned types. Signed right shift is logical; negative offsets fail and offsets of 64 or more produce zero.
- Invalid extrema literals fail while parsing; dynamic invalid values fail during evaluation. Custom ordinary function families retain namespace precedence.
- Work and collection limits apply before scanning input lists. Allocation failures clean up variadic compilation and evaluation storage.

The direct dynamic-result test initially failed and then passed after correcting inference. The public CEL-Go probe in `conformance/reference/math.go` independently confirms that result type and the selected edge behaviors.

## Gates and artifacts

88 Zig core/application tests, 86 Python tests, 68 Node tests, and 47 audit CLI tests pass. Python wrapper line/branch coverage and Node wrapper line/branch/function coverage remain 100%. Native coverage is not included.

The math runtime fuzzer completed 194,141 executions. Source and checked-source fuzzers, with math seeds added, completed 101,791 and 105,325 executions. Zig tests pass in Debug, ReleaseSafe, and ReleaseFast. A focused read-only review found no additional concrete issues; it did not run tests itself.

Alpha.12's Python wheel was built from its sdist and passes all 86 tests on CPython 3.10, 3.12, 3.13, and 3.14. The addon passes all 68 tests on Node 22.14.0 and 24.14.1. A separately installed npm archive checks exact numeric selection and logical shifts. Neither package was published.

Linux core binaries and bindings cross-link. Docker remains unavailable, so execution of those artifacts is not claimed. Remote CI has been updated but has not run.

## Performance and remaining scope

[Application measurements](../../benchmarks/results/2026-09-15-math/) use 39 complete decisions, including quota and permission policies. New Zig iteration options allow bounded-duration sampling without changing the workload or number of samples. Two incomplete long command attempts remain documented, and all final samples exceed 100 ms.

The original authorization policy is still about eight times faster in `cel-js`. The pinned competitors lack required math overloads for the new quota policy, and the protobuf-`Struct` path loses integer mask types. These failures remain visible. No performance-leadership claim is made.

Remaining extension libraries, unknown/error values, arbitrary runtime extension values, native coverage and foreign allocation-failure injection, current platform execution, portable distribution artifacts, and comparative performance work remain open.
