const std = @import("std");

// Represents an IP network.
pub const Network = struct {
    ip: std.net.Address,
    prefix_len: usize,

    pub fn init(ip_bytes: []const u8, prefix_len: usize) !Network {
        return switch (ip_bytes.len) {
            4 => .{
                .ip = std.net.Address.initIp4([4]u8{
                    ip_bytes[0],
                    ip_bytes[1],
                    ip_bytes[2],
                    ip_bytes[3],
                }, 0),
                .prefix_len = prefix_len,
            },
            16 => {
                // IPv4 in IPv6 form.
                if (std.mem.allEqual(u8, ip_bytes[0..12], 0)) {
                    return .{
                        .ip = std.net.Address.initIp4([4]u8{
                            ip_bytes[12],
                            ip_bytes[13],
                            ip_bytes[14],
                            ip_bytes[15],
                        }, 0),
                        .prefix_len = prefix_len - 96,
                    };
                }

                return .{
                    .ip = std.net.Address.initIp6([16]u8{
                        ip_bytes[0],
                        ip_bytes[1],
                        ip_bytes[2],
                        ip_bytes[3],
                        ip_bytes[4],
                        ip_bytes[5],
                        ip_bytes[6],
                        ip_bytes[7],
                        ip_bytes[8],
                        ip_bytes[9],
                        ip_bytes[10],
                        ip_bytes[11],
                        ip_bytes[12],
                        ip_bytes[13],
                        ip_bytes[14],
                        ip_bytes[15],
                    }, 0, 0, 0),
                    .prefix_len = prefix_len,
                };
            },
            else => error.InvalidNetwork,
        };
    }
};

// Converts an IP address into bytes slice, e.g., IPv6 address 1000:0ac3:22a2:0000:0000:4b3c:0504:1234
// is converted into [16 0 10 195 34 162 0 0 0 0 75 60 5 4 18 52].
pub fn ipToBytes(address: *const std.net.Address) []const u8 {
    return switch (address.any.family) {
        std.posix.AF.INET => {
            const b = std.mem.asBytes(&address.in.sa.addr).*;
            return &b;
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
