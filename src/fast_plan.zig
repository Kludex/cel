//! Emit the plain-data subset of a compiled program as JSON so a host wrapper can compile it to native code.
//! The subset covers bool/int/string literals, identifiers, unquoted field selection, indexing, comparison and
//! arithmetic operators, `!`/unary minus, `?:`, `in` against a list literal, `size()`, the `startsWith`/`endsWith`/
//! `contains` string predicates, `matches` against a literal pattern, and single-variable `all`/`exists` over a
//! list. Anything else yields no plan.

const std = @import("std");
const syntax = @import("syntax.zig");
const names = @import("names.zig");
const Node = syntax.Node;

/// Serialize the subset or return null when any node falls outside it. The result is caller-owned.
pub fn emit(gpa: std.mem.Allocator, root: *const Node) error{OutOfMemory}!?[]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    write(&json, root, 0) catch |err| switch (err) {
        error.Unsupported => {
            out.deinit();
            return null;
        },
        error.WriteFailed => return error.OutOfMemory,
    };
    return try out.toOwnedSlice();
}

const max_depth: usize = 64;
/// JavaScript numbers represent integers exactly only inside this range.
const max_safe_integer: i64 = 9007199254740991;

fn write(json: *std.json.Stringify, node: *const Node, depth: usize) (std.json.Stringify.Error || error{Unsupported})!void {
    if (depth >= max_depth) return error.Unsupported;
    switch (node.*) {
        .literal => |v| switch (v) {
            .bool => |b| try json.write(.{ "bool", b }),
            .int => |n| {
                if (n < -max_safe_integer or n > max_safe_integer) return error.Unsupported;
                try json.write(.{ "int", n });
            },
            .string => |s| try json.write(.{ "string", s }),
            else => return error.Unsupported,
        },
        .ident => |name| {
            if (!names.valid(name, false) or std.mem.indexOfScalar(u8, name, '.') != null) return error.Unsupported;
            try json.write(.{ "ident", name });
        },
        .select => |s| {
            // A quoted field such as `a.\`b-c\`` is not a valid identifier; the host reads plain properties only.
            if (s.optional or !names.valid(s.field, false) or std.mem.indexOfScalar(u8, s.field, '.') != null) {
                return error.Unsupported;
            }
            try json.beginArray();
            try json.write("select");
            try write(json, s.target, depth + 1);
            try json.write(s.field);
            try json.endArray();
        },
        .binary => |b| {
            const op: []const u8 = switch (b.op) {
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
                .and_op => "&&",
                .or_op => "||",
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .percent => "%",
                .in_op => "in",
                else => return error.Unsupported,
            };
            try json.beginArray();
            try json.write(op);
            try write(json, b.left, depth + 1);
            try write(json, b.right, depth + 1);
            try json.endArray();
        },
        .conditional => |c| {
            try json.beginArray();
            try json.write("?:");
            try write(json, c.condition, depth + 1);
            try write(json, c.yes, depth + 1);
            try write(json, c.no, depth + 1);
            try json.endArray();
        },
        .index => |i| {
            if (i.optional) return error.Unsupported;
            try json.beginArray();
            try json.write("index");
            try write(json, i.target, depth + 1);
            try write(json, i.key, depth + 1);
            try json.endArray();
        },
        .list => |items| {
            // Only string-literal lists are emitted; they appear as the right side of `in`.
            try json.beginArray();
            try json.write("list");
            for (items) |item| {
                if (item.optional or item.value.* != .literal or item.value.literal != .string) return error.Unsupported;
                try json.write(item.value.literal.string);
            }
            try json.endArray();
        },
        .comprehension => |c| {
            if (c.value_name != null or c.transform != null) return error.Unsupported;
            const kind: []const u8 = switch (c.kind) {
                .all => "all",
                .exists => "exists",
                else => return error.Unsupported,
            };
            const predicate = c.predicate orelse return error.Unsupported;
            if (!names.valid(c.key_name, false) or std.mem.indexOfScalar(u8, c.key_name, '.') != null) return error.Unsupported;
            try json.beginArray();
            try json.write(kind);
            try write(json, c.target, depth + 1);
            try json.write(c.key_name);
            try write(json, predicate, depth + 1);
            try json.endArray();
        },
        .unary => |u| {
            try json.beginArray();
            try json.write(switch (u.op) {
                .bang => "!",
                .minus => "neg",
                else => return error.Unsupported,
            });
            try write(json, u.operand, depth + 1);
            try json.endArray();
        },
        .call => |c| {
            const target = c.target orelse return error.Unsupported;
            if (c.function_indices != null) return error.Unsupported;
            if (std.mem.eql(u8, c.name, "size") and c.args.len == 0) {
                try json.beginArray();
                try json.write("size");
                try write(json, target, depth + 1);
                try json.endArray();
                return;
            }
            if (c.args.len != 1) return error.Unsupported;
            if (std.mem.eql(u8, c.name, "matches")) {
                // Only literal patterns are precompiled by the program; the host asks the engine to match them.
                if (c.args[0].* != .literal or c.args[0].literal != .string) return error.Unsupported;
                try json.beginArray();
                try json.write("matches");
                try write(json, target, depth + 1);
                try json.write(c.args[0].literal.string);
                try json.endArray();
                return;
            }
            const known = std.StaticStringMap(void).initComptime(.{ .{"startsWith"}, .{"endsWith"}, .{"contains"} });
            if (!known.has(c.name)) return error.Unsupported;
            try json.beginArray();
            try json.write(c.name);
            try write(json, target, depth + 1);
            try write(json, c.args[0], depth + 1);
            try json.endArray();
        },
        else => return error.Unsupported,
    }
}
