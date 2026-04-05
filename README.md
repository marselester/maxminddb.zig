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
| `geolite2.City` | ~1,420,000 | ~1,348,000 | ~1,565,000 |
| `MyCity`        | ~1,383,000 |            |            |
| `any.Value`     | ~1,254,000 | ~1,349,000 |            |

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

Lookups Per Second (avg):1181277.2875127245
Lookups Per Second (avg):1298229.636700173
Lookups Per Second (avg):1284580.6443966748
Lookups Per Second (avg):1293284.3402910086
Lookups Per Second (avg):1285891.7841541092
Lookups Per Second (avg):1283654.9587741245
Lookups Per Second (avg):1287798.220295312
Lookups Per Second (avg):1291991.2632139924
Lookups Per Second (avg):1282363.8582417285
Lookups Per Second (avg):1246191.3914272592
---
Lookups Per Second (avg):1323980.8070552205
Lookups Per Second (avg):1351732.5910886768
Lookups Per Second (avg):1351039.987754606
Lookups Per Second (avg):1348480.894738865
Lookups Per Second (avg):1357111.6649975393
Lookups Per Second (avg):1348661.0150208646
Lookups Per Second (avg):1357781.4722981465
Lookups Per Second (avg):1356498.714039219
Lookups Per Second (avg):1346452.11429767
Lookups Per Second (avg):1315870.3443053183
```

</details>

<details>

<summary>geolite2.City with Cache</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1493822.3908664712
Lookups Per Second (avg):1503051.0049070602
Lookups Per Second (avg):1499514.437731375
Lookups Per Second (avg):1491749.9700251492
Lookups Per Second (avg):1449924.9391983037
Lookups Per Second (avg):1396100.6211600688
Lookups Per Second (avg):1465750.9875955326
Lookups Per Second (avg):1515611.9396877384
Lookups Per Second (avg):1485235.6423035355
Lookups Per Second (avg):1439334.222943596
```

</details>

<details>

<summary>MyCity</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_mycity -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1405912.7999428671
Lookups Per Second (avg):1376923.8357458028
Lookups Per Second (avg):1372073.1321839818
Lookups Per Second (avg):1378707.359082014
Lookups Per Second (avg):1395492.1172529764
Lookups Per Second (avg):1394880.1743390427
Lookups Per Second (avg):1390645.867575583
Lookups Per Second (avg):1373588.0075019994
Lookups Per Second (avg):1372678.8857965483
Lookups Per Second (avg):1387958.9236387985
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

Lookups Per Second (avg):1249814.6118740842
Lookups Per Second (avg):1225988.817449499
Lookups Per Second (avg):1264197.1313154744
Lookups Per Second (avg):1270859.3015692532
Lookups Per Second (avg):1261325.321815331
Lookups Per Second (avg):1269464.4605490116
Lookups Per Second (avg):1260642.9131866288
Lookups Per Second (avg):1248199.6670115339
Lookups Per Second (avg):1259984.7888336368
Lookups Per Second (avg):1227344.2469651096
---
Lookups Per Second (avg):1366697.6894286321
Lookups Per Second (avg):1359936.8717304142
Lookups Per Second (avg):1350500.9773859177
Lookups Per Second (avg):1345155.3802565804
Lookups Per Second (avg):1354979.4314596548
Lookups Per Second (avg):1363058.6900699302
Lookups Per Second (avg):1351386.2025057953
Lookups Per Second (avg):1360068.193819238
Lookups Per Second (avg):1342324.820976454
Lookups Per Second (avg):1315986.2950186788
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
| Default | ~1,295,000  |
| `Cache` | ~2,930,000  |

<details>

<summary>no cache (any.Value)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_scan -Doptimize=ReleaseFast -- GeoLite2-City.mmdb \
      2>&1 | grep 'Records Per Second'
  done

Records Per Second: 1216758.945145436
Records Per Second: 1238440.9772222256
Records Per Second: 1234710.6362391203
Records Per Second: 1229527.4688849829
Records Per Second: 1243478.3908140333
Records Per Second: 1226863.3718734735
Records Per Second: 1240073.3248202254
Records Per Second: 1247541.1528026997
Records Per Second: 1230510.441029532
Records Per Second: 1246311.587919839
```

</details>

<details>

<summary>cache (any.Value)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_scan_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb \
      2>&1 | grep 'Records Per Second'
  done

Records Per Second: 2847560.3756875996
Records Per Second: 2925388.867798729
Records Per Second: 2919203.9046571665
Records Per Second: 2814410.555872645
Records Per Second: 2933972.04386147
Records Per Second: 2900700.06160036
Records Per Second: 2922279.338699886
Records Per Second: 2862525.847598088
Records Per Second: 2916760.542913819
Records Per Second: 2908245.98918392
```

</details>
