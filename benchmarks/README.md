# End-to-end benchmarks

```sh
./scripts/build-python
bindings/python/.venv/bin/python benchmarks/python.py \
  --engine candidate --cold-iterations 600 --warm-iterations 10000 \
  --output /tmp/python-candidate.json

uv run --no-project --python 3.14 --with cel-python==0.5.0 \
  python benchmarks/python.py --engine cel-python \
  --cold-iterations 8 --warm-iterations 50 --output /tmp/python-cel-python.json

npm ci --prefix bindings/typescript
npm run build --prefix bindings/typescript
npm ci --prefix benchmarks --ignore-scripts --no-audit --no-fund
node benchmarks/typescript.mjs --engine candidate \
  --cold-iterations 1500 --warm-iterations 10000 --output /tmp/node-candidate.json
node benchmarks/typescript.mjs --engine cel-js \
  --cold-iterations 1000 --warm-iterations 10000 --output /tmp/node-cel-js.json
node benchmarks/typescript.mjs --engine bufbuild \
  --cold-iterations 100 --warm-iterations 2000 --output /tmp/node-bufbuild.json

zig build test -Dbenchmarks=true
zig build benchmark -Dbenchmarks=true -Doptimize=ReleaseSafe \
  -Dbenchmark-cold-iterations=1000 -Dbenchmark-warm-iterations=10000 > /tmp/zig.json
```

Run these commands from the repository root. Use the same Python version for both Python engines. Build the SDK in `ReleaseSafe`, which keeps runtime safety checks enabled.

## Application workloads

`workloads.json` contains 64 request decisions across twelve workloads:

| Workload | Complete decision |
| --- | --- |
| Authorization | Method, route, authenticated user, role, and ownership |
| Data validation | Name, tags, email domain, region, and metadata |
| Cart validation | Every item's price, quantity, stock availability, and coupon validity |
| Routing | Admin, canary, or default destination |
| Customer format validation | Customer ID, email, and every tag validated with regular expressions |
| Temporal authorization | Grant validity, local business hours, weekends, and a nanosecond deadline |
| Optional authorization | Missing/null principals, optional roles, lazy defaults, and deleted resources |
| Quota and permissions | Permission bits, rounded CPU demand, quota boundaries, and absolute adjustments |
| Batch dispatch | Flatten batches, reject duplicate job IDs, select ready priority jobs, and check available nodes |
| Text ingestion | Normalize names and labels, reject invalid slugs/revisions, and verify formatted canonical keys |
| Attachment ingestion | Validate media type, decode content, enforce byte quota, and check canonical transport representation |
| Network gateway authorization | Check identity, tenant, method, path, address classification, and a CIDR allowlist |

Each engine evaluates the same expressions and inputs. The harness verifies every expected result before timing and consumes every timed result by checking the decision. A wrong decision stops the benchmark. The suite includes both accepted and rejected requests, short-circuiting, nested maps, lists, and collection macros.

## Metrics

| Metric | Timed work |
| --- | --- |
| `cold_compile_and_evaluate` | Create a program and evaluate one request |
| `warm_evaluate_reused_program` | Evaluate a request with a previously compiled program |

Python and Node measurements include native binding conversion and result conversion. Zig measurements start with native typed inputs, as a Zig application would. The Zig caller resets a retained evaluation arena after every request.

All runners perform five warmups and record 30 samples. Python and Node accept `--warmups`, `--samples`, `--cold-iterations`, and `--warm-iterations`. Zig accepts `-Dbenchmark-cold-iterations` and `-Dbenchmark-warm-iterations` while retaining five warmups and 30 samples. Raw sample times, medians, quartiles, and runtime details are written to JSON. The Zig report records raw samples, medians, relative interquartile range, compiler version, optimization mode, architecture, and OS.

Process startup, module imports, fixture JSON parsing, baseline environment setup, and report serialization are outside the measured region. These are in-memory policy decisions, not network or filesystem benchmarks. No claim about memory consumption is established by these timing results.

## Baselines

| Runtime | Pinned baseline | Compile and evaluate API |
| --- | --- | --- |
| Python | `cel-python==0.5.0` | `Environment.compile()`, `Environment.program()`, `Runner.evaluate()` |
| Node | `@bufbuild/cel@0.6.1` | `parse()`, `plan()`, planned function |
| Node | `@marcbachmann/cel-js@8.0.0` | `parse()`, returned evaluation function |

`cel-python` requires `json_to_cel()` for native dictionaries. That conversion stays inside the measured request. The JavaScript baselines accept native objects directly. Optional baseline dependencies are isolated from SDK dependencies and pinned in the commands or `package-lock.json`.

A Rust-backed competitor with native arm64 wheels is available as `--engine cel-rust`:

```sh
uv venv --python 3.14 /tmp/cel-rs-venv
uv pip install --python /tmp/cel-rs-venv/bin/python common-expression-language==0.10.0
/tmp/cel-rs-venv/bin/python benchmarks/python.py --engine cel-rust --workload request_authorization --output /tmp/cel-rust.json
```

It imports as `cel`, so keep it in a separate interpreter. [Same-host results](results/2026-09-16-python-native/) cover the five workloads it can compile; this SDK's Python binding is 7-43x faster warm on each. The other seven workloads fail in its compiler and are recorded as failures.

An older adapter also exists for the Rust-backed `python-cel` package:

```sh
uv run --no-project --python 3.14 --with python-cel==0.1.1 \
  python benchmarks/python.py --engine python-cel --output /tmp/python-cel-rust.json
```

`python-cel==0.1.1` provides only a Linux x86-64 wheel on PyPI, without a source distribution. An [emulated Linux correctness probe](results/2026-09-15-linux-python-native/) passes 22 decisions across five complete workloads. Temporal selectors, optional syntax, and math functions prevent the other 17 decisions from passing. The benchmark adapter now uses its documented `Program.execute(Context)` API. Neither emulated execution nor the pure-Python baseline establishes performance leadership over native Python SDKs.

## Plain-data fast path checkpoint

[Plain-data measurements](results/2026-09-16-plain-fast-path/) compare the default engine path with `evaluate(bindings, { plainData: true })` on the same build. Authorization drops from about 955 ns to 137 ns per warm decision (7x) and routing from 627 ns to 93 ns (6.8x); both are 2.2-2.5x faster than `cel-js`, the first workloads where the Node binding leads that competitor. Two of twelve workloads are inside the compiled subset, so the 64-decision mix moves 8%. `--engine candidate-plain` runs the full harness in this mode.

## Numeric comparison checkpoint

[Numeric measurements](results/2026-09-16-numeric/) isolate the replacement of exact `f128` mixed-numeric ordering with the clamp-then-double algorithm shared by CEL-Go and CEL-C++. Because every numeric equality passed through the `f128` path, the change is 1.13-1.15x on both the 64-decision mix and authorization in paired runs. Cumulative since the evaluator-path checkpoint is 1.24x on the mix. `cel-js` remains about 3.2x faster on warm authorization.

## Evaluator-path checkpoint

[Evaluator-path measurements](results/2026-09-16-eval-paths/) add exact-precondition fast paths for string-key map lookup, bare identifier resolution, and string predicates, plus borrowed Python string inputs and trimmed Node encoder fixed costs. Paired Node runs improve authorization 1.10-1.12x and the mix 1.08-1.10x; alternating Python runs improve authorization about 5%. A `ReleaseFast` addon build measured 18% faster but shipped artifacts stay `ReleaseSafe`. `cel-js` remains about 3.7x faster on warm authorization.

## Plain-data transport checkpoint

[Plain-data measurements](results/2026-09-16-node-plain/) compare the same source tree before and after two changes: the Node wrapper flattens plain request data into typed buffers so native conversion needs one boundary crossing, and the shared evaluator skips the qualified-name activation scan when no binding, constant, container, or descriptor can supply a dotted name. Three paired runs reduce complete warm authorization time from about 2.16 us to 1.20 us (1.79-1.80x), and two paired runs reduce the 64-decision mix from about 2.60 us to 1.70 us (1.52-1.54x), all with relative IQR at or below 1.3%.

`cel-js` still evaluates the original authorization workload in about 0.30 us warm, roughly four times faster than this SDK's 1.21 us. Cold compile-and-evaluate times are now within 4%. Performance leadership on that workload is not established. A read-only review found that deferred `Map` values were snapshotted after later getters and that the collection budget was enforced only after the JavaScript traversal; both are fixed and pinned by public tests.

## Network-extension checkpoint

[Network measurements](results/2026-09-16-network/) add seven gateway decisions. A separate complete gateway policy normalizes and deduplicates 600 configured prefixes before containment. Scalar IP/CIDR hashing reduces its elapsed time by about 83% in three stable pairs. The ordinary 64-decision mix has no meaningful change from that hashing adjustment.

The expanded aggregate is not a controlled comparison with alpha.19. Both pinned JavaScript competitors fail the network policy on missing operations, while `cel-js` remains about seven times faster on original authorization. The first native Zig cold measurement exceeded the variance threshold and remains recorded separately from the stable retry.

## Protobuf-helper and encoder checkpoint

[Alpha.19 measurements](results/2026-09-16-proto-encoders/) add six complete attachment-ingestion decisions. The 57-decision mix is not directly comparable to earlier aggregates. Base64 is transport encoding, not authentication, and this workload makes no cryptographic claim.

Pinned JavaScript baselines fail the new policy on unsupported operations; their errors remain recorded. `cel-js` has a separate bytes-encoding method, but not the namespace decoder required by this policy. It remains about 6.9 times faster on the original authorization workload.

## String-extension checkpoint

[Alpha.18 measurements](results/2026-09-16-strings/) add six complete text-ingestion decisions. The 51-decision mix includes native input/output conversion in Python and Node; its changed composition cannot establish a speedup over earlier aggregates. Both pinned JavaScript baselines fail the new text policy on missing operations, and those failures are retained.

The original authorization workload still favors `cel-js` by about 6.9 times. String-extension conformance and bounded formatting are progress toward the SDK goal, not a performance-leadership result.

## Indexed-block checkpoint

[Alpha.17 measurements](results/2026-09-16-blocks/) compare complete dispatch policies with repeated expressions versus lazy indexed slots. The 500-job elapsed reduction is about 2%, below the meaningful-effect threshold. Unchanged policies also show no meaningful change.

The aliases expose an optimizer/conformance format, not ordinary CEL-Go source functions. The original authorization workload still favors `cel-js` by roughly seven times; no performance-leadership claim follows from these results.

## Local-binding checkpoint

[Alpha.16 measurements](results/2026-09-16-bindings/) compare a complete dispatch policy that repeats flattening with an equivalent `cel.bind` policy that reuses the result. The 500-job reduction is about 1.9-2.3%, below the meaningful-effect threshold. The unchanged 45-decision workload mix shows no meaningful regression from the added scoping and memoization machinery.

The paired driver rejects different case names, inputs, or expected results and records both source expressions. The original authorization workload still favors `cel-js` by about 7.1 times. This is a language-support checkpoint, not a performance-leadership claim.

## List-extension checkpoint

[Alpha.15 measurements](results/2026-09-16-lists/) add six complete batch-dispatch decisions. A separate 500-job version of the same policy exercises larger collection conversion, ID deduplication, sorting, selection, and node availability. Hash-bucket deduplication reduces its Node elapsed time by about 53% in three paired comparisons, without a meaningful change in the ordinary 45-decision mix.

Compound-value deduplication can still require quadratic work. The SDK retains semantic equality and work limits rather than substituting serialized-byte identity. Both pinned JavaScript competitors fail the batch policy on missing `flatten` support; their errors remain recorded. The original authorization workload still favors `cel-js` by about 6.8 times.

## Node request-conversion checkpoint

[Alpha.14 measurements](results/2026-09-16-node-requests/) show repeated 13-15% elapsed reductions for complete authorization requests and 10.7-11.5% for the 39-decision mix. Public tests retain key ordering, getter effects, symbol rejection, and prototype safety. A more complex fused transport was discarded, and an unstable clean-build comparison remains recorded.

The candidate still takes about 2.101 us for warm authorization versus 0.306 us for `cel-js`. This is progress on a measured bottleneck, not performance leadership. The cold full-suite difference remains below the meaningful-effect threshold.

## Math-extension checkpoint

[Math iteration results](results/2026-09-15-math/) use 39 complete decisions. Warm medians are 1.25 us for Python, 2.56 us for Node, and 0.64 us for native Zig values. The changed mix is not directly comparable to earlier aggregates. The original authorization policy still favors `cel-js` by about eight times.

The new quota policy cannot run in the pinned JavaScript baselines because required math overloads are missing. The existing protobuf-`Struct` round-trip mode also fails that policy because `Struct` turns integer permission masks into doubles. These failures are retained; none is replaced with a partial-suite timing or a weaker overload.

## Optional-policy checkpoint

[Optional iteration results](results/2026-09-15-optionals/) use the new 33-decision mix. Python and Node warm medians are about 1.23 us and 2.43 us. The added optional policy changes the mixture, so these aggregates are not directly comparable with the earlier 27-decision reports.

The JavaScript baseline now enables its documented `enableOptionalTypes` option. It still cannot compile the policy because its `optional.ofNonZeroValue` overload is missing. `bufbuild` and `cel-python` also fail to parse the optional policy. Their errors are retained rather than weakening the expression or reporting partial-suite timings as complete.

On the original authorization workload alone, `cel-js` remains faster: about 0.30 us versus 2.44 us for the Node candidate. The candidate is not the fastest SDK across workloads. The pure-Python baseline's separate temporal run still fails the nanosecond deadline case.

## Custom-function policies

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate-functions \
  --cold-iterations 400 --warm-iterations 5000 --output /tmp/python-callbacks.json
node benchmarks/typescript.mjs --engine candidate-functions \
  --cold-iterations 400 --warm-iterations 5000 --output /tmp/node-callbacks.json
zig build benchmark -Dbenchmarks=true -Dbenchmark-functions=true -Doptimize=ReleaseSafe \
  > /tmp/zig-callbacks.json
```

This mode delegates the authorization policy's role/ownership check to a typed host callback while preserving every expected request decision. Its historical report below used the earlier 27-decision mix. Callback argument/result conversion remains inside evaluation. Cold measurements include checking; environment setup is outside timing. [Raw results](results/2026-09-15-functions/) measure about 1.28 us warm for Python, 2.45 us for Node, and 0.65 us for native Zig values.

The default and callback modes differ in checking and policy implementation, so these results do not isolate callback overhead or establish a speedup. Blocking callbacks and independent custom-function competitors still need separate evidence.

## Alpha.9 typed-map checkpoint

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate-maps \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/python-maps.json
node benchmarks/typescript.mjs --engine candidate-maps \
  --cold-iterations 500 --warm-iterations 5000 --output /tmp/node-maps.json
```

This path constructs typed maps inside each timed request, then evaluates the same complete policies. The existing fixture keys are strings; this measures representation overhead, not numeric-key throughput. [Raw results](results/2026-09-15-maps/) record 4.60 us warm for Python and 3.34 us for Node, versus 1.25 us and 2.43 us for ordinary dictionaries/objects.

A paired ordinary-object comparison measured a 6.5% Node slowdown after map recognition was added. It is below the meaningful-effect threshold, but is not omitted or described as a speedup. The favorable full-suite aggregate does not erase the faster JavaScript competitor on authorization and customer-format validation.

## Alpha.8 conversion checkpoint

[Current absolute measurements](results/2026-09-15-conversion/) use the same 27 decisions and include binding conversion. Warm medians are 1.21 us for Python and 2.26 us for Node. [Paired Node experiments](profiling/results/2026-09-15-strings/) isolate short-string reads and per-call stack storage. Customer-format validation improves by about 10-15% across three comparisons; the full-mix reduction is about 9%, below the existing meaningful-effect threshold.

Authorization still favors `cel-js`, roughly 0.31 us versus 2.04 us. The same competitor remains faster on customer-format validation. The raw records retain the rejected UTF-16 experiment, near-threshold effects, and baseline correctness failures. No overall leadership or memory-consumption claim is made.

## Alpha.7 checkpoint

[Strong-enum iteration results](results/2026-09-15-strong-enums/) rerun the unchanged 27-decision suite through the default SDK mode. Stable warm medians are 1.33 us for Python, 2.51 us for Node, 9.39 us for `cel-js`, and 17.40 us for `bufbuild`. This is a regression checkpoint, not an enum-specific throughput measurement or a controlled speedup claim.

The original authorization workload still favors `cel-js`: 0.30 us versus 2.28 us for the Node candidate. The pure-Python baseline still fails the nanosecond deadline case. Keep these limitations alongside the aggregate.

## Temporal workload measurements

```sh
node benchmarks/typescript.mjs --engine candidate --workload request_authorization \
  --cold-iterations 20000 --warm-iterations 50000 --output /tmp/authorization.json
node benchmarks/typescript.mjs --engine candidate --workload temporal_authorization \
  --cold-iterations 5000 --warm-iterations 10000 --output /tmp/temporal.json
```

`--workload` selects one complete named policy workload. It does not select an isolated operator. Python supports the same option.

[Temporal iteration results](results/2026-09-15-temporal/) use the new 27-case mix. Stable aggregate warm medians were 1.27 us for the Python candidate, 2.42 us for the Node candidate, 8.53 us for `@marcbachmann/cel-js`, and 16.46 us for `@bufbuild/cel`.

The aggregate hides important differences. On the original authorization policy alone, the Node candidate's stable warm median was 2.25 us versus 0.30 us for `@marcbachmann/cel-js`. The candidate is not the fastest implementation across workloads. Temporal parsing and named-zone operations change the workload mix substantially; do not compare this aggregate directly with historical 17- or 22-case results.

The `cel-python==0.5.0` baseline fails the new nanosecond deadline decision: it accepts a request whose elapsed duration exceeds 30 seconds by one nanosecond. Its run stops before timing. `python-cel-python-failure.txt` records that failure; the case was not weakened to obtain a benchmark number. Per-workload runs remain available for cases that baseline can evaluate correctly.

## Protobuf request round trips

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate-protobuf \
  --cold-iterations 300 --warm-iterations 500 --output /tmp/python-protobuf.json
node benchmarks/typescript.mjs --engine candidate-protobuf \
  --cold-iterations 300 --warm-iterations 500 --output /tmp/node-protobuf.json
```

These commands now attempt all 57 decisions. The new quota policy fails on this transport because protobuf `Struct` cannot preserve its integer permission masks; use `--workload` for an individually supported complete workload. The historical protobuf reports below used the earlier 22-decision suite. Each timed request encodes every input object as a protobuf `Struct`, wraps its wire bytes in the SDK `Message` value, and evaluates the complete policy. Python uses the standard protobuf JSON encoder; Node uses `@bufbuild/protobuf`. Encoding is inside the timed region, not hidden in fixture setup.

[Raw results](results/2026-09-15-protobuf/) record the round-trip cost separately from native-object evaluation. The final round-trip medians were 31.69 us cold / 15.70 us warm for Python and 31.31 us cold / 13.80 us warm for Node. Both 30-sample runs had relative interquartile range below 5%. The SDK is not claimed to outperform other protobuf/CEL implementations from these measurements.

Message metadata was moved behind an arena-owned pointer to avoid widening every scalar `Value`. Follow-up native-object timing attempts were noisy and did not establish a speedup. Those attempts remain in the results directory; do not use them as a performance claim or compare them directly with a different input transport.

## Checked environment measurements

```sh
bindings/python/.venv/bin/python benchmarks/python.py --engine candidate-checked \
  --cold-iterations 600 --warm-iterations 10000 --output /tmp/python-checked.json
node benchmarks/typescript.mjs --engine candidate-checked \
  --cold-iterations 1500 --warm-iterations 10000 --output /tmp/node-checked.json
```

`candidate-checked` registers the workload's input names as dynamic variables in a reusable environment. Its cold metric includes parsing, checking, and program construction. Environment creation is outside timing, as it is for baseline environments. Its warm metric uses the checked program but still includes binding conversion and a complete request decision.

[Raw checked/unchecked results](results/2026-09-15-checked/) use the same 22 requests, runtime versions, and `ReleaseSafe` mode. All four runs have 30 samples and relative interquartile range below 5%.

| SDK path | Compile + evaluate, us/decision | Reused program, us/decision |
| --- | ---: | ---: |
| Python unchecked | 11.91 | 0.95 |
| Python checked | 13.63 | 0.89 |
| Node unchecked | 14.56 | 2.06 |
| Node checked | 16.72 | 2.03 |

Checking adds cold-path work. The observed warm differences are below the benchmark's 10% meaningful-effect threshold, so these measurements do not establish a warm speedup. They are a correctness/performance checkpoint, not evidence that the SDK is the fastest available implementation.

## RE2 workload measurements

[Current raw results](results/2026-09-15-re2/) include the new regex workload, with Zig 0.16.0 `ReleaseSafe`, CPython 3.14.6, and Node 24.14.1 on the same macOS arm64 host. Each final run has 30 samples and relative interquartile range below 5%.

| Runtime and engine | Compile + evaluate, us/decision | Reused program, us/decision |
| --- | ---: | ---: |
| Python candidate | 11.53 | 0.90 |
| Python `cel-python` | 771.92 | 407.60 |
| Node candidate | 14.37 | 2.03 |
| Node `@marcbachmann/cel-js` | 5.68 | 0.69 |
| Node `@bufbuild/cel` | 85.98 | 7.73 |

The Node candidate remains about three times slower than `@marcbachmann/cel-js` for warm requests. Literal RE2 compilation is included in the cold path, and adds a visible cost. The warm path reuses those patterns. These measurements do not establish overall performance leadership.

The separate Zig report measured 11.01 us for compile/evaluate and 0.32 us for reused programs with native inputs. Do not compare those directly with binding conversion costs. Files ending in `attempt1.json` retain the earlier unstable runs rather than discarding them. The new 22-case results are not directly comparable to the historical 17-case aggregate below.

## Initial measurements

[Raw results](results/2026-09-15-macos-arm64/) come from an Apple Silicon macOS host, Zig 0.16.0 `ReleaseSafe`, CPython 3.14.6, and Node 24.14.1. Each row includes 30 samples. These are aggregate medians across the 17 decisions, not universal performance claims.

| Runtime and engine | Compile + evaluate, us/decision | Reused program, us/decision |
| --- | ---: | ---: |
| Python candidate | 2.26 | 0.90 |
| Python `cel-python` | 768.28 | 418.62 |
| Node candidate | 5.32 | 3.11 |
| Node `@marcbachmann/cel-js` | 5.76 | 0.64 |
| Node `@bufbuild/cel` | 77.13 | 3.22 |

The TypeScript binding is about 4.9 times slower than `@marcbachmann/cel-js` for reused programs on these workloads. This is a measured gap to address, not a result to omit. Its warm difference from `@bufbuild/cel` is below the meaningful-effect threshold below.

The Zig-only result is recorded separately. Do not compare its native input path directly with Python or Node conversion costs. `source.sha256` records the SDK and harness source snapshot used by the initial experiment.

## Variance

Use a quiet machine on external power. Keep runtime versions, input fixtures, CPU configuration, and build mode unchanged. Increase iterations until samples last at least 100 ms.

A run is stable when its relative interquartile range is at most 5%. Treat a median difference as meaningful only when it exceeds both 10% and twice the larger relative interquartile range. Do not discard outliers. Report unstable runs as inconclusive.

An experiment that specialized same-type numeric comparisons changed the complete Python request median by less than 3%. It was reverted rather than presented as a meaningful optimization. A later [controlled converter experiment](profiling/README.md) measured a 1.57x speedup, or about 36% less elapsed evaluation time, using interleaved complete-request samples. Competitive baseline results must be refreshed before making a broader speed claim.
