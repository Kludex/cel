//! Bound the evaluation cost of an untrusted expression.

const std = @import("std");
const cel = @import("cel");

/// Print the expected cost-limit error.
pub fn main(init: std.process.Init) !void {
    var program = try cel.Program.compile(init.gpa, "1 + 2", .{ .max_steps = 2 });
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    _ = program.evaluate(arena.allocator(), &.{}) catch |err| {
        if (err != error.CostLimitExceeded) return err;
        var buffer: [128]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.print("{s}\n", .{@errorName(err)});
        try stdout.interface.flush();
        return;
    };
    return error.ExpectedCostLimit;
}
