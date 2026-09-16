# Conversion checkpoint

## Reproduce the controlled comparison

```sh
CONVERTER_PATCH=benchmarks/profiling/results/2026-09-15-strings/restore-before.patch \
  benchmarks/profiling/compare-converters \
  --workload customer_format_validation --iterations 25000 > /tmp/cel-customer-paired.json
```

Run from the repository root with Zig 0.16.0 and Node headers installed. The script builds two copies of the same current SDK. The inverse patch restores the exact pre-change `src/node.zig`, verified against `before.sha256`. Both copies use the same wrapper and core. The driver alternates sample order, performs five warmups, and checks every complete request decision in all 30 paired samples.

Omit `--workload` to run all 27 decisions. `--workload` selects a complete policy, not an isolated operation. Timing excludes compilation in this paired experiment. The general benchmark still measures cold and warm paths separately.

## Results

| Comparison | Before, us/decision | After, us/decision | Elapsed reduction |
| --- | ---: | ---: | ---: |
| Full mix | 2.46 | 2.23 | 9.4% |
| Full mix, repetition | 2.46 | 2.23 | 9.1% |
| Customer format validation | 1.51 | 1.30 | 13.5% |
| Customer format validation, repetition | 1.54 | 1.31 | 15.1% |
| Customer format validation, two fresh builds | 1.47 | 1.32 | 10.3% |

All these runs meet the 5% relative-IQR criterion. The full mix does not exceed the existing 10% meaningful elapsed-effect threshold. Customer format validation does exceed it in three runs, including the independent rebuild. This is a workload-specific improvement, not overall performance leadership.

The per-workload files retain authorization, validation, cart, routing, regex, and temporal results. Several changes are near the threshold and should not be described as established improvements. Authorization measurements span roughly 8.6-10.2% reductions across attempts. Its candidate median remains about 2.04 us versus a separately measured 0.31 us for `cel-js`, roughly a 6.6x gap. Customer format validation also remains slower than `cel-js`: about 1.31 us versus 0.55 us.

Python's stack-buffer experiment measured 1.33 us before versus 1.22 us after for the full mix. Its authorization and customer-format reductions were also below 10%. Those Python runs were sequential, not paired; no meaningful or causal Python speedup is claimed.

## What changed

The Node profile points to input conversion, string length/copy operations, property enumeration, and property reads. `before.sample.txt` and `after.sample.txt` retain native samples; the corresponding `.cpuprofile` files retain Node profiles. Sampled stacks are not precise phase timings.

Short strings now cross Node-API with one bounded UTF-8 read. Potentially truncated strings use length-checked storage. UTF-16 validation distinguishes legitimate `U+FFFD` characters from Node's silent replacement of lone surrogates. Source, values, names, and environment metadata share this reader. Eager validation still covers unused CEL inputs.

Both bindings use `std.heap.stackFallback(4096, ...)` with an arena fallback during evaluation. This is per-call storage, not a program cache. Native Node-API operations validate the private wrapper constructor metadata when needed instead of checking it again on every call. Program handle validation and CEL activation limits remain in place.

## Rejected experiment

`paired-utf16*.json` records an earlier implementation that read UTF-16 and transcoded every string with the Zig standard library. It correctly rejected lone surrogates but increased authorization time from 2.31 us to 2.55 us. It was replaced, not presented as a speedup.

The `paired-short-utf8*.json` and `paired-stack-only.json` files isolate intermediate attempts. Their roughly 3-5% effects did not exceed the meaningful-effect threshold. No samples or slow alternatives were removed.

## Correctness and limits

Public tests cover UTF-8 byte boundaries, surrogate-pair boundaries, real replacement characters, embedded NUL, malformed source and unused input, deterministic Unicode differential inputs, large heap-fallback requests, reentrant getters, garbage collection, and independent results after errors. `red-tests.txt` records the original Unicode failures.

No custom allocator, object-shape cache, lazy validation, JSON serialization, or CEL operator shortcut was introduced. The 4 KiB buffer does not eliminate Python, V8, RE2, or protobuf allocations and is not a total memory-use guarantee. Full conformance, native coverage, native allocation-failure injection, and performance leadership remain open.
