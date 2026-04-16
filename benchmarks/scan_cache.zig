const std = @import("std");
const maxminddb = @import("maxminddb");

const default_db_path: []const u8 = "GeoLite2-City.mmdb";
const max_mmdb_fields = 32;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    const db_path = args.next() orelse default_db_path;
    var fields: ?[]const []const u8 = null;
    if (args.next()) |arg| {
        const f = try maxminddb.Fields(max_mmdb_fields).parse(arg, ',');
        fields = f.only();
    }

    std.debug.print("Benchmarking with:\n", .{});
    std.debug.print("  Database: {s}\n", .{db_path});
    std.debug.print("Opening database...\n", .{});

    const open_start = std.Io.Clock.Timestamp.now(io, .awake);
    var db = try maxminddb.Reader.mmap(allocator, io, db_path, .{});
    defer db.close();
    const open_elapsed_ns: i64 = @intCast(open_start.untilNow(io).raw.nanoseconds);
    const open_time_ms = @as(f64, @floatFromInt(open_elapsed_ns)) /
        @as(f64, @floatFromInt(std.time.ns_per_ms));
    std.debug.print("Database opened successfully in {d} ms. Type: {s}\n", .{
        open_time_ms,
        db.metadata.database_type,
    });

    const network = if (db.metadata.ip_version == 4)
        maxminddb.Network.all_ipv4
    else
        maxminddb.Network.all_ipv6;

    var cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{});
    defer cache.deinit();

    std.debug.print("Starting benchmark...\n", .{});
    const timer_start = std.Io.Clock.Timestamp.now(io, .awake);

    var it = try db.entries(network, .{});

    var n: usize = 0;
    while (try it.next()) |entry| {
        _ = try cache.decode(&db, entry, .{ .only = fields });
        n += 1;
    }

    const elapsed_ns: i64 = @intCast(timer_start.untilNow(io).raw.nanoseconds);
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
