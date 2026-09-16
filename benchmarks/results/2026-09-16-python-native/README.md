# Native Python competitor: `common-expression-language` (Rust)

`common-expression-language==0.10.0` is a PyO3 binding over the Rust `cel` crate (v0.14.5) and publishes native wheels for macOS arm64 and Linux aarch64, so it can run on this host without emulation. It is a stronger comparison than the earlier `python-cel==0.1.1` probe, whose only artifact was an x86-64 wheel and whose source repository is no longer public.

```sh
uv venv --python 3.14 /tmp/cel-rs-venv
uv pip install --python /tmp/cel-rs-venv/bin/python common-expression-language==0.10.0
/tmp/cel-rs-venv/bin/python benchmarks/python.py --engine cel-rust --workload request_authorization \
  --cold-iterations 1000 --warm-iterations 8000 --output /tmp/cel-rust.json
```

Both engines import as `cel`, so the competitor lives in its own interpreter. Both runs use CPython 3.14.6 on the same macOS arm64 host; the harness verifies every decision before timing, and each engine was run twice per workload in alternating order.

## Supported workloads

`cel-rust-workload-support.txt` records a one-iteration probe of all twelve workloads. Five compile and produce every expected decision. The other seven fail at compile time: no `getHours`/temporal selectors, no `math` or `lists` namespaces, no `strings.*`/`format`, no `base64`, no network functions, and the optional-syntax policy is rejected by its parser. Those failures are retained, not replaced with partial-suite timings.

## Results (median ns per complete decision, relative IQR in parentheses)

| Workload | This SDK cold | `cel-rust` cold | This SDK warm | `cel-rust` warm | Warm ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| Authorization | 1,741 / 1,732 (1.5-1.9%) | 42,877 / 43,513 (0.8%) | 781 / 789 (1.3-1.5%) | 7,729 / 7,752 (1.0-1.4%) | 9.8x |
| Data validation | 2,390 / 2,373 (0.5-0.9%) | 66,158 / 67,441 (0.6-0.7%) | 905 / 919 (1.0-1.2%) | 8,194 / 8,177 (0.5-0.8%) | 9.0x |
| Cart validation | 3,061 / 3,007 (1.4-1.8%) | 90,082 / 90,492 (0.5%) | 1,301 / 1,295 (1.5-1.6%) | 11,626 / 11,705 (0.9%) | 9.0x |
| Routing | 1,660 / 1,659 (1.1-1.8%) | 41,092 / 40,816 (0.5-0.8%) | 597 / 595 (1.3-1.7%) | 4,304 / 4,216 (0.5-0.9%) | 7.1x |
| Customer format (RE2) | 43,126 / 43,192 (0.5-1.0%) | 67,894 / 68,083 (0.4-0.5%) | 812 / 807 (1.4-1.5%) | 35,019 / 34,967 (0.6-0.7%) | 43x |

Every run satisfies the 5% relative-IQR threshold. The customer-format cold figure for this SDK is dominated by compiling three RE2 patterns per program; the Rust engine compiles regexes lazily at first evaluation, which is why its warm time is high rather than its cold time.

## What this does and does not show

On the five complete workloads the competitor supports, this SDK's Python binding is 7-43x faster warm and 1.6-30x faster cold on the same host and interpreter. The comparison covers a narrower policy language than this SDK implements; the competitor cannot run the other seven workloads at all. This is evidence toward, not proof of, performance leadership for Python: other native bindings may exist, and `@marcbachmann/cel-js` still leads this SDK's Node binding by about 3.2x on warm authorization.
