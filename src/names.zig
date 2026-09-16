//! Qualified CEL name matching. This module borrows syntax and names and allocates nothing.

const std = @import("std");
const syntax = @import("syntax.zig");

/// Validate a dot-separated name, allowing an empty container when requested.
pub fn valid(name: []const u8, allow_empty: bool) bool {
    if (name.len == 0) return allow_empty;
    var segments = std.mem.splitScalar(u8, name, '.');
    while (segments.next()) |segment| {
        if (segment.len == 0 or (!std.ascii.isAlphabetic(segment[0]) and segment[0] != '_')) return false;
        for (segment[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Return the identifier at the root of a qualified selection chain.
pub fn root(node: *const syntax.Node) []const u8 {
    var current = node;
    while (current.* == .select) current = current.select.target;
    return current.ident;
}

/// Match a syntactic identifier chain against one fully qualified declaration or activation name.
pub fn matches(node: *const syntax.Node, name: []const u8, prefix: []const u8) bool {
    var rest = name;
    if (prefix.len > 0) {
        if (rest.len <= prefix.len or !std.mem.startsWith(u8, rest, prefix) or rest[prefix.len] != '.') return false;
        rest = rest[prefix.len + 1 ..];
    }
    var current = node;
    while (current.* == .select) {
        const field = current.select.field;
        if (rest.len <= field.len or rest[rest.len - field.len - 1] != '.' or
            !std.mem.endsWith(u8, rest, field)) return false;
        rest = rest[0 .. rest.len - field.len - 1];
        current = current.select.target;
    }
    const identifier = current.ident;
    return std.mem.eql(u8, rest, if (std.mem.startsWith(u8, identifier, ".")) identifier[1..] else identifier);
}

/// Move from a namespace to its parent, or to the root namespace.
pub fn parent(container: []const u8) []const u8 {
    return container[0 .. std.mem.lastIndexOfScalar(u8, container, '.') orelse 0];
}
