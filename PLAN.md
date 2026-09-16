# CEL SDK implementation plan

Objective: a high-performance CEL engine in Zig, with Python and TypeScript SDKs. Correctness is measured through public APIs and upstream CEL conformance tests. Performance is measured on complete application workloads, including binding conversion costs. Performance leadership and full SDK readiness remain unproven.

## Established foundations

- [x] Shared Zig compile/evaluate engine, typed values, explicit ownership, resource limits, public-API tests, allocation-failure injection, and a built-in source fuzzer.
- [x] Native CPython and Node-API bindings without JSON serialization, reusable programs, conversion limits, lifecycle tests, and independent result storage.
- [x] Authorization, validation, cart, and routing benchmarks through all three public APIs, with warm/cold measurements and pinned Python/JavaScript baselines.
- [x] Import every case in the pinned upstream simple-test corpus with provenance and checksums.
- [x] Add one- and two-variable comprehensions, all three transformation macros, quoted fields, absolute names, longest-prefix qualified-variable lookup, and CEL type values.
- [x] Run the shared evaluation audit through Python and Node. Test the audit itself through its CLI, including phase errors, type mismatches, map-key collisions, checksums, and unperformed-checker claims.

## Required remaining work

- [x] Add upstream RE2 matching, literal/dynamic pattern reuse, explicit limits, statically linked SDK artifacts, and whole-request regex benchmarks.
- [x] Add owned environments, namespace containers, variable declarations, constants, checked compilation, and inferred result types for the implemented primitive/collection language.
- [x] Add descriptor-backed proto2/proto3 messages, construction, defaults, presence, repeated/map fields, oneofs, registered extensions, wire transport, and CEL well-known wrapper/JSON/Any conversions.
- [x] Add nanosecond timestamps/durations, checked arithmetic, conversions, timezone selectors, protobuf mappings, and lossless binding value types.
- [x] Add opt-in strong enums, nominal checking, conversion constructors, protobuf field semantics, and lossless bindings. Pass all 85 pinned enum cases without changing legacy defaults.
- [x] Add typed custom functions, overloads, generic signature checking, trusted host callbacks, ownership, and error propagation through all three SDKs.
- [x] Add optional values, access/chaining syntax, optional initializers, lazy defaults, mapping macros, and native bindings; pass all pinned optional cases.
- [x] Add the pinned math extension: numeric extrema, rounding, predicates, absolute/sign operations, and bounded 64-bit bit operations.
- [x] Add the pinned list extension: slicing, flattening, distinct values, integer ranges, reversal, sorting, and single-evaluation sortBy.
- [x] Add `cel.bind` with lazy initialization, per-binding value/error memoization, lexical capture, and checked declarations.
- [x] Support the pinned indexed-block source aliases, including lazy slots, forward/cyclic references, and private lexical iterator/accumulator handles.
- [x] Add all pinned string-extension operations with Unicode code-point semantics, bounded output/search work, CEL quoting, and locale-independent value formatting.
- [x] Add descriptor-backed `proto.hasExt`/`proto.getExt` macros and bounded standard/URL-safe Base64 operations, passing all 22 pinned helper/encoder cases.
- [ ] Complete language grammar, remaining standard functions and extensions, unknown/error values, runtime extension values, and remaining checker type families.
- [x] Run the complete pinned conformance audit directly through the public Zig SDK as well as both bindings, with matched phase/type/value reporting.
- [ ] Expand differential testing beyond the current CEL-Go semantic probes and shared-core parity checks.
- [x] Add lossless typed-map interoperability with Python `CELMap` and native JavaScript `Map`. Preserve ordinary dictionary/object outputs when possible; validate duplicate CEL keys, ownership, and limits.
- [x] Resolve mixed numeric comparison disagreements with authoritative evidence: CEL-Go and CEL-C++ share a clamp-then-double algorithm that the corpus encodes; implemented and verified against both on 4,000 generated comparisons. The four cases now pass without excluding anything.
- [ ] Demonstrate comparative performance leadership on representative workloads. Python now leads the only native Rust binding with arm64 wheels by 7-43x warm on every workload it can run; Node still trails `cel-js` by about 3.2x on warm authorization. Allocation/memory reporting remains unadded.
- [ ] Reach honest native coverage, fuzz structured activations and FFI boundaries, and verify concurrency and resource ceilings. Check malformed host Unicode and exception provenance as well as ordinary values. Native line coverage is now measured (95.66% merged on aarch64 Debug); branch coverage, C++ allocation-failure injection, and proto field-kind fixtures remain.
- [x] Execute alpha.19 Linux arm64 core and installed Python/Node packages down to glibc 2.28, and core tests on emulated Linux x86-64. Match every Linux audit field against macOS. Repeat this matrix for the network changes.
- [ ] Verify current x86-64 binding packages, Windows, other supported runtime/platform combinations, portable distributions, browser support, examples, and every CI gate. Remote CI has not run.
- [ ] Audit the original objective against current artifacts. Do not mark it complete while any required semantics, coverage, portability, or comparative-performance evidence remains missing.

## Latest Node fast-path iteration

- [x] `Program.fastPlan` (Zig, `src/fast_plan.zig`) emits the plain-data subset as JSON or null; quoted fields are excluded by the identifier check that the reverted attempt lacked, plus optional selects, absolute names, unsafe integers, and any environment with a container, constants, functions, or descriptors. Public tests pin the authorization plan byte-for-byte and 19 rejections; allocation failures are exercised.
- [x] The wrapper compiles the plan lazily with `new Function`; `evaluate(bindings, { plainData: true })` runs it and falls back on a bail signal. Tests: every workload decision agrees with the engine in both modes, bail on bigint/double/Map/array/proxy/dotted key/missing root, unused getters unread, hand-built plans outside the vocabulary refused. 108 Node tests at 100% wrapper coverage.
- [x] Read-only review found lone surrogates compared as equal code units (fixed with `isWellFormed`, pinned), and two direct-read differences that are documented in the README and API doc comment rather than hidden.
- [x] Paired on the same build: authorization 955 -> 137 ns (6.9-7.1x, IQR <= 3.9%), about 2.2x faster than `cel-js` (304 ns). Adding `?:` and string-literal indexing brought routing in: 627 -> 93 ns (6.7-6.9x), 2.5x faster than `cel-js` (254 ns). The mix moves 8% with two of twelve workloads in the subset. Default cold path unchanged (compilation is deferred to first plain-data use).

## Latest remote CI iteration

- [x] The repository now lives at github.com/Kludex/cel. The first remote run exposed three problems: `Py_IS_TYPE` does not translate on Python 3.10 headers (replaced with a stable `ob_type` comparison), the audit jobs treated the three retained network disagreements as failures (they now compare against the committed baseline reports with `conformance/compare_reports.py`, pinned by a CLI test), and Zig 0.16.0 fuzz mode cannot rebuild tests on x86_64 Linux (reproduced with a one-test project; the fuzz job runs on the arm64 hosted runner).
- [x] Third run green on all 11 jobs. It produced and tested the first native x86-64 Linux wheel (`cp310-abi3-manylinux_2_28_x86_64`, strict abi3audit, 134 tests) and x86-64 npm archive, closing the long-standing "x86-64 bindings never executed" gap.

## Rejected experiment

- [x] A same-tag scalar fast path in `Context.equal` measured 1.00-1.02x in five paired runs and was reverted (`benchmarks/results/2026-09-16-equal-fastpath/`).

## Latest native-Python competitor iteration

- [x] `python-cel`'s source repository is no longer public, so it cannot be built for arm64. `common-expression-language==0.10.0` (PyO3 over the Rust `cel` crate) publishes native macOS arm64 and Linux aarch64 wheels and is now a `--engine cel-rust` option in `benchmarks/python.py`.
- [x] It supports five of twelve complete workloads (no temporal selectors, math/lists/strings/base64/network namespaces, or optional syntax); the seven compile failures are recorded.
- [x] On those five, same host and CPython 3.14.6, alternating runs, all IQR under 2%: this SDK is 7.1-9.8x faster warm on authorization/validation/cart/routing and 43x on the regex workload; cold is 1.6-30x faster. No workload favored the competitor. Evidence: `benchmarks/results/2026-09-16-python-native/`.

## Latest numeric-semantics iteration

- [x] Re-read the four failing `comparisons/*lossy*` cases: their descriptions state the int-to-double conversion is lossy and the values compare equal. CEL-Go `compareDoubleInt` and CEL-C++ `DoubleCompareVisitor` both clamp against the double-rounded integer bounds and then compare in double space; the SDK's exact f128 comparison was the outlier.
- [x] Replaced `Value.order` with the reference algorithm behind a red public test; three older tests that encoded the exact stance were corrected after each expectation was confirmed against CEL-Go. Extrema ties keep the first argument as CEL-Go does.
- [x] All six audits now agree at 2,505 / 3 / 0 full and 2,481 / 2 / 25 evaluation; only the three network disagreements remain. 138 Zig, 134 Python, 102 Node, 71 CLI tests pass; source and math fuzzers completed 101,982 and 100,036 runs.
- [x] Independent verification: 4,000 generated cross-type comparisons over boundary and random int/uint/double literals and all six operators match CEL-Go's runtime and a from-source transcription of CEL-C++'s comparison visitors with zero mismatches (`validation/2026-09-16-numeric/`).
- [x] Linux matrix rebuilt on these sources: 137 core tests on arm64 glibc 2.28 and emulated x86-64, installed npm on Node 22/24, manylinux_2_28 wheel with strict abi3audit, 134 wheel tests on CPython 3.10.20, and all six audits field-for-field equal to macOS (`validation/2026-09-16-numeric/linux-*`). One container OOM at 1 GiB during the addon build is recorded; 4 GiB succeeded.
- [x] The exact path had also been a hot-path cost: every numeric equality, including `int == int`, went through software `f128`. Paired runs isolating only the `order` change show 1.13-1.15x on the 64-decision mix and authorization (IQR <= 2.2%); cumulative since the evaluator-path checkpoint is 1.24x. Warm Node authorization is now about 0.96 us versus `cel-js` 0.30 us.

## Latest native-coverage iteration

- [x] First measurement of Zig core plus C++ bridge line coverage with kcov 43 on aarch64 Linux Debug binaries: Zig tests alone 91.14%, merged with both corpus modes through the direct Zig adapter 94.70%. `CEL_CONFORMANCE_DUMP` in `conformance/run.py` records the adapter transport for replay.
- [x] Four public-API Zig tests raised the merged figure to 95.66% (tests alone 92.63%): runtime signature checks for network/map/wrapper/type parameters, optional index edge cases, constants of every value family, weekday and millisecond selectors, format byte sanitizing, and container-form quoting. A dead pre-fast-path string-predicate block was removed. 137 Zig tests pass.
- [x] Remaining gaps are documented line by line in `validation/2026-09-16-native-coverage/`: `protobuf.cc` allocation handlers and field kinds absent from the fixtures, `temporal.cc` allocation handlers, FFI status arms, and `unreachable` defaults. kcov attribution has ±1-2 line run-to-run noise on this architecture.
- [x] A fifth public test constructs `TestAllTypes` with every repeated scalar kind, wrapper boxing, `Duration`/`Struct`/`Value` fields, and nested-message assignment plus their rejections; merged coverage is 95.77% (tests alone 93.17%), `protobuf.cc` 82.51%. 139 Zig tests.
- [ ] Add adversarial wire fixtures for the remaining `protobuf.cc` status arms and a failing C++ allocator path. Branch coverage and other targets remain unmeasured.

## Latest evaluator-path iteration

- [x] Profiled native evaluation of complete authorization: map lookups routed every string key through generic equality, bare identifiers went through qualified matching, and string predicates sat behind a 40-comparison extension cascade. Added exact-precondition fast paths for all three; the native probe fell from 455 to 313 ns.
- [x] Python inputs now borrow string/bytes buffers with per-call strong references. A public test drops and reallocates the bindings from a callback and fails without the reference (`red-borrow-without-incref.txt`).
- [x] Node encoder fixed costs trimmed (no per-call deferred allocation, no per-string `push` growth check). Paired: authorization 1.20 -> 1.09 us (1.10-1.12x), mix 1.72 -> 1.58 us (1.08-1.10x). Python authorization about 5% in alternating runs.
- [x] A read-only review found the string-key lookup double-charging mixed-key maps and skipping the depth check; both are fixed and pinned by a public Python test. All gates, six audits, source/checked fuzzing, and the full Linux matrix (glibc 2.28 arm64, emulated x86-64, installed wheel and npm archives, six audit parity) pass on the final sources. Evidence: `validation/2026-09-16-eval-paths/`.
- [x] A `ReleaseFast` addon measured about 18% faster; shipped artifacts stay `ReleaseSafe` for untrusted-expression safety. Recorded, not adopted. `cel-js` remains about 3.7x faster on warm authorization.

## Latest Node request-performance iteration

- [x] Profiled complete warm authorization requests: a constant program against the same bindings cost 1.75 of 2.17 us, so per-value Node-API conversion dominated; pure Zig evaluation was 455 ns with about 40% in the qualified-name activation scan.
- [x] The wrapper now flattens plain request data into typed buffers decoded in one native call; wrapper classes, `Map`, and bytes stay on the per-value converter with exact ancestor chains. The evaluator skips the activation scan when no dotted name can exist.
- [x] Public tests caught five regressions in the first flattened build and a review caught two more (deferred `Map` snapshot order, late collection budget). All are fixed and pinned. Node has 102 tests at 100% wrapper coverage; Zig has 133.
- [x] Paired complete-request runs: authorization 2.16 -> 1.20 us (1.79-1.80x), 64-decision mix 2.60 -> 1.70 us (1.52-1.54x), IQR <= 1.3%. `cel-js` remains about 4x faster on warm authorization; cold is within 4%. Not performance leadership.
- [x] Linux arm64/glibc 2.28 and emulated x86-64 core, installed wheel on 3.10, installed npm on Node 22/24, and all six audits match macOS. Evidence: `validation/2026-09-16-node-plain/`.

## Active network-extension pass

- [x] Establish public red tests and reference evidence for IP/CIDR parsing, identity, classification, containment, and mapped-address edge cases.
- [x] Implement shared network values, type checking, and lossless Python/TypeScript interoperability with bounded input and ownership.
- [x] Measure a complete 600-prefix gateway policy before/after network-value hashing. Three stable pairs reduce elapsed time about 83%; the ordinary 64-decision mix has no meaningful change.
- [x] Finish sequential SDK/audit/source-fuzz gates. Two concurrent commands timed out first; the sequential rerun passes 132 Zig, 132 Python, 94 Node, and 71 audit/CLI tests, with source and checked-source fuzzing at 102,215 and 104,761 runs.
- [x] Rebuild alpha.20 artifacts across the existing matrix: macOS wheels on CPython 3.10/3.12/3.13/3.14, Linux arm64 wheel accepted as `manylinux_2_28_aarch64` with strict `abi3audit`, installed wheel on CPython 3.10.20/glibc 2.28, installed npm archive on Node 24/glibc 2.28 and Node 22/glibc 2.31, all six Linux audits matching macOS field-for-field, and 131 core tests on emulated x86-64. Evidence is in `validation/2026-09-16-network/`.

Current network results: all 69 cases execute in every SDK. Full mode has 66 passes and three visible disagreements; evaluation mode has 67 passes and two. Reject all IPv4-mapped IPv6 forms, including hexadecimal forms that two pinned cases accept. A third case expects an evaluation error for `isIP(cidr(...))`, which correctly fails checking. CEL-Go agrees with these outcomes and additionally validates malformed literal arguments at compile time; this SDK still validates those literals at evaluation time.

Public tests exposed missing nested metadata validation and quadratic network deduplication exhausting the default work budget. Both have regression tests and shared-core corrections. The focused replacement review found no concrete issue; the earlier review failed with an output-limit error and is not review evidence. Unknown/error propagation, broader grammar/libraries, numeric disagreements, native resources/coverage, distribution, and performance leadership remain unfinished.

## Latest protobuf-helper and encoder iteration

1. Added `proto.hasExt` and `proto.getExt` as qualified-name macros over existing descriptor-backed presence/selection. Tests cover defaults, explicit-zero presence, repeated fields, strong enums, wrong containing messages, quoted names, and activation-independent name capture. Qualified field-name lookup now consumes CEL work after a public red test exposed missing accounting.
2. Added standard and URL-safe Base64 via Zig's codecs. Outputs and work are bounded; CR/LF and padded/unpadded input are supported. Nonzero unused tail bits retain CEL-Go compatibility, while spaces, tabs, malformed padding, and wrong alphabets fail. Encoding is canonical. Unrelated encoder APIs are not implied.
3. All 22 pinned helper/encoder cases pass in every SDK and audit mode. Alpha.19 passes 117 Zig tests including the complete-workload test, 125 Python tests, 91 Node tests, and 65 audit/benchmark CLI tests. Formatting, lint, strict typing, wrapper coverage, and allocation-failure gates pass. Binary, malformed-text, checker, and source fuzzers completed 100,046, 122,242, 103,498, and 101,653 executions.
4. Full audits agree at 2,435 passed, four failed, 69 unsupported, with 2,295 checked result types. Evaluation mode reports 2,410 passed, four failed, 94 unsupported. The remaining unsupported corpus file is network_ext; this does not prove that unknown/error values or untested library behavior are complete.
5. Current Linux arm64 packages/core and emulated x86-64 core pass their tests. All six Linux reports match macOS. Sdist wheels pass Python 3.10/3.12/3.13/3.14 on macOS and 3.10 on Linux, with ABI gates; installed Node packages pass macOS 24 and Linux 22/24. A focused review found no concrete issue; an earlier output-limit failure was not counted as a review.
6. Added six complete attachment-ingestion decisions, making 57 across eleven workloads. The changed mix is not a controlled speedup. Competitor failures remain logged; `cel-js` still evaluates original authorization about 6.9 times faster. Evidence is in `validation/2026-09-16-proto-encoders/` and the matching benchmark checkpoint.
7. Network types, unknown/error propagation, broader compatibility/libraries, native coverage/resources, portable distribution, Windows/browser support, remote CI, and performance leadership remain open. Packages remain unpublished.

## Latest string-extension iteration

1. Added code-point indexing/search/substrings, ASCII casing, replacement, splitting, Unicode trimming, joining, reversal, CEL quoting, and value formatting. All 216 pinned string-extension cases pass through every SDK in both modes. Namespace handling and checked argument/result types follow the existing extension model.
2. Public tests caught high precision returning `(float)`, incorrect shortest-decimal rounding, invalid-byte output, extra-argument rejection, borrowed results bypassing limits, and premature duration conversion. The final formatter uses bounded growable storage and C++ standard-library `to_chars` for fixed/scientific precision instead of a rounding workaround or an unconditional 100 KB output allocation.
3. Independent CEL-Go probes and Python checks cover Unicode indexing, 200 generated floating-point values, byte sanitization, duration display, and edge cases. Differences remain explicit: pinned search-boundary errors, collapsed invalid-byte runs, literal format-checking behavior, and the document's inconsistent `%d` type table. Duration display follows specified floating-point seconds; exact arithmetic/storage remains unchanged.
4. Alpha.18 passes 111 Zig tests including the application workload, 118 Python tests, 89 Node tests, and 62 audit/benchmark CLI tests. Formatting, lint, strict typing, wrapper coverage, and allocation-failure gates pass. Unicode, byte-format, checker, and source fuzzers completed 100,030, 200,000, 106,121, and 102,551 executions.
5. Full reports agree at 2,413 passed, four failed, 91 unsupported, with 2,273 successfully checked types. Evaluation mode reports 2,388 passed, four failed, 116 unsupported. All six Linux reports match macOS. Current Linux arm64 and emulated x86-64 core tests pass; installed Node 22/24 packages and macOS/Linux wheels pass their documented matrices and ABI gates.
6. Added six complete text-ingestion decisions, making 51 across ten workloads. Warm medians are 1.442 us Python, 2.547 us Node, and 0.807 us native Zig. The changed mix is not a controlled aggregate speedup. Both pinned JavaScript baselines fail the new policy on missing operations; original authorization still favors cel-js by about 6.9 times.
7. Evidence is in `validation/2026-09-16-strings/` and the matching benchmark checkpoint. Network/encoder/protobuf helpers, unknown/error values, broad compatibility, native coverage/resources, portable distribution, Windows/browser support, remote CI, and performance leadership remain open.

## Latest indexed-block iteration

1. Added the pinned optimizer/conformance source aliases `cel.block`, `cel.index`, `cel.iterVar`, and `cel.accuVar`. Runtime slots are lazy, cache values/errors per block evaluation, and capture block-entry scope. Private lexical identifiers cannot be supplied by activations. All 37 pinned cases pass through every SDK in both modes.
2. Public red tests and CEL-Go probes corrected two provisional restrictions: forward/cyclic references are resolved lazily rather than rejected during parsing, and optional slot markers preserve values without compacting indices. The source aliases map to AST-only operators in CEL-Go; no normative broader block language is claimed.
3. Added nested-frame, scope-capture, host-error, reentry/GIL-release, alias-spoofing, optional-slot, allocation-failure, and resource tests. Dependency graph, request-cache, checker, and source fuzzers completed 100,039, 100,012, 103,567, and 101,950 executions. A focused review found no concrete issue; a queued implementation delegation was stopped and not counted as completed work.
4. Alpha.17 passes 105 Zig tests including the application workload, 111 Python tests, 86 Node tests, and 59 audit/benchmark CLI tests. Formatting, lint, strict typing, and wrapper coverage gates pass. Full audits agree at 2,197 passed, four failed, 307 unsupported; evaluation mode reports 2,172 passed, four failed, 332 unsupported, with 2,101 checked types in full mode.
5. Installed packages pass macOS and Linux tests, including glibc 2.28 and Linux Node 22/24. Sdist wheels pass the macOS Python 3.10/3.12/3.13/3.14 matrix, Linux Python 3.10, and ABI audits. All six Linux audit reports match macOS. Emulated x86-64 core passes all 104 tests; packages remain unpublished.
6. Equivalent indexed dispatch policies change 500-job elapsed time by about 2%, below the meaningful-effect threshold. The ordinary 45-decision mix also shows no meaningful change. Fresh authorization still favors `cel-js` by about seven times. Evidence is in `validation/2026-09-16-blocks/` and the corresponding benchmark checkpoint.
7. Remaining string/network/encoder/protobuf-helper extensions, unknown/error values, independent compatibility, native coverage/resources, broader distributions/platforms, remote CI, and performance leadership remain open.

## Latest local-binding iteration

1. Added `cel.bind` as a shared AST/checker/evaluator feature. Stack-local cells capture the outer scope and cache initializer values or CEL errors on first use. Compiled programs retain no request caches. Local-name traversal and matching consume evaluation work.
2. Public red tests and CEL-Go probes establish lazy behavior, repeated-request isolation, error memoization, lexical/absolute lookup, exact namespace matching, and custom-function precedence. An absolute binding name is accepted but absolute references bypass it, matching the reference. Checked compilation still validates unused initializers.
3. Python/Node tests cover empty/null values, host-error identity, reentry, and result ownership. The Python same-program concurrency test releases the GIL during initialization. Allocation-failure checks pass; binding, checker, and source fuzzers completed 100,020, 105,366, and 102,388 executions. A focused review found no concrete issue; an earlier timeout is not counted as a review.
4. Alpha.16 passes 100 Zig tests including the application workload, 103 Python tests, 83 Node tests, and 56 audit/benchmark CLI tests. Formatting, strict typing, lint, and wrapper coverage gates pass. All eight pinned binding cases pass; full audits now agree at 2,160 passed, four failed, 344 unsupported, with 2,064 checked result types.
5. Installed packages pass macOS and Linux runtime checks, including glibc 2.28 and Node 22/24. Sdist wheels pass the macOS Python 3.10/3.12/3.13/3.14 matrix, Linux Python 3.10, and ABI gates. All six Linux audits match macOS; emulated x86-64 core passes all 99 tests. Packages remain unpublished.
6. Paired complete-policy benchmarks compare identical inputs and expected decisions, recording both expressions. Reusing flattened jobs changes the 500-job latency by about 1.9-2.3%, below the meaningful-effect threshold. The ordinary mix also shows no meaningful change. Original authorization still favors `cel-js` by about 7.1 times.
7. Evidence is in `validation/2026-09-16-bindings/` and its benchmark checkpoint. Indexed blocks, remaining libraries, unknown/error values, broad compatibility, native coverage/memory accounting, other platforms, remote CI, and performance leadership remain open.

## Latest collection-extension iteration

1. Implemented all seven pinned list operations in the shared engine, with static checking, lexical sortBy scope, single receiver/key evaluation, stable equal-key order, and allocation/work/depth limits. All 52 pinned cases pass through every SDK in both modes.
2. Public red tests caught invalid sortBy receiver syntax, missing container lookup, nested protobuf wrappers comparing unequal to scalars, and checked sorting rejecting wrappers. Shared equality now adapts nested protobuf values, and comparable-type checking accepts scalar wrappers.
3. A 3,000-ID policy exposed quadratic distinct work. Larger scalar lists now use hash buckets with budgeted CEL equality on collisions; small lists avoid hash overhead, and compound values retain a bounded-comparison fallback. Numeric alias/collision tests and a public Value.eql differential fuzzer verify hashing semantics.
4. Review exposed one-step accounting for whole protobuf comparisons. Cached encoded-size/reflection estimates now consume CEL work, including nested and unknown fields. This is a work proxy, not exact native CPU or allocator accounting. Public tests demonstrate unsuppressible cost failures for constructed and wire messages.
5. Alpha.15 passes 96 Zig tests including the application workload, 95 Python tests, 78 Node tests, and 50 audit CLI tests. Formatting, lint, strict typing, wrapper coverage, allocation-failure tests, and five 100,000-plus fuzz targets pass. Full audits agree at 2,152 passed, four failed, 352 unsupported; evaluation mode reports 2,127 passed, four failed, 377 unsupported.
6. Linux arm64 core and installed bindings pass on glibc 2.28; all six Linux reports match macOS. Emulated x86-64 core passes all 95 tests. Sdist wheels pass the Python 3.10/3.12/3.13/3.14 macOS matrix and Linux 3.10, with ABI gates. Node packages pass macOS 24 and Linux 22/24. Packages remain unpublished.
7. Added six batch-dispatch decisions, making 45 across nine workloads. A separate complete 500-job dispatch comparison improves by about 53% in three stable pairs and a clean rebuild, while the ordinary mix is unchanged by hashing. Original authorization still favors cel-js by about 6.8 times. Evidence is in `validation/2026-09-16-lists/` and the matching benchmark directory.
8. Reference differences remain explicit: stable ties, rejection of multi-element NaN sorting, and precise list(dyn) inference differ from CEL-Go's unstable/overload-dependent behavior. These and the four numeric disagreements still require authoritative compatibility review. Compound scaling, native memory accounting, remaining extensions, broader platforms, and performance leadership remain open.

## Latest Node request-performance iteration

1. Re-measured complete requests and profiled authorization and the full 39-decision suite. Native stacks identified property enumeration and conversion costs. Moved intrinsic Map/plain-record recognition before optional wrapper checks and replaced generic native property enumeration with captured JavaScript intrinsics.
2. Public red tests exposed Maps misclassified through `OptionalValue.prototype` and proxy traps running before rejection. Added key/getter ordering, symbol errors, prototype pollution, optional subclass, mutable instance-hook, and reentrancy cases. All 75 Node tests pass at 100% wrapper coverage.
3. Three stable paired runs show 13-15% authorization reductions and 10.7-11.5% reductions across all 39 decisions. A clean-build reproduction confirms 14.7% on authorization. Cart, customer-format, and optional authorization also improve in measured complete-policy comparisons. The first clean-build run was unstable and remains visible.
4. Discarded a fused classification/key transport: its extra shape-discrimination code bought only about 0.7% on authorization. Retained its patch and measurements. The simpler implementation preserves string-keyed getter effects before enumerable-symbol errors and does not invoke inherited setters for appended symbol keys.
5. Alpha.14 passes 88 Zig tests including the application workload, 86 Python tests, 75 Node tests, 47 audit CLI tests, formatting, lint, strict typing, and wrapper coverage gates. All six macOS audits remain unchanged. Linux Node full/evaluation reports on glibc 2.28 match every macOS field.
6. Installed Node archives pass all 75 tests on macOS Node 24, Linux Node 22/glibc 2.31, and Linux Node 24/glibc 2.28. Sdist-built wheels pass Python 3.10/3.12/3.13/3.14 on macOS and Python 3.10/glibc 2.28 on Linux, including strict ABI gates. Independent reviews found no remaining concrete issues in the changed conversion path.
7. `cel-js` still evaluates authorization about 6.9 times faster: 0.306 us versus 2.101 us. Full-suite cold changes remain below the meaningful-effect threshold. Native coverage, memory accounting, broader platform support, unsupported language cases, and performance leadership are still open. Evidence is in `validation/2026-09-16-node-requests/` and the matching benchmark checkpoint.

## Latest Linux portability iteration

1. Docker became available. Rebuilt and executed all 87 core tests on Linux arm64 and emulated x86-64. Installed alpha.13 packages pass 86 Python tests and 68 Node tests, including callback concurrency and ownership paths. Both wrapper coverage gates remain at 100%; native coverage is still unproven.
2. A source-built wheel failed on older glibc. GNU targets now default to glibc 2.28 instead of inheriting a newer host requirement, while explicit target versions remain available. `auditwheel` rejects the earlier artifact and accepts the corrected manylinux 2.28 wheel.
3. The minimum-Python test then exposed an unintended Python 3.14 `Py_TYPE` dependency from Zig's translated C macros. Exact checks use `Py_IS_TYPE`; flag checks use stable `ob_type` and `PyType_HasFeature`. Strict `abi3audit` now passes. CI includes both ABI gates and installed-wheel tests on Python 3.10, but remote execution remains unverified.
4. The same Linux wheel passes on Python 3.10 with glibc 2.28/2.31 and Python 3.14 with glibc 2.41. The same Node archive passes on Node 22/24, including Node 24 on glibc 2.28/2.31/2.41. All three full/evaluation audit pairs match macOS on both glibc 2.28 and 2.41. Current Linux execution no longer depends on alpha.7 evidence.
5. macOS SDK gates and the sdist-built alpha.13 wheel pass; all 86 wheel tests run on Python 3.10/3.12/3.13/3.14. Packages remain unpublished. Current Linux x86 binding packages, multi-platform npm installation, older macOS versions, Windows/browser support, and remote CI still need work.
6. Whole-application before/after measurements retain all 39 decisions, 30 samples, and reversed run order. Warm time changes from about 1.419 to 1.398 us; cold time remains about 9.5 us. The approximately 1.4% difference is below the meaningful-effect threshold, not a performance win.
7. An independent native Python competitor probe passes 22 decisions across five complete workloads under x86 emulation. Remaining temporal, optional, and math policies fail. Corrected its benchmark adapter to use `Program.execute(Context)` and verified the public CLI. Emulated smoke timings do not establish performance leadership. Evidence is in `validation/2026-09-15-linux/` and the Linux benchmark checkpoints.

## Latest math-extension iteration

1. Added numeric extrema, rounding, predicates, absolute/sign functions, and 64-bit bit operations in a shared Zig module. Extrema retain the winning type and first-tie value; comparisons retain existing exact numeric semantics. Shift counts are validated before narrowing, and signed right shifts are logical.
2. Added parse-time extrema validation and static checking for every operation. A failing public test caught overly narrow inference when a dynamic argument could win; those calls now infer `dyn`, corroborated by a CEL-Go probe.
3. All 199 pinned math cases pass through every SDK. Full audits agree at 2,100 passed, four failed, and 404 unsupported; evaluation mode reports 2,075 passed, four failed, and 429 unsupported. The four numeric disagreements remain visible.
4. Alpha.12 passes 88 Zig tests, 86 Python tests, 68 Node tests, 47 audit CLI tests, and both 100% wrapper coverage gates. Math/source/checker fuzz targets completed 194,141, 101,791, and 105,325 executions. Allocation-failure and resource-limit tests pass.
5. The sdist-built wheel passes Python 3.10/3.12/3.13/3.14. The addon passes Node 22/24 and a separately installed archive smoke test. Linux artifacts cross-link but remain unexecuted while Docker is unavailable.
6. Added six complete quota/permission decisions, bringing the workload suite to 39 decisions across eight workloads. Warm medians are 1.25 us Python, 2.56 us Node, and 0.64 us native Zig. Configurable Zig iteration counts retain 30 samples and five warmups; two earlier command timeouts are recorded, not counted as successful measurements.
7. The new math policy exposes missing competitor overloads and the protobuf-Struct adapter's loss of integer mask types. Those failures remain recorded. Original authorization still favors `cel-js` by about eight times; no overall performance-leadership claim is made.

## Latest optional-value iteration

1. Added optional values without widening scalar storage, optional field/index access and chaining, list/map/message initializer markers, lazy `or`/`orValue`, and single-evaluation `optMap`/`optFlatMap`. Checking preserves fresh payload inference and validates skipped branches.
2. Added zero-value construction, optional equality, list unwrap/first/last helpers, value matching, protobuf presence semantics, and lossless Python/Node `OptionalValue` wrappers. Present null and absence remain distinct through constants, callbacks, nested values, and audit transport.
3. All 70 pinned optional cases and the six previously failing optional checker cases pass through every SDK. Full audits now execute every core case: 1,901 passed, four mixed-numeric failures, and 603 unsupported extension cases. Evaluation mode reports 1,876 passed, four failed, and 628 unsupported. Full reports record 1,805 checked types.
4. Independent CEL-Go probes informed boundary tests. An added failing test caught invalid fractional optional indexes being treated as absence; those now remain errors. Absent optionals still skip later index expressions, and timestamp zero means year 1 rather than the Unix epoch.
5. Alpha.11 passes 81 Zig tests, 83 Python tests, 65 Node tests, 44 audit CLI tests, and both 100% wrapper coverage gates. The optional/source fuzzer completed 118,795 executions; the checked-source target completed another 102,663. Allocation-failure tests cover optional ownership paths.
6. The sdist-built wheel passes Python 3.10/3.12/3.13/3.14. The addon passes Node 22/24 and a separately installed archive check. Linux core and binding artifacts cross-link, but Docker remains unavailable for execution.
7. Added a six-decision optional authorization workload, bringing the suite to 33 decisions across seven workloads. Warm medians are 1.23 us Python, 2.43 us Node, and 0.64 us native Zig. The new mixture is not directly comparable to earlier aggregates. Baseline optional configuration was checked and enabled where available; missing overload/parser failures remain recorded. Original authorization still favors `cel-js` by about eight times.

## Latest custom-function iteration

1. Added typed flat overload declarations, global/receiver namespace resolution, callbacks, fresh generic substitutions, and abstract type descriptions. Failed overload candidates roll back all speculative constraints. Checked calls retain final inferred return contracts; erased overlapping signatures are rejected.
2. Added Python `Function` and TypeScript `FunctionDeclaration`, with native value conversion for callback arguments/results. Programs retain environments through host-visible references so callback cycles remain collectable. Zig contexts remain explicitly borrowed.
3. Preserved host exception identity at native compile/evaluation boundaries, including native-looking error codes. Host callback exceptions are fatal to CEL evaluation; ordinary CEL errors retain language suppression rules. Callback collections obey configured limits.
4. A deterministic two-thread test caught per-environment callback state corruption when Python host code released the GIL. Callback frames are now thread-local and nested frames restore correctly. Public tests also cover reentrancy, message ownership, allocation failures, signatures, and limits.
5. The five pinned function/generic checking cases pass through every SDK. Full audits now agree at 1,825 passed, 10 failed, and 673 unsupported, with 1,729 checked types. Six previously filtered optional-library cases are newly visible failures alongside the four mixed-numeric disagreements; they are not reclassified to green the audit. Evaluation-only counts are unchanged.
6. Alpha.10 passes 71 Zig tests, 74 Python tests, 56 Node tests, 38 audit CLI tests, and both 100% wrapper coverage gates. The sdist-built wheel passes Python 3.10/3.12/3.13/3.14; the addon passes Node 22/24 and a separately installed callback smoke test. Updated Linux artifacts cross-link but remain unexecuted while Docker is unavailable.
7. Function and checked-source fuzz targets completed 106,127 and 105,511 executions. A Debug audit-fuzzer attempt timed out; a separate ReleaseSafe run completed 191,100 executions. The independent CEL-Go generic-erasure probe corroborates allowing mixed runtime types when `dyn` erased the static constraint.
8. Whole-policy callback benchmarks verify all 27 decisions through all three SDKs. Warm medians are about 1.28 us for Python, 2.45 us for Node, and 0.65 us for native Zig values. These are differing paths, not isolated callback overhead or performance-leadership evidence.

## Latest direct-Zig conformance iteration

1. Added failing shared CLI tests for a third engine, then implemented a standalone adapter using only public Zig SDK calls. The shared Python controller still selects cases, prepares protobuf wire transport, and compares outcomes; it does not evaluate Zig cases through a language binding.
2. Added strict typed-JSON value/type conversion, owned output strings, compilation-before-activation decoding, check-only handling, and explicit byte/value/nesting/batch limits. Malformed values remain input errors rather than being mislabeled unsupported features.
3. All three full-mode reports match except for the implementation label: 1,820 passed, four failed, 684 unsupported, and 1,724 successfully checked types. Evaluation-only reports also match: 1,806 passed, four failed, and 698 unsupported. No corpus, admission policy, or expected result was weakened.
4. All 35 CLI tests pass with Debug, ReleaseSafe, and ReleaseFast adapters. Exact-limit tests also corrected the reader's EOF boundary so a 32 MiB batch is accepted. The public audit transport fuzzer completed 198,873 executions without traps or leaks. Existing SDK tests and both 100% wrapper coverage gates remain green; native coverage is not established.
5. Added optional adapter build/test targets, Zig matrix coverage in the conformance workflow, and the transport fuzzer in CI. Linux arm64/x86-64 adapters cross-link, but Docker and remote CI remain unavailable for execution. A source-distribution wheel build verifies the optional target does not become a product dependency.
6. Reran all 27 application decisions through Zig, Python, and Node. Stable warm medians are 0.67 us for native Zig values, 1.24 us for Python, and 2.42 us for Node. These are different input paths and not proof of comparative leadership; no product runtime optimization was introduced.

## Latest typed-map iteration

1. Added failing public tests and implemented Python `CELMap`, native JavaScript `Map` inputs, and lossless nested results. Python returns dictionaries unless boolean/integer keys would collapse. TypeScript outputs are valid inputs without casts. Both SDKs reject CEL-equivalent numeric duplicate keys.
2. Replaced quadratic constant-map duplicate detection with shared hash-based validation. A 2,049-entry constant now stays within the work budget. Public allocation-failure tests and 109,982 map-key fuzz executions exercise key equality, collisions, and cleanup.
3. Captured JavaScript map operations and used a null-prototype entry snapshot before value getters run. Review-driven tests cover spoofed proxy prototypes and polluted object/array prototypes. Proxy CEL values, keys, and binding records are rejected explicitly. Both SDKs now count map keys and values consistently.
4. Passed 59 Zig tests, 51 Python tests, 44 Node tests, eight conformance CLI tests, and both 100% wrapper coverage gates. Full/evaluation audit counts remain unchanged; additional CLI tests cover map distinctions absent from the admitted pinned cases.
5. Alpha.9's sdist-built wheel passes Python 3.10/3.12/3.13/3.14. The addon passes Node 22/24; a separately installed npm archive passes mixed-key round-trip and proxy checks. Updated Linux core and binding binaries cross-link, but Docker remains unavailable for runtime validation.
6. Added a `candidate-maps` application mode that constructs typed maps inside each timed request. On the same 27 decisions, Python measures 4.60 us warm and Node 3.34 us, versus 1.25 us and 2.43 us for ordinary dictionaries/objects. These fixtures have string keys; numeric-key application benchmarks remain needed.
7. The paired ordinary-object Node comparison records a 6.5% slowdown after map recognition was added. It is below the meaningful-effect threshold, but remains visible. Earlier descriptor-based snapshots and pre-review results are retained. Performance leadership is not established.

## Latest conversion/performance iteration

1. Profiled complete Node authorization requests. Conversion, string length/copy operations, property enumeration, and property reads dominate the observed stacks; sampled stacks are not exact phase timings.
2. Added failing public Unicode tests and a shared short-string reader. Lone JavaScript surrogates now raise `TypeError` in source, inputs, names, and metadata instead of silently becoming `U+FFFD`. Valid replacement characters and exact UTF-8 byte budgets are preserved.
3. Added per-evaluation 4 KiB standard-library stack storage with arena fallback to both bindings. Public tests cover nested Node evaluations, GC, large requests, errors, and independent results. No request cache or lazy input validation was introduced.
4. Rejected an all-UTF-16 conversion experiment that made authorization about 10% slower. Retained all intermediate measurements and added per-workload selection to the profiler and paired driver. A baseline restoration patch reproduces the exact original Node source.
5. Customer-format validation improved by 10.3-15.1% across three paired comparisons, including two fresh builds. Full-mix reductions were about 9%, below the 10% meaningful elapsed-effect threshold. Authorization remains roughly 6.6 times slower than `cel-js`, and customer-format validation also remains slower. Python's sequential reductions stayed below the threshold.
6. Alpha.8 passes 55 Zig tests, 46 Python tests, 29 Node tests, six conformance CLI tests, and both 100% wrapper coverage gates on macOS. The sdist-built wheel passes Python 3.10/3.12/3.13/3.14; the addon passes Node 22/24 and a separately installed npm archive smoke test. Full/evaluation audit counts are unchanged.
7. Both updated bindings cross-link for Linux arm64, but Docker became unavailable before execution. Current Linux binding tests remain pending; alpha.7's earlier Linux execution is not substituted for validation of these changes. Evidence is in `validation/2026-09-15-conversion/` and `benchmarks/profiling/results/2026-09-15-strings/`.

## Latest strong-enum iteration

1. Added `Environment.strong_enums` / `strongEnums`, defaulting to false. Distinct enum values carry a fully qualified name and signed 32-bit number. Constructors accept exact symbols or in-range integers; fields require matching enum types in strong mode.
2. Added checked enum declarations, constants, type values, collection fields, namespace resolution, and Python/Node `EnumValue` wrappers. Enum metadata stays behind a pointer rather than widening every scalar value.
3. Added failing public tests before implementation. Review found that forged enum constants could masquerade as primitive types; recursive environment validation now rejects them. Native Python rejects spoofed non-integer metadata rather than invoking callbacks during conversion.
4. Both bindings pass all 85 pinned enum cases. Full audits now pass 1,820, fail four mixed-numeric cases, and leave 684 unsupported. Evaluation-only audits pass 1,806, fail four, and leave 698 unsupported. Full reports record 1,724 successfully checked types.
5. Passed 54 core tests plus one shared-workload test in Debug, ReleaseSafe, and ReleaseFast. All six fuzz targets completed another 100,000+ executions, including enum conversion and checked-source enum-mode variation. Zig allocation-failure and concurrent descriptor-evaluation tests pass; foreign allocator injection and native coverage remain open.
6. Alpha.7's sdist-built wheel passes 45 tests on Python 3.10/3.12/3.13/3.14. The addon passes 24 tests on Node 22/24; a packed archive was installed separately and exercised. Both wrappers retain their 100% coverage gates. Build paths replace native library inodes atomically after reproducing a macOS stale code-signature crash.
7. Executed all 54 core tests in Linux arm64 and emulated Linux x86-64 containers. Linux arm64 also passes 45 Python tests and 24 Node tests. Complete conformance reports match macOS with Debian's full timezone data. The bare slim image lacks `US/Central`; the two extra failures and the `tzdata-legacy` dependency remain recorded in `validation/2026-09-15-strong-enums/`.
8. Reran all 27 application decisions with 30 samples. Stable warm medians are 1.33 us for Python, 2.51 us for Node, 9.39 us for `cel-js`, and 17.40 us for `bufbuild`. Original authorization still favors `cel-js`, 0.30 us versus 2.28 us. No overall leadership or enum-specific throughput claim is made.

## Previous temporal iteration

1. Added inline nanosecond timestamp and duration values, range-checked arithmetic/conversions, RFC3339 parsing, compound duration parsing, calendar selectors, and explicit timezone support using existing protobuf/Abseil code.
2. Added Python `Timestamp`/`Duration` and Node bigint-based equivalents. Protobuf temporal fields, Any packing, JSON conversion, and null pruning retain precision and CEL behavior.
3. Matched the pinned CEL millisecond-component behavior rather than silently adopting a newer reference runtime's total-millisecond interpretation. Normalized the one in-range large nanosecond component that Abseil's signed-integer parser cannot represent directly.
4. Rejected path traversal, local-machine aliases, and repeated separators in timezone names. Named zones still use the host database; no pinned timezone-data version is claimed.
5. Added public-API boundary, daylight-saving, nanosecond, ownership, allocation, and fuzz checks. Temporal string fuzzing completed over 100,000 executions.
6. Added a five-case temporal authorization workload and whole-workload selection. The suite now has 27 decisions; historical aggregates with 17 or 22 decisions are not directly comparable. `cel-python` fails the one-nanosecond deadline case and is not timed for the complete suite.
7. Alpha.6 passed 37 Python public-API tests on Python 3.10/3.12/3.13/3.14 and 17 Node tests on Node 22/24. The wheel was built from its sdist; a packed addon was installed separately and exercised. Linux x86-64/arm64 test binaries cross-linked, but Linux execution remains unverified.

## Latest protobuf iteration

1. Pinned protobuf 36.1 and its vendored utf8_range, extended the reproducible native-source manifest, and statically linked both with RE2 and Abseil. Added real descriptor fixtures generated from the pinned CEL specification.
2. Added reference-counted descriptor registries, evaluation-local protobuf arenas, lazy wire parsing, message construction/selection, defaults, presence, repeated/maps, oneofs, enum-as-int values, registered extensions, and descriptor-backed checking.
3. Added `Message` wire-value transport and `Environment(descriptors=...)` to both bindings. Native pointers are removed before results leave evaluation. Regular messages remain distinct from maps; protobuf semantics, not byte order, govern expression equality.
4. Implemented scalar wrappers, JSON `Value`/`Struct`/`ListValue`, and `Any` boxing/unboxing, including null pruning/retention and protobuf JSON conversion. A private descriptor pool also permits semantic comparison of packed Any payloads.
5. Exercised public ownership, malformed-wire, overflow, descriptor-limit, and well-known-type tests. Wire-input fuzzing completed 100,000+ executions; Zig allocation failure injection tests descriptor/message cleanup but does not inject C++ allocator failures.
6. Added a complete-request protobuf round-trip benchmark. Moved message metadata behind a pointer to avoid widening every scalar value; noisy native-object timings do not establish a throughput improvement from that representation change.
7. Alpha.5 passed 34 public Python tests on Python 3.10/3.12/3.13/3.14 and 15 Node tests on Node 22/24. The wheel was built from its sdist; the packed addon was installed separately and exercised. Linux x86-64/arm64 test binaries cross-linked successfully, but Linux execution is still unverified.
8. The 22-decision protobuf round-trip runs include host Struct encoding, wire transport, and complete policy evaluation. Stable warm medians were 15.70 us for Python and 13.80 us for Node; these are not comparable to native-object inputs and do not establish performance leadership.

## Latest environment/checker iteration

1. Added immutable native environment snapshots with namespaces, declarations, constants, and optional checking. Legacy `Program(source)` stays unchecked; `Environment.compile()` checks by default.
2. Implemented primitive/collection/type-value inference, builtin overload checks, macro typing, transactional type-variable unification, and inferred result types. Invalid dead branches are checked. Ranked variable unions prevent flat aggregate inference from becoming an artificial nesting failure.
3. Lowered checked references to declared fully qualified variables, and disabled ambiguous qualified-name probes for checked field access. Undeclared activation keys cannot redirect a checked map selection.
4. Added Python and Node bindings, ownership tests, inference-budget tests, allocation-failure tests, and a checked-source fuzzer. Shared audits now run actual checking, compare deduced types, and execute check-only cases without evaluation.
5. Measured checked and unchecked complete request workloads. Checking adds cold work; observed warm differences were below the meaningful-effect threshold. No speedup or overall-readiness claim is made from this milestone.
6. Alpha.4 wheels passed all 31 Python public-API tests on 3.10, 3.12, 3.13, and 3.14. The addon passed all 12 wrapper tests on Node 22.14.0 and 24.14.1. Source and checked-source fuzz targets each completed another 100,000+ executions, and Linux x86-64/arm64 test binaries cross-linked successfully.

## Latest RE2 iteration

1. Pinned RE2 2025-11-05 and Abseil 20260817.0, generated their 148 translation-unit dependency closure, and built them with Zig. Normal builds require neither CMake nor system RE2 libraries.
2. Added both matching forms, Unicode/RE2 grammar tests, lazy evaluation of invalid-pattern errors, per-program literal caches, per-evaluation dynamic caches, resource limits, and concurrent evaluation tests.
3. Detected and guarded RE2's tiny-budget behavior: it computes `max_mem * 2 / 3`, where zero means unlimited. Also prevented signed overflow when forwarding user-configured budgets.
4. Added source and dynamic-pattern fuzz targets. Each has completed over 100,000 executions. Zig allocation-failure injection exercises cache cleanup; it does not cover RE2's separate C++ allocator.
5. Verified static linkage, license notices, source-distribution wheel builds, Python 3.10/3.12/3.13/3.14, Node 22/24, and Linux x86-64/arm64 test-binary cross-linking. Linux execution remains unverified.
6. Added customer-format validation to the shared application suite. The new 22-case measurements are not directly comparable with historical 17-case aggregates.

## Previous iteration

1. Added two-variable comprehensions, quoted fields, type values, and qualified/absolute names using failing public-API tests and upstream cases.
2. Corrected double-to-int lower-bound handling after reading the language definition's explicit non-inclusive range.
3. Checked macro arity and absolute-call behavior against CEL-Go. Only matching signatures now expand; presence checks have their own compiled node instead of relying on unchecked call arguments.
4. Profiled complete Node requests. Converter frames dominated the observed native sample. Captured intrinsic prototypes and reduced repeated class/prototype checks, with a regression test for overwritten globals and preserved wrapper subclass support.
5. Added the Node audit adapter and separated full conformance from evaluation-only results. The old audit could incorrectly imply that a default checker phase had run. Full mode now fails on unsupported phases as well as failed cases.

## Evidence and caveats

- Toolchains: Zig 0.16.0, Node 24.14.1, uv 0.12.1.
- Pinned specification and all 2,508 simple tests: https://github.com/google/cel-spec/tree/ba58ae5007845f3a1279b488cdeb79645ce958bb
- Evaluation mode: all three SDKs match 2,410 cases, fail four, and report 94 unsupported. These results deliberately omit checking and do not claim full conformance.
- Full mode: each SDK matches 2,435 cases, fails four, and reports 69 unsupported extension cases. Checking actually runs when requested; 2,295 successful checked cases include their inferred type. Every core corpus case executes, but this is not proof that all language behavior is covered.
- Remaining full-mode failures are the three network-extension disagreements; the former mixed-numeric failures pass after adopting the shared reference comparison algorithm. Both enum modes, function/generic declaration cases, and optional cases pass. Unknown/error values, arbitrary runtime extension values, and extension libraries remain gaps. All admitted temporal cases pass with complete host timezone data, including legacy aliases.
- The integer conversion disagreement is resolved: CEL explicitly excludes both integer endpoints for double conversions. Mixed comparison follows the clamp-then-double algorithm shared by both reference implementations. `conformance/reference/` records CEL-Go observations without treating every unchecked-runtime quirk as normative behavior.
- Python wrapper line/branch coverage, including tests, is 100%. Node wrapper line/branch/function coverage is 100%. These percentages do not measure native Zig coverage.
- Source fuzzing has completed over 100,000 runs after the new compiler changes. It is not a substitute for structured activation or binding fuzzing.
- The initial stable benchmark showed the Node candidate about 4.9 times slower than `@marcbachmann/cel-js` on warm requests. Uncontrolled follow-up attempts were too noisy. Two later interleaved whole-request comparisons isolated the converter change and measured 1.56x and 1.57x speedups with acceptable variance, reducing evaluation time by about 36%. This does not establish leadership against competing SDKs; see `benchmarks/profiling/`.
- Alpha.2 adds `CELType` to both SDKs and preserves Node uint results as `UInt`, instead of losing the type in a bare bigint. Its macOS arm64 wheel was built from the sdist and passed all 27 public-API tests on Python 3.10, 3.12, 3.13, and 3.14. The same Node-API binary passed all 10 wrapper tests on Node 22.14.0 and 24.14.1, and a packed npm tarball was installed and exercised separately.

## Historical RE2 measurements and remaining caveats

- Alpha.3 macOS wheels pass 28 public-API tests on all four tested Python versions. The addon passes 11 public-API tests on Node 22.14.0 and 24.14.1.
- `benchmarks/results/2026-09-15-re2/` contains 30-sample whole-request measurements with the 22-case workload mix. Warm medians are 0.90 us for Python, 2.03 us for Node, and 0.32 us for native Zig inputs.
- The Node candidate remains about three times slower than `@marcbachmann/cel-js` on warm requests; its cold regex compilation is also slower. Performance leadership is not established.
- RE2's memory option bounds its program/DFA storage, not total heap use. Foreign allocation-failure injection, native coverage, and Node external-memory pressure accounting need further work.

## Historical checked-path measurements

- The checked and unchecked paths use the same 22 complete application decisions. All four 30-sample runs in `benchmarks/results/2026-09-15-checked/` satisfy the variance threshold.
- Python medians: unchecked 11.91 us cold / 0.95 us warm; checked 13.63 us cold / 0.89 us warm. Node: unchecked 14.56 us / 2.06 us; checked 16.72 us / 2.03 us.
- Warm differences are below 10%, so do not present them as a meaningful optimization. Declaration-based access planning is a foundation for further work, not performance leadership.

## Temporal benchmark caveats

- Stable 27-decision aggregate warm medians were 1.27 us for Python, 2.42 us for Node, 8.53 us for `@marcbachmann/cel-js`, and 16.46 us for `@bufbuild/cel`.
- This is not universal performance leadership: on the original authorization workload alone, Node measured 2.25 us versus 0.30 us for `@marcbachmann/cel-js`. Keep contrary per-workload results visible.
- The pure-Python baseline accepts a request that exceeds its deadline by one nanosecond. Its complete-suite benchmark stops before timing; the failure is recorded rather than changing the expected decision.

## Next concrete steps

1. The pinned corpus is now fully executed; implement unknown/error values, remaining grammar/checker behavior, and untested runtime/library APIs with independent tests. Keep the complete original SDK objective intact rather than treating the executed corpus as completion.
2. Add broader differential tests and numeric-key application workloads. The direct Zig audit now runs; shared-core parity is not a substitute for independent reference implementations. The generated numeric differential is a model for further operator families.
3. Improve native memory-pressure accounting and foreign allocation-failure coverage. Expand structured FFI/resource tests beyond wrapper coverage.
4. Close the remaining ~3.2x warm authorization gap to `cel-js` (now 0.96 us versus 0.30 us). Remaining cost is roughly 175 ns fixed boundary, 450 ns JS encode plus native decode, 300 ns evaluation, and result conversion. Options measured but not adopted: `ReleaseFast` artifacts (18%). Structural options remain: compile-time read plans that skip unused activation fields, and a JavaScript code-generation backend for plain-data hot paths with the Zig engine as the semantic reference. Also reduce compound-value deduplication cost. Profile protobuf/callback-heavy complete requests and expand large-input, numeric-key, allocation, and memory benchmarks. Compare against native Python SDKs on real Linux hardware; emulated x86 execution is correctness evidence, not a performance result.
5. Execute current Linux x86-64 binding packages, add remote exact-glibc-floor runtime checks, and verify remote CI. Complete platform-aware npm distribution, older macOS support, and Windows/browser support; arm64 Linux success is not evidence for every platform.
