//! Nanosecond CEL temporal values. Calendar parsing and named zones use the pinned native libraries.

const std = @import("std");

/// Earliest supported UTC second: 0001-01-01T00:00:00Z.
pub const min_seconds: i64 = -62_135_596_800;
/// Latest supported UTC second: 9999-12-31T23:59:59Z.
pub const max_seconds: i64 = 253_402_300_799;

/// A normalized UTC instant. Nanoseconds are always in [0, 1_000_000_000).
pub const Timestamp = struct {
    seconds: i64,
    nanos: u32 = 0,

    /// Validate the protobuf/CEL timestamp range.
    pub fn validate(self: Timestamp) error{Overflow}!void {
        if (self.seconds < min_seconds or self.seconds > max_seconds or self.nanos >= 1_000_000_000) return error.Overflow;
    }

    /// Normalize a total nanosecond count without losing distant dates or subsecond precision.
    pub fn fromNanos(total: i128) error{Overflow}!Timestamp {
        const seconds = @divFloor(total, 1_000_000_000);
        if (seconds < min_seconds or seconds > max_seconds) return error.Overflow;
        return .{ .seconds = @intCast(seconds), .nanos = @intCast(@mod(total, 1_000_000_000)) };
    }

    /// Exact nanosecond count, wide enough for the full supported date range.
    pub fn toNanos(self: Timestamp) i128 {
        return @as(i128, self.seconds) * 1_000_000_000 + self.nanos;
    }

    /// Parse an RFC3339 timestamp using the protobuf runtime's calendar validation.
    pub fn parse(text: []const u8) error{ InvalidArgument, OutOfMemory, Overflow }!Timestamp {
        var result: Timestamp = undefined;
        try status(cel_timestamp_parse(text.ptr, text.len, &result.seconds, &result.nanos));
        try result.validate();
        return result;
    }

    /// Format a UTC RFC3339 value into arena-owned storage.
    pub fn format(self: Timestamp, arena: std.mem.Allocator) error{ InvalidArgument, OutOfMemory, Overflow }![]const u8 {
        try self.validate();
        var buffer: [40]u8 = undefined;
        var length: usize = 0;
        try status(cel_timestamp_format(self.seconds, self.nanos, &buffer, buffer.len, &length));
        return arena.dupe(u8, buffer[0..length]);
    }

    /// Select a calendar field using UTC, a fixed offset, or a named IANA timezone.
    pub fn select(self: Timestamp, component: c_int, zone: []const u8) error{ InvalidArgument, OutOfMemory, Overflow }!i64 {
        try self.validate();
        var result: i64 = 0;
        try status(cel_timestamp_select(self.seconds, self.nanos, zone.ptr, zone.len, component, &result));
        return result;
    }
};

/// A signed 64-bit duration measured in nanoseconds.
pub const Duration = struct {
    nanoseconds: i64,

    /// Parse the CEL duration grammar, excluding calendar-dependent day/week units.
    pub fn parse(text: []const u8) error{ InvalidArgument, OutOfMemory, Overflow }!Duration {
        var result: Duration = undefined;
        try status(cel_duration_parse(text.ptr, text.len, &result.nanoseconds));
        return result;
    }

    /// Format seconds and an optional fractional component into arena-owned storage.
    pub fn format(self: Duration, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const magnitude = @abs(self.nanoseconds);
        const seconds = magnitude / 1_000_000_000;
        const fraction = magnitude % 1_000_000_000;
        const sign: []const u8 = if (self.nanoseconds < 0) "-" else "";
        if (fraction == 0) return std.fmt.allocPrint(arena, "{s}{d}s", .{ sign, seconds });
        var digits: [9]u8 = undefined;
        _ = std.fmt.bufPrint(&digits, "{d:0>9}", .{fraction}) catch unreachable; // Nine digits fit a nanosecond remainder.
        return std.fmt.allocPrint(arena, "{s}{d}.{s}s", .{ sign, seconds, std.mem.trimEnd(u8, &digits, "0") });
    }
};

/// Resolve a standard timestamp selector to its native calendar operation.
pub fn selector(name: []const u8) ?c_int {
    const methods = std.StaticStringMap(c_int).initComptime(.{
        .{ "getDate", 0 },     .{ "getDayOfMonth", 1 }, .{ "getDayOfWeek", 2 },    .{ "getDayOfYear", 3 },
        .{ "getFullYear", 4 }, .{ "getHours", 5 },      .{ "getMilliseconds", 6 }, .{ "getMinutes", 7 },
        .{ "getMonth", 8 },    .{ "getSeconds", 9 },
    });
    return methods.get(name);
}

fn status(code: c_int) error{ InvalidArgument, OutOfMemory, Overflow }!void {
    return switch (code) {
        0 => {},
        1 => error.InvalidArgument,
        2 => error.OutOfMemory,
        3 => error.Overflow,
        else => unreachable,
    };
}

extern fn cel_timestamp_parse([*]const u8, usize, *i64, *u32) c_int;
extern fn cel_duration_parse([*]const u8, usize, *i64) c_int;
extern fn cel_timestamp_format(i64, u32, [*]u8, usize, *usize) c_int;
extern fn cel_timestamp_select(i64, u32, [*]const u8, usize, c_int, *i64) c_int;
