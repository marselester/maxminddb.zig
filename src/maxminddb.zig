const std = @import("std");

const reader = @import("reader.zig");
const decoder = @import("decoder.zig");
const net = @import("net.zig");

pub const geolite2 = @import("geolite2.zig");
pub const geoip2 = @import("geoip2.zig");

pub const Error = reader.ReadError || decoder.DecodeError;
pub const Reader = reader.Reader;
pub const Metadata = reader.Metadata;
pub const Network = net.Network;

test {
    std.testing.refAllDecls(@This());
}

fn expectEqualMaps(
    map: std.hash_map.StringHashMap([]const u8),
    keys: []const []const u8,
    values: []const []const u8,
) !void {
    try std.testing.expectEqual(map.count(), keys.len);

    for (keys, values) |key, want_value| {
        const got_value = map.get(key) orelse {
            std.debug.print("map key=\"{s}\" was not found\n", .{key});
            return error.MapKeyNotFound;
        };
        try std.testing.expectEqualStrings(want_value, got_value);
    }
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualDeep = std.testing.expectEqualDeep;

test "GeoLite2 Country" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoLite2-Country-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = try db.lookup(geolite2.Country, &ip);
    defer got.deinit();

    try expectEqualStrings("EU", got.continent.code);
    try expectEqual(6255148, got.continent.geoname_id);
    try expectEqualMaps(
        got.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.country.geoname_id);
    try expectEqual(true, got.country.is_in_european_union);
    try expectEqualStrings("SE", got.country.iso_code);
    try expectEqualMaps(
        got.country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Schweden", "Sweden", "Suecia", "Suède", "スウェーデン王国", "Suécia", "Швеция", "瑞典" },
    );

    try expectEqual(2921044, got.registered_country.geoname_id);
    try expectEqual(true, got.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.registered_country.iso_code);
    try expectEqualMaps(
        got.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geolite2.Country.RepresentedCountry{}, got.represented_country);
}

test "GeoLite2 City" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoLite2-City-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = try db.lookup(geolite2.City, &ip);
    defer got.deinit();

    try expectEqual(2694762, got.city.geoname_id);
    try expectEqualMaps(
        got.city.names.?,
        &.{ "de", "en", "fr", "ja", "zh-CN" },
        &.{ "Linköping", "Linköping", "Linköping", "リンシェーピング", "林雪平" },
    );

    try expectEqualStrings("EU", got.continent.code);
    try expectEqual(6255148, got.continent.geoname_id);
    try expectEqualMaps(
        got.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.country.geoname_id);
    try expectEqual(true, got.country.is_in_european_union);
    try expectEqualStrings("SE", got.country.iso_code);
    try expectEqualMaps(
        got.country.names.?,
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
        got.location,
    );

    try expectEqualDeep(geolite2.City.Postal{}, got.postal);

    try expectEqual(2921044, got.registered_country.geoname_id);
    try expectEqual(true, got.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.registered_country.iso_code);
    try expectEqualMaps(
        got.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geolite2.Country.RepresentedCountry{}, got.represented_country);

    try expectEqual(1, got.subdivisions.?.items.len);
    const sub = got.subdivisions.?.getLast();
    try expectEqual(2685867, sub.geoname_id);
    try expectEqualStrings("E", sub.iso_code);
    try expectEqualMaps(
        sub.names.?,
        &.{ "en", "fr" },
        &.{ "Östergötland County", "Comté d'Östergötland" },
    );
}

test "GeoLite2 ASN" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoLite2-ASN-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = try db.lookup(geolite2.ASN, &ip);

    const want = geolite2.ASN{
        .autonomous_system_number = 29518,
        .autonomous_system_organization = "Bredband2 AB",
    };
    try expectEqualDeep(want, got);
}

test "GeoIP2 Country" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-Country-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = try db.lookup(geoip2.Country, &ip);
    defer got.deinit();

    try expectEqualStrings("EU", got.continent.code);
    try expectEqual(6255148, got.continent.geoname_id);
    try expectEqualMaps(
        got.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.country.geoname_id);
    try expectEqual(true, got.country.is_in_european_union);
    try expectEqualStrings("SE", got.country.iso_code);
    try expectEqualMaps(
        got.country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Schweden", "Sweden", "Suecia", "Suède", "スウェーデン王国", "Suécia", "Швеция", "瑞典" },
    );

    try expectEqual(2921044, got.registered_country.geoname_id);
    try expectEqual(true, got.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.registered_country.iso_code);
    try expectEqualMaps(
        got.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geoip2.Country.RepresentedCountry{}, got.represented_country);

    try expectEqualDeep(
        geoip2.Country.Traits{
            .is_anycast = false,
        },
        got.traits,
    );
}

test "GeoIP2 City" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-City-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("89.160.20.128", 0);
    const got = try db.lookup(geoip2.City, &ip);
    defer got.deinit();

    try expectEqual(2694762, got.city.geoname_id);
    try expectEqualMaps(
        got.city.names.?,
        &.{ "de", "en", "fr", "ja", "zh-CN" },
        &.{ "Linköping", "Linköping", "Linköping", "リンシェーピング", "林雪平" },
    );

    try expectEqualStrings("EU", got.continent.code);
    try expectEqual(6255148, got.continent.geoname_id);
    try expectEqualMaps(
        got.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Europa", "Europe", "Europa", "Europe", "ヨーロッパ", "Europa", "Европа", "欧洲" },
    );

    try expectEqual(2661886, got.country.geoname_id);
    try expectEqual(true, got.country.is_in_european_union);
    try expectEqualStrings("SE", got.country.iso_code);
    try expectEqualMaps(
        got.country.names.?,
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
        got.location,
    );

    try expectEqualDeep(geoip2.City.Postal{}, got.postal);

    try expectEqual(2921044, got.registered_country.geoname_id);
    try expectEqual(true, got.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.registered_country.iso_code);
    try expectEqualMaps(
        got.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try expectEqualDeep(geoip2.Country.RepresentedCountry{}, got.represented_country);

    try expectEqual(1, got.subdivisions.?.items.len);
    const sub = got.subdivisions.?.getLast();
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
        got.traits,
    );
}

test "GeoIP2 Enterprise" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-Enterprise-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("74.209.24.0", 0);
    const got = try db.lookup(geoip2.Enterprise, &ip);
    defer got.deinit();

    try expectEqual(11, got.city.confidence);
    try expectEqual(5112335, got.city.geoname_id);
    try expectEqualMaps(
        got.city.names.?,
        &.{"en"},
        &.{"Chatham"},
    );

    try expectEqualStrings("NA", got.continent.code);
    try expectEqual(6255149, got.continent.geoname_id);
    try expectEqualMaps(
        got.continent.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Nordamerika", "North America", "Norteamérica", "Amérique du Nord", "北アメリカ", "América do Norte", "Северная Америка", "北美洲" },
    );

    try expectEqual(99, got.country.confidence);
    try expectEqual(6252001, got.country.geoname_id);
    try expectEqual(false, got.country.is_in_european_union);
    try expectEqualStrings("US", got.country.iso_code);
    try expectEqualMaps(
        got.country.names.?,
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
        got.location,
    );

    try expectEqualDeep(
        geoip2.Enterprise.Postal{
            .code = "12037",
            .confidence = 11,
        },
        got.postal,
    );

    try expectEqual(6252001, got.registered_country.geoname_id);
    try expectEqual(false, got.registered_country.is_in_european_union);
    try expectEqualStrings("US", got.registered_country.iso_code);
    try expectEqualMaps(
        got.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "USA", "United States", "Estados Unidos", "États-Unis", "アメリカ合衆国", "Estados Unidos", "США", "美国" },
    );

    try expectEqualDeep(geoip2.Enterprise.RepresentedCountry{}, got.represented_country);

    try expectEqual(1, got.subdivisions.?.items.len);
    const sub = got.subdivisions.?.getLast();
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
        got.traits,
    );
}

test "GeoIP2 ISP" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-ISP-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("89.160.20.112", 0);
    const got = try db.lookup(geoip2.ISP, &ip);

    const want = geoip2.ISP{
        .autonomous_system_number = 29518,
        .autonomous_system_organization = "Bredband2 AB",
        .isp = "Bredband2 AB",
        .organization = "Bevtec",
    };
    try expectEqualDeep(want, got);
}

test "GeoIP2 Connection-Type" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-Connection-Type-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("96.1.20.112", 0);
    const got = try db.lookup(geoip2.ConnectionType, &ip);

    const want = geoip2.ConnectionType{
        .connection_type = "Cable/DSL",
    };
    try expectEqualDeep(want, got);
}

test "GeoIP2 Anonymous-IP" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-Anonymous-IP-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("81.2.69.0", 0);
    const got = try db.lookup(geoip2.AnonymousIP, &ip);

    const want = geoip2.AnonymousIP{
        .is_anonymous = true,
        .is_anonymous_vpn = true,
        .is_hosting_provider = true,
        .is_public_proxy = true,
        .is_residential_proxy = true,
        .is_tor_exit_node = true,
    };
    try expectEqualDeep(want, got);
}

test "GeoIP2 DensityIncome" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-DensityIncome-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("5.83.124.123", 0);
    const got = try db.lookup(geoip2.DensityIncome, &ip);

    const want = geoip2.DensityIncome{
        .average_income = 32323,
        .population_density = 1232,
    };
    try expectEqualDeep(want, got);
}

test "GeoIP2 Domain" {
    var db = try Reader.open_mmap(
        std.testing.allocator,
        "test-data/test-data/GeoIP2-Domain-Test.mmdb",
    );
    defer db.close();

    const ip = try std.net.Address.parseIp("66.92.80.123", 0);
    const got = try db.lookup(geoip2.Domain, &ip);

    const want = geoip2.Domain{
        .domain = "speakeasy.net",
    };
    try expectEqualDeep(want, got);
}
