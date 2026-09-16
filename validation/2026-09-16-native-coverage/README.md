# Native line coverage of the Zig core

Wrapper coverage gates (Python, Node) have always excluded native code. This is the first measurement of the Zig core and its C++ bridges.

## Method

```sh
zig build test-install -Dtarget=aarch64-linux-gnu -Doptimize=Debug --prefix /tmp/debug
zig build conformance -Dconformance=true -Dtarget=aarch64-linux-gnu -Doptimize=Debug --prefix /tmp/debug
CEL_CONFORMANCE_DUMP=/tmp/full.json bindings/python/.venv/bin/python conformance/run.py --engine zig --mode full
CEL_CONFORMANCE_DUMP=/tmp/evaluation.json bindings/python/.venv/bin/python conformance/run.py --engine zig --mode evaluation
# inside debian:trixie-slim (kcov 43), with the source tree mounted at the path recorded in DWARF:
kcov --include-path=<source>/src /out /tmp/debug/bin/cel-test
kcov --include-path=<source>/src /out /tmp/debug/bin/cel-conformance < /tmp/full.json
kcov --include-path=<source>/src /out /tmp/debug/bin/cel-conformance < /tmp/evaluation.json
```

kcov reads DWARF line tables and sets breakpoints, so no compiler instrumentation is needed. The `Debug` build keeps every source line attributable; an optimized build would hide inlined lines. Zig 0.16 has no built-in coverage output. `CEL_CONFORMANCE_DUMP` is a new debugging hook in `conformance/run.py` that writes the exact adapter transport so the direct Zig adapter can be replayed under a profiler. The include path is the macOS realpath (`/private/tmp/...`) recorded in the binary; mounting the source at that path inside the container is required or kcov reports zero files.

Vendored RE2, protobuf, and Abseil sources under `zig-pkg/` are excluded. `src/*.cc` bridges are included because they are this project's code.

## Results

| Run | Lines covered | Total lines | Percent |
| --- | ---: | ---: | ---: |
| Before this pass, Zig tests only | 5,556 | 6,096 | 91.14% |
| Before this pass, tests plus both corpus modes (merged) | 5,773 | 6,096 | 94.70% |
| After this pass, Zig tests only | 5,703 | 6,157 | 92.63% |
| After this pass, corpus only | 3,654 | 4,412 | 82.82% |
| After this pass, merged | 5,890 | 6,157 | 95.66% |

Per-file merged results after this pass:

| File | Percent | Uncovered lines |
| --- | ---: | ---: |
| `protobuf.cc` | 81.46% | 158 |
| `program.zig` (tests live here) | 98.21% | 32 |
| `temporal.cc` | 83.22% | 24 |
| `eval.zig` | 98.96% | 10 |
| `proto.zig` | 95.39% | 10 |
| `re2.cc` | 82.86% | 6 |
| `checker.zig` | 99.37% | 5 |
| `regex.zig` | 89.19% | 4 |
| `string_format.zig` | 98.39% | 3 |
| `types.zig`, `value.zig` | 96.51%, 96.25% | 3, 3 |
| `math.zig`, `temporal.zig` | 96.08%, 95.24% | 2, 2 |
| `encoders.zig`, `format.cc`, `functions.zig`, `strings.zig`, `syntax.zig` | 88.9-99.8% | 1 each |
| `names.zig`, `network.zig`, `network_functions.zig`, `root.zig` | 100% | 0 |

`uncovered-lines.txt` lists every remaining line. `merged-coverage.json`, `merged-cobertura.xml`, `tests-coverage.json`, and `conformance-coverage.json` are the raw kcov outputs; `before-*.json` are the pre-pass measurements.

## Follow-up measurement

After the numeric-comparison change and a fifth public test that constructs `TestAllTypes` with every repeated scalar kind, wrapper boxing (`BoolValue`, `UInt64Value`, `DoubleValue`, `StringValue`), `Duration`/`Struct`/`Value` fields, a `uint32` field, direct and repeated nested-message assignment, plus the type/overflow rejections for each: Zig tests alone **93.17%** (5,768/6,191) and merged **95.77%** (5,948/6,211). `protobuf.cc` rose to 82.51% (703/852). The remaining `protobuf.cc` lines are allocation handlers, status arms for limits the fixtures cannot trip, and boundary conversions (Any payload resolution failures, duration/timestamp overflow arms) that need adversarial wire data rather than new field kinds; the bridge dispatches on C++ type, so `fixed`/`sfixed`/`sint` fields already share the covered integer arms. `merged-coverage.json` and `uncovered-lines.txt` are from this later run; `before-*.json` remain the first measurement.

## What the pass added

Four public-API Zig tests (137 total, up from 133):

- Runtime signature checks for `net.IP`, `net.CIDR`, parameterized `map`, wrapper, and parameterized `type` custom-function parameters, including the rejecting cases.
- Optional list indexing with out-of-range, unsigned, and fractional indices; network value deduplication above the hash threshold; `type()` of messages and strong enums; `sortBy` with incomparable keys.
- Constants of every value family (network, message, temporal, bytes, list, map, absent optional) through checked compilation; invalid constant metadata; checked `sortBy`, `transformMapEntry` on typed and `dyn` maps, and namespaced extrema; direct `Value.eql` for optional, message, and map values.
- Every weekday selector, timestamp milliseconds with and without a zone, `%s` formatting of leading/trailing/interior invalid bytes, `quote` under the `strings` container, `type(map)`/`type(list)`/`type(optional_type)`, `transformMapEntry` rejecting a double key, and string/bytes concatenation exceeding the collection limit.

While writing these, a dead branch was found and removed: `eval.zig` still contained the pre-fast-path global `contains`/`startsWith`/`endsWith` handling that the earlier receiver fast path had made unreachable. The CEL-Go probe (`/tmp/cel-type-string-probe.go`) confirmed that `string(type_value)` is rejected in both checked and unchecked modes, so no conversion was added for it.

## What remains and why

- `protobuf.cc` (158 lines): fourteen `catch (const std::bad_alloc &)` handlers and their status returns, plus status arms for limits and malformed Any/Struct payloads that need adversarial wire data. The allocation handlers need a failing C++ allocator; Zig's `checkAllAllocationFailures` does not reach `operator new`. Adversarial wire fixtures for those arms are the next coverage step.
- `temporal.cc` (24 lines): `bad_alloc` handlers and a duration-normalization fallback for `INT64_MIN` nanoseconds spelled without a leading zero component. The Zig tests exercise the spelled form; the fallback branch depends on Abseil's parser rejecting the raw form first.
- `re2.cc`, `regex.zig`, `proto.zig` remaining lines: FFI status codes for out-of-memory and `unreachable` defaults for statuses the bridge cannot return.
- `eval.zig` line 350 and similar `else => unreachable` arms after exhaustive numeric checks; `types.zig`/`value.zig` remaining lines are the same pattern.

Run-to-run noise: kcov on aarch64 attributed one or two lines differently between otherwise identical runs (`encoders.zig` 100% then 98.28%; `eval.zig` 9 then 10 uncovered). Percentages are precise to roughly ±0.05 points, not exact.

## Caveats

- Line coverage, not branch coverage. A covered line may still have an untested branch.
- One architecture (aarch64 Linux, Debug). Optimized builds and other targets were not measured.
- Coverage is not correctness. The four unresolved corpus disagreements and every documented semantic gap remain regardless of this number.
