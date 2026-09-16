//! Compile a typed policy and evaluate native input values.

const std = @import("std");
const cel = @import("cel");

/// Demonstrate checked compilation with a namespace and constant.
pub fn main(init: std.process.Init) !void {
    const environment = cel.Environment{
        .container = "policy",
        .variables = &.{.{ .name = "policy.score", .type = .{ .name = "int" } }},
        .constants = &.{.{ .name = "policy.threshold", .value = .{ .int = 80 } }},
    };
    var program = try environment.compile(init.gpa, "score >= threshold", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const result = try program.evaluate(arena.allocator(), &.{
        .{ .name = "policy.score", .value = .{ .int = 88 } },
    });
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("type: {s}, allowed: {any}\n", .{ program.result_type.?.name, result.bool });
    try stdout.interface.flush();
}
