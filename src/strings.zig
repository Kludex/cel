//! UTF-8 CEL string extensions. Results borrow inputs or use caller-owned arena storage.

const std = @import("std");
const value = @import("value.zig");
const EvalError = @import("errors.zig").EvalError;
const Value = value.Value;

/// String extension operations, excluding general value formatting.
pub const Operation = enum { charAt, indexOf, lastIndexOf, lowerAscii, upperAscii, replace, split, substring, trim, join, reverse, quote };

/// Resolve a receiver-style string extension.
pub fn method(name: []const u8) ?Operation {
    const op = std.meta.stringToEnum(Operation, name) orelse return null;
    return if (op == .quote) null else op;
}

/// Evaluate materialized arguments with explicit work and output limits.
pub fn evaluate(arena: std.mem.Allocator, op: Operation, args: []const Value, remaining: *usize, limit: usize) EvalError!Value {
    var context = Context{ .arena = arena, .remaining = remaining, .limit = limit };
    if (args.len == 0) return error.NoMatchingOverload;
    if (op == .join) {
        if (args.len > 2 or args[0] != .list or (args.len == 2 and args[1] != .string)) return error.NoMatchingOverload;
        if (args[0].list.len > limit) return error.CollectionLimitExceeded;
        const separator = if (args.len == 2) args[1].string else "";
        try context.validate(separator);
        var out: std.ArrayList(u8) = .empty;
        for (args[0].list, 0..) |item, i| {
            if (item != .string) return error.NoMatchingOverload;
            try context.validate(item.string);
            if (i != 0) try context.append(&out, separator);
            try context.append(&out, item.string);
        }
        return .{ .string = out.items };
    }
    if (args[0] != .string) return error.NoMatchingOverload;
    const text = args[0].string;
    try context.validate(text);
    switch (op) {
        .charAt, .substring => {
            if (args.len < 2 or args.len > (if (op == .charAt) @as(usize, 2) else 3) or args[1] != .int or
                (args.len == 3 and args[2] != .int)) return error.NoMatchingOverload;
            const start = try offset(text, args[1].int);
            const end = if (op == .charAt)
                (if (start == text.len) start else start + (std.unicode.utf8ByteSequenceLength(text[start]) catch return error.InvalidArgument))
            else if (args.len == 3) try offset(text, args[2].int) else text.len;
            if (end < start) return error.InvalidArgument;
            if (end - start > limit) return error.CollectionLimitExceeded;
            return .{ .string = text[start..end] };
        },
        .indexOf, .lastIndexOf => {
            if (args.len < 2 or args.len > 3 or args[1] != .string or (args.len == 3 and args[2] != .int))
                return error.NoMatchingOverload;
            const needle = args[1].string;
            try context.validate(needle);
            const start = if (args.len == 3) try offset(text, args[2].int) else if (op == .indexOf) 0 else text.len;
            if (needle.len == 0) return .{ .int = @intCast(std.unicode.utf8CountCodepoints(text[0..start]) catch return error.InvalidArgument) };
            const found = if (op == .indexOf) blk: {
                const index = try context.find(text[start..], needle, false) orelse return .{ .int = -1 };
                break :blk start + index;
            } else try context.find(text[0..@min(text.len, start +| needle.len)], needle, true) orelse return .{ .int = -1 };
            return .{ .int = @intCast(std.unicode.utf8CountCodepoints(text[0..found]) catch return error.InvalidArgument) };
        },
        .lowerAscii, .upperAscii, .reverse => {
            if (args.len != 1) return error.NoMatchingOverload;
            if (text.len > limit) return error.CollectionLimitExceeded;
            try context.charge(text.len);
            const out = try arena.alloc(u8, text.len);
            if (op == .reverse) {
                var index: usize = 0;
                while (index < text.len) {
                    const size = std.unicode.utf8ByteSequenceLength(text[index]) catch return error.InvalidArgument;
                    @memcpy(out[text.len - index - size ..][0..size], text[index..][0..size]);
                    index += size;
                }
            } else for (text, out) |c, *destination| {
                destination.* = if (op == .lowerAscii) std.ascii.toLower(c) else std.ascii.toUpper(c);
            }
            return .{ .string = out };
        },
        .trim => {
            if (args.len != 1) return error.NoMatchingOverload;
            var start: usize = 0;
            var end: usize = 0;
            var leading = true;
            var iterator = (std.unicode.Utf8View.init(text) catch return error.InvalidArgument).iterator();
            while (iterator.nextCodepoint()) |cp| {
                const whitespace = switch (cp) {
                    0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
                    else => false,
                };
                if (leading and whitespace) start = iterator.i else leading = false;
                if (!whitespace) end = iterator.i;
            }
            const result = text[start..@max(start, end)];
            if (result.len > limit) return error.CollectionLimitExceeded;
            return .{ .string = result };
        },
        .quote => {
            if (args.len != 1) return error.NoMatchingOverload;
            var out: std.ArrayList(u8) = .empty;
            try context.append(&out, "\"");
            for (text) |c| {
                const escaped: ?u8 = switch (c) {
                    7 => 'a',
                    8 => 'b',
                    12 => 'f',
                    10 => 'n',
                    13 => 'r',
                    9 => 't',
                    11 => 'v',
                    '\\' => '\\',
                    '"' => '"',
                    else => null,
                };
                if (escaped) |e| try context.append(&out, &.{ '\\', e }) else try context.append(&out, &.{c});
            }
            try context.append(&out, "\"");
            return .{ .string = out.items };
        },
        .replace => {
            if (args.len < 3 or args.len > 4 or args[1] != .string or args[2] != .string or
                (args.len == 4 and args[3] != .int)) return error.NoMatchingOverload;
            const old = args[1].string;
            const new = args[2].string;
            try context.validate(old);
            try context.validate(new);
            const count = if (args.len == 4) args[3].int else -1;
            if (count == 0) {
                if (text.len > limit) return error.CollectionLimitExceeded;
                return .{ .string = text };
            }
            var out: std.ArrayList(u8) = .empty;
            var start: usize = 0;
            var replaced: usize = 0;
            while (count < 0 or replaced < count) {
                const found = if (old.len == 0) start else start + (try context.find(text[start..], old, false) orelse break);
                try context.append(&out, text[start..found]);
                try context.append(&out, new);
                replaced += 1;
                start = found + old.len;
                if (old.len == 0) {
                    if (start == text.len) break;
                    const size = std.unicode.utf8ByteSequenceLength(text[start]) catch return error.InvalidArgument;
                    try context.append(&out, text[start..][0..size]);
                    start += size;
                }
            }
            try context.append(&out, text[start..]);
            return .{ .string = out.items };
        },
        .split => {
            if (args.len < 2 or args.len > 3 or args[1] != .string or (args.len == 3 and args[2] != .int))
                return error.NoMatchingOverload;
            const separator = args[1].string;
            try context.validate(separator);
            const count = if (args.len == 3) args[2].int else -1;
            if (count == 0 or (separator.len == 0 and text.len == 0)) return .{ .list = &.{} };
            var out: std.ArrayList(Value) = .empty;
            var start: usize = 0;
            while (count < 0 or out.items.len + 1 < count) {
                const end = if (separator.len == 0) blk: {
                    if (start == text.len) break;
                    break :blk start + (std.unicode.utf8ByteSequenceLength(text[start]) catch return error.InvalidArgument);
                } else start + (try context.find(text[start..], separator, false) orelse break);
                if (out.items.len >= limit or end - start > limit) return error.CollectionLimitExceeded;
                try context.charge(1);
                try out.append(arena, .{ .string = text[start..end] });
                start = end + separator.len;
            }
            if (separator.len != 0 or start < text.len) {
                if (out.items.len >= limit or text.len - start > limit) return error.CollectionLimitExceeded;
                try context.charge(1);
                try out.append(arena, .{ .string = text[start..] });
            }
            return .{ .list = out.items };
        },
        .join => unreachable,
    }
}

fn offset(text: []const u8, index: i64) EvalError!usize {
    if (index < 0) return error.IndexOutOfBounds;
    var position: usize = 0;
    var count: usize = 0;
    while (count < index) : (count += 1) {
        if (position == text.len) return error.IndexOutOfBounds;
        position += std.unicode.utf8ByteSequenceLength(text[position]) catch return error.InvalidArgument;
    }
    return position;
}

const Context = struct {
    arena: std.mem.Allocator,
    remaining: *usize,
    limit: usize,

    fn charge(self: *Context, cost: usize) EvalError!void {
        if (cost > self.remaining.*) return error.CostLimitExceeded;
        self.remaining.* -= cost;
    }

    fn validate(self: *Context, bytes: []const u8) EvalError!void {
        try self.charge(bytes.len *| 3);
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidArgument;
    }

    fn append(self: *Context, out: *std.ArrayList(u8), bytes: []const u8) EvalError!void {
        if (bytes.len > self.limit - out.items.len) return error.CollectionLimitExceeded;
        try self.charge(bytes.len);
        try out.appendSlice(self.arena, bytes);
    }

    fn find(self: *Context, text: []const u8, needle: []const u8, reverse: bool) EvalError!?usize {
        if (needle.len > text.len) return null;
        const positions = text.len - needle.len + 1;
        const allowed = @min(positions, self.remaining.* / needle.len);
        if (allowed == 0) return error.CostLimitExceeded;
        const base = if (reverse) positions - allowed else 0;
        const portion = text[base .. base + allowed + needle.len - 1];
        const found = if (reverse) std.mem.lastIndexOf(u8, portion, needle) else std.mem.indexOf(u8, portion, needle);
        const scanned = if (found) |n| (if (reverse) allowed - n else n + 1) else allowed;
        try self.charge(scanned * needle.len);
        if (found) |n| return base + n;
        if (allowed < positions) return error.CostLimitExceeded;
        return null;
    }
};
