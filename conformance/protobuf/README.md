# Protobuf descriptor fixtures

These binary files are protobuf `FileDescriptorSet` values generated with `--include_imports`.

| Descriptor | Input | Files | SHA-256 |
| --- | --- | ---: | --- |
| `cel-spec-test-descriptors.pb` | Three pinned `cel-spec` schemas below | 10 | `9c2736ccb5eb85ec8c7e16435d44571844776aa2a6a0586d6577cbff0fd5269b` |
| `test-schema-descriptor.pb` | `test_schema.proto` | 1 | `a65ec6deecfd7a2d9a9531bf3e4754287f108acec4d84ec9386bbff600728b34` |

The first descriptor includes seven imported `google/protobuf/*.proto` descriptors. The second schema is an original,
small SDK fixture for scalar, nested, repeated, map, proto3 optional, oneof, and enum handling.

## Upstream source

The upstream source is [`google/cel-spec`](https://github.com/google/cel-spec) at commit
`ba58ae5007845f3a1279b488cdeb79645ce958bb` (`v0.25.3`).

| Path below upstream `proto/` | SHA-256 |
| --- | --- |
| `cel/expr/conformance/proto2/test_all_types.proto` | `15998bccdaceea908b8d575a2d834977fe39bdbb54f5920c52a1feed9dece0c5` |
| `cel/expr/conformance/proto2/test_all_types_extensions.proto` | `bf45f05c3a78cab7fb110c3f33975b5547b518b2f2270176e090ae7abbf48b23` |
| `cel/expr/conformance/proto3/test_all_types.proto` | `b25323999ef1c92d56e8285e8b8475663c0ffd2cbd0f7c93a55607d59508e65a` |

## Regeneration

```sh
git clone https://github.com/google/cel-spec.git /tmp/cel-spec-reference
git -C /tmp/cel-spec-reference checkout ba58ae5007845f3a1279b488cdeb79645ce958bb
./conformance/protobuf/regenerate.sh /tmp/cel-spec-reference
shasum -a 256 conformance/protobuf/*.pb
```

The script uses an isolated `uv` environment. It pins `grpcio-tools==1.76.0`, `grpcio==1.76.0`,
`protobuf==6.33.0`, and `setuptools==80.9.0`. The generated fixtures used CPython 3.12.7, `uv` 0.12.1, and
`libprotoc 31.1`. It does not modify an SDK bindings environment.

## License

The `cel-spec` schemas and derived descriptor data are Copyright Google LLC and licensed under Apache License 2.0.
See `LICENSE.cel-spec` for the upstream license. `test_schema.proto` is original to this project and uses the project
license.
