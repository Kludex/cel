# Direct Zig conformance validation

```sh
zig build conformance conformance-test -Dconformance=true -Doptimize=ReleaseSafe
bindings/python/.venv/bin/python -m pytest -c bindings/python/pyproject.toml conformance/test_*.py
bindings/python/.venv/bin/python conformance/run.py --engine zig --mode full \
  --report /tmp/zig-full.json
```

The full audit deliberately exits with status 1 because failures and unsupported cases remain. `parity.json` records comparison of every report field across Python, Node, and Zig, excluding only the implementation label.

| Mode | Passed | Failed | Unsupported | Successfully checked |
| --- | ---: | ---: | ---: | ---: |
| Full, each SDK | 1,820 | 4 | 684 | 1,724 |
| Evaluation-only, each SDK | 1,806 | 4 | 698 | 0 |

The four failures remain the documented mixed-numeric comparisons. The pinned corpus, admission policy, and expected results were not narrowed or altered to obtain parity. Full conformance is not claimed.

## Direct execution

`conformance/zig.zig` imports the public `cel` module and pinned test descriptors. `zig_codec.zig` imports only the standard library and public `cel` module. Checking and evaluation call `Environment.compile()`, `Environment.parse()`, and `Program.evaluate()` directly, with no Python or Node engine invocation.

The shared Python controller still handles case selection, protobuf JSON-to-wire transport, comparison, and reporting. This is direct Zig SDK execution, not a claim that all audit orchestration is written in Zig. The standalone executable can process typed JSON without either language binding installed.

## Test evidence

- Four shared CLI test families now run against all three engines.
- Direct adapter tests cover scalar type distinctions, signed/unsigned endpoints, NaN/infinities, bytes, strings, messages, timestamps, durations, static type descriptions, malformed shapes, and error-phase separation.
- Encoders copy non-static strings before programs are destroyed. Repeated request batches serialize independent outcomes.
- Malformed typed values are input errors, not unsupported-feature claims. Input values cannot hide syntax errors, and check-only cases do not decode activations.
- Transport limits cover batch bytes, request count, JSON depth/tokens, and per-activation value/byte/depth budgets. Boundary tests caught an exclusive reader limit; reserving one EOF probe byte now accepts exactly 32 MiB and rejects larger input.

All 35 CLI checks pass with Debug, ReleaseSafe, and ReleaseFast adapters. The public transport fuzz test completed 198,873 executions without a trap or leak. Its edge counts do not measure complete native coverage. A delegated review timed out without a final report; it is not counted as a completed review.

The SDK gate also passes its existing 59 Zig tests, 51 Python tests, and 44 Node tests, plus the new Zig transport test. Python and Node wrapper coverage gates remain 100%. A wheel built from the sdist confirms the optional audit target does not become a product build dependency.

## Portability and performance

The adapter cross-links for Linux arm64 and x86-64. Docker remains unavailable, so execution of those artifacts is not verified. Remote CI has been configured for the Zig engine and transport fuzzer but has not run.

[Application-workload results](../../benchmarks/results/2026-09-15-zig-audit/) rerun all 27 decisions through the existing SDK entry points. The audit's JSON transport is not included in those product benchmarks. No SDK runtime optimization or performance-leadership claim is made by this tooling change.

Custom functions, unknown/error values, remaining type families/extensions, broader differential testing, native coverage and allocation-failure injection, distribution portability, and performance leadership remain open.
