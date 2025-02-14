const std = @import("std");
const maxminddb = @import("maxminddb");

const db_path = "test-data/test-data/GeoLite2-City-Test.mmdb";
// We expect a DB file not larger than 1 GB.
const max_db_size: usize = 1024 * 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    var db = try maxminddb.Reader.open(allocator, db_path, max_db_size);
    defer db.close();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const city = try db.lookup(maxminddb.geolite2.City, &ip);
    defer city.deinit();

    var it = city.country.names.iterator();
    while (it.next()) |kv| {
        std.debug.print("{s} = {s}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
    }
}
