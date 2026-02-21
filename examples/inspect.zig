const std = @import("std");
const maxminddb = @import("maxminddb");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const db_path = if (args.len > 1) args[1] else "test-data/test-data/GeoIP2-City-Test.mmdb";
    const ip = if (args.len > 2) args[2] else "89.160.20.128";

    var db = try maxminddb.Reader.mmap(allocator, db_path);
    defer db.close();

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
