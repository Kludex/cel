//! Authorize a source address against a tenant's IP prefix without network I/O.

const std = @import("std");
const cel = @import("cel");

/// Evaluate a checked policy using native network values.
pub fn main(init: std.process.Init) !void {
    const environment = cel.Environment{ .variables = &.{
        .{ .name = "source", .type = .{ .name = "net.IP", .kind = .abstract } },
        .{ .name = "network", .type = .{ .name = "net.CIDR", .kind = .abstract } },
    } };
    var policy = try environment.compile(init.gpa, "network.containsIP(source) && source.isGlobalUnicast() && !source.isLoopback()", .{});
    defer policy.deinit();
    const source = try cel.IP.parse("10.24.3.8");
    const network = try cel.CIDR.parse("10.24.0.17/16");
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const result = try policy.evaluate(arena.allocator(), &.{
        .{ .name = "source", .value = .{ .ip = &source } },
        .{ .name = "network", .value = .{ .cidr = &network } },
    });
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("allowed: {}\n", .{result.bool});
    try stdout.interface.flush();
}
