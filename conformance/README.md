# CEL conformance corpus

```sh
./scripts/build-python
npm ci --prefix bindings/typescript
npm run build --prefix bindings/typescript
zig build conformance -Dconformance=true -Doptimize=ReleaseSafe
bindings/python/.venv/bin/python conformance/run.py --engine python --mode evaluation \
  --report /tmp/python-evaluation.json
bindings/python/.venv/bin/python conformance/run.py --engine node --mode evaluation \
  --report /tmp/node-evaluation.json
bindings/python/.venv/bin/python conformance/run.py --engine zig --mode evaluation \
  --report /tmp/zig-evaluation.json
```

Run these commands from the repository root. All three engines evaluate the same imported cases through public SDK APIs. Node and Zig audit adapters use typed JSON as subprocess transport; the product SDK does not serialize values through JSON at its native boundary.

## Corpus and provenance

This directory contains all 2,508 tests from 31 upstream `tests/simple/testdata/*.textproto` files, including unsupported tests. The source is `google/cel-spec` commit [`ba58ae5007845f3a1279b488cdeb79645ce958bb`](https://github.com/google/cel-spec/commit/ba58ae5007845f3a1279b488cdeb79645ce958bb), tagged `v0.25.3`.

Imported files retain the upstream Apache 2.0 license in `upstream/LICENSE`. `testdata/manifest.json` records source and generated-file checksums. The runner rejects modified files, missing cases, and mismatched adapter response IDs.

## Evaluation versus full conformance

```sh
bindings/python/.venv/bin/python conformance/run.py --engine python --mode full \
  --report /tmp/python-full.json
```

`full` is the default. It requires the phases requested by each upstream case. Type checking is requested by default unless a case sets `disableCheck`. The runner now creates an environment from supported declarations and the namespace, runs the actual checker, and compares any requested deduced type. Check-only cases do not execute their expressions. Full mode exits with status 1 if any case fails or remains unsupported.

`evaluation` deliberately omits type checking and deduced-type matching. It runs declarations-based cases where the remaining inputs and configuration can be represented. It still skips check-only cases and unsupported runtime features. Its report records `omittedChecks`, and `fullConformance` is always false. It exits with status 1 when any executed case fails.

This distinction prevents a successful evaluation from being presented as proof that a missing checker succeeded.

## Current results

| Mode | SDK | Passed | Failed | Unsupported |
| --- | --- | ---: | ---: | ---: |
| Evaluation | Python | 2,481 | 2 | 25 |
| Evaluation | Node | 2,481 | 2 | 25 |
| Evaluation | Zig | 2,481 | 2 | 25 |
| Full | Python | 2,505 | 3 | 0 |
| Full | Node | 2,505 | 3 | 0 |
| Full | Zig | 2,505 | 3 | 0 |

All 2,508 pinned cases now execute in full mode, with 2,363 successful checked result types recorded. The 69 network cases produce 66 passes and three disagreements: two hexadecimal IPv4-mapped forms are rejected consistently with CEL-Go, and `isIP(cidr(...))` fails checking rather than evaluation. Evaluation mode passes 67 network cases and omits 25 core check-only cases.

The four former mixed-numeric failures now pass: cross-type comparison follows the algorithm shared by CEL-Go and CEL-C++ (clamp a double against the integer range, then compare in double space), verified against both references on 4,000 generated boundary comparisons in [the numeric validation record](../validation/2026-09-16-numeric/). The only remaining failures are the three network-extension disagreements. Previously admitted extension files still pass. No unsupported cases in this pinned full-mode corpus does not prove complete language support: unknown/error values, other runtime extension values, untested libraries, and broader independent compatibility remain unfinished.

The list reference probe also records behavior outside this corpus: CEL-Go's equal-key sorting is unstable and it discards NaN comparison errors. This SDK preserves equal-key order and rejects NaN sorting when a comparison would be needed. It retains `list(dyn)` instead of copying CEL-Go's ambiguous overload-dependent inference. These differences remain explicit, not independent full-compatibility claims.

Alpha.19's Python, Node, and direct Zig reports match macOS arm64 and Linux arm64/glibc 2.28 field-for-field in both modes. [Alpha.19 validation records](../validation/2026-09-16-proto-encoders/) identify those artifacts and runtime versions; they do not verify the newer network changes. [Network validation](../validation/2026-09-16-network/) records the current pass. Earlier [Linux validation](../validation/2026-09-15-linux/) also covered glibc 2.41 with a complete timezone database. A Debian 13 slim image without `tzdata-legacy` also fails two `US/Central` selector cases. [Earlier validation records](../validation/2026-09-15-strong-enums/) retain that attempt and the dependency versions.

The adapters enable `strong_enums` only for the pinned `enums/strong_proto2` and `enums/strong_proto3` sections. These sections describe the mode, but the upstream test message has no dedicated flag for it. Each executed case records `strongEnums`, and the CLI tests run the entire enum file to protect both modes. Expected enum values retain their type name and number, including protobuf's omitted-zero default.

The adapters use the pinned descriptor fixture in `protobuf/` and standard protobuf JSON conversion for test transport. The SDK handles wire parsing, message presence, field typing, boxing/unboxing, and message equality. Node and Zig transport use wire bytes rather than pretending a protobuf message is a plain object.

`report.json`, `report-node.json`, and `report-zig.json` contain full-mode snapshots. `evaluation-python.json`, `evaluation-node.json`, and `evaluation-zig.json` contain evaluation snapshots. Their per-case results match exactly across the three SDKs; only the implementation label differs. `unsupported.json` lists runtime and configuration gaps. It does not remove cases from the corpus.

## Direct Zig transport

Set `CEL_CONFORMANCE_DUMP=/path/file.json` to write the exact adapter transport that `run.py` sends. This replays the direct Zig adapter under an external tool such as kcov without re-running the Python controller.


```sh
zig build conformance -Dconformance=true -Doptimize=ReleaseSafe
printf '%s\n' '[{"id":"answer","expr":"x + 1","variables":{"x":{"primitive":"INT64"}},"bindings":{"x":{"int64Value":"41"}},"check":true}]' \
  | zig-out/bin/cel-conformance
```

The executable returns the integer value `42` and the checked type `INT64`. It calls `Environment.compile()` or `Environment.parse()`, then `Program.evaluate()` directly. It does not execute either language binding. The shared Python controller still selects corpus cases, prepares protobuf wire values, and compares typed results.

Function declarations are transported without host implementations because the pinned function cases are check-only. Generic parameters and abstract result types are encoded explicitly, not disguised as protobuf messages.

The adapter compiles before decoding activation values, so malformed inputs cannot turn parse failures into expected evaluation errors. Check-only cases skip activation decoding and evaluation. Encoded outputs own their strings before the program is destroyed.

Transport batches are limited to 32 MiB, 10,000 requests, 1,024 JSON nesting levels, and two million scanner tokens. Each decoded activation has a 100,000-value and 1 MiB byte budget, with 128 value/type nesting levels. These are audit-tool limits, not process-heap accounting guarantees. Malformed data is an input error, not an unsupported-language excuse.

## Audit checks

```sh
zig build conformance conformance-test -Dconformance=true -Doptimize=ReleaseSafe
bindings/python/.venv/bin/python -m pytest -c bindings/python/pyproject.toml conformance/test_*.py
zig build conformance-test -Dconformance=true --fuzz=100000 -Dtest-filter='untrusted audit transport'
```

The tests invoke the audit CLI. They prove that wrong value types fail, parse errors do not satisfy expected evaluation errors, map keys such as `true` and `1` remain distinct during comparison, and omitted checking cannot produce a full-conformance claim. They also require checked dead branches to fail and intentionally wrong deduced types to be reported as checker mismatches.

Expected values remain in typed protobuf JSON during comparison. Converting them to Python dictionaries first would collapse distinct CEL map keys and could create false positives. Python map inputs use `CELMap`; Node inputs use native `Map`. The typed `optionalValue` audit transport distinguishes an absent payload from a present `null`, including nested optionals. The CLI self-tests check boolean/integer distinctions, unsigned boundaries, input/output round trips, and literals through all three SDKs. These added checks strengthen adapter coverage without changing the pinned corpus or its reported counts.

## Reimport

```sh
source="$(mktemp -d)"
git clone https://github.com/cel-expr/cel-spec.git "$source"
git -C "$source" checkout ba58ae5007845f3a1279b488cdeb79645ce958bb
cd conformance/importer
cache="$(mktemp -d)"
output="$(mktemp -d)"
GOMODCACHE="$cache/mod" GOPATH="$cache/path" go run . \
  --source "$source" --output "$output"
diff -rq ../testdata "$output"
```

The source clone must be at the pinned commit. The importer uses `cel.dev/expr@v0.25.3` and standard protobuf parsers. Use a dedicated output directory: the current importer removes existing JSON files there before generating the corpus.
