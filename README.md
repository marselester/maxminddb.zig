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

## Usage

### Lookup

Use `lookup()` for IP lookups in basic cases.
It returns `Result` or null when the IP is not found or the record is empty.
Each result owns an arena so you should call `result.deinit()` to free it.

```zig
var db = try maxminddb.Reader.mmap(allocator, io, db_path, .{});
defer db.close();

if (try db.lookup(maxminddb.geolite2.City, allocator, ip, .{})) |result| {
    defer result.deinit();
    std.debug.print("{f} {s}\n", .{ result.network, result.value.city.names.?.get("en").? });
}
```

Use `.only` to decode only the top-level fields you need.

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
if (try db.lookup(maxminddb.any.Value, allocator, ip, .{})) |result| {
    defer result.deinit();
    // Formats as compact JSON.
    std.debug.print("{f}\n", .{result.value});
}
```

Use `find()` and `Cache.decode()` for repeated lookups, e.g., in web services.
The cache avoids re-decoding when different IPs resolve to the same record.
No per-lookup arena allocation because values are owned by the cache.

⚠️ Use a consistent `.only` field set with the same cache instance to avoid poisoning the cache.

```zig
var cache = try maxminddb.Cache(maxminddb.geolite2.City).init(allocator, .{ .size = 16 });
defer cache.deinit();

const decode_options: maxminddb.Reader.DecodeOptions = .{
    .only = &.{ "city", "country" },
};

for (ips) |ip| {
    const entry = try db.find(ip, .{}) orelse continue;
    const value = try cache.decode(&db, entry, decode_options);
    std.debug.print("{f} {s}\n", .{ entry.network, value.city.names.?.get("en").? });
}
```

Use `find()` to check if an IP exists without decoding.

```zig
if (try db.find(ip, .{})) |entry| {
    std.debug.print("found in {f}\n", .{entry.network});
}
```

Build the IPv4 index to speed up lookups if you have a long-lived `Reader` with many lookups.
It adds a one-time build cost (~1-4ms warm, ~10-120ms with page faults)
and uses ~320KB at depth 16, or 12 (~20KB) for constrained devices.
It's not worth creating an index for short-lived readers.

```zig
var db = try maxminddb.Reader.mmap(allocator, io, db_path, .{ .ipv4_index_first_n_bits = 16 });
defer db.close();
```

For repeated lookups with the same allocator, use `ArenaAllocator` with `reset()`
to avoid per-lookup alloc/free.

```zig
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

⚠️ Don't reset the arena if you use `Cache.init(arena_allocator)` or else
the cached values will be corrupted.

### Scan

Use `scan()` to iterate over networks in the database.
Each result owns an arena so you should call `deinit()` to free it.

```zig
var it = try db.scan(maxminddb.any.Value, allocator, maxminddb.Network.all_ipv6, .{});

while (try it.next()) |item| {
    defer item.deinit();
    std.debug.print("{f} {f}\n", .{ item.network, item.value });
}
```

Use `entries()` and `Cache.decode()` for faster scans, see [Benchmarks](#benchmarks) section.
Adjacent networks often share the same record so the cache avoids re-decoding them.
Same cache caveat applies, i.e., use a consistent `.only` field set.

```zig
var cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{});
defer cache.deinit();

var it = try db.entries(maxminddb.Network.all_ipv6, .{});

while (try it.next()) |entry| {
    const value = try cache.decode(&db, entry, .{});
    std.debug.print("{f} {f}\n", .{ entry.network, value });
}
```

Use `decodeUnmanaged()` with a reusable arena when you only need a subset of networks,
filter on the cheap `entry.network` before paying the decode cost:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const arena_allocator = arena.allocator();

var it = try db.entries(maxminddb.Network.all_ipv4, .{});

while (try it.next()) |entry| {
    // Skip decoding.
    if (entry.network.prefix_len < 24) {
        continue;
    }

    const value = try db.decodeUnmanaged(maxminddb.any.Value, arena_allocator, entry, .{});
    std.debug.print("{f} {f}\n", .{ entry.network, value });
    _ = arena.reset(.retain_capacity);
}
```

## Benchmarks

The impact of each optimization depends on the database:

- Index benefits sparse databases most because tree traversal dominates.
  Dense databases like City still benefit though.
  Index does not help scans at all.
- `.only` helps when decoding is the bottleneck, i.e., databases with large records and many fields.
  Little effect on databases with tiny records.
- `Cache` helps when many IPs resolve to the same record.
  Databases with few unique records benefit most.
  Databases with millions of unique records benefit least because
  almost every lookup is a cache miss.
  For scans, the cache hit rate is much higher because adjacent entries
  in the tree often share the same record.
- `Cache` + `.only`: `.only` helps on cache misses when decoding fewer fields.

Here are reference results on Apple M2 Pro.

### Lookup

1M random IPv4 lookups in GeoLite2-City.

| Optimization              | `geolite2.City` | `MyCity`   | `any.Value` |
|---                        |---              |---         |---          |
| Default                   | ~1,326,000      |            |             |
| Index                     | ~1,559,000      | ~3,875,000 | ~1,411,000  |
| Index + `.only`           | ~3,776,000      |            | ~3,526,000  |
| Index + `Cache`           | ~1,725,000      |            |             |
| Index + `Cache` + `.only` | ~4,399,000      |            |             |

Index means `Reader.Options{ .ipv4_index_first_n_bits = 16 }`.

<details>

<summary>Default vs Index (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 '' 0 \
      2>&1 | grep 'Lookups Per Second'
  done

  echo '---'

  for i in $(seq 1 10); do
    zig build benchmark_lookup -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 '' 16 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1035105.6505787085
Lookups Per Second (avg):1343232.5849613282
Lookups Per Second (avg):1414320.3828140981
Lookups Per Second (avg):1403204.5808096242
Lookups Per Second (avg):1397749.6334335194
Lookups Per Second (avg):1239495.4695665902
Lookups Per Second (avg):1311846.2399504937
Lookups Per Second (avg):1389317.1825729539
Lookups Per Second (avg):1326293.074373302
Lookups Per Second (avg):1397069.5070021125
---
Lookups Per Second (avg):1609554.3144103398
Lookups Per Second (avg):1551616.3615884783
Lookups Per Second (avg):1562781.5253244028
Lookups Per Second (avg):1549749.8760265964
Lookups Per Second (avg):1553338.1374043243
Lookups Per Second (avg):1606371.620343102
Lookups Per Second (avg):1462599.8590053734
Lookups Per Second (avg):1531200.7025148824
Lookups Per Second (avg):1575262.394410654
Lookups Per Second (avg):1589061.3264260693
```

</details>

<details>

<summary>Index vs Index + .only (geolite2.City)</summary>

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

Lookups Per Second (avg):1609554.3144103398
Lookups Per Second (avg):1551616.3615884783
Lookups Per Second (avg):1562781.5253244028
Lookups Per Second (avg):1549749.8760265964
Lookups Per Second (avg):1553338.1374043243
Lookups Per Second (avg):1606371.620343102
Lookups Per Second (avg):1462599.8590053734
Lookups Per Second (avg):1531200.7025148824
Lookups Per Second (avg):1575262.394410654
Lookups Per Second (avg):1589061.3264260693
---
Lookups Per Second (avg):3837828.091414087
Lookups Per Second (avg):3863406.691132952
Lookups Per Second (avg):3631899.1474487204
Lookups Per Second (avg):3868374.68303505
Lookups Per Second (avg):3817877.0773159857
Lookups Per Second (avg):3989842.515290244
Lookups Per Second (avg):3538369.0460390393
Lookups Per Second (avg):3722414.586061188
Lookups Per Second (avg):3635122.737647285
Lookups Per Second (avg):3859718.5300261974
```

</details>

<details>

<summary>Index + Cache (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1652482.1728157594
Lookups Per Second (avg):1804678.8566034087
Lookups Per Second (avg):1719533.2374486062
Lookups Per Second (avg):1694836.616690878
Lookups Per Second (avg):1736597.144251784
Lookups Per Second (avg):1755151.149229094
Lookups Per Second (avg):1767479.3964661632
Lookups Per Second (avg):1802208.2468461858
Lookups Per Second (avg):1643340.813272935
Lookups Per Second (avg):1678393.1576825297
```

</details>

<details>

<summary>Index + Cache + .only (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 city \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):4655800.5527301235
Lookups Per Second (avg):4292970.178049822
Lookups Per Second (avg):4623904.14454354
Lookups Per Second (avg):4447315.433629933
Lookups Per Second (avg):4507954.856600761
Lookups Per Second (avg):4311083.472275961
Lookups Per Second (avg):4367167.417000619
Lookups Per Second (avg):4717858.319912245
Lookups Per Second (avg):4063137.087197969
Lookups Per Second (avg):3997879.1251241216
```

</details>

<details>

<summary>Index (MyCity)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_mycity -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):3574868.3224958642
Lookups Per Second (avg):3712462.9437726922
Lookups Per Second (avg):4215673.875468994
Lookups Per Second (avg):3785552.852435273
Lookups Per Second (avg):4096116.7391959913
Lookups Per Second (avg):3790834.4038207424
Lookups Per Second (avg):4150497.7283101534
Lookups Per Second (avg):3614017.509011327
Lookups Per Second (avg):4065847.0764656705
Lookups Per Second (avg):3743099.2409548718
```

</details>

<details>

<summary>Index vs Index + .only (any.Value)</summary>

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

Lookups Per Second (avg):1372488.367732181
Lookups Per Second (avg):1381428.2973413563
Lookups Per Second (avg):1436810.2525032377
Lookups Per Second (avg):1298657.7295777556
Lookups Per Second (avg):1435992.605534141
Lookups Per Second (avg):1390345.613850623
Lookups Per Second (avg):1481108.8279176715
Lookups Per Second (avg):1429234.491287208
Lookups Per Second (avg):1444525.002072749
Lookups Per Second (avg):1443027.1238867515
---
Lookups Per Second (avg):3711973.1550101433
Lookups Per Second (avg):3450866.4870384834
Lookups Per Second (avg):3503674.1945138867
Lookups Per Second (avg):3561013.662053258
Lookups Per Second (avg):3531490.6660123705
Lookups Per Second (avg):3568312.1477823895
Lookups Per Second (avg):3414696.5486716116
Lookups Per Second (avg):3463143.9870786774
Lookups Per Second (avg):3446752.06486644
Lookups Per Second (avg):3607881.6020832886
```

</details>

### Scan

Full GeoLite2-City scan using `any.Value`.

| Optimization      | `any.Value` |
|---                |---          |
| Default           | ~1,251,000  |
| `.only`           | ~3,985,000  |
| `Cache`           | ~2,941,000  |
| `Cache` + `.only` | ~8,684,000  |

<details>

<summary>Default vs .only (scan)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_scan -Doptimize=ReleaseFast -- GeoLite2-City.mmdb \
      2>&1 | grep 'Records Per Second'
  done

  echo '---'

  for i in $(seq 1 10); do
    zig build benchmark_scan -Doptimize=ReleaseFast -- GeoLite2-City.mmdb city \
      2>&1 | grep 'Records Per Second'
  done

Records Per Second: 1242452.4123182923
Records Per Second: 1243499.0105694628
Records Per Second: 1256255.1086560711
Records Per Second: 1258270.5852588415
Records Per Second: 1258737.4840462913
Records Per Second: 1240246.776441071
Records Per Second: 1254978.5706566381
Records Per Second: 1256865.6957137983
Records Per Second: 1254152.8936018357
Records Per Second: 1243770.9953847837
---
Records Per Second: 4038297.649537256
Records Per Second: 3980863.123692981
Records Per Second: 3987337.158356897
Records Per Second: 3961305.225122879
Records Per Second: 3916544.091235813
Records Per Second: 3976104.5463913656
Records Per Second: 4030883.5208862103
Records Per Second: 3942161.4397791903
Records Per Second: 4013103.2605841225
Records Per Second: 4008183.3987511103
```

</details>

<details>

<summary>Cache vs Cache + .only (scan)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_scan_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb \
      2>&1 | grep 'Records Per Second'
  done

  echo '---'

  for i in $(seq 1 10); do
    zig build benchmark_scan_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb city \
      2>&1 | grep 'Records Per Second'
  done

Records Per Second: 2854843.2443026598
Records Per Second: 2973037.4280465073
Records Per Second: 2964057.4398981016
Records Per Second: 2965855.6226585647
Records Per Second: 2968159.7253859886
Records Per Second: 2922091.105699196
Records Per Second: 2946091.688041803
Records Per Second: 2954772.8941297107
Records Per Second: 2980153.3473268477
Records Per Second: 2883343.2081189225
---
Records Per Second: 8357092.292734527
Records Per Second: 8731200.670444885
Records Per Second: 8764048.778310044
Records Per Second: 8708447.640573917
Records Per Second: 8675092.065399949
Records Per Second: 8741972.179699976
Records Per Second: 8711490.068666434
Records Per Second: 8715545.166671745
Records Per Second: 8708163.382388143
Records Per Second: 8722572.467671666
```

</details>
