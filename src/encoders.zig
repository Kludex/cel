//! Bounded Base64 operations using Zig's codecs. Encoded and decoded results belong to the caller's arena.

const std = @import("std");
const Value = @import("value.zig").Value;
const EvalError = @import("errors.zig").EvalError;

/// Supported Base64 alphabet and direction choices.
pub const Operation = enum { encode, decode, encodeUrl, decodeUrl };

/// Resolve a qualified function or an unqualified name within the Base64 container.
pub fn operation(name: []const u8, container: []const u8) ?Operation {
    const absolute = std.mem.startsWith(u8, name, ".");
    const local = if (absolute) name[1..] else name;
    if (std.mem.startsWith(u8, local, "base64.")) return std.meta.stringToEnum(Operation, local[7..]);
    if (!absolute and (std.mem.eql(u8, container, "base64") or std.mem.startsWith(u8, container, "base64.")))
        return std.meta.stringToEnum(Operation, local);
    return null;
}

/// Transform one argument with explicit work and output accounting.
pub fn evaluate(arena: std.mem.Allocator, op: Operation, input: Value, remaining: *usize, limit: usize) EvalError!Value {
    const encode = op == .encode or op == .encodeUrl;
    const url = op == .encodeUrl or op == .decodeUrl;
    if (encode) {
        if (input != .bytes) return error.NoMatchingOverload;
        const rounded = std.math.add(usize, input.bytes.len, 2) catch return error.CollectionLimitExceeded;
        const length = std.math.mul(usize, rounded / 3, 4) catch return error.CollectionLimitExceeded;
        if (length > limit) return error.CollectionLimitExceeded;
        try charge(remaining, input.bytes.len +| length);
        const result = try arena.alloc(u8, length);
        const codec = if (url) std.base64.url_safe.Encoder else std.base64.standard.Encoder;
        return .{ .string = codec.encode(result, input.bytes) };
    }
    if (input != .string) return error.NoMatchingOverload;
    try charge(remaining, input.string.len *| 3);
    var source = input.string;
    var owned: ?[]u8 = null;
    if (std.mem.indexOfAny(u8, source, "\r\n") != null) {
        const buffer = try arena.alloc(u8, source.len);
        var length: usize = 0;
        for (source) |byte| {
            if (byte == '\r' or byte == '\n') continue;
            buffer[length] = byte;
            length += 1;
        }
        owned = buffer[0..length];
        source = owned.?;
    }
    var padding: usize = 0;
    while (padding < source.len and source[source.len - padding - 1] == '=') : (padding += 1) {}
    if (padding > 2 or (padding > 0 and source.len % 4 != 0)) return error.InvalidArgument;
    if (padding > 0) source = source[0 .. source.len - padding];
    const tail = source.len % 4;
    if (tail == 1 or (padding > 0 and padding != 4 - tail)) return error.InvalidArgument;
    const decoder = if (url) std.base64.url_safe_no_pad.Decoder else std.base64.standard_no_pad.Decoder;
    const length = decoder.calcSizeForSlice(source) catch return error.InvalidArgument;
    if (length > limit) return error.CollectionLimitExceeded;
    try charge(remaining, length);
    if (tail != 0) {
        const alphabet = if (url) std.base64.url_safe_alphabet_chars else std.base64.standard_alphabet_chars;
        const last = source.len - 1;
        const digit = std.mem.indexOfScalar(u8, &alphabet, source[last]) orelse return error.InvalidArgument;
        const mask: usize = if (tail == 2) 0x30 else 0x3c;
        if (digit & mask != digit) {
            // CEL-Go accepts unused tail bits that Zig's decoder requires to be zero.
            const buffer = if (owned) |bytes| bytes[0..source.len] else try arena.dupe(u8, source);
            buffer[last] = alphabet[digit & mask];
            source = buffer;
        }
    }
    const result = try arena.alloc(u8, length);
    decoder.decode(result, source) catch return error.InvalidArgument;
    return .{ .bytes = result };
}

fn charge(remaining: *usize, cost: usize) EvalError!void {
    if (cost > remaining.*) return error.CostLimitExceeded;
    remaining.* -= cost;
}
