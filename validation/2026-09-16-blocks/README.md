# Alpha.17 indexed-block validation

## Public behavior and reference evidence

```sh
./scripts/test
./scripts/check
zig build test -Dbenchmarks=true -Doptimize=ReleaseFast -j4
bindings/python/.venv/bin/python -m pytest \
  -c bindings/python/pyproject.toml conformance/test_blocks.py
```

The SDK now accepts the pinned corpus's `cel.block`, `cel.index`, `cel.iterVar`, and `cel.accuVar` source aliases. They describe optimizer/conformance AST forms; they are not installed as ordinary source functions by CEL-Go's `ext.Bindings()` library. [Reference notes](../../conformance/reference/blocks-notes.md) document the mapping and reproducible public AST probes.

Each block owns request-local lazy slots. Initializers capture block-entry scope, not the local scope at a later use. Slots cache values and CEL errors once per evaluation. A temporary missing-value sentinel terminates cyclic lookup without recursion; the final initializer result replaces it. Nested blocks and reentrant evaluations use separate frames. Private iteration and accumulator names cannot resolve from activation properties, including through field-selection chains.

## Corrections driven by evidence

- Initial public tests failed because the aliases were absent.
- A provisional implementation rejected forward, cyclic, and out-of-range references during parsing. The reference probe showed forward references working and cycles resolving lazily. The eager validator was removed. Used cycles or missing slots now raise evaluation errors; unused slots remain unevaluated. Checked compilation still validates references.
- A provisional optional-slot rejection was also removed after a reference probe. The structural slot list does not compact optional entries or unwrap their values.

`red-forward-reference.txt` and `red-optional-slots.txt` retain those failures. Earlier red tests contain provisional expectations, not a claim that the initial dependency rules were correct. There is no normative block-extension document beyond the pinned test format; broader AST portability remains unproven. Forward slot types are conservatively inferred where the later initializer is not yet known.

## Gates

| Check | Result |
| --- | --- |
| Zig Debug, ReleaseSafe, ReleaseFast | 104 core tests plus one complete-workload test pass |
| Python | 111 tests; wrapper/test line and branch coverage 100% |
| Node | 86 tests; wrapper line/branch/function coverage 100% |
| Audit and benchmark CLI tests | 59 pass |
| All 37 pinned block cases | Every SDK passes full and evaluation modes |
| Full corpus | 2,197 passed, four failed, 307 unsupported |
| Evaluation-only corpus | 2,172 passed, four failed, 332 unsupported |
| Checked result types | 2,101 recorded |
| Linux arm64/glibc 2.28 | Core, installed bindings, and all six audits pass corresponding gates |
| Emulated Linux x86-64 | All 104 core tests pass |
| Formatting, lint, strict typing | Pass |

`parity.json` compares every SDK report field except the implementation label and verifies Linux/macOS agreement. The remaining four numeric failures and 307 unsupported extension cases stay visible. Shared-core parity is not independent semantic proof.

## Ownership, limits, and fuzzing

Public tests cover heterogeneous slot types, lazy successes/errors, forward/cyclic dependencies, nested frame shadowing, empty frames, private aliases, optional slots, callback failure identity, reentry, and Python callbacks releasing the GIL. Slot allocation and lookup consume collection/work limits. Evaluation depth remains bounded.

Zig allocation-failure injection exercises a checked block/list policy. The dependency-graph fuzzer completed 100,039 executions and compares evaluated graphs against a simple graph walk. The request-cache fuzzer completed 100,012, checked-source fuzzing 103,567, and source fuzzing 101,950. These runs and wrapper percentages do not establish native coverage, exact foreign allocation accounting, or a complete native memory ceiling.

A focused read-only review found no concrete issue. The originally delegated parser/checker implementation remained queued and was stopped before editing; implementation proceeded in the parent session. That queued task is not counted as completed work or review evidence.

## Packages and platforms

Python `0.1.0a17` wheels were built from source distributions on macOS and Linux. All 111 tests pass on macOS Python 3.10/3.12/3.13/3.14 and Linux Python 3.10.20 with glibc 2.28. Strict stable-ABI audits pass; the Linux wheel satisfies the manylinux 2.28 policy.

Node `0.1.0-alpha.17` installed archives pass all 86 tests on macOS Node 24, Linux Node 22/glibc 2.31, and Linux Node 24/glibc 2.28. Installed-wrapper coverage explicitly includes `**/cel/dist/index.js`. Packages remain unpublished and platform-specific. Linux setup uses the pinned images and offline dependency preparation in [the earlier Linux record](../2026-09-15-linux/).

## Complete-policy measurements

[Paired measurements](../../benchmarks/results/2026-09-16-blocks/) compare equivalent original and indexed dispatch policies with identical decisions and inputs. The 500-job change is about 2%, below the meaningful-effect threshold. No general speedup is claimed. `cel-js` still evaluates the original authorization workload about seven times faster.

String/network/encoder/protobuf-helper extensions, unknown/error values, broad independent compatibility work, native coverage/resource accounting, portable distributions, Windows/browser support, remote CI, and performance leadership remain open.
