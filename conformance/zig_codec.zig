//! Strict JSON transport for the Zig conformance driver. Returned storage belongs to the caller's arena.

const std = @import("std");
const cel = @import("cel");

const max_depth = 128;

/// Failures exposed by the conformance transport.
pub const Error = error{
    /// The caller's arena could not allocate output storage.
    OutOfMemory,
    /// A recognized transport value has an invalid shape or payload.
    InvalidInput,
    /// The transport or CEL value has no supported representation.
    UnsupportedValue,
    /// A value or type exceeds 128 nested levels.
    DepthLimitExceeded,
    /// Decoded CEL values exceed the work budget.
    ValueLimitExceeded,
    /// Decoded string, byte, or name storage exceeds the byte budget.
    ByteLimitExceeded,
};

/// Limits aggregate decoded values and owned byte storage.
pub const Budget = struct {
    /// CEL values that may still be decoded.
    remaining: usize = 100_000,
    /// Payload bytes that may still be copied or decoded.
    bytes: usize = 1_048_576,
};

/// Decode one strict conformance transport value into arena-owned CEL storage.
pub fn decodeValue(
    arena: std.mem.Allocator,
    input: std.json.Value,
    budget: *Budget,
    depth: usize,
) Error!cel.Value {
    try enter(depth);
    try consumeValues(budget, 1);
    const object = switch (input) {
        .object => |value| value,
        else => return error.InvalidInput,
    };
    if (object.count() != 1) return error.InvalidInput;

    if (object.get("nullValue")) |raw| {
        const valid = raw == .null or (raw == .string and std.mem.eql(u8, raw.string, "NULL_VALUE")) or
            (raw == .integer and raw.integer == 0);
        if (!valid) return error.InvalidInput;
        return .null;
    }
    if (object.get("boolValue")) |raw| return .{ .bool = switch (raw) {
        .bool => |value| value,
        else => return error.InvalidInput,
    } };
    if (object.get("int64Value")) |raw| return .{ .int = try parseDecimal(i64, raw, true) };
    if (object.get("uint64Value")) |raw| return .{ .uint = try parseDecimal(u64, raw, false) };
    if (object.get("doubleValue")) |raw| return .{ .double = try decodeDouble(raw) };
    if (object.get("stringValue")) |raw| return .{ .string = try copyString(arena, raw, budget) };
    if (object.get("bytesValue")) |raw| return .{ .bytes = try decodeBytes(arena, raw, budget) };
    if (object.get("typeValue")) |raw| {
        const name = try copyString(arena, raw, budget);
        if (name.len == 0) return error.InvalidInput;
        return .{ .type_value = name };
    }

    if (object.get("ipValue")) |raw| return cel.Value.fromIP(arena, cel.IP.parse(try copyString(arena, raw, budget)) catch return error.InvalidInput);
    if (object.get("cidrValue")) |raw| return cel.Value.fromCIDR(arena, cel.CIDR.parse(try copyString(arena, raw, budget)) catch return error.InvalidInput);
    if (object.get("optionalValue")) |raw| {
        const item = try expectObject(raw);
        if (!hasOnly(item, &.{"value"})) return error.InvalidInput;
        return cel.Value.fromOptional(arena, if (item.get("value")) |v|
            try decodeValue(arena, v, budget, depth + 1)
        else
            null);
    }
    if (object.get("enumValue")) |raw| {
        const item = try expectObject(raw);
        if (!hasOnly(item, &.{ "type", "value" }) or item.get("type") == null) return error.InvalidInput;
        const type_name = try copyString(arena, item.get("type").?, budget);
        var segments = std.mem.splitScalar(u8, type_name, '.');
        var count: usize = 0;
        while (segments.next()) |segment| {
            count += 1;
            if (count > max_depth or segment.len == 0 or
                (!std.ascii.isAlphabetic(segment[0]) and segment[0] != '_')) return error.InvalidInput;
            for (segment[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidInput;
        }
        const number: i32 = if (item.get("value")) |value| switch (value) {
            .integer => |integer| std.math.cast(i32, integer) orelse return error.InvalidInput,
            else => return error.InvalidInput,
        } else 0;
        return cel.Value.fromEnum(arena, .{ .type_name = type_name, .number = number });
    }
    if (object.get("messageValue")) |raw| {
        const item = try expectObject(raw);
        if (!hasExactly(item, &.{ "typeName", "data" })) return error.InvalidInput;
        const type_name = try copyString(arena, item.get("typeName").?, budget);
        if (type_name.len == 0) return error.InvalidInput;
        const data = try decodeBytes(arena, item.get("data").?, budget);
        return cel.Value.fromMessage(arena, .{ .type_name = type_name, .data = data });
    }
    if (object.get("timestampValue")) |raw| {
        const item = try expectObject(raw);
        if (!hasExactly(item, &.{ "seconds", "nanos" })) return error.InvalidInput;
        const nanos = switch (item.get("nanos").?) {
            .integer => |value| std.math.cast(u32, value) orelse return error.InvalidInput,
            else => return error.InvalidInput,
        };
        const timestamp: cel.Value = .{ .timestamp = .{
            .seconds = try parseDecimal(i64, item.get("seconds").?, true),
            .nanos = nanos,
        } };
        timestamp.timestamp.validate() catch return error.InvalidInput;
        return timestamp;
    }
    if (object.get("durationValue")) |raw| return .{ .duration = .{
        .nanoseconds = try parseDecimal(i64, raw, true),
    } };
    if (object.get("listValue")) |raw| {
        const item = try expectObject(raw);
        if (!hasOnly(item, &.{"values"})) return error.InvalidInput;
        const source = if (item.get("values")) |values| switch (values) {
            .array => |array| array.items,
            else => return error.InvalidInput,
        } else &.{};
        if (source.len > budget.remaining) return error.ValueLimitExceeded;
        const values = try arena.alloc(cel.Value, source.len);
        for (source, values) |value, *output| output.* = try decodeValue(arena, value, budget, depth + 1);
        return .{ .list = values };
    }
    if (object.get("mapValue")) |raw| {
        const item = try expectObject(raw);
        if (!hasOnly(item, &.{"entries"})) return error.InvalidInput;
        const source = if (item.get("entries")) |entries| switch (entries) {
            .array => |array| array.items,
            else => return error.InvalidInput,
        } else &.{};
        if (source.len > budget.remaining / 2) return error.ValueLimitExceeded;
        const entries = try arena.alloc(cel.Entry, source.len);
        for (source, entries) |entry_value, *output| {
            const entry = try expectObject(entry_value);
            if (!hasExactly(entry, &.{ "key", "value" })) return error.InvalidInput;
            output.* = .{
                .key = try decodeValue(arena, entry.get("key").?, budget, depth + 1),
                .value = try decodeValue(arena, entry.get("value").?, budget, depth + 1),
            };
        }
        cel.value.validateMapKeys(arena, entries) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidMapKey, error.DuplicateKey => error.InvalidInput,
        };
        return .{ .map = entries };
    }
    return error.UnsupportedValue;
}

/// Encode one CEL value as arena-owned conformance transport JSON.
pub fn encodeValue(arena: std.mem.Allocator, input: cel.Value, depth: usize) Error!std.json.Value {
    try enter(depth);
    return switch (input) {
        .null => tagged(arena, "nullValue", .null),
        .bool => |value| tagged(arena, "boolValue", .{ .bool = value }),
        .int => |value| tagged(arena, "int64Value", try decimalString(arena, value)),
        .uint => |value| tagged(arena, "uint64Value", try decimalString(arena, value)),
        .double => |value| tagged(arena, "doubleValue", encodeDouble(value)),
        .string => |value| tagged(arena, "stringValue", .{ .string = try arena.dupe(u8, value) }),
        .bytes => |value| tagged(arena, "bytesValue", .{ .string = try encodeBytes(arena, value) }),
        .type_value => |value| tagged(arena, "typeValue", .{ .string = try arena.dupe(u8, value) }),
        .ip => |v| tagged(arena, "ipValue", .{ .string = v.format(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnsupportedValue,
        } }),
        .cidr => |v| tagged(arena, "cidrValue", .{ .string = v.format(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnsupportedValue,
        } }),
        .optional => |present| tagged(arena, "optionalValue", if (present) |v|
            try objectValue(arena, &.{.{ "value", try encodeValue(arena, v.*, depth + 1) }})
        else
            try objectValue(arena, &.{})),
        .enum_value => |value| tagged(arena, "enumValue", try objectValue(arena, &.{
            .{ "type", .{ .string = try arena.dupe(u8, value.type_name) } },
            .{ "value", .{ .integer = value.number } },
        })),
        .message => |value| blk: {
            if (value.native != null) return error.UnsupportedValue;
            break :blk tagged(arena, "messageValue", try objectValue(arena, &.{
                .{ "typeName", .{ .string = try arena.dupe(u8, value.type_name) } },
                .{ "data", .{ .string = try encodeBytes(arena, value.data) } },
            }));
        },
        .timestamp => |value| blk: {
            value.validate() catch return error.UnsupportedValue;
            break :blk tagged(arena, "timestampValue", try objectValue(arena, &.{
                .{ "seconds", try decimalString(arena, value.seconds) },
                .{ "nanos", .{ .integer = value.nanos } },
            }));
        },
        .duration => |value| tagged(arena, "durationValue", try decimalString(arena, value.nanoseconds)),
        .list => |values| blk: {
            var array = std.json.Array.init(arena);
            try array.ensureTotalCapacity(values.len);
            for (values) |value| array.appendAssumeCapacity(try encodeValue(arena, value, depth + 1));
            break :blk tagged(arena, "listValue", try objectValue(arena, &.{.{ "values", .{ .array = array } }}));
        },
        .map => |entries| blk: {
            cel.value.validateMapKeys(arena, entries) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidMapKey => error.UnsupportedValue,
                error.DuplicateKey => error.InvalidInput,
            };
            var array = std.json.Array.init(arena);
            try array.ensureTotalCapacity(entries.len);
            for (entries) |entry| array.appendAssumeCapacity(try objectValue(arena, &.{
                .{ "key", try encodeValue(arena, entry.key, depth + 1) },
                .{ "value", try encodeValue(arena, entry.value, depth + 1) },
            }));
            break :blk tagged(arena, "mapValue", try objectValue(arena, &.{.{ "entries", .{ .array = array } }}));
        },
    };
}

/// Decode one strict conformance static type into arena-owned CEL type metadata.
pub fn decodeType(arena: std.mem.Allocator, input: std.json.Value, depth: usize) Error!cel.Type {
    try enter(depth);
    const object = try expectObject(input);
    if (object.count() != 1) return error.InvalidInput;
    if (object.get("typeParam")) |raw| return .{ .kind = .parameter, .name = try arena.dupe(u8, try expectString(raw)) };
    if (object.get("abstractType")) |raw| {
        const item = try expectObject(raw);
        if (!hasOnly(item, &.{ "name", "parameterTypes" }) or item.get("name") == null) return error.InvalidInput;
        const parameters = if (item.get("parameterTypes")) |p| switch (p) {
            .array => |a| a.items,
            else => return error.InvalidInput,
        } else &.{};
        const decoded = try arena.alloc(cel.Type, parameters.len);
        for (parameters, decoded) |p, *out| out.* = try decodeType(arena, p, depth + 1);
        return .{ .kind = .abstract, .name = try arena.dupe(u8, try expectString(item.get("name").?)), .parameters = decoded };
    }
    if (object.get("primitive")) |raw| {
        return .{ .name = primitiveName(try expectString(raw)) orelse return error.UnsupportedValue };
    }
    if (object.get("wrapper")) |raw| {
        const parameter = primitiveName(try expectString(raw)) orelse return error.UnsupportedValue;
        const parameters = try arena.alloc(cel.Type, 1);
        parameters[0] = .{ .name = parameter };
        return .{ .name = "wrapper", .parameters = parameters };
    }
    if (object.get("wellKnown")) |raw| {
        const name = try expectString(raw);
        if (std.mem.eql(u8, name, "TIMESTAMP")) return .{ .name = "google.protobuf.Timestamp" };
        if (std.mem.eql(u8, name, "DURATION")) return .{ .name = "google.protobuf.Duration" };
        if (std.mem.eql(u8, name, "ANY")) return .{ .name = "dyn" };
        if (std.mem.eql(u8, name, "LIST_VALUE")) return typeWith(arena, "list", &.{.{ .name = "dyn" }});
        if (std.mem.eql(u8, name, "STRUCT")) return typeWith(arena, "map", &.{
            .{ .name = "string" }, .{ .name = "dyn" },
        });
        return error.UnsupportedValue;
    }
    if (object.get("dyn")) |raw| {
        if (!isEmptyObject(raw)) return error.InvalidInput;
        return .{ .name = "dyn" };
    }
    if (object.get("null")) |raw| {
        if (raw != .null) return error.InvalidInput;
        return .{ .name = "null_type" };
    }
    if (object.get("messageType")) |raw| return .{ .name = try arena.dupe(u8, try expectString(raw)) };
    if (object.get("listType")) |raw| {
        const item = try expectObject(raw);
        if (!hasExactly(item, &.{"elemType"})) return error.InvalidInput;
        return typeWith(arena, "list", &.{try decodeType(arena, item.get("elemType").?, depth + 1)});
    }
    if (object.get("mapType")) |raw| {
        const item = try expectObject(raw);
        if (!hasExactly(item, &.{ "keyType", "valueType" })) return error.InvalidInput;
        return typeWith(arena, "map", &.{
            try decodeType(arena, item.get("keyType").?, depth + 1),
            try decodeType(arena, item.get("valueType").?, depth + 1),
        });
    }
    if (object.get("type")) |raw| {
        if (isEmptyObject(raw)) return .{ .name = "type" };
        return typeWith(arena, "type", &.{try decodeType(arena, raw, depth + 1)});
    }
    return error.UnsupportedValue;
}

/// Encode one CEL static type exactly as the shared Node type transport.
pub fn encodeType(arena: std.mem.Allocator, input: cel.Type, depth: usize) Error!std.json.Value {
    try enter(depth);
    if (input.kind == .parameter) return tagged(arena, "typeParam", .{ .string = try arena.dupe(u8, input.name) });
    if (input.kind == .abstract) {
        var parameters = std.json.Array.init(arena);
        for (input.parameters) |p| try parameters.append(try encodeType(arena, p, depth + 1));
        return tagged(arena, "abstractType", try objectValue(arena, &.{
            .{ "name", .{ .string = try arena.dupe(u8, input.name) } },
            .{ "parameterTypes", .{ .array = parameters } },
        }));
    }
    if (primitiveTag(input.name)) |tag| {
        if (input.parameters.len != 0) return error.UnsupportedValue;
        return tagged(arena, "primitive", .{ .string = tag });
    }
    if (std.mem.eql(u8, input.name, "wrapper")) {
        if (input.parameters.len != 1 or input.parameters[0].parameters.len != 0) return error.UnsupportedValue;
        const tag = primitiveTag(input.parameters[0].name) orelse return error.UnsupportedValue;
        return tagged(arena, "wrapper", .{ .string = tag });
    }
    if (input.parameters.len == 0) {
        if (std.mem.eql(u8, input.name, "google.protobuf.Timestamp")) {
            return tagged(arena, "wellKnown", .{ .string = "TIMESTAMP" });
        }
        if (std.mem.eql(u8, input.name, "google.protobuf.Duration")) {
            return tagged(arena, "wellKnown", .{ .string = "DURATION" });
        }
        if (std.mem.eql(u8, input.name, "dyn")) return tagged(arena, "dyn", try objectValue(arena, &.{}));
        if (std.mem.eql(u8, input.name, "null_type")) return tagged(arena, "null", .null);
        if (std.mem.eql(u8, input.name, "type")) return tagged(arena, "type", try objectValue(arena, &.{}));
        if (std.mem.eql(u8, input.name, "list") or std.mem.eql(u8, input.name, "map")) {
            return error.UnsupportedValue;
        }
        return tagged(arena, "messageType", .{ .string = try arena.dupe(u8, input.name) });
    }
    if (std.mem.eql(u8, input.name, "list") and input.parameters.len == 1) return tagged(
        arena,
        "listType",
        try objectValue(arena, &.{.{ "elemType", try encodeType(arena, input.parameters[0], depth + 1) }}),
    );
    if (std.mem.eql(u8, input.name, "map") and input.parameters.len == 2) return tagged(
        arena,
        "mapType",
        try objectValue(arena, &.{
            .{ "keyType", try encodeType(arena, input.parameters[0], depth + 1) },
            .{ "valueType", try encodeType(arena, input.parameters[1], depth + 1) },
        }),
    );
    if (std.mem.eql(u8, input.name, "type") and input.parameters.len == 1) return tagged(
        arena,
        "type",
        try encodeType(arena, input.parameters[0], depth + 1),
    );
    return error.UnsupportedValue;
}

const JsonField = struct { []const u8, std.json.Value };

fn enter(depth: usize) Error!void {
    if (depth >= max_depth) return error.DepthLimitExceeded;
}

fn consumeValues(budget: *Budget, count: usize) Error!void {
    if (count > budget.remaining) return error.ValueLimitExceeded;
    budget.remaining -= count;
}

fn consumeBytes(budget: *Budget, count: usize) Error!void {
    if (count > budget.bytes) return error.ByteLimitExceeded;
    budget.bytes -= count;
}

fn expectObject(input: std.json.Value) Error!std.json.ObjectMap {
    return switch (input) {
        .object => |value| value,
        else => error.InvalidInput,
    };
}

fn expectString(input: std.json.Value) Error![]const u8 {
    return switch (input) {
        .string => |value| value,
        else => error.InvalidInput,
    };
}

fn hasExactly(object: std.json.ObjectMap, names: []const []const u8) bool {
    return object.count() == names.len and hasOnly(object, names);
}

fn hasOnly(object: std.json.ObjectMap, names: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (names) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return false;
    }
    return true;
}

fn isEmptyObject(input: std.json.Value) bool {
    return input == .object and input.object.count() == 0;
}

fn copyString(arena: std.mem.Allocator, input: std.json.Value, budget: *Budget) Error![]const u8 {
    const value = try expectString(input);
    try consumeBytes(budget, value.len);
    return arena.dupe(u8, value);
}

fn parseDecimal(comptime T: type, input: std.json.Value, signed: bool) Error!T {
    const text = try expectString(input);
    if (text.len == 0 or text.len > 20) return error.InvalidInput;
    const start: usize = if (signed and text[0] == '-') 1 else 0;
    if (start == text.len or (!signed and text[0] == '-')) return error.InvalidInput;
    if (text[start] == '0' and text.len - start != 1) return error.InvalidInput;
    for (text[start..]) |byte| if (byte < '0' or byte > '9') return error.InvalidInput;
    return std.fmt.parseInt(T, text, 10) catch return error.InvalidInput;
}

fn decodeDouble(input: std.json.Value) Error!f64 {
    return switch (input) {
        .integer => |value| @floatFromInt(value),
        .float => |value| if (std.math.isFinite(value)) value else error.InvalidInput,
        .number_string => |value| blk: {
            const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidInput;
            if (!std.math.isFinite(parsed)) return error.InvalidInput;
            break :blk parsed;
        },
        .string => |value| if (std.mem.eql(u8, value, "NaN")) std.math.nan(f64) else if (std.mem.eql(
            u8,
            value,
            "Infinity",
        )) std.math.inf(f64) else if (std.mem.eql(u8, value, "-Infinity")) -std.math.inf(f64) else error.InvalidInput,
        else => error.InvalidInput,
    };
}

fn decodeBytes(arena: std.mem.Allocator, input: std.json.Value, budget: *Budget) Error![]const u8 {
    const source = try expectString(input);
    const size = std.base64.standard.Decoder.calcSizeForSlice(source) catch return error.InvalidInput;
    try consumeBytes(budget, size);
    const output = try arena.alloc(u8, size);
    std.base64.standard.Decoder.decode(output, source) catch return error.InvalidInput;
    return output;
}

fn primitiveName(tag: []const u8) ?[]const u8 {
    const primitives = std.StaticStringMap([]const u8).initComptime(.{
        .{ "BOOL", "bool" },     .{ "INT64", "int" },     .{ "UINT64", "uint" },
        .{ "DOUBLE", "double" }, .{ "STRING", "string" }, .{ "BYTES", "bytes" },
    });
    return primitives.get(tag);
}

fn primitiveTag(name: []const u8) ?[]const u8 {
    const primitives = std.StaticStringMap([]const u8).initComptime(.{
        .{ "bool", "BOOL" },     .{ "int", "INT64" },     .{ "uint", "UINT64" },
        .{ "double", "DOUBLE" }, .{ "string", "STRING" }, .{ "bytes", "BYTES" },
    });
    return primitives.get(name);
}

fn typeWith(arena: std.mem.Allocator, name: []const u8, source: []const cel.Type) Error!cel.Type {
    const parameters = try arena.dupe(cel.Type, source);
    return .{ .name = name, .parameters = parameters };
}

fn tagged(arena: std.mem.Allocator, name: []const u8, value: std.json.Value) Error!std.json.Value {
    return objectValue(arena, &.{.{ name, value }});
}

fn objectValue(arena: std.mem.Allocator, fields: []const JsonField) Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.ensureTotalCapacity(arena, fields.len);
    for (fields) |field| object.putAssumeCapacityNoClobber(field[0], field[1]);
    return .{ .object = object };
}

fn decimalString(arena: std.mem.Allocator, value: anytype) Error!std.json.Value {
    return .{ .string = try std.fmt.allocPrint(arena, "{d}", .{value}) };
}

fn encodeDouble(value: f64) std.json.Value {
    if (std.math.isNan(value)) return .{ .string = "NaN" };
    if (value == std.math.inf(f64)) return .{ .string = "Infinity" };
    if (value == -std.math.inf(f64)) return .{ .string = "-Infinity" };
    return .{ .float = value };
}

fn encodeBytes(arena: std.mem.Allocator, source: []const u8) Error![]const u8 {
    const padded = std.math.add(usize, source.len, 2) catch return error.UnsupportedValue;
    const size = std.math.mul(usize, padded / 3, 4) catch return error.UnsupportedValue;
    const output = try arena.alloc(u8, size);
    return std.base64.standard.Encoder.encode(output, source);
}
