const std = @import("std");

const reader = @import("reader.zig");
const decoder = @import("decoder.zig");
const net = @import("net.zig");

pub const geolite2 = @import("geolite2.zig");

pub const Error = reader.ReadError || decoder.DecodeError;
pub const Reader = reader.Reader;
pub const Metadata = reader.Metadata;
pub const Network = net.Network;

test {
    std.testing.refAllDecls(@This());
}

fn expectEqualMaps(
    map: geolite2.StringMap,
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

    try std.testing.expectEqualDeep(geolite2.Country.RepresentedCountry{}, got.represented_country);
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

    try std.testing.expectEqualDeep(
        geolite2.City.Location{
            .accuracy_radius = 76,
            .latitude = 58.4167,
            .longitude = 15.6167,
            .time_zone = "Europe/Stockholm",
        },
        got.location,
    );

    try std.testing.expectEqualDeep(geolite2.City.Postal{}, got.postal);

    try expectEqual(2921044, got.registered_country.geoname_id);
    try expectEqual(true, got.registered_country.is_in_european_union);
    try expectEqualStrings("DE", got.registered_country.iso_code);
    try expectEqualMaps(
        got.registered_country.names.?,
        &.{ "de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN" },
        &.{ "Deutschland", "Germany", "Alemania", "Allemagne", "ドイツ連邦共和国", "Alemanha", "Германия", "德国" },
    );

    try std.testing.expectEqualDeep(geolite2.Country.RepresentedCountry{}, got.represented_country);

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
    try std.testing.expectEqualDeep(want, got);
}
