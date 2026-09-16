# Alpha.16 local-binding validation

## Behavior and regression evidence

```sh
./scripts/test
./scripts/check
zig build test -Dbenchmarks=true -Doptimize=ReleaseFast -j4
bindings/python/.venv/bin/python -m pytest \
  -c bindings/python/pyproject.toml conformance/test_bindings.py
```

`cel.bind` stores an initializer, its outer lexical scope, and a per-binding cached evaluation result. The cell lives on the evaluation stack, not in the compiled AST. It initializes on first use, caches CEL errors as well as values, and disappears when the body returns. Every request, reentrant evaluation, and enclosing comprehension iteration gets independent state.

The public red tests record missing macro support and the initial overly strict rejection of absolute binding names. Independent CEL-Go probes establish lazy initialization, error memoization, repeated-evaluation isolation, nested shadowing, and exact namespace handling. The checker validates unused initializers. Absolute references bypass local bindings. `.cel.bind` can resolve a custom function but does not expand the macro.

Python and Node tests also cover null/false/empty values, host exception identity, result ownership after GC, and reentrant initialization. A two-thread Python test releases the GIL inside the initializer and verifies separate caches in the same program. Input conversion remains eager; this feature does not defer host property getters.

## Gates

| Check | Result |
| --- | --- |
| Zig Debug, ReleaseSafe, ReleaseFast | 99 core tests plus one complete-workload test pass |
| Python | 103 tests; wrapper/test line and branch coverage 100% |
| Node | 83 tests; wrapper line/branch/function coverage 100% |
| Audit and benchmark CLI tests | 56 tests pass |
| Eight pinned binding cases | Every SDK passes in full and evaluation modes |
| Full corpus | 2,160 passed, four failed, 344 unsupported |
| Evaluation-only corpus | 2,135 passed, four failed, 369 unsupported |
| Checked result types | 2,064 recorded |
| Linux arm64, glibc 2.28 | Core, installed Python/Node packages, and all six audits pass their corresponding gates |
| Emulated Linux x86-64 | All 99 core tests pass |
| Formatting, lint, strict typing | Pass |

`parity.json` verifies agreement between SDKs and between Linux and macOS. Shared-core parity does not prove independent correctness. The four numeric disagreements and all remaining unsupported files remain visible, including the indexed block extension.

## Resource and fuzz checks

Lazy initialization skips unused engine work but cannot suppress collection or cost failures when used. Local-name traversal and comparison work consume the evaluation budget. Existing scope and evaluation-depth limits still apply.

The ownership test injects every Zig allocation failure through a checked nested-binding/list policy. The binding activation fuzzer completed 100,020 executions; checked-source fuzzing completed 105,366; source fuzzing completed 102,388. These are runtime/fuzz checks, not native coverage or foreign allocator accounting.

A focused read-only review found no concrete lifetime or scoping issue. An earlier broader review timed out and is not counted as completed evidence. Reference callback failures in `bindings.txt` are CEL `types.NewErr` values; Python and JavaScript host exceptions follow this SDK's existing fatal-error contract instead.

## Packages and platforms

Python `0.1.0a16` wheels were built from source distributions on macOS and Linux. All 103 tests pass on macOS Python 3.10/3.12/3.13/3.14 and Linux Python 3.10.20 with glibc 2.28. Both wheels pass strict `abi3audit`; the Linux wheel passes the manylinux 2.28 policy.

Node `0.1.0-alpha.16` installed archives pass all 83 tests and explicit wrapper coverage on macOS Node 24, Linux Node 22/glibc 2.31, and Linux Node 24/glibc 2.28. Packages remain unpublished and platform-specific. Linux uses the pinned images and offline setup recorded in [the earlier Linux validation](../2026-09-15-linux/). No native x86 binding-performance claim follows from emulated core tests.

## Application benchmarks

[The paired measurements](../../benchmarks/results/2026-09-16-bindings/) compare complete dispatch policies with identical named cases, inputs, and expected results. Only the expression changes to reuse flattened jobs. The helper records both expressions and rejects mismatched decision sets through tested CLI guards.

The 500-job changes are about 1.9-2.3%; neither those nor the ordinary 45-decision changes meet the 10% meaningful-effect threshold. No speedup is claimed. The pinned `cel-js` baseline still evaluates authorization about 7.1 times faster than the candidate.

Remaining libraries, unknown/error values, broader independent compatibility work, native coverage, memory accounting, platform-aware distributions, Windows/browser support, remote CI, and comparative performance leadership remain unfinished.
