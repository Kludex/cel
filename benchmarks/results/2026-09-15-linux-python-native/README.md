# `python-cel==0.1.1` complete-workload probe

## Conclusion

Performance is inconclusive because `python-cel==0.1.1` cannot evaluate the complete 39-decision suite. No timing or performance-leadership claim is valid. The corrected public API probe confirms 22 decisions and records all remaining failures.

## Method

The correctness metric was exact agreement with `benchmarks/workloads.json`: 39 decisions across eight complete workloads. The subject was the only PyPI artifact for `python-cel==0.1.1`; expected fixture results were the reference. Evaluation used emulated Linux amd64, CPython 3.14.7, and image `python@sha256:810da6270e43d30a1f3e0e1eabbeb6fbd9d78ad9dd2e754d5297a3d6cb42df46`.

Dependencies were fetched separately with network access:

```sh
docker run --rm --platform linux/amd64 --network bridge -v /tmp/python-cel-native/download:/download \
  python@sha256:810da6270e43d30a1f3e0e1eabbeb6fbd9d78ad9dd2e754d5297a3d6cb42df46 \
  python -m pip download --no-deps --only-binary=:all: --dest /download python-cel==0.1.1
```

Public evaluation disabled networking:

```sh
docker run --rm --platform linux/amd64 --network none -v /tmp/python-cel-native/download:/wheels:ro \
  -v "$PWD":/repo:ro -v "$PWD/benchmarks/results/2026-09-15-linux-python-native":/results \
  python@sha256:810da6270e43d30a1f3e0e1eabbeb6fbd9d78ad9dd2e754d5297a3d6cb42df46 sh -ceu '
python -m pip install --no-index --no-deps /wheels/python_cel-0.1.1-cp39-abi3-manylinux_2_34_x86_64.whl
python /results/probe.py /repo/benchmarks/workloads.json /results/correctness.json'
```

`provenance.json` records image, wheel, input hashes, PyPI availability, and API evidence. `harness-*.log` records the unmodified benchmark adapter checks.

## Results

- 5 workloads passed completely: 22/39 decisions.
- Temporal authorization: 5 evaluation errors, `Undeclared reference to 'getDayOfWeek'`.
- Optional authorization: compile error at `?`; its 6 cases could not run.
- Quota and permissions: 6 evaluation errors, `Undeclared reference to 'bitAnd'`.
- Mismatched results: 0.

The wheel is the release's sole PyPI file: `cp39-abi3-manylinux_2_34_x86_64`, SHA-256 `f7ffaa78a0e6482b83a8d8545453b600d32cdffb3005284be11aa82c97c15dcc`; no sdist is published. No timing samples, variance, effect size, allocator profile, or CPU profile were collected after the correctness gate failed.

## Cause

The package lacks syntax or functions required by three complete workloads. Separately, `benchmarks/python.py` calls nonexistent `Program.evaluate`; wheel metadata, its stub, and runtime expose `Program.execute(Context)`. The full unmodified harness first stops at the optional parse error, while the authorization-only harness exposes the adapter error.

## Next step

The adapter has been corrected to `Program.execute(Context)`. A [public CLI smoke run](../../../validation/2026-09-15-linux/native-competitor-adapter-smoke.json) now passes the complete authorization workload. Its single-sample emulated timing is not performance evidence. Benchmark supported workloads on native hardware with explicit partial-coverage labels; a complete-suite comparison requires a competitor release that passes all eight workloads.
