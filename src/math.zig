//! CEL math extension operations. Values retain their numeric tags; callers bound evaluation work.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

/// Supported math-extension operations.
pub const Operation = enum {
    greatest,
    least,
    ceil,
    floor,
    round,
    trunc,
    abs,
    sign,
    isNaN,
    isInf,
    isFinite,
    bitAnd,
    bitOr,
    bitXor,
    bitNot,
    bitShiftLeft,
    bitShiftRight,
};

/// Resolve a global math-extension name, including an absolute name.
pub fn operation(name: []const u8) ?Operation {
    const full = if (std.mem.startsWith(u8, name, ".")) name[1..] else name;
    const entries = std.StaticStringMap(Operation).initComptime(.{
        .{ "math.greatest", .greatest },           .{ "math.least", .least },
        .{ "math.ceil", .ceil },                   .{ "math.floor", .floor },
        .{ "math.round", .round },                 .{ "math.trunc", .trunc },
        .{ "math.abs", .abs },                     .{ "math.sign", .sign },
        .{ "math.isNaN", .isNaN },                 .{ "math.isInf", .isInf },
        .{ "math.isFinite", .isFinite },           .{ "math.bitAnd", .bitAnd },
        .{ "math.bitOr", .bitOr },                 .{ "math.bitXor", .bitXor },
        .{ "math.bitNot", .bitNot },               .{ "math.bitShiftLeft", .bitShiftLeft },
        .{ "math.bitShiftRight", .bitShiftRight },
    });
    return entries.get(full);
}

/// Evaluate scalar arguments or a single list for greatest/least; results borrow argument storage.
pub fn evaluate(op: Operation, arguments: []const Value) error{
    /// The supplied argument types or count have no matching overload.
    NoMatchingOverload,
    /// A list is empty, a comparison contains NaN, or a shift count is negative.
    InvalidArgument,
    /// An absolute value cannot fit a signed CEL integer.
    Overflow,
}!Value {
    if (op == .greatest or op == .least) {
        const items = if (arguments.len == 1 and arguments[0] == .list) arguments[0].list else arguments;
        if (items.len == 0) return error.InvalidArgument;
        var result = items[0];
        if (!result.numeric()) return error.NoMatchingOverload;
        for (items[1..]) |item| {
            if (!item.numeric()) return error.NoMatchingOverload;
            const order = result.order(item) orelse return error.InvalidArgument;
            if ((op == .greatest and order == .lt) or (op == .least and order == .gt)) result = item;
        }
        return result;
    }
    const arity: usize = switch (op) {
        .bitAnd, .bitOr, .bitXor, .bitShiftLeft, .bitShiftRight => 2,
        else => 1,
    };
    if (arguments.len != arity) return error.NoMatchingOverload;
    const first = arguments[0];
    switch (op) {
        .ceil, .floor, .round, .trunc, .isNaN, .isInf, .isFinite => {
            if (first != .double) return error.NoMatchingOverload;
            return switch (op) {
                .ceil => .{ .double = @ceil(first.double) },
                .floor => .{ .double = @floor(first.double) },
                .round => .{ .double = @round(first.double) },
                .trunc => .{ .double = @trunc(first.double) },
                .isNaN => .{ .bool = std.math.isNan(first.double) },
                .isInf => .{ .bool = std.math.isInf(first.double) },
                .isFinite => .{ .bool = std.math.isFinite(first.double) },
                else => unreachable,
            };
        },
        .abs => return switch (first) {
            .int => |v| .{ .int = if (v >= 0) v else std.math.negate(v) catch return error.Overflow },
            .uint => first,
            .double => |v| .{ .double = @abs(v) },
            else => error.NoMatchingOverload,
        },
        .sign => return switch (first) {
            .int => |v| .{ .int = if (v < 0) -1 else if (v > 0) 1 else 0 },
            .uint => |v| .{ .uint = if (v > 0) 1 else 0 },
            .double => |v| .{ .double = if (std.math.isNan(v)) v else if (v < 0) -1 else if (v > 0) 1 else 0 },
            else => error.NoMatchingOverload,
        },
        .bitAnd, .bitOr, .bitXor, .bitNot, .bitShiftLeft, .bitShiftRight => {
            const bits: u64 = switch (first) {
                .int => |v| @bitCast(v),
                .uint => |v| v,
                else => return error.NoMatchingOverload,
            };
            const result: u64 = if (op == .bitNot) ~bits else if (op == .bitShiftLeft or op == .bitShiftRight) blk: {
                if (arguments[1] != .int) return error.NoMatchingOverload;
                const offset = arguments[1].int;
                if (offset < 0) return error.InvalidArgument;
                if (offset >= 64) break :blk 0;
                const shift: u6 = @intCast(offset);
                break :blk if (op == .bitShiftLeft) bits << shift else bits >> shift;
            } else blk: {
                if (std.meta.activeTag(first) != std.meta.activeTag(arguments[1])) return error.NoMatchingOverload;
                const other: u64 = if (first == .int) @bitCast(arguments[1].int) else arguments[1].uint;
                break :blk switch (op) {
                    .bitAnd => bits & other,
                    .bitOr => bits | other,
                    .bitXor => bits ^ other,
                    else => unreachable,
                };
            };
            return if (first == .int) .{ .int = @bitCast(result) } else .{ .uint = result };
        },
        .greatest, .least => unreachable,
    }
}
