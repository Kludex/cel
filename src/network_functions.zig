//! Network extension dispatch shared by checked and unchecked programs.

const std = @import("std");
const network = @import("network.zig");
const Value = @import("value.zig").Value;
const Type = @import("types.zig").Type;
const EvalError = @import("errors.zig").EvalError;

/// The network library's constructor and receiver operations.
pub const Operation = enum {
    ip,
    cidr,
    isIP,
    isCIDR,
    isCanonical,
    family,
    isUnspecified,
    isLoopback,
    isGlobalUnicast,
    isLinkLocalMulticast,
    isLinkLocalUnicast,
    address,
    prefixLength,
    masked,
    containsIP,
    containsCIDR,
};

/// Resolve a global function independently of variable bindings.
pub fn function(name: []const u8, container: []const u8) ?Operation {
    const absolute = std.mem.startsWith(u8, name, ".");
    const local = if (absolute) name[1..] else name;
    if (std.mem.eql(u8, local, "ip.isCanonical") or (!absolute and std.mem.eql(u8, local, "isCanonical") and
        (std.mem.eql(u8, container, "ip") or std.mem.startsWith(u8, container, "ip.")))) return .isCanonical;
    return std.StaticStringMap(Operation).initComptime(.{
        .{ "ip", .ip }, .{ "cidr", .cidr }, .{ "isIP", .isIP }, .{ "isCIDR", .isCIDR },
    }).get(local);
}

/// Resolve a receiver operation by its unqualified method name.
pub fn method(name: []const u8) ?Operation {
    return std.StaticStringMap(Operation).initComptime(.{
        .{ "family", .family },
        .{ "isUnspecified", .isUnspecified },
        .{ "isLoopback", .isLoopback },
        .{ "isGlobalUnicast", .isGlobalUnicast },
        .{ "isLinkLocalMulticast", .isLinkLocalMulticast },
        .{ "isLinkLocalUnicast", .isLinkLocalUnicast },
        .{ "ip", .address },
        .{ "prefixLength", .prefixLength },
        .{ "masked", .masked },
        .{ "containsIP", .containsIP },
        .{ "containsCIDR", .containsCIDR },
    }).get(name);
}

/// Describe nominal parameters and results; containment also accepts string operands.
pub fn signature(op: Operation) struct { parameters: []const Type, result: Type } {
    const ip_type: Type = .{ .name = "net.IP", .kind = .abstract };
    const cidr_type: Type = .{ .name = "net.CIDR", .kind = .abstract };
    return .{
        .parameters = switch (op) {
            .ip, .cidr, .isIP, .isCIDR, .isCanonical => &.{.{ .name = "string" }},
            .family,
            .isUnspecified,
            .isLoopback,
            .isGlobalUnicast,
            .isLinkLocalMulticast,
            .isLinkLocalUnicast,
            => &.{ip_type},
            .address, .prefixLength, .masked => &.{cidr_type},
            .containsIP => &.{ cidr_type, ip_type },
            .containsCIDR => &.{ cidr_type, cidr_type },
        },
        .result = switch (op) {
            .ip, .address => ip_type,
            .cidr, .masked => cidr_type,
            .family, .prefixLength => .{ .name = "int" },
            else => .{ .name = "bool" },
        },
    };
}

/// Evaluate validated arguments with request-owned results and bounded parsing work.
pub fn evaluate(arena: std.mem.Allocator, op: Operation, args: []const Value, remaining: *usize) EvalError!Value {
    const parameters = signature(op).parameters;
    if (args.len != parameters.len) return error.NoMatchingOverload;
    for (args, parameters, 0..) |arg, parameter, i| {
        const actual: []const u8 = switch (arg) {
            .string => "string",
            .ip => "net.IP",
            .cidr => "net.CIDR",
            else => "",
        };
        if (!std.mem.eql(u8, actual, parameter.name) and
            !(i == 1 and (op == .containsIP or op == .containsCIDR) and arg == .string))
            return error.NoMatchingOverload;
        const cost: usize = if (arg == .string) arg.string.len else 16;
        if (cost > remaining.*) return error.CostLimitExceeded;
        remaining.* -= cost;
    }
    return switch (op) {
        .ip => Value.fromIP(arena, try network.IP.parse(args[0].string)),
        .cidr => Value.fromCIDR(arena, try network.CIDR.parse(args[0].string)),
        .isIP => .{ .bool = if (network.IP.parse(args[0].string)) |_| true else |_| false },
        .isCIDR => .{ .bool = if (network.CIDR.parse(args[0].string)) |_| true else |_| false },
        .isCanonical => blk: {
            const address = try network.IP.parse(args[0].string);
            break :blk .{ .bool = std.mem.eql(u8, args[0].string, try address.format(arena)) };
        },
        .family => .{ .int = args[0].ip.family },
        .isUnspecified => .{ .bool = args[0].ip.isUnspecified() },
        .isLoopback => .{ .bool = args[0].ip.isLoopback() },
        .isGlobalUnicast => .{ .bool = args[0].ip.isGlobalUnicast() },
        .isLinkLocalMulticast => .{ .bool = args[0].ip.isLinkLocalMulticast() },
        .isLinkLocalUnicast => .{ .bool = args[0].ip.isLinkLocalUnicast() },
        .address => Value.fromIP(arena, args[0].cidr.address),
        .prefixLength => .{ .int = args[0].cidr.prefix },
        .masked => Value.fromCIDR(arena, args[0].cidr.masked()),
        .containsIP => .{ .bool = args[0].cidr.containsIP(if (args[1] == .ip)
            args[1].ip.*
        else
            try network.IP.parse(args[1].string)) },
        .containsCIDR => .{ .bool = args[0].cidr.containsCIDR(if (args[1] == .cidr)
            args[1].cidr.*
        else
            try network.CIDR.parse(args[1].string)) },
    };
}
