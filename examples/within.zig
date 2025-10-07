const std = @import("std");
const maxminddb = @import("maxminddb");

const db_path = "test-data/test-data/GeoLite2-City-Test.mmdb";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    var db = try maxminddb.Reader.mmap(allocator, db_path);
    defer db.unmap();

    const network = maxminddb.Network{
        .ip = try std.net.Address.parseIp("0.0.0.0", 0),
    };
    var it = try db.within(allocator, maxminddb.geolite2.City, network);
    defer it.deinit();

    var n: usize = 0;
    while (try it.next()) |item| {
        defer item.record.deinit();

        const continent = item.record.continent.code;
        const country = item.record.country.iso_code;
        var city: []const u8 = "";
        if (item.record.city.names) |city_names| {
            city = city_names.get("en") orelse "";
        }

        if (city.len != 0) {
            std.debug.print("{f}/{d} {s}-{s}-{s}\n", .{
                item.net.ip,
                item.net.prefix_len,
                continent,
                country,
                city,
            });
        } else if (country.len != 0) {
            std.debug.print("{f}/{d} {s}-{s}\n", .{
                item.net.ip,
                item.net.prefix_len,
                continent,
                country,
            });
        } else if (continent.len != 0) {
            std.debug.print("{f}/{d} {s}\n", .{
                item.net.ip,
                item.net.prefix_len,
                continent,
            });
        }

        n += 1;
    }

    std.debug.print("processed {d} items\n", .{n});
}
