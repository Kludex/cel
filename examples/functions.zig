//! Register a trusted function and evaluate an authorization policy with native values.

const std = @import("std");
const cel = @import("cel");

/// Compile a typed callback-backed policy and print its decision.
pub fn main(init: std.process.Init) !void {
    const string = cel.Type{ .name = "string" };
    const environment = cel.Environment{
        .variables = &.{
            .{ .name = "role", .type = string },
            .{ .name = "owner", .type = string },
            .{ .name = "user", .type = string },
        },
        .functions = &.{.{
            .name = "allowed",
            .parameters = &.{ string, string, string },
            .result = .{ .name = "bool" },
            .implementation = allowed,
        }},
    };
    var program = try environment.compile(init.gpa, "allowed(role, owner, user)", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const result = try program.evaluate(arena.allocator(), &.{
        .{ .name = "role", .value = .{ .string = "member" } },
        .{ .name = "owner", .value = .{ .string = "alice" } },
        .{ .name = "user", .value = .{ .string = "alice" } },
    });
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("allowed: {any}\n", .{result.bool});
    try stdout.interface.flush();
}

fn allowed(_: ?*anyopaque, _: std.mem.Allocator, args: []const cel.Value) cel.EvalError!cel.Value {
    return .{ .bool = std.mem.eql(u8, args[0].string, "admin") or args[1].eql(args[2]) };
}
