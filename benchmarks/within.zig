const std = @import("std");
const maxminddb = @import("maxminddb");

const default_db_path: []const u8 = "GeoLite2-City.mmdb";

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var db_path: []const u8 = default_db_path;
    if (args.len > 1) db_path = args[1];

    std.debug.print("Benchmarking with:\n", .{});
    std.debug.print("  Database: {s}\n", .{db_path});
    std.debug.print("Opening database...\n", .{});

    var open_timer = try std.time.Timer.start();
    var db = try maxminddb.Reader.mmap(allocator, db_path, .{});
    defer db.close();
    const open_time_ms = @as(f64, @floatFromInt(open_timer.read())) /
        @as(f64, @floatFromInt(std.time.ns_per_ms));
    std.debug.print("Database opened successfully in {d} ms. Type: {s}\n", .{
        open_time_ms,
        db.metadata.database_type,
    });

    const network = if (db.metadata.ip_version == 4)
        maxminddb.Network.all_ipv4
    else
        maxminddb.Network.all_ipv6;

    std.debug.print("Starting benchmark...\n", .{});
    var timer = try std.time.Timer.start();

    var it = try db.within(allocator, maxminddb.any.Value, network, .{});
    defer it.deinit();

    var n: usize = 0;
    while (try it.next()) |item| {
        n += 1;
        item.deinit();
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));

    const records_per_second = if (elapsed_s > 0)
        @as(f64, @floatFromInt(n)) / elapsed_s
    else
        0.0;

    std.debug.print("\n--- Benchmark Finished ---\n", .{});
    std.debug.print("Records:            {d}\n", .{n});
    std.debug.print("Elapsed Time:       {d} s\n", .{elapsed_s});
    std.debug.print("Records Per Second: {d}\n", .{records_per_second});
}
