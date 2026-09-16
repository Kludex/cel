# Linux Python ABI correction

```sh
PYTHONPATH=/tmp/before python benchmarks/python.py --engine candidate \
  --warmups 5 --samples 30 --cold-iterations 1000 --warm-iterations 5000 \
  --output /tmp/before.json
PYTHONPATH=/tmp/after python benchmarks/python.py --engine candidate \
  --warmups 5 --samples 30 --cold-iterations 1000 --warm-iterations 5000 \
  --output /tmp/after.json
```

Install the two wheels into separate directories before running these commands. `wheels.sha256` identifies them. Both were built with Python 3.14.7 headers and the glibc 2.28 target. The earlier snapshot still requires Python's newer `Py_TYPE` symbol. The correction removes that unintended ABI dependency, including calls through translated type-check macros.

## Results

Each run evaluates all 39 decisions across eight complete application workloads. Input conversion and result checking stay inside the timed requests. There are five warmups and 30 retained samples per metric. The order is before, after, after, before.

| Run | Cold, us/decision | Cold relative IQR | Warm, us/decision | Warm relative IQR |
| --- | ---: | ---: | ---: | ---: |
| Before 1 | 9.508 | 0.66% | 1.419 | 0.79% |
| After 1 | 9.524 | 0.71% | 1.398 | 1.26% |
| After 2 | 9.535 | 0.51% | 1.398 | 0.65% |
| Before 2 | 9.585 | 0.62% | 1.418 | 0.63% |

All runs meet the 5% relative-IQR stability criterion. Warm time falls by about 1.4%, below the required 10% effect threshold. Cold time is effectively unchanged. This is a compatibility correction, not a demonstrated performance improvement.

## Environment and limits

The runs use native arm64 execution in Docker Desktop's Linux VM, CPython 3.14.7, and image `python@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6`. Each container has two CPUs and a 1 GiB memory limit. No unrelated host processes were stopped. The container limit does not establish SDK memory accounting.

The runtime dependency installation and measurements have networking disabled. These are same-environment comparisons between two candidate artifacts, not comparisons against competitors or against macOS measurements. [The native Python competitor probe](../2026-09-15-linux-python-native/) retains its incomplete workload coverage; no emulated performance ranking is inferred.
