# Zig MaxMind DB Reader

This Zig package reads the [MaxMind DB format](https://maxmind.github.io/MaxMind-DB/).
It's based on [maxminddb-rust](https://github.com/oschwald/maxminddb-rust) implementation.

⚠️ Note that strings such as `geolite2.City.postal.code` are backed by the memory of an open database file.
You must create a copy if you wish to continue using the string when the database is closed.

You'll need [MaxMind-DB/test-data](https://github.com/maxmind/MaxMind-DB/tree/main/test-data)
to run tests/examples and `GeoLite2-City.mmdb` to run the benchmarks.

```sh
$ git submodule update --init
$ zig build test
$ zig build example_lookup
zh-CN = 瑞典
de = Schweden
pt-BR = Suécia
es = Suecia
en = Sweden
ru = Швеция
fr = Suède
ja = スウェーデン王国
```

## Quick start

Add maxminddb.zig as a dependency in your `build.zig.zon`.

```sh
$ zig fetch --save git+https://github.com/marselester/maxminddb.zig#master
```

Add the `maxminddb` module as a dependency in your `build.zig`:

```zig
const mmdb = b.dependency("maxminddb", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("maxminddb", mmdb.module("maxminddb"));
```

See [examples](./examples/).

## Suggestions

Build the IPv4 index to speed up lookups with `.ipv4_index_first_n_bits` if you have a long-lived `Reader`.
The recommended value is 16 (~320KB fits L2 cache, ~1-4ms to build when warm
and ~10ms-120ms due to page faults) or 12 (~20KB) for constrained devices.

```zig
var db = try maxminddb.Reader.mmap(allocator, db_path, .{ .ipv4_index_first_n_bits = 16 });
defer db.close();
```

Each `lookup` result owns an arena with all decoded allocations.
Call `deinit()` to free it or use `ArenaAllocator` with `reset()`,
see [benchmarks](./benchmarks/lookup.zig).

```zig
if (try db.lookup(maxminddb.geolite2.City, allocator, ip, .{})) |result| {
    defer result.deinit();
    std.debug.print("{f} {s}\n", .{ result.network, result.value.city.names.?.get("en").? });
}

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const arena_allocator = arena.allocator();
for (ips) |ip| {
    if (try db.lookup(maxminddb.geolite2.City, arena_allocator, ip, .{})) |result| {
        std.debug.print("{f} {s}\n", .{ result.network, result.value.city.names.?.get("en").? });
    }

    _ = arena.reset(.retain_capacity);
}
```

If you don't need all the fields, use `.only` to decode only the top-level fields you want.

```zig
const fields = &.{ "city", "country" };
if (try db.lookup(maxminddb.geolite2.City, allocator, ip, .{ .only = fields })) |result| {
    defer result.deinit();
    std.debug.print("{f} {s}\n", .{ result.network, result.value.city.names.?.get("en").? });
}
```

Alternatively, define your own struct with only the fields you need.

```zig
const MyCity = struct {
    city: struct {
        names: struct {
            en: []const u8 = "",
        } = .{},
    } = .{},
};

if (try db.lookup(MyCity, allocator, ip, .{})) |result| {
    defer result.deinit();
    std.debug.print("{s}\n", .{result.value.city.names.en});
}
```

Use `any.Value` to decode any record without knowing the schema.

```zig
if (try db.lookup(maxminddb.any.Value, allocator, ip, .{ .only = fields })) |result| {
    defer result.deinit();
    // Formats as compact JSON.
    std.debug.print("{f}\n", .{result.value});
}
```

Use `lookupWithCache` to skip decoding when different IPs resolve to the same record.
The cache owns decoded memory, so results don't need to be individually freed.

```zig
var cache = try maxminddb.Cache(maxminddb.geolite2.City).init(allocator, .{});
defer cache.deinit();

if (try db.lookupWithCache(maxminddb.geolite2.City, &cache, ip, .{})) |result| {
    std.debug.print("{f} {s}\n", .{ result.network, result.value.city.names.?.get("en").? });
}
```

Use `find` to check if an IP exists without decoding or to separate tree traversal from decoding.

```zig
if (try db.find(ip)) |entry| {
    if (try db.decode(maxminddb.geolite2.City, allocator, entry, .{})) |result| {
        defer result.deinit();
        std.debug.print("{s}\n", .{result.value.city.names.?.get("en").?});
    }
}
```

Here are reference results on Apple M2 Pro (1M random IPv4 lookups against GeoLite2-City
with `ipv4_index_first_n_bits = 16`):

| Type            | Default    | `.only`    | `Cache`    |
|---              |---         |---         |---         |
| `geolite2.City` | ~1,444,000 | ~1,519,000 | ~1,687,000 |
| `MyCity`        | ~1,567,000 |            |            |
| `any.Value`     | ~1,411,000 | ~1,534,000 |            |

<details>

<summary>All fields vs filtered (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

  echo '---'

  for i in $(seq 1 10); do
    zig build benchmark_lookup -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 city \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1336834.7262872674
Lookups Per Second (avg):1451391.9756166148
Lookups Per Second (avg):1465245.0296734683
Lookups Per Second (avg):1477075.9656476441
Lookups Per Second (avg):1455251.2079883837
Lookups Per Second (avg):1480748.4188786792
Lookups Per Second (avg):1455594.8950616007
Lookups Per Second (avg):1444548.4772946609
Lookups Per Second (avg):1445186.5149623165
Lookups Per Second (avg):1426811.8637979662
---
Lookups Per Second (avg):1519486.5596566636
Lookups Per Second (avg):1529797.101878328
Lookups Per Second (avg):1547355.7584052305
Lookups Per Second (avg):1512456.4964197539
Lookups Per Second (avg):1496866.3111260908
Lookups Per Second (avg):1523768.1167895973
Lookups Per Second (avg):1507465.5353845328
Lookups Per Second (avg):1503804.060346153
Lookups Per Second (avg):1526249.4879909921
Lookups Per Second (avg):1526612.3841468173
```

</details>

<details>

<summary>geolite2.City with Cache</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1667393.603034771
Lookups Per Second (avg):1702172.2057832577
Lookups Per Second (avg):1687919.0899495105
Lookups Per Second (avg):1711950.6136486975
Lookups Per Second (avg):1677534.2929947844
Lookups Per Second (avg):1678256.5441289553
Lookups Per Second (avg):1682461.3558984331
Lookups Per Second (avg):1671664.48097093
Lookups Per Second (avg):1679197.6793488073
Lookups Per Second (avg):1711229.9465240643
```

</details>

<details>

<summary>MyCity</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_mycity -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1529492.242988903
Lookups Per Second (avg):1569407.6398299362
Lookups Per Second (avg):1582132.2414254
Lookups Per Second (avg):1571155.8831846418
Lookups Per Second (avg):1555105.2509851856
Lookups Per Second (avg):1563462.4039402052
Lookups Per Second (avg):1575683.5274174165
Lookups Per Second (avg):1592775.9126053287
Lookups Per Second (avg):1587157.672409466
Lookups Per Second (avg):1547889.6749373637
```

</details>

<details>

<summary>All fields vs filtered (any.Value)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_inspect -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

  echo '---'

  for i in $(seq 1 10); do
    zig build benchmark_inspect -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 city \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1340746.319735149
Lookups Per Second (avg):1401828.871364838
Lookups Per Second (avg):1422839.8394335485
Lookups Per Second (avg):1438347.4818876525
Lookups Per Second (avg):1420334.8378589922
Lookups Per Second (avg):1428544.4739779825
Lookups Per Second (avg):1406831.3620695053
Lookups Per Second (avg):1420446.979153165
Lookups Per Second (avg):1436113.5894043539
Lookups Per Second (avg):1391091.5316276387
---
Lookups Per Second (avg):1537147.178300735
Lookups Per Second (avg):1539823.9865696551
Lookups Per Second (avg):1525064.0478860594
Lookups Per Second (avg):1544661.1739143485
Lookups Per Second (avg):1523803.9115671553
Lookups Per Second (avg):1538574.5645160857
Lookups Per Second (avg):1519627.0285774737
Lookups Per Second (avg):1512507.58772119
Lookups Per Second (avg):1547616.3846134257
Lookups Per Second (avg):1555055.2749218142
```

</details>

Use `scan` to iterate over all networks in the database.

```zig
var it = try db.scan(maxminddb.any.Value, allocator, maxminddb.Network.all_ipv6, .{});

while (try it.next()) |item| {
    defer item.deinit();
    std.debug.print("{f} {f}\n", .{ item.network, item.value });
}
```

Use `scanWithCache` to avoid re-decoding networks that share the same record.
The cache owns decoded memory, so results don't need to be individually freed.

```zig
var cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{});
defer cache.deinit();

var it = try db.scanWithCache(maxminddb.any.Value, &cache, maxminddb.Network.all_ipv6, .{});

while (try it.next()) |item| {
    std.debug.print("{f} {f}\n", .{ item.network, item.value });
}
```

Here are reference results on Apple M2 Pro (full GeoLite2-City scan using `any.Value`):

| Mode    | Records/sec |
|---      |---          |
| Default | ~1,288,000  |
| `Cache` | ~3,061,000  |

<details>

<summary>no cache (any.Value)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_scan -Doptimize=ReleaseFast -- GeoLite2-City.mmdb \
      2>&1 | grep 'Records Per Second'
  done

Records Per Second: 1288290.740360951
Records Per Second: 1297969.4219374093
Records Per Second: 1294606.3597480278
Records Per Second: 1292000.0442060304
Records Per Second: 1291402.9663056156
Records Per Second: 1283349.9530272684
Records Per Second: 1285392.657595849
Records Per Second: 1284616.7577796134
Records Per Second: 1282453.2935413013
Records Per Second: 1283224.1123905785
```

</details>

<details>

<summary>cache (any.Value)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_scan_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb \
      2>&1 | grep 'Records Per Second'
  done

Records Per Second: 3028071.506344128
Records Per Second: 3067492.3032345856
Records Per Second: 3068284.064917464
Records Per Second: 3064978.468652021
Records Per Second: 3086129.8223793525
Records Per Second: 3072366.3772443924
Records Per Second: 3059010.4090477442
Records Per Second: 3053284.447089802
Records Per Second: 3057155.2096146354
Records Per Second: 3052158.2348704967
```

</details>
