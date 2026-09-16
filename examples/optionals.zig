//! Evaluate a policy against an absent request field without confusing absence with null.

const std = @import("std");
const cel = @import("cel");

/// Use optional field access and a lazy default through the public SDK.
pub fn main(init: std.process.Init) !void {
    const environment = cel.Environment{ .variables = &.{.{
        .name = "request",
        .type = .{ .name = "map", .parameters = &.{ .{ .name = "string" }, .{ .name = "dyn" } } },
    }} };
    var policy = try environment.compile(init.gpa, "request.?limit.orValue(10)", .{});
    defer policy.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const result = try policy.evaluate(arena.allocator(), &.{
        .{ .name = "request", .value = .{ .map = &.{} } },
    });
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("limit: {d}\n", .{result.int});
    try stdout.interface.flush();
}
