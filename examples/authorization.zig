//! Evaluate one authorization request through the public Zig API.

const std = @import("std");
const cel = @import("cel");

/// Compile a policy and evaluate native input values.
pub fn main(init: std.process.Init) !void {
    var program = try cel.Program.compile(init.gpa, "user.active && 'admin' in user.roles", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const roles = [_]cel.Value{.{ .string = "admin" }};
    const user = [_]cel.Entry{
        .{ .key = .{ .string = "active" }, .value = .{ .bool = true } },
        .{ .key = .{ .string = "roles" }, .value = .{ .list = &roles } },
    };
    const result = try program.evaluate(arena.allocator(), &.{
        .{ .name = "user", .value = .{ .map = &user } },
    });
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("allowed: {any}\n", .{result.bool});
    try stdout.interface.flush();
}
