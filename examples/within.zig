const std = @import("std");
const maxminddb = @import("maxminddb");

const db_path = "test-data/test-data/GeoLite2-City-Test.mmdb";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    var db = try maxminddb.Reader.mmap(allocator, db_path);
    defer db.unmap();

    const network = if (db.metadata.ip_version == 4)
        maxminddb.Network.all_ipv4
    else
        maxminddb.Network.all_ipv6;

    var it = try db.within(allocator, maxminddb.geolite2.City, network, .{});
    defer it.deinit();

    // Note, for better performance use arena allocator and reset it after calling it.next().
    // You won't need to call item.record.deinit() in that case.
    var n: usize = 0;
    while (try it.next(allocator)) |item| {
        defer item.record.deinit();

        const continent = item.record.continent.code;
        const country = item.record.country.iso_code;
        var city: []const u8 = "";
        if (item.record.city.names) |city_names| {
            city = city_names.get("en") orelse "";
        }

        if (city.len != 0) {
            std.debug.print("{f} {s}-{s}-{s}\n", .{
                item.net,
                continent,
                country,
                city,
            });
        } else if (country.len != 0) {
            std.debug.print("{f} {s}-{s}\n", .{
                item.net,
                continent,
                country,
            });
        } else if (continent.len != 0) {
            std.debug.print("{f} {s}\n", .{
                item.net,
                continent,
            });
        }

        n += 1;
    }

    std.debug.print("processed {d} items\n", .{n});
}
