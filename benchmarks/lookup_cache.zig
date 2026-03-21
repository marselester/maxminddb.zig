const std = @import("std");
const maxminddb = @import("maxminddb");

const default_db_path: []const u8 = "GeoLite2-City.mmdb";
const default_num_lookups: u64 = 1_000_000;
const max_mmdb_fields = 32;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var db_path: []const u8 = default_db_path;
    var num_lookups = default_num_lookups;
    var fields: ?[]const []const u8 = null;
    if (args.len > 1) db_path = args[1];
    if (args.len > 2) num_lookups = try std.fmt.parseUnsigned(u64, args[2], 10);
    if (args.len > 3) {
        var items: [max_mmdb_fields][]const u8 = undefined;

        var it = std.mem.splitScalar(u8, args[3], ',');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            items[i] = part;
        }

        fields = items[0..i];
    }

    std.debug.print("Benchmarking with:\n", .{});
    std.debug.print("  Database: {s}\n", .{db_path});
    std.debug.print("  Lookups:  {d}\n", .{num_lookups});
    std.debug.print("Opening database...\n", .{});

    var open_timer = try std.time.Timer.start();
    var db = try maxminddb.Reader.mmap(allocator, db_path, .{ .ipv4_index_first_n_bits = 16 });
    defer db.close();
    const open_time_ms = @as(f64, @floatFromInt(open_timer.read())) /
        @as(f64, @floatFromInt(std.time.ns_per_ms));
    std.debug.print("Database opened successfully in {d} ms. Type: {s}\n", .{
        open_time_ms,
        db.metadata.database_type,
    });

    var cache = try maxminddb.Cache(maxminddb.geolite2.City).init(allocator, .{});
    defer cache.deinit();

    std.debug.print("Starting benchmark...\n", .{});
    var timer = try std.time.Timer.start();
    var not_found_count: u64 = 0;
    var lookup_errors: u64 = 0;
    var ip_bytes: [4]u8 = undefined;

    for (0..num_lookups) |_| {
        std.crypto.random.bytes(&ip_bytes);
        const ip = std.net.Address.initIp4(ip_bytes, 0);

        const result = db.lookupWithCache(
            maxminddb.geolite2.City,
            &cache,
            ip,
            .{ .only = fields },
        ) catch |err| {
            std.debug.print("! Lookup error for IP {any}: {any}\n", .{ ip, err });
            lookup_errors += 1;
            continue;
        };
        if (result == null) {
            not_found_count += 1;
            continue;
        }
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));
    const lookups_per_second = if (elapsed_s > 0)
        @as(f64, @floatFromInt(num_lookups)) / elapsed_s
    else
        0.0;
    const successful_lookups = num_lookups - not_found_count - lookup_errors;

    std.debug.print("\n--- Benchmark Finished ---\n", .{});
    std.debug.print("Total Lookups Attempted: {d}\n", .{num_lookups});
    std.debug.print("Successful Lookups:      {d}\n", .{successful_lookups});
    std.debug.print("IPs Not Found:           {d}\n", .{not_found_count});
    std.debug.print("Lookup Errors:           {d}\n", .{lookup_errors});
    std.debug.print("Elapsed Time:            {d} s\n", .{elapsed_s});
    std.debug.print("Lookups Per Second (avg):{d}\n", .{lookups_per_second});
}
