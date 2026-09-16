//! Gradual CEL type inference. The compiler exclusively owns the syntax while resolved names are lowered.

const std = @import("std");
const math = @import("math.zig");
const strings = @import("strings.zig");
const encoders = @import("encoders.zig");
const network = @import("network_functions.zig");
const names = @import("names.zig");
const syntax = @import("syntax.zig");
const types = @import("types.zig");
const value = @import("value.zig");
const proto = @import("proto.zig");
const temporal = @import("temporal.zig");
const functions_mod = @import("functions.zig");
const Type = types.Type;
const Function = functions_mod.Function;
const Node = syntax.Node;

/// Static checking failures.
pub const CheckError = error{
    /// Allocation failed.
    OutOfMemory,
    /// No declaration exists for a referenced variable.
    UndeclaredReference,
    /// No overload accepts the inferred argument types.
    TypeMismatch,
    /// This type requires an unimplemented provider.
    UnsupportedType,
    /// Type or syntax nesting exceeds the configured limit.
    DepthLimitExceeded,
    /// Inference exhausted its work budget.
    CheckLimitExceeded,
};

/// Infer a result type and bind global references to their declared fully qualified names.
pub fn check(
    arena: std.mem.Allocator,
    root: *const Node,
    variables: []const types.Declaration,
    constants: []const value.Binding,
    container: []const u8,
    limits: syntax.Limits,
    registry: ?*proto.Registry,
    strong_enums: bool,
    functions: []const Function,
) CheckError!Type {
    var checker = Checker{
        .arena = arena,
        .variables = variables,
        .constants = constants,
        .container = container,
        .max_depth = limits.max_depth,
        .remaining = limits.max_check_steps,
        .registry = registry,
        .strong_enums = strong_enums,
        .functions = functions,
    };
    const result = try checker.infer(root, null);
    for (checker.function_results.items) |entry| entry.call.function_result = try checker.finish(entry.type, 0);
    return checker.finish(result, 0);
}

const Term = struct {
    name: ?[]const u8 = null,
    parameters: []const *Term = &.{},
    kind: Type.Kind = .concrete,
    binding: ?*Term = null,
    parent: ?*Term = null,
    rank: usize = 0,
};
const Local = struct { name: []const u8, type: *Term, block_types: ?[]const *Term = null, parent: ?*const Local };
const Change = struct { variable: *Term, previous: Term };

const Checker = struct {
    arena: std.mem.Allocator,
    variables: []const types.Declaration,
    constants: []const value.Binding,
    container: []const u8,
    registry: ?*proto.Registry,
    strong_enums: bool,
    functions: []const Function,
    max_depth: usize,
    remaining: usize,
    depth: usize = 0,
    changes: std.ArrayList(Change) = .empty,
    function_results: std.ArrayList(struct { call: *syntax.Call, type: *Term }) = .empty,

    fn tick(self: *Checker) CheckError!void {
        if (self.remaining == 0) return error.CheckLimitExceeded;
        self.remaining -= 1;
    }

    fn term(self: *Checker, name: ?[]const u8, parameters: []const *Term) CheckError!*Term {
        return self.typedTerm(.concrete, name, parameters);
    }

    fn typedTerm(self: *Checker, kind: Type.Kind, name: ?[]const u8, parameters: []const *Term) CheckError!*Term {
        try self.tick();
        const result = try self.arena.create(Term);
        result.* = .{ .name = name, .parameters = try self.arena.dupe(*Term, parameters), .kind = kind };
        return result;
    }

    fn infer(self: *Checker, source: *const Node, scope: ?*const Local) CheckError!*Term {
        try self.tick();
        if (self.depth >= self.max_depth) return error.DepthLimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        const node = @constCast(source);
        switch (node.*) {
            .literal => |v| return self.literal(v),
            .variable => unreachable,
            .ident, .local_ident => |identifier| {
                if (!std.mem.startsWith(u8, identifier, ".")) {
                    var local = scope;
                    while (local) |binding| : (local = binding.parent) {
                        if (std.mem.eql(u8, binding.name, identifier)) return binding.type;
                    }
                }
                if (node.* == .local_ident) return error.UndeclaredReference;
                return (try self.resolve(node)) orelse error.UndeclaredReference;
            },
            .select => |selection| {
                if (selection.qualified) {
                    const root = names.root(node);
                    var local = if (std.mem.startsWith(u8, root, ".")) null else scope;
                    var shadowed = false;
                    while (local) |binding| : (local = binding.parent) {
                        if (std.mem.eql(u8, binding.name, root)) {
                            shadowed = true;
                            break;
                        }
                    }
                    if (!shadowed) if (try self.resolve(node)) |resolved| return resolved;
                }
                node.select.qualified = false;
                return self.select(try self.infer(selection.target, scope), selection.field, selection.optional);
            },
            .presence => |selection| {
                _ = try self.select(try self.infer(selection.target, scope), selection.field, false);
                return self.term("bool", &.{});
            },
            .index => |index| return self.inferIndex(
                try self.infer(index.target, scope),
                try self.infer(index.key, scope),
                index.optional,
            ),
            .unary => |unary| {
                const operand = try self.infer(unary.operand, scope);
                if (unary.op == .bang) {
                    _ = try self.combine(operand, try self.term("bool", &.{}));
                    return self.term("bool", &.{});
                }
                if (!dynamic(operand) and !is(operand, "int") and !is(operand, "double")) return error.TypeMismatch;
                return if (dynamic(operand)) self.term("dyn", &.{}) else operand;
            },
            .binary => |binary| {
                const left = try self.infer(binary.left, scope);
                const right = try self.infer(binary.right, scope);
                const timestamp = "google.protobuf.Timestamp";
                const duration = "google.protobuf.Duration";
                if (binary.op == .plus) {
                    if ((is(left, timestamp) and (is(right, duration) or dynamic(right))) or
                        (is(right, timestamp) and (is(left, duration) or dynamic(left)))) return self.term(timestamp, &.{});
                    if (is(left, duration) and is(right, duration)) return self.term(duration, &.{});
                    if ((is(left, duration) and dynamic(right)) or (is(right, duration) and dynamic(left))) return self.term("dyn", &.{});
                }
                if (binary.op == .minus) {
                    if (is(left, timestamp) and is(right, duration)) return self.term(timestamp, &.{});
                    if ((is(left, timestamp) and is(right, timestamp)) or
                        (is(left, duration) and (is(right, duration) or dynamic(right))) or
                        (dynamic(left) and is(right, timestamp))) return self.term(duration, &.{});
                    if ((is(left, timestamp) and dynamic(right)) or (dynamic(left) and is(right, duration))) return self.term("dyn", &.{});
                }
                switch (binary.op) {
                    .and_op, .or_op => {
                        _ = try self.combine(left, try self.term("bool", &.{}));
                        _ = try self.combine(right, try self.term("bool", &.{}));
                        return self.term("bool", &.{});
                    },
                    .eq, .ne => {
                        _ = try self.combine(left, right);
                        return self.term("bool", &.{});
                    },
                    .lt, .le, .gt, .ge => {
                        _ = try self.overload(left, right, &.{ "bool", "int", "uint", "double", "string", "bytes", timestamp, duration });
                        return self.term("bool", &.{});
                    },
                    .in_op => {
                        if (!dynamic(right)) {
                            if (!is(right, "list") and !is(right, "map")) return error.TypeMismatch;
                            _ = try self.combine(left, peek(right).parameters[0]);
                        }
                        return self.term("bool", &.{});
                    },
                    .plus => return self.overload(left, right, &.{ "int", "uint", "double", "string", "bytes", "list" }),
                    .minus, .star, .slash => return self.overload(left, right, &.{ "int", "uint", "double" }),
                    .percent => return self.overload(left, right, &.{ "int", "uint" }),
                    else => unreachable,
                }
            },
            .conditional => |conditional| {
                _ = try self.combine(try self.infer(conditional.condition, scope), try self.term("bool", &.{}));
                return self.combine(try self.infer(conditional.yes, scope), try self.infer(conditional.no, scope));
            },
            .list => |items| {
                var element = try self.term(null, &.{});
                for (items) |item| {
                    const inferred = try self.infer(item.value, scope);
                    element = try self.join(element, if (item.optional) try self.optionalPayload(inferred) else inferred);
                }
                return self.term("list", &.{element});
            },
            .map => |items| {
                var key = try self.term(null, &.{});
                var item_type = try self.term(null, &.{});
                for (items) |item| {
                    const current_key = try self.infer(item.key, scope);
                    if (!dynamic(current_key) and !oneOf(current_key, &.{ "bool", "int", "uint", "string" })) {
                        return error.TypeMismatch;
                    }
                    key = try self.join(key, current_key);
                    const inferred = try self.infer(item.value, scope);
                    item_type = try self.join(item_type, if (item.optional) try self.optionalPayload(inferred) else inferred);
                }
                return self.term("map", &.{ key, item_type });
            },
            .message => |m| {
                const desc = (try self.messageType(m.type_name)) orelse return error.UnsupportedType;
                var assigned: std.StringHashMapUnmanaged(void) = .empty;
                for (m.fields) |initializer| {
                    const descriptor_field = try proto.field(desc, initializer.name) orelse return error.TypeMismatch;
                    if ((try assigned.getOrPut(self.arena, initializer.name)).found_existing) return error.TypeMismatch;
                    const inferred = try self.infer(initializer.value, scope);
                    const input_type = if (initializer.optional) try self.optionalPayload(inferred) else inferred;
                    if (proto.kind(descriptor_field) != .message or proto.repeated(descriptor_field) or !is(input_type, "null_type")) {
                        _ = try self.combine(try self.fieldType(descriptor_field), input_type);
                    }
                }
                node.message.type_name = try self.arena.dupe(u8, proto.name(desc));
                return self.messageTerm(desc);
            },
            .call => {
                const result = try self.call(&node.call, scope);
                node.call.checked = true;
                if (node.call.function_indices != null)
                    try self.function_results.append(self.arena, .{ .call = &node.call, .type = result });
                return result;
            },
            .block => |b| {
                const slots = try self.arena.alloc(*Term, b.slots.len);
                const marker = try self.term("dyn", &.{});
                @memset(slots, marker);
                const local = Local{ .name = "", .type = marker, .block_types = slots, .parent = scope };
                for (b.slots, 0..) |initializer, i| slots[i] = try self.infer(initializer, &local);
                return self.infer(b.body, &local);
            },
            .block_index => |index| {
                var current = scope;
                while (current) |local| : (current = local.parent) {
                    try self.tick();
                    if (local.block_types) |slots| {
                        if (index >= slots.len) return error.UndeclaredReference;
                        return slots[index];
                    }
                }
                return error.UndeclaredReference;
            },
            .local_bind => |b| {
                const initializer = try self.infer(b.initializer, scope);
                const local = Local{ .name = b.name, .type = initializer, .parent = scope };
                return self.infer(b.body, &local);
            },
            .optional_map => |m| {
                const payload = try self.optionalPayload(try self.infer(m.target, scope));
                const local = Local{ .name = m.variable, .type = payload, .parent = scope };
                const body = try self.infer(m.body, &local);
                return if (m.flat) self.optional(try self.optionalPayload(body)) else self.optional(body);
            },
            .sort_by => |s| {
                const target = try self.infer(s.target, scope);
                if (!dynamic(target) and !is(target, "list")) return error.TypeMismatch;
                const item = if (is(target, "list")) peek(target).parameters[0] else try self.term("dyn", &.{});
                const local = Local{ .name = s.variable, .type = item, .parent = scope };
                if (!comparable(try self.infer(s.body, &local))) return error.TypeMismatch;
                return target;
            },
            .comprehension => |c| {
                const target = try self.infer(c.target, scope);
                if (!dynamic(target) and !is(target, "list") and !is(target, "map")) return error.TypeMismatch;
                const key = if (is(target, "list")) try self.term("int", &.{}) else if (is(target, "map"))
                    peek(target).parameters[0]
                else
                    try self.term("dyn", &.{});
                const item = if (is(target, "list")) peek(target).parameters[0] else if (is(target, "map"))
                    peek(target).parameters[1]
                else
                    try self.term("dyn", &.{});
                const first = Local{ .name = c.key_name, .type = if (c.value_name != null or is(target, "map")) key else item, .parent = scope };
                const second = Local{ .name = c.value_name orelse "", .type = item, .parent = &first };
                const local = if (c.value_name == null) &first else &second;
                if (c.predicate) |predicate| {
                    _ = try self.combine(try self.infer(predicate, local), try self.term("bool", &.{}));
                }
                const transformed = if (c.transform) |body| try self.infer(body, local) else first.type;
                return switch (c.kind) {
                    .all, .exists, .exists_one => self.term("bool", &.{}),
                    .list => self.term("list", &.{transformed}),
                    .map => self.term("map", &.{ key, transformed }),
                    .map_entries => if (is(transformed, "map")) transformed else if (dynamic(transformed))
                        self.term("map", &.{ try self.term("dyn", &.{}), try self.term("dyn", &.{}) })
                    else
                        error.TypeMismatch,
                };
            },
        }
    }

    fn call(self: *Checker, c: *syntax.Call, scope: ?*const Local) CheckError!*Term {
        c.function_indices = null;
        if (c.math_extrema) |_| {
            const arguments = try self.inferArguments(c.args, scope);
            return self.mathExtrema(arguments);
        }
        if (try self.customCall(c, scope)) |result| return result;
        if (c.target) |target| {
            const prefix = syntax.qualifiedName(self.arena, target) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (prefix) |qualified| {
                const full = try std.mem.concat(self.arena, u8, &.{ qualified, ".", c.name });
                const name = if (std.mem.startsWith(u8, full, ".")) full[1..] else full;
                if (math.operation(name) != null or encoders.operation(name, "") != null or
                    network.function(name, "") != null or
                    std.mem.eql(u8, name, "strings.quote") or
                    std.mem.eql(u8, name, "optional.of") or
                    std.mem.eql(u8, name, "optional.ofNonZeroValue") or
                    std.mem.eql(u8, name, "optional.none") or
                    std.mem.eql(u8, name, "optional.unwrap") or
                    std.mem.eql(u8, name, "lists.range"))
                {
                    c.target = null;
                    c.name = name;
                }
            }
        }
        if (c.target == null) if (encoders.operation(c.name, self.container)) |operation| {
            if (c.args.len != 1) return error.TypeMismatch;
            const argument = try self.infer(c.args[0], scope);
            const encode = operation == .encode or operation == .encodeUrl;
            const expected: []const u8 = if (encode) "bytes" else "string";
            if (!dynamic(argument) and !oneOf(argument, &.{expected})) return error.TypeMismatch;
            c.name = try std.mem.concat(self.arena, u8, &.{ ".base64.", @tagName(operation) });
            return self.term(if (encode) "string" else "bytes", &.{});
        };
        if (c.target == null) if (math.operation(c.name)) |operation| {
            return self.mathCall(operation, try self.inferArguments(c.args, scope));
        };
        var enum_type: ?[]const u8 = null;
        // CEL function names resolve independently of lexical variable bindings.
        if (self.strong_enums) {
            const qualified: ?[]const u8 = blk: {
                const target = c.target orelse break :blk c.name;
                const prefix = syntax.qualifiedName(self.arena, target) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk null,
                };
                break :blk try std.mem.concat(self.arena, u8, &.{ prefix, ".", c.name });
            };
            if (qualified) |full| {
                const absolute = std.mem.startsWith(u8, full, ".");
                const local = if (absolute) full[1..] else full;
                var prefix = if (absolute) "" else self.container;
                while (true) {
                    try self.tick();
                    const candidate = if (prefix.len == 0) local else try std.mem.concat(self.arena, u8, &.{ prefix, ".", local });
                    if (try proto.enumType(self.registry, candidate)) |type_name| {
                        enum_type = type_name;
                        c.target = null;
                        c.name = try std.mem.concat(self.arena, u8, &.{ ".", type_name });
                        break;
                    }
                    if (prefix.len == 0) break;
                    prefix = names.parent(prefix);
                }
            }
        }
        const name = if (c.target == null and std.mem.startsWith(u8, c.name, ".")) c.name[1..] else c.name;
        var arguments: std.ArrayList(*Term) = .empty;
        if (c.target) |target| try arguments.append(self.arena, try self.infer(target, scope));
        for (c.args) |argument| try arguments.append(self.arena, try self.infer(argument, scope));
        const args = arguments.items;
        if (enum_type) |type_name| {
            if (args.len != 1 or (!dynamic(args[0]) and !oneOf(args[0], &.{ "int", "string" }))) return error.TypeMismatch;
            return self.term(type_name, &.{});
        }
        const network_operation = if (c.target == null) network.function(c.name, self.container) else network.method(name);
        if (network_operation) |operation| {
            const signature = network.signature(operation);
            if (args.len != signature.parameters.len) return error.TypeMismatch;
            for (args, signature.parameters, 0..) |argument, parameter, i| {
                if (dynamic(argument)) continue;
                if (i == 1 and (operation == .containsIP or operation == .containsCIDR) and is(argument, "string")) continue;
                const actual = peek(argument);
                if (actual.kind != parameter.kind or actual.name == null or
                    !std.mem.eql(u8, actual.name.?, parameter.name) or actual.parameters.len != 0) return error.TypeMismatch;
            }
            return self.typedTerm(signature.result.kind, signature.result.name, &.{});
        }
        if (std.mem.eql(u8, name, "string") and args.len == 1 and isNetwork(args[0])) return self.term("string", &.{});
        if (std.mem.eql(u8, name, "lists.range") or (c.target == null and
            std.mem.eql(u8, c.name, "range") and (std.mem.eql(u8, self.container, "lists") or
            std.mem.startsWith(u8, self.container, "lists."))))
        {
            c.name = "lists.range";
            if (args.len != 1 or (!dynamic(args[0]) and !is(args[0], "int"))) return error.TypeMismatch;
            return self.term("list", &.{try self.term("int", &.{})});
        }
        if (c.target != null and std.mem.eql(u8, name, "slice")) {
            if (args.len != 3 or (!dynamic(args[0]) and !is(args[0], "list"))) return error.TypeMismatch;
            for (args[1..]) |argument| {
                if (!dynamic(argument) and !is(argument, "int")) return error.TypeMismatch;
            }
            return args[0];
        }
        if (c.target != null and std.mem.eql(u8, name, "flatten")) {
            if (args.len < 1 or args.len > 2 or (!dynamic(args[0]) and !is(args[0], "list")) or
                (args.len == 2 and !dynamic(args[1]) and !is(args[1], "int"))) return error.TypeMismatch;
            return self.term("list", &.{try self.term("dyn", &.{})});
        }
        if (c.target != null and (std.mem.eql(u8, name, "distinct") or
            (std.mem.eql(u8, name, "reverse") and !is(numericPrimitive(args[0]), "string"))))
        {
            if (args.len != 1 or (!dynamic(args[0]) and !is(args[0], "list"))) return error.TypeMismatch;
            return args[0];
        }
        if (c.target != null and std.mem.eql(u8, name, "sort")) {
            if (args.len != 1 or (!dynamic(args[0]) and !is(args[0], "list"))) return error.TypeMismatch;
            if (is(args[0], "list") and !comparable(peek(args[0]).parameters[0])) return error.TypeMismatch;
            return args[0];
        }
        if (std.mem.eql(u8, name, "optional.none")) {
            if (args.len != 0) return error.TypeMismatch;
            return self.optional(try self.term(null, &.{}));
        }
        if (std.mem.eql(u8, name, "optional.of") or std.mem.eql(u8, name, "optional.ofNonZeroValue")) {
            if (args.len != 1) return error.TypeMismatch;
            return self.optional(args[0]);
        }
        if (std.mem.eql(u8, name, "optional.unwrap")) {
            if (args.len != 1) return error.TypeMismatch;
            return self.unwrapOptionalList(args[0]);
        }
        if (c.target != null and std.mem.eql(u8, name, "hasValue")) {
            if (args.len < 1 or args.len > 2) return error.TypeMismatch;
            const payload = try self.optionalPayload(args[0]);
            if (args.len == 2) _ = try self.combine(payload, args[1]);
            return self.term("bool", &.{});
        }
        if (c.target != null and std.mem.eql(u8, name, "value")) {
            if (args.len != 1) return error.TypeMismatch;
            return self.optionalPayload(args[0]);
        }
        if (c.target != null and std.mem.eql(u8, name, "or")) {
            if (args.len != 2) return error.TypeMismatch;
            return self.optional(try self.combine(
                try self.optionalPayload(args[0]),
                try self.optionalPayload(args[1]),
            ));
        }
        if (c.target != null and std.mem.eql(u8, name, "orValue")) {
            if (args.len != 2) return error.TypeMismatch;
            return self.combine(try self.optionalPayload(args[0]), args[1]);
        }
        if (c.target != null and std.mem.eql(u8, name, "unwrapOpt")) {
            if (args.len != 1) return error.TypeMismatch;
            return self.unwrapOptionalList(args[0]);
        }
        if (c.target != null and (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last"))) {
            if (args.len != 1) return error.TypeMismatch;
            if (dynamic(args[0])) return self.optional(try self.term("dyn", &.{}));
            if (!is(args[0], "list")) return error.TypeMismatch;
            return self.optional(peek(args[0]).parameters[0]);
        }
        const quote = c.target == null and (std.mem.eql(u8, name, "strings.quote") or
            (std.mem.eql(u8, c.name, "quote") and (std.mem.eql(u8, self.container, "strings") or
                std.mem.startsWith(u8, self.container, "strings."))));
        if (quote) {
            if (args.len != 1 or (!dynamic(args[0]) and !oneOf(args[0], &.{"string"}))) return error.TypeMismatch;
            c.name = "strings.quote";
            return self.term("string", &.{});
        }
        if (c.target != null and std.mem.eql(u8, name, "format")) {
            if (args.len != 2 or (!dynamic(args[0]) and !oneOf(args[0], &.{"string"})) or
                (!dynamic(args[1]) and !is(args[1], "list"))) return error.TypeMismatch;
            return self.term("string", &.{});
        }
        if (c.target != null) if (strings.method(name)) |operation| {
            if (operation == .join) {
                if (args.len < 1 or args.len > 2) return error.TypeMismatch;
                if (!dynamic(args[0])) {
                    if (!is(args[0], "list")) return error.TypeMismatch;
                    const element = peek(args[0]).parameters[0];
                    if (!dynamic(element) and !oneOf(element, &.{"string"})) return error.TypeMismatch;
                }
                if (args.len == 2 and !dynamic(args[1]) and !oneOf(args[1], &.{"string"})) return error.TypeMismatch;
                return self.term("string", &.{});
            }
            if (args.len == 0 or (!dynamic(args[0]) and !oneOf(args[0], &.{"string"}))) return error.TypeMismatch;
            const minimum: usize = switch (operation) {
                .charAt, .indexOf, .lastIndexOf, .split, .substring => 2,
                .replace => 3,
                else => 1,
            };
            const maximum: usize = switch (operation) {
                .indexOf, .lastIndexOf, .split, .substring => 3,
                .replace => 4,
                else => minimum,
            };
            if (args.len < minimum or args.len > maximum) return error.TypeMismatch;
            for (args[1..], 1..) |argument, index| {
                const expected: []const u8 = if ((operation == .indexOf or operation == .lastIndexOf or operation == .split) and index == 1)
                    "string"
                else if (operation == .replace and index < 3) "string" else "int";
                if (!dynamic(argument) and !oneOf(argument, &.{expected})) return error.TypeMismatch;
            }
            return switch (operation) {
                .indexOf, .lastIndexOf => self.term("int", &.{}),
                .split => self.term("list", &.{try self.term("string", &.{})}),
                else => self.term("string", &.{}),
            };
        };
        if (c.target != null) if (temporal.selector(name)) |selector| {
            if (args.len == 0 or args.len > 2) return error.TypeMismatch;
            if (args.len == 2) _ = try self.combine(args[1], try self.term("string", &.{}));
            if (!dynamic(args[0]) and !is(args[0], "google.protobuf.Timestamp") and
                !(is(args[0], "google.protobuf.Duration") and args.len == 1 and
                    (selector == 5 or selector == 6 or selector == 7 or selector == 9))) return error.TypeMismatch;
            return self.term("int", &.{});
        };
        if (std.mem.eql(u8, name, "size") and args.len == 1) {
            if (!dynamic(args[0]) and !oneOf(args[0], &.{ "string", "bytes", "list", "map" })) return error.TypeMismatch;
            return self.term("int", &.{});
        }
        if (args.len == 2 and (std.mem.eql(u8, name, "matches") or (c.target != null and
            (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "startsWith") or std.mem.eql(u8, name, "endsWith")))))
        {
            for (args) |arg| _ = try self.combine(arg, try self.term("string", &.{}));
            return self.term("bool", &.{});
        }
        if (c.target != null or args.len != 1) return error.TypeMismatch;
        if (std.mem.eql(u8, name, "dyn")) return self.term("dyn", &.{});
        if (std.mem.eql(u8, name, "type")) {
            return self.term("type", if (isOptional(args[0])) &.{} else args);
        }
        if (std.mem.eql(u8, name, "timestamp")) {
            if (!dynamic(args[0]) and !oneOf(args[0], &.{ "string", "int", "google.protobuf.Timestamp" })) return error.TypeMismatch;
            return self.term("google.protobuf.Timestamp", &.{});
        }
        if (std.mem.eql(u8, name, "duration")) {
            if (!dynamic(args[0]) and !oneOf(args[0], &.{ "string", "google.protobuf.Duration" })) return error.TypeMismatch;
            return self.term("google.protobuf.Duration", &.{});
        }
        if (std.mem.eql(u8, name, "int") and (is(args[0], "google.protobuf.Timestamp") or
            (peek(args[0]).kind == .concrete and peek(args[0]).name != null and
                try proto.enumType(self.registry, peek(args[0]).name.?) != null)))
            return self.term("int", &.{});
        const allowed: []const []const u8 = if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "uint") or
            std.mem.eql(u8, name, "double")) &.{ "int", "uint", "double", "string" } else if (std.mem.eql(u8, name, "bool")) &.{ "bool", "string" } else if (std.mem.eql(u8, name, "string")) &.{ "bool", "int", "uint", "double", "string", "bytes", "google.protobuf.Timestamp", "google.protobuf.Duration" } else if (std.mem.eql(u8, name, "bytes")) &.{ "string", "bytes" } else return error.TypeMismatch;
        if (!dynamic(args[0]) and !oneOf(args[0], allowed)) return error.TypeMismatch;
        return self.term(name, &.{});
    }

    fn inferArguments(self: *Checker, source: []const *const Node, scope: ?*const Local) CheckError![]const *Term {
        const arguments = try self.arena.alloc(*Term, source.len);
        for (source, arguments) |argument, *output| output.* = try self.infer(argument, scope);
        return arguments;
    }

    fn mathExtrema(self: *Checker, arguments: []const *Term) CheckError!*Term {
        if (arguments.len == 0) return error.TypeMismatch;
        if (arguments.len == 1) {
            const argument = numericPrimitive(arguments[0]);
            if (dynamic(argument)) return self.term("dyn", &.{});
            if (is(argument, "list")) {
                const element = numericPrimitive(peek(argument).parameters[0]);
                if (!dynamic(element) and !oneOf(element, &.{ "int", "uint", "double" })) return error.TypeMismatch;
                return if (dynamic(element)) self.term("dyn", &.{}) else element;
            }
            if (!oneOf(argument, &.{ "int", "uint", "double" })) return error.TypeMismatch;
            return argument;
        }
        var result: ?*Term = null;
        var mixed = false;
        for (arguments) |input| {
            const argument = numericPrimitive(input);
            if (dynamic(argument)) {
                mixed = true;
                continue;
            }
            if (!oneOf(argument, &.{ "int", "uint", "double" })) return error.TypeMismatch;
            if (result) |current| {
                mixed = mixed or !std.mem.eql(u8, peek(current).name.?, peek(argument).name.?);
            } else {
                result = argument;
            }
        }
        return if (mixed or result == null) self.term("dyn", &.{}) else result.?;
    }

    fn mathCall(self: *Checker, operation: math.Operation, arguments: []const *Term) CheckError!*Term {
        const arity: usize = switch (operation) {
            .bitAnd, .bitOr, .bitXor, .bitShiftLeft, .bitShiftRight => 2,
            else => 1,
        };
        if (arguments.len != arity) return error.TypeMismatch;
        const first = numericPrimitive(arguments[0]);
        return switch (operation) {
            .greatest, .least => self.mathExtrema(arguments),
            .ceil, .floor, .round, .trunc => blk: {
                if (!dynamic(first) and !is(first, "double")) return error.TypeMismatch;
                break :blk self.term("double", &.{});
            },
            .isNaN, .isInf, .isFinite => blk: {
                if (!dynamic(first) and !is(first, "double")) return error.TypeMismatch;
                break :blk self.term("bool", &.{});
            },
            .abs, .sign => blk: {
                if (!dynamic(first) and !oneOf(first, &.{ "int", "uint", "double" })) return error.TypeMismatch;
                break :blk if (dynamic(first)) self.term("dyn", &.{}) else first;
            },
            .bitNot => blk: {
                if (!dynamic(first) and !oneOf(first, &.{ "int", "uint" })) return error.TypeMismatch;
                break :blk if (dynamic(first)) self.term("dyn", &.{}) else first;
            },
            .bitAnd, .bitOr, .bitXor => self.overload(first, numericPrimitive(arguments[1]), &.{ "int", "uint" }),
            .bitShiftLeft, .bitShiftRight => blk: {
                const offset = numericPrimitive(arguments[1]);
                if ((!dynamic(first) and !oneOf(first, &.{ "int", "uint" })) or
                    (!dynamic(offset) and !is(offset, "int"))) return error.TypeMismatch;
                break :blk if (dynamic(first)) self.term("dyn", &.{}) else first;
            },
        };
    }

    fn customCall(self: *Checker, c: *syntax.Call, scope: ?*const Local) CheckError!?*Term {
        if (self.functions.len == 0) return null;
        const qualified: ?[]const u8 = if (c.target) |target| blk: {
            const prefix = syntax.qualifiedName(self.arena, target) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk null,
            };
            break :blk try std.mem.concat(self.arena, u8, &.{ prefix, ".", c.name });
        } else c.name;
        if (qualified) |full| {
            const absolute = std.mem.startsWith(u8, full, ".");
            const local = if (absolute) full[1..] else full;
            var prefix = if (absolute) "" else self.container;
            while (true) {
                const candidate = if (prefix.len == 0) local else try std.mem.concat(
                    self.arena,
                    u8,
                    &.{ prefix, ".", local },
                );
                var found = false;
                for (self.functions) |function| {
                    try self.tick();
                    if (!function.member and std.mem.eql(u8, function.name, candidate)) found = true;
                }
                if (found) {
                    c.target = null;
                    c.name = candidate;
                    const arguments = try self.arena.alloc(*Term, c.args.len);
                    for (c.args, arguments) |argument, *output| output.* = try self.infer(argument, scope);
                    return try self.customOverloads(c, arguments, candidate, false);
                }
                if (prefix.len == 0) break;
                prefix = names.parent(prefix);
            }
        }
        if (c.target == null) return null;
        const local = if (std.mem.startsWith(u8, c.name, ".")) c.name[1..] else c.name;
        var prefix = if (std.mem.startsWith(u8, c.name, ".")) "" else self.container;
        while (true) {
            const candidate = if (prefix.len == 0) local else try std.mem.concat(
                self.arena,
                u8,
                &.{ prefix, ".", local },
            );
            var found = false;
            for (self.functions) |function| {
                try self.tick();
                if (function.member and std.mem.eql(u8, function.name, candidate)) found = true;
            }
            if (found) {
                c.name = candidate;
                const arguments = try self.arena.alloc(*Term, c.args.len + 1);
                arguments[0] = try self.infer(c.target.?, scope);
                for (c.args, arguments[1..]) |argument, *output| output.* = try self.infer(argument, scope);
                return try self.customOverloads(c, arguments, candidate, true);
            }
            if (prefix.len == 0) return null;
            prefix = names.parent(prefix);
        }
    }

    fn customOverloads(
        self: *Checker,
        c: *syntax.Call,
        arguments: []const *Term,
        name: []const u8,
        member: bool,
    ) CheckError!*Term {
        var candidates: std.ArrayList(usize) = .empty;
        for (self.functions, 0..) |function, index| {
            try self.tick();
            if (function.member == member and std.mem.eql(u8, function.name, name) and
                function.parameters.len == arguments.len) try candidates.append(self.arena, index);
        }
        if (candidates.items.len == 0) return error.TypeMismatch;
        if (candidates.items.len == 1) {
            const result = try self.applyFunction(self.functions[candidates.items[0]], arguments);
            c.function_indices = try candidates.toOwnedSlice(self.arena);
            return result;
        }
        var indices: std.ArrayList(usize) = .empty;
        var result: ?*Term = null;
        for (candidates.items) |index| {
            const candidate = (try self.matchFunction(self.functions[index], arguments)) orelse continue;
            try indices.append(self.arena, index);
            const candidate_term = try self.fromType(candidate, 0);
            result = if (result) |previous| try self.join(previous, candidate_term) else candidate_term;
        }
        if (result == null) return error.TypeMismatch;
        if (indices.items.len == 1) {
            const selected = indices.items[0];
            c.function_indices = try indices.toOwnedSlice(self.arena);
            return self.applyFunction(self.functions[selected], arguments);
        }
        c.function_indices = try indices.toOwnedSlice(self.arena);
        return result.?;
    }

    fn matchFunction(self: *Checker, function: Function, arguments: []const *Term) CheckError!?Type {
        const checkpoint = self.changes.items.len;
        defer self.rollback(checkpoint);
        var variables: std.StringHashMapUnmanaged(*Term) = .empty;
        const parameters = try self.arena.alloc(*Term, function.parameters.len);
        for (function.parameters, parameters) |parameter, *output| {
            output.* = try self.instantiate(parameter, &variables, 0);
        }
        const result = try self.instantiate(function.result, &variables, 0);
        for (arguments, parameters) |actual, expected| {
            _ = self.unify(actual, expected, 0) catch |err| switch (err) {
                error.TypeMismatch => return null,
                else => return err,
            };
        }
        return try self.finish(result, 0);
    }

    fn applyFunction(self: *Checker, function: Function, arguments: []const *Term) CheckError!*Term {
        const checkpoint = self.changes.items.len;
        errdefer self.rollback(checkpoint);
        var variables: std.StringHashMapUnmanaged(*Term) = .empty;
        const parameters = try self.arena.alloc(*Term, function.parameters.len);
        for (function.parameters, parameters) |parameter, *output| {
            output.* = try self.instantiate(parameter, &variables, 0);
        }
        const result = try self.instantiate(function.result, &variables, 0);
        for (arguments, parameters) |actual, expected| _ = try self.unify(actual, expected, 0);
        self.changes.clearRetainingCapacity();
        return result;
    }

    fn instantiate(
        self: *Checker,
        declaration: Type,
        variables: *std.StringHashMapUnmanaged(*Term),
        depth: usize,
    ) CheckError!*Term {
        if (depth >= self.max_depth) return error.DepthLimitExceeded;
        if (declaration.kind == .parameter) {
            const entry = try variables.getOrPut(self.arena, declaration.name);
            if (!entry.found_existing) entry.value_ptr.* = try self.term(null, &.{});
            return entry.value_ptr.*;
        }
        if (declaration.kind == .concrete and declaration.parameters.len == 0) {
            return self.fromType(declaration, depth);
        }
        const parameters = try self.arena.alloc(*Term, declaration.parameters.len);
        for (declaration.parameters, parameters) |parameter, *output| {
            output.* = try self.instantiate(parameter, variables, depth + 1);
        }
        return self.typedTerm(declaration.kind, declaration.name, parameters);
    }

    fn optional(self: *Checker, payload: *Term) CheckError!*Term {
        return self.typedTerm(.abstract, "optional_type", &.{payload});
    }

    fn optionalPayload(self: *Checker, input: *Term) CheckError!*Term {
        if (dynamic(input)) return self.term("dyn", &.{});
        const optional_type = peek(input);
        if (!isOptional(optional_type) or optional_type.parameters.len != 1) return error.TypeMismatch;
        return optional_type.parameters[0];
    }

    fn unwrapOptionalList(self: *Checker, input: *Term) CheckError!*Term {
        if (dynamic(input)) return self.term("list", &.{try self.term("dyn", &.{})});
        if (!is(input, "list")) return error.TypeMismatch;
        return self.term("list", &.{try self.optionalPayload(peek(input).parameters[0])});
    }

    fn select(self: *Checker, target: *Term, field_name: []const u8, optional_access: bool) CheckError!*Term {
        const wrapped = optional_access or isOptional(target);
        const input = if (isOptional(target)) try self.optionalPayload(target) else target;
        const selected = try self.field(input, field_name);
        return if (wrapped) self.optional(selected) else selected;
    }

    fn inferIndex(self: *Checker, target: *Term, key: *Term, optional_access: bool) CheckError!*Term {
        const wrapped = optional_access or isOptional(target);
        const input = if (isOptional(target)) try self.optionalPayload(target) else target;
        if (dynamic(input)) {
            const result = try self.term("dyn", &.{});
            return if (wrapped) self.optional(result) else result;
        }
        const concrete = peek(input);
        const result = if (is(input, "list")) blk: {
            _ = try self.combine(key, try self.term("int", &.{}));
            break :blk concrete.parameters[0];
        } else if (is(input, "map")) blk: {
            _ = try self.combine(key, concrete.parameters[0]);
            break :blk concrete.parameters[1];
        } else return error.TypeMismatch;
        return if (wrapped) self.optional(result) else result;
    }

    fn field(self: *Checker, target: *Term, field_name: []const u8) CheckError!*Term {
        if (dynamic(target)) return self.term("dyn", &.{});
        if (is(target, "map")) {
            _ = try self.combine(peek(target).parameters[0], try self.term("string", &.{}));
            return peek(target).parameters[1];
        }
        if (peek(target).kind != .concrete) return error.TypeMismatch;
        const desc = try proto.descriptor(self.registry, peek(target).name.?) orelse return error.TypeMismatch;
        return self.fieldType(try proto.field(desc, field_name) orelse return error.TypeMismatch);
    }

    fn fieldType(self: *Checker, f: *const proto.Field) CheckError!*Term {
        if (proto.isMap(f)) return self.term("map", &.{ try self.fieldType(proto.mapKey(f)), try self.fieldType(proto.mapValue(f)) });
        const scalar = switch (proto.kind(f)) {
            .message => try self.messageTerm(proto.fieldMessage(f)),
            .enum_value => try self.term(if (self.strong_enums) proto.fieldEnum(f) else "int", &.{}),
            else => try self.term(@tagName(proto.kind(f)), &.{}),
        };
        return if (proto.repeated(f)) self.term("list", &.{scalar}) else scalar;
    }

    fn messageTerm(self: *Checker, desc: *const proto.Descriptor) CheckError!*Term {
        const type_name = proto.name(desc);
        if (std.mem.eql(u8, type_name, "google.protobuf.Any") or std.mem.eql(u8, type_name, "google.protobuf.Value")) {
            return self.term("dyn", &.{});
        }
        if (std.mem.eql(u8, type_name, "google.protobuf.Struct")) return self.term("map", &.{
            try self.term("string", &.{}), try self.term("dyn", &.{}),
        });
        if (std.mem.eql(u8, type_name, "google.protobuf.ListValue")) return self.term("list", &.{try self.term("dyn", &.{})});
        const wrappers = std.StaticStringMap([]const u8).initComptime(.{
            .{ "google.protobuf.Int32Value", "int" },    .{ "google.protobuf.Int64Value", "int" },
            .{ "google.protobuf.UInt32Value", "uint" },  .{ "google.protobuf.UInt64Value", "uint" },
            .{ "google.protobuf.FloatValue", "double" }, .{ "google.protobuf.DoubleValue", "double" },
            .{ "google.protobuf.BoolValue", "bool" },    .{ "google.protobuf.StringValue", "string" },
            .{ "google.protobuf.BytesValue", "bytes" },
        });
        if (wrappers.get(type_name)) |primitive| return self.term("wrapper", &.{try self.term(primitive, &.{})});
        return self.term(type_name, &.{});
    }

    fn messageType(self: *Checker, type_name: []const u8) CheckError!?*const proto.Descriptor {
        const absolute = std.mem.startsWith(u8, type_name, ".");
        const local = if (absolute) type_name[1..] else type_name;
        var prefix = if (absolute) "" else self.container;
        while (true) {
            try self.tick();
            const candidate = if (prefix.len == 0) local else try std.mem.concat(self.arena, u8, &.{ prefix, ".", local });
            if (try proto.descriptor(self.registry, candidate)) |desc| return desc;
            if (prefix.len == 0) return null;
            prefix = names.parent(prefix);
        }
    }

    fn resolve(self: *Checker, node: *Node) CheckError!?*Term {
        const root = names.root(node);
        var prefix = if (std.mem.startsWith(u8, root, ".")) "" else self.container;
        while (true) {
            for (self.constants) |binding| {
                try self.tick();
                if (names.matches(node, binding.name, prefix)) {
                    node.* = .{ .literal = binding.value };
                    return self.literal(binding.value);
                }
            }
            for (self.variables) |declaration| {
                try self.tick();
                if (names.matches(node, declaration.name, prefix)) {
                    node.* = .{ .variable = declaration.name };
                    return self.fromType(declaration.type, 0);
                }
            }
            for ([_][]const u8{ "net.IP", "net.CIDR" }) |type_name| {
                if (names.matches(node, type_name, prefix)) {
                    node.* = .{ .literal = .{ .type_value = type_name } };
                    return self.literal(node.literal);
                }
            }
            if (self.registry != null or std.mem.startsWith(u8, root, "google") or
                std.mem.startsWith(u8, root, ".google") or std.mem.startsWith(u8, prefix, "google"))
            {
                const qualified = syntax.qualifiedName(self.arena, node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.TypeMismatch,
                };
                const local = if (std.mem.startsWith(u8, qualified, ".")) qualified[1..] else qualified;
                const candidate = if (prefix.len == 0) local else try std.mem.concat(self.arena, u8, &.{ prefix, ".", local });
                if (try proto.enumValue(self.registry, candidate)) |item| {
                    node.* = .{ .literal = if (self.strong_enums) try value.Value.fromEnum(self.arena, item) else .{ .int = item.number } };
                    return self.literal(node.literal);
                }
                if (self.strong_enums) if (try proto.enumType(self.registry, candidate)) |type_name| {
                    node.* = .{ .literal = .{ .type_value = try self.arena.dupe(u8, type_name) } };
                    return self.literal(node.literal);
                };
                if (try proto.descriptor(self.registry, candidate)) |desc| {
                    const type_name = try self.arena.dupe(u8, proto.name(desc));
                    node.* = .{ .literal = .{ .type_value = type_name } };
                    return self.literal(node.literal);
                }
            }
            if (prefix.len == 0) break;
            prefix = names.parent(prefix);
        }
        if (node.* == .ident) {
            const name = if (std.mem.startsWith(u8, root, ".")) root[1..] else root;
            for ([_][]const u8{
                "bool", "bytes", "double", "int", "list", "map", "null_type", "optional_type", "string", "type", "uint",
            }) |builtin| {
                if (std.mem.eql(u8, name, builtin)) {
                    node.* = .{ .literal = .{ .type_value = builtin } };
                    return self.literal(node.literal);
                }
            }
        }
        return null;
    }

    fn literal(self: *Checker, v: value.Value) CheckError!*Term {
        try self.tick();
        switch (v) {
            .list => |items| {
                var element = try self.term(null, &.{});
                for (items) |item| element = try self.join(element, try self.literal(item));
                return self.term("list", &.{element});
            },
            .map => |entries| {
                var key = try self.term(null, &.{});
                var element = try self.term(null, &.{});
                for (entries) |entry| {
                    key = try self.join(key, try self.literal(entry.key));
                    element = try self.join(element, try self.literal(entry.value));
                }
                return self.term("map", &.{ key, element });
            },
            .type_value => |name| {
                const described = if (std.mem.eql(u8, name, "list"))
                    try self.term("list", &.{try self.term("dyn", &.{})})
                else if (std.mem.eql(u8, name, "map"))
                    try self.term("map", &.{ try self.term("dyn", &.{}), try self.term("dyn", &.{}) })
                else if (std.mem.eql(u8, name, "net.IP") or std.mem.eql(u8, name, "net.CIDR"))
                    try self.typedTerm(.abstract, name, &.{})
                else if (std.mem.eql(u8, name, "optional_type"))
                    try self.optional(try self.term("dyn", &.{}))
                else
                    try self.term(name, &.{});
                return self.term("type", &.{described});
            },
            .message => |message| {
                const desc = try proto.descriptor(self.registry, message.type_name) orelse return error.UnsupportedType;
                return self.messageTerm(desc);
            },
            .ip => return self.typedTerm(.abstract, "net.IP", &.{}),
            .cidr => return self.typedTerm(.abstract, "net.CIDR", &.{}),
            .enum_value => |item| return self.term(item.type_name, &.{}),
            .timestamp => return self.term("google.protobuf.Timestamp", &.{}),
            .duration => return self.term("google.protobuf.Duration", &.{}),
            .optional => |payload| return self.optional(if (payload) |present|
                try self.literal(present.*)
            else
                try self.term(null, &.{})),
            .null => return self.term("null_type", &.{}),
            else => return self.term(@tagName(v), &.{}),
        }
    }

    fn fromType(self: *Checker, t: Type, depth: usize) CheckError!*Term {
        if (depth >= self.max_depth) return error.DepthLimitExceeded;
        if (t.kind == .parameter) return error.UnsupportedType;
        if (t.kind == .concrete and t.parameters.len == 0) {
            if (try proto.descriptor(self.registry, t.name)) |desc| return self.messageTerm(desc);
        }
        const parameters = try self.arena.alloc(*Term, t.parameters.len);
        for (t.parameters, parameters) |p, *out| out.* = try self.fromType(p, depth + 1);
        return self.typedTerm(t.kind, t.name, parameters);
    }

    fn finish(self: *Checker, input: *Term, depth: usize) CheckError!Type {
        try self.tick();
        if (depth >= self.max_depth) return error.DepthLimitExceeded;
        const t = peek(input);
        const parameters = try self.arena.alloc(Type, t.parameters.len);
        for (t.parameters, parameters) |p, *out| out.* = try self.finish(p, depth + 1);
        return .{
            .name = t.name orelse "dyn",
            .parameters = parameters,
            .kind = if (t.name == null) .concrete else t.kind,
        };
    }

    fn overload(self: *Checker, left: *Term, right: *Term, allowed: []const []const u8) CheckError!*Term {
        const a = if (is(left, "wrapper")) peek(left).parameters[0] else left;
        const b = if (is(right, "wrapper")) peek(right).parameters[0] else right;
        if ((!dynamic(a) and !oneOf(a, allowed)) or (!dynamic(b) and !oneOf(b, allowed))) return error.TypeMismatch;
        if (dynamic(a) and dynamic(b)) return self.term("dyn", &.{});
        const merged = try self.combine(a, b);
        if (dynamic(a)) return b;
        if (dynamic(b)) return a;
        return merged;
    }

    fn join(self: *Checker, a: *Term, b: *Term) CheckError!*Term {
        return self.combine(a, b) catch |err| switch (err) {
            error.TypeMismatch => self.term("dyn", &.{}),
            else => return err,
        };
    }

    fn combine(self: *Checker, a: *Term, b: *Term) CheckError!*Term {
        const result = self.unify(a, b, 0) catch |err| {
            self.rollback(0);
            return err;
        };
        self.changes.clearRetainingCapacity();
        return result;
    }

    fn rollback(self: *Checker, checkpoint: usize) void {
        var index = self.changes.items.len;
        while (index > checkpoint) {
            index -= 1;
            const change = self.changes.items[index];
            change.variable.* = change.previous;
        }
        self.changes.items.len = checkpoint;
    }

    fn unify(self: *Checker, left: *Term, right: *Term, depth: usize) CheckError!*Term {
        try self.tick();
        if (depth >= self.max_depth) return error.DepthLimitExceeded;
        var a = representative(left);
        var b = representative(right);
        if (a == b) return a;
        if (a.name == null and b.name == null) {
            if (a.binding) |bound| if (try self.occurs(b, bound, depth + 1)) return error.TypeMismatch;
            if (b.binding) |bound| if (try self.occurs(a, bound, depth + 1)) return error.TypeMismatch;
            const constraint = if (a.binding) |x| if (b.binding) |y| try self.unify(x, y, depth + 1) else x else b.binding;
            if (a.rank < b.rank) std.mem.swap(*Term, &a, &b);
            try self.changes.append(self.arena, .{ .variable = a, .previous = a.* });
            try self.changes.append(self.arena, .{ .variable = b, .previous = b.* });
            b.parent = a;
            a.binding = constraint;
            if (a.rank == b.rank) a.rank += 1;
            return a;
        }
        if (a.name == null) {
            const merged = if (a.binding) |bound| try self.unify(bound, b, depth + 1) else blk: {
                if (try self.occurs(a, b, depth + 1)) return error.TypeMismatch;
                break :blk b;
            };
            try self.changes.append(self.arena, .{ .variable = a, .previous = a.* });
            a.binding = merged;
            return a;
        }
        if (b.name == null) return self.unify(b, a, depth + 1);
        if (is(a, "dyn")) return a;
        if (is(b, "dyn")) return b;
        if (is(a, "wrapper")) {
            if (is(b, "null_type")) return a;
            const other = if (is(b, "wrapper")) b.parameters[0] else b;
            return self.term("wrapper", &.{try self.unify(a.parameters[0], other, depth + 1)});
        }
        if (is(b, "wrapper")) return self.unify(b, a, depth + 1);
        if (is(a, "null_type") and ((b.kind == .concrete and
            try proto.descriptor(self.registry, b.name.?) != null) or b.kind == .abstract)) return b;
        if (is(b, "null_type") and ((a.kind == .concrete and
            try proto.descriptor(self.registry, a.name.?) != null) or a.kind == .abstract)) return a;
        if (a.kind != b.kind or !std.mem.eql(u8, a.name.?, b.name.?)) return error.TypeMismatch;
        if (is(a, "type")) return self.term("type", &.{});
        if (a.parameters.len != b.parameters.len) return error.TypeMismatch;
        const parameters = try self.arena.alloc(*Term, a.parameters.len);
        for (a.parameters, b.parameters, parameters) |x, y, *out| out.* = try self.unify(x, y, depth + 1);
        return self.typedTerm(a.kind, a.name, parameters);
    }

    fn occurs(self: *Checker, variable: *Term, input: *Term, depth: usize) CheckError!bool {
        const t = representative(input);
        try self.tick();
        if (depth >= self.max_depth) return error.DepthLimitExceeded;
        if (variable == t) return true;
        if (t.binding) |bound| return self.occurs(variable, bound, depth + 1);
        for (t.parameters) |parameter| if (try self.occurs(variable, parameter, depth + 1)) return true;
        return false;
    }
};

fn representative(t: *Term) *Term {
    var current = t;
    while (current.parent) |parent| current = parent;
    return current;
}

fn peek(t: *Term) *Term {
    var current = representative(t);
    while (current.binding) |binding| current = representative(binding);
    return current;
}

fn is(t: *Term, name: []const u8) bool {
    const input = peek(t);
    return input.kind == .concrete and if (input.name) |n| std.mem.eql(u8, n, name) else false;
}

fn isNetwork(t: *Term) bool {
    const input = peek(t);
    return input.kind == .abstract and input.parameters.len == 0 and if (input.name) |name|
        std.mem.eql(u8, name, "net.IP") or std.mem.eql(u8, name, "net.CIDR")
    else
        false;
}

fn isOptional(t: *Term) bool {
    const input = peek(t);
    return input.kind == .abstract and if (input.name) |name| std.mem.eql(u8, name, "optional_type") else false;
}

fn dynamic(t: *Term) bool {
    return peek(t).name == null or is(t, "dyn");
}

fn numericPrimitive(t: *Term) *Term {
    return if (is(t, "wrapper")) peek(t).parameters[0] else t;
}

fn comparable(t: *Term) bool {
    const input = numericPrimitive(t);
    if (dynamic(input)) return true;
    for ([_][]const u8{
        "int", "uint", "double", "bool", "string", "bytes", "google.protobuf.Timestamp", "google.protobuf.Duration",
    }) |name| if (is(input, name)) return true;
    return false;
}

fn oneOf(t: *Term, options: []const []const u8) bool {
    const input = numericPrimitive(t);
    for (options) |name| if (is(input, name)) return true;
    return false;
}
