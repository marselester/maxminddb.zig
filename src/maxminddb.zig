const std = @import("std");

const reader = @import("reader.zig");
const cache = @import("cache.zig");
const collection = @import("collection.zig");
const net = @import("net.zig");
const filter = @import("filter.zig");
const errors = @import("errors.zig");

pub const any = @import("any.zig");
pub const lazy = @import("lazy.zig");
pub const geolite2 = @import("geolite2.zig");
pub const geoip2 = @import("geoip2.zig");

pub const Reader = reader.Reader;
pub const Metadata = reader.Metadata;
pub const DecodedIterator = reader.DecodedIterator;
pub const NetworkIterator = reader.NetworkIterator;
pub const Cache = cache.Cache;
pub const Error = errors.Error;
pub const ErrorCategory = errors.ErrorCategory;
pub const errorCategory = errors.errorCategory;
pub const Network = net.Network;
pub const Map = collection.Map;
pub const Array = collection.Array;
pub const Fields = filter.Fields;

/// Maps the metadata.database_type to a known GeoLite/GeoIP record type.
pub const DatabaseType = enum {
    geolite_city,
    geolite_country,
    geolite_asn,
    geoip_city,
    geoip_country,
    geoip_enterprise,
    geoip_isp,
    geoip_connection_type,
    geoip_anonymous_ip,
    geoip_anonymous_plus,
    geoip_ip_risk,
    geoip_densityincome,
    geoip_domain,
    geoip_static_ip_score,
    geoip_user_count,
    geoip_regions,
    geoip_residential_proxy,

    pub fn new(database_type: []const u8) ?DatabaseType {
        var db_type_snake: [64]u8 = undefined;
        if (database_type.len >= db_type_snake.len) {
            return null;
        }

        // Convert hyphen-separated words to snake_case, skipping product variant decorators.
        // Shield and Precision variants use the same schemas as their base types.
        var i: usize = 0;
        var it = std.mem.splitScalar(u8, database_type, '-');
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "Shield") or std.mem.eql(u8, part, "Precision")) {
                continue;
            }

            if (i > 0) {
                db_type_snake[i] = '_';
                i += 1;
            }

            for (part) |c| {
                switch (c) {
                    'a'...'z' => {
                        db_type_snake[i] = c;
                        i += 1;
                    },
                    'A'...'Z' => {
                        db_type_snake[i] = std.ascii.toLower(c);
                        i += 1;
                    },
                    else => continue,
                }
            }
        }

        return std.meta.stringToEnum(DatabaseType, db_type_snake[0..i]);
    }

    /// Returns the record type corresponding to the GeoLite/GeoIP database type.
    pub fn recordType(self: DatabaseType) type {
        return switch (self) {
            .geolite_city => geolite2.City,
            .geolite_country => geolite2.Country,
            .geolite_asn => geolite2.ASN,
            .geoip_city => geoip2.City,
            .geoip_country => geoip2.Country,
            .geoip_enterprise => geoip2.Enterprise,
            .geoip_isp => geoip2.ISP,
            .geoip_connection_type => geoip2.ConnectionType,
            .geoip_anonymous_ip => geoip2.AnonymousIP,
            .geoip_anonymous_plus => geoip2.AnonymousPlus,
            .geoip_ip_risk => geoip2.IPRisk,
            .geoip_densityincome => geoip2.DensityIncome,
            .geoip_domain => geoip2.Domain,
            .geoip_static_ip_score => geoip2.StaticIPScore,
            .geoip_user_count => geoip2.UserCount,
            .geoip_regions => geoip2.Regions,
            .geoip_residential_proxy => geoip2.ResidentialProxy,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("schema_test.zig");
}

fn decodeAll(path: []const u8) !usize {
    var db = try Reader.mmap(allocator, io, path, .{});
    defer db.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var count: usize = 0;
    var it = try db.networks(null, .{});
    while (try it.next()) |result| : (count += 1) {
        _ = try db.decodeUnmanaged(any.Value, arena.allocator(), result, .{});
    }

    return count;
}

const allocator = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectError = std.testing.expectError;

test "open and mmap return the OS error for a bad path" {
    const tests = [_]struct {
        path: []const u8,
        want: anyerror,
    }{
        .{
            .path = "test-data/test-data/does-not-exist.mmdb",
            .want = error.FileNotFound,
        },
        .{
            .path = "test-data",
            .want = error.IsDir,
        },
    };

    for (tests) |tc| {
        try expectError(tc.want, Reader.open(allocator, io, tc.path, .{}));
        try expectError(tc.want, Reader.mmap(allocator, io, tc.path, .{}));
    }
}

test "Reader.decodeMetadata" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const meta = try db.decodeMetadata(arena.allocator());
    try expectEqualStrings("GeoLite2-City", meta.get("database_type").?.string);
    try expectEqual(6, meta.get("ip_version").?.uint16);
    try expectEqual(2, meta.get("binary_format_major_version").?.uint16);
}

test "reject metadata with a non-string database_type" {
    const src = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test-data/test-data/MaxMind-DB-test-ipv4-24.mmdb",
        allocator,
        .limited(4096),
    );
    defer allocator.free(src);

    const key = "database_type";
    const value = std.mem.findLast(u8, src, key).? + key.len;
    try expectEqual(0x44, src[value]);
    src[value] = 0xC4;

    try expectError(
        error.InvalidMetadata,
        Reader.openBytes(allocator, src, .{}),
    );
}

test "reject a database with broken pointers" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-test-broken-pointers-24.mmdb",
        .{},
    );
    defer db.close();

    var it = try db.scan(any.Value, allocator, net.Network.all_ipv4, .{});
    while (it.next() catch |err| {
        try expectEqual(error.InvalidPointer, err);
        return;
    }) |result| {
        result.deinit();
    }

    return error.TestExpectedBrokenPointer;
}

test "strict off decodes a valid database identically" {
    var strictOn = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoIP2-City-Test.mmdb",
        .{ .strict = true },
    );
    defer strictOn.close();
    var strictOff = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoIP2-City-Test.mmdb",
        .{ .strict = false },
    );
    defer strictOff.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var iterStrictOn = try strictOn.networks(null, .{});
    var iterStrictOff = try strictOff.networks(null, .{});
    var n: usize = 0;
    while (try iterStrictOn.next()) |resStrictOn| {
        const resStrictOff = (try iterStrictOff.next()).?;
        try expectEqual(resStrictOn.pointer, resStrictOff.pointer);

        const valStrictOn = try strictOn.decodeUnmanaged(
            any.Value,
            arena.allocator(),
            resStrictOn,
            .{},
        );
        const valStrictOff = try strictOff.decodeUnmanaged(
            any.Value,
            arena.allocator(),
            resStrictOff,
            .{},
        );

        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena.allocator(), "{f}", .{valStrictOn}),
            try std.fmt.allocPrint(arena.allocator(), "{f}", .{valStrictOff}),
        );

        n += 1;
    }

    try expectEqual(null, try iterStrictOff.next());
    try expect(n > 0);
}

test "decoder resource limit" {
    const tests = [_]struct {
        path: []const u8,
        want: ?anyerror,
    }{
        .{
            .path = "test-data/test-data/MaxMind-DB-test-decoder-value-limit.mmdb",
            .want = null,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-decoder-value-limit-over.mmdb",
            .want = error.TooManyValues,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-decoder-value-limit-pointer-heavy.mmdb",
            .want = null,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-decoder-payload-limit.mmdb",
            .want = null,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-decoder-payload-limit-over.mmdb",
            .want = error.PayloadTooLarge,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-pointer-decoder-dos.mmdb",
            .want = error.TooManyValues,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-pointer-decoder-dos-ipv6.mmdb",
            .want = error.TooManyValues,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-payload-amplification-dos.mmdb",
            .want = error.PayloadTooLarge,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-payload-amplification-dos-string.mmdb",
            .want = error.PayloadTooLarge,
        },
        .{
            .path = "test-data/test-data/MaxMind-DB-test-payload-amplification-dos-worst-case.mmdb",
            .want = error.PayloadTooLarge,
        },
    };

    for (tests) |tc| {
        if (tc.want) |want| {
            try expectError(want, decodeAll(tc.path));
        } else {
            const n = try decodeAll(tc.path);
            try expect(n > 0);
        }
    }
}

test "path lookup shares one budget with the value it selects" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-test-decode-path-shared-budget.mmdb",
        .{},
    );
    defer db.close();

    var it = try db.networks(null, .{});
    const result = (try it.next()).?;
    try expectError(
        error.PayloadTooLarge,
        db.getPath(result, &.{"target"}),
    );
}

test "reject metadata whose payload exceeds the limit" {
    try expectError(
        error.PayloadTooLarge,
        Reader.mmap(
            allocator,
            io,
            "test-data/test-data/MaxMind-DB-test-metadata-payload-limit.mmdb",
            .{},
        ),
    );
}

test "each bad-data fixture decodes fully or fails with its known error" {
    const tests = [_]struct {
        path: []const u8,
        want: ?anyerror,
    }{
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-corrupt-search-tree.mmdb",
            .want = null,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-deep-array-nesting.mmdb",
            .want = error.TooDeep,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-deep-nesting.mmdb",
            .want = error.TooDeep,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-empty-array-last-in-metadata.mmdb",
            .want = null,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-empty-map-last-in-metadata.mmdb",
            .want = null,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-metadata-marker-only.mmdb",
            .want = error.InvalidDataOffset,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-offset-integer-overflow.mmdb",
            .want = error.InvalidPointer,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-oversized-array.mmdb",
            .want = error.InvalidDataOffset,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-oversized-map.mmdb",
            .want = error.InvalidDataOffset,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-separator-record-max-left.mmdb",
            .want = error.CorruptedTree,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-separator-record-min-left.mmdb",
            .want = error.CorruptedTree,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-separator-record-min-right.mmdb",
            .want = error.CorruptedTree,
        },
        .{
            .path = "test-data/bad-data/libmaxminddb/libmaxminddb-uint64-max-epoch.mmdb",
            .want = null,
        },
        .{
            .path = "test-data/bad-data/maxminddb-golang/cyclic-data-structure.mmdb",
            .want = error.InvalidDataOffset,
        },
        .{
            .path = "test-data/bad-data/maxminddb-golang/invalid-bytes-length.mmdb",
            .want = error.InvalidDataOffset,
        },
        .{
            .path = "test-data/bad-data/maxminddb-golang/invalid-data-record-offset.mmdb",
            .want = error.UnknownFieldType,
        },
        .{
            .path = "test-data/bad-data/maxminddb-golang/invalid-map-key-length.mmdb",
            .want = error.InvalidDataOffset,
        },
        .{
            .path = "test-data/bad-data/maxminddb-golang/invalid-string-length.mmdb",
            .want = error.InvalidDataOffset,
        },
        .{
            .path = "test-data/bad-data/maxminddb-golang/metadata-is-an-uint128.mmdb",
            .want = error.InvalidMetadata,
        },
        .{
            .path = "test-data/bad-data/maxminddb-golang/unexpected-bytes.mmdb",
            .want = error.InvalidMetadata,
        },
        .{
            .path = "test-data/bad-data/maxminddb-python/bad-unicode-in-map-key.mmdb",
            .want = error.CorruptedTree,
        },
    };

    for (tests) |tc| {
        if (tc.want) |want| {
            try expectError(want, decodeAll(tc.path));
        } else {
            _ = try decodeAll(tc.path);
        }
    }
}

test "a broken search tree reports InvalidTreeNode from lookup and from iteration" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-test-broken-search-tree-24.mmdb",
        .{},
    );
    defer db.close();

    // 255.255.255.255 is the one address whose path reaches the broken node.
    const ip = try std.Io.net.IpAddress.parse("255.255.255.255", 0);
    try expectError(error.InvalidTreeNode, db.lookup(ip, .{}));

    var it = try db.networks(null, .{});
    while (true) {
        _ = (it.next() catch |err| {
            try expectEqual(error.InvalidTreeNode, err);
            break;
        }) orelse return error.TestExpectedError;
    }
}

test "reject a map key that is not a string" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/bad-data/maxminddb-python/bad-unicode-in-map-key.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("163.254.149.39", 0);
    const result = (try db.lookup(ip, .{})).?;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try expectError(
        error.InvalidMapKey,
        db.decodeUnmanaged(any.Value, arena.allocator(), result, .{}),
    );
}

test "decode every MMDB data type" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-test-decoder.mmdb",
        .{},
    );
    defer db.close();

    // 1.1.1.0 holds a mid-range value of every type.
    {
        const ip = try std.Io.net.IpAddress.parse("1.1.1.0", 0);
        const result = (try db.query(any.Value, allocator, ip, .{})).?;
        defer result.deinit();
        const v = result.value;

        try expectEqualStrings("unicode! ☯ - ♫", v.get("utf8_string").?.string);
        try expectEqual(true, v.get("boolean").?.boolean);
        try expectEqual(@as(u16, 100), v.get("uint16").?.uint16);
        try expectEqual(@as(u32, 268435456), v.get("uint32").?.uint32);
        try expectEqual(@as(i32, -268435456), v.get("int32").?.int32);
        try expectEqual(@as(u64, 1152921504606846976), v.get("uint64").?.uint64);
        try expectEqual(
            @as(u128, 1329227995784915872903807060280344576),
            v.get("uint128").?.uint128,
        );
        try expectEqual(@as(f64, 42.123456), v.get("double").?.double);
        try expectEqual(@as(f32, 1.1), v.get("float").?.float);

        try std.testing.expectEqualSlices(
            u8,
            "\x00\x00\x00\x2a",
            v.get("bytes").?.bytes,
        );

        const array = v.get("array").?.array;
        try expectEqual(@as(usize, 3), array.len);
        try expectEqual(@as(u32, 1), array[0].uint32);
        try expectEqual(@as(u32, 2), array[1].uint32);
        try expectEqual(@as(u32, 3), array[2].uint32);

        // Nested map, and an array nested inside it.
        const map_x = v.get("map").?.get("mapX").?;
        try expectEqualStrings("hello", map_x.get("utf8_stringX").?.string);

        const array_x = map_x.get("arrayX").?.array;
        try expectEqual(@as(usize, 3), array_x.len);
        try expectEqual(@as(u32, 7), array_x[0].uint32);
        try expectEqual(@as(u32, 9), array_x[2].uint32);
    }

    // 255.255.255.255 holds the type maxima plus float/double infinity.
    {
        const ip = try std.Io.net.IpAddress.parse("255.255.255.255", 0);
        const result = (try db.query(any.Value, allocator, ip, .{})).?;
        defer result.deinit();
        const v = result.value;

        try expectEqual(@as(u16, 65535), v.get("uint16").?.uint16);
        try expectEqual(@as(u32, 4294967295), v.get("uint32").?.uint32);
        try expectEqual(@as(i32, 2147483647), v.get("int32").?.int32);
        try expectEqual(@as(u64, 18446744073709551615), v.get("uint64").?.uint64);
        try expectEqual(
            @as(u128, 340282366920938463463374607431768211455),
            v.get("uint128").?.uint128,
        );
        try expectEqual(std.math.inf(f64), v.get("double").?.double);
        try expectEqual(std.math.inf(f32), v.get("float").?.float);
    }
}

test "typed decode surfaces a type error for each mismatched field" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-test-decoder.mmdb",
        .{},
    );
    defer db.close();

    // 1.1.1.0 holds one field of every wire type.
    // Declaring a field with the right name but a wrong Zig type returns a schema error.
    const ip = try std.Io.net.IpAddress.parse("1.1.1.0", 0);
    const tests = .{
        // Scalar wire value decoded into the wrong scalar type.
        .{
            struct { uint32: u16 = 0 },
            error.ExpectedUint16,
        },
        .{
            struct { uint16: u32 = 0 },
            error.ExpectedUint32,
        },
        .{
            struct { uint32: i32 = 0 },
            error.ExpectedInt32,
        },
        .{
            struct { uint32: u64 = 0 },
            error.ExpectedUint64,
        },
        .{
            struct { uint32: u128 = 0 },
            error.ExpectedUint128,
        },
        .{
            struct { uint32: bool = false },
            error.ExpectedBool,
        },
        .{
            struct { float: f64 = 0 },
            error.ExpectedDouble,
        },
        .{
            struct { double: f32 = 0 },
            error.ExpectedFloat,
        },
        .{
            struct { uint32: []const u8 = "" },
            error.ExpectedStringOrBytes,
        },
        // Scalar wire value decoded into an aggregate type.
        .{
            struct { uint32: struct {} = .{} },
            error.ExpectedStructType,
        },
        .{
            struct { uint32: Map(u32) = .{} },
            error.ExpectedMap,
        },
        .{
            struct { uint32: Array(u32) = .{} },
            error.ExpectedArray,
        },
        .{
            struct { uint32: i64 = 0 },
            error.UnsupportedType,
        },
    };

    inline for (tests) |tc| {
        try expectError(
            tc[1],
            db.query(tc[0], allocator, ip, .{}),
        );

        try expectEqual(.schema, errorCategory(tc[1]));
    }
}

test "reject invalid metadata" {
    try expectError(
        error.MetadataStartNotFound,
        Reader.openBytes(allocator, "not a valid mmdb", .{}),
    );
}

test "reject an empty file the same way on every open path" {
    try expectError(error.EmptyFile, Reader.openBytes(allocator, "", .{}));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "empty.mmdb", .{});
    file.close(io);

    const path = try tmp.dir.realPathFileAlloc(io, "empty.mmdb", allocator);
    defer allocator.free(path);

    try expectError(error.EmptyFile, Reader.open(allocator, io, path, .{}));
    try expectError(error.EmptyFile, Reader.mmap(allocator, io, path, .{}));
}

test "Reader.open" {
    var db = try Reader.open(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const got = (try db.query(geolite2.City, allocator, ip, .{})).?;
    defer got.deinit();

    try expectEqualStrings("SE", got.value.country.iso_code);
}

test "reject index bits > 24" {
    try expectError(error.InvalidIndexBits, Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{ .ipv4_index_first_n_bits = 25 },
    ));
}

test "reject invalid prefix length" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    try expectError(error.InvalidPrefixLen, db.networks(.{
        .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 0),
        .prefix_len = 33,
    }, .{}));
}

test "reject invalid node count" {
    try expectError(
        error.CorruptedTree,
        Reader.mmap(allocator, io, "test-data/test-data/GeoIP2-City-Test-Invalid-Node-Count.mmdb", .{}),
    );
}

test "reject IPv6 on IPv4-only database" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-test-ipv4-32.mmdb",
        .{},
    );
    defer db.close();

    const network = try net.Network.parse("::/0");
    const it = db.scan(any.Value, allocator, network, .{});
    try expectError(error.IPv6AddressInIPv4Database, it);

    const ip = try std.Io.net.IpAddress.parse("2001:db8::1", 0);
    const result = db.query(any.Value, allocator, ip, .{});
    try expectError(error.IPv6AddressInIPv4Database, result);
}

test DatabaseType {
    var db_type = DatabaseType.new("unknown db type!");
    try expectEqual(null, db_type);

    // Testing a long db type.
    db_type = DatabaseType.new("v" ** 64);
    try expectEqual(null, db_type);

    db_type = DatabaseType.new("GeoLite2-City");
    try expectEqual(DatabaseType.geolite_city, db_type);

    switch (db_type.?) {
        inline DatabaseType.geolite_city => |dt| {
            try expectEqual(geolite2.City, dt.recordType());
        },
        else => {
            return error.TestUnexpectedDatabaseType;
        },
    }

    // Shield variants map to their base types.
    try expectEqual(DatabaseType.geoip_city, DatabaseType.new("GeoIP2-City-Shield"));
    try expectEqual(DatabaseType.geoip_country, DatabaseType.new("GeoIP2-Country-Shield"));
    try expectEqual(DatabaseType.geoip_enterprise, DatabaseType.new("GeoIP2-Enterprise-Shield"));

    // Precision variants map to their base types.
    try expectEqual(DatabaseType.geoip_enterprise, DatabaseType.new("GeoIP2-Precision-Enterprise"));
    try expectEqual(DatabaseType.geoip_enterprise, DatabaseType.new("GeoIP2-Precision-Enterprise-Shield"));
}

test "query with field name filtering" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);

    const got = (try db.query(
        geolite2.City,
        allocator,
        ip,
        .{ .only = &.{ "city", "country" } },
    )).?;
    defer got.deinit();

    // Filtered fields are decoded.
    try expectEqual(2694762, got.value.city.geoname_id);
    try expectEqual(2661886, got.value.country.geoname_id);
    try expectEqualStrings("SE", got.value.country.iso_code);

    // Non-filtered fields remain at defaults.
    try expectEqualStrings("", got.value.continent.code);
    try expectEqual(0, got.value.continent.geoname_id);
    try expectEqualDeep(geolite2.City.Location{}, got.value.location);
    try expectEqualDeep(geolite2.City.Postal{}, got.value.postal);
}

test "query with custom record" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const MyCity = struct {
        city: struct {
            geoname_id: u32 = 0,
            names: struct {
                en: []const u8 = "",
            } = .{},
        } = .{},
    };

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const got = (try db.query(MyCity, allocator, ip, .{})).?;
    defer got.deinit();

    try expectEqual(2694762, got.value.city.geoname_id);
    try expectEqualStrings("Linköping", got.value.city.names.en);
}

test "query with any.Value" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const got = (try db.query(any.Value, allocator, ip, .{})).?;
    defer got.deinit();

    const city = got.value.get("city").?;
    try expectEqual(2694762, city.get("geoname_id").?.uint32);

    const names = city.get("names").?;
    try expectEqualStrings("Linköping", names.get("en").?.string);

    const country = got.value.get("country").?;
    try expectEqualStrings("SE", country.get("iso_code").?.string);
    try expectEqual(true, country.get("is_in_european_union").?.boolean);
}

test "query with any.Value and field name filtering" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const got = (try db.query(
        any.Value,
        allocator,
        ip,
        .{ .only = &.{ "city", "country" } },
    )).?;
    defer got.deinit();

    // Filtered fields are decoded.
    const city = got.value.get("city").?;
    try expectEqual(2694762, city.get("geoname_id").?.uint32);

    const country = got.value.get("country").?;
    try expectEqualStrings("SE", country.get("iso_code").?.string);

    // Non-filtered fields are absent.
    try expectEqual(null, got.value.get("continent"));
    try expectEqual(null, got.value.get("location"));
}

test "IPv4 index matches non-indexed find" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    var db_idx = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{ .ipv4_index_first_n_bits = 16 },
    );
    defer db_idx.close();

    for ([_][]const u8{
        "89.160.20.128",
        "175.16.199.0",
        "216.160.83.56",
        "2001:218::",
        "0.0.0.0",
        "255.255.255.255",
    }) |ip_str| {
        const ip = try std.Io.net.IpAddress.parse(ip_str, 0);
        const result1 = try db.lookup(ip, .{});
        const result2 = try db_idx.lookup(ip, .{});

        if (result1) |r1| {
            const r2 = result2.?;
            try expectEqual(r1.pointer, r2.pointer);
            try expectEqual(r1.network.prefix_len, r2.network.prefix_len);
        } else {
            try expect(result2 == null);
        }
    }
}

test "scan returns all networks" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    var it = try db.scan(geolite2.City, allocator, net.Network.all_ipv6, .{});

    var n: usize = 0;
    while (try it.next()) |item| : (n += 1) {
        item.deinit();
    }

    try expectEqual(242, n);
}

test "scan yields record when query prefix is narrower than record network" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-ASN-Test.mmdb",
        .{},
    );
    defer db.close();

    // 89.160.20.0/24 is inside the /17 record.
    // The iterator must still yield it even though the data record is found
    // before exhausting the 24-bit prefix.
    const network = try net.Network.parse("89.160.20.0/24");
    var it = try db.scan(any.Value, allocator, network, .{});

    const item = (try it.next()) orelse return error.TestExpectedNotNull;
    defer item.deinit();
    try expectEqual(17, item.network.prefix_len);

    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try item.network.format(&w);
    try expectEqualStrings("89.160.0.0/17", out[0..w.end]);

    if (try it.next()) |i| {
        i.deinit();
        return error.TestExpectedNull;
    }
}

test "scan yields record when start node is a data pointer" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-no-ipv4-search-tree.mmdb",
        .{},
    );
    defer db.close();

    const network = try net.Network.parse("0.0.0.0/0");
    var it = try db.scan(any.Value, allocator, network, .{});

    const item = (try it.next()) orelse return error.TestExpectedNotNull;
    defer item.deinit();
    try expectEqual(0, item.network.prefix_len);

    if (try it.next()) |i| {
        i.deinit();
        return error.TestExpectedNull;
    }
}

test "lookup skips empty records by default" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoIP2-Anonymous-IP-Test.mmdb",
        .{},
    );
    defer db.close();

    // 1.0.0.1 is in the db but its record is empty.
    const ip = try std.Io.net.IpAddress.parse("1.0.0.1", 0);

    // Empty records are skipped by default.
    try expect(try db.lookup(ip, .{}) == null);

    try expect((try db.lookup(ip, .{ .include_empty_values = true })) != null);
}

test "scan skips empty records" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoIP2-Anonymous-IP-Test.mmdb",
        .{},
    );
    defer db.close();

    // All records including empty.
    {
        var it = try db.scan(geoip2.AnonymousIP, allocator, net.Network.all_ipv6, .{
            .include_empty_values = true,
        });

        var n: usize = 0;
        while (try it.next()) |item| : (n += 1) {
            item.deinit();
        }
        try expectEqual(599, n);
    }

    // Only non-empty records.
    {
        var it = try db.scan(geoip2.AnonymousIP, allocator, net.Network.all_ipv6, .{
            .include_empty_values = false,
        });

        var n: usize = 0;
        while (try it.next()) |item| : (n += 1) {
            item.deinit();
        }
        try expectEqual(12, n);
    }
}

test "getPath with an empty path returns a map at the record root" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result = (try db.lookup(ip, .{})).?;

    const root = (try db.getPath(result, &.{})).?;
    try expect(root == .map);
    try expect(root.map.len > 0);
}

test "getPath walks map-key paths to each scalar variant" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result = (try db.lookup(ip, .{})).?;

    const iso = (try db.getPath(result, &.{ "country", "iso_code" })).?;
    try expect(iso == .string);
    try expectEqualStrings("SE", iso.string);

    const gid = (try db.getPath(result, &.{ "country", "geoname_id" })).?;
    try expect(gid == .uint32);
    try expectEqual(2661886, gid.uint32);

    const in_eu = (try db.getPath(result, &.{ "country", "is_in_european_union" })).?;
    try expect(in_eu == .boolean);
    try expectEqual(true, in_eu.boolean);

    const lat = (try db.getPath(result, &.{ "location", "latitude" })).?;
    try expect(lat == .double);
    try expectEqual(@as(f64, 58.4167), lat.double);
}

test "getPath returns null for unresolved paths" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result = (try db.lookup(ip, .{})).?;

    try expectEqual(null, try db.getPath(result, &.{"nonexistent"}));
    try expectEqual(null, try db.getPath(result, &.{ "country", "nonexistent" }));
    try expectEqual(null, try db.getPath(result, &.{ "country", "iso_code", "nope" }));
}

test "Array.at and Array.len" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result = (try db.lookup(ip, .{})).?;

    const subs_v = (try db.getPath(result, &.{"subdivisions"})).?;
    try expect(subs_v == .array);
    const subs = subs_v.array;
    try expectEqual(1, subs.len);

    const first_v = (try subs.at(0)).?;
    try expect(first_v == .map);
    const first = first_v.map;

    const sub_iso = (try first.get("iso_code")).?;
    try expect(sub_iso == .string);
    try expectEqualStrings("E", sub_iso.string);

    try expectEqual(null, try subs.at(1));
}

test "lazy Map.get on a nested map" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result = (try db.lookup(ip, .{})).?;

    const names_v = (try db.getPath(result, &.{ "country", "names" })).?;
    try expect(names_v == .map);
    const names = names_v.map;

    const en = (try names.get("en")).?;
    try expect(en == .string);
    try expectEqualStrings("Sweden", en.string);

    try expectEqual(null, try names.get("zz"));
}

test "getPath indexes into arrays" {
    var db = try Reader.mmap(
        allocator,
        io,
        "test-data/test-data/MaxMind-DB-test-decoder.mmdb",
        .{},
    );
    defer db.close();

    const ip = try std.Io.net.IpAddress.parse("1.1.1.0", 0);
    const result = (try db.lookup(ip, .{})).?;

    const tests = [_]struct {
        path: []const []const u8,
        want: ?u32,
    }{
        .{
            .path = &.{ "array", "2" },
            .want = 3,
        },
        .{
            .path = &.{ "array", "-1" },
            .want = 3,
        },
        .{
            .path = &.{ "array", "-3" },
            .want = 1,
        },
        .{
            .path = &.{ "map", "mapX", "arrayX", "0" },
            .want = 7,
        },
        .{
            .path = &.{ "array", "9" },
            .want = null,
        },
        .{
            .path = &.{ "array", "-4" },
            .want = null,
        },
        .{
            .path = &.{ "array", "x" },
            .want = null,
        },
        .{
            .path = &.{ "array", "99999999999999999999" },
            .want = null,
        },
    };

    for (tests) |tc| {
        const got = try db.getPath(result, tc.path);
        try expectEqual(tc.want, if (got) |v| v.uint32 else null);
    }
}
