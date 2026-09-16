//! Compile CEL expressions once and evaluate them against borrowed input bindings.

const std = @import("std");
const cel = @import("root.zig");
const value = @import("value.zig");
const syntax = @import("syntax.zig");
const eval = @import("eval.zig");
const regex = @import("regex.zig");
const checker = @import("checker.zig");
const names = @import("names.zig");
const types = @import("types.zig");
const proto = @import("proto.zig");
const function_module = @import("functions.zig");
const Allocator = std.mem.Allocator;
const Value = value.Value;
const Binding = value.Binding;

/// Resource limits for untrusted source and evaluation.
pub const Limits = syntax.Limits;
/// Compilation errors.
pub const CompileError = syntax.ParseError || checker.CheckError || error{
    /// A declaration name, type, or constant is invalid or duplicated.
    InvalidDeclaration,
    /// Environment data exceeds its byte or work budget.
    DeclarationLimitExceeded,
    /// A descriptor set is malformed or has unresolved dependencies.
    InvalidDescriptor,
    /// Descriptor loading exceeds its resource limits.
    ProtobufLimitExceeded,
    /// The program contains more distinct literal regexes than allowed.
    RegexLimitExceeded,
};
/// Evaluation errors.
pub const EvalError = eval.EvalError;

/// A static CEL type description.
pub const Type = types.Type;
/// A named variable declaration.
pub const Declaration = types.Declaration;
/// A typed custom function overload.
pub const Function = function_module.Function;

/// Borrowed environment configuration. Compiled programs copy their environment data.
pub const Environment = struct {
    container: []const u8 = "",
    variables: []const Declaration = &.{},
    constants: []const Binding = &.{},
    functions: []const Function = &.{},
    descriptors: []const u8 = "",
    /// Preserve protobuf enum identity instead of mapping enum fields and constants to int.
    strong_enums: bool = false,
    /// Owned native registry in cloned configurations; callers normally supply descriptors instead.
    registry: ?*proto.Registry = null,

    /// Validate and copy configuration into caller-owned arena storage.
    pub fn clone(self: Environment, arena: std.mem.Allocator, limits: Limits) CompileError!Environment {
        var remaining = limits.max_source_bytes;
        const registry = if (self.registry) |existing| blk: {
            proto.retain(existing);
            break :blk existing;
        } else if (self.descriptors.len > 0) try proto.load(self.descriptors, limits.protobuf) else null;
        errdefer proto.release(registry);
        if (!names.valid(self.container, true)) return error.InvalidDeclaration;
        if (self.container.len > remaining) return error.DeclarationLimitExceeded;
        remaining -= self.container.len;
        if (std.mem.count(u8, self.container, ".") >= limits.max_depth) return error.DepthLimitExceeded;
        const container = try arena.dupe(u8, self.container);
        if (self.variables.len > remaining or self.constants.len > remaining) return error.DeclarationLimitExceeded;
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        const variables = try arena.alloc(Declaration, self.variables.len);
        for (self.variables, variables) |input, *output| {
            if (!names.valid(input.name, false)) return error.InvalidDeclaration;
            if (input.name.len >= remaining) return error.DeclarationLimitExceeded;
            remaining -= input.name.len + 1;
            if ((try declared.getOrPut(arena, input.name)).found_existing) return error.InvalidDeclaration;
            output.* = .{ .name = try arena.dupe(u8, input.name), .type = try input.type.clone(arena, limits.max_depth, &remaining, registry) };
        }
        const constants = try arena.alloc(Binding, self.constants.len);
        for (self.constants, constants) |input, *output| {
            if (!names.valid(input.name, false)) return error.InvalidDeclaration;
            if (input.name.len >= remaining) return error.DeclarationLimitExceeded;
            remaining -= input.name.len + 1;
            if ((try declared.getOrPut(arena, input.name)).found_existing) return error.InvalidDeclaration;
            output.* = .{ .name = try arena.dupe(u8, input.name), .value = try types.cloneValue(arena, input.value, limits.max_depth, &remaining, registry) };
        }
        if (self.functions.len > remaining) return error.DeclarationLimitExceeded;
        const functions = try arena.alloc(Function, self.functions.len);
        var overload_ids: std.StringHashMapUnmanaged(void) = .empty;
        for (self.functions, functions, 0..) |input, *output, i| {
            if (!names.valid(input.name, false) or (input.member and input.parameters.len == 0))
                return error.InvalidDeclaration;
            const id = if (input.overload_id.len == 0) input.name else input.overload_id;
            const size = std.math.add(usize, input.name.len, id.len) catch return error.DeclarationLimitExceeded;
            if (size >= remaining) return error.DeclarationLimitExceeded;
            remaining -= size + 1;
            if ((try overload_ids.getOrPut(arena, id)).found_existing) return error.InvalidDeclaration;
            if (input.parameters.len > remaining) return error.DeclarationLimitExceeded;
            const parameters = try arena.alloc(Type, input.parameters.len);
            for (input.parameters, parameters) |parameter, *p| p.* = try parameter.clone(arena, limits.max_depth, &remaining, registry);
            if (i > remaining) return error.DeclarationLimitExceeded;
            remaining -= i;
            for (functions[0..i]) |previous| {
                if (input.member != previous.member or !std.mem.eql(u8, input.name, previous.name) or
                    parameters.len != previous.parameters.len) continue;
                const same = for (parameters, previous.parameters) |a, b| {
                    if (!try function_module.typesOverlap(a, b, registry, &remaining)) break false;
                } else true;
                if (same) return error.InvalidDeclaration;
            }
            output.* = .{
                .name = try arena.dupe(u8, input.name),
                .overload_id = try arena.dupe(u8, id),
                .parameters = parameters,
                .result = try input.result.clone(arena, limits.max_depth, &remaining, registry),
                .member = input.member,
                .implementation = input.implementation,
                .context = input.context,
            };
        }
        return .{
            .container = container,
            .variables = variables,
            .constants = constants,
            .functions = functions,
            .registry = registry,
            .strong_enums = self.strong_enums,
        };
    }

    /// Release a cloned configuration's native descriptor ownership before freeing its arena.
    pub fn deinit(self: *Environment) void {
        proto.release(self.registry);
        self.registry = null;
    }

    /// Compile and statically check an expression against this environment.
    pub fn compile(self: Environment, gpa: std.mem.Allocator, source: []const u8, limits: Limits) CompileError!Program {
        return buildProgram(gpa, source, self, limits, true);
    }

    /// Compile without checking, retaining namespace and constant resolution.
    pub fn parse(self: Environment, gpa: std.mem.Allocator, source: []const u8, limits: Limits) CompileError!Program {
        return buildProgram(gpa, source, self, limits, false);
    }
};

/// An immutable compiled expression. Independent evaluations may run concurrently.
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    root: *const syntax.Node,
    limits: Limits,
    regexes: regex.Cache,
    environment: Environment,
    result_type: ?Type,

    /// Copy and compile source. The caller must call deinit exactly once.
    pub fn compile(gpa: std.mem.Allocator, source: []const u8, limits: Limits) CompileError!Program {
        return (Environment{}).parse(gpa, source, limits);
    }

    /// Serialize the plain-data subset of this program as JSON for host-side compilation, or null when
    /// any node falls outside that subset. The caller owns the returned bytes.
    pub fn fastPlan(self: *const Program, gpa: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
        if (self.environment.container.len != 0 or self.environment.constants.len != 0 or
            self.environment.functions.len != 0 or self.environment.registry != null) return null;
        return @import("fast_plan.zig").emit(gpa, self.root);
    }

    /// Release syntax and literals. No evaluation may still be using this program.
    pub fn deinit(self: *Program) void {
        self.regexes.deinit(self.arena.allocator());
        self.environment.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Evaluate with borrowed bindings. The result lives no longer than the program, inputs, and arena.
    pub fn evaluate(self: *const Program, arena: std.mem.Allocator, bindings: []const Binding) EvalError!Value {
        return eval.evaluate(arena, self.root, bindings, self.limits, &self.regexes, self.environment.container, self.environment.constants, self.environment.registry, self.environment.strong_enums, self.environment.functions);
    }
};

fn buildProgram(
    gpa: std.mem.Allocator,
    source: []const u8,
    environment: Environment,
    limits: Limits,
    checked: bool,
) CompileError!Program {
    if (source.len > limits.max_source_bytes) return error.SourceLimitExceeded;
    var state = std.heap.ArenaAllocator.init(gpa);
    errdefer state.deinit();
    const arena = state.allocator();
    var config = try environment.clone(arena, limits);
    errdefer config.deinit();
    const owned = try arena.dupe(u8, source);
    var patterns: std.ArrayList([]const u8) = .empty;
    const root = try syntax.parse(arena, owned, limits, &patterns);
    const result_type = if (checked) try checker.check(arena, root, config.variables, config.constants, config.container, limits, config.registry, config.strong_enums, config.functions) else null;
    var regexes: regex.Cache = .{};
    errdefer regexes.deinit(arena);
    for (patterns.items) |pattern| _ = try regexes.get(arena, pattern, limits.regex);
    return .{ .arena = state, .root = root, .limits = limits, .regexes = regexes, .environment = config, .result_type = result_type };
}

fn expectExpression(source: []const u8, bindings: []const Binding, expected: Value) !void {
    var program = try Program.compile(std.testing.allocator, source, .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try program.evaluate(arena.allocator(), bindings);
    try std.testing.expect(expected.eql(result));
}

test "protobuf helper policies use descriptor fields and syntactic extension names" {
    const environment = Environment{ .descriptors = @import("fixtures").upstream, .container = "cel.expr.conformance.proto2" };
    var program = try environment.compile(std.testing.allocator, "cel.bind(msg, TestAllTypes{`cel.expr.conformance.proto2.int32_ext`: 42}, " ++
        "proto.hasExt(msg, cel.expr.conformance.proto2.int32_ext) && " ++
        "proto.getExt(msg, cel.expr.conformance.proto2.int32_ext) == 42 && " ++
        "!proto.hasExt(msg, cel.expr.conformance.proto2.repeated_test_all_types))", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    try expectExpression("proto.getExt({'a.b': 3}, a.b)", &.{}, .{ .int = 3 });
    try expectExpression("base64.encode(b'hello') == 'aGVsbG8=' && base64.decode('aGVsbG8') == b'hello' && " ++
        "base64.decode('Zh==') == b'f' && base64.decodeUrl('-x==') == b'\\xfb'", &.{}, .{ .bool = true });
}

test "protobuf extension lookup charges the qualified field name" {
    const environment = Environment{ .descriptors = @import("fixtures").upstream };
    var program = try environment.parse(std.testing.allocator, "proto.hasExt(msg, cel.expr.conformance.proto2.int32_ext)", .{ .max_steps = 16 });
    defer program.deinit();
    const message = value.Message{ .type_name = "cel.expr.conformance.proto2.TestAllTypes", .data = "" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CostLimitExceeded, program.evaluate(arena.allocator(), &.{
        .{ .name = "msg", .value = .{ .message = &message } },
    }));
}

test "Base64 conversion obeys output and work limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "base64.encode(b'abc')", "base64.decode('YWJj')" }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{ .max_collection_size = 2 });
        defer program.deinit();
        try std.testing.expectError(error.CollectionLimitExceeded, program.evaluate(arena.allocator(), &.{}));
    }
    var program = try Program.compile(std.testing.allocator, "base64.decode(text) == b'' || true", .{ .max_steps = 16 });
    defer program.deinit();
    try std.testing.expectError(error.CostLimitExceeded, program.evaluate(arena.allocator(), &.{
        .{ .name = "text", .value = .{ .string = "\r\n" ** 32 } },
    }));
}

test "protobuf helpers and Base64 release every failing Zig allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const environment = Environment{ .descriptors = @import("fixtures").upstream };
            var program = try environment.compile(gpa, "proto.getExt(cel.expr.conformance.proto2.TestAllTypes{}, cel.expr.conformance.proto2.int32_ext) == 0 && " ++
                "base64.encode(base64.decode('Z\\r\\nh==')) == 'Zg=='", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }.run, .{});
}

test "Base64 untrusted text returns decoded bytes or an encoding error" {
    var program = try Program.compile(std.testing.allocator, "base64.decode(text)", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_- \r\n\t";
            var bytes: [128]u8 = undefined;
            for (&bytes) |*b| b.* = alphabet[smith.value(u8) % alphabet.len];
            const len = smith.value(u8) % 129;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const result = p.evaluate(arena.allocator(), &.{
                .{ .name = "text", .value = .{ .string = bytes[0..len] } },
            }) catch |err| {
                try std.testing.expectEqual(error.InvalidArgument, err);
                return;
            };
            try std.testing.expect(result == .bytes);
            try std.testing.expect(result.bytes.len <= len);
        }
    }.run, .{});
}

test "Base64 binary activations round trip without trapping" {
    var program = try Program.compile(std.testing.allocator, "base64.decode(base64.encode(data)) == data && base64.decodeUrl(base64.encodeUrl(data)) == data", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            var bytes: [127]u8 = undefined;
            for (&bytes) |*b| b.* = smith.value(u8);
            const len = smith.value(u8) % 128;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try p.evaluate(arena.allocator(), &.{
                .{ .name = "data", .value = .{ .bytes = bytes[0..len] } },
            }));
        }
    }.run, .{});
}

test "string extension policies preserve Unicode and formatting semantics" {
    const source = "'  Alice Smith  '.trim().lowerAscii().replace(' ', '-') == 'alice-smith' && " ++
        "' admin, read '.split(',').map(x,x.trim().upperAscii()).join('|') == 'ADMIN|READ' && " ++
        "'A😀Z'.charAt(1) == '😀' && 'A😀Z'.substring(1,3).reverse() == 'Z😀' && " ++
        "'😀x😀'.lastIndexOf('😀') == 2 && strings.quote('a\\nb') == '\"a\\\\nb\"' && " ++
        "'%.0f|%.3f|%.2e|%X'.format([2.5,1.25,10.0,b'az']) == '2|1.250|1.00e+01|617A'";
    try expectExpression(source, &.{}, .{ .bool = true });
    var checked = try (Environment{}).compile(std.testing.allocator, source, .{});
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try checked.evaluate(arena.allocator(), &.{}));
}

test "string extension output and search costs stay bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "'aaaa'.replace('a','abcd')", "'abc'.split('')", "'%.1000f'.format([1.1])" }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{ .max_collection_size = 2 });
        defer program.deinit();
        try std.testing.expectError(error.CollectionLimitExceeded, program.evaluate(arena.allocator(), &.{}));
    }
    var search = try Program.compile(std.testing.allocator, "text.indexOf(needle)", .{ .max_steps = 2000 });
    defer search.deinit();
    try std.testing.expectError(error.CostLimitExceeded, search.evaluate(arena.allocator(), &.{
        .{ .name = "text", .value = .{ .string = "a" ** 300 } },
        .{ .name = "needle", .value = .{ .string = "a" ** 100 ++ "b" } },
    }));
    var invalid = try Program.compile(std.testing.allocator, "text.lowerAscii()", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidArgument, invalid.evaluate(arena.allocator(), &.{
        .{ .name = "text", .value = .{ .string = "\xff" } },
    }));
}

test "borrowed string extension results obey output limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "text.substring(0)", "text.trim()", "text.replace('x','y',0)", "text.split(',')" }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{ .max_collection_size = 2 });
        defer program.deinit();
        try std.testing.expectError(error.CollectionLimitExceeded, program.evaluate(arena.allocator(), &.{
            .{ .name = "text", .value = .{ .string = "abc" } },
        }));
    }
}

test "string extension allocation failures release all temporary storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{}).compile(gpa, "'%s|%.400f'.format([{'b': ['x,y'.split(',').join('-')], 'a': strings.quote('z')},1.25]).size() > 400", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }.run, .{});
}

test "Unicode string transformations round trip through public evaluation" {
    var program = try Program.compile(std.testing.allocator, "text.replace('', '-').split('-').join('').reverse().reverse() == text", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            const alphabet = [_][]const u8{ "a", "😀", "é", "\x00", "\n" };
            var text: [64]u8 = undefined;
            var length: usize = 0;
            for (0..16) |_| {
                const part = alphabet[smith.value(u8) % alphabet.len];
                @memcpy(text[length..][0..part.len], part);
                length += part.len;
            }
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try p.evaluate(arena.allocator(), &.{
                .{ .name = "text", .value = .{ .string = text[0..length] } },
            }));
        }
    }.run, .{});
}

test "formatted untrusted bytes always produce valid UTF-8" {
    var program = try Program.compile(std.testing.allocator, "'%s'.format([data])", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            var bytes: [32]u8 = undefined;
            for (&bytes) |*b| b.* = smith.value(u8);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const result = try p.evaluate(arena.allocator(), &.{.{ .name = "data", .value = .{ .bytes = &bytes } }});
            try std.testing.expect(std.unicode.utf8ValidateSlice(result.string));
        }
    }.run, .{});
}

test "indexed blocks preserve lazy dependencies and lexical iterator handles" {
    const source = "cel.block([1, 'ok', [cel.index(0)], cel.index(0)+2], [cel.index(1),cel.index(2),cel.index(3)])";
    try expectExpression(source, &.{}, .{ .list = &.{ .{ .string = "ok" }, .{ .list = &.{.{ .int = 1 }} }, .{ .int = 3 } } });
    var checked = try (Environment{}).compile(std.testing.allocator, "cel.block([1, cel.index(0)+2], cel.index(1))", .{});
    defer checked.deinit();
    try std.testing.expect(checked.result_type.?.eql(.{ .name = "int" }));
    try expectExpression("cel.block([1/0], true)", &.{}, .{ .bool = true });
    try expectExpression("cel.block([1/0], (cel.index(0) == 1 || true) && (cel.index(0) == 1 || true))", &.{}, .{ .bool = true });
    try expectExpression("cel.block([10], cel.bind(x, cel.index(0), cel.block([2,x+cel.index(0)], cel.index(1))))", &.{}, .{ .int = 12 });
    try expectExpression("[1,2].map(cel.iterVar(0,0), cel.iterVar(0,0)+1)", &.{}, .{ .list = &.{ .{ .int = 2 }, .{ .int = 3 } } });
}

test "indexed block allocation and dependency work obey resource limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var slots = try Program.compile(std.testing.allocator, "cel.block([1,2,3],true)", .{ .max_collection_size = 2 });
    defer slots.deinit();
    try std.testing.expectError(error.CollectionLimitExceeded, slots.evaluate(arena.allocator(), &.{}));
    var work = try Program.compile(std.testing.allocator, "cel.block([1,2],true)", .{ .max_steps = 2 });
    defer work.deinit();
    try std.testing.expectError(error.CostLimitExceeded, work.evaluate(arena.allocator(), &.{}));
    try expectExpression("cel.block([cel.index(1)+1,2],cel.index(0))", &.{}, .{ .int = 3 });
    try expectExpression("cel.block([cel.index(0)],true)", &.{}, .{ .bool = true });
    var cycle = try Program.compile(std.testing.allocator, "cel.block([cel.index(0)],cel.index(0))", .{});
    defer cycle.deinit();
    try std.testing.expectError(error.UndeclaredReference, cycle.evaluate(arena.allocator(), &.{}));
}

test "indexed block ownership cleans up after every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{}).compile(gpa, "cel.block([lists.range(32),cel.index(0).reverse(),[cel.index(0),cel.index(1)].flatten()]," ++
                "cel.index(2).distinct().size() == 32)", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }.run, .{});
}

test "indexed dependency graphs resolve values or bounded cycle errors" {
    try std.testing.fuzz(.{}, struct {
        fn run(_: @TypeOf(.{}), smith: *std.testing.Smith) !void {
            const links = [_]usize{ smith.value(u8) % 5, 1, smith.value(u8) % 5 };
            const query: usize = smith.value(u8) % 5;
            var buffer: [128]u8 = undefined;
            const source = try std.fmt.bufPrint(&buffer, "cel.block([cel.index({d}), 42, cel.index({d})], cel.index({d}))", .{ links[0], links[2], query });
            var program = try Program.compile(std.testing.allocator, source, .{ .max_steps = 100 });
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var visited = [_]bool{false} ** 3;
            var index = query;
            while (index < links.len and index != 1 and !visited[index]) {
                visited[index] = true;
                index = links[index];
            }
            if (index == 1) {
                try std.testing.expectEqual(Value{ .int = 42 }, try program.evaluate(arena.allocator(), &.{}));
            } else {
                try std.testing.expectError(error.UndeclaredReference, program.evaluate(arena.allocator(), &.{}));
            }
        }
    }.run, .{});
}

test "indexed block caches remain request local for untrusted scalar activations" {
    var program = try Program.compile(std.testing.allocator, "cel.block([value, [cel.index(0), other]], [cel.index(0),cel.index(1),cel.index(1)])", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            const first = Value{ .int = smith.value(i64) };
            const second = Value{ .uint = smith.value(u64) };
            const pair = Value{ .list = &.{ first, second } };
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const actual = try p.evaluate(arena.allocator(), &.{
                .{ .name = "value", .value = first }, .{ .name = "other", .value = second },
            });
            try std.testing.expect((Value{ .list = &.{ first, pair, pair } }).eql(actual));
        }
    }.run, .{});
}

test "local bindings preserve lazy lexical scope through the public API" {
    const source = "cel.bind(x, 10, [1,2].map(y, cel.bind(z, x+y, cel.bind(x, 100, z+z))))";
    try expectExpression(source, &.{}, .{ .list = &.{ .{ .int = 22 }, .{ .int = 24 } } });
    var checked = try (Environment{}).compile(std.testing.allocator, source, .{});
    defer checked.deinit();
    try std.testing.expect(checked.result_type.?.eql(.{ .name = "list", .parameters = &.{.{ .name = "int" }} }));
    try expectExpression("cel.bind(x, missing, true)", &.{}, .{ .bool = true });
    try expectExpression("cel.bind(x, 1/0, (x == 1 || true) && (x == 2 || true))", &.{}, .{ .bool = true });
    try expectExpression("cel.bind(x, null, [x,x])", &.{}, .{ .list = &.{ .null, .null } });
    try expectExpression("cel.bind(x, {'y': 1}, x.y + .x.y)", &.{
        .{ .name = "x.y", .value = .{ .int = 9 } },
    }, .{ .int = 10 });
}

test "local bindings skip unused work but cannot suppress resource errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var unused = try Program.compile(std.testing.allocator, "cel.bind(x, lists.range(100), true)", .{
        .max_steps = 10,
        .max_collection_size = 1,
    });
    defer unused.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try unused.evaluate(arena.allocator(), &.{}));
    var used = try Program.compile(std.testing.allocator, "cel.bind(x, lists.range(100), x == [] || true)", .{
        .max_steps = 10,
        .max_collection_size = 1,
    });
    defer used.deinit();
    try std.testing.expectError(error.CollectionLimitExceeded, used.evaluate(arena.allocator(), &.{}));
    const name = "a" ** 64;
    var lookup = try Program.compile(std.testing.allocator, "cel.bind(" ++ name ++ ", 1, " ++ name ++ ")", .{ .max_steps = 32 });
    defer lookup.deinit();
    try std.testing.expectError(error.CostLimitExceeded, lookup.evaluate(arena.allocator(), &.{}));
}

test "local binding ownership cleans up after every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{}).compile(gpa, "cel.bind(x, lists.range(32), cel.bind(y, x.reverse(), [x,y,x].flatten().distinct().size() == 32))", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }.run, .{});
}

test "local binding caches remain scoped for untrusted scalar activations" {
    var program = try Program.compile(std.testing.allocator, "cel.bind(x, value, cel.bind(value, other, [x,x,value]))", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            const first = Value{ .int = smith.value(i64) };
            const second = Value{ .uint = smith.value(u64) };
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const result = try p.evaluate(arena.allocator(), &.{
                .{ .name = "value", .value = first }, .{ .name = "other", .value = second },
            });
            try std.testing.expect((Value{ .list = &.{ first, first, second } }).eql(result));
        }
    }.run, .{});
}

test "list extension policies preserve ordering types and nested equality" {
    const source = "[[3,1],[2,3],[4]].flatten().distinct().sort().slice(0,3).reverse() == [3,2,1] && " ++
        "lists.range(5).sortBy(e, -e) == [4,3,2,1,0] && " ++
        "[1,1u,1.0,true,true,{'x':[1]},{'x':[1u]}].distinct().size() == 3";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |checked| {
        var program = if (checked) try (Environment{}).compile(std.testing.allocator, source, .{}) else try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    }
    try expectExpression("lists.range(30).sortBy(e, e % 3).slice(0, 3)", &.{}, .{ .list = &.{
        .{ .int = 0 }, .{ .int = 3 }, .{ .int = 6 },
    } });
}

test "large distinct lists preserve numeric aliases and unequal hash collisions" {
    try expectExpression("lists.range(100).map(x, [x, uint(x), double(x)]).flatten().distinct().size() == 100 && " ++
        "lists.range(30).map(x, [-1, 18446744073709551615u, true, 1]).flatten().distinct().size() == 4 && " ++
        "lists.range(30).map(x, {'x': [1]}).distinct().size() == 1", &.{}, .{ .bool = true });
    try expectExpression("lists.range(20).map(x, [null,true,1,1u,1.0,-0.0,0,b'a','a',int," ++
        "timestamp('1970-01-01T00:00:00Z'),duration('1s'),optional.none(),[1]]).flatten().distinct().size() == 11", &.{}, .{ .bool = true });
    const enumeration = value.EnumValue{ .type_name = "sample.State", .number = -1 };
    const enums = [_]Value{.{ .enum_value = &enumeration }} ** 30;
    try expectExpression("items.distinct().size()", &.{.{ .name = "items", .value = .{ .list = &enums } }}, .{ .int = 1 });
}

test "list equality adapts nested protobuf wrappers" {
    const message = value.Message{ .type_name = "google.protobuf.Int64Value", .data = "\x08\x01" };
    const wrapped = [_]Value{.{ .message = &message }};
    const integer = [_]Value{.{ .int = 1 }};
    const items = [_]Value{ .{ .list = &wrapped }, .{ .list = &integer } };
    try expectExpression("items.distinct().size() == 1 && items[0] == items[1]", &.{
        .{ .name = "items", .value = .{ .list = &items } },
    }, .{ .bool = true });
}

test "list extensions enforce collection depth and comparison budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "lists.range(3)", "[[1,2],[3]].flatten()" }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{ .max_collection_size = 2 });
        defer program.deinit();
        try std.testing.expectError(error.CollectionLimitExceeded, program.evaluate(arena.allocator(), &.{}));
    }
    var program = try Program.compile(std.testing.allocator, "items.sort() == [] || true", .{ .max_steps = 40 });
    defer program.deinit();
    const items = [_]Value{ .{ .string = "a" ** 100 }, .{ .string = "a" ** 100 } };
    try std.testing.expectError(error.CostLimitExceeded, program.evaluate(arena.allocator(), &.{
        .{ .name = "items", .value = .{ .list = &items } },
    }));
    var cyclic = [_]Value{.null};
    cyclic[0] = .{ .list = &cyclic };
    var flatten = try Program.compile(std.testing.allocator, "items.flatten(9223372036854775807)", .{});
    defer flatten.deinit();
    try std.testing.expectError(error.DepthLimitExceeded, flatten.evaluate(arena.allocator(), &.{
        .{ .name = "items", .value = .{ .list = &cyclic } },
    }));
}

test "protobuf collection equality charges field and unknown byte work" {
    const environment = Environment{ .descriptors = @import("fixtures").schema, .container = "cel.conformance.fixture" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var constructed = try environment.parse(std.testing.allocator, "[TestSchema{name: text}, TestSchema{name: text}].distinct().size() == 1 || true", .{ .max_steps = 64 });
    defer constructed.deinit();
    try std.testing.expectError(error.CostLimitExceeded, constructed.evaluate(arena.allocator(), &.{
        .{ .name = "text", .value = .{ .string = "a" ** 1024 } },
    }));
    const bytes = "\x9a\x06\x80\x08" ++ "a" ** 1024;
    const first = value.Message{ .type_name = "cel.conformance.fixture.TestSchema", .data = bytes };
    const second = value.Message{
        .type_name = first.type_name,
        .data = try arena.allocator().dupe(u8, bytes),
    };
    var unknown = try environment.parse(std.testing.allocator, "a == b || true", .{ .max_steps = 64 });
    defer unknown.deinit();
    try std.testing.expectError(error.CostLimitExceeded, unknown.evaluate(arena.allocator(), &.{
        .{ .name = "a", .value = .{ .message = &first } },
        .{ .name = "b", .value = .{ .message = &second } },
    }));
}

test "list extension allocations clean up through the public API" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{}).compile(gpa, "[lists.range(24), [1,2]].flatten().distinct().sortBy(e,-e).reverse().slice(0,3) == [0,1,2]", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }.run, .{});
}

test "distinct numeric hashing agrees with public CEL value equality" {
    var program = try Program.compile(std.testing.allocator, "items.distinct()", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            var input: [32]Value = undefined;
            for (&input) |*item| {
                const integer = smith.value(i64);
                item.* = switch (smith.value(u8) % 5) {
                    0 => .{ .int = integer },
                    1 => .{ .uint = @bitCast(integer) },
                    2 => .{ .double = @floatFromInt(integer) },
                    3 => .{ .double = smith.value(f64) },
                    else => .{ .bool = integer != 0 },
                };
            }
            var expected: [32]Value = undefined;
            var count: usize = 0;
            outer: for (input) |item| {
                for (expected[0..count]) |previous| if (item.eql(previous)) continue :outer;
                expected[count] = item;
                count += 1;
            }
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const actual = try p.evaluate(arena.allocator(), &.{.{ .name = "items", .value = .{ .list = &input } }});
            try std.testing.expectEqual(count, actual.list.len);
            for (actual.list, expected[0..count]) |a, b| {
                if (a == .double and b == .double and std.math.isNan(a.double) and std.math.isNan(b.double)) continue;
                try std.testing.expect(a.eql(b));
            }
        }
    }.run, .{});
}

test "list extension runtime sorting preserves values and never mutates inputs" {
    var program = try Program.compile(std.testing.allocator, "items.sort().reverse().sort().distinct()", .{});
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(p: *Program, smith: *std.testing.Smith) !void {
            var input: [64]Value = undefined;
            for (&input) |*item| item.* = .{ .int = smith.value(i64) };
            const original = input;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const result = try p.evaluate(arena.allocator(), &.{.{ .name = "items", .value = .{ .list = &input } }});
            try std.testing.expect((Value{ .list = &input }).eql(.{ .list = &original }));
            for (result.list[1..], result.list[0 .. result.list.len - 1]) |item, previous|
                try std.testing.expect(previous.int < item.int);
            for (input) |item| {
                var found = false;
                for (result.list) |out| if (item.eql(out)) {
                    found = true;
                    break;
                };
                try std.testing.expect(found);
            }
        }
    }.run, .{});
}

test "math extension policies preserve numeric types and bitwise permission decisions" {
    const source = "math.greatest(1, 2u, 3.0, -1, 2) == 3.0 && " ++
        "type(math.greatest(1u, 1, 1.0)) == uint && " ++
        "math.least([4, 2u, -1.0]) == -1.0 && math.abs(-12) == 12 && " ++
        "math.round(-1.5) == -2.0 && math.ceil(1.2) == 2.0 && math.floor(-1.2) == -2.0 && " ++
        "math.trunc(-1.2) == -1.0 && math.sign(-2.5) == -1.0 && math.sign(0u) == 0u && " ++
        "math.isFinite(1.0) && math.isNaN(0.0 / 0.0) && math.isInf(1.0 / 0.0) && " ++
        "math.bitAnd(permissions, 3u) == 3u && math.bitOr(1u, 2u) == 3u && " ++
        "math.bitXor(3u, 1u) == 2u && math.bitNot(0u) == 18446744073709551615u";
    const environment = Environment{ .variables = &.{.{ .name = "permissions", .type = .{ .name = "uint" } }} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |checked| {
        var program = if (checked) try environment.compile(std.testing.allocator, source, .{}) else try environment.parse(std.testing.allocator, source, .{});
        defer program.deinit();
        const result = try program.evaluate(arena.allocator(), &.{.{ .name = "permissions", .value = .{ .uint = 7 } }});
        try std.testing.expectEqual(Value{ .bool = true }, result);
    }
}

test "math extrema infer dynamic results when a dynamic argument may win" {
    for ([_][]const u8{ "math.greatest(1, dyn(2.5))", "math.least(dyn(0u), 1)" }) |source| {
        var program = try (Environment{}).compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expect(program.result_type.?.eql(.{ .name = "dyn" }));
    }
}

test "math bit shifts use fixed width logical semantics without undefined behavior" {
    try expectExpression("math.bitShiftLeft(1, 63)", &.{}, .{ .int = std.math.minInt(i64) });
    try expectExpression("math.bitShiftRight(-1, 0)", &.{}, .{ .int = -1 });
    try expectExpression("math.bitShiftRight(-1, 1)", &.{}, .{ .int = std.math.maxInt(i64) });
    try expectExpression("math.bitShiftRight(-1024, 3)", &.{}, .{ .int = 2305843009213693824 });
    for ([_][]const u8{
        "math.bitShiftLeft(-1, 64)",                 "math.bitShiftRight(-1, 64)",
        "math.bitShiftLeft(1, 9223372036854775807)",
    }) |source| try expectExpression(source, &.{}, .{ .int = 0 });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failures = .{
        .{ "math.abs(-9223372036854775808)", error.Overflow },
        .{ "math.bitShiftLeft(1u, -1)", error.InvalidArgument },
        .{ "math.bitShiftRight(1, -1)", error.InvalidArgument },
        .{ "math.ceil(dyn(1))", error.NoMatchingOverload },
        .{ "math.bitAnd(1, 1u)", error.NoMatchingOverload },
        .{ "math.least(dyn([]))", error.InvalidArgument },
        .{ "math.greatest(dyn([1, 'bad']))", error.NoMatchingOverload },
    };
    inline for (failures) |entry| {
        var program = try Program.compile(std.testing.allocator, entry[0], .{});
        defer program.deinit();
        try std.testing.expectError(entry[1], program.evaluate(arena.allocator(), &.{}));
    }
}

test "math extrema and rounding retain NaN and signed zero rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "math.greatest(0.0 / 0.0)", "math.sign(0.0 / 0.0)" }) |source| {
        var program = try (Environment{}).compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expect(std.math.isNan((try program.evaluate(arena.allocator(), &.{})).double));
    }
    for ([_][]const u8{ "math.greatest(1.0, 0.0 / 0.0)", "math.least(0.0 / 0.0, 1.0)" }) |source| {
        var program = try (Environment{}).compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectError(error.InvalidArgument, program.evaluate(arena.allocator(), &.{}));
    }
    var zero = try Program.compile(std.testing.allocator, "math.least(-0.0, 0.0)", .{});
    defer zero.deinit();
    try std.testing.expect(std.math.signbit((try zero.evaluate(arena.allocator(), &.{})).double));
    var sign = try Program.compile(std.testing.allocator, "math.sign(-0.0)", .{});
    defer sign.deinit();
    try std.testing.expect(!std.math.signbit((try sign.evaluate(arena.allocator(), &.{})).double));
}

test "math evaluation obeys work and collection limits before scanning inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    const bindings = [_]Binding{.{ .name = "items", .value = .{ .list = &items } }};
    var small = try Program.compile(std.testing.allocator, "math.greatest(items)", .{ .max_collection_size = 2 });
    defer small.deinit();
    try std.testing.expectError(error.CollectionLimitExceeded, small.evaluate(arena.allocator(), &bindings));
    var limited = try Program.compile(std.testing.allocator, "math.greatest(items) == 3 || true", .{ .max_steps = 4 });
    defer limited.deinit();
    try std.testing.expectError(error.CostLimitExceeded, limited.evaluate(arena.allocator(), &bindings));
}

test "math variadic allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{}).compile(gpa, "math.greatest(1,2,3,4,5,6,7,8) == 8 && math.least([1,2u,-3.5]) == -3.5", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }.run, .{});
}

test "math shifts and extrema stay bounded for untrusted runtime values" {
    var shift = try Program.compile(std.testing.allocator, "math.bitShiftRight(value, shift)", .{});
    defer shift.deinit();
    var maximum = try Program.compile(std.testing.allocator, "math.greatest([value, other])", .{});
    defer maximum.deinit();
    try std.testing.fuzz(.{ &shift, &maximum }, struct {
        fn run(programs: struct { *Program, *Program }, smith: *std.testing.Smith) !void {
            const number = smith.value(i64);
            const offset = smith.value(i64);
            const other = smith.value(u64);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const result = programs[0].evaluate(arena.allocator(), &.{
                .{ .name = "value", .value = .{ .int = number } },
                .{ .name = "shift", .value = .{ .int = offset } },
            });
            if (offset < 0) {
                try std.testing.expectError(error.InvalidArgument, result);
            } else {
                const expected: u64 = if (offset >= 64) 0 else @as(u64, @bitCast(number)) >> @as(u6, @intCast(offset));
                try std.testing.expectEqual(Value{ .int = @bitCast(expected) }, try result);
            }
            const a = Value{ .int = number };
            const b = Value{ .uint = other };
            const selected = try programs[1].evaluate(arena.allocator(), &.{
                .{ .name = "value", .value = a }, .{ .name = "other", .value = b },
            });
            try std.testing.expect(selected.eql(if (a.order(b) == .lt) b else a));
        }
    }.run, .{});
}

test "optional policies distinguish absent null and present values" {
    const source = "optional.of(null).hasValue() && !optional.none().hasValue() && " ++
        "optional.of(null).value() == null && optional.none().orValue(42) == 42 && " ++
        "optional.none().or(optional.of(1)).value() == 1 && " ++
        "optional.of(1).orValue(1 / 0) == 1 && " ++
        "optional.of(1).or(optional.of(1 / 0)).value() == 1 && " ++
        "type(optional.none()) == optional_type";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |checked| {
        var program = if (checked) try (Environment{}).compile(std.testing.allocator, source, .{}) else try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    }
    var missing = try Program.compile(std.testing.allocator, "optional.none().value()", .{});
    defer missing.deinit();
    try std.testing.expectError(error.NoSuchKey, missing.evaluate(arena.allocator(), &.{}));
}

test "optional access and entries preserve presence and laziness" {
    const source = "{'nested': {'value': 3}}.?nested.value.orValue(0) == 3 && " ++
        "{}.?missing.deep[0].orValue(7) == 7 && ![][?0].hasValue() && " ++
        "[?optional.none(), ?optional.of(2), 3] == [2,3] && " ++
        "{?'empty': optional.none(), ?'kept': optional.of(null)} == {'kept': null} && " ++
        "optional.none().optMap(x, 1 / 0).orValue(4) == 4 && " ++
        "optional.of(2).optMap(x, x + 3).value() == 5 && " ++
        "optional.of({'x': 9}).optFlatMap(v, v.?x).value() == 9";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |checked| {
        var program = if (checked) try (Environment{}).compile(std.testing.allocator, source, .{}) else try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    }
}

test "optional zero values and list helpers follow the value domain" {
    const source = "!optional.ofNonZeroValue(null).hasValue() && !optional.ofNonZeroValue(false).hasValue() && " ++
        "!optional.ofNonZeroValue(0).hasValue() && !optional.ofNonZeroValue(0u).hasValue() && " ++
        "!optional.ofNonZeroValue(0.0).hasValue() && !optional.ofNonZeroValue('').hasValue() && " ++
        "!optional.ofNonZeroValue(b'').hasValue() && !optional.ofNonZeroValue([]).hasValue() && " ++
        "!optional.ofNonZeroValue({}).hasValue() && !optional.ofNonZeroValue(duration('0s')).hasValue() && " ++
        "!optional.ofNonZeroValue(timestamp('0001-01-01T00:00:00Z')).hasValue() && " ++
        "optional.ofNonZeroValue(timestamp(0)).hasValue() && optional.ofNonZeroValue(optional.none()).hasValue() && " ++
        "optional.ofNonZeroValue(int).hasValue() && " ++
        "optional.unwrap([optional.of(1),optional.none(),optional.of(2)]) == [1,2] && " ++
        "[optional.none(), optional.of(3)].unwrapOpt() == [3] && " ++
        "[1,2].first().value() == 1 && [1,2].last().value() == 2 && ![].first().hasValue() && " ++
        "optional.of(1).hasValue(1) && !optional.of(1).hasValue(2) && " ++
        "!optional.of(1).hasValue(dyn(optional.of(1))) && " ++
        "optional.none()[1 / 0] == optional.none() && optional.none()[?1 / 0] == optional.none()";
    var program = try (Environment{}).compile(std.testing.allocator, source, .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
}

test "optional checking rejects invalid initializers and checks unreachable defaults" {
    for ([_][]const u8{
        "[?1]",                             "{?'x': 1}",                          "optional.of(1).or(2)", "optional.of(1).orValue('wrong')",
        "optional.none().optFlatMap(v, 1)", "optional.none().optMap(v, missing)", "optional.unwrap([1])", "[1].unwrapOpt()",
        "optional.of(1).hasValue('wrong')",
    }) |source| {
        const result = (Environment{}).compile(std.testing.allocator, source, .{});
        if (std.mem.indexOf(u8, source, "missing") != null) {
            try std.testing.expectError(error.UndeclaredReference, result);
        } else try std.testing.expectError(error.TypeMismatch, result);
    }
    var program = try Program.compile(std.testing.allocator, "optional.of(1).or(2)", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(i64, 1), (try program.evaluate(arena.allocator(), &.{})).optional.?.int);
}

test "optional indexes do not turn invalid keys into absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "[1][?0.5]", "[1][?(0.0/0.0)]" }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectError(error.IndexOutOfBounds, program.evaluate(arena.allocator(), &.{}));
    }
    for ([_][]const u8{ "{}[?null]", "{}[?[]]", "{}[?optional.none()]" }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectError(error.NoMatchingOverload, program.evaluate(arena.allocator(), &.{}));
    }
}

test "optional constants and callbacks own their data and obey limits" {
    const echo = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return args[0];
        }
    }.call;
    const optional_type = Type{ .kind = .abstract, .name = "optional_type", .parameters = &.{.{ .name = "string" }} };
    const input = Value{ .string = "kept" };
    var program = try (Environment{
        .constants = &.{.{ .name = "saved", .value = .{ .optional = &input } }},
        .functions = &.{.{ .name = "echo", .parameters = &.{optional_type}, .result = optional_type, .implementation = echo }},
    }).compile(std.testing.allocator, "echo(saved).value()", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("kept", (try program.evaluate(arena.allocator(), &.{})).string);
    var limited = try Program.compile(std.testing.allocator, "optional.of([1,2])", .{ .max_collection_size = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.CollectionLimitExceeded, limited.evaluate(arena.allocator(), &.{}));
}

test "optional allocation failures release compile and evaluation storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{}).compile(gpa, "{?'nested': optional.of([?optional.of('kept'), ?optional.none()])}.?nested.optMap(v, v[0])", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const result = try program.evaluate(arena.allocator(), &.{});
            try std.testing.expectEqualStrings("kept", result.optional.?.string);
        }
    }.run, .{});
}

test "optional macros evaluate their receiver once and obey lexical scope" {
    const Host = struct {
        calls: usize = 0,
        fn fetch(context: ?*anyopaque, arena: std.mem.Allocator, _: []const Value) EvalError!Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return Value.fromOptional(arena, .{ .int = 2 });
        }
    };
    var host = Host{};
    const optional_int = Type{ .kind = .abstract, .name = "optional_type", .parameters = &.{.{ .name = "int" }} };
    var program = try (Environment{
        .constants = &.{.{ .name = "x", .value = .{ .int = 40 } }},
        .functions = &.{.{ .name = "fetch", .parameters = &.{}, .result = optional_int, .implementation = Host.fetch, .context = &host }},
    }).compile(std.testing.allocator, "fetch().optMap(x, x + .x).value()", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .int = 42 }, try program.evaluate(arena.allocator(), &.{}));
    try std.testing.expectEqual(@as(usize, 1), host.calls);
}

test "optional callback signatures preserve types and reject nullable overlaps" {
    const call = struct {
        fn identity(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return args[0];
        }
    }.identity;
    const parameter = Type{ .kind = .parameter, .name = "T" };
    const optional_int = Type{ .kind = .abstract, .name = "optional_type", .parameters = &.{.{ .name = "int" }} };
    var program = try (Environment{ .functions = &.{.{ .name = "identity", .parameters = &.{parameter}, .result = parameter, .implementation = call }} }).compile(std.testing.allocator, "identity(optional.of(1))", .{});
    defer program.deinit();
    try std.testing.expect(program.result_type.?.eql(optional_int));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(i64, 1), (try program.evaluate(arena.allocator(), &.{})).optional.?.int);
    try std.testing.expectError(error.InvalidDeclaration, (Environment{ .functions = &.{
        .{ .name = "ambiguous", .overload_id = "optional", .parameters = &.{optional_int}, .result = .{ .name = "int" } },
        .{ .name = "ambiguous", .overload_id = "null", .parameters = &.{.{ .name = "null_type" }}, .result = .{ .name = "int" } },
    } }).compile(std.testing.allocator, "true", .{}));
}

test "custom functions evaluate complete checked and unchecked policies" {
    const Host = struct {
        calls: usize = 0,
        fn allowed(context: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            const host: *@This() = @ptrCast(@alignCast(context.?));
            host.calls += 1;
            return .{ .bool = std.mem.eql(u8, args[0].string, "admin") and args[1].int >= 18 };
        }
    };
    var host = Host{};
    const environment = Environment{
        .container = "policy",
        .variables = &.{ .{ .name = "role", .type = .{ .name = "string" } }, .{ .name = "age", .type = .{ .name = "int" } } },
        .functions = &.{.{
            .name = "policy.allowed",
            .parameters = &.{ .{ .name = "string" }, .{ .name = "int" } },
            .result = .{ .name = "bool" },
            .implementation = Host.allowed,
            .context = &host,
        }},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |checked| {
        var program = if (checked) try environment.compile(std.testing.allocator, "age >= 0 && allowed(role, age)", .{}) else try environment.parse(std.testing.allocator, "age >= 0 && allowed(role, age)", .{});
        defer program.deinit();
        if (checked) try std.testing.expect(program.result_type.?.eql(.{ .name = "bool" }));
        for ([_]i64{ 21, 10 }) |age| {
            const result = try program.evaluate(arena.allocator(), &.{
                .{ .name = "role", .value = .{ .string = "admin" } },
                .{ .name = "age", .value = .{ .int = age } },
            });
            try std.testing.expectEqual(Value{ .bool = age >= 18 }, result);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), host.calls);
    try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, "false && allowed(1, 'wrong')", .{}));
}

test "custom generic functions instantiate fresh parameters and abstract result types" {
    const identity = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return args[0];
        }
    }.call;
    const t = Type{ .kind = .parameter, .name = "T" };
    const environment = Environment{ .functions = &.{
        .{ .name = "identity", .parameters = &.{t}, .result = t, .implementation = identity },
        .{ .name = "tuple", .parameters = &.{ t, .{ .kind = .parameter, .name = "U" }, .{ .kind = .parameter, .name = "V" } }, .result = .{ .kind = .abstract, .name = "tuple", .parameters = &.{ t, .{ .kind = .parameter, .name = "U" }, .{ .kind = .parameter, .name = "V" } } } },
        .{ .name = "sort", .parameters = &.{.{ .kind = .abstract, .name = "tuple", .parameters = &.{ t, t, t } }}, .result = .{ .kind = .abstract, .name = "tuple", .parameters = &.{ t, t, t } } },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program = try environment.compile(std.testing.allocator, "identity(1) == 1 && identity('x') == 'x' && identity([1,2]) == [1,2]", .{});
    defer program.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    var generic = try environment.compile(std.testing.allocator, "sort(tuple(dyn(1), 2u, 3.0))", .{});
    defer generic.deinit();
    try std.testing.expect(generic.result_type.?.eql(.{
        .kind = .abstract,
        .name = "tuple",
        .parameters = &.{ .{ .name = "dyn" }, .{ .name = "dyn" }, .{ .name = "dyn" } },
    }));
    try std.testing.expectError(error.MissingFunction, generic.evaluate(arena.allocator(), &.{}));
}

test "custom overloads resolve members and validate runtime signatures" {
    const callbacks = struct {
        fn echo(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return args[0];
        }
        fn adult(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return .{ .bool = args[0].int >= args[1].int };
        }
        fn wrong(_: ?*anyopaque, _: std.mem.Allocator, _: []const Value) EvalError!Value {
            return .{ .string = "wrong" };
        }
        fn failed(_: ?*anyopaque, _: std.mem.Allocator, _: []const Value) EvalError!Value {
            return error.HostFunctionError;
        }
    };
    const environment = Environment{ .container = "policy", .functions = &.{
        .{ .name = "policy.echo", .overload_id = "echo_int", .parameters = &.{.{ .name = "int" }}, .result = .{ .name = "int" }, .implementation = callbacks.echo },
        .{ .name = "policy.echo", .overload_id = "echo_string", .parameters = &.{.{ .name = "string" }}, .result = .{ .name = "string" }, .implementation = callbacks.echo },
        .{ .name = "policy.atLeast", .member = true, .parameters = &.{ .{ .name = "int" }, .{ .name = "int" } }, .result = .{ .name = "bool" }, .implementation = callbacks.adult },
        .{ .name = "wrong", .parameters = &.{}, .result = .{ .name = "bool" }, .implementation = callbacks.wrong },
        .{ .name = "failed", .parameters = &.{}, .result = .{ .name = "bool" }, .implementation = callbacks.failed },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |checked| {
        const source = "echo(1) == 1 && echo('x') == 'x' && echo(dyn('s')) == 's' && " ++
            "(21).atLeast(18) && [1].all(policy, .policy.echo(policy) == 1)";
        var program = if (checked) try environment.compile(std.testing.allocator, source, .{}) else try environment.parse(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        var bad = if (checked) try environment.compile(std.testing.allocator, "wrong()", .{}) else try environment.parse(std.testing.allocator, "wrong()", .{});
        defer bad.deinit();
        try std.testing.expectError(error.NoMatchingOverload, bad.evaluate(arena.allocator(), &.{}));
        var failure = if (checked) try environment.compile(std.testing.allocator, "failed() || true", .{}) else try environment.parse(std.testing.allocator, "failed() || true", .{});
        defer failure.deinit();
        try std.testing.expectError(error.HostFunctionError, failure.evaluate(arena.allocator(), &.{}));
    }
    try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, "echo(true)", .{}));
}

test "checked generic callbacks cannot return a different inferred type" {
    const wrong = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: []const Value) EvalError!Value {
            return .{ .string = "not an integer" };
        }
    }.call;
    const parameter = Type{ .name = "T", .kind = .parameter };
    var program = try (Environment{ .functions = &.{.{
        .name = "identity",
        .parameters = &.{parameter},
        .result = parameter,
        .implementation = wrong,
    }} }).compile(std.testing.allocator, "identity(1)", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NoMatchingOverload, program.evaluate(arena.allocator(), &.{}));
}

test "custom overload backtracking restores empty collection constraints" {
    const call = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return args[1];
        }
    }.run;
    const environment = Environment{ .functions = &.{
        .{ .name = "choose", .overload_id = "strings", .parameters = &.{
            .{ .name = "list", .parameters = &.{.{ .name = "string" }} }, .{ .name = "bool" },
        }, .result = .{ .name = "bool" }, .implementation = call },
        .{ .name = "choose", .overload_id = "integers", .parameters = &.{
            .{ .name = "list", .parameters = &.{.{ .name = "int" }} }, .{ .name = "int" },
        }, .result = .{ .name = "int" }, .implementation = call },
    } };
    var program = try environment.compile(std.testing.allocator, "choose([], 1)", .{});
    defer program.deinit();
    try std.testing.expect(program.result_type.?.eql(.{ .name = "int" }));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .int = 1 }, try program.evaluate(arena.allocator(), &.{}));
}

test "custom callbacks receive public message values and support more than four arguments" {
    const call = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            if (args[0] == .message and args[0].message.native != null) return error.InvalidArgument;
            return args[0];
        }
    }.run;
    const integer = Type{ .name = "int" };
    const message_type = Type{ .name = "google.protobuf.DescriptorProto" };
    const environment = Environment{ .functions = &.{
        .{ .name = "first", .parameters = &.{ integer, integer, integer, integer, integer, integer }, .result = integer, .implementation = call },
        .{ .name = "message", .parameters = &.{message_type}, .result = message_type, .implementation = call },
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first = try environment.compile(std.testing.allocator, "first(1,2,3,4,5,6)", .{});
    defer first.deinit();
    try std.testing.expectEqual(Value{ .int = 1 }, try first.evaluate(arena.allocator(), &.{}));
    var message_program = try environment.compile(std.testing.allocator, "message(google.protobuf.DescriptorProto{name:'kept'}).name", .{});
    defer message_program.deinit();
    try std.testing.expectEqualStrings("kept", (try message_program.evaluate(arena.allocator(), &.{})).string);
}

test "function declarations and costs reject invalid or excessive work" {
    const integer = Type{ .name = "int" };
    const function = Function{ .name = "f", .parameters = &.{integer}, .result = integer };
    try std.testing.expectError(error.InvalidDeclaration, (Environment{ .functions = &.{ function, function } }).compile(std.testing.allocator, "true", .{}));
    var member = function;
    member.member = true;
    member.parameters = &.{};
    try std.testing.expectError(error.InvalidDeclaration, (Environment{ .functions = &.{member} }).compile(std.testing.allocator, "true", .{}));
    var bad_name = function;
    bad_name.name = ".bad";
    try std.testing.expectError(error.InvalidDeclaration, (Environment{ .functions = &.{bad_name} }).compile(std.testing.allocator, "true", .{}));
    try std.testing.expectError(error.DeclarationLimitExceeded, (Environment{ .functions = &.{function} }).compile(std.testing.allocator, "true", .{ .max_source_bytes = 4 }));
    var limited = try (Environment{ .functions = &.{function} }).parse(std.testing.allocator, "f(1) || true", .{ .max_steps = 2 });
    defer limited.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CostLimitExceeded, limited.evaluate(arena.allocator(), &.{}));
}

test "function signatures and callback allocations clean up on every failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn callback(_: ?*anyopaque, arena: std.mem.Allocator, args: []const Value) EvalError!Value {
            return .{ .string = try std.mem.concat(arena, u8, &.{ args[0].string, "!" }) };
        }
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{ .functions = &.{.{
                .name = "greet",
                .parameters = &.{.{ .name = "string" }},
                .result = .{ .name = "string" },
                .implementation = callback,
            }} }).compile(gpa, "greet('hello')", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqualStrings("hello!", (try program.evaluate(arena.allocator(), &.{})).string);
        }
    }.run, .{});
}

test "alpha equivalent and erased generic overloads are rejected" {
    const a = Type{ .name = "T", .kind = .parameter };
    const b = Type{ .name = "U", .kind = .parameter };
    for ([_]Type{ b, .{ .name = "int" }, .{ .name = "dyn" } }) |other| {
        const env = Environment{ .functions = &.{
            .{ .name = "same", .overload_id = "first", .parameters = &.{a}, .result = a },
            .{ .name = "same", .overload_id = "second", .parameters = &.{other}, .result = other },
        } };
        try std.testing.expectError(error.InvalidDeclaration, env.compile(std.testing.allocator, "true", .{}));
    }
}

test "dynamic arguments erase generic runtime constraints" {
    const implementation = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: []const Value) EvalError!Value {
            return .{ .bool = true };
        }
    }.call;
    const t = Type{ .name = "T", .kind = .parameter };
    const env = Environment{ .functions = &.{.{ .name = "same", .parameters = &.{ t, t }, .result = .{ .name = "bool" }, .implementation = implementation }} };
    try std.testing.expectError(error.TypeMismatch, env.compile(std.testing.allocator, "same(1,'x')", .{}));
    var program = try env.compile(std.testing.allocator, "same(dyn(1), 'x')", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
}

test "custom callback collections obey configured size limits" {
    const call = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, _: []const Value) EvalError!Value {
            return .{ .list = &.{ .{ .int = 1 }, .{ .int = 2 } } };
        }
    }.run;
    var program = try (Environment{ .functions = &.{.{
        .name = "items",
        .parameters = &.{},
        .result = .{ .name = "list", .parameters = &.{.{ .name = "int" }} },
        .implementation = call,
    }} }).compile(std.testing.allocator, "items()", .{ .max_collection_size = 1 });
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CollectionLimitExceeded, program.evaluate(arena.allocator(), &.{}));
}

test "optional source and activations stay bounded" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var source: [1024]u8 = undefined;
            const length = smith.slice(&source);
            const environment = Environment{ .variables = &.{.{ .name = "x", .type = .{ .name = "dyn" } }} };
            const limits = Limits{ .max_depth = 64, .max_nodes = 2048, .max_steps = 4096, .max_check_steps = 8192, .max_collection_size = 128 };
            var program = (if (smith.value(bool)) environment.compile(std.testing.allocator, source[0..length], limits) else environment.parse(std.testing.allocator, source[0..length], limits)) catch return;
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const payload = Value{ .map = &.{.{ .key = .{ .string = "y" }, .value = .{ .int = smith.value(i64) } }} };
            const input = Value{ .optional = if (smith.value(bool)) &payload else null };
            _ = program.evaluate(arena.allocator(), &.{.{ .name = "x", .value = input }}) catch return;
        }
    }.run, .{ .corpus = &.{ "\x0f\x00\x00\x00optional.none()", "\x04\x00\x00\x00[?x]" } });
}

test "custom function source and runtime values stay bounded" {
    const callback = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return args[0];
        }
    }.call;
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var source: [1024]u8 = undefined;
            const length = smith.slice(&source);
            const parameter = Type{ .kind = .parameter, .name = "T" };
            const environment = Environment{
                .variables = &.{.{ .name = "x", .type = .{ .name = "dyn" } }},
                .functions = &.{.{ .name = "identity", .parameters = &.{parameter}, .result = parameter, .implementation = callback }},
            };
            const limits = Limits{ .max_depth = 64, .max_nodes = 2048, .max_steps = 4096, .max_check_steps = 8192 };
            var program = (if (smith.value(bool)) environment.compile(std.testing.allocator, source[0..length], limits) else environment.parse(std.testing.allocator, source[0..length], limits)) catch return;
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = program.evaluate(arena.allocator(), &.{.{ .name = "x", .value = .{ .int = smith.value(i64) } }}) catch return;
        }
    }.run, .{ .corpus = &.{ "\x0b\x00\x00\x00identity(x)", "\x0f\x00\x00\x00identity([x,x])" } });
}

test "strong enums preserve identity in checked and unchecked programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "cel.expr.conformance.proto2", "cel.expr.conformance.proto3" }) |container| {
        const environment = Environment{
            .descriptors = @import("fixtures").upstream,
            .container = container,
            .strong_enums = true,
        };
        for ([_]bool{ false, true }) |checked| {
            const source = "type(GlobalEnum.GAZ) == GlobalEnum && " ++
                "GlobalEnum.GAR != GlobalEnum.GAZ && int(GlobalEnum.GAZ) == 2 && " ++
                "TestAllTypes.NestedEnum('BAR') == TestAllTypes.NestedEnum(1) && " ++
                "int(TestAllTypes{}.standalone_enum) == 0 && " ++
                "TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.BAZ}.standalone_enum == " ++
                "TestAllTypes.NestedEnum.BAZ";
            var program = if (checked) try environment.compile(std.testing.allocator, source, .{}) else try environment.parse(std.testing.allocator, source, .{});
            defer program.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }
}

test "strong enum constructors enforce input types and signed 32 bit bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const environment = Environment{
        .descriptors = @import("fixtures").upstream,
        .container = "cel.expr.conformance.proto3",
        .strong_enums = true,
    };
    const enum_name = "cel.expr.conformance.proto3.GlobalEnum";
    for ([_][]const u8{ "GlobalEnum(2147483647)", "GlobalEnum(-2147483648)", "GlobalEnum(-33)" }, [_]i32{ 2147483647, -2147483648, -33 }) |source, number| {
        for ([_]bool{ false, true }) |checked| {
            var program = if (checked) try environment.compile(std.testing.allocator, source, .{}) else try environment.parse(std.testing.allocator, source, .{});
            defer program.deinit();
            if (checked) try std.testing.expect(program.result_type.?.eql(.{ .name = enum_name }));
            const result = try program.evaluate(arena.allocator(), &.{});
            try std.testing.expectEqualStrings(enum_name, result.enum_value.type_name);
            try std.testing.expectEqual(number, result.enum_value.number);
        }
    }
    const invalid = .{
        .{ "GlobalEnum(2147483648)", error.Overflow },
        .{ "GlobalEnum(-2147483649)", error.Overflow },
        .{ "GlobalEnum('missing')", error.InvalidArgument },
        .{ "GlobalEnum('GlobalEnum.GAZ')", error.InvalidArgument },
        .{ "GlobalEnum('GAZ\\x00')", error.InvalidArgument },
    };
    inline for (invalid) |case| {
        for ([_]bool{ false, true }) |checked| {
            var program = if (checked) try environment.compile(std.testing.allocator, case[0], .{}) else try environment.parse(std.testing.allocator, case[0], .{});
            defer program.deinit();
            try std.testing.expectError(case[1], program.evaluate(arena.allocator(), &.{}));
        }
    }
    for ([_][]const u8{
        "GlobalEnum(true)",                                     "GlobalEnum(1u)",                   "GlobalEnum(1.0)",                               "GlobalEnum(null)",
        "GlobalEnum()",                                         "GlobalEnum(1, 2)",                 "GlobalEnum(GlobalEnum.GAR)",                    "GlobalEnum.GAR + GlobalEnum.GAZ",
        "GlobalEnum.GAR < GlobalEnum.GAZ",                      "uint(GlobalEnum.GAR)",             "double(GlobalEnum.GAR)",                        "string(GlobalEnum.GAR)",
        "{GlobalEnum.GAR: 1}",                                  "TestAllTypes{standalone_enum: 1}", "TestAllTypes{standalone_enum: GlobalEnum.GAR}", "TestAllTypes{repeated_nested_enum: [1]}",
        "TestAllTypes{map_string_enum: {'x': GlobalEnum.GAR}}",
    }) |source| {
        try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, source, .{}));
        var program = try environment.parse(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectError(error.NoMatchingOverload, program.evaluate(arena.allocator(), &.{}));
    }
    for ([_][]const u8{ "GlobalEnum.GAR == 1", "GlobalEnum.GAR == TestAllTypes.NestedEnum.BAR", "GlobalEnum.GAR in [1]" }) |source| {
        try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, source, .{}));
        var program = try environment.parse(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectEqual(Value{ .bool = false }, try program.evaluate(arena.allocator(), &.{}));
    }
}

test "enum constants cannot impersonate primitive message or unregistered types" {
    for ([_][]const u8{ "int", "google.protobuf.DescriptorProto", "missing.Enum" }) |type_name| {
        const forged = value.EnumValue{ .type_name = type_name, .number = 1 };
        const items = [_]Value{.{ .enum_value = &forged }};
        const entries = [_]value.Entry{.{ .key = .{ .string = "nested" }, .value = .{ .list = &items } }};
        for ([_]Value{ .{ .enum_value = &forged }, .{ .map = &entries } }) |constant| {
            const environment = Environment{
                .strong_enums = true,
                .constants = &.{.{ .name = "fake", .value = constant }},
            };
            try std.testing.expectError(error.InvalidDeclaration, environment.compile(std.testing.allocator, "fake", .{}));
            try std.testing.expectError(error.InvalidDeclaration, environment.parse(std.testing.allocator, "fake", .{}));
        }
    }
}

test "strong enum declarations collections and namespace resolution retain their types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const enum_name = "cel.expr.conformance.proto3.TestAllTypes.NestedEnum";
    const environment = Environment{
        .descriptors = @import("fixtures").upstream,
        .container = "cel.expr.conformance.proto3.deeper",
        .strong_enums = true,
        .variables = &.{.{ .name = "e", .type = .{ .name = enum_name } }},
    };
    const input = value.EnumValue{ .type_name = enum_name, .number = 1 };
    const bindings = [_]Binding{.{ .name = "e", .value = .{ .enum_value = &input } }};
    const source = "[e].all(v, v == TestAllTypes.NestedEnum.BAR) && " ++
        "TestAllTypes{repeated_nested_enum: [e, TestAllTypes.NestedEnum.FOO]}.repeated_nested_enum == " ++
        "[TestAllTypes.NestedEnum.BAR, TestAllTypes.NestedEnum.FOO] && " ++
        "TestAllTypes{map_string_enum: {'x': e}}.map_string_enum['x'] == e && " ++
        "type(e) == .cel.expr.conformance.proto3.TestAllTypes.NestedEnum && " ++
        ".cel.expr.conformance.proto3.TestAllTypes.NestedEnum(1) == e && " ++
        "[e].map(x, int(x)) == [1] && [e].map(x, [x]).size() == 1 && " ++
        "[{}].map(TestAllTypes, TestAllTypes.NestedEnum(1)) == [e] && " ++
        "[7].map(GlobalEnum, int(GlobalEnum(1)) + GlobalEnum) == [8]";
    for ([_]bool{ false, true }) |checked| {
        var program = if (checked) try environment.compile(std.testing.allocator, source, .{}) else try environment.parse(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &bindings));
    }
    var identity = try environment.compile(std.testing.allocator, "[e]", .{});
    defer identity.deinit();
    try std.testing.expect(identity.result_type.?.eql(.{ .name = "list", .parameters = &.{.{ .name = enum_name }} }));
    var lookup = try environment.compile(std.testing.allocator, "TestAllTypes.NestedEnum.BAR", .{});
    defer lookup.deinit();
    const result = try lookup.evaluate(arena.allocator(), &.{.{ .name = enum_name ++ ".BAR", .value = .{ .int = 99 } }});
    try std.testing.expect(result.eql(.{ .enum_value = &input }));
}

test "protobuf construction retains message types field defaults and presence" {
    var program = try (Environment{}).compile(std.testing.allocator, "google.protobuf.DescriptorProto{name: 'Entry'}.name == 'Entry' && " ++
        "!has(google.protobuf.DescriptorProto{}.name) && " ++
        "google.protobuf.DescriptorProto{}.field == []", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(program.result_type.?.eql(.{ .name = "bool" }));
    try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    var identity = try (Environment{}).compile(std.testing.allocator, "google.protobuf.DescriptorProto{name:'Entry'}", .{});
    defer identity.deinit();
    try std.testing.expect(identity.result_type.?.eql(.{ .name = "google.protobuf.DescriptorProto" }));
    const result = try identity.evaluate(arena.allocator(), &.{});
    try std.testing.expect(result == .message);
    try std.testing.expectEqualStrings("google.protobuf.DescriptorProto", result.message.type_name);
    try std.testing.expectEqualSlices(u8, "\x0a\x05Entry", result.message.data);
}

test "protobuf messages are not maps and reject unknown or mistyped fields" {
    try std.testing.expectError(error.UnsupportedType, (Environment{}).compile(std.testing.allocator, "unknown.Message{}", .{}));
    try std.testing.expectError(error.TypeMismatch, (Environment{}).compile(std.testing.allocator, "google.protobuf.DescriptorProto{name: 1}", .{}));
    try std.testing.expectError(error.TypeMismatch, (Environment{}).compile(std.testing.allocator, "google.protobuf.DescriptorProto{missing: 1}", .{}));
    try expectExpression("google.protobuf.DescriptorProto{} != {}", &.{}, .{ .bool = true });
    try expectExpression("google.protobuf.DescriptorProto{} == google.protobuf.DescriptorProto{}", &.{}, .{ .bool = true });
}

test "registered proto3 messages preserve maps lists oneofs and optional presence" {
    const fixture = @import("fixtures").schema;
    const environment = Environment{ .descriptors = fixture, .container = "cel.conformance.fixture" };
    var program = try environment.compile(std.testing.allocator, "TestSchema{signed_value: 12, unsigned_value: 18446744073709551615u, float_value: 1.5, " ++
        "nested: TestSchema.Nested{value:'inside'}, values:[1,2], counts:{'x':3}, optional_value:'', " ++
        "name:'selected', status:TestSchema.Status.STATUS_READY}", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try program.evaluate(arena.allocator(), &.{});
    try std.testing.expect(result == .message);
    try std.testing.expect(result.message.native == null);
    var read = try (Environment{
        .descriptors = fixture,
        .variables = &.{.{ .name = "m", .type = .{ .name = "cel.conformance.fixture.TestSchema" } }},
    }).compile(std.testing.allocator, "m.signed_value == 12 && m.unsigned_value == 18446744073709551615u && m.float_value == 1.5 && " ++
        "m.nested.value == 'inside' && m.values == [1,2] && m.counts['x'] == 3 && " ++
        "has(m.optional_value) && has(m.name) && !has(m.code) && m.status == 1", .{});
    defer read.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try read.evaluate(arena.allocator(), &.{.{ .name = "m", .value = result }}));
    var absent = try environment.compile(std.testing.allocator, "!has(TestSchema{}.optional_value) && TestSchema{}.nested.value == '' && " ++
        "!has(TestSchema{}.values) && !has(TestSchema{}.counts)", .{});
    defer absent.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try absent.evaluate(arena.allocator(), &.{}));
}

test "descriptor and protobuf limits reject malformed external data" {
    try std.testing.expectError(error.InvalidDescriptor, (Environment{ .descriptors = "bad descriptor bytes" }).compile(std.testing.allocator, "true", .{}));
    const fixture = @import("fixtures").schema;
    try std.testing.expectError(error.ProtobufLimitExceeded, (Environment{ .descriptors = fixture }).compile(std.testing.allocator, "true", .{ .protobuf = .{ .max_files = 0 } }));
    var program = try (Environment{ .descriptors = fixture }).compile(std.testing.allocator, "cel.conformance.fixture.TestSchema{signed_value:2147483648}", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Overflow, program.evaluate(arena.allocator(), &.{}));
    var invalid = try (Environment{ .descriptors = fixture }).parse(std.testing.allocator, "m.signed_value", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidArgument, invalid.evaluate(arena.allocator(), &.{.{ .name = "m", .value = .{
        .message = &.{ .type_name = "cel.conformance.fixture.TestSchema", .data = "\x80" },
    } }}));
}

test "protobuf well-known values follow CEL unboxing and null semantics" {
    const environment = Environment{ .descriptors = @import("fixtures").upstream, .container = "cel.expr.conformance.proto3" };
    for ([_][]const u8{
        "google.protobuf.Int64Value{value:42} == 42",
        "google.protobuf.BoolValue{} == false",
        "TestAllTypes{}.single_int64_wrapper == null",
        "TestAllTypes{single_int64_wrapper:42}.single_int64_wrapper == 42",
        "TestAllTypes{single_struct:{'x':1}}.single_struct.x == 1",
        "TestAllTypes{single_value:'text'}.single_value == 'text'",
        "TestAllTypes{single_any:TestAllTypes{single_int64:42}}.single_any.single_int64 == 42",
        "TestAllTypes{repeated_int32_wrapper:[1,null]}.repeated_int32_wrapper == [1]",
        "TestAllTypes{repeated_any:[1,null]}.repeated_any == [1,null]",
        "TestAllTypes{map_bool_int32_wrapper:{true:null,false:1}}.map_bool_int32_wrapper == {false:1}",
    }) |source| {
        var program = try environment.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    }
}

test "temporal policies preserve nanoseconds arithmetic and canonical types" {
    const cases = [_][]const u8{
        "timestamp('2009-02-13T23:00:00Z') + duration('240s') == timestamp('2009-02-13T23:04:00Z')",
        "duration('1m') + timestamp('2009-02-13T23:00:00Z') == timestamp('2009-02-13T23:01:00Z')",
        "timestamp('0001-01-01T00:00:01.000000001Z') + duration('-999999999ns') == timestamp('0001-01-01T00:00:00.000000002Z')",
        "timestamp('2009-02-13T23:31:00Z') - timestamp('2009-02-13T23:29:00Z') == duration('120s')",
        "duration('1h30m') - duration('30m') == duration('3600s')",
        "int(timestamp('2009-02-13T23:31:30Z')) == 1234567890",
        "string(timestamp('9999-12-31T23:59:59.999999999Z')) == '9999-12-31T23:59:59.999999999Z'",
        "string(duration('1m1ms')) == '60.001s'",
        "type(timestamp(0)) == google.protobuf.Timestamp && type(duration('0')) == google.protobuf.Duration",
        "timestamp(timestamp(0)) == timestamp('1970-01-01T00:00:00Z')",
        "duration(duration('1h')) == duration('3600s')",
        "duration('1.234s').getMilliseconds() == 234 && duration('-1.234s').getMilliseconds() == -234",
        "duration('-3730s').getMinutes() == -62",
        "duration('-0h9223372036854775808ns') == duration('-9223372036.854775808s')",
        "duration('1.5ns') == duration('1ns') && duration('-1.5ns') == duration('-1ns')",
        "timestamp('2009-02-14T01:31:30+02:00') == timestamp('2009-02-13T23:31:30Z')",
        "timestamp('2024-03-01T00:00:00Z').getDayOfYear() == 60",
        "int(timestamp('1969-12-31T23:59:59.500Z')) == -1",
    };
    for (cases) |source| {
        var program = try (Environment{}).compile(std.testing.allocator, source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expect(program.result_type.?.eql(.{ .name = "bool" }));
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    }
}

test "timestamp selectors use explicit zones and reject filesystem paths" {
    try expectExpression("timestamp('2009-02-13T23:31:30Z').getDate('Australia/Sydney') == 14", &.{}, .{ .bool = true });
    try expectExpression("timestamp('2009-02-13T23:31:30Z').getHours('02:00') == 1", &.{}, .{ .bool = true });
    try expectExpression("timestamp('2009-02-13T23:31:30Z').getMinutes('Asia/Kathmandu') == 16", &.{}, .{ .bool = true });
    try expectExpression("timestamp('2024-03-10T09:59:59Z').getHours('America/Los_Angeles') == 1 && " ++
        "timestamp('2024-03-10T10:00:00Z').getHours('America/Los_Angeles') == 3", &.{}, .{ .bool = true });
    for ([_][]const u8{
        "timestamp('2000-02-30T00:00:00Z')",      "duration('1d')",                          "duration('inf')",
        "timestamp(0).getHours('../etc/passwd')", "timestamp(0).getHours('/etc/localtime')", "timestamp(0).getHours('Not/AZone')",
        "timestamp(0).getHours('+25:00')",        "timestamp(0).getHours('localtime')",      "timestamp(0).getHours('America//New_York')",
    }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidArgument, program.evaluate(arena.allocator(), &.{}));
    }
}

test "temporal boundaries report errors instead of overflowing" {
    for ([_][]const u8{
        "timestamp(-62135596801)",                                               "timestamp(253402300800)",
        "timestamp('9999-12-31T23:59:59.999999999Z') + duration('1ns')",         "timestamp('0001-01-01T00:00:00Z') - duration('1ns')",
        "duration('9223372036854775807ns') + duration('1ns')",                   "duration('-9223372036854775808ns') - duration('1ns')",
        "timestamp('9999-12-31T23:59:59Z') - timestamp('0001-01-01T00:00:00Z')",
    }) |source| {
        var program = try (Environment{}).compile(std.testing.allocator, source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.Overflow, program.evaluate(arena.allocator(), &.{}));
    }
}

test "protobuf temporal fields box values and prune null collection entries" {
    const environment = Environment{ .descriptors = @import("fixtures").upstream, .container = "cel.expr.conformance.proto3" };
    for ([_][]const u8{
        "TestAllTypes{repeated_timestamp:[timestamp(1),null]}.repeated_timestamp == [timestamp(1)]",
        "TestAllTypes{repeated_duration:[duration('1s'),null]}.repeated_duration == [duration('1s')]",
        "TestAllTypes{map_bool_timestamp:{true:null,false:timestamp(1)}}.map_bool_timestamp == {false:timestamp(1)}",
        "TestAllTypes{map_bool_duration:{true:null,false:duration('1s')}}.map_bool_duration == {false:duration('1s')}",
        "TestAllTypes{single_any:timestamp('2009-02-13T23:31:30Z')}.single_any == timestamp(1234567890)",
        "TestAllTypes{single_value:duration('1m1ms')}.single_value == '60.001s'",
    }) |source| {
        var program = try environment.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
    }
}

test "checked environments infer types and reject unreachable type errors" {
    const environment = Environment{ .variables = &.{
        .{ .name = "user", .type = .{ .name = "map", .parameters = &.{ .{ .name = "string" }, .{ .name = "dyn" } } } },
    } };
    var program = try environment.compile(std.testing.allocator, "user.active && user.age >= 18", .{});
    defer program.deinit();
    try std.testing.expect(program.result_type.?.eql(.{ .name = "bool" }));
    try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, "false && (1 + 'x' == 2)", .{}));
    try std.testing.expectError(error.UndeclaredReference, environment.compile(std.testing.allocator, "false && missing", .{}));
    try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, "1 == 1u", .{}));
    try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, "true ? 1 : 'x'", .{}));
    var dynamic = try environment.compile(std.testing.allocator, "dyn(1) + 1", .{});
    defer dynamic.deinit();
    try std.testing.expect(dynamic.result_type.?.eql(.{ .name = "int" }));
}

test "checked type values compare independently of their described types" {
    for ([_][]const u8{ "type(1) == type(1u)", "type([1]) == type(['x'])", "type(type(1)) == type(type('x'))" }) |source| {
        var program = try (Environment{}).compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expect(program.result_type.?.eql(.{ .name = "bool" }));
    }
}

test "checked collection inference unifies empty and nested lists" {
    var list = try (Environment{}).compile(std.testing.allocator, "[[], [[]], [[[]]]]", .{});
    defer list.deinit();
    const dyn_type = Type{ .name = "dyn" };
    const l1 = Type{ .name = "list", .parameters = &.{dyn_type} };
    const l2 = Type{ .name = "list", .parameters = &.{l1} };
    const l3 = Type{ .name = "list", .parameters = &.{l2} };
    try std.testing.expect(list.result_type.?.eql(.{ .name = "list", .parameters = &.{l3} }));
    var transformed = try (Environment{}).compile(std.testing.allocator, "[1, 2].transformMap(i, v, string(v))", .{});
    defer transformed.deinit();
    try std.testing.expect(transformed.result_type.?.eql(.{
        .name = "map",
        .parameters = &.{ .{ .name = "int" }, .{ .name = "string" } },
    }));
    try std.testing.expectError(error.TypeMismatch, (Environment{}).compile(std.testing.allocator, "[].map(x, [x + 1, x + 'a'])", .{}));
    var meta = try (Environment{}).compile(std.testing.allocator, "type([1])", .{});
    defer meta.deinit();
    try std.testing.expect(meta.result_type.?.eql(.{
        .name = "type",
        .parameters = &.{.{ .name = "list", .parameters = &.{.{ .name = "int" }} }},
    }));
}

test "flat aggregate inference does not turn type variable links into nesting" {
    var empty = try (Environment{}).compile(std.testing.allocator, "[" ++ ("[]," ** 512) ++ "[]]", .{});
    defer empty.deinit();
    try std.testing.expect(empty.result_type.?.eql(.{ .name = "list", .parameters = &.{
        .{ .name = "list", .parameters = &.{.{ .name = "dyn" }} },
    } }));
    var bound = try (Environment{}).compile(std.testing.allocator, "[[1]," ++ ("[]," ** 512) ++ "[]]", .{});
    defer bound.deinit();
    try std.testing.expect(bound.result_type.?.eql(.{ .name = "list", .parameters = &.{
        .{ .name = "list", .parameters = &.{.{ .name = "int" }} },
    } }));
}

test "failed aggregate joins do not retain speculative variable constraints" {
    var program = try (Environment{}).compile(std.testing.allocator, "[].map(x, [{x: 1}, {'a': true}, x + 1])", .{});
    defer program.deinit();
    try std.testing.expect(program.result_type.?.eql(.{ .name = "list", .parameters = &.{
        .{ .name = "list", .parameters = &.{.{ .name = "dyn" }} },
    } }));
}

test "environment validation and inference budgets fail through the public API" {
    try std.testing.expectError(error.InvalidDeclaration, (Environment{ .container = "a..b" }).compile(std.testing.allocator, "1", .{}));
    try std.testing.expectError(error.InvalidDeclaration, (Environment{
        .variables = &.{.{ .name = "x", .type = .{ .name = "int" } }},
        .constants = &.{.{ .name = "x", .value = .{ .int = 1 } }},
    }).compile(std.testing.allocator, "x", .{}));
    try std.testing.expectError(error.UnsupportedType, (Environment{
        .variables = &.{.{ .name = "x", .type = .{ .name = "not.registered" } }},
    }).compile(std.testing.allocator, "true", .{}));
    try std.testing.expectError(error.CheckLimitExceeded, (Environment{}).compile(std.testing.allocator, "[1, 2, 3].map(x, x * 2)", .{ .max_check_steps = 4 }));
    try std.testing.expectError(error.DeclarationLimitExceeded, (Environment{ .constants = &.{.{ .name = "x", .value = .{ .string = "a" ** 32 } }} })
        .compile(std.testing.allocator, "x", .{ .max_source_bytes = 16 }));
}

test "environments resolve namespace prefixes and own constants" {
    var source = [_]u8{ 'o', 'k' };
    var program = try (Environment{
        .container = "acme.policy",
        .variables = &.{.{ .name = "acme.user", .type = .{ .name = "string" } }},
        .constants = &.{.{ .name = "acme.policy.allowed", .value = .{ .string = &source } }},
    }).compile(std.testing.allocator, "user == allowed && .acme.user == 'ok'", .{});
    defer program.deinit();
    @memset(&source, 'x');
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{
        .{ .name = "acme.user", .value = .{ .string = "ok" } },
        .{ .name = "acme.policy.allowed", .value = .{ .string = "overridden" } },
    }));
    var unchecked = try (Environment{ .container = "acme.policy" }).parse(std.testing.allocator, "user", .{});
    defer unchecked.deinit();
    try std.testing.expect(unchecked.result_type == null);
    const resolved = try unchecked.evaluate(arena.allocator(), &.{
        .{ .name = "user", .value = .{ .int = 1 } },
        .{ .name = "acme.user", .value = .{ .int = 2 } },
        .{ .name = "acme.policy.user", .value = .{ .int = 3 } },
    });
    try std.testing.expectEqual(Value{ .int = 3 }, resolved);
}

test "checked selection cannot be redirected by undeclared qualified bindings" {
    var program = try (Environment{ .variables = &.{
        .{ .name = "request", .type = .{ .name = "map", .parameters = &.{ .{ .name = "string" }, .{ .name = "bool" } } } },
    } }).compile(std.testing.allocator, "request.allowed", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = false }, try program.evaluate(arena.allocator(), &.{
        .{ .name = "request", .value = .{ .map = &.{.{ .key = .{ .string = "allowed" }, .value = .{ .bool = false } }} } },
        .{ .name = "request.allowed", .value = .{ .bool = true } },
    }));
}

test "evaluate request authorization with nested inputs and a reusable program" {
    var program = try Program.compile(std.testing.allocator, "request.user.active && request.user.age >= 18 && 'admin' in request.roles", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ true, false, true }) |active| {
        const user = [_]value.Entry{
            .{ .key = .{ .string = "active" }, .value = .{ .bool = active } },
            .{ .key = .{ .string = "age" }, .value = .{ .int = 21 } },
        };
        const roles = [_]Value{.{ .string = "admin" }};
        const request = [_]value.Entry{
            .{ .key = .{ .string = "user" }, .value = .{ .map = &user } },
            .{ .key = .{ .string = "roles" }, .value = .{ .list = &roles } },
        };
        const result = try program.evaluate(arena.allocator(), &.{
            .{ .name = "request", .value = .{ .map = &request } },
        });
        try std.testing.expectEqual(Value{ .bool = active }, result);
    }
}

test "evaluate scalar arithmetic precedence and CEL numeric types" {
    try expectExpression("1 + 2 * 3 == 7 && (10 - 2) / 4 == 2", &.{}, .{ .bool = true });
    try expectExpression("-7 / 3 == -2 && -7 % 3 == -1", &.{}, .{ .bool = true });
    try expectExpression("0xffu + 1u", &.{}, .{ .uint = 256 });
    try expectExpression("1.5 * 2.0 + 1e1", &.{}, .{ .double = 13 });
    try expectExpression("9223372036854775807 < 9223372036854775808u", &.{}, .{ .bool = true });
    try expectExpression("9007199254740993 == 9007199254740992.0 && 9007199254740993 != 9007199254740994.0", &.{}, .{ .bool = true });
    try expectExpression("-9223372036854775808", &.{}, .{ .int = std.math.minInt(i64) });
}

test "boolean ordering and mixed numeric comparisons follow CEL" {
    try expectExpression("false < true && true > false && false <= false", &.{}, .{ .bool = true });
    try expectExpression("18446744073709551615u == 18446744073709551616.0 && 18446744073709551615u < 18446744073709555712.0", &.{}, .{ .bool = true });
    try expectExpression("0.0 / 0.0 != 0.0 / 0.0", &.{}, .{ .bool = true });
    try expectExpression("!(0.0 / 0.0 < 1.0)", &.{}, .{ .bool = true });
}

test "evaluate collections and string operations" {
    try expectExpression("{'x': [1, 2, 3]}['x'][1]", &.{}, .{ .int = 2 });
    try expectExpression("'hello'.startsWith('he') && 'hello'.endsWith('lo')", &.{}, .{ .bool = true });
    try expectExpression("'世界'.size() == 2 && size([1, 2]) == 2", &.{}, .{ .bool = true });
    try expectExpression("[1, 2] + [3] == [1, 2, 3]", &.{}, .{ .bool = true });
    try expectExpression("'a\\nb' == \"a\\nb\"", &.{}, .{ .bool = true });
    try expectExpression("b'abc' == b'abc'", &.{}, .{ .bool = true });
    try expectExpression("{'x': 1} == {'x': 1u}", &.{}, .{ .bool = true });
}

test "quoted field selection supports punctuation without admitting quoted calls or identifiers" {
    try expectExpression("{'/api/v1': 42}.`/api/v1`", &.{}, .{ .int = 42 });
    try expectExpression("{'content-type': 'json'}.`content-type`", &.{}, .{ .string = "json" });
    try expectExpression("{'foo.txt': 32}.`foo.txt`", &.{}, .{ .int = 32 });
    try expectExpression("{'a b/1-x._': true}.`a b/1-x._`", &.{}, .{ .bool = true });
    try expectExpression("has({'true': null}.`true`) && !has({}.`missing-field`)", &.{}, .{ .bool = true });
    for ([_][]const u8{
        "`name`",           "{}.``",         "{}.`unclosed", "{}.`new\nline`",
        "{}.`emoji🐱`",
        "{}.`back\\slash`", "{}.`method`()", "{}.true",      "{}.false",
        "{}.null",
    }) |source| {
        try std.testing.expectError(error.InvalidSyntax, Program.compile(std.testing.allocator, source, .{}));
    }
}

test "upstream string escapes conversions and numeric indexing" {
    try expectExpression("bytes('\\377') == b'\\377'", &.{}, .{ .bool = false });
    try expectExpression("'\\xff' == '\\u00ff'", &.{}, .{ .bool = true });
    try expectExpression("'\\`'", &.{}, .{ .string = "`" });
    try expectExpression("bool('1') && bool('t') && bool('TRUE') && bool('True')", &.{}, .{ .bool = true });
    try expectExpression("!bool('0') && !bool('f') && !bool('FALSE') && !bool('False')", &.{}, .{ .bool = true });
    try expectExpression("[7, 8, 9][dyn(0.0)] == 7 && [7, 8, 9][dyn(0u)] == 7", &.{}, .{ .bool = true });
}

test "logical operators suppress errors only when the result is determined" {
    try expectExpression("false && missing", &.{}, .{ .bool = false });
    try expectExpression("missing && false", &.{}, .{ .bool = false });
    try expectExpression("true || 1 / 0 == 1", &.{}, .{ .bool = true });
    try expectExpression("1 / 0 == 1 || true", &.{}, .{ .bool = true });
    try expectExpression("true ? 42 : missing", &.{}, .{ .int = 42 });
    try expectExpression("has({'x': null}.x) && !has({}.x)", &.{}, .{ .bool = true });
}

test "evaluate collection macros with lexical scope" {
    try expectExpression("[1, 2, 3].all(x, x > 0)", &.{}, .{ .bool = true });
    try expectExpression("[1, 2, 3].exists(x, x == 2)", &.{}, .{ .bool = true });
    try expectExpression("[1, 2, 3].exists_one(x, x > 1)", &.{}, .{ .bool = false });
    try expectExpression("[1, 2, 3].filter(x, x > 1).map(x, x * 2) == [4, 6]", &.{}, .{ .bool = true });
    try expectExpression("[1, 2, 3].map(x, x > 1, x * 2) == [4, 6]", &.{}, .{ .bool = true });
    try expectExpression("[1, 2].all(x, [2, 3].exists(y, y > x))", &.{}, .{ .bool = true });
}

test "two variable comprehensions preserve keys scope and error semantics" {
    try expectExpression("[1, 2, 3].all(i, v, i < v)", &.{}, .{ .bool = true });
    try expectExpression("[1, 2, 3].exists(i, v, v / i == 2)", &.{}, .{ .bool = true });
    try expectExpression("[1, 2, 3].all(i, v, v / i == 2)", &.{}, .{ .bool = false });
    try expectExpression("[5, 7, 8].existsOne(i, v, v % 5 == i)", &.{}, .{ .bool = true });
    try expectExpression("[5, 7, 8].exists_one(i, v, v % 5 == i)", &.{}, .{ .bool = true });
    try expectExpression("[2, 4, 6].transformList(i, v, i != 1, v / 2 + i) == [1, 5]", &.{}, .{ .bool = true });
    try expectExpression("[2, 4, 6].transformMap(i, v, i != 1, v * 2) == {0: 4, 2: 12}", &.{}, .{ .bool = true });
    try expectExpression("{'x': 1, 'y': 2}.transformMap(k, v, v > 1, v + 3) == {'y': 5}", &.{}, .{ .bool = true });
    try expectExpression("{'x': 1}.transformList(k, v, k + string(v)) == ['x1']", &.{}, .{ .bool = true });
    try expectExpression("[2].transformList(i, v, [3].transformList(i, v, i + v)[0] + v) == [5]", &.{}, .{ .bool = true });
    try expectExpression("[].all(i, v, missing) && ![].exists(i, v, missing)", &.{}, .{ .bool = true });
    try expectExpression("{}.transformMap(k, v, missing) == {}", &.{}, .{ .bool = true });
    try expectExpression("[1, 2].transformMapEntry(i, v, {v: i}) == {1: 0, 2: 1}", &.{}, .{ .bool = true });
    try expectExpression("[1, 2].transformMapEntry(i, v, i > 0, {v: i}) == {2: 1}", &.{}, .{ .bool = true });
    try expectExpression("[1, 2].transformMapEntry(i, v, {}) == {}", &.{}, .{ .bool = true });
    for ([_][]const u8{
        "[].all(x, x, true)", "[].all(1, x, true)", "[].transformList(i, 3, i)",
    }) |source| {
        try std.testing.expectError(error.InvalidSyntax, Program.compile(std.testing.allocator, source, .{}));
    }
    const faults = .{
        .{ "[1, 2].existsOne(i, v, v / i > 0)", error.DivisionByZero },
        .{ "[1, 2].transformMapEntry(i, v, {1: v})", error.DuplicateKey },
        .{ "[1, 2].transformMapEntry(i, v, v)", error.NoMatchingOverload },
        .{ "42.all(i, v, true)", error.NoMatchingOverload },
        .{ "[].all()", error.NoMatchingOverload },
        .{ "[].map(x)", error.UndeclaredReference },
        .{ "[].existsOne(x, true)", error.UndeclaredReference },
        .{ "[].transformMap(i, v)", error.UndeclaredReference },
        .{ ".has(1)", error.NoMatchingOverload },
        .{ "has()", error.NoMatchingOverload },
        .{ "[1].transformList(i, v, 'not bool', v)", error.NoMatchingOverload },
    };
    inline for (faults) |fault| {
        var program = try Program.compile(std.testing.allocator, fault[0], .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(fault[1], program.evaluate(arena.allocator(), &.{}));
    }
}

test "RE2 matching supports Unicode flags classes anchors and embedded nul" {
    for ([_][]const u8{
        "matches('foobar', 'foo.*')",                   ".matches('foobar', 'foo.*')",
        "'hubba'.matches('ubb')",                       "'grey'.matches('gr(a|e)y')",
        "'banana'.matches('ba(na)*')",
        "'mañana'.matches('a+ñ+a+')",
        "'🐱😀😀'.matches('(a|😀){2}')",
        "'世界'.matches(r'\\p{Han}+')",
        "'ABC'.matches('(?i)^abc$')",                   "'a\\nb'.matches('(?s)^a.b$')",
        "'abc'.matches(r'\\Aabc\\z')",                  "'xabc'.matches('abc$')",
        "!('xabc'.matches('^abc$'))",                   "''.matches('')",
        "'abc123'.matches('[[:alpha:]]+[[:digit:]]+')", "'a\\x00b'.matches('a\\x00b')",
    }) |source| {
        try expectExpression(source, &.{}, .{ .bool = true });
    }
}

test "regex errors remain evaluation errors and obey CEL logical suppression" {
    try expectExpression("false && 'x'.matches('(')", &.{}, .{ .bool = false });
    try expectExpression("'x'.matches('(') || true", &.{}, .{ .bool = true });
    for ([_][]const u8{ "'x'.matches('(')", "'aa'.matches(r'(a)\\1')", "'ab'.matches('a(?=b)')" }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidArgument, program.evaluate(arena.allocator(), &.{}));
    }
}

test "reusable regex policies evaluate independent requests and dynamic patterns" {
    var program = try Program.compile(std.testing.allocator, "request.path.matches('^/v[0-9]+/orders/[a-z]+$') && request.user.matches(pattern)", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "^admin", "^guest", "^admin", "(" }, 0..) |pattern, index| {
        const request = [_]value.Entry{
            .{ .key = .{ .string = "path" }, .value = .{ .string = "/v1/orders/abc" } },
            .{ .key = .{ .string = "user" }, .value = .{ .string = "admin-1" } },
        };
        const bindings = [_]Binding{
            .{ .name = "request", .value = .{ .map = &request } },
            .{ .name = "pattern", .value = .{ .string = pattern } },
        };
        const result = program.evaluate(arena.allocator(), &bindings);
        if (index == 3) {
            try std.testing.expectError(error.InvalidArgument, result);
        } else {
            try std.testing.expectEqual(Value{ .bool = index != 1 }, try result);
        }
        _ = arena.reset(.retain_capacity);
    }
}

test "regex caches and work obey explicit resource limits" {
    try std.testing.expectError(error.RegexLimitExceeded, Program.compile(std.testing.allocator, "'a'.matches('a') && 'b'.matches('b')", .{ .regex = .{ .max_patterns = 1 } }));
    var repeated = try Program.compile(std.testing.allocator, "'a'.matches('a') && 'a'.matches('a') && ['a', 'a'].all(p, 'a'.matches(p))", .{ .regex = .{ .max_patterns = 1 } });
    defer repeated.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try repeated.evaluate(arena.allocator(), &.{}));
    var dynamic = try Program.compile(std.testing.allocator, "['a', 'a'].all(p, 'a'.matches(p))", .{ .regex = .{ .max_patterns = 1 } });
    defer dynamic.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try dynamic.evaluate(arena.allocator(), &.{}));
    const limits = [_]Limits{
        .{ .regex = .{ .max_patterns = 1 } },
        .{ .regex = .{ .max_pattern_bytes = 0 } },
        .{ .regex = .{ .max_program_size = 1 } },
        .{ .regex = .{ .max_memory_bytes = 1 } },
        .{ .regex = .{ .max_memory_bytes = std.math.maxInt(u64) } },
        .{ .regex = .{ .max_memory_bytes = @intCast(std.math.maxInt(i64)) } },
    };
    for (limits) |limit| {
        var program = try Program.compile(std.testing.allocator, "['a', 'b'].all(p, 'ab'.matches(p)) || true", limit);
        defer program.deinit();
        try std.testing.expectError(error.RegexLimitExceeded, program.evaluate(arena.allocator(), &.{}));
    }
    var limited = try Program.compile(std.testing.allocator, "text.matches('^a+$') || true", .{ .max_steps = 512 });
    defer limited.deinit();
    try std.testing.expectError(error.CostLimitExceeded, limited.evaluate(arena.allocator(), &.{
        .{ .name = "text", .value = .{ .string = "a" ** 256 } },
    }));
}

test "regex programs support concurrent request evaluations" {
    var program = try Program.compile(std.testing.allocator, "path.matches('^/v[0-9]+/orders/[a-z]+$') && user.matches(pattern)", .{});
    defer program.deinit();
    const Worker = struct {
        program: *const Program,
        passed: bool = false,

        fn run(self: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            for (0..100) |i| {
                const result = self.program.evaluate(arena.allocator(), &.{
                    .{ .name = "path", .value = .{ .string = "/v1/orders/abc" } },
                    .{ .name = "user", .value = .{ .string = "admin-1" } },
                    .{ .name = "pattern", .value = .{ .string = if (i % 2 == 0) "^admin" else "^guest" } },
                }) catch return;
                if (!result.eql(.{ .bool = i % 2 == 0 })) return;
                _ = arena.reset(.retain_capacity);
            }
            self.passed = true;
        }
    };
    var workers = [_]Worker{.{ .program = &program }} ** 4;
    var threads: [workers.len]std.Thread = undefined;
    var count: usize = 0;
    {
        defer for (threads[0..count]) |thread| thread.join();
        for (&workers, &threads) |*worker, *thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
            count += 1;
        }
    }
    for (workers) |worker| try std.testing.expect(worker.passed);
}

test "qualified names prefer the longest binding and respect local and absolute scope" {
    const leaf = [_]value.Entry{.{ .key = .{ .string = "c" }, .value = .{ .int = 2 } }};
    const nested = [_]value.Entry{.{ .key = .{ .string = "b" }, .value = .{ .map = &leaf } }};
    const bindings = [_]Binding{
        .{ .name = "a", .value = .{ .map = &nested } },
        .{ .name = "a.b", .value = .{ .map = &leaf } },
        .{ .name = "a.b.c", .value = .{ .int = 3 } },
    };
    try expectExpression("a.b.c", &bindings, .{ .int = 3 });
    try expectExpression("a.b.c", bindings[0..2], .{ .int = 2 });
    try expectExpression("a.b.c", bindings[1..2], .{ .int = 2 });
    try expectExpression("a.b.c", bindings[0..1], .{ .int = 2 });
    try expectExpression(".a.b.c", &bindings, .{ .int = 3 });
    try expectExpression("a.b.`c`", &bindings, .{ .int = 2 });
    try expectExpression("[{'b': {'c': 4}}].all(a, a.b.c == 4 && .a.b.c == 3)", &bindings, .{ .bool = true });
    try expectExpression("[42].all(int, .int(1.0) == 1 && type(int) == .int)", &.{}, .{ .bool = true });
    try std.testing.expectError(error.InvalidSyntax, Program.compile(std.testing.allocator, "[1].all(.x, true)", .{}));
}

test "qualified resolution stays exact when only constants or containers are dotted" {
    const leaf = [_]value.Entry{.{ .key = .{ .string = "c" }, .value = .{ .int = 2 } }};
    const nested = [_]value.Entry{.{ .key = .{ .string = "b" }, .value = .{ .map = &leaf } }};
    const plain = [_]Binding{.{ .name = "a", .value = .{ .map = &nested } }};
    const dotted = [_]Binding{ plain[0], .{ .name = "a.b.c", .value = .{ .int = 3 } } };
    var program = try Program.compile(std.testing.allocator, "a.b.c", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .int = 2 }, try program.evaluate(arena.allocator(), &plain));
    try std.testing.expectEqual(Value{ .int = 3 }, try program.evaluate(arena.allocator(), &dotted));
    try std.testing.expectEqual(Value{ .int = 2 }, try program.evaluate(arena.allocator(), &plain));

    const constants = Environment{ .constants = &.{.{ .name = "a.b.c", .value = .{ .int = 5 } }} };
    var constant_program = try constants.parse(std.testing.allocator, "a.b.c", .{});
    defer constant_program.deinit();
    try std.testing.expectEqual(Value{ .int = 5 }, try constant_program.evaluate(arena.allocator(), &plain));

    const container = Environment{ .container = "google.protobuf" };
    var enum_program = try container.parse(std.testing.allocator, "FieldDescriptorProto.Type.TYPE_STRING", .{});
    defer enum_program.deinit();
    try std.testing.expectEqual(Value{ .int = 9 }, try enum_program.evaluate(arena.allocator(), &.{}));
    try expectExpression("type(ip('10.0.0.1')) == net.IP && google.protobuf.FieldDescriptorProto.Type.TYPE_STRING == 9", &plain, .{ .bool = true });
}

test "type values preserve CEL types without becoming strings" {
    try expectExpression("type(1) == int && type(1u) == uint && type(1.0) == double", &.{}, .{ .bool = true });
    try expectExpression("type(true) == bool && type(null) == null_type", &.{}, .{ .bool = true });
    try expectExpression("type('x') == string && type(b'x') == bytes", &.{}, .{ .bool = true });
    try expectExpression("type([1]) == list && type({1: true}) == map", &.{}, .{ .bool = true });
    try expectExpression("type(type(1)) == type && int != uint && int != 'int'", &.{}, .{ .bool = true });
    try expectExpression("type(type) == type && dyn(int) == int", &.{}, .{ .bool = true });
    try expectExpression("[1].all(int, int == 1)", &.{}, .{ .bool = true });
}

test "invalid expressions and runtime faults return public errors" {
    for ([_][]const u8{ "", "1 +", "[1,", "'unterminated", "a b", "1 @ 2", "has(1)" }) |source| {
        try std.testing.expectError(error.InvalidSyntax, Program.compile(std.testing.allocator, source, .{}));
    }
    const cases = .{
        .{ "1 / 0", error.DivisionByZero },
        .{ "9223372036854775807 + 1", error.Overflow },
        .{ "0u - 1u", error.Overflow },
        .{ "int(-9223372036854775808.0)", error.Overflow },
        .{ "int(9223372036854775808.0)", error.Overflow },
        .{ "1 + 1u", error.NoMatchingOverload },
        .{ "missing", error.UndeclaredReference },
        .{ "{}.missing", error.NoSuchKey },
        .{ "[1][2]", error.IndexOutOfBounds },
        .{ "1 && true", error.NoMatchingOverload },
        .{ "{'x': 1, 'x': 2}", error.DuplicateKey },
    };
    inline for (cases) |case| {
        var program = try Program.compile(std.testing.allocator, case[0], .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(case[1], program.evaluate(arena.allocator(), &.{}));
    }
}

test "resource limits reject excessive work without trapping" {
    try std.testing.expectError(error.SourceLimitExceeded, Program.compile(std.testing.allocator, "true", .{ .max_source_bytes = 3 }));
    try std.testing.expectError(error.DepthLimitExceeded, Program.compile(std.testing.allocator, "((((true))))", .{ .max_depth = 3 }));
    var program = try Program.compile(std.testing.allocator, "[1, 2, 3].all(x, x > 0)", .{ .max_steps = 2 });
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CostLimitExceeded, program.evaluate(arena.allocator(), &.{}));
}

test "collection equality obeys depth and cost budgets" {
    var nested: [8]Value = undefined;
    nested[0] = .{ .list = &.{} };
    for (1..nested.len) |i| nested[i] = .{ .list = nested[i - 1 .. i] };
    var program = try Program.compile(std.testing.allocator, "a == b", .{ .max_depth = 4 });
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bindings = [_]Binding{
        .{ .name = "a", .value = nested[nested.len - 1] },
        .{ .name = "b", .value = nested[nested.len - 1] },
    };
    try std.testing.expectError(error.DepthLimitExceeded, program.evaluate(arena.allocator(), &bindings));
    var bounded = try Program.compile(std.testing.allocator, "a == b", .{ .max_steps = 5 });
    defer bounded.deinit();
    try std.testing.expectError(error.CostLimitExceeded, bounded.evaluate(arena.allocator(), &bindings));
}

test "comprehensions enforce collection and work limits even in logical branches" {
    const items = [_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    const bindings = [_]Binding{.{ .name = "items", .value = .{ .list = &items } }};
    for ([_][]const u8{
        "items.transformList(i, v, v)",
        "items.transformMap(i, v, v)",
        "items.transformMapEntry(i, v, {v: i})",
    }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{ .max_collection_size = 2 });
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.CollectionLimitExceeded, program.evaluate(arena.allocator(), &bindings));
    }
    var limited = try Program.compile(std.testing.allocator, "items.all(i, v, true) || true", .{ .max_steps = 3 });
    defer limited.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CostLimitExceeded, limited.evaluate(arena.allocator(), &bindings));
}

test "untrusted source never traps or leaks" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buffer: [4096]u8 = undefined;
            const len = smith.slice(&buffer);
            var program = Program.compile(std.testing.allocator, buffer[0..len], .{
                .max_nodes = 4096,
                .max_steps = 4096,
                .max_collection_size = 4096,
            }) catch return;
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = program.evaluate(arena.allocator(), &.{}) catch return;
        }
    }.run, .{ .corpus = &.{
        "\x04\x00\x00\x00true",
        "\x09\x00\x00\x00[1, 2, 3]",
        "\x17\x00\x00\x00[1, 2].all(x, x > 0)",
        "\x12\x00\x00\x00math.greatest(1,2)",
        "\x1b\x00\x00\x00lists.range(4).sortBy(x,-x)",
        "\x11\x00\x00\x00cel.bind(x,1,x+x)",
        "\x1b\x00\x00\x00cel.block([1],cel.index(0))",
        "\x0f\x00\x00\x00'abc'.split('')",
        "\x10\x00\x00\x00'%s'.format([1])",
        "\x15\x00\x00\x00base64.decode('Zg==')",
        "\x13\x00\x00\x00proto.getExt(x,a.b)",
        "\x19\x00\x00\x00math.bitShiftRight(-1,63)",
        "\x16\x00\x00\x00math.least([1,2u,3.5])",
    } });
}

test "dynamic RE2 inputs never trap or leak evaluation storage" {
    var program = try Program.compile(std.testing.allocator, "text.matches(pattern)", .{
        .max_steps = 4096,
        .regex = .{ .max_patterns = 1, .max_pattern_bytes = 512, .max_memory_bytes = 65_536, .max_program_size = 512 },
    });
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(compiled: *Program, smith: *std.testing.Smith) !void {
            var pattern: [512]u8 = undefined;
            var text: [512]u8 = undefined;
            const pattern_len = smith.slice(&pattern);
            const text_len = smith.slice(&text);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = compiled.evaluate(arena.allocator(), &.{
                .{ .name = "pattern", .value = .{ .string = pattern[0..pattern_len] } },
                .{ .name = "text", .value = .{ .string = text[0..text_len] } },
            }) catch return;
        }
    }.run, .{ .corpus = &.{ "\x02\x00\x00\x00a+\x04\x00\x00\x00aaaa", "\x01\x00\x00\x00(\x01\x00\x00\x00a" } });
}

test "checking and environment ownership clean up every Zig allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{
                .container = "acme.policy",
                .variables = &.{.{ .name = "acme.items", .type = .{
                    .name = "list",
                    .parameters = &.{.{ .name = "int" }},
                } }},
                .constants = &.{.{ .name = "acme.policy.delta", .value = .{ .int = 1 } }},
            }).compile(gpa, "items.map(x, x + delta) == [2, 3] && 'abc'.matches('^a')", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const result = try program.evaluate(arena.allocator(), &.{
                .{ .name = "acme.items", .value = .{ .list = &.{ .{ .int = 1 }, .{ .int = 2 } } } },
            });
            try std.testing.expectEqual(Value{ .bool = true }, result);
        }
    }.run, .{});
}

test "protobuf ownership cleans up after every Zig allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try (Environment{
                .descriptors = @import("fixtures").schema,
                .container = "cel.conformance.fixture",
            }).compile(gpa, "TestSchema{nested:TestSchema.Nested{value:'kept'},values:[1,2]}", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const result = try program.evaluate(arena.allocator(), &.{});
            try std.testing.expect(result == .message);
            try std.testing.expect(result.message.native == null);
        }
    }.run, .{});
}

test "strong enum protobuf wire values retain identity across independent programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "cel.expr.conformance.proto2", "cel.expr.conformance.proto3" }) |container| {
        const environment = Environment{
            .container = container,
            .descriptors = @import("fixtures").upstream,
            .strong_enums = true,
        };
        const wire = blk: {
            var writer = try environment.compile(std.testing.allocator, "TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.BAZ, " ++
                "repeated_nested_enum: [TestAllTypes.NestedEnum.BAR], " ++
                "map_string_enum: {'x': TestAllTypes.NestedEnum.BAZ}}", .{});
            defer writer.deinit();
            break :blk try writer.evaluate(arena.allocator(), &.{});
        };
        try std.testing.expect(wire.message.native == null);
        var reader_environment = environment;
        reader_environment.variables = &.{.{ .name = "m", .type = .{ .name = wire.message.type_name } }};
        var reader = try reader_environment.compile(std.testing.allocator, "has(m.standalone_enum) && m.standalone_enum == TestAllTypes.NestedEnum.BAZ && " ++
            "m.repeated_nested_enum == [TestAllTypes.NestedEnum.BAR] && " ++
            "m.map_string_enum['x'] == TestAllTypes.NestedEnum.BAZ", .{});
        defer reader.deinit();
        try std.testing.expectEqual(Value{ .bool = true }, try reader.evaluate(arena.allocator(), &.{
            .{ .name = "m", .value = wire },
        }));
    }
    var json_null = try (Environment{ .strong_enums = true }).compile(std.testing.allocator, "google.protobuf.Value{null_value: google.protobuf.NullValue.NULL_VALUE} == null", .{});
    defer json_null.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try json_null.evaluate(arena.allocator(), &.{}));
}

test "strong enum policies share immutable descriptors across concurrent requests" {
    const enum_name = "cel.conformance.fixture.TestSchema.Status";
    var program = try (Environment{
        .container = "cel.conformance.fixture",
        .descriptors = @import("fixtures").schema,
        .strong_enums = true,
        .variables = &.{.{ .name = "status", .type = .{ .name = enum_name } }},
    }).compile(std.testing.allocator, "TestSchema{status: status}.status == TestSchema.Status('STATUS_READY')", .{});
    defer program.deinit();
    const Worker = struct {
        program: *const Program,
        passed: bool = false,

        fn run(self: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            for (0..100) |i| {
                const input = value.EnumValue{ .type_name = enum_name, .number = @intCast(i % 2) };
                const result = self.program.evaluate(arena.allocator(), &.{
                    .{ .name = "status", .value = .{ .enum_value = &input } },
                }) catch return;
                if (!result.eql(.{ .bool = i % 2 == 1 })) return;
                _ = arena.reset(.retain_capacity);
            }
            self.passed = true;
        }
    };
    var workers = [_]Worker{.{ .program = &program }} ** 4;
    var threads: [workers.len]std.Thread = undefined;
    var count: usize = 0;
    {
        defer for (threads[0..count]) |thread| thread.join();
        for (&workers, &threads) |*worker, *thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
            count += 1;
        }
    }
    for (workers) |worker| try std.testing.expect(worker.passed);
}

test "strong enum ownership cleans up after every Zig allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const enum_name = "cel.conformance.fixture.TestSchema.Status";
            const enum_value = value.EnumValue{ .type_name = enum_name, .number = 1 };
            for ([_]bool{ false, true }) |checked| {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const environment = Environment{
                    .descriptors = @import("fixtures").schema,
                    .container = "cel.conformance.fixture",
                    .strong_enums = true,
                    .constants = &.{.{ .name = "saved", .value = .{ .enum_value = &enum_value } }},
                };
                const source = "[saved, TestSchema.Status.STATUS_READY, TestSchema.Status('STATUS_READY'), " ++
                    "TestSchema{status: TestSchema.Status(1)}.status]";
                var program = if (checked) try environment.compile(gpa, source, .{}) else try environment.parse(gpa, source, .{});
                defer program.deinit();
                const result = try program.evaluate(arena.allocator(), &.{});
                try std.testing.expectEqual(@as(usize, 4), result.list.len);
                for (result.list) |item| try std.testing.expect(item.eql(.{ .enum_value = &enum_value }));
            }
        }
    }.run, .{});
}

test "strong enum conversion never traps on untrusted values and wire bytes" {
    var program = try (Environment{
        .descriptors = @import("fixtures").schema,
        .container = "cel.conformance.fixture",
        .strong_enums = true,
        .variables = &.{
            .{ .name = "input", .type = .{ .name = "dyn" } },
            .{ .name = "m", .type = .{ .name = "cel.conformance.fixture.TestSchema" } },
        },
    }).compile(std.testing.allocator, "[TestSchema.Status(input), m.status]", .{
        .max_steps = 8192,
        .protobuf = .{ .max_message_bytes = 256, .max_total_bytes = 4096, .max_values = 256 },
    });
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(compiled: *Program, smith: *std.testing.Smith) !void {
            var data: [256]u8 = undefined;
            const length = smith.slice(&data);
            const number = smith.value(i64);
            const input: Value = if (smith.value(bool)) .{ .string = data[0..length] } else .{ .int = number };
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = compiled.evaluate(arena.allocator(), &.{
                .{ .name = "input", .value = input },
                .{ .name = "m", .value = .{ .message = &.{
                    .type_name = "cel.conformance.fixture.TestSchema",
                    .data = data[0..length],
                } } },
            }) catch return;
        }
    }.run, .{ .corpus = &.{ "\x02\x00\x00\x00\x50\x01", "\x0c\x00\x00\x00STATUS_READY" } });
}

test "protobuf wire input never traps or escapes native evaluation storage" {
    var program = try (Environment{
        .descriptors = @import("fixtures").schema,
        .variables = &.{.{ .name = "m", .type = .{ .name = "cel.conformance.fixture.TestSchema" } }},
    }).compile(std.testing.allocator, "m.signed_value >= 0 && m.values.all(v, v < 100)", .{
        .max_steps = 8192,
        .protobuf = .{ .max_message_bytes = 2048, .max_total_bytes = 8192, .max_values = 2048 },
    });
    defer program.deinit();
    try std.testing.fuzz(&program, struct {
        fn run(compiled: *Program, smith: *std.testing.Smith) !void {
            var data: [2048]u8 = undefined;
            const length = smith.slice(&data);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = compiled.evaluate(arena.allocator(), &.{.{ .name = "m", .value = .{ .message = &.{
                .type_name = "cel.conformance.fixture.TestSchema",
                .data = data[0..length],
            } } }}) catch return;
        }
    }.run, .{ .corpus = &.{ "\x02\x00\x00\x00\x08\x01", "\x01\x00\x00\x00\x80" } });
}

test "temporal parsing never traps on untrusted string values" {
    var program = try Program.compile(std.testing.allocator, "timestamp(text).getHours(zone)", .{ .max_steps = 4096 });
    defer program.deinit();
    var duration = try Program.compile(std.testing.allocator, "duration(text)", .{ .max_steps = 4096 });
    defer duration.deinit();
    try std.testing.fuzz(.{ &program, &duration }, struct {
        fn run(programs: struct { *Program, *Program }, smith: *std.testing.Smith) !void {
            var text: [256]u8 = undefined;
            var zone: [128]u8 = undefined;
            const text_len = smith.slice(&text);
            const zone_len = smith.slice(&zone);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = programs[0].evaluate(arena.allocator(), &.{
                .{ .name = "text", .value = .{ .string = text[0..text_len] } },
                .{ .name = "zone", .value = .{ .string = zone[0..zone_len] } },
            }) catch {};
            _ = programs[1].evaluate(arena.allocator(), &.{
                .{ .name = "text", .value = .{ .string = text[0..text_len] } },
            }) catch {};
        }
    }.run, .{ .corpus = &.{
        "\x03\x00\x00\x001ns\x03\x00\x00\x00UTC",
        "\x14\x00\x00\x002000-01-01T00:00:00Z\x13\x00\x00\x00America/Los_Angeles",
    } });
}

test "checked source never traps or leaks" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buffer: [2048]u8 = undefined;
            const len = smith.slice(&buffer);
            var program = (Environment{
                .container = "google.protobuf.FieldDescriptorProto",
                .strong_enums = smith.value(bool),
                .variables = &.{.{ .name = "x", .type = .{ .name = "dyn" } }},
            }).compile(std.testing.allocator, buffer[0..len], .{
                .max_depth = 64,
                .max_nodes = 2048,
                .max_check_steps = 8192,
                .regex = .{ .max_patterns = 8, .max_program_size = 512 },
            }) catch return;
            defer program.deinit();
        }
    }.run, .{ .corpus = &.{
        "\x05\x00\x00\x00x + 1",                       "\x0a\x00\x00\x00[[], [[]]]",
        "\x07\x00\x00\x00Type(9)\x01",                 "\x10\x00\x00\x00Type.TYPE_STRING\x01",
        "\x12\x00\x00\x00math.greatest(1,2)",          "\x19\x00\x00\x00math.bitShiftRight(-1,63)",
        "\x1b\x00\x00\x00lists.range(4).sortBy(x,-x)", "\x1d\x00\x00\x00x.flatten().distinct().sort()",
        "\x11\x00\x00\x00cel.bind(x,1,x+x)",           "\x14\x00\x00\x00cel.bind(x,1/0,true)",
        "\x1b\x00\x00\x00cel.block([1],cel.index(0))", "\x2a\x00\x00\x00[1].map(cel.iterVar(0,0),cel.iterVar(0,0))",
        "\x0f\x00\x00\x00'abc'.split('')",             "\x10\x00\x00\x00'%s'.format([1])",
        "\x15\x00\x00\x00base64.decode('Zg==')",       "\x13\x00\x00\x00proto.getExt(x,a.b)",
        "\x0e\x00\x00\x00ip(x).family()",              "\x15\x00\x00\x00cidr(x).containsIP(x)",
        "\x15\x00\x00\x00type(ip(x)) == net.IP",       "\x0d\x00\x00\x00string(ip(x))",
    } });
}

test "map constants reject duplicate CEL keys including signed and unsigned aliases" {
    const duplicates = [_][2]Value{
        .{ .{ .int = 1 }, .{ .uint = 1 } },
        .{ .{ .uint = 0 }, .{ .int = 0 } },
        .{ .{ .bool = true }, .{ .bool = true } },
        .{ .{ .string = "same" }, .{ .string = "same" } },
    };
    for (duplicates) |keys| {
        const entries = [_]value.Entry{
            .{ .key = keys[0], .value = .{ .int = 1 } },
            .{ .key = keys[1], .value = .{ .int = 2 } },
        };
        try std.testing.expectError(error.InvalidDeclaration, (Environment{
            .constants = &.{.{ .name = "m", .value = .{ .map = &entries } }},
        }).compile(std.testing.allocator, "true", .{}));
    }
}

test "map key validation cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const entries = [_]value.Entry{
                .{ .key = .{ .bool = false }, .value = .{ .int = 1 } },
                .{ .key = .{ .int = 0 }, .value = .{ .int = 2 } },
                .{ .key = .{ .string = "x" }, .value = .{ .int = 3 } },
                .{ .key = .{ .int = -1 }, .value = .{ .int = 4 } },
                .{ .key = .{ .uint = std.math.maxInt(u64) }, .value = .{ .int = 5 } },
            };
            var program = try (Environment{
                .constants = &.{.{ .name = "m", .value = .{ .map = &entries } }},
            }).compile(gpa, "m[false] == 1 && m[0] == 2 && m['x'] == 3 && " ++
                "m[-1] == 4 && m[18446744073709551615u] == 5", .{});
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
        }
    }.run, .{});
}

test "typed map key validation agrees with public CEL equality" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var entries: [32]value.Entry = undefined;
            const length = smith.value(u8) % (entries.len + 1);
            var duplicate = false;
            for (entries[0..length], 0..) |*entry, i| {
                entry.* = .{
                    .key = switch (smith.value(u8) % 4) {
                        0 => .{ .bool = smith.value(bool) },
                        1 => .{ .int = smith.value(i64) },
                        2 => .{ .uint = smith.value(u64) },
                        else => .{ .string = if (smith.value(bool)) "first" else "second" },
                    },
                    .value = .{ .int = @intCast(i) },
                };
                for (entries[0..i]) |previous| duplicate = duplicate or previous.key.eql(entry.key);
            }
            const compiled = (Environment{
                .constants = &.{.{ .name = "m", .value = .{ .map = entries[0..length] } }},
            }).parse(std.testing.allocator, "m", .{});
            if (duplicate) {
                try std.testing.expectError(error.InvalidDeclaration, compiled);
            } else {
                var program = try compiled;
                defer program.deinit();
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const result = try program.evaluate(arena.allocator(), &.{});
                try std.testing.expectEqual(length, result.map.len);
                for (entries[0..length]) |entry| try std.testing.expect(result.get(entry.key).?.eql(entry.value));
            }
        }
    }.run, .{});
}

test "large typed map constants retain distinct boolean and integer keys within linear budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try arena.allocator().alloc(value.Entry, 2049);
    entries[0] = .{ .key = .{ .bool = true }, .value = .{ .string = "boolean" } };
    for (entries[1..], 0..) |*entry, i| entry.* = .{
        .key = .{ .int = @intCast(i) },
        .value = .{ .int = @intCast(i * 2) },
    };
    const environment = Environment{ .constants = &.{.{ .name = "catalog", .value = .{ .map = entries } }} };
    var program = try environment.compile(std.testing.allocator, "catalog[true] == 'boolean' && catalog[1] == 2 && catalog[2047] == 4094", .{});
    defer program.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
}

test "all allocation failures clean up through the public API" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            for ([_][]const u8{
                "[1, 2, 3].map(x, x * 2) == [2, 4, 6]",
                "[1, 2, 3].transformMap(i, v, v * 2).transformList(k, v, v).all(x, x > 0)",
                "[1, 2].transformMapEntry(i, v, {v: i}) == {1: 0, 2: 1}",
                ".int(1.0) == 1 && has({'/api': true}.`/api`)",
                "string(timestamp('2000-01-01T00:00:00.000000001Z')) == '2000-01-01T00:00:00.000000001Z'",
                "string(duration('-1.234s')) == '-1.234s'",
                "matches('abc', '^a') && 'abc'.matches('c$') && ('x'.matches('(') || true)",
                "['a', 'b', 'a'].all(p, 'abc'.matches(p))",
            }) |source| {
                var program = try Program.compile(gpa, source, .{});
                defer program.deinit();
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const result = try program.evaluate(arena.allocator(), &.{});
                try std.testing.expectEqual(Value{ .bool = true }, result);
            }
        }
    }.run, .{});
}

fn expectNetworkExpression(
    environment: Environment,
    checked: bool,
    source: []const u8,
    bindings: []const Binding,
    expected: Value,
) !void {
    var program = if (checked)
        try environment.compile(std.testing.allocator, source, .{})
    else
        try environment.parse(std.testing.allocator, source, .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(expected.eql(try program.evaluate(arena.allocator(), bindings)));
}

fn customIP(_: ?*anyopaque, _: Allocator, _: []const Value) cel.EvalError!Value {
    return .{ .string = "custom" };
}

fn customCanonical(_: ?*anyopaque, _: Allocator, _: []const Value) cel.EvalError!Value {
    return .{ .bool = true };
}

fn maskByte(prefix: u8, index: usize) u8 {
    const offset = index * 8;
    if (prefix >= offset + 8) return 0xff;
    if (prefix <= offset) return 0;
    return @as(u8, 0xff) << @intCast(offset + 8 - prefix);
}

fn maskedBytes(address: cel.IP, prefix: u8) [16]u8 {
    var bytes = address.bytes;
    const length: usize = if (address.family == 4) 4 else 16;
    for (0..length) |index| bytes[index] &= maskByte(prefix, index);
    return bytes;
}

fn containsBytes(network: cel.CIDR, address: cel.IP) bool {
    if (network.address.family != address.family) return false;
    const length: usize = if (address.family == 4) 4 else 16;
    for (0..length) |index| {
        const mask = maskByte(network.prefix, index);
        if (network.address.bytes[index] & mask != address.bytes[index] & mask) return false;
    }
    return true;
}

fn randomIP(smith: *std.testing.Smith, family: u8) cel.IP {
    var bytes: [16]u8 = undefined;
    for (&bytes) |*byte| byte.* = smith.value(u8);
    if (family == 4) {
        @memset(bytes[4..], 0);
    } else if (std.mem.allEqual(u8, bytes[0..10], 0) and bytes[10] == 0xff and bytes[11] == 0xff) {
        bytes[11] = 0xfe;
    }
    return .{ .bytes = bytes, .family = family };
}

test "Program and Environment expose network constructors and methods" {
    const source =
        "string(ip('2001:0DB8:0:0:0:0:0:1')) == '2001:db8::1' && " ++
        "ip('192.168.1.2').family() == 4 && ip('::1').family() == 6 && " ++
        "ip('0.0.0.0').isUnspecified() && ip('127.42.0.1').isLoopback() && " ++
        "ip('192.168.1.2').isGlobalUnicast() && !ip('255.255.255.255').isGlobalUnicast() && " ++
        "ip('224.0.0.1').isLinkLocalMulticast() && !ip('224.0.1.1').isLinkLocalMulticast() && " ++
        "ip('169.254.3.4').isLinkLocalUnicast() && ip('ff02::1').isLinkLocalMulticast() && " ++
        "ip('fe80::1').isLinkLocalUnicast() && !ip('ff00::1').isGlobalUnicast() && " ++
        "string(cidr('10.1.2.3/8')) == '10.1.2.3/8' && " ++
        "cidr('10.1.2.3/8').ip() == ip('10.1.2.3') && " ++
        "cidr('10.1.2.3/8').masked() == cidr('10.0.0.0/8') && " ++
        "cidr('10.1.2.3/8').prefixLength() == 8 && " ++
        "cidr('10.1.2.3/8').containsIP('10.255.255.255') && " ++
        "cidr('2001:db8:1234::1/33').containsCIDR('2001:db8:7fff::9/65')";
    inline for (.{ false, true }) |checked| {
        try expectNetworkExpression(.{}, checked, source, &.{}, .{ .bool = true });
    }
}

test "checked network declarations retain nominal abstract types" {
    const ip_type = cel.Type{ .name = "net.IP", .kind = .abstract };
    const cidr_type = cel.Type{ .name = "net.CIDR", .kind = .abstract };
    const environment = Environment{ .variables = &.{
        .{ .name = "source", .type = ip_type },
        .{ .name = "network", .type = cidr_type },
    } };
    var policy = try environment.compile(
        std.testing.allocator,
        "network.containsIP(source) && source.isGlobalUnicast() && !source.isLoopback()",
        .{},
    );
    defer policy.deinit();
    try std.testing.expect(policy.result_type.?.eql(.{ .name = "bool" }));

    const address = try cel.IP.parse("10.2.3.4");
    const network = try cel.CIDR.parse("10.9.8.7/8");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Value{ .bool = true }, try policy.evaluate(arena.allocator(), &.{
        .{ .name = "source", .value = .{ .ip = &address } },
        .{ .name = "network", .value = .{ .cidr = &network } },
    }));

    var identity = try environment.compile(std.testing.allocator, "source", .{});
    defer identity.deinit();
    try std.testing.expect(identity.result_type.?.eql(ip_type));
    try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, "source.masked()", .{}));
    try std.testing.expectError(error.TypeMismatch, environment.compile(std.testing.allocator, "isIP(network)", .{}));
    try expectNetworkExpression(
        .{},
        true,
        "type(ip('10.0.0.1')) == net.IP && type(cidr('10.0.0.1/8')) == net.CIDR",
        &.{},
        .{ .bool = true },
    );
}

test "network names honor containers absolute names and custom precedence" {
    const string_type = cel.Type{ .name = "string" };
    const bool_type = cel.Type{ .name = "bool" };
    const environment = Environment{
        .container = "scope.deep",
        .functions = &.{
            .{
                .name = "scope.ip",
                .parameters = &.{string_type},
                .result = string_type,
                .implementation = customIP,
            },
            .{
                .name = "scope.ip.isCanonical",
                .parameters = &.{string_type},
                .result = bool_type,
                .implementation = customCanonical,
            },
        },
    };
    const source =
        "ip('not an address') == 'custom' && ip.isCanonical('not an address') && " ++
        "string(.ip('127.0.0.1')) == '127.0.0.1' && .ip.isCanonical('127.0.0.1') && " ++
        "!.ip.isCanonical('2001:DB8::1')";
    inline for (.{ false, true }) |checked| {
        try expectNetworkExpression(environment, checked, source, &.{}, .{ .bool = true });
    }
    try expectNetworkExpression(
        .{ .container = "ip.policy" },
        true,
        "isCanonical('127.0.0.1') && !isCanonical('2001:DB8::1')",
        &.{},
        .{ .bool = true },
    );
}

test "network errors obey CEL lazy boolean evaluation" {
    const source =
        "(ip('bad').family() == 4 || true) && " ++
        "!(ip('bad').family() == 4 && false) && " ++
        "(true || cidr('bad').masked() == cidr('0.0.0.0/0')) && " ++
        "!(false && cidr('bad').containsIP('also bad'))";
    inline for (.{ false, true }) |checked| {
        try expectNetworkExpression(.{}, checked, source, &.{}, .{ .bool = true });
    }

    var program = try Program.compile(std.testing.allocator, "ip('bad').family() == 4 || false", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidArgument, program.evaluate(arena.allocator(), &.{}));
}

test "network equality and distinct preserve value identity" {
    const source =
        "ip('2001:db8::1') == ip('2001:0DB8:0:0:0:0:0:1') && " ++
        "ip('10.0.0.1') != ip('10.0.0.2') && " ++
        "cidr('10.1.2.3/8') != cidr('10.0.0.0/8') && " ++
        "cidr('10.1.2.3/8') != cidr('10.1.2.3/9') && " ++
        "[ip('10.0.0.1'), ip('10.0.0.1'), ip('10.0.0.2')].distinct().size() == 2 && " ++
        "[cidr('10.0.0.1/8'), cidr('10.0.0.0/8'), cidr('10.0.0.1/8')].distinct().size() == 2";
    inline for (.{ false, true }) |checked| {
        try expectNetworkExpression(.{}, checked, source, &.{}, .{ .bool = true });
    }

    const first = try cel.IP.parse("192.0.2.1");
    const same = try cel.IP.parse("192.0.2.1");
    const prefix = try cel.CIDR.parse("192.0.2.1/24");
    try std.testing.expect((Value{ .ip = &first }).eql(.{ .ip = &same }));
    try std.testing.expect(!(Value{ .ip = &first }).eql(.{ .cidr = &prefix }));
}

test "mapped IPv6 forms are rejected including hexadecimal corpus cases" {
    for ([_][]const u8{
        "::ffff:192.168.0.1",
        "::ffff:c0a8:1",
        "0:0:0:0:0:ffff:192.168.0.1",
        "0:0:0:0:0:ffff:c0a8:0001",
    }) |text| {
        try std.testing.expectError(error.InvalidArgument, cel.IP.parse(text));
        var program = try Program.compile(std.testing.allocator, "isIP(text)", .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(Value{ .bool = false }, try program.evaluate(arena.allocator(), &.{
            .{ .name = "text", .value = .{ .string = text } },
        }));
    }
    for ([_][]const u8{
        "::ffff:192.168.0.1/128",
        "::ffff:c0a8:1/128",
        "0:0:0:0:0:ffff:192.168.0.1/128",
        "0:0:0:0:0:ffff:c0a8:0001/128",
    }) |text| {
        try std.testing.expectError(error.InvalidArgument, cel.CIDR.parse(text));
    }
}

test "raw invalid network metadata is rejected by public boundaries" {
    var padded_bytes = [_]u8{0} ** 16;
    padded_bytes[0] = 10;
    padded_bytes[4] = 1;
    const padded = cel.IP{ .bytes = padded_bytes, .family = 4 };
    const wrong_family = cel.IP{ .bytes = [_]u8{0} ** 16, .family = 5 };
    var mapped_bytes = [_]u8{0} ** 16;
    mapped_bytes[10] = 0xff;
    mapped_bytes[11] = 0xff;
    const mapped = cel.IP{ .bytes = mapped_bytes, .family = 6 };
    const invalid_prefix = cel.CIDR{ .address = try cel.IP.parse("192.0.2.1"), .prefix = 33 };

    for ([_]cel.IP{ padded, wrong_family, mapped }) |address| {
        try std.testing.expectError(error.InvalidArgument, address.validate());
        try std.testing.expectError(error.InvalidArgument, address.format(std.testing.allocator));
        try std.testing.expect(!address.isUnspecified());
        try std.testing.expect(!address.isLoopback());
        try std.testing.expect(!address.isGlobalUnicast());
    }
    try std.testing.expectError(error.InvalidArgument, invalid_prefix.validate());
    try std.testing.expectError(error.InvalidArgument, invalid_prefix.format(std.testing.allocator));
    try std.testing.expect(!invalid_prefix.containsIP(try cel.IP.parse("192.0.2.1")));

    var ip_program = try Program.compile(std.testing.allocator, "input.family()", .{});
    defer ip_program.deinit();
    var cidr_program = try Program.compile(std.testing.allocator, "input.masked()", .{});
    defer cidr_program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidArgument, ip_program.evaluate(arena.allocator(), &.{
        .{ .name = "input", .value = .{ .ip = &padded } },
    }));
    try std.testing.expectError(error.InvalidArgument, cidr_program.evaluate(arena.allocator(), &.{
        .{ .name = "input", .value = .{ .cidr = &invalid_prefix } },
    }));
}

test "nested raw network metadata is validated before escaping evaluation" {
    var bytes = [_]u8{0} ** 16;
    bytes[0] = 10;
    bytes[8] = 1;
    const invalid = cel.IP{ .bytes = bytes, .family = 4 };
    const item = Value{ .ip = &invalid };
    const list = [_]Value{item};
    const map = [_]cel.Entry{.{ .key = .{ .string = "address" }, .value = item }};
    const optional = Value{ .optional = &item };

    const cases = [_]struct { source: []const u8, input: Value }{
        .{ .source = "input", .input = .{ .list = &list } },
        .{ .source = "input", .input = .{ .map = &map } },
        .{ .source = "input", .input = optional },
    };
    for (cases) |case| {
        var program = try Program.compile(std.testing.allocator, case.source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidArgument, program.evaluate(arena.allocator(), &.{
            .{ .name = "input", .value = case.input },
        }));
    }
}

test "network formatting reports validation and allocation failures" {
    const address = try cel.IP.parse("2001:db8::1");
    const prefix = try cel.CIDR.parse("192.0.2.129/24");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, address.format(failing.allocator()));
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, prefix.format(failing.allocator()));

    const invalid_address = cel.IP{ .bytes = [_]u8{0} ** 16, .family = 0 };
    const invalid_prefix = cel.CIDR{ .address = address, .prefix = 129 };
    try std.testing.expectError(error.InvalidArgument, invalid_address.format(std.testing.allocator));
    try std.testing.expectError(error.InvalidArgument, invalid_prefix.format(std.testing.allocator));
}

test "network evaluation obeys input output and work limits" {
    try std.testing.expectError(error.InvalidArgument, cel.IP.parse("1" ** 46));
    try std.testing.expectError(error.InvalidArgument, cel.CIDR.parse("::/" ++ "1" ** 47));

    var output = try Program.compile(
        std.testing.allocator,
        "string(ip('2001:db8::1'))",
        .{ .max_collection_size = 8 },
    );
    defer output.deinit();
    var work = try Program.compile(std.testing.allocator, "ip(text).isGlobalUnicast() || true", .{ .max_steps = 32 });
    defer work.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CollectionLimitExceeded, output.evaluate(arena.allocator(), &.{}));
    try std.testing.expectError(error.CostLimitExceeded, work.evaluate(arena.allocator(), &.{
        .{ .name = "text", .value = .{ .string = "2001:db8::1" ** 8 } },
    }));
}

test "network allocation failures release public Program and format storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var program = try (Environment{}).compile(
                gpa,
                "string(cidr('2001:db8:ffff::1234/33').masked()) == '2001:db8:8000::/33'",
                .{},
            );
            defer program.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try std.testing.expectEqual(Value{ .bool = true }, try program.evaluate(arena.allocator(), &.{}));
            const text = try (try cel.IP.parse("2001:db8::1")).format(gpa);
            defer gpa.free(text);
            try std.testing.expectEqualStrings("2001:db8::1", text);
        }
    }.run, .{});
}

test "network text parsing stays consistent through public Programs" {
    var ip_program = try Program.compile(std.testing.allocator, "isIP(text)", .{});
    defer ip_program.deinit();
    var cidr_program = try Program.compile(std.testing.allocator, "isCIDR(text)", .{});
    defer cidr_program.deinit();
    try std.testing.fuzz(.{ &ip_program, &cidr_program }, struct {
        fn run(programs: struct { *Program, *Program }, smith: *std.testing.Smith) !void {
            var storage: [64]u8 = undefined;
            for (&storage) |*byte| byte.* = smith.value(u8);
            const text = storage[0 .. smith.value(u8) % 65];

            const ip_valid = if (cel.IP.parse(text)) |address| valid: {
                const formatted = try address.format(std.testing.allocator);
                defer std.testing.allocator.free(formatted);
                try std.testing.expect(address.eql(try cel.IP.parse(formatted)));
                break :valid true;
            } else |err| invalid: {
                try std.testing.expectEqual(error.InvalidArgument, err);
                break :invalid false;
            };
            const cidr_valid = if (cel.CIDR.parse(text)) |prefix| valid: {
                const formatted = try prefix.format(std.testing.allocator);
                defer std.testing.allocator.free(formatted);
                try std.testing.expect(prefix.eql(try cel.CIDR.parse(formatted)));
                break :valid true;
            } else |err| invalid: {
                try std.testing.expectEqual(error.InvalidArgument, err);
                break :invalid false;
            };

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const bindings = &.{Binding{ .name = "text", .value = .{ .string = text } }};
            try std.testing.expectEqual(
                Value{ .bool = ip_valid },
                try programs[0].evaluate(arena.allocator(), bindings),
            );
            try std.testing.expectEqual(
                Value{ .bool = cidr_valid },
                try programs[1].evaluate(arena.allocator(), bindings),
            );
        }
    }.run, .{ .corpus = &.{
        "192.0.2.1",
        "2001:db8::1",
        "192.0.2.129/25",
        "2001:db8::1234/65",
        "::ffff:c000:201",
    } });
}

test "network IP and CIDR math matches an independent byte-mask oracle" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const family: u8 = if (smith.value(bool)) 4 else 6;
            const address = randomIP(smith, family);
            const candidate = randomIP(smith, family);
            const other = randomIP(smith, if (family == 4) 6 else 4);
            const maximum: u8 = if (family == 4) 32 else 128;
            const prefix_length = smith.value(u8) % (maximum + 1);
            const inner_length = smith.value(u8) % (maximum + 1);
            const prefix = cel.CIDR{ .address = address, .prefix = prefix_length };
            const inner = cel.CIDR{ .address = candidate, .prefix = inner_length };

            try address.validate();
            try candidate.validate();
            try prefix.validate();
            const expected_masked = maskedBytes(address, prefix_length);
            const masked = prefix.masked();
            try std.testing.expectEqualSlices(u8, &expected_masked, &masked.address.bytes);
            try std.testing.expect(address.eql(prefix.address));
            try std.testing.expectEqual(containsBytes(prefix, candidate), prefix.containsIP(candidate));
            try std.testing.expect(!prefix.containsIP(other));
            try std.testing.expectEqual(
                prefix_length <= inner_length and containsBytes(prefix, candidate),
                prefix.containsCIDR(inner),
            );

            const length: usize = if (family == 4) 4 else 16;
            const unspecified = std.mem.allEqual(u8, address.bytes[0..length], 0);
            const loopback = if (family == 4)
                address.bytes[0] == 127
            else
                std.mem.allEqual(u8, address.bytes[0..15], 0) and address.bytes[15] == 1;
            const link_local_multicast = if (family == 4)
                address.bytes[0] == 224 and address.bytes[1] == 0 and address.bytes[2] == 0
            else
                address.bytes[0] == 0xff and address.bytes[1] & 0x0f == 2;
            const link_local_unicast = if (family == 4)
                address.bytes[0] == 169 and address.bytes[1] == 254
            else
                address.bytes[0] == 0xfe and address.bytes[1] & 0xc0 == 0x80;
            const global = if (family == 4)
                !unspecified and !loopback and !link_local_unicast and
                    !std.mem.allEqual(u8, address.bytes[0..4], 0xff) and address.bytes[0] & 0xf0 != 0xe0
            else
                !unspecified and !loopback and !link_local_unicast and address.bytes[0] != 0xff;
            try std.testing.expectEqual(unspecified, address.isUnspecified());
            try std.testing.expectEqual(loopback, address.isLoopback());
            try std.testing.expectEqual(link_local_multicast, address.isLinkLocalMulticast());
            try std.testing.expectEqual(link_local_unicast, address.isLinkLocalUnicast());
            try std.testing.expectEqual(global, address.isGlobalUnicast());
        }
    }.run, .{});
}

test "runtime signature checks cover network wrapper type and map parameters" {
    const Host = struct {
        fn first(_: ?*anyopaque, _: std.mem.Allocator, args: []const Value) EvalError!Value {
            return args[0];
        }
    };
    const ip_type = Type{ .kind = .abstract, .name = "net.IP" };
    const cidr_type = Type{ .kind = .abstract, .name = "net.CIDR" };
    const string_map = Type{ .name = "map", .parameters = &.{ .{ .name = "string" }, .{ .name = "int" } } };
    const wrapper = Type{ .name = "google.protobuf.Int64Value" };
    const type_of_int = Type{ .name = "type", .parameters = &.{.{ .name = "int" }} };
    const environment = Environment{ .functions = &.{
        .{ .name = "keepIP", .parameters = &.{ip_type}, .result = ip_type, .implementation = Host.first },
        .{ .name = "keepCIDR", .parameters = &.{cidr_type}, .result = cidr_type, .implementation = Host.first },
        .{ .name = "keepMap", .parameters = &.{string_map}, .result = string_map, .implementation = Host.first },
        .{ .name = "keepWrapped", .parameters = &.{wrapper}, .result = wrapper, .implementation = Host.first },
        .{ .name = "keepType", .parameters = &.{type_of_int}, .result = type_of_int, .implementation = Host.first },
    } };
    try expectNetworkExpression(environment, false, "keepIP(ip('10.0.0.1')) == ip('10.0.0.1')", &.{}, .{ .bool = true });
    try expectNetworkExpression(environment, false, "keepCIDR(cidr('10.0.0.0/8')).prefixLength() == 8", &.{}, .{ .bool = true });
    try expectNetworkExpression(environment, false, "keepMap({'a': 1})['a'] == 1", &.{}, .{ .bool = true });
    try expectNetworkExpression(environment, false, "keepWrapped(7) == 7 && keepWrapped(null) == null", &.{}, .{ .bool = true });
    try expectNetworkExpression(environment, false, "keepType(int) == int", &.{}, .{ .bool = true });
    for ([_][]const u8{
        "keepIP(cidr('10.0.0.0/8'))",
        "keepCIDR('10.0.0.0/8')",
        "keepMap({1: 1})",
        "keepMap({'a': 'text'})",
        "keepWrapped('seven')",
        "keepType(string)",
    }) |source| {
        var program = try environment.parse(std.testing.allocator, source, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.NoMatchingOverload, program.evaluate(arena.allocator(), &.{}));
    }
}

test "optional list indexes and network deduplication reach every runtime branch" {
    try expectExpression("[1, 2][?5].orValue(0) == 0 && [1, 2][?1u].orValue(0) == 2 && [1, 2][?3.0].orValue(9) == 9", &.{}, .{ .bool = true });
    try expectExpression("[1, 2][?-1].orValue(7) == 7 && [1, 2][?18446744073709551615u].orValue(8) == 8", &.{}, .{ .bool = true });
    try expectExpression(
        "lists.range(20).map(i, ip('10.0.0.' + string(i))).distinct().size() == 20 && " ++
            "lists.range(20).map(i, cidr('10.0.' + string(i) + '.0/24')).distinct().size() == 20 && " ++
            "(lists.range(20).map(i, ip('10.0.0.1')) + [ip('10.0.0.1')]).distinct().size() == 1",
        &.{},
        .{ .bool = true },
    );
    try expectExpression("size(b'abc') == 3 && size({'a': 1}) == 1 && string(true) == 'true' && string(false) == 'false'", &.{}, .{ .bool = true });
    try expectExpression("optional.ofNonZeroValue(ip('10.0.0.1')).hasValue() && optional.ofNonZeroValue(cidr('10.0.0.0/8')).hasValue()", &.{}, .{ .bool = true });
    try expectExpression("type(ip('10.0.0.1')) == net.IP && type(cidr('10.0.0.0/8')) == net.CIDR", &.{}, .{ .bool = true });
    try expectExpression(
        "type(google.protobuf.Empty{}) == google.protobuf.Empty && type(type(google.protobuf.Empty{})) == type",
        &.{},
        .{ .bool = true },
    );
    const strong = Environment{ .strong_enums = true };
    try expectNetworkExpression(
        strong,
        false,
        "type(google.protobuf.FieldDescriptorProto.Type.TYPE_STRING) == google.protobuf.FieldDescriptorProto.Type",
        &.{},
        .{ .bool = true },
    );
    var program = try Program.compile(std.testing.allocator, "[[1], 'x'].sortBy(v, v)", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NoMatchingOverload, program.evaluate(arena.allocator(), &.{}));
}

test "declared constants and checked macros cover every value family" {
    const address = try cel.IP.parse("10.0.0.1");
    const prefix = try cel.CIDR.parse("10.0.0.0/8");
    const message = cel.Message{ .type_name = "google.protobuf.Empty", .data = "" };
    const items = [_]Value{ .{ .int = 1 }, .{ .int = 2 } };
    const map_entries = [_]value.Entry{.{ .key = .{ .string = "k" }, .value = .{ .int = 3 } }};
    const environment = Environment{ .constants = &.{
        .{ .name = "source", .value = .{ .ip = &address } },
        .{ .name = "network", .value = .{ .cidr = &prefix } },
        .{ .name = "empty", .value = .{ .message = &message } },
        .{ .name = "when", .value = .{ .timestamp = .{ .seconds = 1 } } },
        .{ .name = "span", .value = .{ .duration = .{ .nanoseconds = 5 } } },
        .{ .name = "raw", .value = .{ .bytes = "ab" } },
        .{ .name = "items", .value = .{ .list = &items } },
        .{ .name = "table", .value = .{ .map = &map_entries } },
        .{ .name = "maybe", .value = .{ .optional = null } },
    } };
    try expectNetworkExpression(
        environment,
        true,
        "network.containsIP(source) && empty == google.protobuf.Empty{} && int(when) == 1 && span == duration('5ns') && " ++
            "raw == b'ab' && items[1] == 2 && table.k == 3 && !maybe.hasValue()",
        &.{},
        .{ .bool = true },
    );
    var typed = try environment.compile(std.testing.allocator, "[source, network, empty, when, span, raw, items, table]", .{});
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.result_type.?.parameters.len);

    try expectNetworkExpression(.{}, true, "[3, 1, 2].sortBy(v, -v) == [3, 2, 1]", &.{}, .{ .bool = true });
    try expectNetworkExpression(.{}, true, "{'a': 1}.transformMapEntry(k, v, {v: k}) == {1: 'a'}", &.{}, .{ .bool = true });
    try expectNetworkExpression(.{}, true, "dyn({'a': 1}).transformMapEntry(k, v, dyn({v: k})) == {1: 'a'}", &.{}, .{ .bool = true });
    try expectNetworkExpression(.{}, true, "math.greatest([1, 2, 3]) == 3 && math.least(4, 2) == 2", &.{}, .{ .bool = true });

    const invalid_address = cel.IP{ .bytes = @splat(0), .family = 9 };
    const invalid_time = cel.Timestamp{ .seconds = 1 << 62 };
    for ([_]Environment{
        .{ .constants = &.{.{ .name = "bad", .value = .{ .ip = &invalid_address } }} },
        .{ .constants = &.{.{ .name = "bad", .value = .{ .timestamp = invalid_time } }} },
        .{ .constants = &.{.{ .name = "bad", .value = .{ .map = &.{.{ .key = .{ .double = 1.5 }, .value = .null }} } }} },
        .{ .variables = &.{.{ .name = "bad", .type = .{ .kind = .abstract, .name = "net.IP", .parameters = &.{.{ .name = "int" }} } }} },
        .{ .variables = &.{.{ .name = "bad", .type = .{ .kind = .abstract, .name = "optional_type", .parameters = &.{ .{ .name = "int" }, .{ .name = "int" } } } }} },
    }) |invalid| {
        try std.testing.expectError(error.InvalidDeclaration, invalid.compile(std.testing.allocator, "bad", .{}));
    }

    const present = Value{ .int = 1 };
    const optional_a = Value{ .optional = &present };
    const optional_b = Value{ .optional = &present };
    try std.testing.expect(optional_a.eql(optional_b));
    try std.testing.expect(!optional_a.eql(.{ .optional = null }));
    try std.testing.expect((Value{ .optional = null }).eql(.{ .optional = null }));
    try std.testing.expect((Value{ .message = &message }).eql(.{ .message = &message }));
    try std.testing.expect((Value{ .map = &map_entries }).eql(.{ .map = &map_entries }));
    try std.testing.expect(!(Value{ .map = &map_entries }).eql(.{ .map = &.{} }));
    try std.testing.expect(!(Value{ .map = &map_entries }).eql(.{ .map = &.{.{ .key = .{ .string = "k" }, .value = .{ .int = 4 } }} }));
    try std.testing.expect(!(Value{ .map = &map_entries }).eql(.{ .map = &.{.{ .key = .{ .string = "z" }, .value = .{ .int = 3 } }} }));
}

test "temporal selectors format sanitizing and checked container quoting cover remaining branches" {
    try expectExpression(
        "[timestamp('2024-01-07T12:00:00Z'), timestamp('2024-01-08T12:00:00Z'), timestamp('2024-01-09T12:00:00Z'), " ++
            "timestamp('2024-01-10T12:00:00Z'), timestamp('2024-01-11T12:00:00Z'), timestamp('2024-01-12T12:00:00Z'), " ++
            "timestamp('2024-01-13T12:00:00Z')].map(t, t.getDayOfWeek()) == [0, 1, 2, 3, 4, 5, 6] && " ++
            "timestamp('2024-01-07T12:00:00.250Z').getMilliseconds() == 250 && " ++
            "timestamp('2024-01-07T12:00:00.250Z').getMilliseconds('America/New_York') == 250",
        &.{},
        .{ .bool = true },
    );
    try expectExpression("'%s'.format([b'\\xff\\xfe']) == '\\ufffd' && '%s'.format([b'a\\xffb']) == 'a\\ufffdb'", &.{}, .{ .bool = true });
    try expectExpression("'%s'.format([b'ok\\xff']) == 'ok\\ufffd'", &.{}, .{ .bool = true });
    try expectNetworkExpression(.{ .container = "strings" }, true, "quote('x') == '\"x\"'", &.{}, .{ .bool = true });
    try expectNetworkExpression(.{}, true, "type(map) == type && type(list) == type && type(optional_type) == type", &.{}, .{ .bool = true });

    var program = try Program.compile(std.testing.allocator, "{'a': 1}.transformMapEntry(k, v, {1.5: k})", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NoMatchingOverload, program.evaluate(arena.allocator(), &.{}));

    var concat = try Program.compile(std.testing.allocator, "x + x", .{ .max_collection_size = 8 });
    defer concat.deinit();
    try std.testing.expectError(error.CollectionLimitExceeded, concat.evaluate(arena.allocator(), &.{.{ .name = "x", .value = .{ .string = "12345" } }}));
    try std.testing.expectError(error.CollectionLimitExceeded, concat.evaluate(arena.allocator(), &.{.{ .name = "x", .value = .{ .bytes = "12345" } }}));
}

test "mixed numeric comparison follows the reference clamp-then-double algorithm" {
    // CEL-Go `compareDoubleInt` and CEL-C++ `DoubleCompareVisitor` clamp the double against the integer
    // range and otherwise compare in double space, so integers beyond 2^53 round.
    const cases = [_]struct { source: []const u8, expected: bool }{
        .{ .source = "dyn(9223372036854775807) < 9223372036854775808.0", .expected = false },
        .{ .source = "dyn(9223372036854775808.0) > 9223372036854775807", .expected = false },
        .{ .source = "dyn(9223372036854775808.0) <= 9223372036854775807", .expected = true },
        .{ .source = "dyn(9223372036854775807) >= 9223372036854775808.0", .expected = true },
        .{ .source = "dyn(9223372036854775807) == 9223372036854775808.0", .expected = true },
        .{ .source = "dyn(9007199254740993) == 9007199254740992.0", .expected = true },
        .{ .source = "dyn(9007199254740993) > 9007199254740992.0", .expected = false },
        .{ .source = "dyn(9223372036854775807) < 9223372036854777857.0", .expected = true },
        .{ .source = "dyn(-9223372036854775808) < -9223372036854775809.0", .expected = false },
        .{ .source = "dyn(-9223372036854775808) == -9223372036854775809.0", .expected = true },
        .{ .source = "dyn(-9223372036854775808) > -9223372036854777857.0", .expected = true },
        .{ .source = "dyn(18446744073709551615u) < 18446744073709590000.0", .expected = true },
        .{ .source = "dyn(18446744073709551615u) == 18446744073709551616.0", .expected = true },
        .{ .source = "dyn(18446744073709551615u) < 18446744073709551616.0", .expected = false },
        .{ .source = "dyn(9223372036854775807) == 9223372036854777856.0", .expected = false },
        .{ .source = "dyn(18446744073709553665.0) > 18446744073709551615u", .expected = true },
        .{ .source = "dyn(9223372036854775808u) > 1", .expected = true },
        .{ .source = "dyn(9223372036854775808u) == -1", .expected = false },
        .{ .source = "dyn(-1) < 9223372036854775808u", .expected = true },
        .{ .source = "dyn(1.0/0.0) > 9223372036854775807 && dyn(-1.0/0.0) < -9223372036854775808", .expected = true },
        .{ .source = "dyn(0.0/0.0) < 1 || dyn(0.0/0.0) > 1 || dyn(0.0/0.0) == 1", .expected = false },
        .{ .source = "dyn(1) == 1.0 && dyn(1u) == 1.0 && dyn(1) == 1u && dyn(2.5) > 2 && dyn(2) < 2.5", .expected = true },
        .{ .source = "{1: 'a'}[dyn(1.0)] == 'a' && dyn(1.0) in [1] && [9223372036854775807].exists(x, x == dyn(9223372036854775808.0))", .expected = true },
    };
    for (cases) |case| {
        try expectExpression(case.source, &.{}, .{ .bool = case.expected });
    }
    // `order` is public and defined only for numeric pairs; every other pairing is unordered.
    const one = Value{ .int = 1 };
    const nan = Value{ .double = std.math.nan(f64) };
    try std.testing.expectEqual(@as(?std.math.Order, null), one.order(.{ .string = "1" }));
    try std.testing.expectEqual(@as(?std.math.Order, null), (Value{ .uint = 1 }).order(.{ .bool = true }));
    try std.testing.expectEqual(@as(?std.math.Order, null), (Value{ .double = 1 }).order(.null));
    try std.testing.expectEqual(@as(?std.math.Order, null), (Value{ .string = "1" }).order(one));
    try std.testing.expectEqual(@as(?std.math.Order, null), nan.order(one));
    try std.testing.expectEqual(@as(?std.math.Order, null), one.order(nan));
    try std.testing.expectEqual(@as(?std.math.Order, null), nan.order(.{ .uint = 1 }));
    try std.testing.expectEqual(@as(?std.math.Order, null), (Value{ .uint = 1 }).order(nan));
    try std.testing.expectEqual(std.math.Order.eq, (Value{ .int = -1 }).order(.{ .int = -1 }).?);
    try std.testing.expectEqual(std.math.Order.lt, (Value{ .int = -1 }).order(.{ .uint = 0 }).?);
    try std.testing.expectEqual(std.math.Order.gt, (Value{ .uint = 0 }).order(.{ .int = -1 }).?);
}

test "protobuf repeated scalar reads wrapper boxing and message assignment reach every field kind" {
    const environment = Environment{ .descriptors = @import("fixtures").upstream, .container = "cel.expr.conformance.proto3" };
    const source =
        "cel.bind(m, TestAllTypes{" ++
        "repeated_bool: [true, false], repeated_int64: [1, -2], repeated_uint32: [3u], repeated_uint64: [4u], " ++
        "repeated_float: [1.5], repeated_double: [2.5], repeated_string: ['a'], " ++
        "repeated_nested_message: [TestAllTypes.NestedMessage{bb: 7}], " ++
        "single_bool_wrapper: true, single_uint64_wrapper: 5u, single_double_wrapper: 6.5, single_string_wrapper: 's', " ++
        "single_duration: duration('3s'), single_struct: {'k': 1.0}, single_value: [1, 'x'], single_uint32: 9u, " ++
        "single_nested_message: TestAllTypes.NestedMessage{bb: 8}}, " ++
        "m.repeated_bool[1] == false && m.repeated_int64[1] == -2 && m.repeated_uint32[0] == 3u && m.repeated_uint64[0] == 4u && " ++
        "m.repeated_float[0] == 1.5 && m.repeated_double[0] == 2.5 && m.repeated_string[0] == 'a' && " ++
        "m.repeated_nested_message[0].bb == 7 && m.single_bool_wrapper == true && m.single_uint64_wrapper == 5u && " ++
        "m.single_double_wrapper == 6.5 && m.single_string_wrapper == 's' && m.single_duration == duration('3s') && " ++
        "m.single_struct.k == 1.0 && m.single_value[1] == 'x' && m.single_uint32 == 9u && m.single_nested_message.bb == 8)";
    try expectNetworkExpression(environment, false, source, &.{}, .{ .bool = true });
    try expectNetworkExpression(environment, true, source, &.{}, .{ .bool = true });
    for ([_][]const u8{
        "TestAllTypes{single_nested_message: TestAllTypes{}}",
        "TestAllTypes{repeated_nested_message: [TestAllTypes{}]}",
        "TestAllTypes{single_uint32: 4294967296u}",
        "TestAllTypes{single_bool_wrapper: 'text'}",
        "TestAllTypes{single_duration: 'text'}",
    }) |source_error| {
        var program = try environment.parse(std.testing.allocator, source_error, .{});
        defer program.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = program.evaluate(arena.allocator(), &.{});
        try std.testing.expect(result == error.NoMatchingOverload or result == error.Overflow or result == error.InvalidArgument);
    }
}

test "fast plans describe only the plain-data subset" {
    var authorization = try Program.compile(
        std.testing.allocator,
        "request.method == \"GET\" && request.path.startsWith(\"/v1/\") && principal.authenticated && (principal.role == \"admin\" || resource.owner == principal.id)",
        .{},
    );
    defer authorization.deinit();
    const plan = (try authorization.fastPlan(std.testing.allocator)).?;
    defer std.testing.allocator.free(plan);
    try std.testing.expectEqualStrings(
        "[\"&&\",[\"&&\",[\"&&\",[\"==\",[\"select\",[\"ident\",\"request\"],\"method\"],[\"string\",\"GET\"]]," ++
            "[\"startsWith\",[\"select\",[\"ident\",\"request\"],\"path\"],[\"string\",\"/v1/\"]]]," ++
            "[\"select\",[\"ident\",\"principal\"],\"authenticated\"]]," ++
            "[\"||\",[\"==\",[\"select\",[\"ident\",\"principal\"],\"role\"],[\"string\",\"admin\"]]," ++
            "[\"==\",[\"select\",[\"ident\",\"resource\"],\"owner\"],[\"select\",[\"ident\",\"principal\"],\"id\"]]]]",
        plan,
    );
    for ([_][]const u8{
        "a.b != 3 && !c",
        "x.y.z == true || q.contains('t') || q.endsWith('u')",
        "a == 9007199254740991",
        "a.`b`.c == 1",
    }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        const supported = (try program.fastPlan(std.testing.allocator)) orelse return error.TestUnexpectedResult;
        std.testing.allocator.free(supported);
    }
    for ([_][]const u8{
        "a.b < 3",
        "a + 1 == 2",
        "has(a.b)",
        "a.?b == 1",
        "[1, 2].exists(x, x == 1)",
        "a.b == 1.5",
        "a.b == 9007199254740992",
        "a.b == -9007199254740992",
        "a.b == 1u",
        ".a.b == 1",
        "a.`b-c` == 1",
        "a == -1",
        "size(a) == 1",
        "a.b.matches('x')",
        "a.startsWith('x', 'y')",
        "a ? b : c",
        "timestamp('2024-01-01T00:00:00Z') == a",
        "a == b'x'",
        "a == null",
    }) |source| {
        var program = try Program.compile(std.testing.allocator, source, .{});
        defer program.deinit();
        try std.testing.expectEqual(@as(?[]u8, null), try program.fastPlan(std.testing.allocator));
    }
    const constants = Environment{ .constants = &.{.{ .name = "k", .value = .{ .int = 1 } }} };
    var with_constants = try constants.parse(std.testing.allocator, "a.b == 1", .{});
    defer with_constants.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try with_constants.fastPlan(std.testing.allocator));
    const container = Environment{ .container = "ns" };
    var with_container = try container.parse(std.testing.allocator, "a.b == 1", .{});
    defer with_container.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try with_container.fastPlan(std.testing.allocator));
    const custom = Environment{ .functions = &.{.{ .name = "startsWith", .parameters = &.{ .{ .name = "string" }, .{ .name = "string" } }, .result = .{ .name = "bool" }, .member = true }} };
    var with_custom = try custom.parse(std.testing.allocator, "a.startsWith('x')", .{});
    defer with_custom.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try with_custom.fastPlan(std.testing.allocator));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var program = try Program.compile(gpa, "a.b == 'x' && !c.d", .{});
            defer program.deinit();
            const bytes = (try program.fastPlan(gpa)) orelse return error.TestUnexpectedResult;
            gpa.free(bytes);
        }
    }.run, .{});
}
