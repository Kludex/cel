//! Static CEL type descriptions and owned declaration data. Runtime type() values remain unparameterized.

const std = @import("std");
const value = @import("value.zig");
const proto = @import("proto.zig");
const names = @import("names.zig");

/// A static CEL type. List, map, and type descriptions may carry type parameters.
pub const Type = struct {
    /// The role of a type in a declaration.
    pub const Kind = enum {
        /// A primitive, container, wrapper, or registered protobuf type.
        concrete,
        /// A named variable instantiated for one function signature.
        parameter,
        /// A nominal extension type used during checking.
        abstract,
    };

    name: []const u8,
    parameters: []const Type = &.{},
    kind: Kind = .concrete,

    /// Compare static types, including their parameters.
    pub fn eql(self: Type, other: Type) bool {
        if (self.kind != other.kind or !std.mem.eql(u8, self.name, other.name) or
            self.parameters.len != other.parameters.len) return false;
        for (self.parameters, other.parameters) |a, b| if (!a.eql(b)) return false;
        return true;
    }

    /// Copy and validate a declaration type into an arena.
    pub fn clone(self: Type, arena: std.mem.Allocator, depth: usize, remaining: *usize, registry: ?*proto.Registry) error{
        /// Allocation failed.
        OutOfMemory,
        /// The declaration uses a type not yet supported by this checker.
        UnsupportedType,
        /// The number of parameters does not match the type constructor.
        InvalidDeclaration,
        /// The declaration exceeds its nesting budget.
        DepthLimitExceeded,
        /// Declaration metadata exceeds its work or byte budget.
        DeclarationLimitExceeded,
    }!Type {
        if (depth == 0) return error.DepthLimitExceeded;
        if (self.name.len >= remaining.*) return error.DeclarationLimitExceeded;
        remaining.* -= self.name.len + 1;
        if (self.kind == .parameter) {
            if (!names.valid(self.name, false) or std.mem.indexOfScalar(u8, self.name, '.') != null or
                self.parameters.len != 0) return error.InvalidDeclaration;
            return .{ .name = try arena.dupe(u8, self.name), .kind = .parameter };
        }
        if (self.kind == .abstract) {
            if ((std.mem.eql(u8, self.name, "net.IP") or std.mem.eql(u8, self.name, "net.CIDR")) and
                self.parameters.len != 0) return error.InvalidDeclaration;
            if (std.mem.eql(u8, self.name, "optional_type")) {
                if (self.parameters.len > 1) return error.InvalidDeclaration;
                const parameter = try arena.alloc(Type, 1);
                parameter[0] = if (self.parameters.len == 0) .{ .name = "dyn" } else try self.parameters[0].clone(arena, depth - 1, remaining, registry);
                return .{ .kind = .abstract, .name = "optional_type", .parameters = parameter };
            }
            if (!names.valid(self.name, false)) return error.InvalidDeclaration;
            if (self.parameters.len > remaining.*) return error.DeclarationLimitExceeded;
            const parameters = try arena.alloc(Type, self.parameters.len);
            for (self.parameters, parameters) |parameter, *output| {
                output.* = try parameter.clone(arena, depth - 1, remaining, registry);
            }
            return .{ .name = try arena.dupe(u8, self.name), .parameters = parameters, .kind = .abstract };
        }
        const arity: usize = if (std.mem.eql(u8, self.name, "list") or std.mem.eql(u8, self.name, "type") or
            std.mem.eql(u8, self.name, "wrapper")) 1 else if (std.mem.eql(u8, self.name, "map")) 2 else 0;
        if (arity == 0) {
            const primitives = std.StaticStringMap(void).initComptime(.{
                .{"dyn"}, .{"bool"}, .{"bytes"}, .{"double"}, .{"int"}, .{"null_type"}, .{"string"}, .{"uint"},
            });
            if (!primitives.has(self.name) and try proto.descriptor(registry, self.name) == null and
                try proto.enumType(registry, self.name) == null) return error.UnsupportedType;
        }
        if (self.parameters.len != 0 and self.parameters.len != arity) return error.InvalidDeclaration;
        const count = if (std.mem.eql(u8, self.name, "type") and self.parameters.len == 0) 0 else arity;
        const parameters = try arena.alloc(Type, count);
        for (parameters, 0..) |*parameter, i| {
            parameter.* = if (self.parameters.len == 0) .{ .name = "dyn" } else try self.parameters[i].clone(arena, depth - 1, remaining, registry);
        }
        return .{ .name = try arena.dupe(u8, self.name), .parameters = parameters };
    }
};

/// A variable name and the type required by a checked expression.
pub const Declaration = struct { name: []const u8, type: Type };

/// Copy constant values while bounding nesting, aggregate work, and byte storage.
pub fn cloneValue(arena: std.mem.Allocator, input: value.Value, depth: usize, remaining: *usize, registry: ?*proto.Registry) error{
    /// Allocation failed.
    OutOfMemory,
    /// Constant data exceeds its work or byte budget.
    DeclarationLimitExceeded,
    /// Constant data exceeds its nesting budget.
    DepthLimitExceeded,
    /// A constant contains an invalid key, duplicate key, or non-enum nominal type.
    InvalidDeclaration,
}!value.Value {
    if (depth == 0) return error.DepthLimitExceeded;
    if (remaining.* == 0) return error.DeclarationLimitExceeded;
    remaining.* -= 1;
    return switch (input) {
        .string, .bytes, .type_value => blk: {
            const bytes = switch (input) {
                .string => input.string,
                .bytes => input.bytes,
                else => input.type_value,
            };
            if (bytes.len > remaining.*) return error.DeclarationLimitExceeded;
            remaining.* -= bytes.len;
            const owned = try arena.dupe(u8, bytes);
            break :blk switch (input) {
                .string => .{ .string = owned },
                .bytes => .{ .bytes = owned },
                else => .{ .type_value = owned },
            };
        },
        .ip => |address| blk: {
            address.validate() catch return error.InvalidDeclaration;
            break :blk try value.Value.fromIP(arena, address.*);
        },
        .cidr => |prefix| blk: {
            prefix.validate() catch return error.InvalidDeclaration;
            break :blk try value.Value.fromCIDR(arena, prefix.*);
        },
        .enum_value => |item| blk: {
            if (item.type_name.len > remaining.*) return error.DeclarationLimitExceeded;
            remaining.* -= item.type_name.len;
            if (!names.valid(item.type_name, false)) return error.InvalidDeclaration;
            if (try proto.enumType(registry, item.type_name) == null) return error.InvalidDeclaration;
            break :blk try value.Value.fromEnum(arena, .{
                .type_name = try arena.dupe(u8, item.type_name),
                .number = item.number,
            });
        },
        .optional => |present| try value.Value.fromOptional(arena, if (present) |item|
            try cloneValue(arena, item.*, depth - 1, remaining, registry)
        else
            null),
        .timestamp => |time| blk: {
            time.validate() catch return error.InvalidDeclaration;
            break :blk input;
        },
        .message => |message| blk: {
            if (message.native != null) return error.InvalidDeclaration;
            const bytes = std.math.add(usize, message.type_name.len, message.data.len) catch return error.DeclarationLimitExceeded;
            if (bytes > remaining.*) return error.DeclarationLimitExceeded;
            remaining.* -= bytes;
            break :blk try value.Value.fromMessage(arena, .{ .type_name = try arena.dupe(u8, message.type_name), .data = try arena.dupe(u8, message.data) });
        },
        .list => |items| blk: {
            if (items.len > remaining.*) return error.DeclarationLimitExceeded;
            const copy = try arena.alloc(value.Value, items.len);
            for (items, copy) |item, *out| out.* = try cloneValue(arena, item, depth - 1, remaining, registry);
            break :blk .{ .list = copy };
        },
        .map => |items| blk: {
            if (items.len > remaining.* / 2) return error.DeclarationLimitExceeded;
            const copy = try arena.alloc(value.Entry, items.len);
            for (items, copy) |item, *out| {
                switch (item.key) {
                    .bool, .int, .uint, .string => {},
                    else => return error.InvalidDeclaration,
                }
                out.* = .{ .key = try cloneValue(arena, item.key, depth - 1, remaining, registry), .value = try cloneValue(arena, item.value, depth - 1, remaining, registry) };
            }
            value.validateMapKeys(arena, copy) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidMapKey, error.DuplicateKey => error.InvalidDeclaration,
            };
            break :blk .{ .map = copy };
        },
        else => input,
    };
}
