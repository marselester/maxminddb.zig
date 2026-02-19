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

// Converts an IP address into bytes slice, e.g., IPv6 address 1000:0ac3:22a2:0000:0000:4b3c:0504:1234
// is converted into [16 0 10 195 34 162 0 0 0 0 75 60 5 4 18 52].
pub fn ipToBytes(address: *const std.net.Address) []const u8 {
    return switch (address.any.family) {
        std.posix.AF.INET => std.mem.asBytes(&address.in.sa.addr),
        std.posix.AF.INET6 => &address.in6.sa.addr,
        else => unreachable,
    };
}

test "ipToBytes" {
    const tests = [_]struct {
        addr: []const u8,
        want: []const u8,
    }{
        .{
            .addr = "89.160.20.128",
            .want = &.{ 89, 160, 20, 128 },
        },
        .{
            .addr = "1000:0ac3:22a2:0000:0000:4b3c:0504:1234",
            .want = &.{ 16, 0, 10, 195, 34, 162, 0, 0, 0, 0, 75, 60, 5, 4, 18, 52 },
        },
    };

    for (tests) |tc| {
        const addr = try std.net.Address.parseIp(tc.addr, 0);
        try std.testing.expectEqualStrings(tc.want, ipToBytes(&addr));
    }
}
