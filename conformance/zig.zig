//! Typed-JSON conformance transport. Each request calls the public Zig SDK with independent storage.

const std = @import("std");
const cel = @import("cel");
const fixtures = @import("fixtures");
const codec = @import("zig_codec.zig");

const Outcome = struct {
    id: std.json.Value = .null,
    outcome: []const u8 = "input_error",
    value: ?std.json.Value = null,
    checked_type: ?std.json.Value = null,
    @"error": ?[]const u8 = null,
};

/// Read one bounded request batch and write phase-separated public SDK outcomes.
pub fn main(init: std.process.Init) !void {
    var storage = std.heap.ArenaAllocator.init(init.gpa);
    defer storage.deinit();
    const arena = storage.allocator();
    var input_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;
    // Reader limits stop before probing EOF; reserve one byte for that probe.
    const data = input.interface.allocRemaining(arena, .limited(32 * 1024 * 1024 + 1)) catch |err| {
        try std.json.Stringify.value([_]Outcome{.{ .@"error" = @errorName(err) }}, .{}, writer);
        try writer.flush();
        return;
    };
    try run(init.gpa, data, writer);
}

/// Execute a bounded typed-JSON request batch through the public CEL SDK.
pub fn run(gpa: std.mem.Allocator, data: []const u8, writer: *std.Io.Writer) !void {
    if (data.len > 32 * 1024 * 1024) {
        try std.json.Stringify.value([_]Outcome{.{ .@"error" = "StreamTooLong" }}, .{}, writer);
        try writer.flush();
        return;
    }
    var storage = std.heap.ArenaAllocator.init(gpa);
    defer storage.deinit();
    const arena = storage.allocator();
    validateBatch(arena, data) catch |err| {
        try std.json.Stringify.value([_]Outcome{.{ .@"error" = @errorName(err) }}, .{}, writer);
        try writer.flush();
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{ .max_value_len = 32 * 1024 * 1024 }) catch |err| {
        try std.json.Stringify.value([_]Outcome{.{ .@"error" = @errorName(err) }}, .{}, writer);
        try writer.flush();
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len > 10_000) {
        try std.json.Stringify.value([_]Outcome{.{ .@"error" = "expected a request array with at most 10000 cases" }}, .{}, writer);
        try writer.flush();
        return;
    }
    var environment = try (cel.Environment{ .descriptors = fixtures.upstream }).clone(arena, .{});
    defer environment.deinit();
    try writer.writeByte('[');
    for (parsed.value.array.items, 0..) |request, i| {
        var request_storage = std.heap.ArenaAllocator.init(gpa);
        defer request_storage.deinit();
        if (i != 0) try writer.writeByte(',');
        const outcome = execute(gpa, request_storage.allocator(), environment, request);
        try std.json.Stringify.value(outcome, .{ .emit_null_optional_fields = false }, writer);
    }
    try writer.writeAll("]\n");
    try writer.flush();
}

test "untrusted audit transport returns JSON without traps or leaks" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) !void {
            var bytes: [2048]u8 = undefined;
            const length = smith.slice(&bytes);
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            try run(std.testing.allocator, bytes[0..length], &output.writer);
            try std.testing.expect(try std.json.validate(std.testing.allocator, output.written()));
        }
    }.one, .{ .corpus = &.{
        "\x02\x00\x00\x00[]",
        "\x29\x00\x00\x00[{\"id\":\"v\",\"expr\":\"[1,2]\",\"bindings\":{}}]",
    } });
}

fn validateBatch(arena: std.mem.Allocator, data: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(arena, data);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        tokens += 1;
        if (tokens > 2_000_000) return error.JSONValueLimitExceeded;
        switch (try scanner.next()) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > 1024) return error.JSONDepthLimitExceeded;
            },
            .object_end, .array_end => depth -= 1,
            .end_of_document => return,
            else => {},
        }
    }
}

fn execute(gpa: std.mem.Allocator, arena: std.mem.Allocator, base: cel.Environment, request: std.json.Value) Outcome {
    var result = Outcome{};
    if (request != .object) {
        result.@"error" = "request must be an object";
        return result;
    }
    result.id = request.object.get("id") orelse .null;
    if (result.id != .string or result.id.string.len > 4096) {
        result.id = .null;
        result.@"error" = "id must be a bounded string";
        return result;
    }
    for (request.object.keys()) |key| {
        const known = std.StaticStringMap(void).initComptime(.{
            .{"id"},    .{"expr"},      .{"bindings"},    .{"variables"}, .{"container"},
            .{"check"}, .{"checkOnly"}, .{"strongEnums"}, .{"functions"},
        });
        if (!known.has(key)) {
            result.@"error" = "unknown request field";
            return result;
        }
    }
    const expression = request.object.get("expr") orelse .null;
    const container: std.json.Value = request.object.get("container") orelse .{ .string = "" };
    const check: std.json.Value = request.object.get("check") orelse .{ .bool = false };
    const check_only: std.json.Value = request.object.get("checkOnly") orelse .{ .bool = false };
    const strong_enums: std.json.Value = request.object.get("strongEnums") orelse .{ .bool = false };
    if (expression != .string or container != .string or check != .bool or check_only != .bool or strong_enums != .bool) {
        result.@"error" = "invalid expression or configuration type";
        return result;
    }
    var environment = base;
    environment.container = container.string;
    environment.strong_enums = strong_enums.bool;
    if (request.object.get("variables")) |variables| {
        if (variables != .object or variables.object.count() > 100_000) {
            result.@"error" = "variables must be a bounded object";
            return result;
        }
        const declarations = arena.alloc(cel.Declaration, variables.object.count()) catch |err| {
            result.@"error" = @errorName(err);
            return result;
        };
        for (variables.object.keys(), variables.object.values(), declarations) |name, type_value, *declaration| {
            const declared = codec.decodeType(arena, type_value, 0) catch |err| {
                result.@"error" = @errorName(err);
                return result;
            };
            declaration.* = .{ .name = name, .type = declared };
        }
        environment.variables = declarations;
    }
    if (request.object.get("functions")) |declarations| {
        if (declarations != .array or declarations.array.items.len > 100_000) {
            result.@"error" = "functions must be a bounded array";
            return result;
        }
        const declared = arena.alloc(cel.Function, declarations.array.items.len) catch |err| {
            result.@"error" = @errorName(err);
            return result;
        };
        for (declarations.array.items, declared) |declaration, *out| {
            if (declaration != .object) {
                result.@"error" = "invalid function declaration";
                return result;
            }
            for (declaration.object.keys()) |key| {
                const known = std.StaticStringMap(void).initComptime(.{
                    .{"name"}, .{"overloadId"}, .{"member"}, .{"params"}, .{"resultType"},
                });
                if (!known.has(key)) {
                    result.@"error" = "unknown function declaration field";
                    return result;
                }
            }
            const name = declaration.object.get("name") orelse .null;
            const id: std.json.Value = declaration.object.get("overloadId") orelse .{ .string = "" };
            const member: std.json.Value = declaration.object.get("member") orelse .{ .bool = false };
            const params = declaration.object.get("params") orelse .null;
            const returns = declaration.object.get("resultType") orelse .null;
            if (name != .string or id != .string or member != .bool or params != .array or params.array.items.len > 100_000) {
                result.@"error" = "invalid function signature";
                return result;
            }
            const parameters = arena.alloc(cel.Type, params.array.items.len) catch |err| {
                result.@"error" = @errorName(err);
                return result;
            };
            for (params.array.items, parameters) |p, *output| output.* = codec.decodeType(arena, p, 0) catch |err| {
                result.@"error" = @errorName(err);
                return result;
            };
            out.* = .{ .name = name.string, .overload_id = id.string, .member = member.bool, .parameters = parameters, .result = codec.decodeType(arena, returns, 0) catch |err| {
                result.@"error" = @errorName(err);
                return result;
            } };
        }
        environment.functions = declared;
    }
    var program = (if (check.bool)
        environment.compile(gpa, expression.string, .{})
    else
        environment.parse(gpa, expression.string, .{})) catch |err| {
        result.outcome = "compile_error";
        result.@"error" = @errorName(err);
        return result;
    };
    defer program.deinit();
    if (program.result_type) |t| result.checked_type = codec.encodeType(arena, t, 0) catch |err| {
        result.@"error" = @errorName(err);
        return result;
    };
    if (check_only.bool) {
        result.outcome = "checked";
        return result;
    }
    const input = request.object.get("bindings") orelse .null;
    if (input != .object or input.object.count() > 100_000) {
        result.@"error" = "bindings must be a bounded object";
        return result;
    }
    const bindings = arena.alloc(cel.Binding, input.object.count()) catch |err| {
        result.@"error" = @errorName(err);
        return result;
    };
    var budget = codec.Budget{};
    for (input.object.keys(), input.object.values(), bindings) |name, value, *binding| {
        if (name.len > budget.bytes) {
            result.@"error" = "ByteLimitExceeded";
            return result;
        }
        budget.bytes -= name.len;
        const decoded = codec.decodeValue(arena, value, &budget, 0) catch |err| {
            if (err == error.UnsupportedValue) result.outcome = "unsupported";
            result.@"error" = @errorName(err);
            return result;
        };
        binding.* = .{ .name = name, .value = decoded };
    }
    const value = program.evaluate(arena, bindings) catch |err| {
        result.outcome = "eval_error";
        result.@"error" = @errorName(err);
        return result;
    };
    result.value = codec.encodeValue(arena, value, 0) catch |err| {
        result.outcome = "unsupported";
        result.@"error" = @errorName(err);
        return result;
    };
    result.outcome = "value";
    return result;
}
