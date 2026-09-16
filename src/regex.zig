//! RE2 ownership and bounded caches. RE2 uses its own C++ heap; Zig owns cache keys and tables.

const std = @import("std");

/// Caps for each compiled-program cache and each evaluation's dynamic-pattern cache.
pub const Limits = struct {
    max_patterns: usize = 64,
    max_pattern_bytes: usize = 65_536,
    max_memory_bytes: u64 = 1_048_576,
    max_program_size: usize = 10_000,
};

/// A cached RE2 program or a deferred evaluation failure.
pub const Pattern = union(enum) {
    compiled: struct { handle: *anyopaque, program_size: usize },
    invalid,
    limited,

    /// Search a string. RE2 may fill its internal DFA cache within its memory limit.
    pub fn matches(self: Pattern, text: []const u8, remaining: *usize) error{
        /// RE2 could not allocate working storage.
        OutOfMemory,
        /// The pattern is not valid RE2 syntax.
        InvalidArgument,
        /// The compiled pattern exceeds its resource limits.
        RegexLimitExceeded,
        /// The match would exceed the remaining evaluation work budget.
        CostLimitExceeded,
    }!bool {
        const compiled = switch (self) {
            .compiled => |v| v,
            .invalid => return error.InvalidArgument,
            .limited => return error.RegexLimitExceeded,
        };
        const cost = std.math.mul(usize, @max(compiled.program_size, 1), @max(text.len, 1)) catch return error.CostLimitExceeded;
        if (cost > remaining.*) return error.CostLimitExceeded;
        remaining.* -= cost;
        return switch (cel_re2_match(compiled.handle, text.ptr, text.len)) {
            0 => false,
            1 => true,
            -1 => error.OutOfMemory,
            else => unreachable,
        };
    }

    fn deinit(self: Pattern) void {
        if (self == .compiled) cel_re2_free(self.compiled.handle);
    }
};

/// Own compiled patterns. An immutable cache can be shared by independent evaluations.
pub const Cache = struct {
    entries: std.StringHashMapUnmanaged(Pattern) = .empty,

    /// Retrieve a pattern, copying the key and compiling it only on a cache miss.
    pub fn get(self: *Cache, gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) error{
        /// A Zig cache allocation or a RE2 allocation failed.
        OutOfMemory,
        /// Too many distinct patterns were requested in this cache.
        RegexLimitExceeded,
    }!Pattern {
        if (self.entries.get(pattern)) |entry| return entry;
        if (pattern.len > limits.max_pattern_bytes) return .limited;
        if (self.entries.count() >= limits.max_patterns) return error.RegexLimitExceeded;
        const memory_limit = std.math.cast(i64, limits.max_memory_bytes) orelse return .limited;
        // RE2 computes max_mem * 2 / 3 and treats a zero budget as unlimited.
        if (memory_limit < 3 or memory_limit > std.math.maxInt(i64) / 2) return .limited;
        const key = try gpa.dupe(u8, pattern);
        errdefer gpa.free(key);
        var status: c_int = 0;
        var program_size: usize = 0;
        const handle = cel_re2_compile(key.ptr, key.len, memory_limit, limits.max_program_size, &status, &program_size);
        const entry: Pattern = switch (status) {
            0 => .{ .compiled = .{ .handle = handle.?, .program_size = program_size } },
            1 => .invalid,
            2 => .limited,
            3 => return error.OutOfMemory,
            else => unreachable,
        };
        errdefer entry.deinit();
        try self.entries.put(gpa, key, entry);
        return entry;
    }

    /// Release every RE2 program, copied key, and cache table.
    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit();
            gpa.free(entry.key_ptr.*);
        }
        self.entries.deinit(gpa);
        self.* = .{};
    }
};

extern fn cel_re2_compile(
    pattern: [*]const u8,
    length: usize,
    memory_limit: i64,
    program_limit: usize,
    status: *c_int,
    program_size: *usize,
) ?*anyopaque;
extern fn cel_re2_match(handle: *const anyopaque, text: [*]const u8, length: usize) c_int;
extern fn cel_re2_free(handle: *anyopaque) void;
