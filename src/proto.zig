//! Protobuf descriptors, reflection, and scoped native storage. The protobuf runtime owns its C++ allocations.

const std = @import("std");
const value = @import("value.zig");
const c = @cImport({
    @cInclude("protobuf.h");
});

/// Native immutable descriptor registry, shared by environment snapshots.
pub const Registry = c.CelProtoRegistry;
/// Native descriptor reference, valid for the lifetime of its registry.
pub const Descriptor = c.CelProtoDescriptor;
/// Native field descriptor reference.
pub const Field = c.CelProtoField;
/// Native evaluation-local message.
pub const NativeMessage = c.CelProtoMessage;
/// A scalar protobuf field kind.
pub const Kind = enum { bool, int, uint, double, string, bytes, message, enum_value };

/// Limits for descriptor loading and each evaluation's protobuf conversion work.
pub const Limits = struct {
    max_descriptor_bytes: usize = 1_048_576,
    max_files: usize = 256,
    max_message_bytes: usize = 1_048_576,
    max_total_bytes: usize = 8_388_608,
    max_depth: usize = 100,
    max_values: usize = 100_000,
};

/// Recoverable descriptor and message failures.
pub const Error = error{
    /// Native or Zig allocation failed.
    OutOfMemory,
    /// No registered message type has this name.
    UnsupportedType,
    /// A serialized message or field initializer is invalid.
    InvalidArgument,
    /// The selected protobuf field does not exist.
    NoSuchKey,
    /// A field value has an incompatible CEL type.
    NoMatchingOverload,
    /// A value cannot fit the protobuf field's numeric range.
    Overflow,
    /// Protobuf processing exceeds the configured resource limits.
    ProtobufLimitExceeded,
    /// Protobuf equality exhausts the evaluation's CEL step budget.
    CostLimitExceeded,
};

/// Load a FileDescriptorSet into an independently owned native registry.
pub fn load(data: []const u8, limits: Limits) error{ OutOfMemory, InvalidDescriptor, ProtobufLimitExceeded }!*Registry {
    if (data.len > limits.max_descriptor_bytes) return error.ProtobufLimitExceeded;
    const depth = std.math.cast(c_int, limits.max_depth) orelse return error.ProtobufLimitExceeded;
    var status: c_int = 0;
    const registry = c.cel_proto_registry(data.ptr, data.len, limits.max_files, depth, &status);
    switch (status) {
        c.CEL_P_OK => return registry.?,
        c.CEL_P_OOM => return error.OutOfMemory,
        c.CEL_P_LIMIT => return error.ProtobufLimitExceeded,
        else => return error.InvalidDescriptor,
    }
}

/// Retain a shared descriptor registry.
pub fn retain(registry: ?*Registry) void {
    c.cel_proto_retain(registry);
}
/// Release a shared descriptor registry.
pub fn release(registry: ?*Registry) void {
    c.cel_proto_release(registry);
}
/// Resolve an exact message name, including generated well-known descriptors.
pub fn descriptor(registry: ?*Registry, type_name: []const u8) error{OutOfMemory}!?*const Descriptor {
    var status: c_int = 0;
    const result = c.cel_proto_descriptor(registry, type_name.ptr, type_name.len, &status);
    if (status == c.CEL_P_OOM) return error.OutOfMemory;
    return result;
}
/// Resolve an exact protobuf enum name and borrow its canonical full name.
pub fn enumType(registry: ?*Registry, type_name: []const u8) error{OutOfMemory}!?[]const u8 {
    var size: usize = 0;
    var status: c_int = 0;
    const result = c.cel_proto_enum_type(registry, type_name.ptr, type_name.len, &size, &status);
    if (status == c.CEL_P_OOM) return error.OutOfMemory;
    return if (result != null) result[0..size] else null;
}
/// Resolve a protobuf enum constant, accepting protobuf sibling and CEL enum-qualified syntax.
pub fn enumValue(registry: ?*Registry, enum_name: []const u8) error{OutOfMemory}!?value.EnumValue {
    var number: i32 = 0;
    var size: usize = 0;
    var status: c_int = 0;
    const type_name = c.cel_proto_enum(registry, enum_name.ptr, enum_name.len, &number, &size, &status);
    if (status == c.CEL_P_OOM) return error.OutOfMemory;
    return if (type_name != null) .{ .type_name = type_name[0..size], .number = number } else null;
}
/// Convert an integer or exact symbol to a typed protobuf enum value.
pub fn convertEnum(registry: ?*Registry, type_name: []const u8, input: value.Value) Error!value.EnumValue {
    const canonical = try enumType(registry, type_name) orelse return error.InvalidArgument;
    if (input == .int) return .{
        .type_name = canonical,
        .number = std.math.cast(i32, input.int) orelse return error.Overflow,
    };
    if (input != .string) return error.NoMatchingOverload;
    var number: i32 = 0;
    var size: usize = 0;
    var status: c_int = 0;
    const result = c.cel_proto_enum_symbol(
        registry,
        canonical.ptr,
        canonical.len,
        input.string.ptr,
        input.string.len,
        &number,
        &size,
        &status,
    );
    if (status == c.CEL_P_OOM) return error.OutOfMemory;
    if (result == null) return error.InvalidArgument;
    return .{ .type_name = result[0..size], .number = number };
}
/// Borrow the full name of a descriptor.
pub fn name(desc: *const Descriptor) []const u8 {
    var len: usize = 0;
    const text = c.cel_proto_name(desc, &len);
    return text[0..len];
}
/// Resolve a field by its protobuf source name.
pub fn field(desc: *const Descriptor, field_name: []const u8) error{OutOfMemory}!?*const Field {
    var status: c_int = 0;
    const result = c.cel_proto_field(desc, field_name.ptr, field_name.len, &status);
    if (status == c.CEL_P_OOM) return error.OutOfMemory;
    return result;
}
/// Return the CEL scalar kind of a field.
pub fn kind(f: *const Field) Kind {
    return switch (c.cel_proto_field_kind(f)) {
        c.CEL_P_BOOL => .bool,
        c.CEL_P_INT => .int,
        c.CEL_P_UINT => .uint,
        c.CEL_P_DOUBLE => .double,
        c.CEL_P_STRING => .string,
        c.CEL_P_BYTES => .bytes,
        c.CEL_P_MESSAGE => .message,
        c.CEL_P_ENUM => .enum_value,
        else => unreachable,
    };
}
/// Whether the field is repeated.
pub fn repeated(f: *const Field) bool {
    return c.cel_proto_repeated(f) != 0;
}
/// Whether the field is a protobuf map.
pub fn isMap(f: *const Field) bool {
    return c.cel_proto_map(f) != 0;
}
/// Borrow the message descriptor of a message field.
pub fn fieldMessage(f: *const Field) *const Descriptor {
    return c.cel_proto_field_message(f).?;
}
/// Borrow the canonical type name of an enum field.
pub fn fieldEnum(f: *const Field) []const u8 {
    var size: usize = 0;
    const type_name = c.cel_proto_field_enum(f, &size);
    return type_name[0..size];
}
/// Borrow the key field of a protobuf map entry.
pub fn mapKey(f: *const Field) *const Field {
    return c.cel_proto_map_key(f).?;
}
/// Borrow the value field of a protobuf map entry.
pub fn mapValue(f: *const Field) *const Field {
    return c.cel_proto_map_value(f).?;
}

/// Evaluation-local protobuf arena. Values must be materialized before deinit.
pub const Scope = struct {
    native: ?*c.CelProtoScope = null,
    registry: ?*Registry,
    limits: Limits,
    strong_enums: bool = false,
    parsed: std.AutoHashMapUnmanaged(CacheKey, *const NativeMessage) = .empty,
    converted: usize = 0,

    const CacheKey = struct { descriptor: *const Descriptor, data: [*]const u8, size: usize };

    /// Release all decoded and constructed native messages.
    pub fn deinit(self: *Scope, arena: std.mem.Allocator) void {
        if (self.native) |native| c.cel_proto_scope_free(native);
        self.parsed.deinit(arena);
    }

    /// Decode a wire value at most once in this evaluation.
    pub fn message(self: *Scope, arena: std.mem.Allocator, input: *const value.Message) Error!*const NativeMessage {
        if (input.native) |native| return @ptrCast(@alignCast(native));
        const desc = try descriptor(self.registry, input.type_name) orelse return error.UnsupportedType;
        if (input.data.len > self.limits.max_message_bytes) return error.ProtobufLimitExceeded;
        const key = CacheKey{ .descriptor = desc, .data = input.data.ptr, .size = input.data.len };
        if (self.parsed.get(key)) |result| return result;
        var status: c_int = 0;
        const result = c.cel_proto_parse(try self.storage(), desc, input.data.ptr, input.data.len, &status);
        try check(status);
        try self.parsed.put(arena, key, result.?);
        return result.?;
    }

    /// Construct a message using descriptor-validated field assignments.
    pub fn construct(self: *Scope, arena: std.mem.Allocator, desc: *const Descriptor, fields: []const *const Field, values: []const value.Value) Error!value.Value {
        const inputs = try arena.alloc(c.CelProtoValue, values.len);
        for (values, inputs) |v, *out| out.* = try self.toNative(arena, v, 0);
        var status: c_int = 0;
        const result = c.cel_proto_construct(try self.storage(), desc, fields.ptr, inputs.ptr, inputs.len, &status);
        try check(status);
        var adapted: c.CelProtoValue = undefined;
        try check(c.cel_proto_adapt(try self.storage(), result.?, &adapted));
        return self.fromNative(arena, adapted, 0);
    }

    /// Apply CEL's well-known-type mapping to a message value.
    pub fn adapt(self: *Scope, arena: std.mem.Allocator, input: *const value.Message) Error!value.Value {
        var adapted: c.CelProtoValue = undefined;
        try check(c.cel_proto_adapt(try self.storage(), try self.message(arena, input), &adapted));
        return self.fromNative(arena, adapted, 0);
    }

    /// Read a scalar, collection, or nested message field.
    pub fn get(self: *Scope, arena: std.mem.Allocator, input: *const value.Message, f: *const Field) Error!value.Value {
        var result: c.CelProtoValue = undefined;
        try check(c.cel_proto_get(try self.storage(), try self.message(arena, input), f, &result));
        return self.fromNative(arena, result, 0);
    }

    /// Test protobuf presence, including nonempty repeated and map fields.
    pub fn has(self: *Scope, arena: std.mem.Allocator, input: *const value.Message, f: *const Field) Error!bool {
        var result: c_int = 0;
        try check(c.cel_proto_has(try self.message(arena, input), f, &result));
        return result != 0;
    }

    /// Compare messages through protobuf's semantic equality, charging the shared CEL step budget.
    pub fn equal(
        self: *Scope,
        arena: std.mem.Allocator,
        a: *const value.Message,
        b: *const value.Message,
        remaining: *usize,
    ) Error!bool {
        if (!std.mem.eql(u8, a.type_name, b.type_name)) return false;
        var result: c_int = 0;
        try check(c.cel_proto_equal(
            try self.storage(),
            try self.message(arena, a),
            try self.message(arena, b),
            remaining,
            &result,
        ));
        return result != 0;
    }

    /// Serialize a result into Zig arena storage, removing the native handle.
    pub fn materialize(self: *Scope, arena: std.mem.Allocator, input: *const value.Message) Error!value.Message {
        const msg = try self.message(arena, input);
        var size: usize = 0;
        var status: c_int = 0;
        const data = c.cel_proto_serialize(try self.storage(), msg, &size, &status);
        try check(status);
        return .{ .type_name = try arena.dupe(u8, input.type_name), .data = try arena.dupe(u8, if (size == 0) "" else data[0..size]) };
    }

    fn storage(self: *Scope) Error!*c.CelProtoScope {
        if (self.native) |native| return native;
        if (self.limits.max_message_bytes > std.math.maxInt(c_int)) return error.ProtobufLimitExceeded;
        const depth = std.math.cast(c_int, self.limits.max_depth) orelse return error.ProtobufLimitExceeded;
        var status: c_int = 0;
        self.native = c.cel_proto_scope(
            self.registry,
            self.limits.max_message_bytes,
            self.limits.max_total_bytes,
            depth,
            self.limits.max_values,
            @intFromBool(self.strong_enums),
            &status,
        );
        try check(status);
        return self.native.?;
    }

    fn toNative(self: *Scope, arena: std.mem.Allocator, input: value.Value, depth: usize) Error!c.CelProtoValue {
        if (depth >= self.limits.max_depth or self.converted >= self.limits.max_values) return error.ProtobufLimitExceeded;
        self.converted += 1;
        var out = std.mem.zeroes(c.CelProtoValue);
        switch (input) {
            .null => out.kind = c.CEL_P_NULL,
            .bool => |v| {
                out.kind = c.CEL_P_BOOL;
                out.number.integer = @intFromBool(v);
            },
            .int => |v| {
                out.kind = c.CEL_P_INT;
                out.number.integer = v;
            },
            .uint => |v| {
                out.kind = c.CEL_P_UINT;
                out.number.unsigned_integer = v;
            },
            .double => |v| {
                out.kind = c.CEL_P_DOUBLE;
                out.number.real = v;
            },
            .string, .bytes => {
                const bytes = if (input == .string) input.string else input.bytes;
                if (bytes.len > self.limits.max_message_bytes) return error.ProtobufLimitExceeded;
                out.kind = if (input == .string) c.CEL_P_STRING else c.CEL_P_BYTES;
                out.data = bytes.ptr;
                out.size = bytes.len;
            },
            .timestamp => |v| {
                try v.validate();
                out.kind = c.CEL_P_TIMESTAMP;
                out.number.integer = v.seconds;
                out.size = v.nanos;
            },
            .duration => |v| {
                out.kind = c.CEL_P_DURATION;
                out.number.integer = v.nanoseconds;
            },
            .enum_value => |v| {
                out.kind = c.CEL_P_ENUM;
                out.number.integer = v.number;
                out.data = v.type_name.ptr;
                out.size = v.type_name.len;
            },
            .message => |v| {
                out.kind = c.CEL_P_MESSAGE;
                out.message = try self.message(arena, v);
            },
            .list => |items| {
                if (items.len > self.limits.max_values) return error.ProtobufLimitExceeded;
                const converted = try arena.alloc(c.CelProtoValue, items.len);
                for (items, converted) |item, *slot| slot.* = try self.toNative(arena, item, depth + 1);
                out.kind = c.CEL_P_LIST;
                out.items = converted.ptr;
                out.count = items.len;
            },
            .map => |entries| {
                if (entries.len > self.limits.max_values / 2) return error.ProtobufLimitExceeded;
                const converted = try arena.alloc(c.CelProtoValue, entries.len * 2);
                for (entries, 0..) |entry, i| {
                    converted[i * 2] = try self.toNative(arena, entry.key, depth + 1);
                    converted[i * 2 + 1] = try self.toNative(arena, entry.value, depth + 1);
                }
                out.kind = c.CEL_P_MAP;
                out.items = converted.ptr;
                out.count = entries.len;
            },
            .type_value, .optional, .ip, .cidr => return error.NoMatchingOverload,
        }
        return out;
    }

    fn fromNative(self: *Scope, arena: std.mem.Allocator, input: c.CelProtoValue, depth: usize) Error!value.Value {
        if (depth >= self.limits.max_depth) return error.ProtobufLimitExceeded;
        return switch (input.kind) {
            c.CEL_P_NULL => .null,
            c.CEL_P_BOOL => .{ .bool = input.number.integer != 0 },
            c.CEL_P_INT => .{ .int = input.number.integer },
            c.CEL_P_UINT => .{ .uint = input.number.unsigned_integer },
            c.CEL_P_DOUBLE => .{ .double = input.number.real },
            c.CEL_P_STRING, c.CEL_P_BYTES => blk: {
                const bytes = try arena.dupe(u8, if (input.size == 0) "" else input.data[0..input.size]);
                break :blk if (input.kind == c.CEL_P_STRING) .{ .string = bytes } else .{ .bytes = bytes };
            },
            c.CEL_P_TIMESTAMP => .{ .timestamp = .{ .seconds = input.number.integer, .nanos = @intCast(input.size) } },
            c.CEL_P_DURATION => .{ .duration = .{ .nanoseconds = input.number.integer } },
            c.CEL_P_ENUM => if (self.strong_enums)
                try value.Value.fromEnum(arena, .{
                    .type_name = input.data[0..input.size],
                    .number = @intCast(input.number.integer),
                })
            else
                .{ .int = input.number.integer },
            c.CEL_P_MESSAGE => try value.Value.fromMessage(arena, .{
                .type_name = name(c.cel_proto_message_descriptor(input.message).?),
                .native = input.message,
            }),
            c.CEL_P_LIST => blk: {
                const items = try arena.alloc(value.Value, input.count);
                for (items, 0..) |*out, i| out.* = try self.fromNative(arena, input.items[i], depth + 1);
                break :blk .{ .list = items };
            },
            c.CEL_P_MAP => blk: {
                const entries = try arena.alloc(value.Entry, input.count);
                for (entries, 0..) |*out, i| out.* = .{
                    .key = try self.fromNative(arena, input.items[i * 2], depth + 1),
                    .value = try self.fromNative(arena, input.items[i * 2 + 1], depth + 1),
                };
                break :blk .{ .map = entries };
            },
            else => unreachable,
        };
    }
};

fn check(status: c_int) Error!void {
    return switch (status) {
        c.CEL_P_OK => {},
        c.CEL_P_UNKNOWN_TYPE => error.UnsupportedType,
        c.CEL_P_INVALID => error.InvalidArgument,
        c.CEL_P_FIELD => error.NoSuchKey,
        c.CEL_P_TYPE => error.NoMatchingOverload,
        c.CEL_P_OVERFLOW => error.Overflow,
        c.CEL_P_OOM => error.OutOfMemory,
        c.CEL_P_LIMIT => error.ProtobufLimitExceeded,
        c.CEL_P_COST => error.CostLimitExceeded,
        else => unreachable,
    };
}
