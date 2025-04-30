const std = @import("std");

// Represents an IP network.
pub const Network = struct {
    ip: std.net.Address,
    prefix_len: usize = 0,
};

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
                if (std.mem.allEqual(u8, b[0..12], 0)) {
                    return .{
                        .ip = std.net.Address.initIp4([4]u8{
                            b[12],
                            b[13],
                            b[14],
                            b[15],
                        }, 0),
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
        std.posix.AF.INET => {
            return std.mem.asBytes(&address.in.sa.addr);
        },
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
