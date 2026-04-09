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
var db = try maxminddb.Reader.mmap(allocator, db_path, .{});
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
var db = try maxminddb.Reader.mmap(allocator, db_path, .{ .ipv4_index_first_n_bits = 16 });
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
| Default                   | ~1,293,000      |            |             |
| Index                     | ~1,454,000      | ~1,511,000 | ~1,438,000  |
| Index + `.only`           | ~1,531,000      |            | ~1,528,000  |
| Index + `Cache`           | ~1,650,000      |            |             |
| Index + `Cache` + `.only` | ~1,792,000      |            |             |

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

Lookups Per Second (avg):1288123.6986424406
Lookups Per Second (avg):1297844.4971600326
Lookups Per Second (avg):1299800.7833033653
Lookups Per Second (avg):1289163.7206031256
Lookups Per Second (avg):1296087.9427189995
Lookups Per Second (avg):1293914.0954956787
Lookups Per Second (avg):1304671.4413292515
Lookups Per Second (avg):1259770.3727349874
Lookups Per Second (avg):1299818.3136058154
Lookups Per Second (avg):1304484.7981250943
---
Lookups Per Second (avg):1428547.0249066802
Lookups Per Second (avg):1380507.1016736578
Lookups Per Second (avg):1424615.0690083539
Lookups Per Second (avg):1479872.0734649224
Lookups Per Second (avg):1470581.8382631212
Lookups Per Second (avg):1452131.834013217
Lookups Per Second (avg):1441057.419112997
Lookups Per Second (avg):1460678.0011842097
Lookups Per Second (avg):1469818.5626422924
Lookups Per Second (avg):1427603.971951151
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

Lookups Per Second (avg):1428547.0249066802
Lookups Per Second (avg):1380507.1016736578
Lookups Per Second (avg):1424615.0690083539
Lookups Per Second (avg):1479872.0734649224
Lookups Per Second (avg):1470581.8382631212
Lookups Per Second (avg):1452131.834013217
Lookups Per Second (avg):1441057.419112997
Lookups Per Second (avg):1460678.0011842097
Lookups Per Second (avg):1469818.5626422924
Lookups Per Second (avg):1427603.971951151
---
Lookups Per Second (avg):1480631.763363951
Lookups Per Second (avg):1547402.0513766634
Lookups Per Second (avg):1522023.2008449882
Lookups Per Second (avg):1512118.8782619492
Lookups Per Second (avg):1507072.3128425558
Lookups Per Second (avg):1524512.3489753657
Lookups Per Second (avg):1564611.0025010307
Lookups Per Second (avg):1518824.4053660445
Lookups Per Second (avg):1559368.5734912506
Lookups Per Second (avg):1571173.0594097849
```

</details>

<details>

<summary>Index + Cache (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1621097.9412664056
Lookups Per Second (avg):1643755.6794738034
Lookups Per Second (avg):1689941.621422972
Lookups Per Second (avg):1619515.4855034132
Lookups Per Second (avg):1635409.8950475699
Lookups Per Second (avg):1667425.4591913386
Lookups Per Second (avg):1624120.681573548
Lookups Per Second (avg):1663304.0203721477
Lookups Per Second (avg):1669982.860181014
Lookups Per Second (avg):1667252.0583156152
```

</details>

<details>

<summary>Index + Cache + .only (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 city \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1778201.5145052548
Lookups Per Second (avg):1843785.5733650513
Lookups Per Second (avg):1775074.2749654094
Lookups Per Second (avg):1787008.1402384518
Lookups Per Second (avg):1673250.9089935562
Lookups Per Second (avg):1780556.2368656157
Lookups Per Second (avg):1795938.4381684947
Lookups Per Second (avg):1796003.7580157353
Lookups Per Second (avg):1853067.3542248248
Lookups Per Second (avg):1837493.7370404094
```

</details>

<details>

<summary>Index (MyCity)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_mycity -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1538491.815980477
Lookups Per Second (avg):1517054.8236260759
Lookups Per Second (avg):1557013.2507370606
Lookups Per Second (avg):1536283.169286917
Lookups Per Second (avg):1493722.1650662713
Lookups Per Second (avg):1422596.100204022
Lookups Per Second (avg):1578921.6062375184
Lookups Per Second (avg):1506038.555716555
Lookups Per Second (avg):1446028.78250593
Lookups Per Second (avg):1517982.1124964976
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

Lookups Per Second (avg):1349487.9036850187
Lookups Per Second (avg):1474607.7166711385
Lookups Per Second (avg):1450025.6791572636
Lookups Per Second (avg):1393922.5795159582
Lookups Per Second (avg):1445392.2657224636
Lookups Per Second (avg):1434162.4432459075
Lookups Per Second (avg):1445543.9211354603
Lookups Per Second (avg):1444219.8956908425
Lookups Per Second (avg):1419883.9356485484
Lookups Per Second (avg):1417836.1303990977
---
Lookups Per Second (avg):1465955.9223703041
Lookups Per Second (avg):1555487.9502469338
Lookups Per Second (avg):1535026.522234302
Lookups Per Second (avg):1517282.513153197
Lookups Per Second (avg):1538161.4005770471
Lookups Per Second (avg):1566922.985338839
Lookups Per Second (avg):1568882.0602355888
Lookups Per Second (avg):1536738.9132451336
Lookups Per Second (avg):1549521.6473272059
Lookups Per Second (avg):1448953.6358135713
```

</details>

### Scan

Full GeoLite2-City scan using `any.Value`.

| Optimization        | `any.Value` |
|---                  |---          |
| Default             | ~1,295,000  |
| `.only`             | ~1,458,000  |
| `Cache`             | ~2,455,000  |
| `Cache` + `.only`   | ~3,463,000  |

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

Records Per Second: 1286608.969567542
Records Per Second: 1295843.0532171922
Records Per Second: 1299430.7275630098
Records Per Second: 1293056.1891340162
Records Per Second: 1297424.4160547797
Records Per Second: 1299599.593210179
Records Per Second: 1296055.3662371547
Records Per Second: 1293770.8917179666
Records Per Second: 1296683.084988625
Records Per Second: 1294042.5025624551
---
Records Per Second: 1453867.3129307455
Records Per Second: 1461263.840886964
Records Per Second: 1457367.244735448
Records Per Second: 1457043.3486106358
Records Per Second: 1461137.9718384417
Records Per Second: 1458449.0786374495
Records Per Second: 1455565.253714005
Records Per Second: 1460540.094927675
Records Per Second: 1454875.141172453
Records Per Second: 1458530.6343777399
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

Records Per Second: 2456181.6827736874
Records Per Second: 2460551.0497955345
Records Per Second: 2464874.3375610826
Records Per Second: 2462940.773846509
Records Per Second: 2448205.1643172107
Records Per Second: 2462645.62772618
Records Per Second: 2448077.631411299
Records Per Second: 2454071.3112366917
Records Per Second: 2441321.7258892707
Records Per Second: 2449213.043913177
---
Records Per Second: 3458689.2169479122
Records Per Second: 3460744.848789136
Records Per Second: 3464104.521198864
Records Per Second: 3470945.186361765
Records Per Second: 3440523.702543425
Records Per Second: 3448881.855919776
Records Per Second: 3461577.9857890424
Records Per Second: 3479900.251019196
Records Per Second: 3472727.724310288
Records Per Second: 3467312.0330495955
```

</details>
