//! CEL values with borrowed storage. Metadata and map validation use caller-supplied allocators.

const std = @import("std");
const temporal = @import("temporal.zig");
const network = @import("network.zig");

/// A CEL value. Collection and string storage must outlive every evaluation that borrows it.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    uint: u64,
    double: f64,
    string: []const u8,
    bytes: []const u8,
    type_value: []const u8,
    list: []const Value,
    map: []const Entry,
    message: *const Message,
    timestamp: temporal.Timestamp,
    duration: temporal.Duration,
    enum_value: *const EnumValue,
    optional: ?*const Value,
    ip: *const network.IP,
    cidr: *const network.CIDR,

    /// Copy a validated network address into caller-owned arena storage.
    pub fn fromIP(arena: std.mem.Allocator, address: network.IP) std.mem.Allocator.Error!Value {
        const owned = try arena.create(network.IP);
        owned.* = address;
        return .{ .ip = owned };
    }

    /// Copy a validated network prefix, preserving host bits.
    pub fn fromCIDR(arena: std.mem.Allocator, prefix: network.CIDR) std.mem.Allocator.Error!Value {
        const owned = try arena.create(network.CIDR);
        owned.* = prefix;
        return .{ .cidr = owned };
    }

    /// Wrap a present value in arena-owned metadata, or return an absent optional.
    pub fn fromOptional(arena: std.mem.Allocator, input: ?Value) std.mem.Allocator.Error!Value {
        const value = input orelse return .{ .optional = null };
        const payload = try arena.create(Value);
        payload.* = value;
        return .{ .optional = payload };
    }

    /// Allocate enum metadata, borrowing its fully qualified type name.
    pub fn fromEnum(arena: std.mem.Allocator, enum_value: EnumValue) std.mem.Allocator.Error!Value {
        const allocated = try arena.create(EnumValue);
        allocated.* = enum_value;
        return .{ .enum_value = allocated };
    }

    /// Allocate message metadata, borrowing its name and wire storage.
    pub fn fromMessage(arena: std.mem.Allocator, message_value: Message) std.mem.Allocator.Error!Value {
        const allocated = try arena.create(Message);
        allocated.* = message_value;
        return .{ .message = allocated };
    }

    /// Compare scalar/collection values; messages compare wire identity without a descriptor context.
    pub fn eql(a: Value, b: Value) bool {
        if (a.numeric() and b.numeric()) return a.order(b) == .eq;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .bool => |v| v == b.bool,
            .int, .uint, .double => unreachable,
            .string => |v| std.mem.eql(u8, v, b.string),
            .bytes => |v| std.mem.eql(u8, v, b.bytes),
            .type_value => |v| std.mem.eql(u8, v, b.type_value),
            .timestamp => |v| v.seconds == b.timestamp.seconds and v.nanos == b.timestamp.nanos,
            .duration => |v| v.nanoseconds == b.duration.nanoseconds,
            .ip => |v| v.eql(b.ip.*),
            .cidr => |v| v.eql(b.cidr.*),
            .optional => |v| if (v) |present| if (b.optional) |other| present.eql(other.*) else false else b.optional == null,
            .enum_value => |v| v.number == b.enum_value.number and std.mem.eql(u8, v.type_name, b.enum_value.type_name),
            .message => |v| std.mem.eql(u8, v.type_name, b.message.type_name) and std.mem.eql(u8, v.data, b.message.data),
            .list => |v| blk: {
                if (v.len != b.list.len) break :blk false;
                for (v, b.list) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            .map => |v| blk: {
                if (v.len != b.map.len) break :blk false;
                for (v) |entry| {
                    const other = b.get(entry.key) orelse break :blk false;
                    if (!entry.value.eql(other)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Look up a map key; returns null for an absent key or a non-map value.
    pub fn get(self: Value, key: Value) ?Value {
        if (self != .map) return null;
        for (self.map) |entry| if (entry.key.eql(key)) return entry.value;
        return null;
    }

    /// Whether the value has a numeric type.
    pub fn numeric(self: Value) bool {
        return switch (self) {
            .int, .uint, .double => true,
            else => false,
        };
    }

    /// Compare numeric values exactly. Returns null for NaN or nonnumeric inputs.
    /// Order two numeric values the way CEL-Go and CEL-C++ do: a double is clamped against the integer
    /// range, then compared in double space, so integers beyond 2^53 round. NaN orders with nothing.
    pub fn order(a: Value, b: Value) ?std.math.Order {
        return switch (a) {
            .int => |x| switch (b) {
                .int => |y| std.math.order(x, y),
                .uint => |y| if (x < 0) .lt else std.math.order(@as(u64, @intCast(x)), y),
                .double => |y| invert(orderDoubleInt(y, x)),
                else => null,
            },
            .uint => |x| switch (b) {
                .int => |y| if (y < 0) .gt else std.math.order(x, @as(u64, @intCast(y))),
                .uint => |y| std.math.order(x, y),
                .double => |y| invert(orderDoubleUint(y, x)),
                else => null,
            },
            .double => |x| switch (b) {
                .int => |y| orderDoubleInt(x, y),
                .uint => |y| orderDoubleUint(x, y),
                .double => |y| orderDouble(x, y),
                else => null,
            },
            else => null,
        };
    }

    fn orderDouble(x: f64, y: f64) ?std.math.Order {
        if (std.math.isNan(x) or std.math.isNan(y)) return null;
        return std.math.order(x, y);
    }

    fn orderDoubleInt(x: f64, y: i64) ?std.math.Order {
        if (std.math.isNan(x)) return null;
        if (x < @as(f64, @floatFromInt(std.math.minInt(i64)))) return .lt;
        if (x > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return .gt;
        return std.math.order(x, @as(f64, @floatFromInt(y)));
    }

    fn orderDoubleUint(x: f64, y: u64) ?std.math.Order {
        if (std.math.isNan(x)) return null;
        if (x < 0) return .lt;
        if (x > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return .gt;
        return std.math.order(x, @as(f64, @floatFromInt(y)));
    }

    fn invert(order_or_nan: ?std.math.Order) ?std.math.Order {
        return if (order_or_nan) |o| o.invert() else null;
    }
};

/// A distinct protobuf enum value, including unnamed signed 32-bit numbers.
pub const EnumValue = struct {
    type_name: []const u8,
    number: i32,
};

/// A protobuf wire value. Returned wire data borrows the caller's evaluation arena.
pub const Message = struct {
    type_name: []const u8,
    data: []const u8 = "",
    /// Reserved for evaluation-local handles; callers leave this null and results never expose it.
    native: ?*const anyopaque = null,
};

/// One map entry. CEL keys are bool, int, uint, or string.
pub const Entry = struct { key: Value, value: Value };

/// One named input in an evaluation activation.
pub const Binding = struct { name: []const u8, value: Value };

/// Validate map key types and uniqueness using CEL equality and temporary hash storage.
pub fn validateMapKeys(arena: std.mem.Allocator, entries: []const Entry) error{
    /// Temporary allocation failed.
    OutOfMemory,
    /// A key is not bool, int, uint, or string.
    InvalidMapKey,
    /// Two keys are equal under CEL numeric and scalar equality.
    DuplicateKey,
}!void {
    var keys: std.HashMapUnmanaged(Value, void, MapKeyContext, 80) = .empty;
    defer keys.deinit(arena);
    for (entries) |entry| {
        switch (entry.key) {
            .bool, .int, .uint, .string => {},
            else => return error.InvalidMapKey,
        }
        if ((try keys.getOrPut(arena, entry.key)).found_existing) return error.DuplicateKey;
    }
}

const MapKeyContext = struct {
    /// Hash supported keys so equal signed and unsigned integers share a hash.
    pub fn hash(_: MapKeyContext, key: Value) u64 {
        return switch (key) {
            .bool => |v| @intFromBool(v),
            .int => |v| std.hash.Wyhash.hash(0, std.mem.asBytes(&v)),
            .uint => |v| std.hash.Wyhash.hash(0, std.mem.asBytes(&v)),
            .string => |v| std.hash.Wyhash.hash(1, v),
            else => unreachable,
        };
    }

    /// Compare map keys under CEL scalar equality.
    pub fn eql(_: MapKeyContext, a: Value, b: Value) bool {
        return a.eql(b);
    }
};
