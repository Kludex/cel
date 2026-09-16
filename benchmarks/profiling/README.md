# Profile complete TypeScript requests

```sh
npm run build --prefix bindings/typescript
mkdir -p /tmp/cel-profile
node --cpu-prof --cpu-prof-dir=/tmp/cel-profile --cpu-prof-name=candidate.cpuprofile \
  benchmarks/profiling/typescript-full-workloads.mjs --workload request_authorization --iterations 1500000 \
  > /tmp/cel-profile/run.json &
pid=$!
sleep 1
sample "$pid" 5 1 -file /tmp/cel-profile/candidate.sample.txt
wait "$pid"
```

Run this from the repository root on macOS. `sample` is the macOS native sampling tool. The Node profile works on other supported platforms without the `sample` command. The workload driver reuses compiled programs and verifies every complete request decision.

## Observations

A native sample collected before the converter change contained 189 main-thread samples. Counting only the outermost matching frame in each stack gave:

| Observed frame | Inclusive samples |
| --- | ---: |
| Native evaluation callback | 184 |
| Converter methods | 135 |
| Zig evaluator methods | 22 |

These are sampled stack counts, not precise phase timings. Inlining hides some conversion work inside the callback, and recursive frames must not be counted twice. The Node CPU profile alone cannot reliably separate converter and evaluator work.

The stacks identified repeated `napi_instanceof`, global `Object.prototype` lookups, property enumeration, and property reads during conversion. The implementation now captures the object prototype and recognizes arrays, byte arrays, and plain maps before checking wrapper classes. A public-API regression test also verifies that replacing the global `Object` does not break normal bindings.

## Initial timing attempts

`results/` retains the full-workload before/after timing attempts. The before warm median was 3.33 us with 1.8% relative interquartile range. Subsequent after medians ranged from 2.48 to 4.71 us, with relative interquartile ranges of 15.5% to 21.8%.

The host had substantial unrelated CPU load during those runs. Those results fail the stability threshold and do not establish an improvement. No unrelated processes were stopped.

## Plain-data transport profile

A fresh `sample` of the warm authorization loop before this change attributed most self time to per-value Node-API calls: string reads, `napi_typeof`, property lookups, and the `Object.keys` callback, with the Zig evaluator itself below 20%. A constant `true` program evaluated against the same bindings cost about 1.75 us, so conversion dominated the 2.17 us request. Pure Zig evaluation of the same policy measured about 455 ns, of which the qualified-name activation scan (`names.matches`, `resolve`) was roughly 40%.

The wrapper now encodes plain data into a `Float64Array` tag stream and a UTF-8 `Uint8Array` before one native call; native strings borrow that buffer for the call. A first version used `TextEncoder.encodeInto` with a `subarray` per string and reset `ancestors.length`, which the next sample showed as `Builtins_CreateTypedArray`, `TypedArrayPrototypeSubArray`, and `ArrayLengthSetter`. Replacing those with an ASCII fast path and an explicit depth counter brought conversion of the authorization bindings from about 1.70 us to 0.87 us. The evaluator change removed the activation scan for undotted names (455 ns to 375 ns in the native probe). [Paired results](../results/2026-09-16-node-plain/) record the complete-request effect.

## Current conversion comparison

```sh
CONVERTER_PATCH=benchmarks/results/2026-09-16-node-requests/restore-before.patch \
  benchmarks/profiling/compare-converters \
  --workload request_authorization --iterations 15000 > /tmp/paired-converters.json
```

You supply a baseline restoration patch explicitly so an old experiment cannot silently compare the wrong implementations. The script copies the engine and wrapper into two temporary builds, applies the patch only to the before build, and removes both copies afterward. Set `NODE_INCLUDE` if your headers are not next to Node.

The driver compiles programs before timing, checks every decision, performs five warmups, and collects 30 paired samples in alternating order. Omit `--workload` to run the current 39-decision suite. [Current results](../results/2026-09-16-node-requests/) show repeated 13-15% authorization reductions and 10.7-11.5% reductions across the full mix, using captured addons. The first clean-build run was unstable and is recorded separately; the second reproduces a 14.7% authorization reduction. The current restoration patch changes both native code and the copied JavaScript wrapper to preserve their internal argument contract.

The [earlier string-conversion results](results/2026-09-15-strings/) used a 27-decision mix and showed about 9% aggregate reduction, below the meaningful-effect threshold. `cel-js` remains faster on authorization.

## Historical intrinsic-capture comparison

The earlier comparison restored repeated prototype lookups and wrapper checks with `uncached-converter.patch`. That patch is an archived artifact tied to its original source snapshot, not a patch for the current binding. Both historical builds used Zig `ReleaseSafe`, baseline CPU settings, the same wrapper and interpreter, and 17 request decisions. Each sample contained 85,000 complete evaluations.

| Run | Before, us/decision | After, us/decision | Before relative IQR | After relative IQR | Median paired speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Initial paired run | 3.41 | 2.18 | 1.0% | 1.3% | 1.56x |
| Reproduction | 3.45 | 2.19 | 4.4% | 2.8% | 1.57x |

Both paired runs satisfy the stability and meaningful-effect thresholds. The converter change reduces elapsed request-evaluation time by about 36% on this workload mix. This is not a claim of performance leadership against other SDKs or on other workloads.

`results/paired-intrinsics.json` and `results/paired-reproduction.json` retain raw samples. `results/source.sha256` records the source and patch used by the experiment.
