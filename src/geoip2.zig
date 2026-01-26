const std = @import("std");

pub const Names = std.StringArrayHashMap([]const u8);

/// Country represents a record in the GeoIP2-Country database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-Country-Test.json.
///
/// It can be used for geolocation at the country-level for analytics, content customization,
/// or compliance use cases in territories that are not disputed.
pub const Country = struct {
    continent: Self.Continent,
    country: Self.Country,
    registered_country: Self.Country,
    represented_country: Self.RepresentedCountry,
    traits: Self.Traits,

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
    pub const Traits = struct {
        is_anycast: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        const arena = std.heap.ArenaAllocator.init(allocator);

        return .{
            .continent = .{},
            .country = .{},
            .registered_country = .{},
            .represented_country = .{},
            .traits = .{},

            ._arena = arena,
        };
    }

    pub fn deinit(self: *const Self) void {
        self._arena.deinit();
    }
};

/// City represents a record in the GeoIP2-City database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-City-Test.json.
///
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
    traits: Country.Traits,

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
            .traits = .{},

            ._arena = arena,
        };
    }

    pub fn deinit(self: *const Self) void {
        self._arena.deinit();
    }
};

/// Enterprise represents a record in the GeoIP2-Enterprise database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-Enterprise-Test.json.
/// Determine geolocation data such as country, region, state, city, ZIP/postal code,
/// and additional intelligence such as confidence factors, ISP, domain, and connection type.
pub const Enterprise = struct {
    city: Self.City,
    continent: Self.Continent,
    country: Self.Country,
    location: Self.Location,
    postal: Self.Postal,
    registered_country: Self.Country,
    represented_country: Self.RepresentedCountry,
    subdivisions: ?std.ArrayList(Self.Subdivision) = null,
    traits: Self.Traits,

    _arena: std.heap.ArenaAllocator,

    const Self = @This();
    pub const City = struct {
        confidence: u16 = 0,
        geoname_id: u32 = 0,
        names: ?Names = null,
    };
    pub const Continent = struct {
        code: []const u8 = "",
        geoname_id: u32 = 0,
        names: ?Names = null,
    };
    pub const Country = struct {
        confidence: u16 = 0,
        geoname_id: u32 = 0,
        is_in_european_union: bool = false,
        iso_code: []const u8 = "",
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
        confidence: u16 = 0,
    };
    pub const RepresentedCountry = struct {
        geoname_id: u32 = 0,
        is_in_european_union: bool = false,
        iso_code: []const u8 = "",
        names: ?Names = null,
        type: []const u8 = "",
    };
    pub const Subdivision = struct {
        confidence: u16 = 0,
        geoname_id: u32 = 0,
        iso_code: []const u8 = "",
        names: ?Names = null,
    };
    pub const Traits = struct {
        autonomous_system_number: u32 = 0,
        autonomous_system_organization: []const u8 = "",
        connection_type: []const u8 = "",
        domain: []const u8 = "",
        is_anycast: bool = false,
        is_legitimate_proxy: bool = false,
        isp: []const u8 = "",
        mobile_country_code: []const u8 = "",
        mobile_network_code: []const u8 = "",
        organization: []const u8 = "",
        static_ip_score: f64 = 0,
        user_type: []const u8 = "",
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
            .traits = .{},

            ._arena = arena,
        };
    }

    pub fn deinit(self: *const Self) void {
        self._arena.deinit();
    }
};

/// ISP represents a record in the GeoIP2-ISP database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-ISP-Test.json.
/// Determine the Internet Service Provider, organization name, and autonomous system organization
/// and number associated with an IP address.
pub const ISP = struct {
    autonomous_system_number: u32 = 0,
    autonomous_system_organization: []const u8 = "",
    isp: []const u8 = "",
    mobile_country_code: []const u8 = "",
    mobile_network_code: []const u8 = "",
    organization: []const u8 = "",
};

/// ConnectionType represents a record in the GeoIP2-Connection-Type database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-Connection-Type-Test.json.
/// Determine the connection type of your visitors based on their IP address.
/// The database identifies cellular, cable/DSL, and corporate connection speeds.
pub const ConnectionType = struct {
    connection_type: []const u8 = "",
};

/// AnonymousIP represents a record in the GeoIP2-Anonymous-IP database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-Anonymous-IP-Test.json.
/// It helps protect your business by identifying proxy, VPN, hosting, and other anonymous IP addresses.
pub const AnonymousIP = struct {
    is_anonymous: bool = false,
    is_anonymous_vpn: bool = false,
    is_hosting_provider: bool = false,
    is_public_proxy: bool = false,
    is_residential_proxy: bool = false,
    is_tor_exit_node: bool = false,
};

/// DensityIncome represents a record in the GeoIP2-DensityIncome database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-DensityIncome-Test.json.
pub const DensityIncome = struct {
    average_income: u32 = 0,
    population_density: u32 = 0,
};

/// Domain represents a record in the GeoIP2-Domain database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-Domain-Test.json.
/// Look up the second level domain names associated with IPv4 and IPv6 addresses.
pub const Domain = struct {
    domain: []const u8 = "",
};

/// AnonymousPlus represents a record in the GeoIP-Anonymous-Plus database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP-Anonymous-Plus-Test.json.
/// It extends AnonymousIP with additional fields like provider name and confidence scores.
pub const AnonymousPlus = struct {
    anonymizer_confidence: u16 = 0,
    is_anonymous: bool = false,
    is_anonymous_vpn: bool = false,
    is_hosting_provider: bool = false,
    is_public_proxy: bool = false,
    is_residential_proxy: bool = false,
    is_tor_exit_node: bool = false,
    network_last_seen: []const u8 = "",
    provider_name: []const u8 = "",
};

/// IPRisk represents a record in the GeoIP2-IP-Risk database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-IP-Risk-Test.json.
/// It provides a risk score for an IP address along with anonymous IP indicators.
pub const IPRisk = struct {
    anonymizer_confidence: u16 = 0,
    ip_risk: f64 = 0,
    is_anonymous: bool = false,
    is_anonymous_vpn: bool = false,
    is_hosting_provider: bool = false,
    is_public_proxy: bool = false,
    is_residential_proxy: bool = false,
    is_tor_exit_node: bool = false,
    network_last_seen: []const u8 = "",
    provider_name: []const u8 = "",
};

/// StaticIPScore represents a record in the GeoIP2-Static-IP-Score database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-Static-IP-Score-Test.json.
/// It indicates how static or dynamic an IP address assignment is (0-99.99).
pub const StaticIPScore = struct {
    score: f64 = 0,
};

/// UserCount represents a record in the GeoIP2-User-Count database, for example,
/// https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-User-Count-Test.json.
/// It provides estimated user counts for IP address ranges at various prefix lengths.
pub const UserCount = struct {
    ipv4_24: u32 = 0,
    ipv4_32: u32 = 0,
    ipv6_32: u32 = 0,
    ipv6_48: u32 = 0,
    ipv6_64: u32 = 0,
};
