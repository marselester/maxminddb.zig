// The benchmark is contributed by @oschwald.
const std = @import("std");
const maxminddb = @import("maxminddb");

const default_db_path: []const u8 = "GeoLite2-City.mmdb";
const default_num_lookups: u64 = 1_000_000;
const max_mmdb_fields = 32;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    const db_path = args.next() orelse default_db_path;
    var num_lookups = default_num_lookups;
    var fields: ?[]const []const u8 = null;
    if (args.next()) |arg| num_lookups = try std.fmt.parseUnsigned(u64, arg, 10);
    if (args.next()) |arg| {
        const f = try maxminddb.Fields(max_mmdb_fields).parse(arg, ',');
        fields = f.only();
    }

    std.debug.print("Benchmarking with:\n", .{});
    std.debug.print("  Database: {s}\n", .{db_path});
    std.debug.print("  Lookups:  {d}\n", .{num_lookups});
    std.debug.print("Opening database...\n", .{});

    const open_start = std.Io.Clock.Timestamp.now(io, .awake);
    var db = try maxminddb.Reader.mmap(allocator, io, db_path, .{ .ipv4_index_first_n_bits = 16 });
    defer db.close();
    const open_elapsed_ns: i64 = @intCast(open_start.untilNow(io).raw.nanoseconds);
    const open_time_ms = @as(f64, @floatFromInt(open_elapsed_ns)) /
        @as(f64, @floatFromInt(std.time.ns_per_ms));
    std.debug.print("Database opened successfully in {d} ms. Type: {s}\n", .{
        open_time_ms,
        db.metadata.database_type,
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    std.debug.print("Starting benchmark...\n", .{});
    const timer_start = std.Io.Clock.Timestamp.now(io, .awake);
    var not_found_count: u64 = 0;
    var lookup_errors: u64 = 0;
    var ip_bytes: [4]u8 = undefined;

    for (0..num_lookups) |_| {
        io.random(&ip_bytes);
        const ip: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = ip_bytes, .port = 0 } };

        const result = db.lookup(
            maxminddb.any.Value,
            arena_allocator,
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

        _ = arena.reset(.retain_capacity);
    }

    const elapsed_ns: i64 = @intCast(timer_start.untilNow(io).raw.nanoseconds);
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
