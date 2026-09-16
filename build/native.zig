//! Static RE2, protobuf, and their pinned Abseil dependency. Zig supplies the C++ toolchain.

const std = @import("std");
const sources = @import("native_sources.zon");

/// Build the regex backend without a dependency on system RE2 or Abseil libraries.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const re2 = b.dependency("re2", .{});
    const abseil = b.dependency("abseil", .{});
    const protobuf = b.dependency("protobuf", .{});
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        // The archive is also linked into Python and Node shared libraries.
        .pic = true,
    });
    module.addIncludePath(re2.path(""));
    module.addIncludePath(abseil.path(""));
    module.addIncludePath(protobuf.path("src"));
    module.addIncludePath(protobuf.path("third_party/utf8_range"));
    // Keep private RE2/Abseil symbols from interposing on libraries loaded by the host process.
    const flags = &.{ "-std=c++17", "-fvisibility=hidden", "-fexceptions" };
    module.addCSourceFiles(.{ .root = re2.path(""), .files = &sources.re2, .flags = flags });
    module.addCSourceFiles(.{ .root = abseil.path(""), .files = &sources.abseil, .flags = flags });
    inline for (sources.protobuf) |source| {
        module.addCSourceFile(.{
            .file = protobuf.path(source),
            .flags = if (std.mem.endsWith(u8, source, ".c")) &.{"-fvisibility=hidden"} else &.{ "-std=c++17", "-fvisibility=hidden", "-fexceptions", "-DGOOGLE_PROTOBUF_CMAKE_BUILD" },
        });
    }
    module.addCSourceFile(.{ .file = b.path("src/re2.cc"), .flags = flags });
    module.addCSourceFile(.{ .file = b.path("src/protobuf.cc"), .flags = flags });
    module.addCSourceFile(.{ .file = b.path("src/temporal.cc"), .flags = flags });
    module.addCSourceFile(.{ .file = b.path("src/format.cc"), .flags = flags });
    if (target.result.os.tag.isDarwin()) module.linkFramework("CoreFoundation", .{});
    return b.addLibrary(.{ .name = "cel_native", .linkage = .static, .root_module = module });
}
