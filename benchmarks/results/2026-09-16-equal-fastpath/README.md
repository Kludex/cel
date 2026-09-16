# Rejected experiment: scalar fast path in `Context.equal`

Hypothesis: skipping message adaptation and depth accounting for same-tag string/bool/int pairs would reduce evaluator time on authorization.

Paired runs (before = same tree without the change, after = with it), macOS arm64 Node 24.14.1:

| Workload | Runs | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: |
| Authorization | 3 | 962-978 ns (1.6-3.5%) | 957-963 ns (2.2-2.8%) | 1.00-1.02x |
| 64-decision mix | 2 | 1,382-1,389 ns (1.4-1.5%) | 1,386-1,388 ns (1.3-1.4%) | 1.00x |

Below the meaningful-effect threshold. The change was reverted; the general path is already cheap once the `f128` conversion is gone. Retained so the same idea is not retried without a new reason.
