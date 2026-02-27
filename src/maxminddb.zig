const std = @import("std");

const reader = @import("reader.zig");
const decoder = @import("decoder.zig");
const collection = @import("collection.zig");
const net = @import("net.zig");

pub const any = @import("any.zig");
pub const geolite2 = @import("geolite2.zig");
pub const geoip2 = @import("geoip2.zig");

pub const Error = reader.ReadError || decoder.DecodeError;
pub const Reader = reader.Reader;
pub const Result = reader.Result;
pub const Metadata = reader.Metadata;
pub const Iterator = reader.Iterator;
pub const Network = net.Network;
pub const Options = reader.Options;
pub const Map = collection.Map;
pub const Array = collection.Array;

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

    pub fn new(database_type: []const u8) ?DatabaseType {
        var db_type_snake: [64]u8 = undefined;
        if (database_type.len >= db_type_snake.len) {
            return null;
        }

        var i: usize = 0;
        for (database_type) |c| {
            switch (c) {
                'a'...'z' => {
                    db_type_snake[i] = c;
                    i += 1;
                },
                'A'...'Z' => {
                    db_type_snake[i] = std.ascii.toLower(c);
                    i += 1;
                },
                '-' => {
                    db_type_snake[i] = '_';
                    i += 1;
                },
                else => continue,
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
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}

fn expectEqualMaps(
    map: anytype,
    keys: []const []const u8,
    values: []const []const u8,
) !void {
    try std.testing.expectEqual(map.entries.len, keys.len);

    for (keys, values) |key, want_value| {
        const got_value = map.get(key) orelse {
            std.debug.print("map key=\"{s}\" was not found\n", .{key});
            return error.MapKeyNotFound;
        };
        try std.testing.expectEqualStrings(want_value, got_value);
    }
}

const allocator = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualDeep = std.testing.expectEqualDeep;

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
}

test "GeoLite2 Country" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-Country-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geolite_country, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(allocator, geolite2.Country, ip, .{})).?;
    defer got.deinit();

    try expectEqualStrings("EU", got.value.continent.code);
    try expectEqual(6255148, got.value.continent.geoname_id);
    try expectEqualMaps(
        got.value.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.value.country.geoname_id);
    try expectEqual(true, got.value.country.is_in_european_union);
    try expectEqualStrings("SE", got.value.country.iso_code);
    try expectEqualMaps(
        got.value.country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Schweden", "Sweden", "Suecia", "Suède", "スウェーデン王国", "Suécia", "Швеция", "瑞典" },
    );

    try expectEqual(2921044, got.value.registered_country.geoname_id);
    try expectEqual(true, got.value.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.value.registered_country.iso_code);
    try expectEqualMaps(
        got.value.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geolite2.Country.RepresentedCountry{}, got.value.represented_country);

    // Verify network masking for an IPv6 lookup.
    const ipv6 = try std.net.Address.parseIp("2001:218:ffff:ffff:ffff:ffff:ffff:ffff", 0);
    const got_v6 = (try db.lookup(allocator, geolite2.Country, ipv6, .{})).?;
    defer got_v6.deinit();

    try expectEqualStrings("JP", got_v6.value.country.iso_code);

    var buf: [64]u8 = undefined;
    const got_network = try std.fmt.bufPrint(&buf, "{f}", .{got_v6.network});
    try expectEqualStrings("2001:0218:0000:0000:0000:0000:0000:0000/32", got_network);
}

test "GeoLite2 City" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geolite_city, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(allocator, geolite2.City, ip, .{})).?;
    defer got.deinit();

    try expectEqual(2694762, got.value.city.geoname_id);
    try expectEqualMaps(
        got.value.city.names.?,
        &.{ "de", "en", "fr", "ja", "zh-CN" },
        &.{ "Linköping", "Linköping", "Linköping", "リンシェーピング", "林雪平" },
    );

    try expectEqualStrings("EU", got.value.continent.code);
    try expectEqual(6255148, got.value.continent.geoname_id);
    try expectEqualMaps(
        got.value.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.value.country.geoname_id);
    try expectEqual(true, got.value.country.is_in_european_union);
    try expectEqualStrings("SE", got.value.country.iso_code);
    try expectEqualMaps(
        got.value.country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Schweden", "Sweden", "Suecia", "Suède", "スウェーデン王国", "Suécia", "Швеция", "瑞典" },
    );

    try expectEqualDeep(
        geolite2.City.Location{
            .accuracy_radius = 76,
            .latitude = 58.4167,
            .longitude = 15.6167,
            .time_zone = "Europe/Stockholm",
        },
        got.value.location,
    );

    try expectEqualDeep(geolite2.City.Postal{}, got.value.postal);

    try expectEqual(2921044, got.value.registered_country.geoname_id);
    try expectEqual(true, got.value.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.value.registered_country.iso_code);
    try expectEqualMaps(
        got.value.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geolite2.Country.RepresentedCountry{}, got.value.represented_country);

    try expectEqual(1, got.value.subdivisions.?.items.len);
    const sub = got.value.subdivisions.?.items[0];
    try expectEqual(2685867, sub.geoname_id);
    try expectEqualStrings("E", sub.iso_code);
    try expectEqualMaps(
        sub.names.?,
        &.{ "en", "fr" },
        &.{ "Östergötland County", "Comté d'Östergötland" },
    );
}

test "GeoLite2 ASN" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-ASN-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geolite_asn, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(allocator, geolite2.ASN, ip, .{})).?;
    defer got.deinit();

    const want = geolite2.ASN{
        .autonomous_system_number = 29518,
        .autonomous_system_organization = "Bredband2 AB",
    };
    try expectEqualDeep(want, got.value);

    var buf: [64]u8 = undefined;
    const got_network = try std.fmt.bufPrint(&buf, "{f}", .{got.network});
    try expectEqualStrings("89.160.0.0/17", got_network);
}

test "GeoIP2 Country" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-Country-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_country, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(allocator, geoip2.Country, ip, .{})).?;
    defer got.deinit();

    try expectEqualStrings("EU", got.value.continent.code);
    try expectEqual(6255148, got.value.continent.geoname_id);
    try expectEqualMaps(
        got.value.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.value.country.geoname_id);
    try expectEqual(true, got.value.country.is_in_european_union);
    try expectEqualStrings("SE", got.value.country.iso_code);
    try expectEqualMaps(
        got.value.country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Schweden", "Sweden", "Suecia", "Suède", "スウェーデン王国", "Suécia", "Швеция", "瑞典" },
    );

    try expectEqual(2921044, got.value.registered_country.geoname_id);
    try expectEqual(true, got.value.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.value.registered_country.iso_code);
    try expectEqualMaps(
        got.value.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geoip2.Country.RepresentedCountry{}, got.value.represented_country);

    try expectEqualDeep(
        geoip2.Country.Traits{
            .is_anycast = false,
        },
        got.value.traits,
    );

    const ip2 = try std.net.Address.parseIp("214.1.1.0", 0);
    const got2 = (try db.lookup(allocator, geoip2.Country, ip2, .{})).?;
    defer got2.deinit();

    try expectEqual(true, got2.value.traits.is_anycast);
}

test "GeoIP2 Country RepresentedCountry" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-Country-Test.mmdb",
    );
    defer db.unmap();

    const ip = try std.net.Address.parseIp("202.196.224.0", 0);
    const got = (try db.lookup(allocator, geoip2.Country, ip, .{})).?;
    defer got.deinit();

    try expectEqualStrings("AS", got.value.continent.code);
    try expectEqual(6255147, got.value.continent.geoname_id);

    try expectEqual(1694008, got.value.country.geoname_id);
    try expectEqualStrings("PH", got.value.country.iso_code);

    try expectEqual(1694008, got.value.registered_country.geoname_id);
    try expectEqualStrings("PH", got.value.registered_country.iso_code);

    try expectEqual(6252001, got.value.represented_country.geoname_id);
    try expectEqualStrings("US", got.value.represented_country.iso_code);
    try expectEqualStrings("military", got.value.represented_country.type);
}

test "GeoIP2 City" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-City-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_city, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(allocator, geoip2.City, ip, .{})).?;
    defer got.deinit();

    try expectEqual(2694762, got.value.city.geoname_id);
    try expectEqualMaps(
        got.value.city.names.?,
        &.{ "de", "en", "fr", "ja", "zh-CN" },
        &.{ "Linköping", "Linköping", "Linköping", "リンシェーピング", "林雪平" },
    );

    try expectEqualStrings("EU", got.value.continent.code);
    try expectEqual(6255148, got.value.continent.geoname_id);
    try expectEqualMaps(
        got.value.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.value.country.geoname_id);
    try expectEqual(true, got.value.country.is_in_european_union);
    try expectEqualStrings("SE", got.value.country.iso_code);
    try expectEqualMaps(
        got.value.country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Schweden", "Sweden", "Suecia", "Suède", "スウェーデン王国", "Suécia", "Швеция", "瑞典" },
    );

    try expectEqualDeep(
        geoip2.City.Location{
            .accuracy_radius = 76,
            .latitude = 58.4167,
            .longitude = 15.6167,
            .time_zone = "Europe/Stockholm",
        },
        got.value.location,
    );

    try expectEqualDeep(geoip2.City.Postal{}, got.value.postal);

    try expectEqual(2921044, got.value.registered_country.geoname_id);
    try expectEqual(true, got.value.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.value.registered_country.iso_code);
    try expectEqualMaps(
        got.value.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geoip2.Country.RepresentedCountry{}, got.value.represented_country);

    try expectEqual(1, got.value.subdivisions.?.items.len);
    const sub = got.value.subdivisions.?.items[0];
    try expectEqual(2685867, sub.geoname_id);
    try expectEqualStrings("E", sub.iso_code);
    try expectEqualMaps(
        sub.names.?,
        &.{ "en", "fr" },
        &.{ "Östergötland County", "Comté d'Östergötland" },
    );

    try expectEqualDeep(
        geoip2.Country.Traits{
            .is_anycast = false,
        },
        got.value.traits,
    );

    const ip2 = try std.net.Address.parseIp("214.1.1.0", 0);
    const got2 = (try db.lookup(allocator, geoip2.City, ip2, .{})).?;
    defer got2.deinit();

    try expectEqual(true, got2.value.traits.is_anycast);
}

test "GeoIP2 Enterprise" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-Enterprise-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_enterprise, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("74.209.24.0", 0);
    const got = (try db.lookup(allocator, geoip2.Enterprise, ip, .{})).?;
    defer got.deinit();

    try expectEqual(11, got.value.city.confidence);
    try expectEqual(5112335, got.value.city.geoname_id);
    try expectEqualMaps(
        got.value.city.names.?,
        &.{"en"},
        &.{"Chatham"},
    );

    try expectEqualStrings("NA", got.value.continent.code);
    try expectEqual(6255149, got.value.continent.geoname_id);
    try expectEqualMaps(
        got.value.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Nordamerika", "North America", "Norteamérica", "Amérique du Nord", "北アメリカ", "América do Norte", "Северная Америка", "北美洲" },
    );

    try expectEqual(99, got.value.country.confidence);
    try expectEqual(6252001, got.value.country.geoname_id);
    try expectEqual(false, got.value.country.is_in_european_union);
    try expectEqualStrings("US", got.value.country.iso_code);
    try expectEqualMaps(
        got.value.country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "USA", "United States", "Estados Unidos", "États-Unis", "アメリカ合衆国", "Estados Unidos", "США", "美国" },
    );

    try expectEqualDeep(
        geoip2.Enterprise.Location{
            .accuracy_radius = 27,
            .latitude = 42.3478,
            .longitude = -73.5549,
            .metro_code = 532,
            .time_zone = "America/New_York",
        },
        got.value.location,
    );

    try expectEqualDeep(
        geoip2.Enterprise.Postal{
            .code = "12037",
            .confidence = 11,
        },
        got.value.postal,
    );

    try expectEqual(6252001, got.value.registered_country.geoname_id);
    try expectEqual(false, got.value.registered_country.is_in_european_union);
    try expectEqualStrings("US", got.value.registered_country.iso_code);
    try expectEqualMaps(
        got.value.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "USA", "United States", "Estados Unidos", "États-Unis", "アメリカ合衆国", "Estados Unidos", "США", "美国" },
    );

    try expectEqualDeep(geoip2.Enterprise.RepresentedCountry{}, got.value.represented_country);

    try expectEqual(1, got.value.subdivisions.?.items.len);
    const sub = got.value.subdivisions.?.items[0];
    try expectEqual(93, sub.confidence);
    try expectEqual(5128638, sub.geoname_id);
    try expectEqualStrings("NY", sub.iso_code);
    try expectEqualMaps(
        sub.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "New York", "New York", "Nueva York", "New York", "ニューヨーク州", "Nova Iorque", "Нью-Йорк", "纽约州" },
    );

    try expectEqualDeep(
        geoip2.Enterprise.Traits{
            .autonomous_system_number = 14671,
            .autonomous_system_organization = "FairPoint Communications",
            .connection_type = "Cable/DSL",
            .domain = "frpt.net",
            .is_legitimate_proxy = true,
            .isp = "Fairpoint Communications",
            .organization = "Fairpoint Communications",
            .static_ip_score = 0.34,
            .user_type = "residential",
        },
        got.value.traits,
    );

    const ip2 = try std.net.Address.parseIp("214.1.1.0", 0);
    const got2 = (try db.lookup(allocator, geoip2.Enterprise, ip2, .{})).?;
    defer got2.deinit();

    try expectEqual(true, got2.value.traits.is_anycast);
}

test "GeoIP2 ISP" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-ISP-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_isp, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("149.101.100.0", 0);
    const got = (try db.lookup(allocator, geoip2.ISP, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.ISP{
        .autonomous_system_number = 6167,
        .autonomous_system_organization = "CELLCO-PART",
        .isp = "Verizon Wireless",
        .mobile_country_code = "310",
        .mobile_network_code = "004",
        .organization = "Verizon Wireless",
    };
    try expectEqualDeep(want, got.value);
}

test "GeoIP2 Connection-Type" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-Connection-Type-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_connection_type, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("96.1.20.112", 0);
    const got = (try db.lookup(allocator, geoip2.ConnectionType, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.ConnectionType{
        .connection_type = "Cable/DSL",
    };
    try expectEqualDeep(want, got.value);
}

test "GeoIP2 Anonymous-IP" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-Anonymous-IP-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_anonymous_ip, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("81.2.69.0", 0);
    const got = (try db.lookup(allocator, geoip2.AnonymousIP, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.AnonymousIP{
        .is_anonymous = true,
        .is_anonymous_vpn = true,
        .is_hosting_provider = true,
        .is_public_proxy = true,
        .is_residential_proxy = true,
        .is_tor_exit_node = true,
    };
    try expectEqualDeep(want, got.value);
}

test "GeoIP Anonymous-Plus" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP-Anonymous-Plus-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_anonymous_plus, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("1.2.0.1", 0);
    const got = (try db.lookup(allocator, geoip2.AnonymousPlus, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.AnonymousPlus{
        .anonymizer_confidence = 30,
        .is_anonymous = true,
        .is_anonymous_vpn = true,
        .network_last_seen = "2025-04-14",
        .provider_name = "foo",
    };
    try expectEqualDeep(want, got.value);
}

test "GeoIP2 DensityIncome" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-DensityIncome-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_densityincome, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("5.83.124.123", 0);
    const got = (try db.lookup(allocator, geoip2.DensityIncome, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.DensityIncome{
        .average_income = 32323,
        .population_density = 1232,
    };
    try expectEqualDeep(want, got.value);
}

test "GeoIP2 Domain" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-Domain-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_domain, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("66.92.80.123", 0);
    const got = (try db.lookup(allocator, geoip2.Domain, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.Domain{
        .domain = "speakeasy.net",
    };
    try expectEqualDeep(want, got.value);
}

test "GeoIP2 IP-Risk" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-IP-Risk-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_ip_risk, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("6.1.2.1", 0);
    const got = (try db.lookup(allocator, geoip2.IPRisk, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.IPRisk{
        .anonymizer_confidence = 95,
        .ip_risk = 75,
        .is_anonymous = true,
        .is_anonymous_vpn = true,
        .network_last_seen = "2025-01-15",
        .provider_name = "Test VPN Service",
    };
    try expectEqualDeep(want, got.value);

    const ip2 = try std.net.Address.parseIp("214.2.3.5", 0);
    const got2 = (try db.lookup(allocator, geoip2.IPRisk, ip2, .{})).?;
    defer got2.deinit();

    const want2 = geoip2.IPRisk{
        .ip_risk = 90,
        .is_anonymous = true,
        .is_anonymous_vpn = true,
        .is_residential_proxy = true,
        .is_tor_exit_node = true,
    };
    try expectEqualDeep(want2, got2.value);
}

test "GeoIP2 Static-IP-Score" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-Static-IP-Score-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_static_ip_score, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("1.2.3.4", 0);
    const got = (try db.lookup(allocator, geoip2.StaticIPScore, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.StaticIPScore{
        .score = 0.05,
    };
    try expectEqualDeep(want, got.value);
}

test "GeoIP2 User-Count" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoIP2-User-Count-Test.mmdb",
    );
    defer db.unmap();

    try expectEqual(DatabaseType.geoip_user_count, DatabaseType.new(db.metadata.database_type));

    const ip = try std.net.Address.parseIp("1.2.3.4", 0);
    const got = (try db.lookup(allocator, geoip2.UserCount, ip, .{})).?;
    defer got.deinit();

    const want = geoip2.UserCount{
        .ipv4_24 = 4,
        .ipv4_32 = 3,
    };
    try expectEqualDeep(want, got.value);
}

test "lookup with field name filtering" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
    );
    defer db.unmap();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);

    const got = (try db.lookup(
        allocator,
        geolite2.City,
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

test "lookup with custom record" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
    );
    defer db.unmap();

    const MyCity = struct {
        city: struct {
            geoname_id: u32 = 0,
            names: struct {
                en: []const u8 = "",
            } = .{},
        } = .{},
    };

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(allocator, MyCity, ip, .{})).?;
    defer got.deinit();

    try expectEqual(2694762, got.value.city.geoname_id);
    try expectEqualStrings("Linköping", got.value.city.names.en);
}

test "lookup with any.Value" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
    );
    defer db.unmap();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(allocator, any.Value, ip, .{})).?;
    defer got.deinit();

    const city = got.value.get("city").?;
    try expectEqual(2694762, city.get("geoname_id").?.uint32);

    const names = city.get("names").?;
    try expectEqualStrings("Linköping", names.get("en").?.string);

    const country = got.value.get("country").?;
    try expectEqualStrings("SE", country.get("iso_code").?.string);
    try expectEqual(true, country.get("is_in_european_union").?.boolean);
}

test "lookup with any.Value and field name filtering" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
    );
    defer db.unmap();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = (try db.lookup(
        allocator,
        any.Value,
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

test "within returns all networks" {
    var db = try Reader.mmap(
        allocator,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
    );
    defer db.unmap();

    var it = try db.within(allocator, geolite2.City, net.Network.all_ipv6, .{});
    defer it.deinit();

    var n: usize = 0;
    while (try it.next()) |_| : (n += 1) {}

    try expectEqual(242, n);
}
