//! Bounded CEL string formatting. Values are already materialized by the evaluator.

const std = @import("std");
const errors = @import("errors.zig");
const value = @import("value.zig");
const EvalError = errors.EvalError;
const Entry = value.Entry;
const Value = value.Value;

const default_precision: usize = 6;

/// Format materialized CEL values using the strings extension format syntax.
pub fn format(
    arena: std.mem.Allocator,
    template: []const u8,
    arguments: []const Value,
    remaining: *usize,
    max_output: usize,
    max_depth: usize,
    max_collection: usize,
) EvalError!Value {
    var context = Context{
        .arena = arena,
        .max_output = max_output,
        .remaining = remaining,
        .max_depth = max_depth,
        .max_collection = max_collection,
    };

    try context.charge(template.len);
    if (!std.unicode.utf8ValidateSlice(template)) return error.InvalidArgument;
    if (arguments.len > max_collection) return error.CollectionLimitExceeded;
    var template_index: usize = 0;
    var argument_index: usize = 0;
    while (template_index < template.len) {
        const percent = std.mem.findScalarPos(u8, template, template_index, '%') orelse template.len;
        try context.append(template[template_index..percent]);
        if (percent == template.len) break;
        if (percent + 1 < template.len and template[percent + 1] == '%') {
            try context.charge(1);
            try context.append("%");
            template_index = percent + 2;
            continue;
        }
        if (argument_index >= arguments.len or percent + 1 >= template.len) return error.InvalidArgument;

        var clause_index = percent + 1;
        var precision = default_precision;
        if (template[clause_index] == '.') {
            clause_index += 1;
            if (clause_index >= template.len or
                !std.ascii.isDigit(template[clause_index])) return error.InvalidArgument;
            precision = 0;
            while (clause_index < template.len and std.ascii.isDigit(template[clause_index])) : (clause_index += 1) {
                try context.charge(1);
                const digit = template[clause_index] - '0';
                if (precision > (max_output -| digit) / 10) return error.CollectionLimitExceeded;
                precision = precision * 10 + digit;
                if (precision > max_output) return error.CollectionLimitExceeded;
            }
            if (clause_index >= template.len) return error.InvalidArgument;
        }

        try context.charge(clause_index - percent + 1);
        try context.writeClause(template[clause_index], arguments[argument_index], precision);
        argument_index += 1;
        template_index = clause_index + 1;
    }
    return .{ .string = context.output.items };
}

const Context = struct {
    arena: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    max_output: usize,
    remaining: *usize,
    max_depth: usize,
    max_collection: usize,

    fn charge(self: *Context, amount: usize) EvalError!void {
        if (amount > self.remaining.*) return error.CostLimitExceeded;
        self.remaining.* -= amount;
    }

    fn append(self: *Context, bytes: []const u8) EvalError!void {
        if (bytes.len > self.max_output - self.output.items.len) return error.CollectionLimitExceeded;
        try self.charge(bytes.len);
        try self.output.appendSlice(self.arena, bytes);
    }

    fn writeClause(self: *Context, clause: u8, argument: Value, precision: usize) EvalError!void {
        switch (clause) {
            's' => try self.writeValue(argument, 0),
            'd' => switch (argument) {
                .int => |number| try self.writeInt(number, 10, .lower),
                .uint => |number| try self.writeInt(number, 10, .lower),
                .double => |number| try self.writeFloat(number, .decimal, null),
                else => return error.InvalidArgument,
            },
            'b' => switch (argument) {
                .bool => |boolean| try self.append(if (boolean) "1" else "0"),
                .int => |number| try self.writeInt(number, 2, .lower),
                .uint => |number| try self.writeInt(number, 2, .lower),
                else => return error.InvalidArgument,
            },
            'o' => switch (argument) {
                .int => |number| try self.writeInt(number, 8, .lower),
                .uint => |number| try self.writeInt(number, 8, .lower),
                else => return error.InvalidArgument,
            },
            'x', 'X' => try self.writeHex(argument, clause == 'X'),
            'f', 'e' => {
                const number: f64 = switch (argument) {
                    .int => |integer| @floatFromInt(integer),
                    .uint => |integer| @floatFromInt(integer),
                    .double => |double| double,
                    else => return error.InvalidArgument,
                };
                try self.writeFloat(number, if (clause == 'f') .decimal else .scientific, precision);
            },
            else => return error.InvalidArgument,
        }
    }

    fn writeValue(self: *Context, item: Value, depth: usize) EvalError!void {
        try self.charge(1);
        switch (item) {
            .null => try self.append("null"),
            .bool => |boolean| try self.append(if (boolean) "true" else "false"),
            .int => |number| try self.writeInt(number, 10, .lower),
            .uint => |number| try self.writeInt(number, 10, .lower),
            .double => |number| try self.writeFloat(number, .decimal, null),
            .string, .type_value => {
                const text = if (item == .string) item.string else item.type_value;
                try self.charge(text.len);
                if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidArgument;
                try self.append(text);
            },
            .bytes => |bytes| try self.writeBytes(bytes),
            .timestamp => |timestamp| try self.append(try timestamp.format(self.arena)),
            .duration => |duration| {
                const seconds: f64 = @floatFromInt(@divTrunc(duration.nanoseconds, 1_000_000_000));
                const fraction: f64 = @floatFromInt(@rem(duration.nanoseconds, 1_000_000_000));
                try self.writeFloat(seconds + fraction / 1_000_000_000, .decimal, null);
                try self.append("s");
            },
            .list => |items| try self.writeList(items, depth),
            .map => |entries| try self.writeMap(entries, depth),
            .message, .enum_value, .optional, .ip, .cidr => return error.InvalidArgument,
        }
    }

    fn writeList(self: *Context, items: []const Value, depth: usize) EvalError!void {
        if (depth >= self.max_depth) return error.DepthLimitExceeded;
        if (items.len > self.max_collection) return error.CollectionLimitExceeded;
        try self.append("[");
        for (items, 0..) |item, index| {
            if (index != 0) try self.append(", ");
            try self.writeValue(item, depth + 1);
        }
        try self.append("]");
    }

    fn writeMap(self: *Context, entries: []const Entry, depth: usize) EvalError!void {
        if (depth >= self.max_depth) return error.DepthLimitExceeded;
        if (entries.len > self.max_collection) return error.CollectionLimitExceeded;

        const indices = try self.arena.alloc(usize, entries.len);
        var key_bytes: usize = 0;
        for (entries, 0..) |entry, index| {
            switch (entry.key) {
                .bool, .int, .uint, .string => {},
                else => return error.InvalidArgument,
            }
            indices[index] = index;
            key_bytes +|= keyLength(entry.key);
        }
        const levels = if (entries.len < 2) 1 else std.math.log2_int(usize, entries.len) + 1;
        try self.charge(key_bytes *| levels);
        const Ordering = struct {
            entries: []const Entry,

            fn lessThan(ordering: @This(), a: usize, b: usize) bool {
                var a_buffer: [65]u8 = undefined;
                var b_buffer: [65]u8 = undefined;
                const a_text = keyText(ordering.entries[a].key, &a_buffer);
                const b_text = keyText(ordering.entries[b].key, &b_buffer);
                const result = std.mem.order(u8, a_text, b_text);
                return result == .lt or (result == .eq and a < b);
            }
        };
        std.sort.heap(usize, indices, Ordering{ .entries = entries }, Ordering.lessThan);

        try self.append("{");
        for (indices, 0..) |index, output_index| {
            if (output_index != 0) try self.append(", ");
            try self.writeValue(entries[index].key, depth + 1);
            try self.append(": ");
            try self.writeValue(entries[index].value, depth + 1);
        }
        try self.append("}");
    }

    fn writeInt(self: *Context, number: anytype, base: u8, case: std.fmt.Case) EvalError!void {
        var buffer: [65]u8 = undefined;
        const end = std.fmt.printInt(&buffer, number, base, case, .{});
        try self.append(buffer[0..end]);
    }

    fn writeHex(self: *Context, item: Value, upper: bool) EvalError!void {
        switch (item) {
            .int => |number| try self.writeInt(number, 16, if (upper) .upper else .lower),
            .uint => |number| try self.writeInt(number, 16, if (upper) .upper else .lower),
            .string, .bytes => {
                const bytes = if (item == .string) item.string else item.bytes;
                if (bytes.len > (self.max_output - self.output.items.len) / 2) return error.CollectionLimitExceeded;
                const alphabet = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
                for (bytes) |byte| try self.append(&.{ alphabet[byte >> 4], alphabet[byte & 0x0f] });
            },
            else => return error.InvalidArgument,
        }
    }

    fn writeFloat(self: *Context, number: f64, mode: std.fmt.Number.Mode, precision: ?usize) EvalError!void {
        if (std.math.isNan(number)) return self.append("NaN");
        if (std.math.isInf(number)) return self.append(if (number < 0) "-Infinity" else "Infinity");
        if (precision) |digits| if (digits > self.max_output - self.output.items.len) return error.CollectionLimitExceeded;
        try self.charge(1 +| (precision orelse 0));
        var buffer: [384]u8 = undefined;
        const needed = @max(buffer.len, std.math.add(usize, precision orelse 0, 350) catch return error.CollectionLimitExceeded);
        const storage = if (needed <= buffer.len) &buffer else try self.arena.alloc(u8, needed);
        if (precision) |digits| {
            const count = std.math.cast(c_int, digits) orelse return error.CollectionLimitExceeded;
            var written: usize = 0;
            if (cel_format_double(number, count, @intFromBool(mode == .scientific), storage.ptr, storage.len, &written) != 0)
                return error.CollectionLimitExceeded;
            try self.append(storage[0..written]);
        } else {
            const text = std.fmt.float.render(storage, number, .{ .mode = .decimal }) catch return error.CollectionLimitExceeded;
            try self.append(text);
        }
    }

    fn writeBytes(self: *Context, bytes: []const u8) EvalError!void {
        try self.charge(bytes.len);
        var start: usize = 0;
        var index: usize = 0;
        var invalid = false;
        while (index < bytes.len) {
            const width = std.unicode.utf8ByteSequenceLength(bytes[index]) catch 0;
            const valid = width > 0 and width <= bytes.len - index and
                (std.unicode.utf8Decode(bytes[index..][0..width]) catch 0x110000) <= 0x10ffff;
            if (valid) {
                if (invalid) {
                    try self.append("\xef\xbf\xbd");
                    start = index;
                    invalid = false;
                }
                index += width;
            } else {
                if (!invalid) try self.append(bytes[start..index]);
                invalid = true;
                index += 1;
            }
        }
        try self.append(if (invalid) "\xef\xbf\xbd" else bytes[start..]);
    }
};

fn keyLength(key: Value) usize {
    return switch (key) {
        .string => |text| text.len,
        .bool => |boolean| if (boolean) 4 else 5,
        .int, .uint => 20,
        else => 0,
    };
}

fn keyText(key: Value, buffer: *[65]u8) []const u8 {
    return switch (key) {
        .string => |text| text,
        .bool => |boolean| if (boolean) "true" else "false",
        .int => |number| buffer[0..std.fmt.printInt(buffer, number, 10, .lower, .{})],
        .uint => |number| buffer[0..std.fmt.printInt(buffer, number, 10, .lower, .{})],
        else => "",
    };
}

extern fn cel_format_double(value: f64, precision: c_int, scientific: c_int, buffer: [*]u8, size: usize, written: *usize) c_int;
