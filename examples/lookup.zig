const std = @import("std");
const maxminddb = @import("maxminddb");

const db_path = "test-data/test-data/GeoIP2-City-Test.mmdb";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var db = try maxminddb.Reader.open(allocator, io, db_path, .{});
    defer db.close();

    // Note, for better performance use arena allocator and reset it after calling lookup().
    // You won't need to call city.deinit() in that case.
    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const city = try db.lookup(maxminddb.geoip2.City, allocator, ip, .{}) orelse return;
    defer city.deinit();

    for (city.value.country.names.?.entries) |e| {
        std.debug.print("{s} = {s}\n", .{ e.key, e.value });
    }
}
