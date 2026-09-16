//! Allocation-free IP address and CIDR parsing, classification, and containment.
//! Only formatting allocates, and returned text is owned by the caller's arena.

const std = @import("std");
const net = std.Io.net;

/// An IPv4 or IPv6 address in network byte order.
pub const IP = struct {
    /// Address bytes. IPv4 uses the first four bytes and requires the remaining bytes to be zero.
    bytes: [16]u8,
    /// Address family, either 4 or 6.
    family: u8,

    /// Parse a bare IP address without a zone, brackets, port, or IPv4-mapped IPv6 representation.
    pub fn parse(text: []const u8) error{InvalidArgument}!IP {
        if (text.len == 0 or text.len > 45 or std.mem.indexOfAny(u8, text, "%[]") != null) return error.InvalidArgument;

        if (net.Ip4Address.parse(text, 0)) |address| {
            return .{ .bytes = address.bytes ++ ([_]u8{0} ** 12), .family = 4 };
        } else |_| {}

        const address = net.Ip6Address.parse(text, 0) catch blk: {
            const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidArgument;
            const ipv4 = net.Ip4Address.parse(text[colon + 1 ..], 0) catch return error.InvalidArgument;
            const high = std.mem.readInt(u16, ipv4.bytes[0..2], .big);
            const low = std.mem.readInt(u16, ipv4.bytes[2..4], .big);
            var normalized_buffer: [39]u8 = undefined;
            const normalized = std.fmt.bufPrint(
                &normalized_buffer,
                "{s}{x}:{x}",
                .{ text[0 .. colon + 1], high, low },
            ) catch return error.InvalidArgument;
            break :blk net.Ip6Address.parse(normalized, 0) catch return error.InvalidArgument;
        };
        const result: IP = .{ .bytes = address.bytes, .family = 6 };
        try result.validate();
        return result;
    }

    /// Validate the family, IPv4 padding, and prohibition on IPv4-mapped IPv6 addresses.
    pub fn validate(self: IP) error{InvalidArgument}!void {
        switch (self.family) {
            4 => if (!std.mem.allEqual(u8, self.bytes[4..], 0)) return error.InvalidArgument,
            6 => if (std.mem.allEqual(u8, self.bytes[0..10], 0) and
                self.bytes[10] == 0xff and self.bytes[11] == 0xff) return error.InvalidArgument,
            else => return error.InvalidArgument,
        }
    }

    /// Format the address canonically as a bare RFC 5952 string in arena-owned storage.
    pub fn format(self: IP, arena: std.mem.Allocator) ![]const u8 {
        try self.validate();
        var buffer: [39]u8 = undefined;
        return arena.dupe(u8, formatInto(self, &buffer) catch unreachable); // Every valid address fits in 39 bytes.
    }

    /// Report whether both the family and address bytes are equal.
    pub fn eql(self: IP, other: IP) bool {
        return self.family == other.family and std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Report whether the address is the family-specific unspecified address.
    pub fn isUnspecified(self: IP) bool {
        return valid(self) and std.mem.allEqual(u8, &self.bytes, 0);
    }

    /// Report whether the address belongs to an IPv4 or IPv6 loopback range.
    pub fn isLoopback(self: IP) bool {
        if (!valid(self)) return false;
        if (self.family == 4) return self.bytes[0] == 127;
        return std.mem.allEqual(u8, self.bytes[0..15], 0) and self.bytes[15] == 1;
    }

    /// Report whether the address is global unicast according to Go `netip.Addr` semantics.
    pub fn isGlobalUnicast(self: IP) bool {
        if (!valid(self) or self.isUnspecified() or self.isLoopback() or self.isLinkLocalUnicast()) return false;
        if (self.family == 4) {
            if (std.mem.allEqual(u8, &self.bytes[0..4].*, 0xff)) return false;
            return self.bytes[0] & 0xf0 != 0xe0;
        }
        return self.bytes[0] != 0xff;
    }

    /// Report whether the address belongs to a link-local multicast range.
    pub fn isLinkLocalMulticast(self: IP) bool {
        if (!valid(self)) return false;
        if (self.family == 4) return self.bytes[0] == 224 and self.bytes[1] == 0 and self.bytes[2] == 0;
        return self.bytes[0] == 0xff and self.bytes[1] & 0x0f == 2;
    }

    /// Report whether the address belongs to a link-local unicast range.
    pub fn isLinkLocalUnicast(self: IP) bool {
        if (!valid(self)) return false;
        if (self.family == 4) return self.bytes[0] == 169 and self.bytes[1] == 254;
        return self.bytes[0] == 0xfe and self.bytes[1] & 0xc0 == 0x80;
    }
};

/// An IP address with a prefix length. Parsing preserves host bits.
pub const CIDR = struct {
    /// The unmasked address supplied by the caller.
    address: IP,
    /// Prefix length in bits.
    prefix: u8,

    /// Parse a CIDR with exactly one slash and a canonical decimal prefix length.
    pub fn parse(text: []const u8) error{InvalidArgument}!CIDR {
        if (text.len > 49) return error.InvalidArgument;
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.InvalidArgument;
        if (std.mem.indexOfScalarPos(u8, text, slash + 1, '/') != null) return error.InvalidArgument;
        const prefix_text = text[slash + 1 ..];
        if (prefix_text.len == 0 or (prefix_text.len > 1 and prefix_text[0] == '0')) return error.InvalidArgument;
        for (prefix_text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidArgument;

        const result: CIDR = .{
            .address = try IP.parse(text[0..slash]),
            .prefix = std.fmt.parseInt(u8, prefix_text, 10) catch return error.InvalidArgument,
        };
        try result.validate();
        return result;
    }

    /// Validate the address metadata and family-specific prefix range.
    pub fn validate(self: CIDR) error{InvalidArgument}!void {
        try self.address.validate();
        if (self.prefix > if (self.address.family == 4) @as(u8, 32) else 128) return error.InvalidArgument;
    }

    /// Format the unmasked address and prefix in canonical arena-owned storage.
    pub fn format(self: CIDR, arena: std.mem.Allocator) ![]const u8 {
        try self.validate();
        var address_buffer: [39]u8 = undefined;
        // Every valid address fits in 39 bytes.
        const address = formatInto(self.address, &address_buffer) catch unreachable;
        var buffer: [43]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s}/{d}", .{ address, self.prefix }) catch unreachable;
        return arena.dupe(u8, text);
    }

    /// Report whether the address, family, and prefix are equal.
    pub fn eql(self: CIDR, other: CIDR) bool {
        return self.prefix == other.prefix and self.address.eql(other.address);
    }

    /// Return the same prefix with all host bits cleared.
    pub fn masked(self: CIDR) CIDR {
        var result = self;
        if (!valid(self.address) or self.prefix > if (self.address.family == 4) @as(u8, 32) else 128) return result;
        const byte_len: usize = if (self.address.family == 4) 4 else 16;
        const whole = self.prefix / 8;
        const partial = self.prefix % 8;
        if (partial != 0) {
            result.address.bytes[whole] &= @as(u8, 0xff) << @intCast(8 - partial);
        }
        const clear_from: usize = whole + @intFromBool(partial != 0);
        @memset(result.address.bytes[clear_from..byte_len], 0);
        return result;
    }

    /// Report whether this prefix contains a valid address of the same family.
    pub fn containsIP(self: CIDR, address: IP) bool {
        if (!valid(self.address) or !valid(address) or self.address.family != address.family) return false;
        if (self.prefix > if (self.address.family == 4) @as(u8, 32) else 128) return false;
        const whole = self.prefix / 8;
        if (!std.mem.eql(u8, self.address.bytes[0..whole], address.bytes[0..whole])) return false;
        const partial = self.prefix % 8;
        if (partial == 0) return true;
        const mask = @as(u8, 0xff) << @intCast(8 - partial);
        return self.address.bytes[whole] & mask == address.bytes[whole] & mask;
    }

    /// Report whether this prefix completely contains another valid prefix.
    pub fn containsCIDR(self: CIDR, other: CIDR) bool {
        self.validate() catch return false;
        other.validate() catch return false;
        return self.address.family == other.address.family and self.prefix <= other.prefix and
            self.containsIP(other.address);
    }
};

fn valid(address: IP) bool {
    address.validate() catch return false;
    return true;
}

fn formatInto(address: IP, buffer: []u8) error{WriteFailed}![]const u8 {
    if (address.family == 4) {
        return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
            address.bytes[0], address.bytes[1], address.bytes[2], address.bytes[3],
        }) catch error.WriteFailed;
    }
    var writer: std.Io.Writer = .fixed(buffer);
    const unresolved: net.Ip6Address.Unresolved = .{ .bytes = address.bytes, .interface_name = null };
    unresolved.format(&writer) catch return error.WriteFailed;
    return buffer[0..writer.end];
}

test "network parsing rejects numeric zones and oversized CIDR input" {
    try std.testing.expectError(error.InvalidArgument, IP.parse("fe80::1%1"));
    try std.testing.expectError(error.InvalidArgument, CIDR.parse("fe80::1%1/64"));
    try std.testing.expectError(error.InvalidArgument, CIDR.parse("::/" ++ "1" ** 100));
}

test "network values parse format classify and contain" {
    const testing = std.testing;

    const ipv4 = try IP.parse("192.168.0.1");
    try testing.expectEqual(@as(u8, 4), ipv4.family);
    try testing.expect(std.mem.allEqual(u8, ipv4.bytes[4..], 0));
    try testing.expect(ipv4.isGlobalUnicast());
    try testing.expect(!(try IP.parse("255.255.255.255")).isGlobalUnicast());
    try testing.expect((try IP.parse("127.42.0.1")).isLoopback());
    try testing.expect((try IP.parse("224.0.0.1")).isLinkLocalMulticast());
    try testing.expect((try IP.parse("169.254.1.2")).isLinkLocalUnicast());
    try testing.expect((try IP.parse("::")).isUnspecified());
    try testing.expect((try IP.parse("::1")).isLoopback());
    try testing.expect((try IP.parse("ff02::1")).isLinkLocalMulticast());
    try testing.expect((try IP.parse("fe80::1")).isLinkLocalUnicast());
    try testing.expect(!(try IP.parse("ff00::1")).isGlobalUnicast());

    const ipv6 = try IP.parse("2001:0DB8:0:0:1:0:0:1");
    const ipv6_text = try ipv6.format(testing.allocator);
    defer testing.allocator.free(ipv6_text);
    try testing.expectEqualStrings("2001:db8::1:0:0:1", ipv6_text);
    const mixed = try IP.parse("2001:db8::192.0.2.1");
    const mixed_text = try mixed.format(testing.allocator);
    defer testing.allocator.free(mixed_text);
    try testing.expectEqualStrings("2001:db8::c000:201", mixed_text);

    for ([_][]const u8{
        "01.2.3.4",
        "[::1]",
        "::1%lo0",
        "1.2.3.4:80",
        "::ffff:192.0.2.1",
        "::ffff:c000:201",
        "0:0:0:0:0:ffff:192.0.2.1",
    }) |text| {
        try testing.expectError(error.InvalidArgument, IP.parse(text));
    }

    const cidr = try CIDR.parse("192.168.0.129/24");
    const cidr_text = try cidr.format(testing.allocator);
    defer testing.allocator.free(cidr_text);
    try testing.expectEqualStrings("192.168.0.129/24", cidr_text);
    try testing.expect(cidr.masked().eql(try CIDR.parse("192.168.0.0/24")));
    try testing.expect(cidr.containsIP(try IP.parse("192.168.0.1")));
    try testing.expect(cidr.containsCIDR(try CIDR.parse("192.168.0.250/32")));
    try testing.expect(!cidr.containsCIDR(try CIDR.parse("192.168.0.0/23")));
    try testing.expect(!cidr.containsIP(try IP.parse("2001:db8::1")));

    for ([_][]const u8{
        "192.168.0.1/",
        "192.168.0.1/024",
        "192.168.0.1/33",
        "::1/129",
        "::1/64/2",
    }) |text| {
        try testing.expectError(error.InvalidArgument, CIDR.parse(text));
    }
}
