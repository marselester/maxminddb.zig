const std = @import("std");

// Represents an IP network.
pub const Network = struct {
    ip: std.net.Address,
    prefix_len: usize = 0,

    pub const all_ipv4 = Network{
        .ip = std.net.Address.parseIp("0.0.0.0", 0) catch unreachable,
    };
    pub const all_ipv6 = Network{
        .ip = std.net.Address.parseIp("::", 0) catch unreachable,
    };

    // Parses an IP address or CIDR string like "1.0.0.0/24".
    pub fn parse(s: []const u8) !Network {
        if (std.mem.indexOfScalar(u8, s, '/')) |sep| {
            const ip = try std.net.Address.parseIp(s[0..sep], 0);
            const prefix_len = try std.fmt.parseInt(usize, s[sep + 1 ..], 10);
            return .{
                .ip = ip,
                .prefix_len = prefix_len,
            };
        }

        return .{
            .ip = try std.net.Address.parseIp(s, 0),
        };
    }

    pub fn format(self: Network, writer: anytype) !void {
        switch (self.ip.any.family) {
            std.posix.AF.INET => {
                const b: *const [4]u8 = @ptrCast(&self.ip.in.sa.addr);
                try writer.print(
                    "{}.{}.{}.{}/{}",
                    .{
                        b[0],
                        b[1],
                        b[2],
                        b[3],
                        self.prefix_len,
                    },
                );
            },
            std.posix.AF.INET6 => {
                const b = self.ip.in6.sa.addr;
                try writer.print(
                    "{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}/{}",
                    .{
                        std.mem.readInt(u16, b[0..2], .big),
                        std.mem.readInt(u16, b[2..4], .big),
                        std.mem.readInt(u16, b[4..6], .big),
                        std.mem.readInt(u16, b[6..8], .big),
                        std.mem.readInt(u16, b[8..10], .big),
                        std.mem.readInt(u16, b[10..12], .big),
                        std.mem.readInt(u16, b[12..14], .big),
                        std.mem.readInt(u16, b[14..16], .big),
                        self.prefix_len,
                    },
                );
            },
            else => unreachable,
        }
    }
};

test "Network.format" {
    const tests = [_]struct {
        addr: []const u8,
        want: []const u8,
    }{
        .{
            .addr = "89.160.20.128",
            .want = "89.160.20.128/64",
        },
        .{
            .addr = "1000:0ac3:22a2:0000:0000:4b3c:0504:1234",
            .want = "1000:0ac3:22a2:0000:0000:4b3c:0504:1234/64",
        },
    };

    var buf: [128]u8 = undefined;
    for (tests) |tc| {
        const addr = Network{
            .ip = try std.net.Address.parseIp(tc.addr, 0),
            .prefix_len = 64,
        };
        const got = try std.fmt.bufPrint(&buf, "{f}", .{addr});
        try std.testing.expectEqualStrings(tc.want, got);
    }
}

test "Network.parse" {
    var buf: [128]u8 = undefined;

    const v4 = try Network.parse("1.0.0.0/24");
    const got_v4 = try std.fmt.bufPrint(&buf, "{f}", .{v4});
    try std.testing.expectEqualStrings("1.0.0.0/24", got_v4);

    const v6 = try Network.parse("2001:db8::/32");
    const got_v6 = try std.fmt.bufPrint(&buf, "{f}", .{v6});
    try std.testing.expectEqualStrings("2001:0db8:0000:0000:0000:0000:0000:0000/32", got_v6);

    const no_cidr = try Network.parse("10.0.0.1");
    try std.testing.expectEqual(0, no_cidr.prefix_len);
}

// Represents IPv4 or IPv6 bytes.
pub const IP = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    pub fn init(addr: std.net.Address) IP {
        return switch (addr.any.family) {
            std.posix.AF.INET => .{
                .v4 = std.mem.asBytes(&addr.in.sa.addr).*,
            },
            std.posix.AF.INET6 => .{
                .v6 = addr.in6.sa.addr,
            },
            else => unreachable,
        };
    }

    pub fn bitAt(self: IP, index: usize) usize {
        return switch (self) {
            .v4 => |b| 1 & std.math.shr(usize, b[index >> 3], 7 - (index % 8)),
            .v6 => |b| 1 & std.math.shr(usize, b[index >> 3], 7 - (index % 8)),
        };
    }

    pub fn bitCount(self: IP) usize {
        return switch (self) {
            .v4 => 32,
            .v6 => 128,
        };
    }

    pub fn isV4InV6(self: IP) bool {
        return switch (self) {
            .v4 => false,
            .v6 => |b| std.mem.allEqual(u8, b[0..12], 0),
        };
    }

    /// Zeros out bits after prefix_len.
    pub fn mask(self: IP, prefix_len: usize) IP {
        return switch (self) {
            .v4 => |b| {
                // Combines IP bytes into a big-endian u32, e.g.,
                // 89.160.20.128 = 89 << 24 | 160 << 16 | 20 << 8 | 128
                const ipAsNumber = std.mem.readInt(u32, &b, .big);
                const ones: u32 = std.math.maxInt(u32);
                const bitmask = if (prefix_len == 0) 0 else ones << @intCast(32 - prefix_len);

                var out: [4]u8 = undefined;
                std.mem.writeInt(u32, &out, ipAsNumber & bitmask, .big);

                return .{ .v4 = out };
            },
            .v6 => |b| {
                const ipAsNumber = std.mem.readInt(u128, &b, .big);
                const ones: u128 = std.math.maxInt(u128);
                const bitmask = if (prefix_len == 0) 0 else ones << @intCast(128 - prefix_len);

                var out: [16]u8 = undefined;
                std.mem.writeInt(u128, &out, ipAsNumber & bitmask, .big);

                return .{ .v6 = out };
            },
        };
    }

    pub fn network(self: IP, prefix_len: usize) Network {
        return switch (self) {
            .v4 => |b| .{
                .ip = std.net.Address.initIp4(b, 0),
                .prefix_len = prefix_len,
            },
            .v6 => |b| {
                // IPv4 in IPv6 form.
                if (std.mem.allEqual(u8, b[0..12], 0) and prefix_len >= 96) {
                    return .{
                        .ip = std.net.Address.initIp4(b[12..16].*, 0),
                        .prefix_len = prefix_len - 96,
                    };
                }

                return .{
                    .ip = std.net.Address.initIp6(b, 0, 0, 0),
                    .prefix_len = prefix_len,
                };
            },
        };
    }
};

test "IP.mask" {
    const tests = [_]struct {
        addr: []const u8,
        prefix_len: usize,
        want: []const u8,
    }{
        // IPv4 partial byte boundary.
        .{
            .addr = "89.160.20.128",
            .prefix_len = 17,
            .want = "89.160.0.0/17",
        },
        // IPv4 byte boundaries.
        .{
            .addr = "89.160.20.128",
            .prefix_len = 8,
            .want = "89.0.0.0/8",
        },
        .{
            .addr = "89.160.20.128",
            .prefix_len = 24,
            .want = "89.160.20.0/24",
        },
        // IPv4 zero prefix (all bits masked).
        .{
            .addr = "89.160.20.128",
            .prefix_len = 0,
            .want = "0.0.0.0/0",
        },
        // IPv4 full prefix (no bits masked).
        .{
            .addr = "89.160.20.128",
            .prefix_len = 32,
            .want = "89.160.20.128/32",
        },
        // IPv6 byte boundary.
        .{
            .addr = "2001:218:ffff:ffff:ffff:ffff:ffff:ffff",
            .prefix_len = 32,
            .want = "2001:0218:0000:0000:0000:0000:0000:0000/32",
        },
        // IPv6 partial byte boundary: /28 keeps top 4 bits of byte 3.
        .{
            .addr = "2a02:ffff::",
            .prefix_len = 28,
            .want = "2a02:fff0:0000:0000:0000:0000:0000:0000/28",
        },
        // IPv6 zero prefix.
        .{
            .addr = "2001:218:ffff:ffff:ffff:ffff:ffff:ffff",
            .prefix_len = 0,
            .want = "0000:0000:0000:0000:0000:0000:0000:0000/0",
        },
        // IPv6 full prefix (no bits masked).
        .{
            .addr = "2001:218:ffff:ffff:ffff:ffff:ffff:ffff",
            .prefix_len = 128,
            .want = "2001:0218:ffff:ffff:ffff:ffff:ffff:ffff/128",
        },
    };

    var buf: [64]u8 = undefined;
    for (tests) |tc| {
        const ip = IP.init(try std.net.Address.parseIp(tc.addr, 0));
        const masked = ip.mask(tc.prefix_len).network(tc.prefix_len);
        const got = try std.fmt.bufPrint(&buf, "{f}", .{masked});

        try std.testing.expectEqualStrings(tc.want, got);
    }
}
