# Complete Node request conversion

```sh
CONVERTER_PATCH=benchmarks/results/2026-09-16-node-requests/restore-before.patch \
  benchmarks/profiling/compare-converters \
  --workload request_authorization --iterations 15000 > /tmp/node-request-pair.json
```

Run this from the repository root with the documented Node and Zig toolchains. The restoration patch includes both the native converter and its compiled JavaScript wrapper, because the internal callback argument list changed. Omit `--workload` and use `--iterations 5000` to measure all 39 decisions across eight workloads.

## Changes

The native profile identified property enumeration and conversion as substantial costs in complete authorization decisions. Ordinary records no longer pass through an optional-wrapper `instanceof` check. Property enumeration uses captured `Object.keys`, `Object.getOwnPropertySymbols`, and `propertyIsEnumerable` functions instead of the generic Node-API property enumeration path.

Keys remain ordered and snapshotted before value conversion. Enumerable symbols still fail after preceding string-keyed getters run. Captured intrinsics and null-prototype key arrays preserve behavior under prototype mutation. Public tests also correct Map brands being hidden by `OptionalValue.prototype`, and proxy prototype traps executing before rejection.

## Repeated paired measurements

Each comparison alternates before/after order, performs five warmups, and retains 30 samples. Every request includes binding conversion, evaluation, and result verification. These are complete policies, not isolated property-operation timings.

| Workload/run | Before, us | After, us | Elapsed reduction | Relative IQR, before/after |
| --- | ---: | ---: | ---: | ---: |
| Authorization 1 | 2.483 | 2.112 | 14.9% | 0.9% / 0.8% |
| Authorization 2 | 2.462 | 2.119 | 13.9% | 1.4% / 1.8% |
| Authorization 3 | 2.430 | 2.111 | 13.1% | 1.2% / 0.8% |
| Authorization, clean rebuild | 2.464 | 2.101 | 14.7% | 0.8% / 0.5% |
| All 39 decisions, 1 | 2.567 | 2.285 | 11.0% | 1.0% / 1.1% |
| All 39 decisions, 2 | 2.548 | 2.254 | 11.5% | 0.8% / 0.7% |
| All 39 decisions, 3 | 2.534 | 2.262 | 10.7% | 0.8% / 0.8% |
| Cart validation | 3.467 | 3.067 | 11.5% | 0.9% / 0.8% |
| Customer-format validation | 1.524 | 1.340 | 12.0% | 0.9% / 0.5% |
| Optional authorization | 1.616 | 1.400 | 13.4% | 1.2% / 0.9% |

These comparisons meet the 5% relative-IQR criterion and exceed both the 10% elapsed-change threshold and twice the larger relative IQR. The first three authorization and full-suite comparisons used captured before/after addons. The first clean-build reproduction in `rebuilt-paired-auth.json` has about 24% relative IQR and is not stable evidence. It is retained rather than averaged into the stable runs. The second clean-build comparison uses 30,000 workload iterations per sample and reproduces a 14.7% reduction with sub-1% relative IQR. No unrelated host processes were stopped.

## Competitor and cold measurements

Fresh standalone runs still favor `@marcbachmann/cel-js@8.0.0` on authorization: about 0.306 us warm versus 2.101 us for the candidate, roughly 6.9 times faster. Cold authorization is about 3.284 us for `cel-js` versus 4.284 us for the candidate. The candidate remains slower; these conversion changes do not establish performance leadership.

The candidate's full-suite standalone medians are 11.200 us cold and 2.287 us warm. The baseline records are 11.954 us cold and 2.580 us warm. The cold change is below the meaningful-effect threshold. Earlier records retain competitors' failures on unsupported optional/math policies; no incomplete competitor run is reported as a full-suite timing.

## Experiments not promoted as wins

Moving map classification ahead of optional wrappers alone reduced authorization time by about 8%, below the meaningful-effect threshold. Its correctness changes remain included.

A fused classification/key-snapshot transport saved only about 0.7% over the simpler corrected converter on authorization. Its additional shape-discrimination code was removed. `fused-vs-keys.json` and `fused-experiment.patch` retain the experiment. An attempted `shopping_cart_validation` selection used a nonexistent workload name and produced no measurement; the correct name is `cart_validation`.

## Scope

Measurements use macOS arm64, Node 24.14.1, Zig 0.16.0, ReleaseSafe, and baseline CPU settings. Native and JavaScript profiles and public tests are recorded in [validation](../../../validation/2026-09-16-node-requests/). Results do not establish the same effect on every input shape, large-input memory behavior, other platforms, or callback-heavy applications. Linux runtime checks establish correctness, not these macOS timings.
