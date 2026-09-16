# Alpha.8 conversion validation

```sh
./scripts/test
./scripts/check
npm exec --yes --package=node@22.14.0 -- \
  node --expose-gc --test bindings/typescript/dist/test/*.test.js
```

Run from the repository root. The macOS checks pass with 55 Zig tests, 46 Python tests, 29 Node tests, and six conformance CLI self-tests. Python wrapper line/branch coverage and Node wrapper line/branch/function coverage remain 100%. These figures exclude native-code coverage.

## Public behavior checks

- Valid Unicode, embedded NUL, replacement characters, and supplementary characters survive source and value conversion.
- Unpaired JavaScript UTF-16 surrogates raise `TypeError`, including in unused bindings and environment metadata.
- UTF-8 byte budgets remain exact for one-, two-, three-, and four-byte characters.
- Deterministic UTF-16 inputs agree with lossless Node encoding round trips.
- Nested evaluations, garbage collection, errors, and large requests do not overwrite outer or previously returned results.
- Eager validation of unsupported values, symbols, cycles, and excessive depth remains intact.

A read-only review reported no actionable safety, semantics, or ownership findings in the changed bindings and tests. Node-API validates private wrapper constructor metadata at its use sites; native program-handle validation remains unconditional.

## Packages and runtimes

The alpha.8 Python wheel was built from its source distribution and passed all 46 public tests on CPython 3.10, 3.12, 3.13, and 3.14. The same Node-API addon passed all 29 tests on Node 22.14.0 and 24.14.1. The npm archive was installed separately and exercised with valid Unicode, malformed Unicode, and independently owned large results. Neither package was published.

Both updated bindings cross-link for Linux arm64. The Docker daemon became unavailable before execution, so this iteration does not claim Linux runtime validation. `linux-bindings.txt` and `docker-retry.txt` record the failed attempts. Alpha.7's earlier Linux evidence remains historical evidence, not a substitute for running these changed bindings.

## Conformance and performance

Full audits remain at 1,820 passed, four failed mixed-numeric cases, and 684 unsupported. Evaluation-only audits remain at 1,806 passed, four failed, and 698 unsupported. The conformance scope was not narrowed to obtain these results.

[Paired application measurements](../../benchmarks/profiling/results/2026-09-15-strings/) retain the rejected UTF-16 experiment, intermediate changes, per-workload results, repeated comparisons, and a two-build reproducer. The customer-format workload improves by about 10-15%; the full-mix effect remains below the 10% meaningful elapsed-effect threshold. The candidate is still slower than `cel-js` on authorization and customer-format validation.

Native coverage, foreign allocation-failure injection, Linux execution of alpha.8, remaining language features, portable distribution artifacts, and performance leadership remain open.
