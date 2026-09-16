//! Typed function overload declarations. Names and types are copied; callback contexts remain caller-owned.

const std = @import("std");
const types = @import("types.zig");
const values = @import("value.zig");
const errors = @import("errors.zig");
const proto = @import("proto.zig");

/// One named overload of a global or receiver-style CEL function.
pub const Function = struct {
    name: []const u8,
    parameters: []const types.Type,
    result: types.Type,
    /// Empty IDs default to the function name and must still be unique in an environment.
    overload_id: []const u8 = "",
    /// Receiver-style signatures include their receiver as the first parameter.
    member: bool = false,
    /// Null implementations permit checking without supplying runtime host code.
    implementation: ?*const fn (?*anyopaque, std.mem.Allocator, []const values.Value) errors.EvalError!values.Value = null,
    /// Borrowed by every compiled program. Keep this alive until those programs are destroyed.
    context: ?*anyopaque = null,
};

/// Check overlap after erasing named type variables, charging declaration work.
pub fn typesOverlap(left: types.Type, right: types.Type, registry: ?*proto.Registry, remaining: *usize) error{ OutOfMemory, DeclarationLimitExceeded }!bool {
    if (remaining.* == 0) return error.DeclarationLimitExceeded;
    remaining.* -= 1;
    if (left.kind == .parameter or right.kind == .parameter) return true;
    const a = canonical(left);
    const b = canonical(right);
    if ((a.kind == .concrete and std.mem.eql(u8, a.name, "dyn")) or
        (b.kind == .concrete and std.mem.eql(u8, b.name, "dyn"))) return true;
    const a_nullable = a.kind == .abstract or std.mem.eql(u8, a.name, "null_type") or
        std.mem.eql(u8, a.name, "wrapper") or try proto.descriptor(registry, a.name) != null;
    const b_nullable = b.kind == .abstract or std.mem.eql(u8, b.name, "null_type") or
        std.mem.eql(u8, b.name, "wrapper") or try proto.descriptor(registry, b.name) != null;
    if (a_nullable and b_nullable) return true;
    if (a.kind != b.kind) return false;
    if (a.kind == .concrete) {
        if (std.mem.eql(u8, a.name, "wrapper")) return typesOverlap(a.parameters[0], b, registry, remaining);
        if (std.mem.eql(u8, b.name, "wrapper")) return typesOverlap(a, b.parameters[0], registry, remaining);
        if (std.mem.eql(u8, a.name, "type") and std.mem.eql(u8, b.name, "type") and
            (a.parameters.len == 0 or b.parameters.len == 0)) return true;
    }
    if (!std.mem.eql(u8, a.name, b.name) or a.parameters.len != b.parameters.len) return false;
    for (a.parameters, b.parameters) |x, y| if (!try typesOverlap(x, y, registry, remaining)) return false;
    return true;
}

fn canonical(t: types.Type) types.Type {
    if (t.kind != .concrete) return t;
    const mappings = std.StaticStringMap(types.Type).initComptime(.{
        .{ "google.protobuf.Any", types.Type{ .name = "dyn" } },
        .{ "google.protobuf.Value", types.Type{ .name = "dyn" } },
        .{ "google.protobuf.Struct", types.Type{ .name = "map", .parameters = &.{ .{ .name = "string" }, .{ .name = "dyn" } } } },
        .{ "google.protobuf.ListValue", types.Type{ .name = "list", .parameters = &.{.{ .name = "dyn" }} } },
        .{ "google.protobuf.Int32Value", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "int" }} } },
        .{ "google.protobuf.Int64Value", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "int" }} } },
        .{ "google.protobuf.UInt32Value", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "uint" }} } },
        .{ "google.protobuf.UInt64Value", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "uint" }} } },
        .{ "google.protobuf.FloatValue", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "double" }} } },
        .{ "google.protobuf.DoubleValue", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "double" }} } },
        .{ "google.protobuf.BoolValue", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "bool" }} } },
        .{ "google.protobuf.StringValue", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "string" }} } },
        .{ "google.protobuf.BytesValue", types.Type{ .name = "wrapper", .parameters = &.{.{ .name = "bytes" }} } },
    });
    return mappings.get(t.name) orelse t;
}
