const std = @import("std");

// City represents a record in the GeoLite2-City database, for example,
// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoLite2-City-Test.json.
pub const City = struct {
    city: struct {
        geoname_id: u32,
        names: std.hash_map.StringHashMap([]const u8),
    },
    continent: struct {
        code: []const u8,
        geoname_id: u32,
        names: std.hash_map.StringHashMap([]const u8),
    },
    country: struct {
        geoname_id: u32,
        is_in_european_union: bool,
        iso_code: []const u8,
        names: std.hash_map.StringHashMap([]const u8),
    },
    location: struct {
        accuracy_radius: u16,
        latitude: f64,
        longitude: f64,
        time_zone: []const u8,
    },
    postal: struct {
        code: []const u8,
    },
    registered_country: struct {
        geoname_id: u32,
        is_in_european_union: bool,
        iso_code: []const u8,
        names: std.hash_map.StringHashMap([]const u8),
    },
    subdivisions: std.ArrayList(struct {
        geoname_id: u32,
        iso_code: []const u8,
        names: std.hash_map.StringHashMap([]const u8),
    }),

    _arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) City {
        const arena = std.heap.ArenaAllocator.init(allocator);

        return City{
            .city = undefined,
            .continent = undefined,
            .country = undefined,
            .location = undefined,
            .postal = undefined,
            .registered_country = undefined,
            .subdivisions = undefined,

            ._arena = arena,
        };
    }

    pub fn deinit(self: *const City) void {
        self._arena.deinit();
    }
};
