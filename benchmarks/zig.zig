//! End-to-end CEL policy benchmarks. Fixtures own input values; timed evaluations reuse an arena per request.

const std = @import("std");
const builtin = @import("builtin");
const cel = @import("cel");

const Case = struct { bindings: []const cel.Binding, expected: cel.Value };
const Workload = struct { source: []const u8, program: cel.Program, environment: cel.Environment, cases: []const Case };
const Metric = struct {
    phase: []const u8,
    iterations_per_sample: usize,
    decisions_per_sample: usize,
    total_ns: [30]u64,
    median_ns_per_decision: f64,
    relative_iqr: f64,
};

/// Run the same authorization, validation, and routing requests used by both bindings.
pub fn main(init: std.process.Init) !void {
    var storage = std.heap.ArenaAllocator.init(init.gpa);
    defer storage.deinit();
    const callback_mode = @import("options").functions;
    const workloads = try prepare(storage.allocator(), callback_mode);
    defer for (workloads) |*workload| workload.program.deinit();
    var evaluation = std.heap.ArenaAllocator.init(init.gpa);
    defer evaluation.deinit();
    var decisions: usize = 0;
    for (workloads) |workload| {
        for (workload.cases) |case| {
            const actual = try workload.program.evaluate(evaluation.allocator(), case.bindings);
            if (!actual.eql(case.expected)) return error.IncorrectDecision;
            _ = evaluation.reset(.retain_capacity);
            decisions += 1;
        }
    }
    var metrics: [2]Metric = undefined;
    for ([_]bool{ true, false }, &metrics) |cold, *metric| {
        const iterations: usize = if (cold) @import("options").cold_iterations else @import("options").warm_iterations;
        var totals: [30]u64 = undefined;
        for (0..35) |sample| {
            const start = std.Io.Clock.awake.now(init.io);
            for (0..iterations) |_| {
                for (workloads) |workload| {
                    for (workload.cases) |case| {
                        var fresh: ?cel.Program = if (!cold) null else if (callback_mode)
                            try workload.environment.compile(init.gpa, workload.source, .{})
                        else
                            try cel.Program.compile(init.gpa, workload.source, .{});
                        defer if (fresh) |*program| program.deinit();
                        const program = if (fresh) |*program| program else &workload.program;
                        const actual = try program.evaluate(evaluation.allocator(), case.bindings);
                        if (!actual.eql(case.expected)) return error.IncorrectDecision;
                        _ = evaluation.reset(.retain_capacity);
                    }
                }
            }
            const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io));
            if (sample >= 5) totals[sample - 5] = @intCast(elapsed.nanoseconds);
        }
        var sorted = totals;
        std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
        const median = @as(f64, @floatFromInt(sorted[14] + sorted[15])) / 2;
        metric.* = .{
            .phase = if (cold) "cold_compile_and_evaluate" else "warm_evaluate_reused_program",
            .iterations_per_sample = iterations,
            .decisions_per_sample = iterations * decisions,
            .total_ns = totals,
            .median_ns_per_decision = median / @as(f64, @floatFromInt(iterations * decisions)),
            .relative_iqr = @as(f64, @floatFromInt(sorted[22] - sorted[7])) / median,
        };
    }
    const output = try std.json.Stringify.valueAlloc(storage.allocator(), .{
        .runtime = "zig",
        .callback_authorization = callback_mode,
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .architecture = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .warmups = 5,
        .decisions_per_iteration = decisions,
        .metrics = metrics,
    }, .{ .whitespace = .indent_2 });
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.writeAll(output);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn prepare(arena: std.mem.Allocator, callback_mode: bool) ![]Workload {
    const root = try std.json.parseFromSlice(std.json.Value, arena, @embedFile("workloads.json"), .{});
    const workloads = try arena.alloc(Workload, root.value.array.items.len);
    var initialized: usize = 0;
    errdefer for (workloads[0..initialized]) |*workload| workload.program.deinit();
    for (root.value.array.items, workloads) |input, *workload| {
        const source = if (callback_mode and std.mem.eql(u8, input.object.get("name").?.string, "request_authorization"))
            "request.method == 'GET' && request.path.startsWith('/v1/') && principal.authenticated && " ++
                "is_allowed(principal.role, resource.owner, principal.id)"
        else
            input.object.get("expression").?.string;
        const inputs = input.object.get("cases").?.array.items;
        const cases = try arena.alloc(Case, inputs.len);
        for (inputs, cases) |item, *case| {
            var object = item.object.get("bindings").?.object;
            const bindings = try arena.alloc(cel.Binding, object.count());
            var iterator = object.iterator();
            var i: usize = 0;
            while (iterator.next()) |entry| : (i += 1) {
                bindings[i] = .{ .name = entry.key_ptr.*, .value = try convert(arena, entry.value_ptr.*) };
            }
            case.* = .{ .bindings = bindings, .expected = try convert(arena, item.object.get("expected").?) };
        }
        var environment = cel.Environment{};
        if (callback_mode) {
            const variables = try arena.alloc(cel.Declaration, cases[0].bindings.len);
            for (variables, cases[0].bindings) |*variable, binding| variable.* = .{ .name = binding.name, .type = .{ .name = "dyn" } };
            environment.variables = variables;
            environment.functions = &.{.{ .name = "is_allowed", .parameters = &.{ .{ .name = "string" }, .{ .name = "string" }, .{ .name = "string" } }, .result = .{ .name = "bool" }, .implementation = allowed }};
        }
        workload.* = .{ .source = source, .environment = environment, .program = if (callback_mode) try environment.compile(arena, source, .{}) else try cel.Program.compile(arena, source, .{}), .cases = cases };
        initialized += 1;
    }
    return workloads;
}

fn allowed(_: ?*anyopaque, _: std.mem.Allocator, args: []const cel.Value) cel.EvalError!cel.Value {
    return .{ .bool = std.mem.eql(u8, args[0].string, "admin") or args[1].eql(args[2]) };
}

fn convert(arena: std.mem.Allocator, input: std.json.Value) std.mem.Allocator.Error!cel.Value {
    return switch (input) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .int = v },
        .float => |v| .{ .double = v },
        .string => |v| .{ .string = v },
        .number_string => unreachable,
        .array => |array| blk: {
            const list = try arena.alloc(cel.Value, array.items.len);
            for (array.items, list) |item, *out| out.* = try convert(arena, item);
            break :blk .{ .list = list };
        },
        .object => |object| blk: {
            const map = try arena.alloc(cel.Entry, object.count());
            var iterator = object.iterator();
            var i: usize = 0;
            while (iterator.next()) |entry| : (i += 1) {
                map[i] = .{ .key = .{ .string = entry.key_ptr.* }, .value = try convert(arena, entry.value_ptr.*) };
            }
            break :blk .{ .map = map };
        },
    };
}

test "shared request workload decisions match their expected outcomes" {
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const workloads = try prepare(storage.allocator(), @import("options").functions);
    defer for (workloads) |*workload| workload.program.deinit();
    var evaluation = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer evaluation.deinit();
    for (workloads) |workload| {
        for (workload.cases) |case| {
            const actual = try workload.program.evaluate(evaluation.allocator(), case.bindings);
            try std.testing.expect(actual.eql(case.expected));
            _ = evaluation.reset(.retain_capacity);
        }
    }
}
