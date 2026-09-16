//! Emit the plain-data subset of a compiled program as JSON so a host wrapper can compile it to native code.
//! The subset covers bool/int/string literals, identifiers, unquoted field selection, string-literal indexing,
//! `==`/`!=`, `&&`/`||`, `!`, `?:`, and the `startsWith`/`endsWith`/`contains` string predicates. Anything else
//! yields no plan.

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
                .and_op => "&&",
                .or_op => "||",
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
            // Only string-literal keys keep object-property semantics; list indexes and dynamic keys do not.
            if (i.optional or i.key.* != .literal or i.key.literal != .string) return error.Unsupported;
            try json.beginArray();
            try json.write("index");
            try write(json, i.target, depth + 1);
            try json.write(i.key.literal.string);
            try json.endArray();
        },
        .unary => |u| {
            if (u.op != .bang) return error.Unsupported;
            try json.beginArray();
            try json.write("!");
            try write(json, u.operand, depth + 1);
            try json.endArray();
        },
        .call => |c| {
            const target = c.target orelse return error.Unsupported;
            if (c.args.len != 1 or c.function_indices != null) return error.Unsupported;
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
