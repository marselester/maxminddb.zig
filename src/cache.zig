const std = @import("std");

const Reader = @import("reader.zig").Reader;

/// Ring buffer cache of recently decoded records.
/// The cache owns the memory that backs decoded values,
/// so each value is valid until its slot is evicted.
///
/// The default size of 16 is good for most databases.
/// Country databases benefit from larger sizes, e.g., 64 or larger.
pub fn Cache(comptime T: type) type {
    return struct {
        slots: []Slot,
        // Number of slots in use.
        filled: usize = 0,
        // Index in the slots array where the next record will be written.
        write_pos: usize = 0,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub const Error = error{
            InvalidCacheSize,
        };
        pub const InitError = Error || std.mem.Allocator.Error;

        pub const Options = struct {
            size: usize = 16,
        };

        const Slot = struct {
            pointer: Reader.DataPointer,
            value: T,
            arena: std.heap.ArenaAllocator,
        };

        pub fn init(allocator: std.mem.Allocator, options: Self.Options) InitError!Self {
            if (options.size == 0) {
                return error.InvalidCacheSize;
            }

            return .{
                .slots = try allocator.alloc(Slot, options.size),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.reset();
            self.allocator.free(self.slots);
        }

        /// Drops every cached record, freeing arenas, and leaves the cache
        /// ready to refill at the same capacity.
        /// Use when the decode filter changes and cached trees are stale.
        pub fn reset(self: *Self) void {
            for (self.slots[0..self.filled]) |*slot| {
                slot.arena.deinit();
            }

            self.filled = 0;
            self.write_pos = 0;
        }

        /// Returns a cached value for the given data pointer, or null on cache miss.
        pub fn get(self: *Self, pointer: Reader.DataPointer) ?T {
            for (self.slots[0..self.filled]) |*slot| {
                if (slot.pointer == pointer) {
                    return slot.value;
                }
            }

            return null;
        }

        /// Decodes a record, using the cache to avoid redundant decoding.
        /// Returns the cached value on hit, or decodes and caches on miss.
        /// The cache owns the decoded memory.
        /// The returned value is valid until its slot is evicted or cache.deinit() is called.
        pub fn decode(
            self: *Self,
            db: *const Reader,
            result: Reader.Result,
            options: Reader.DecodeOptions,
        ) Reader.DecodeError!T {
            if (self.get(result.pointer)) |v| {
                return v;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();

            const value = try db.decodeUnmanaged(T, arena.allocator(), result, options);

            self.insert(.{
                .pointer = result.pointer,
                .value = value,
                .arena = arena,
            });

            return value;
        }

        fn insert(self: *Self, slot: Slot) void {
            if (self.filled < self.slots.len) {
                self.slots[self.filled] = slot;
                self.filled += 1;

                return;
            }

            // Evict the oldest record and take its slot.
            self.slots[self.write_pos].arena.deinit();
            self.slots[self.write_pos] = slot;
            self.write_pos = (self.write_pos + 1) % self.slots.len;
        }
    };
}

const geolite2 = @import("geolite2.zig");

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "cache hit returns same value" {
    var db = try Reader.mmap(
        std.testing.allocator,
        std.testing.io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    var c = try Cache(geolite2.City).init(std.testing.allocator, .{ .size = 4 });
    defer c.deinit();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result = (try db.lookup(ip, .{})).?;

    // Cache miss, decodes.
    const v1 = try c.decode(&db, result, .{});
    try expectEqualStrings("SE", v1.country.iso_code);

    // Cache hit, same pointer.
    const v2 = try c.decode(&db, result, .{});
    try expectEqualStrings("SE", v2.country.iso_code);

    const v3 = c.get(result.pointer).?;
    try expectEqualStrings("SE", v3.country.iso_code);
}

test "cache eviction" {
    var db = try Reader.mmap(
        std.testing.allocator,
        std.testing.io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    // Size 1: every new result evicts the previous one.
    var c = try Cache(geolite2.City).init(std.testing.allocator, .{ .size = 1 });
    defer c.deinit();

    const ip1 = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result1 = (try db.lookup(ip1, .{})).?;
    _ = try c.decode(&db, result1, .{});
    try expect(c.get(result1.pointer) != null);

    const ip2 = try std.Io.net.IpAddress.parse("2001:218::", 0);
    const result2 = (try db.lookup(ip2, .{})).?;
    _ = try c.decode(&db, result2, .{});

    // result1 is evicted.
    try expect(c.get(result1.pointer) == null);
    try expect(c.get(result2.pointer) != null);
}

test "cache ring buffer wrap-around" {
    var db = try Reader.mmap(
        std.testing.allocator,
        std.testing.io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    var c = try Cache(geolite2.City).init(std.testing.allocator, .{ .size = 2 });
    defer c.deinit();

    const ip1 = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const ip2 = try std.Io.net.IpAddress.parse("2001:218::", 0);
    const ip3 = try std.Io.net.IpAddress.parse("216.160.83.56", 0);

    const result1 = (try db.lookup(ip1, .{})).?;
    const result2 = (try db.lookup(ip2, .{})).?;
    const result3 = (try db.lookup(ip3, .{})).?;

    _ = try c.decode(&db, result1, .{});
    _ = try c.decode(&db, result2, .{});
    // Cache is full now, so the next insert evicts result1.
    _ = try c.decode(&db, result3, .{});

    try expect(c.get(result1.pointer) == null);
    try expect(c.get(result2.pointer) != null);
    try expect(c.get(result3.pointer) != null);
}

test "cache decode with field filtering" {
    var db = try Reader.mmap(
        std.testing.allocator,
        std.testing.io,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
        .{},
    );
    defer db.close();

    var c = try Cache(geolite2.City).init(std.testing.allocator, .{ .size = 4 });
    defer c.deinit();

    const ip = try std.Io.net.IpAddress.parse("89.160.20.128", 0);
    const result = (try db.lookup(ip, .{})).?;

    const v = try c.decode(&db, result, .{ .only = &.{"city"} });
    try expectEqualStrings("Linköping", v.city.names.?.get("en").?);
    // Country was not decoded.
    try expectEqualStrings("", v.country.iso_code);
}

test "cache rejects size 0" {
    try expectError(
        error.InvalidCacheSize,
        Cache(geolite2.City).init(std.testing.allocator, .{ .size = 0 }),
    );
}
