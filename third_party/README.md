# Native runtime dependencies

```sh
zig build test
zig build test-compile -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
```

Zig builds the C++ regex and protobuf backends and links it statically into the SDK. You do not need CMake or a system installation of RE2, protobuf, or Abseil for normal builds. The first build downloads the archives pinned by `build.zig.zon`; later builds can reuse Zig's package cache.

| Dependency | Version | Commit | License |
| --- | --- | --- | --- |
| RE2 | 2025-11-05 | `927f5d53caf8111721e734cf24724686bb745f55` | BSD 3-Clause |
| Abseil | 20260817.0 | `2065f4ded0558c6f89fee67c8e5228feb4eb960e` | Apache 2.0 |
| Protobuf | 36.1 | `f377bfefc5e2cfab68b816903c25b23e091c439d` | BSD 3-Clause |
| utf8_range | Vendored by protobuf | Same protobuf archive | MIT |
| C++ runtime | Bundled with Zig 0.16.0 | Zig toolchain | Apache 2.0 with LLVM exceptions |

Python wheels and Node packages include these license notices. RE2, protobuf, and Abseil symbols use hidden visibility to avoid conflicts with other copies loaded into the host process. macOS artifacts link only OS-provided system libraries and CoreFoundation; RE2, protobuf, Abseil, and the C++ runtime are not separate runtime dependencies.

## Regenerate the source list

```sh
re2="$(mktemp -d)"
abseil="$(mktemp -d)"
protobuf="$(mktemp -d)"
git clone https://github.com/google/re2.git "$re2"
git -C "$re2" checkout 927f5d53caf8111721e734cf24724686bb745f55
git clone https://github.com/abseil/abseil-cpp.git "$abseil"
git -C "$abseil" checkout 2065f4ded0558c6f89fee67c8e5228feb4eb960e
git clone https://github.com/protocolbuffers/protobuf.git "$protobuf"
git -C "$protobuf" checkout f377bfefc5e2cfab68b816903c25b23e091c439d
uv run --project bindings/python python build/update-native-sources.py \
  --re2 "$re2" --abseil "$abseil" --protobuf "$protobuf" --output /tmp/native_sources.zon
diff -u build/native_sources.zon /tmp/native_sources.zon
```

Regeneration requires CMake 3.22 or newer and a C++17 compiler. The generator follows the RE2 and libprotobuf targets' dependency graphs and selects its translation units from CMake's compilation database. It does not compile or vendor the entire Abseil repository. The current list contains 22 RE2, 143 Abseil, and 87 protobuf/utf8_range translation units; linking removes unused sections.

## Calendar and timezone behavior

The temporal backend reuses the pinned protobuf/Abseil libraries for RFC3339 parsing, calendar conversion, and IANA timezone lookup. Named zones come from the host timezone database, not from a bundled version. UTC and fixed numeric offsets do not depend on local timezone configuration.

The binding rejects filesystem paths, repeated path separators, traversal components, and local-machine aliases. This also prevents equivalent path spellings from creating redundant entries in the timezone library's cache. Invalid names are not cached by the pinned Abseil implementation.

## Resource and verification limits

RE2's memory setting limits its program and DFA caches, not total process memory. Pattern length, instruction count, cache entry count, and evaluation work are bounded separately. Literal patterns are owned by the compiled CEL program. Dynamic patterns are cached only for one evaluation and then destroyed.

`std.testing.checkAllAllocationFailures` covers Zig cache allocations and cleanup after failure. It does not inject failures into the C++ allocator. Descriptor registries are reference-counted, and protobuf messages use evaluation-local native arenas that are released after results are serialized into Zig storage. The source and dynamic-pattern fuzz targets exercise RE2 through the public CEL API, but their coverage reports do not measure every RE2/Abseil branch. Those limits must not be presented as complete native coverage.

Linux test binaries have been cross-compiled and linked for x86-64 and arm64. That is build evidence, not evidence that the binaries have executed on Linux.
