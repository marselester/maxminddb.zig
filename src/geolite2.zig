const std = @import("std");

// City represents a record in the GeoLite2-City database, for example,
// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoLite2-City-Test.json.
pub const City = struct {
    city: struct {
        geoname_id: u32 = 0,
        names: ?std.hash_map.StringHashMap([]const u8) = null,
    },
    continent: struct {
        code: []const u8 = "",
        geoname_id: u32 = 0,
        names: ?std.hash_map.StringHashMap([]const u8) = null,
    },
    country: struct {
        geoname_id: u32 = 0,
        is_in_european_union: bool = false,
        iso_code: []const u8 = "",
        names: ?std.hash_map.StringHashMap([]const u8) = null,
    },
    location: struct {
        accuracy_radius: u16 = 0,
        latitude: f64 = 0,
        longitude: f64 = 0,
        metro_code: u16 = 0,
        time_zone: []const u8 = "",
    },
    postal: struct {
        code: []const u8 = "",
    },
    registered_country: struct {
        geoname_id: u32 = 0,
        is_in_european_union: bool = false,
        iso_code: []const u8 = "",
        names: ?std.hash_map.StringHashMap([]const u8) = null,
    },
    represented_country: struct {
        geoname_id: u32 = 0,
        is_in_european_union: bool = false,
        iso_code: []const u8 = "",
        names: ?std.hash_map.StringHashMap([]const u8) = null,
        type: []const u8 = "",
    },
    subdivisions: ?std.ArrayList(struct {
        geoname_id: u32 = 0,
        iso_code: []const u8 = "",
        names: ?std.hash_map.StringHashMap([]const u8) = null,
    }) = null,

    _arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) City {
        const arena = std.heap.ArenaAllocator.init(allocator);

        return City{
            .city = .{},
            .continent = .{},
            .country = .{},
            .location = .{},
            .postal = .{},
            .registered_country = .{},
            .represented_country = .{},

            ._arena = arena,
        };
    }

    pub fn deinit(self: *const City) void {
        self._arena.deinit();
    }
};
