const std = @import("std");
const maxminddb = @import("maxminddb");

const db_path = "test-data/test-data/GeoLite2-City-Test.mmdb";

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();

    var db = try maxminddb.Reader.open_mmap(allocator, db_path);
    defer db.close();

    var n: usize = 0;
    var it = try db.within(maxminddb.geolite2.City);
    defer it.deinit();

    while (try it.next()) |item| {
        defer item.record.deinit();

        const continent = item.record.continent.code;
        const country = item.record.country.iso_code;
        const city = item.record.city.names.get("en") orelse "";

        if (city.len != 0) {
            try stdout.print("{}/{d} {s}-{s}-{s}\n", .{
                item.net.ip,
                item.net.prefix_len,
                continent,
                country,
                city,
            });
        } else if (country.len != 0) {
            try stdout.print("{}/{d} {s}-{s}\n", .{
                item.net.ip,
                item.net.prefix_len,
                continent,
                country,
            });
        } else if (continent.len != 0) {
            try stdout.print("{}/{d} {s}\n", .{
                item.net.ip,
                item.net.prefix_len,
                continent,
            });
        }

        n += 1;
    }

    try stdout.print("processed {d} items\n", .{n});
}
