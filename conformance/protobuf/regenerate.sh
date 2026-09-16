#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=${1:-/tmp/cel-spec-reference}
commit=ba58ae5007845f3a1279b488cdeb79645ce958bb

if [ "$(git -C "$source" rev-parse HEAD)" != "$commit" ]; then
  echo "cel-spec source must be at $commit" >&2
  exit 1
fi
if ! git -C "$source" diff --quiet "$commit" -- \
  proto/cel/expr/conformance/proto2/test_all_types.proto \
  proto/cel/expr/conformance/proto2/test_all_types_extensions.proto \
  proto/cel/expr/conformance/proto3/test_all_types.proto; then
  echo "cel-spec inputs differ from $commit" >&2
  exit 1
fi

uv run --isolated --no-project \
  --with grpcio-tools==1.76.0 \
  --with grpcio==1.76.0 \
  --with protobuf==6.33.0 \
  --with setuptools==80.9.0 \
  python - "$source" "$root" <<'PY'
from pathlib import Path
import sys

import grpc_tools
from grpc_tools import protoc

source = Path(sys.argv[1])
root = Path(sys.argv[2])
include = Path(grpc_tools.__file__).parent / "_proto"
inputs = [
    "cel/expr/conformance/proto2/test_all_types.proto",
    "cel/expr/conformance/proto2/test_all_types_extensions.proto",
    "cel/expr/conformance/proto3/test_all_types.proto",
]

commands = [
    [
        "protoc",
        f"-I{source / 'proto'}",
        f"-I{include}",
        "--include_imports",
        f"--descriptor_set_out={root / 'cel-spec-test-descriptors.pb'}",
        *inputs,
    ],
    [
        "protoc",
        f"-I{root}",
        "--include_imports",
        f"--descriptor_set_out={root / 'test-schema-descriptor.pb'}",
        "test_schema.proto",
    ],
]

for command in commands:
    if protoc.main(command) != 0:
        raise SystemExit(1)
PY
