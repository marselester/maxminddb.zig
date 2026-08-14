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
| Default                   | ~1,481,000      |            |             |
| Index                     | ~1,707,000      | ~4,039,000 | ~1,551,000  |
| Index + `.only`           | ~3,846,000      |            | ~3,985,000  |
| Index + `Cache`           | ~1,833,000      |            |             |
| Index + `Cache` + `.only` | ~4,571,000      |            |             |

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

Lookups Per Second (avg):1125588.630936204
Lookups Per Second (avg):1550915.6897028699
Lookups Per Second (avg):1511239.4657163993
Lookups Per Second (avg):1505627.4723871083
Lookups Per Second (avg):1512523.2195947382
Lookups Per Second (avg):1535405.7856776966
Lookups Per Second (avg):1535435.8440204468
Lookups Per Second (avg):1490513.254274344
Lookups Per Second (avg):1524468.191634274
Lookups Per Second (avg):1519063.9679735743
---
Lookups Per Second (avg):1705933.828792017
Lookups Per Second (avg):1608214.1144107645
Lookups Per Second (avg):1733157.9483789927
Lookups Per Second (avg):1712405.4940317846
Lookups Per Second (avg):1749432.9458026795
Lookups Per Second (avg):1693965.0317305569
Lookups Per Second (avg):1709666.9269634562
Lookups Per Second (avg):1706797.626381119
Lookups Per Second (avg):1725899.1664985712
Lookups Per Second (avg):1720099.158969041
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

Lookups Per Second (avg):1705933.828792017
Lookups Per Second (avg):1608214.1144107645
Lookups Per Second (avg):1733157.9483789927
Lookups Per Second (avg):1712405.4940317846
Lookups Per Second (avg):1749432.9458026795
Lookups Per Second (avg):1693965.0317305569
Lookups Per Second (avg):1709666.9269634562
Lookups Per Second (avg):1706797.626381119
Lookups Per Second (avg):1725899.1664985712
Lookups Per Second (avg):1720099.158969041
---
Lookups Per Second (avg):3752004.9729674235
Lookups Per Second (avg):3729479.128488455
Lookups Per Second (avg):3624840.492518967
Lookups Per Second (avg):3962897.373342085
Lookups Per Second (avg):3894333.1124921935
Lookups Per Second (avg):3748089.0602182043
Lookups Per Second (avg):4024040.97284957
Lookups Per Second (avg):3993467.342356549
Lookups Per Second (avg):3909014.4366861195
Lookups Per Second (avg):3823681.7449962017
```

</details>

<details>

<summary>Index + Cache (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1787278.1540991226
Lookups Per Second (avg):1817462.5458136417
Lookups Per Second (avg):1798581.6374415646
Lookups Per Second (avg):1795818.8388155655
Lookups Per Second (avg):1826112.5419463757
Lookups Per Second (avg):1873595.6826569808
Lookups Per Second (avg):1826054.7436457623
Lookups Per Second (avg):1902188.9677319797
Lookups Per Second (avg):1847799.524838352
Lookups Per Second (avg):1851777.2663786227
```

</details>

<details>

<summary>Index + Cache + .only (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 city \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):4614223.059266894
Lookups Per Second (avg):4521374.792549717
Lookups Per Second (avg):4615841.768353353
Lookups Per Second (avg):4630117.292446311
Lookups Per Second (avg):4448471.141208518
Lookups Per Second (avg):4529092.33475036
Lookups Per Second (avg):4407485.232169794
Lookups Per Second (avg):4709314.612237978
Lookups Per Second (avg):4602866.602721189
Lookups Per Second (avg):4633354.0096756015
```

</details>

<details>

<summary>Index (MyCity)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_mycity -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):4231760.094140073
Lookups Per Second (avg):4161761.4239050536
Lookups Per Second (avg):4250223.402367586
Lookups Per Second (avg):3582790.598479445
Lookups Per Second (avg):3522072.387392742
Lookups Per Second (avg):3958456.662349363
Lookups Per Second (avg):4004160.995973864
Lookups Per Second (avg):4273060.678675187
Lookups Per Second (avg):4229349.145460006
Lookups Per Second (avg):4179249.4114864566
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

Lookups Per Second (avg):1535775.5072657668
Lookups Per Second (avg):1536752.492372425
Lookups Per Second (avg):1543397.144445188
Lookups Per Second (avg):1537279.5100559841
Lookups Per Second (avg):1545317.1000347503
Lookups Per Second (avg):1551016.0204972103
Lookups Per Second (avg):1503789.8338456748
Lookups Per Second (avg):1563188.982871649
Lookups Per Second (avg):1576672.4996979686
Lookups Per Second (avg):1615207.1755578776
---
Lookups Per Second (avg):3909220.0910457354
Lookups Per Second (avg):3894748.321363474
Lookups Per Second (avg):3801548.9996837755
Lookups Per Second (avg):4065676.251127097
Lookups Per Second (avg):4244269.74351097
Lookups Per Second (avg):3912579.927698888
Lookups Per Second (avg):4075992.8099486833
Lookups Per Second (avg):4135441.207968663
Lookups Per Second (avg):3827693.1910532312
Lookups Per Second (avg):3981525.0548492903
```

</details>

### Scan

Full GeoLite2-City scan using `any.Value`.

| Optimization      | `any.Value` |
|---                |---          |
| Default           | ~1,343,000  |
| `.only`           | ~4,152,000  |
| `Cache`           | ~3,162,000  |
| `Cache` + `.only` | ~8,690,000  |

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

Records Per Second: 1348416.4971945502
Records Per Second: 1360302.7227391207
Records Per Second: 1362253.5582013272
Records Per Second: 1332654.6560814735
Records Per Second: 1320580.0868553957
Records Per Second: 1351486.1763569769
Records Per Second: 1309867.0925010517
Records Per Second: 1348603.514298871
Records Per Second: 1346351.8185439997
Records Per Second: 1352922.1604877142
---
Records Per Second: 4157235.7883284474
Records Per Second: 4140488.8411180303
Records Per Second: 4123548.4295864706
Records Per Second: 4173748.7043202976
Records Per Second: 4153669.1612003203
Records Per Second: 4118582.9699281245
Records Per Second: 4160452.6453095395
Records Per Second: 4132271.3073195647
Records Per Second: 4214831.898028607
Records Per Second: 4143119.25109507
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

Records Per Second: 3202768.99866599
Records Per Second: 3207125.9102114975
Records Per Second: 3172674.1141741644
Records Per Second: 3162051.935631177
Records Per Second: 3175577.9288906963
Records Per Second: 3191810.4514650158
Records Per Second: 3148586.478626415
Records Per Second: 3170526.0543755963
Records Per Second: 3129229.221252236
Records Per Second: 3061915.669774389
---
Records Per Second: 8860392.508094613
Records Per Second: 8758687.056088189
Records Per Second: 8822526.521036463
Records Per Second: 7472024.218026059
Records Per Second: 8917110.559161728
Records Per Second: 8736839.742059404
Records Per Second: 8049847.73913308
Records Per Second: 9143266.960318854
Records Per Second: 9146243.279598111
Records Per Second: 8997078.824069625
```

</details>
