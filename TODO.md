# TODO

Open work toward the original objective: the most performant CEL SDK, shared Zig engine, native Python and TypeScript bindings, TDD through public APIs, complete-application benchmarks. Everything below is unfinished; `PLAN.md` holds the per-iteration history and evidence links.

## Performance

- [x] Opt-in `evaluate(bindings, { plainData: true })` compiles the bool/string/int-literal, unquoted-select, comparison, logical, and string-predicate subset to a JavaScript function with fallback to the engine. Authorization: 955 -> 137 ns warm (7x), 2.2x faster than `cel-js`; routing 627 -> 93 ns (6.8x), 2.5x faster than `cel-js`. Review found and fixed a lone-surrogate divergence; two direct-read differences (repeated getter reads, non-enumerable properties) are documented rather than papered over.
- [ ] The default path is still about 3.2x behind `cel-js` on authorization (0.96 us versus 0.30 us); its cost is spread across the native boundary (~175 ns), JavaScript encoding (~350 ns), native decode (~100 ns), and evaluation (~300 ns).
- [x] Widened the plain-data subset with ordering, arithmetic, `size()`, dynamic indexing, `in` against a list literal, and single-variable `all`/`exists`; four of twelve workloads compile (authorization, routing, data validation, cart), each 5-7x faster than the default path and 2.2-4.4x faster than `cel-js`. The mix is 1.22x.
- [x] `matches` against a literal pattern calls the program's precompiled RE2 through `Program.matchesLiteral`; the regex workload compiles (1.5x on Node, 568 ns, within 5% of `cel-js`'s JavaScript `RegExp`; Python 1.07x, below threshold). Five of twelve workloads compile.
- [ ] The remaining seven workloads need temporal, optional, math, list, string, encoder, or network functions. The `matchesLiteral` pattern (one native call per extension operation) is the template; each call costs about 100 ns on Node, so only operations that replace substantially more engine work than that are worth adding.
- [x] Python counterpart `evaluate(bindings, plain_data=True)`: 1.5-1.6x on authorization, routing, and data validation; cart validation is interpreter-bound (1.07x). An unguarded Python expression for the authorization policy is about 170 ns.
- [ ] Decide whether shipped artifacts should ever use `ReleaseFast`: measured about 18% faster on complete requests, currently rejected to keep bounds and overflow checks for untrusted expressions.
- [ ] Reduce compound-value `distinct()` cost, which still falls back to a shared bucket with semantic equality.
- [ ] Add allocation and memory reporting to the complete-workload benchmarks; only elapsed time is measured today.
- [ ] Profile protobuf- and callback-heavy complete requests; they have not been profiled since custom functions landed.
- [ ] Python leads `common-expression-language` (Rust) by 7-43x on the five workloads it can run, and Node trails `cel-js` on authorization. Keep looking for native competitors with arm64 artifacts; `python-cel`'s source is no longer public.

## Semantics and conformance

- [ ] Unknown values and unknown/error propagation (`unknown` matchers, `error` expression values) are not implemented; the audit reports them as explicit gaps.
- [ ] Three network-extension corpus cases intentionally fail: two hexadecimal IPv4-mapped forms the corpus accepts but CEL-Go rejects, and `isIP(cidr(...))` which fails checking rather than evaluation. Revisit if upstream changes.
- [ ] CEL-Go validates malformed literal constructor arguments (`ip('bad')`) at check time; this SDK does so at evaluation time.
- [ ] Macro disabling and locale selection are not exposed through the public `Program` API.
- [ ] Remaining checker type families and grammar outside the pinned corpus have no independent tests. The generated numeric differential (`conformance/reference/numeric.go`) is a model for other operator families.
- [ ] String extension follows the pinned document where it differs from newer CEL-Go (`-1`/clamping search results, one replacement per invalid-byte run).
- [ ] List sorting keeps equal-key order and rejects multi-element NaN sorting, unlike CEL-Go's unstable ties; documented, not reconciled.

## Native coverage and resources

- [ ] Native line coverage is 95.77% merged (93.17% Zig tests alone) on aarch64 Debug via kcov. Remaining `protobuf.cc` (82.5%) and `temporal.cc` (83%) lines are `bad_alloc` handlers, status arms for limits, and malformed Any/Struct/timestamp payload paths. Needs adversarial wire fixtures and a failing C++ allocator.
- [ ] Branch coverage is unmeasured. Coverage on other targets and in optimized builds is unmeasured.
- [ ] Protobuf equality work is a cached encoded-size estimate, not exact CPU or memory metering.
- [ ] Structured activation fuzzing across the Python and Node FFI boundaries, concurrency ceilings, and malformed host Unicode paths remain thin.
- [ ] Engine budgets do not meter blocking host callbacks.

## Distribution and platforms

- [x] x86-64 Linux packages now build and run on GitHub-hosted x86-64 runners: the `sdk (ubuntu-latest, 3.10)` job builds `cp310-abi3-manylinux_2_28_x86_64`, passes strict `abi3audit`, and runs all 134 Python tests from the installed wheel plus the Node suite. The x86-64 npm archive is built there too. Not yet: an exact glibc 2.28 runtime check on x86-64 (the hosted runner is newer).
- [ ] Windows and browser (WASM) are unsupported.
- [ ] macOS wheels are tagged `macosx_26_0_arm64`; older macOS and Intel are untested.
- [ ] npm distribution is a single platform-specific archive with a checked-in `cel.node`; platform-aware packaging is missing.
- [ ] Packages are unpublished; versions are `0.1.0a21` / `0.1.0-alpha.21`.
- [x] Remote CI is green (11 jobs: 4 SDK matrix cells on macOS/Ubuntu x Python 3.10/3.14, 6 audits compared to committed baselines, arm64 fuzzing). Remote CI ran for the first time on the initial push; the first run exposed a Python 3.10 header incompatibility (`Py_IS_TYPE` macro), audit jobs that treated the three retained network disagreements as failures, and Zig 0.16.0 fuzz mode failing to rebuild any test on x86_64 Linux (reproduced with a one-test project under emulation). The first two are fixed and verified by the second run; fuzzing moved to the arm64 hosted runner. Fuzzing on x86_64 waits on an upstream Zig fix. Still missing from CI: the exact-glibc-2.28 runtime job and the Docker Linux artifact matrix that only runs locally. The exact-glibc-floor runtime job and the Linux artifact matrix that has only run locally in Docker are still missing from CI.
- [ ] Host must supply complete tzdata including legacy aliases; no tzdata is bundled.

## Housekeeping

- [ ] `validation/` and `benchmarks/results/` hold raw evidence (about 11 MB); decide whether they stay in the repository or move to releases.
- [ ] Reference probes assume `/tmp/cel-go-reference` and `/tmp/cel-spec-reference` checkouts at pinned commits; script the checkout.
- [ ] The vendored native sources under `zig-pkg/` are fetched by Zig on first build; document the offline cache requirement (hash-named `.tar.gz` archives, not expanded directories).
