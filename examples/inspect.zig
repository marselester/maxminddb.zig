const std = @import("std");
const maxminddb = @import("maxminddb");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    var args = std.process.args();
    _ = args.next();
    const db_path = args.next() orelse "test-data/test-data/GeoIP2-City-Test.mmdb";
    const ip = args.next() orelse "89.160.20.128";

    var db = try maxminddb.Reader.mmap(allocator, db_path);
    defer db.unmap();

    const m = db.metadata;
    std.debug.print("{s} v{}.{} ({} nodes, IPv{})\n", .{
        m.database_type,
        m.binary_format_major_version,
        m.binary_format_minor_version,
        m.node_count,
        m.ip_version,
    });

    const result = try db.lookup(
        allocator,
        maxminddb.any.Value,
        try std.net.Address.parseIp(ip, 0),
        .{},
    ) orelse {
        std.debug.print("{s}: not found\n", .{ip});
        return;
    };
    defer result.deinit();

    std.debug.print("{f}\n", .{result.value});
}
