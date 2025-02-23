const std = @import("std");

pub const Names = std.hash_map.StringHashMap([]const u8);

/// Country represents a record in the GeoLite2-Country database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoLite2-Country-Test.json.
/// It can be used for geolocation at the country-level for analytics, content customization,
/// or compliance use cases in territories that are not disputed.
pub const Country = struct {
    continent: Self.Continent,
    country: Self.Country,
    registered_country: Self.Country,
    represented_country: Self.RepresentedCountry,

    _arena: std.heap.ArenaAllocator,

    const Self = @This();
    pub const Continent = struct {
        code: []const u8 = "",
        geoname_id: u32 = 0,
        names: ?Names = null,
    };
    pub const Country = struct {
        geoname_id: u32 = 0,
        is_in_european_union: bool = false,
        iso_code: []const u8 = "",
        names: ?Names = null,
    };
    pub const RepresentedCountry = struct {
        geoname_id: u32 = 0,
        is_in_european_union: bool = false,
        iso_code: []const u8 = "",
        names: ?Names = null,
        type: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        const arena = std.heap.ArenaAllocator.init(allocator);

        return .{
            .continent = .{},
            .country = .{},
            .registered_country = .{},
            .represented_country = .{},

            ._arena = arena,
        };
    }

    pub fn deinit(self: *const Self) void {
        self._arena.deinit();
    }
};

/// City represents a record in the GeoLite2-City database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoLite2-City-Test.json.
/// It can be used for geolocation down to the city or postal code for analytics and content customization.
pub const City = struct {
    city: Self.City,
    continent: Country.Continent,
    country: Country.Country,
    location: Self.Location,
    postal: Self.Postal,
    registered_country: Country.Country,
    represented_country: Country.RepresentedCountry,
    subdivisions: ?std.ArrayList(Self.Subdivision) = null,

    _arena: std.heap.ArenaAllocator,

    const Self = @This();
    pub const City = struct {
        geoname_id: u32 = 0,
        names: ?Names = null,
    };
    pub const Location = struct {
        accuracy_radius: u16 = 0,
        latitude: f64 = 0,
        longitude: f64 = 0,
        metro_code: u16 = 0,
        time_zone: []const u8 = "",
    };
    pub const Postal = struct {
        code: []const u8 = "",
    };
    pub const Subdivision = struct {
        geoname_id: u32 = 0,
        iso_code: []const u8 = "",
        names: ?Names = null,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        const arena = std.heap.ArenaAllocator.init(allocator);

        return .{
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

    pub fn deinit(self: *const Self) void {
        self._arena.deinit();
    }
};

/// Provides the autonomous system number and organization for IP addresses for analytics,
/// e.g., https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoLite2-ASN-Test.json.
pub const ASN = struct {
    autonomous_system_number: u32 = 0,
    autonomous_system_organization: []const u8 = "",
};
