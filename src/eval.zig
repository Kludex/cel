//! Bounded CEL tree evaluator. Results borrow program/input storage or live in the supplied arena.

const std = @import("std");
const syntax = @import("syntax.zig");
const value = @import("value.zig");
const regex = @import("regex.zig");
const names = @import("names.zig");
const proto = @import("proto.zig");
const temporal = @import("temporal.zig");
const math_ext = @import("math.zig");
const strings = @import("strings.zig");
const string_format = @import("string_format.zig");
const encoders = @import("encoders.zig");
const network = @import("network_functions.zig");
const functions = @import("functions.zig");
const Value = value.Value;
const Node = syntax.Node;
const Binding = value.Binding;

/// Failures produced by evaluating a compiled CEL program.
pub const EvalError = @import("errors.zig").EvalError;

/// Evaluate a syntax tree with independent per-call storage and work accounting.
pub fn evaluate(
    arena: std.mem.Allocator,
    root: *const Node,
    bindings: []const Binding,
    limits: syntax.Limits,
    regexes: *const regex.Cache,
    container: []const u8,
    constants: []const Binding,
    registry: ?*proto.Registry,
    strong_enums: bool,
    function_declarations: []const functions.Function,
) EvalError!Value {
    var context = Context{
        .arena = arena,
        .bindings = bindings,
        .limits = limits,
        .remaining = limits.max_steps,
        .regexes = regexes,
        .container = container,
        .constants = constants,
        .functions = function_declarations,
        .messages = .{ .registry = registry, .limits = limits.protobuf, .strong_enums = strong_enums },
    };
    defer context.dynamic_regexes.deinit(arena);
    defer context.messages.deinit(arena);
    context.qualified_names = registry != null or std.mem.startsWith(u8, container, "google") or
        hasDottedName(constants) or hasDottedName(bindings);
    const result = try context.eval(root, null);
    return context.materialize(result, 0);
}

const Scope = struct {
    name: []const u8 = "",
    value: Value = .null,
    lazy: ?*LazyBinding = null,
    block_slots: ?[]LazyBinding = null,
    parent: ?*const Scope,
};

const LazyBinding = struct {
    initializer: *const Node,
    scope: ?*const Scope,
    result: ?(EvalError!Value) = null,
};

const Context = struct {
    arena: std.mem.Allocator,
    bindings: []const Binding,
    limits: syntax.Limits,
    remaining: usize,
    depth: usize = 0,
    regexes: *const regex.Cache,
    dynamic_regexes: regex.Cache = .{},
    container: []const u8,
    constants: []const Binding,
    functions: []const functions.Function,
    messages: proto.Scope,
    /// Whether any qualified selection could name an activation, constant, or descriptor entry.
    qualified_names: bool = true,

    fn charge(self: *Context, cost: usize) EvalError!void {
        if (cost > self.remaining) return error.CostLimitExceeded;
        self.remaining -= cost;
    }

    fn eval(self: *Context, node: *const Node, scope: ?*const Scope) EvalError!Value {
        try self.charge(1);
        if (self.depth >= self.limits.max_depth) return error.DepthLimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        return switch (node.*) {
            .literal => |v| self.adapt(v),
            .variable => |name| blk: {
                try self.charge(self.bindings.len);
                for (self.bindings) |binding| if (std.mem.eql(u8, name, binding.name)) break :blk try self.adapt(binding.value);
                return error.UndeclaredReference;
            },
            .ident, .local_ident => |identifier| blk: {
                const absolute = std.mem.startsWith(u8, identifier, ".");
                const name = if (absolute) identifier[1..] else identifier;
                var current = if (absolute) null else scope;
                while (current) |local| : (current = local.parent) {
                    try self.charge(1);
                    if (name.len != local.name.len) continue;
                    try self.charge(name.len);
                    if (std.mem.eql(u8, name, local.name)) {
                        if (local.lazy) |binding| break :blk try self.force(binding);
                        break :blk try self.adapt(local.value);
                    }
                }
                if (node.* == .local_ident) return error.UndeclaredReference;
                if (try self.resolve(node)) |resolved| break :blk resolved;
                const type_names = [_][]const u8{
                    "bool", "bytes", "double", "int", "list", "map", "null_type", "string", "type", "uint", "optional_type",
                };
                for (type_names) |name_of_type| {
                    if (std.mem.eql(u8, name, name_of_type)) break :blk .{ .type_value = name_of_type };
                }
                return error.UndeclaredReference;
            },
            .unary => |u| blk: {
                const v = try self.eval(u.operand, scope);
                break :blk switch (u.op) {
                    .bang => .{ .bool = !try boolean(v) },
                    .minus => switch (v) {
                        .int => |n| .{ .int = std.math.negate(n) catch return error.Overflow },
                        .double => |n| .{ .double = -n },
                        else => error.NoMatchingOverload,
                    },
                    else => unreachable,
                };
            },
            .binary => |b| blk: {
                if (b.op == .and_op or b.op == .or_op) {
                    const decisive = b.op == .or_op;
                    const left: EvalError!bool = if (self.eval(b.left, scope)) |v| boolean(v) else |err| err;
                    if (left) |v| {
                        if (v == decisive) break :blk .{ .bool = decisive };
                    } else |err| if (fatal(err)) return err;
                    const right: EvalError!bool = if (self.eval(b.right, scope)) |v| boolean(v) else |err| err;
                    if (right) |v| {
                        if (v == decisive) break :blk .{ .bool = decisive };
                    } else |err| if (fatal(err)) return err;
                    _ = try left;
                    break :blk .{ .bool = try right };
                }
                const left = try self.eval(b.left, scope);
                const right = try self.eval(b.right, scope);
                break :blk try self.binary(b.op, left, right);
            },
            .conditional => |c| self.eval(if (try boolean(try self.eval(c.condition, scope))) c.yes else c.no, scope),
            .select => |s| blk: {
                if (s.qualified and (self.qualified_names or qualifiedTypeRoot(node))) {
                    var shadowed = false;
                    if (scope != null) {
                        var root = node;
                        while (root.* == .select) {
                            try self.charge(1);
                            root = root.select.target;
                        }
                        if (!std.mem.startsWith(u8, root.ident, ".")) {
                            var local = scope;
                            while (local) |binding| : (local = binding.parent) {
                                try self.charge(1);
                                if (std.mem.eql(u8, root.ident, binding.name)) {
                                    shadowed = true;
                                    break;
                                }
                            }
                        }
                    }
                    if (!shadowed) if (try self.resolve(node)) |resolved| break :blk resolved;
                }
                const target = try self.eval(s.target, scope);
                break :blk try self.select(target, s.field, s.optional, false);
            },
            .index => |i| blk: {
                var target = try self.eval(i.target, scope);
                const optional = i.optional or target == .optional;
                if (target == .optional) target = try self.adapt((target.optional orelse break :blk .{ .optional = null }).*);
                const key = try self.eval(i.key, scope);
                if (target == .map) {
                    if (optional) switch (key) {
                        .bool, .int, .uint, .double, .string => {},
                        else => return error.NoMatchingOverload,
                    };
                    const found = try self.lookup(target.map, key);
                    if (optional) break :blk try Value.fromOptional(self.arena, if (found) |v| try self.adapt(v) else null);
                    break :blk try self.adapt(found orelse return error.NoSuchKey);
                }
                if (target != .list) return error.NoMatchingOverload;
                const index: usize = switch (key) {
                    .int => |v| std.math.cast(usize, v) orelse {
                        if (optional) break :blk .{ .optional = null };
                        return error.IndexOutOfBounds;
                    },
                    .uint => |v| std.math.cast(usize, v) orelse {
                        if (optional) break :blk .{ .optional = null };
                        return error.IndexOutOfBounds;
                    },
                    .double => |v| blk_index: {
                        if (!std.math.isFinite(v) or @trunc(v) != v) return error.IndexOutOfBounds;
                        if (v < 0 or v >= @as(f64, @floatFromInt(target.list.len))) {
                            if (optional) break :blk .{ .optional = null };
                            return error.IndexOutOfBounds;
                        }
                        break :blk_index @intFromFloat(v);
                    },
                    else => return error.NoMatchingOverload,
                };
                if (index >= target.list.len) {
                    if (optional) break :blk .{ .optional = null };
                    return error.IndexOutOfBounds;
                }
                const found = try self.adapt(target.list[index]);
                break :blk if (optional) try Value.fromOptional(self.arena, found) else found;
            },
            .list => |items| blk: {
                if (items.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                const out = try self.arena.alloc(Value, items.len);
                var count: usize = 0;
                for (items) |item| {
                    var evaluated = try self.eval(item.value, scope);
                    if (item.optional) {
                        if (evaluated != .optional) return error.NoMatchingOverload;
                        evaluated = (evaluated.optional orelse continue).*;
                    }
                    out[count] = evaluated;
                    count += 1;
                }
                break :blk .{ .list = out[0..count] };
            },
            .map => |items| blk: {
                if (items.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                const out = try self.arena.alloc(value.Entry, items.len);
                var count: usize = 0;
                for (items) |item| {
                    const key = try self.eval(item.key, scope);
                    switch (key) {
                        .bool, .int, .uint, .string => {},
                        else => return error.NoMatchingOverload,
                    }
                    var evaluated = try self.eval(item.value, scope);
                    if (item.optional) {
                        if (evaluated != .optional) return error.NoMatchingOverload;
                        evaluated = (evaluated.optional orelse continue).*;
                    }
                    if (try self.lookup(out[0..count], key) != null) return error.DuplicateKey;
                    out[count] = .{ .key = key, .value = evaluated };
                    count += 1;
                }
                break :blk .{ .map = out[0..count] };
            },
            .message => |m| blk: {
                const desc = (try self.messageType(m.type_name)) orelse return error.UnsupportedType;
                const fields = try self.arena.alloc(*const proto.Field, m.fields.len);
                const values = try self.arena.alloc(Value, m.fields.len);
                var count: usize = 0;
                for (m.fields) |initializer| {
                    const field = try proto.field(desc, initializer.name) orelse return error.NoSuchKey;
                    var item = try self.eval(initializer.value, scope);
                    if (initializer.optional) {
                        if (item != .optional) return error.NoMatchingOverload;
                        item = (item.optional orelse continue).*;
                    }
                    fields[count] = field;
                    values[count] = item;
                    count += 1;
                }
                break :blk try self.messages.construct(self.arena, desc, fields[0..count], values[0..count]);
            },
            .presence => |s| blk: {
                const target = try self.eval(s.target, scope);
                break :blk try self.select(target, s.field, false, true);
            },
            .call => |c| self.call(c, scope),
            .comprehension => |c| self.comprehension(c, scope),
            .block => |b| blk: {
                if (b.slots.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try self.charge(b.slots.len);
                const slots = try self.arena.alloc(LazyBinding, b.slots.len);
                const local = Scope{ .block_slots = slots, .parent = scope };
                for (b.slots, slots) |initializer, *slot| slot.* = .{ .initializer = initializer, .scope = &local };
                break :blk try self.eval(b.body, &local);
            },
            .block_index => |index| blk: {
                var current = scope;
                while (current) |local| : (current = local.parent) {
                    try self.charge(1);
                    if (local.block_slots) |slots| {
                        if (index >= slots.len) return error.UndeclaredReference;
                        break :blk try self.force(&slots[index]);
                    }
                }
                return error.UndeclaredReference;
            },
            .local_bind => |b| blk: {
                var binding = LazyBinding{ .initializer = b.initializer, .scope = scope };
                const local = Scope{ .name = b.name, .lazy = &binding, .parent = scope };
                break :blk try self.eval(b.body, &local);
            },
            .sort_by => |m| blk: {
                const target = try self.eval(m.target, scope);
                if (target != .list) return error.NoMatchingOverload;
                if (target.list.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try self.charge(target.list.len);
                const keys = try self.arena.alloc(Value, target.list.len);
                for (target.list, keys) |item, *key| {
                    const local = Scope{ .name = m.variable, .value = item, .parent = scope };
                    key.* = try self.eval(m.body, &local);
                }
                break :blk try self.sortList(target.list, keys);
            },
            .optional_map => |m| blk: {
                const target = try self.eval(m.target, scope);
                if (target != .optional) return error.NoMatchingOverload;
                const payload = target.optional orelse break :blk target;
                const local = Scope{ .name = m.variable, .value = payload.*, .parent = scope };
                const transformed = try self.eval(m.body, &local);
                if (m.flat) {
                    if (transformed != .optional) return error.NoMatchingOverload;
                    break :blk transformed;
                }
                break :blk try Value.fromOptional(self.arena, transformed);
            },
        };
    }

    fn force(self: *Context, binding: *LazyBinding) EvalError!Value {
        if (binding.result == null) {
            // Recursive slot references observe a missing value until initialization finishes.
            binding.result = @as(EvalError!Value, error.UndeclaredReference);
            binding.result = self.eval(binding.initializer, binding.scope);
        }
        return binding.result.?;
    }

    fn distinctHash(self: *Context, item: Value) EvalError!?u64 {
        if (item.numeric()) {
            const integer: ?u64 = switch (item) {
                .int => |v| @bitCast(v),
                .uint => |v| v,
                .double => |v| if (std.math.isFinite(v) and @trunc(v) == v and v >= -0x1p63 and v < 0x1p64)
                    (if (v < 0) @bitCast(@as(i64, @intFromFloat(v))) else @as(u64, @intFromFloat(v)))
                else
                    null,
                else => unreachable,
            };
            if (integer) |v| return std.hash.Wyhash.hash(0, std.mem.asBytes(&v));
            return std.hash.Wyhash.hash(10, std.mem.asBytes(&item.double));
        }
        switch (item) {
            .null => return std.hash.Wyhash.hash(5, ""),
            .bool => |v| return std.hash.Wyhash.hash(1, if (v) "1" else "0"),
            .string, .bytes, .type_value => {
                const bytes = switch (item) {
                    .string => |v| v,
                    .bytes => |v| v,
                    else => item.type_value,
                };
                try self.charge(bytes.len);
                return std.hash.Wyhash.hash(if (item == .string) 2 else if (item == .bytes) 3 else 7, bytes);
            },
            .duration => |v| return std.hash.Wyhash.hash(8, std.mem.asBytes(&v.nanoseconds)),
            .timestamp => |v| {
                const nanos = v.toNanos();
                return std.hash.Wyhash.hash(9, std.mem.asBytes(&nanos));
            },
            .ip => |v| {
                try self.charge(v.bytes.len);
                return std.hash.Wyhash.hash(v.family, &v.bytes);
            },
            .cidr => |v| {
                try self.charge(v.address.bytes.len);
                return std.hash.Wyhash.hash((@as(u64, v.address.family) << 8) | v.prefix, &v.address.bytes);
            },
            .enum_value => |v| {
                try self.charge(v.type_name.len);
                const number: u64 = @bitCast(@as(i64, v.number));
                return std.hash.Wyhash.hash(number, v.type_name);
            },
            // Compound values share a bucket so protobuf and recursive equality remain authoritative.
            else => return null,
        }
    }

    fn flattenList(self: *Context, items: []const Value, levels: i64, out: *std.ArrayList(Value)) EvalError!void {
        if (self.depth >= self.limits.max_depth) return error.DepthLimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        for (items) |item| {
            try self.charge(1);
            const adapted = try self.adapt(item);
            if (levels > 0 and adapted == .list) {
                if (adapted.list.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try self.flattenList(adapted.list, levels - 1, out);
            } else {
                if (out.items.len >= self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try out.append(self.arena, adapted);
            }
        }
    }

    fn sortList(self: *Context, items: []const Value, input_keys: []const Value) EvalError!Value {
        if (items.len == 0) return .{ .list = items };
        const keys = try self.arena.alloc(Value, input_keys.len);
        for (input_keys, keys) |item, *key| key.* = try self.adapt(item);
        const tag = std.meta.activeTag(keys[0]);
        switch (tag) {
            .int, .uint, .double, .bool, .string, .bytes, .timestamp, .duration => {},
            else => return error.NoMatchingOverload,
        }
        for (keys) |key| {
            if (std.meta.activeTag(key) != tag) return error.NoMatchingOverload;
            if (keys.len > 1 and key == .double and std.math.isNan(key.double)) return error.InvalidArgument;
        }
        // Prepay the heap's bounded index work, even if a later comparison exhausts the byte budget.
        try self.charge(items.len *| (3 *| (std.math.log2_int(usize, items.len) + 1)));
        const indices = try self.arena.alloc(usize, items.len);
        for (indices, 0..) |*index, i| index.* = i;
        const Ordering = struct {
            context: *Context,
            keys: []const Value,
            failure: ?EvalError = null,

            fn lessThan(order: *@This(), a: usize, b: usize) bool {
                if (order.failure != null) return false;
                const less = order.context.binary(.lt, order.keys[a], order.keys[b]) catch |err| {
                    order.failure = err;
                    return false;
                };
                if (less.bool) return true;
                const same = order.context.equal(order.keys[a], order.keys[b]) catch |err| {
                    order.failure = err;
                    return false;
                };
                return same and a < b;
            }
        };
        var ordering = Ordering{ .context = self, .keys = keys };
        std.sort.heap(usize, indices, &ordering, Ordering.lessThan);
        if (ordering.failure) |err| return err;
        const out = try self.arena.alloc(Value, items.len);
        for (indices, out) |index, *item| item.* = items[index];
        return .{ .list = out };
    }

    fn select(self: *Context, input: Value, name: []const u8, optional: bool, presence: bool) EvalError!Value {
        var target = input;
        const wrapped = optional or target == .optional;
        if (target == .optional) target = try self.adapt((target.optional orelse {
            return if (presence) .{ .bool = false } else .{ .optional = null };
        }).*);
        if (target == .message) {
            try self.charge(name.len);
            const desc = try proto.descriptor(self.messages.registry, target.message.type_name) orelse return error.UnsupportedType;
            const field = try proto.field(desc, name) orelse return error.NoSuchKey;
            if (wrapped or presence) {
                const exists = try self.messages.has(self.arena, target.message, field);
                if (presence) return .{ .bool = exists };
                if (!exists) return .{ .optional = null };
            }
            const result = try self.messages.get(self.arena, target.message, field);
            return if (wrapped) try Value.fromOptional(self.arena, result) else result;
        }
        if (target != .map) return error.NoMatchingOverload;
        const found = try self.lookup(target.map, .{ .string = name });
        if (presence) return .{ .bool = found != null };
        if (wrapped) return Value.fromOptional(self.arena, if (found) |v| try self.adapt(v) else null);
        return self.adapt(found orelse return error.NoSuchKey);
    }

    fn binary(self: *Context, op: syntax.Token, a: Value, b: Value) EvalError!Value {
        if (op == .eq or op == .ne) return .{ .bool = try self.equal(a, b) == (op == .eq) };
        if (op == .in_op) {
            if (b == .map) {
                return .{ .bool = try self.lookup(b.map, a) != null };
            }
            if (b != .list) return error.NoMatchingOverload;
            for (b.list) |item| if (try self.equal(a, item)) return .{ .bool = true };
            return .{ .bool = false };
        }
        if (op == .lt or op == .le or op == .gt or op == .ge) {
            if (a == .string and b == .string) try self.charge(@min(a.string.len, b.string.len));
            if (a == .bytes and b == .bytes) try self.charge(@min(a.bytes.len, b.bytes.len));
            const order = if (a.numeric() and b.numeric()) a.order(b) else switch (a) {
                .bool => |v| blk: {
                    if (b != .bool) return error.NoMatchingOverload;
                    break :blk std.math.order(@intFromBool(v), @intFromBool(b.bool));
                },
                .string => |v| if (b == .string) std.mem.order(u8, v, b.string) else return error.NoMatchingOverload,
                .bytes => |v| if (b == .bytes) std.mem.order(u8, v, b.bytes) else return error.NoMatchingOverload,
                .timestamp => |v| if (b == .timestamp) std.math.order(v.toNanos(), b.timestamp.toNanos()) else return error.NoMatchingOverload,
                .duration => |v| if (b == .duration) std.math.order(v.nanoseconds, b.duration.nanoseconds) else return error.NoMatchingOverload,
                else => return error.NoMatchingOverload,
            };
            return .{ .bool = if (order) |o| switch (op) {
                .lt => o == .lt,
                .le => o != .gt,
                .gt => o == .gt,
                .ge => o != .lt,
                else => unreachable,
            } else false };
        }
        if (op == .plus or op == .minus) {
            if (a == .duration and b == .duration) return .{ .duration = .{ .nanoseconds = if (op == .plus)
                std.math.add(i64, a.duration.nanoseconds, b.duration.nanoseconds) catch return error.Overflow
            else
                std.math.sub(i64, a.duration.nanoseconds, b.duration.nanoseconds) catch return error.Overflow } };
            if (a == .timestamp and b == .duration) return .{ .timestamp = try temporal.Timestamp.fromNanos(
                a.timestamp.toNanos() + @as(i128, b.duration.nanoseconds) * @as(i128, if (op == .plus) 1 else -1),
            ) };
            if (op == .plus and a == .duration and b == .timestamp) return .{ .timestamp = try temporal.Timestamp.fromNanos(b.timestamp.toNanos() + a.duration.nanoseconds) };
            if (op == .minus and a == .timestamp and b == .timestamp) return .{ .duration = .{
                .nanoseconds = std.math.cast(i64, a.timestamp.toNanos() - b.timestamp.toNanos()) orelse return error.Overflow,
            } };
        }
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.NoMatchingOverload;
        switch (a) {
            .int => |x| {
                const y = b.int;
                return .{ .int = switch (op) {
                    .plus => std.math.add(i64, x, y) catch return error.Overflow,
                    .minus => std.math.sub(i64, x, y) catch return error.Overflow,
                    .star => std.math.mul(i64, x, y) catch return error.Overflow,
                    .slash, .percent => blk: {
                        if (y == 0) return error.DivisionByZero;
                        if (x == std.math.minInt(i64) and y == -1) {
                            if (op == .percent) break :blk 0;
                            return error.Overflow;
                        }
                        break :blk if (op == .slash) @divTrunc(x, y) else @rem(x, y);
                    },
                    else => return error.NoMatchingOverload,
                } };
            },
            .uint => |x| {
                const y = b.uint;
                return .{ .uint = switch (op) {
                    .plus => std.math.add(u64, x, y) catch return error.Overflow,
                    .minus => std.math.sub(u64, x, y) catch return error.Overflow,
                    .star => std.math.mul(u64, x, y) catch return error.Overflow,
                    .slash, .percent => blk: {
                        if (y == 0) return error.DivisionByZero;
                        break :blk if (op == .slash) x / y else x % y;
                    },
                    else => return error.NoMatchingOverload,
                } };
            },
            .double => |x| return .{ .double = switch (op) {
                .plus => x + b.double,
                .minus => x - b.double,
                .star => x * b.double,
                .slash => x / b.double,
                else => return error.NoMatchingOverload,
            } },
            .string, .bytes => {
                if (op != .plus) return error.NoMatchingOverload;
                const x = if (a == .string) a.string else a.bytes;
                const y = if (b == .string) b.string else b.bytes;
                const len = std.math.add(usize, x.len, y.len) catch return error.CollectionLimitExceeded;
                if (len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try self.charge(len);
                const result = try std.mem.concat(self.arena, u8, &.{ x, y });
                return if (a == .string) .{ .string = result } else .{ .bytes = result };
            },
            .list => |x| {
                if (op != .plus) return error.NoMatchingOverload;
                const len = std.math.add(usize, x.len, b.list.len) catch return error.CollectionLimitExceeded;
                if (len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try self.charge(len);
                return .{ .list = try std.mem.concat(self.arena, Value, &.{ x, b.list }) };
            },
            else => return error.NoMatchingOverload,
        }
    }

    fn call(self: *Context, c: syntax.Call, scope: ?*const Scope) EvalError!Value {
        if (c.math_extrema) |greatest|
            return self.mathCall(if (greatest) .greatest else .least, c.args, scope);
        if (c.function_indices) |indices| return self.customCall(c, scope, indices);
        if (!c.checked and self.functions.len != 0) {
            const qualified: ?[]const u8 = blk: {
                const target = c.target orelse break :blk c.name;
                const prefix = syntax.qualifiedName(self.arena, target) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk null,
                };
                break :blk try std.mem.concat(self.arena, u8, &.{ prefix, ".", c.name });
            };
            if (qualified) |name| if (try self.findFunctions(name, false)) |indices| {
                var global = c;
                global.target = null;
                return self.customCall(global, scope, indices);
            };
            if (c.target != null) if (try self.findFunctions(c.name, true)) |indices|
                return self.customCall(c, scope, indices);
        }
        const network_function: ?network.Operation = if (c.target) |t|
            if (t.* == .ident and (std.mem.eql(u8, t.ident, "ip") or std.mem.eql(u8, t.ident, ".ip")) and
                std.mem.eql(u8, c.name, "isCanonical")) .isCanonical else null
        else
            network.function(c.name, self.container);
        if (network_function) |operation| {
            if (c.args.len != 1) return error.NoMatchingOverload;
            return network.evaluate(self.arena, operation, &.{try self.eval(c.args[0], scope)}, &self.remaining);
        }
        const encoding: ?encoders.Operation = if (c.target) |t| blk: {
            if (t.* == .ident and (std.mem.eql(u8, t.ident, "base64") or std.mem.eql(u8, t.ident, ".base64")))
                break :blk std.meta.stringToEnum(encoders.Operation, c.name);
            break :blk null;
        } else encoders.operation(c.name, self.container);
        if (encoding) |operation| {
            if (c.args.len != 1) return error.NoMatchingOverload;
            return encoders.evaluate(self.arena, operation, try self.eval(c.args[0], scope), &self.remaining, self.limits.max_collection_size);
        }
        const math_operation: ?math_ext.Operation = blk: {
            if (c.target) |target| {
                if (target.* == .ident and (std.mem.eql(u8, target.ident, "math") or
                    std.mem.eql(u8, target.ident, ".math")))
                    break :blk std.meta.stringToEnum(math_ext.Operation, c.name);
                break :blk null;
            }
            break :blk math_ext.operation(c.name);
        };
        if (math_operation) |op| return self.mathCall(op, c.args, scope);
        const quote_call = if (c.target) |t|
            t.* == .ident and (std.mem.eql(u8, t.ident, "strings") or std.mem.eql(u8, t.ident, ".strings")) and
                std.mem.eql(u8, c.name, "quote")
        else
            std.mem.eql(u8, c.name, "strings.quote") or std.mem.eql(u8, c.name, ".strings.quote") or
                (std.mem.eql(u8, c.name, "quote") and (std.mem.eql(u8, self.container, "strings") or
                    std.mem.startsWith(u8, self.container, "strings.")));
        if (quote_call) {
            if (c.args.len != 1) return error.NoMatchingOverload;
            return strings.evaluate(self.arena, .quote, &.{try self.eval(c.args[0], scope)}, &self.remaining, self.limits.max_collection_size);
        }
        const range_call = if (c.target) |t|
            t.* == .ident and (std.mem.eql(u8, t.ident, "lists") or std.mem.eql(u8, t.ident, ".lists")) and
                std.mem.eql(u8, c.name, "range")
        else
            std.mem.eql(u8, c.name, "lists.range") or std.mem.eql(u8, c.name, ".lists.range") or
                (std.mem.eql(u8, c.name, "range") and (std.mem.eql(u8, self.container, "lists") or
                    std.mem.startsWith(u8, self.container, "lists.")));
        if (range_call) {
            if (c.args.len != 1) return error.NoMatchingOverload;
            const size = try self.eval(c.args[0], scope);
            if (size != .int) return error.NoMatchingOverload;
            if (size.int < 0) return error.InvalidArgument;
            const count = std.math.cast(usize, size.int) orelse return error.CollectionLimitExceeded;
            if (count > self.limits.max_collection_size) return error.CollectionLimitExceeded;
            try self.charge(count);
            const items = try self.arena.alloc(Value, count);
            for (items, 0..) |*item, i| item.* = .{ .int = @intCast(i) };
            return .{ .list = items };
        }
        const optional_name: ?[]const u8 = blk: {
            if (c.target) |target| {
                if (target.* == .ident and (std.mem.eql(u8, target.ident, "optional") or
                    std.mem.eql(u8, target.ident, ".optional"))) break :blk c.name;
            } else {
                const name = if (std.mem.startsWith(u8, c.name, ".")) c.name[1..] else c.name;
                if (std.mem.startsWith(u8, name, "optional.")) break :blk name[9..];
            }
            break :blk null;
        };
        if (optional_name) |name| {
            if (std.mem.eql(u8, name, "none")) {
                if (c.args.len != 0) return error.NoMatchingOverload;
                return .{ .optional = null };
            }
            if (std.mem.eql(u8, name, "of") or std.mem.eql(u8, name, "ofNonZeroValue")) {
                if (c.args.len != 1) return error.NoMatchingOverload;
                const v = try self.eval(c.args[0], scope);
                if (std.mem.eql(u8, name, "ofNonZeroValue") and try self.isZero(v)) return .{ .optional = null };
                return Value.fromOptional(self.arena, v);
            }
            if (std.mem.eql(u8, name, "unwrap")) {
                if (c.args.len != 1) return error.NoMatchingOverload;
                return self.unwrapList(try self.eval(c.args[0], scope));
            }
        }
        // CEL function names resolve independently of lexical variable bindings.
        if (self.messages.strong_enums) {
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
                    try self.charge(local.len +| prefix.len +| 1);
                    const candidate = if (prefix.len == 0) local else try std.mem.concat(self.arena, u8, &.{ prefix, ".", local });
                    if (try proto.enumType(self.messages.registry, candidate)) |type_name| {
                        if (c.args.len != 1) return error.NoMatchingOverload;
                        const input = try self.eval(c.args[0], scope);
                        if (input == .string) try self.charge(input.string.len);
                        return Value.fromEnum(self.arena, try proto.convertEnum(self.messages.registry, type_name, input));
                    }
                    if (prefix.len == 0) break;
                    prefix = names.parent(prefix);
                }
            }
        }
        const name = if (c.target == null and std.mem.startsWith(u8, c.name, ".")) c.name[1..] else c.name;
        const target: ?Value = if (c.target) |t| try self.eval(t, scope) else null;
        if (target) |receiver| {
            // Common string predicates skip the extension cascade; every later branch would reject them anyway.
            if (receiver == .string and c.args.len == 1) if (StringPredicate.map.get(name)) |predicate| {
                const argument = try self.eval(c.args[0], scope);
                if (argument != .string) return error.NoMatchingOverload;
                const a = receiver.string;
                const b = argument.string;
                try self.charge(a.len +| b.len);
                return .{ .bool = switch (predicate) {
                    .contains => std.mem.indexOf(u8, a, b) != null,
                    .startsWith => std.mem.startsWith(u8, a, b),
                    .endsWith => std.mem.endsWith(u8, a, b),
                } };
            };
            if (receiver == .optional and (std.mem.eql(u8, name, "or") or std.mem.eql(u8, name, "orValue"))) {
                if (c.args.len != 1) return error.NoMatchingOverload;
                if (receiver.optional) |present|
                    return if (std.mem.eql(u8, name, "or")) receiver else self.adapt(present.*);
                const fallback = try self.eval(c.args[0], scope);
                if (std.mem.eql(u8, name, "or") and fallback != .optional) return error.NoMatchingOverload;
                return fallback;
            }
        }
        var args: [4]Value = undefined;
        var count: usize = 0;
        if (target) |v| {
            args[0] = v;
            count = 1;
        }
        if (c.args.len > args.len - count) return error.NoMatchingOverload;
        for (c.args) |arg| {
            args[count] = try self.eval(arg, scope);
            count += 1;
        }
        if (target != null) if (network.method(name)) |operation|
            return network.evaluate(self.arena, operation, args[0..count], &self.remaining);
        if (target != null and args[0] == .list) {
            const operation = std.StaticStringMap(enum { slice, flatten, distinct, reverse, sort }).initComptime(.{
                .{ "slice", .slice },     .{ "flatten", .flatten }, .{ "distinct", .distinct },
                .{ "reverse", .reverse }, .{ "sort", .sort },
            }).get(name);
            if (operation) |op| {
                const items = args[0].list;
                if (items.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try self.charge(items.len);
                switch (op) {
                    .slice => {
                        if (count != 3 or args[1] != .int or args[2] != .int) return error.NoMatchingOverload;
                        const start = std.math.cast(usize, args[1].int) orelse return error.InvalidArgument;
                        const end = std.math.cast(usize, args[2].int) orelse return error.InvalidArgument;
                        if (start > end or end > items.len) return error.InvalidArgument;
                        return .{ .list = items[start..end] };
                    },
                    .flatten => {
                        if (count != 1 and (count != 2 or args[1] != .int)) return error.NoMatchingOverload;
                        const levels = if (count == 1) 1 else args[1].int;
                        if (levels < 0) return error.InvalidArgument;
                        var out: std.ArrayList(Value) = .empty;
                        try self.flattenList(items, levels, &out);
                        return .{ .list = out.items };
                    },
                    .distinct => {
                        if (count != 1) return error.NoMatchingOverload;
                        const out = try self.arena.alloc(Value, items.len);
                        var used: usize = 0;
                        var buckets: std.AutoHashMapUnmanaged(?u64, usize) = .empty;
                        const hashed = items.len > 16;
                        const next: []usize = if (hashed) try self.arena.alloc(usize, items.len) else &.{};
                        for (items) |item| {
                            const adapted = try self.adapt(item);
                            const hash = if (hashed) try self.distinctHash(adapted) else null;
                            const head = if (hashed) buckets.get(hash) orelse items.len else if (used == 0) items.len else used - 1;
                            var previous = head;
                            var seen = false;
                            while (previous != items.len) {
                                if (try self.equal(adapted, out[previous])) {
                                    seen = true;
                                    break;
                                }
                                previous = if (hashed) next[previous] else if (previous == 0) items.len else previous - 1;
                            }
                            if (!seen) {
                                out[used] = adapted;
                                if (hashed) {
                                    next[used] = head;
                                    try buckets.put(self.arena, hash, used);
                                }
                                used += 1;
                            }
                        }
                        return .{ .list = out[0..used] };
                    },
                    .reverse => {
                        if (count != 1) return error.NoMatchingOverload;
                        const out = try self.arena.dupe(Value, items);
                        std.mem.reverse(Value, out);
                        return .{ .list = out };
                    },
                    .sort => {
                        if (count != 1) return error.NoMatchingOverload;
                        return self.sortList(items, items);
                    },
                }
            }
        }
        if (target != null and std.mem.eql(u8, name, "format")) {
            if (count != 2 or args[0] != .string or args[1] != .list) return error.NoMatchingOverload;
            const values = try self.materialize(args[1], 0);
            return string_format.format(self.arena, args[0].string, values.list, &self.remaining, self.limits.max_collection_size, self.limits.max_depth, self.limits.max_collection_size);
        }
        if (target != null) if (strings.method(name)) |operation| {
            if (operation == .join and count > 0) args[0] = try self.materialize(args[0], 0);
            return strings.evaluate(self.arena, operation, args[0..count], &self.remaining, self.limits.max_collection_size);
        };
        if (target != null and args[0] == .optional) {
            if (std.mem.eql(u8, name, "hasValue") and (count == 1 or count == 2)) {
                const present = args[0].optional orelse return .{ .bool = false };
                return .{ .bool = if (count == 1) true else try self.equal(present.*, args[1]) };
            }
            if (std.mem.eql(u8, name, "value") and count == 1)
                return self.adapt((args[0].optional orelse return error.NoSuchKey).*);
        }
        if (target != null and count == 1 and args[0] == .list) {
            if (std.mem.eql(u8, name, "unwrapOpt")) return self.unwrapList(args[0]);
            if (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last")) {
                const items = args[0].list;
                return Value.fromOptional(self.arena, if (items.len == 0) null else try self.adapt(items[if (std.mem.eql(u8, name, "first")) 0 else items.len - 1]));
            }
        }
        if (target != null) if (temporal.selector(name)) |selector| {
            if (args[0] == .timestamp and (count == 1 or (count == 2 and args[1] == .string))) {
                const zone = if (count == 2) args[1].string else "";
                try self.charge(zone.len +| 1);
                return .{ .int = try args[0].timestamp.select(selector, zone) };
            }
            if (args[0] == .duration and count == 1) return .{
                .int = switch (selector) {
                    5 => @divTrunc(args[0].duration.nanoseconds, 3_600_000_000_000),
                    // CEL defines milliseconds as the component, unlike the other duration selectors.
                    6 => @divTrunc(@rem(args[0].duration.nanoseconds, 1_000_000_000), 1_000_000),
                    7 => @divTrunc(args[0].duration.nanoseconds, 60_000_000_000),
                    9 => @divTrunc(args[0].duration.nanoseconds, 1_000_000_000),
                    else => return error.NoMatchingOverload,
                },
            };
            return error.NoMatchingOverload;
        };
        if (std.mem.eql(u8, name, "size") and count == 1) {
            const len = switch (args[0]) {
                .string => |s| blk: {
                    try self.charge(s.len);
                    break :blk std.unicode.utf8CountCodepoints(s) catch return error.InvalidArgument;
                },
                .bytes => |s| s.len,
                .list => |s| s.len,
                .map => |s| s.len,
                else => return error.NoMatchingOverload,
            };
            return .{ .int = std.math.cast(i64, len) orelse return error.Overflow };
        }
        if (std.mem.eql(u8, name, "matches") and count == 2) {
            if (args[0] != .string or args[1] != .string) return error.NoMatchingOverload;
            const text = args[0].string;
            const source = args[1].string;
            try self.charge(text.len +| source.len);
            const pattern = self.regexes.entries.get(source) orelse
                try self.dynamic_regexes.get(self.arena, source, self.limits.regex);
            return .{ .bool = try pattern.matches(text, &self.remaining) };
        }
        if (target == null and count == 1) return self.convert(name, args[0]);
        return error.NoMatchingOverload;
    }

    fn mathCall(self: *Context, op: math_ext.Operation, nodes: []const *const Node, scope: ?*const Scope) EvalError!Value {
        if (nodes.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
        try self.charge(nodes.len);
        var buffer: [4]Value = undefined;
        const args = if (nodes.len <= buffer.len) buffer[0..nodes.len] else try self.arena.alloc(Value, nodes.len);
        for (nodes, args) |node, *argument| argument.* = try self.eval(node, scope);
        if ((op == .greatest or op == .least) and args.len == 1 and args[0] == .list) {
            const items = args[0].list;
            if (items.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
            try self.charge(items.len);
            if (items.len == 0) return error.InvalidArgument;
            var result = try self.adapt(items[0]);
            if (!result.numeric()) return error.NoMatchingOverload;
            for (items[1..]) |item| result = try math_ext.evaluate(op, &.{ result, try self.adapt(item) });
            return result;
        }
        return math_ext.evaluate(op, args);
    }

    fn isZero(self: *Context, input: Value) EvalError!bool {
        return switch (input) {
            .null => true,
            .bool => |v| !v,
            .int => |v| v == 0,
            .uint => |v| v == 0,
            .double => |v| v == 0,
            .string, .bytes => |v| v.len == 0,
            .list => |v| v.len == 0,
            .map => |v| v.len == 0,
            .duration => |v| v.nanoseconds == 0,
            .timestamp => |v| v.seconds == -62135596800 and v.nanos == 0,
            .enum_value => |v| v.number == 0,
            .message => |v| (try self.messages.materialize(self.arena, v)).data.len == 0,
            .optional, .type_value, .ip, .cidr => false,
        };
    }

    fn unwrapList(self: *Context, input: Value) EvalError!Value {
        if (input != .list) return error.NoMatchingOverload;
        if (input.list.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
        const values = try self.arena.alloc(Value, input.list.len);
        var count: usize = 0;
        for (input.list) |item| {
            try self.charge(1);
            if (item != .optional) return error.NoMatchingOverload;
            if (item.optional) |v| {
                values[count] = try self.adapt(v.*);
                count += 1;
            }
        }
        return .{ .list = values[0..count] };
    }

    fn findFunctions(self: *Context, name: []const u8, member: bool) EvalError!?[]const usize {
        const absolute = std.mem.startsWith(u8, name, ".");
        const local = if (absolute) name[1..] else name;
        var prefix = if (absolute) "" else self.container;
        while (true) {
            try self.charge(local.len +| prefix.len +| 1);
            const candidate = if (prefix.len == 0) local else try std.mem.concat(self.arena, u8, &.{ prefix, ".", local });
            var indices: std.ArrayList(usize) = .empty;
            for (self.functions, 0..) |function, i| {
                try self.charge(function.name.len +| 1);
                if (function.member == member and std.mem.eql(u8, function.name, candidate))
                    try indices.append(self.arena, i);
            }
            if (indices.items.len != 0) return try indices.toOwnedSlice(self.arena);
            if (prefix.len == 0) return null;
            prefix = names.parent(prefix);
        }
    }

    fn customCall(self: *Context, c: syntax.Call, scope: ?*const Scope, indices: []const usize) EvalError!Value {
        const count = c.args.len + @as(usize, if (c.target != null) 1 else 0);
        if (count > self.limits.max_collection_size) return error.CollectionLimitExceeded;
        try self.charge(count);
        const args = try self.arena.alloc(Value, count);
        const offset: usize = if (c.target) |target| blk: {
            args[0] = try self.eval(target, scope);
            break :blk 1;
        } else 0;
        for (c.args, args[offset..]) |arg, *out| out.* = try self.eval(arg, scope);
        var selected: ?*const functions.Function = null;
        for (indices) |index| {
            const function = &self.functions[index];
            try self.charge(1);
            if (function.parameters.len != args.len) continue;
            const matches = for (function.parameters, args) |parameter, arg| {
                if (!try self.matchesType(parameter, arg, 0)) break false;
            } else true;
            if (!matches) continue;
            if (selected != null) return error.NoMatchingOverload;
            selected = function;
        }
        const function = selected orelse return error.NoMatchingOverload;
        const implementation = function.implementation orelse return error.MissingFunction;
        for (args) |*arg| arg.* = try self.materialize(arg.*, 0);
        const result = try self.materialize(try self.adapt(try implementation(function.context, self.arena, args)), 0);
        if (!try self.matchesType(function.result, result, 0)) return error.NoMatchingOverload;
        if (c.function_result) |expected| if (!try self.matchesType(expected, result, 0)) return error.NoMatchingOverload;
        return result;
    }

    fn matchesType(self: *Context, t: @import("types.zig").Type, v: Value, depth: usize) EvalError!bool {
        try self.charge(1);
        if (depth >= self.limits.max_depth) return error.DepthLimitExceeded;
        if (t.kind == .parameter) return true;
        if (t.kind == .abstract and std.mem.eql(u8, t.name, "optional_type")) {
            if (v == .null) return true;
            if (v != .optional) return false;
            return if (v.optional) |present| self.matchesType(t.parameters[0], present.*, depth + 1) else true;
        }
        if (t.kind == .abstract) {
            if (std.mem.eql(u8, t.name, "net.IP")) return v == .ip or v == .null;
            if (std.mem.eql(u8, t.name, "net.CIDR")) return v == .cidr or v == .null;
            return v == .null;
        }
        if (std.mem.eql(u8, t.name, "dyn") or std.mem.eql(u8, t.name, "google.protobuf.Any") or
            std.mem.eql(u8, t.name, "google.protobuf.Value")) return true;
        if (std.mem.eql(u8, t.name, "wrapper"))
            return v == .null or try self.matchesType(t.parameters[0], v, depth + 1);
        const wrappers = std.StaticStringMap([]const u8).initComptime(.{
            .{ "google.protobuf.Int32Value", "int" },     .{ "google.protobuf.Int64Value", "int" },
            .{ "google.protobuf.UInt32Value", "uint" },   .{ "google.protobuf.UInt64Value", "uint" },
            .{ "google.protobuf.FloatValue", "double" },  .{ "google.protobuf.DoubleValue", "double" },
            .{ "google.protobuf.StringValue", "string" }, .{ "google.protobuf.BytesValue", "bytes" },
            .{ "google.protobuf.BoolValue", "bool" },
        });
        if (wrappers.get(t.name)) |primitive|
            return v == .null or try self.matchesType(.{ .name = primitive }, v, depth + 1);
        if (std.mem.eql(u8, t.name, "google.protobuf.ListValue")) return v == .list;
        if (std.mem.eql(u8, t.name, "google.protobuf.Struct")) return v == .map;
        if (v == .null and try proto.descriptor(self.messages.registry, t.name) != null) return true;
        if (std.mem.eql(u8, t.name, "type")) {
            if (v != .type_value) return false;
            return t.parameters.len == 0 or t.parameters[0].kind == .parameter or
                std.mem.eql(u8, t.parameters[0].name, "dyn") or
                std.mem.eql(u8, t.parameters[0].name, v.type_value);
        }
        if (std.mem.eql(u8, t.name, "list")) {
            if (v != .list) return false;
            for (v.list) |item| if (!try self.matchesType(t.parameters[0], item, depth + 1)) return false;
            return true;
        }
        if (std.mem.eql(u8, t.name, "map")) {
            if (v != .map) return false;
            for (v.map) |item| {
                if (!try self.matchesType(t.parameters[0], item.key, depth + 1) or
                    !try self.matchesType(t.parameters[1], item.value, depth + 1)) return false;
            }
            return true;
        }
        const name = switch (v) {
            .null => "null_type",
            .type_value => "type",
            .timestamp => "google.protobuf.Timestamp",
            .duration => "google.protobuf.Duration",
            .message => |m| m.type_name,
            .enum_value => |e| e.type_name,
            else => @tagName(v),
        };
        return std.mem.eql(u8, t.name, name);
    }

    fn comprehension(self: *Context, c: syntax.Comprehension, scope: ?*const Scope) EvalError!Value {
        const target = try self.eval(c.target, scope);
        const len = switch (target) {
            .list => |v| v.len,
            .map => |v| v.len,
            else => return error.NoMatchingOverload,
        };
        var list: std.ArrayList(Value) = .empty;
        var map: std.ArrayList(value.Entry) = .empty;
        var matches: usize = 0;
        var saved_error: ?EvalError = null;
        for (0..len) |i| {
            try self.charge(1);
            const key: Value = if (target == .map)
                target.map[i].key
            else
                .{ .int = std.math.cast(i64, i) orelse return error.Overflow };
            const item = if (target == .list) target.list[i] else target.map[i].key;
            const first = Scope{
                .name = c.key_name,
                .value = if (c.value_name != null) key else item,
                .parent = scope,
            };
            const second = Scope{
                .name = c.value_name orelse "",
                .value = if (target == .list) target.list[i] else target.map[i].value,
                .parent = &first,
            };
            const local = if (c.value_name != null) &second else &first;
            const predicate: EvalError!bool = if (c.predicate) |p|
                if (self.eval(p, local)) |v| boolean(v) else |err| err
            else
                true;
            const matched = predicate catch |err| {
                if (fatal(err) or (c.kind != .all and c.kind != .exists)) return err;
                saved_error = err;
                continue;
            };
            if (c.kind == .all and !matched) return .{ .bool = false };
            if (c.kind == .exists and matched) return .{ .bool = true };
            if (!matched) continue;
            matches += 1;
            switch (c.kind) {
                .all, .exists, .exists_one => {},
                .list => {
                    if (list.items.len >= self.limits.max_collection_size) return error.CollectionLimitExceeded;
                    try list.append(self.arena, if (c.transform) |t| try self.eval(t, local) else item);
                },
                .map, .map_entries => {
                    const transformed = try self.eval(c.transform.?, local);
                    const single = [_]value.Entry{.{ .key = key, .value = transformed }};
                    const entries = if (c.kind == .map) &single else if (transformed == .map)
                        transformed.map
                    else
                        return error.NoMatchingOverload;
                    for (entries) |entry| {
                        switch (entry.key) {
                            .bool, .int, .uint, .string => {},
                            else => return error.NoMatchingOverload,
                        }
                        if (map.items.len >= self.limits.max_collection_size) return error.CollectionLimitExceeded;
                        if (try self.lookup(map.items, entry.key) != null) return error.DuplicateKey;
                        try map.append(self.arena, entry);
                    }
                },
            }
        }
        if (saved_error) |err| return err;
        return switch (c.kind) {
            .all => .{ .bool = true },
            .exists => .{ .bool = false },
            .exists_one => .{ .bool = matches == 1 },
            .list => .{ .list = try list.toOwnedSlice(self.arena) },
            .map, .map_entries => .{ .map = try map.toOwnedSlice(self.arena) },
        };
    }

    fn resolve(self: *Context, node: *const Node) EvalError!?Value {
        if (node.* == .ident and self.container.len == 0 and !self.qualified_names) {
            // A bare identifier without a container matches an exact activation or constant name.
            const name = if (std.mem.startsWith(u8, node.ident, ".")) node.ident[1..] else node.ident;
            for (self.constants) |binding| {
                try self.charge(binding.name.len +| 1);
                if (std.mem.eql(u8, binding.name, name)) return try self.adapt(binding.value);
            }
            for (self.bindings) |binding| {
                try self.charge(binding.name.len +| 1);
                if (std.mem.eql(u8, binding.name, name)) return try self.adapt(binding.value);
            }
            return null;
        }
        var prefix = if (std.mem.startsWith(u8, names.root(node), ".")) "" else self.container;
        while (true) {
            for (self.constants) |binding| {
                try self.charge(binding.name.len +| 1);
                if (names.matches(node, binding.name, prefix)) return try self.adapt(binding.value);
            }
            for (self.bindings) |binding| {
                try self.charge(binding.name.len +| 1);
                if (names.matches(node, binding.name, prefix)) return try self.adapt(binding.value);
            }
            for ([_][]const u8{ "net.IP", "net.CIDR" }) |type_name| {
                if (names.matches(node, type_name, prefix)) return .{ .type_value = type_name };
            }
            const root = names.root(node);
            if (self.messages.registry != null or std.mem.startsWith(u8, root, "google") or
                std.mem.startsWith(u8, root, ".google") or std.mem.startsWith(u8, prefix, "google"))
            {
                const qualified = syntax.qualifiedName(self.arena, node) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidArgument,
                };
                const local = if (std.mem.startsWith(u8, qualified, ".")) qualified[1..] else qualified;
                const candidate = if (prefix.len == 0) local else try std.mem.concat(self.arena, u8, &.{ prefix, ".", local });
                if (try proto.enumValue(self.messages.registry, candidate)) |item| return if (self.messages.strong_enums)
                    try Value.fromEnum(self.arena, item)
                else
                    .{ .int = item.number };
                if (self.messages.strong_enums) if (try proto.enumType(self.messages.registry, candidate)) |type_name|
                    return .{ .type_value = type_name };
                if (try proto.descriptor(self.messages.registry, candidate)) |desc| return .{ .type_value = proto.name(desc) };
            }
            if (prefix.len == 0) return null;
            prefix = names.parent(prefix);
        }
    }

    fn messageType(self: *Context, type_name: []const u8) EvalError!?*const proto.Descriptor {
        const absolute = std.mem.startsWith(u8, type_name, ".");
        const local = if (absolute) type_name[1..] else type_name;
        var prefix = if (absolute) "" else self.container;
        while (true) {
            try self.charge(local.len +| prefix.len);
            const candidate = if (prefix.len == 0) local else try std.mem.concat(self.arena, u8, &.{ prefix, ".", local });
            if (try proto.descriptor(self.messages.registry, candidate)) |desc| return desc;
            if (prefix.len == 0) return null;
            prefix = names.parent(prefix);
        }
    }

    fn adapt(self: *Context, input: Value) EvalError!Value {
        if (input == .timestamp) try input.timestamp.validate();
        if (input == .ip) try input.ip.validate();
        if (input == .cidr) try input.cidr.validate();
        if (input == .enum_value) {
            try self.charge(input.enum_value.type_name.len);
            if (!names.valid(input.enum_value.type_name, false)) return error.InvalidArgument;
        }
        return if (input == .message) self.messages.adapt(self.arena, input.message) else input;
    }

    fn materialize(self: *Context, input: Value, depth: usize) EvalError!Value {
        if (input == .ip) try input.ip.validate();
        if (input == .cidr) try input.cidr.validate();
        if (depth >= self.limits.max_depth) return error.DepthLimitExceeded;
        if (self.messages.native == null and input != .message and input != .list and input != .map and input != .optional) return input;
        try self.charge(1);
        return switch (input) {
            .optional => |present| try Value.fromOptional(self.arena, if (present) |v|
                try self.materialize(v.*, depth + 1)
            else
                null),
            .message => |m| blk: {
                const adapted = try self.messages.adapt(self.arena, m);
                if (adapted == .message) break :blk try Value.fromMessage(self.arena, try self.messages.materialize(self.arena, adapted.message));
                break :blk try self.materialize(adapted, depth + 1);
            },
            .list => |items| blk: {
                if (items.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                const copy = try self.arena.alloc(Value, items.len);
                for (items, copy) |item, *out| out.* = try self.materialize(item, depth + 1);
                break :blk .{ .list = copy };
            },
            .map => |entries| blk: {
                if (entries.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                const copy = try self.arena.alloc(value.Entry, entries.len);
                for (entries, copy) |entry, *out| out.* = .{
                    .key = entry.key,
                    .value = try self.materialize(entry.value, depth + 1),
                };
                break :blk .{ .map = copy };
            },
            else => input,
        };
    }

    fn lookup(self: *Context, entries: []const value.Entry, key: Value) EvalError!?Value {
        if (key == .string) {
            // Field selection dominates; string keys only ever equal string keys. Charges and the depth
            // check mirror `equal` so this path is observationally identical to the general one.
            if (self.depth >= self.limits.max_depth) return error.DepthLimitExceeded;
            const name = key.string;
            for (entries, 0..) |entry, index| {
                if (entry.key != .string) return self.lookupGeneral(entries[index..], key);
                try self.charge(1);
                if (entry.key.string.len == name.len) {
                    try self.charge(name.len);
                    if (std.mem.eql(u8, entry.key.string, name)) return entry.value;
                }
            }
            return null;
        }
        return self.lookupGeneral(entries, key);
    }

    fn lookupGeneral(self: *Context, entries: []const value.Entry, key: Value) EvalError!?Value {
        for (entries) |entry| if (try self.equal(entry.key, key)) return entry.value;
        return null;
    }

    fn equal(self: *Context, input_a: Value, input_b: Value) EvalError!bool {
        try self.charge(1);
        const a = if (input_a == .message) try self.adapt(input_a) else input_a;
        const b = if (input_b == .message) try self.adapt(input_b) else input_b;
        if (self.depth >= self.limits.max_depth) return error.DepthLimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        if (a == .optional and b == .optional) {
            const x = a.optional orelse return b.optional == null;
            const y = b.optional orelse return false;
            return self.equal(x.*, y.*);
        }
        if (a == .message and b == .message) return self.messages.equal(self.arena, a.message, b.message, &self.remaining);
        if (a == .list and b == .list) {
            if (a.list.len != b.list.len) return false;
            for (a.list, b.list) |x, y| if (!try self.equal(x, y)) return false;
            return true;
        }
        if (a == .map and b == .map) {
            if (a.map.len != b.map.len) return false;
            for (a.map) |entry| {
                const other = (try self.lookup(b.map, entry.key)) orelse return false;
                if (!try self.equal(entry.value, other)) return false;
            }
            return true;
        }
        if (a == .string and b == .string and a.string.len == b.string.len) try self.charge(a.string.len);
        if (a == .bytes and b == .bytes and a.bytes.len == b.bytes.len) try self.charge(a.bytes.len);
        if (a == .type_value and b == .type_value) try self.charge(@min(a.type_value.len, b.type_value.len));
        if (a == .enum_value and b == .enum_value)
            try self.charge(@min(a.enum_value.type_name.len, b.enum_value.type_name.len));
        return a.eql(b);
    }

    fn convert(self: *Context, name: []const u8, v: Value) EvalError!Value {
        if (v == .string) try self.charge(v.string.len);
        if (v == .bytes) try self.charge(v.bytes.len);
        if (std.mem.eql(u8, name, "dyn")) return v;
        if (std.mem.eql(u8, name, "type")) return .{ .type_value = switch (v) {
            .null => "null_type",
            .type_value => "type",
            .message => |m| m.type_name,
            .enum_value => |item| item.type_name,
            .optional => "optional_type",
            .ip => "net.IP",
            .cidr => "net.CIDR",
            .timestamp => "google.protobuf.Timestamp",
            .duration => "google.protobuf.Duration",
            else => @tagName(v),
        } };
        if (std.mem.eql(u8, name, "timestamp")) return switch (v) {
            .timestamp => v,
            .string => |text| .{ .timestamp = try temporal.Timestamp.parse(text) },
            .int => |seconds| blk: {
                const time = temporal.Timestamp{ .seconds = seconds };
                try time.validate();
                break :blk .{ .timestamp = time };
            },
            else => error.NoMatchingOverload,
        };
        if (std.mem.eql(u8, name, "duration")) return switch (v) {
            .duration => v,
            .string => |text| .{ .duration = try temporal.Duration.parse(text) },
            else => error.NoMatchingOverload,
        };
        if (std.mem.eql(u8, name, "int")) return .{
            .int = switch (v) {
                .timestamp => |time| time.seconds,
                .enum_value => |item| item.number,
                .int => |n| n,
                .uint => |n| std.math.cast(i64, n) orelse return error.Overflow,
                .double => |n| blk: {
                    // CEL's overflow rules exclude both int endpoints for double conversions.
                    if (!std.math.isFinite(n) or n <= -0x1p63 or n >= 0x1p63) return error.Overflow;
                    break :blk @intFromFloat(n);
                },
                .string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidArgument,
                else => return error.NoMatchingOverload,
            },
        };
        if (std.mem.eql(u8, name, "uint")) return .{ .uint = switch (v) {
            .uint => |n| n,
            .int => |n| std.math.cast(u64, n) orelse return error.Overflow,
            .double => |n| blk: {
                if (!std.math.isFinite(n) or n < 0 or n >= 0x1p64) return error.Overflow;
                break :blk @intFromFloat(n);
            },
            .string => |s| std.fmt.parseInt(u64, s, 10) catch return error.InvalidArgument,
            else => return error.NoMatchingOverload,
        } };
        if (std.mem.eql(u8, name, "double")) return .{ .double = switch (v) {
            .double => |n| n,
            .int => |n| @floatFromInt(n),
            .uint => |n| @floatFromInt(n),
            .string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidArgument,
            else => return error.NoMatchingOverload,
        } };
        if (std.mem.eql(u8, name, "bool")) return .{ .bool = switch (v) {
            .bool => |b| b,
            .string => |s| blk: {
                for ([_][]const u8{ "1", "t", "T", "true", "TRUE", "True" }) |text| {
                    if (std.mem.eql(u8, s, text)) break :blk true;
                }
                for ([_][]const u8{ "0", "f", "F", "false", "FALSE", "False" }) |text| {
                    if (std.mem.eql(u8, s, text)) break :blk false;
                }
                return error.InvalidArgument;
            },
            else => return error.NoMatchingOverload,
        } };
        if (std.mem.eql(u8, name, "bytes")) return switch (v) {
            .bytes => v,
            .string => |s| .{ .bytes = s },
            else => error.NoMatchingOverload,
        };
        if (std.mem.eql(u8, name, "string")) return .{ .string = switch (v) {
            .ip, .cidr => blk: {
                const text = if (v == .ip) try v.ip.format(self.arena) else try v.cidr.format(self.arena);
                if (text.len > self.limits.max_collection_size) return error.CollectionLimitExceeded;
                try self.charge(text.len);
                break :blk text;
            },
            .timestamp => |time| try time.format(self.arena),
            .duration => |span| try span.format(self.arena),
            .string => |s| s,
            .bytes => |s| if (std.unicode.utf8ValidateSlice(s)) s else return error.InvalidArgument,
            .bool => |b| if (b) "true" else "false",
            .int => |n| try std.fmt.allocPrint(self.arena, "{d}", .{n}),
            .uint => |n| try std.fmt.allocPrint(self.arena, "{d}", .{n}),
            .double => |n| try std.fmt.allocPrint(self.arena, "{d}", .{n}),
            else => return error.NoMatchingOverload,
        } };
        return error.NoMatchingOverload;
    }
};

const StringPredicate = enum {
    contains,
    startsWith,
    endsWith,

    const map = std.StaticStringMap(StringPredicate).initComptime(.{
        .{ "contains", .contains }, .{ "startsWith", .startsWith }, .{ "endsWith", .endsWith },
    });
};

fn hasDottedName(list: []const Binding) bool {
    for (list) |binding| if (std.mem.indexOfScalar(u8, binding.name, '.') != null) return true;
    return false;
}

/// Built-in qualified type names such as `net.IP` and `google.protobuf.*` resolve without declarations.
fn qualifiedTypeRoot(node: *const Node) bool {
    const root = names.root(node);
    const name = if (std.mem.startsWith(u8, root, ".")) root[1..] else root;
    return std.mem.eql(u8, name, "net") or std.mem.eql(u8, name, "google");
}

fn boolean(v: Value) EvalError!bool {
    return if (v == .bool) v.bool else error.NoMatchingOverload;
}

fn fatal(err: EvalError) bool {
    return switch (err) {
        error.OutOfMemory, error.CostLimitExceeded, error.DepthLimitExceeded, error.CollectionLimitExceeded, error.RegexLimitExceeded, error.ProtobufLimitExceeded, error.HostFunctionError => true,
        else => false,
    };
}
