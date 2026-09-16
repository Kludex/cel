# Alpha.18 string-extension validation

## Public API and corpus gates

```sh
./scripts/test
./scripts/check
zig build test -Dbenchmarks=true -Doptimize=ReleaseFast -j4
bindings/python/.venv/bin/python -m pytest \
  -c bindings/python/pyproject.toml conformance/test_string_extensions.py
```

The shared engine implements code-point indexing/search/substrings, ASCII casing, replacement, splitting, Unicode trimming, joining, reversal, CEL quoting, and value formatting. All 216 pinned string-extension cases pass through all three public SDKs in full and evaluation modes. Only `string_ext` was removed from the unsupported manifest.

| Gate | Result |
| --- | --- |
| Zig Debug, ReleaseSafe, ReleaseFast | 110 core tests plus one complete-workload test pass |
| Python | 118 tests; wrapper/test line and branch coverage 100% |
| Node | 89 tests; wrapper line/branch/function coverage 100% |
| Audit and benchmark CLI | 62 tests pass |
| Full corpus | 2,413 passed, four failed, 91 unsupported |
| Evaluation-only corpus | 2,388 passed, four failed, 116 unsupported |
| Successfully checked result types | 2,273 recorded |
| Linux arm64/glibc 2.28 | Core, installed bindings, and all six audits pass corresponding gates |
| Emulated Linux x86-64 | All 110 core tests pass |
| Formatting, lint, strict typing | Pass |

`parity.json` compares every report field across SDKs and macOS/Linux. These percentages exclude native Zig/C++ coverage. Full corpus agreement is not a claim that unknown/error values, every library, or every checker behavior is implemented.

## Failures caught beyond the corpus

Public red tests establish missing functionality before implementation. Additional tests caught high-precision output becoming the literal `"(float)"`, incorrect rounding beyond shortest-decimal precision, invalid byte runs reaching text output, early loss of duration precision, extra formatting arguments being rejected, and borrowed string results bypassing the output-size limit.

The initial formatter allocated the entire maximum output buffer for each call and used a rounding workaround. The final implementation grows bounded storage as needed and uses C++17 `std::to_chars` for fixed/scientific conversion. This is locale-independent and supplies binary floating-point rounding without a custom rounding algorithm. Shortest decimal output still uses Zig's standard formatter. Precision and output limits are checked before amplification.

A read-only review identified the borrowed-result limit issue; regression tests now cover substring, trim, zero-count replacement, and split fragments. The review also suggested preserving every duration nanosecond in `%s`, but the pinned document and CEL-Go explicitly format floating-point seconds. That suggestion was not applied. A separate test did expose premature whole-nanosecond conversion; splitting seconds and remainder now agrees with the reference's floating-point result. Exact duration storage and arithmetic remain unchanged.

## Independent semantics

[The reference probe](../../conformance/reference/strings.go) runs against CEL-Go `16c2ebb13679d18704cee890f3fdc861fe2ca7b1`. [Its output](../../conformance/reference/strings.txt) records Unicode operations, boundaries, formatting, argument handling, and duration results. Public SDK tests also compare 200 generated binary doubles against Python formatting and 200 Unicode searches against Python code-point indexing.

Known differences remain visible:

- The pinned corpus requires out-of-range search errors. Newer CEL-Go returns `-1` or clamps some offsets, including different end-offset behavior.
- The pinned string-format document requires adjacent invalid UTF-8 bytes to collapse into one replacement character per run. CEL-Go currently emits multiple replacement characters.
- The `%d` type table omits doubles, while the document's example and CEL-Go accept them. This SDK accepts the example.
- Runtime extra arguments are ignored after the argument list is evaluated. The checker validates argument container types, not every literal format clause as CEL-Go's optional validation can do.

Locale selection is not exposed. These facts are not hidden by the 216-case result and remain part of broader compatibility work.

## Resource and ownership checks

Searches cap the candidate window according to remaining work before scanning. Generated string bytes and split collection sizes are bounded, including borrowed results. UTF-8 boundaries are validated, empty separators advance by code point, and invalid-byte formatting produces valid UTF-8. Formatting validates precision and uses bounded temporary numeric storage.

Allocation-failure injection covers a checked quote/split/join/recursive-map/high-precision policy. Unicode transformation fuzzing completed 100,030 executions, byte-format fuzzing 200,000, checked-source fuzzing 106,121, and source fuzzing 102,551. Fuzzer edge counts and wrapper coverage do not prove native coverage or exact foreign memory accounting.

## Distribution checks

Python `0.1.0a18` wheels were built from source distributions on macOS and Linux. All 118 tests pass on macOS CPython 3.10/3.12/3.13/3.14 and Linux CPython 3.10.20 with glibc 2.28. Strict `abi3audit` passes; the Linux wheel satisfies the manylinux 2.28 policy.

Node `0.1.0-alpha.18` installed archives pass all 89 tests and explicit wrapper coverage on macOS Node 24, Linux Node 22/glibc 2.31, and Linux Node 24/glibc 2.28. The added C++ formatter uses the existing statically linked standard library, not a new external dependency. Packages remain unpublished and platform-specific. Linux uses the pinned images and offline setup documented in [the earlier platform validation](../2026-09-15-linux/).

## Complete-policy measurements

[Raw samples](../../benchmarks/results/2026-09-16-strings/) cover 51 complete decisions across ten workloads. The text-ingestion workload normalizes names and labels and validates a formatted canonical key. The changed mix cannot establish a speedup over earlier aggregate reports. Both pinned JavaScript competitors fail this policy on unsupported operations; their logs remain recorded. `cel-js` is still about 6.9 times faster on the original authorization workload.

Network/encoder/protobuf-helper extensions, unknown/error values, broad independent compatibility, native coverage/resources, platform-aware distribution, Windows/browser support, remote CI, and performance leadership remain open.
