const std = @import("std");
const maxminddb = @import("maxminddb");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    const db_path = args.next() orelse "test-data/test-data/GeoIP2-City-Test.mmdb";
    const ip = args.next() orelse "89.160.20.128";

    var db = try maxminddb.Reader.mmap(allocator, io, db_path, .{});
    defer db.close();

    const result = try db.lookup(
        maxminddb.any.Value,
        allocator,
        try std.Io.net.IpAddress.parse(ip, 0),
        .{},
    ) orelse {
        std.debug.print("{s}: not found\n", .{ip});
        return;
    };
    defer result.deinit();

    std.debug.print("{f}\n", .{result.value});
}
