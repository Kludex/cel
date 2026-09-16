//! Build the Zig SDK, statically linked RE2 backend, and optional language bindings.

const std = @import("std");
const native = @import("build/native.zig");

/// Configure the library and public API tests.
pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    if (target.result.isGnuLibC() and target.query.glibc_version == null) {
        var query = target.query;
        // Native host detection must not raise the distributed libraries' glibc requirement.
        query.glibc_version = .{ .major = 2, .minor = 28, .patch = 0 };
        target = b.resolveTargetQuery(query);
    }
    const optimize = b.standardOptimizeOption(.{});
    const cel = b.addModule("cel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const tests = b.addTest(.{
        .filters = if (filter) |text| &.{text} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            // Leave null so --fuzz instruments the runner only after test discovery.
            .fuzz = b.option(bool, "fuzz", "Override test fuzz instrumentation"),
            // Zig 0.16's fuzz runner passes builtin.StackTrace to the new debug.StackTrace API.
            .error_tracing = false,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the Zig public API tests");
    test_step.dependOn(&run_tests.step);
    b.step("test-compile", "Compile and link tests without executing them").dependOn(&tests.step);
    const install_tests = b.addInstallArtifact(tests, .{ .dest_sub_path = "cel-test" });
    b.step("test-install", "Install the test executable for execution on another host").dependOn(&install_tests.step);
    const regex_lib = native.add(b, target, optimize);
    cel.addIncludePath(b.path("src"));
    tests.root_module.addIncludePath(b.path("src"));
    tests.root_module.addImport("fixtures", b.createModule(.{
        .root_source_file = b.path("conformance/fixtures.zig"),
        .target = target,
        .optimize = optimize,
    }));
    cel.linkLibrary(regex_lib);
    tests.root_module.linkLibrary(regex_lib);

    if (b.option(bool, "conformance", "Build the direct Zig conformance transport") orelse false) {
        const adapter = b.addExecutable(.{
            .name = "cel-conformance",
            .root_module = b.createModule(.{
                .root_source_file = b.path("conformance/zig.zig"),
                // Zig 0.16's fuzz runner uses the obsolete error-trace type.
                .error_tracing = false,
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "cel", .module = cel },
                    .{ .name = "fixtures", .module = b.createModule(.{
                        .root_source_file = b.path("conformance/fixtures.zig"),
                        .target = target,
                        .optimize = optimize,
                    }) },
                },
            }),
        });
        const install = b.addInstallArtifact(adapter, .{});
        b.step("conformance", "Build and install the direct Zig conformance adapter").dependOn(&install.step);
        const audit_tests = b.addTest(.{
            .root_module = adapter.root_module,
            .filters = if (filter) |text| &.{text} else &.{},
        });
        b.step("conformance-test", "Exercise the public Zig audit transport").dependOn(&b.addRunArtifact(audit_tests).step);
    }

    if (b.option(bool, "examples", "Build the runnable SDK examples") orelse false) {
        for ([_][]const u8{ "authorization", "limits", "checked", "enums", "functions", "optionals", "network" }) |name| {
            const example = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "cel", .module = cel }},
            }) });
            b.step(b.fmt("example-{s}", .{name}), "Run a public SDK example").dependOn(&b.addRunArtifact(example).step);
        }
    }

    if (b.option(bool, "benchmarks", "Build the shared application workload benchmarks") orelse false) {
        const benchmark_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/zig.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cel", .module = cel }},
        });
        const benchmark_options = b.addOptions();
        benchmark_options.addOption(bool, "functions", b.option(bool, "benchmark-functions", "Use a callback-backed authorization policy") orelse false);
        const cold_iterations = b.option(usize, "benchmark-cold-iterations", "Complete workload iterations per cold sample") orelse 10_000;
        const warm_iterations = b.option(usize, "benchmark-warm-iterations", "Complete workload iterations per warm sample") orelse 50_000;
        if (cold_iterations == 0 or warm_iterations == 0) @panic("benchmark iterations must be positive");
        benchmark_options.addOption(usize, "cold_iterations", cold_iterations);
        benchmark_options.addOption(usize, "warm_iterations", warm_iterations);
        benchmark_module.addOptions("options", benchmark_options);
        const benchmark_tests = b.addTest(.{ .root_module = benchmark_module });
        test_step.dependOn(&b.addRunArtifact(benchmark_tests).step);
        const benchmark = b.addExecutable(.{ .name = "cel-benchmark", .root_module = benchmark_module });
        b.step("benchmark", "Measure complete compile/evaluate request decisions").dependOn(&b.addRunArtifact(benchmark).step);
    }

    if (b.option([]const u8, "python-include", "Directory containing Python.h")) |include| {
        const python = b.addLibrary(.{
            .name = "_native",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/python.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        python.root_module.addIncludePath(b.path("src"));
        python.root_module.linkLibrary(regex_lib);
        python.root_module.addIncludePath(.{ .cwd_relative = include });
        // CPython resolves its C API symbols when loading the extension.
        python.linker_allow_shlib_undefined = true;
        const install = b.addInstallArtifact(python, .{ .dest_sub_path = "_native.so" });
        b.step("python", "Build the CPython extension").dependOn(&install.step);
    }

    if (b.option([]const u8, "node-include", "Directory containing node_api.h")) |include| {
        const node = b.addLibrary(.{
            .name = "cel_node",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/node.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        node.root_module.addIncludePath(b.path("src"));
        node.root_module.linkLibrary(regex_lib);
        node.root_module.addIncludePath(.{ .cwd_relative = include });
        // Node resolves the stable Node-API symbols when loading the addon.
        node.linker_allow_shlib_undefined = true;
        const install = b.addInstallArtifact(node, .{ .dest_sub_path = "cel.node" });
        b.step("node", "Build the Node-API extension").dependOn(&install.step);
    }
}
