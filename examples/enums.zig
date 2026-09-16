//! Evaluate a protobuf enum policy while retaining its nominal type.

const std = @import("std");
const cel = @import("cel");

/// Demonstrate strong enum declarations without converting inputs to integers.
pub fn main(init: std.process.Init) !void {
    const enum_name = "google.protobuf.FieldDescriptorProto.Type";
    const environment = cel.Environment{
        .container = "google.protobuf.FieldDescriptorProto",
        .strong_enums = true,
        .variables = &.{.{ .name = "field_type", .type = .{ .name = enum_name } }},
    };
    var program = try environment.compile(init.gpa, "field_type == Type.TYPE_STRING", .{});
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const field_type = cel.EnumValue{ .type_name = enum_name, .number = 9 };
    const result = try program.evaluate(arena.allocator(), &.{
        .{ .name = "field_type", .value = .{ .enum_value = &field_type } },
    });
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("string field: {any}\n", .{result.bool});
    try stdout.interface.flush();
}
