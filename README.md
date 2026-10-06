# Zig MaxMind DB Reader

This Zig package reads the [MaxMind DB format](https://maxmind.github.io/MaxMind-DB/).
It's based on the [maxminddb-rust](https://github.com/oschwald/maxminddb-rust) implementation.

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

Use `query()` for IP lookups in basic cases.
It returns `Decoded` or null when the IP is not found or the record is empty.
Each result owns an arena so you should call `result.deinit()` to free it.

```zig
var db = try maxminddb.Reader.mmap(allocator, io, db_path, .{});
defer db.close();

if (try db.query(maxminddb.geolite2.City, allocator, ip, .{})) |result| {
    defer result.deinit();
    std.debug.print("{f} {s}\n", .{ result.network, result.value.city.names.?.get("en").? });
}
```

Use `.only` to decode only the top-level fields you need.

```zig
const fields = &.{ "city", "country" };

if (try db.query(maxminddb.geolite2.City, allocator, ip, .{ .only = fields })) |result| {
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

if (try db.query(MyCity, allocator, ip, .{})) |result| {
    defer result.deinit();
    std.debug.print("{s}\n", .{result.value.city.names.en});
}
```

Use `any.Value` to decode any record without knowing the schema.

```zig
if (try db.query(maxminddb.any.Value, allocator, ip, .{})) |result| {
    defer result.deinit();
    // Formats as compact JSON.
    std.debug.print("{f}\n", .{result.value});
}
```

Use `lookup()` and `Cache.decode()` for repeated lookups, e.g., in web services.
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
    const result = try db.lookup(ip, .{}) orelse continue;
    const value = try cache.decode(&db, result, decode_options);
    std.debug.print("{f} {s}\n", .{ result.network, value.city.names.?.get("en").? });
}
```

Use `lookup()` to check if an IP exists without decoding.

```zig
if (try db.lookup(ip, .{})) |result| {
    std.debug.print("found in {f}\n", .{result.network});
}
```

Build the IPv4 index to speed up lookups if you have a long-lived `Reader` with many lookups.
It adds a one-time build cost (~1-4ms warm, ~10-120ms with page faults)
and uses ~320KB at depth 16, or ~20KB at depth 12 for constrained devices.
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
    if (try db.query(maxminddb.geolite2.City, arena_allocator, ip, .{})) |result| {
        std.debug.print("{f} {s}\n", .{ result.network, result.value.city.names.?.get("en").? });
    }
    _ = arena.reset(.retain_capacity);
}
```

⚠️ Don't reset the arena if you use `Cache.init(arena_allocator)` or else
the cached values will be corrupted.

### Scan

Use `scan()` to iterate over networks in the database.
Pass `null` for the whole database, or a `Network` to scan one range.
Each result owns an arena so you should call `deinit()` to free it.

```zig
var it = try db.scan(maxminddb.any.Value, allocator, null, .{});

while (try it.next()) |item| {
    defer item.deinit();
    std.debug.print("{f} {f}\n", .{ item.network, item.value });
}
```

Use `networks()` and `Cache.decode()` for faster scans, see [Benchmarks](#benchmarks) section.
Adjacent networks often share the same record so the cache avoids re-decoding them.
Same cache caveat applies, i.e., use a consistent `.only` field set.

```zig
var cache = try maxminddb.Cache(maxminddb.any.Value).init(allocator, .{});
defer cache.deinit();

var it = try db.networks(null, .{});

while (try it.next()) |result| {
    const value = try cache.decode(&db, result, .{});
    std.debug.print("{f} {f}\n", .{ result.network, value });
}
```

Use `decodeUnmanaged()` with a reusable arena when you only need a subset of networks,
filter on the cheap `result.network` before paying the decode cost:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const arena_allocator = arena.allocator();

var it = try db.networks(null, .{});

while (try it.next()) |result| {
    // Skip decoding.
    if (result.network.prefix_len < 24) {
        continue;
    }

    const value = try db.decodeUnmanaged(maxminddb.any.Value, arena_allocator, result, .{});
    std.debug.print("{f} {f}\n", .{ result.network, value });
    _ = arena.reset(.retain_capacity);
}
```

### Strict mode

Decoding bounds-checks every offset by default.
For a database you trust, skip the checks to decode faster.

```zig
var db = try maxminddb.Reader.mmap(allocator, io, db_path, .{ .strict = false });
```

Lookups or records per second on GeoLite2-City.

| Workload                | Default    | `strict = false` |
|---                      |---         |---               |
| Lookup                  | ~1,294,000 | ~1,469,000       |
| Lookup, Index           | ~1,395,000 | ~1,619,000       |
| Lookup, Index + `.only` | ~3,461,000 | ~3,677,000       |
| Scan                    | ~1,066,000 | ~1,310,000       |
| Scan + `.only`          | ~3,494,000 | ~4,151,000       |

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
  For scans, the cache hit rate is much higher because adjacent networks
  in the tree often share the same record.
- `Cache` + `.only`: `.only` helps on cache misses when decoding fewer fields.

Here are reference results on Apple M2 Pro with the default [`strict = true`](#strict-mode).

### Lookup

1M random IPv4 lookups in GeoLite2-City.

| Optimization              | `geolite2.City` | `MyCity`   | `any.Value` |
|---                        |---              |---         |---          |
| Default                   | ~1,223,000      |            |             |
| Index                     | ~1,311,000      | ~3,760,000 | ~1,300,000  |
| Index + `.only`           | ~3,509,000      |            | ~3,406,000  |
| Index + `Cache`           | ~1,489,000      |            |             |
| Index + `Cache` + `.only` | ~4,202,000      |            |             |

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

Lookups Per Second (avg):1229710.9226305853
Lookups Per Second (avg):1225218.8011050248
Lookups Per Second (avg):1217179.4528881088
Lookups Per Second (avg):1216456.898953503
Lookups Per Second (avg):1242657.7689984504
Lookups Per Second (avg):1215945.8526276886
Lookups Per Second (avg):1218536.437209655
Lookups Per Second (avg):1207031.4414417876
Lookups Per Second (avg):1222543.020906861
Lookups Per Second (avg):1233156.6219894022
---
Lookups Per Second (avg):1324815.5062257235
Lookups Per Second (avg):1304359.381009734
Lookups Per Second (avg):1292325.9626952226
Lookups Per Second (avg):1261687.298052833
Lookups Per Second (avg):1322442.7247939983
Lookups Per Second (avg):1353802.4491041726
Lookups Per Second (avg):1353840.7864714568
Lookups Per Second (avg):1306380.2407783412
Lookups Per Second (avg):1282655.1988740852
Lookups Per Second (avg):1310852.075176428
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

Lookups Per Second (avg):1414755.1660856567
Lookups Per Second (avg):1408326.7318017778
Lookups Per Second (avg):1390837.7519958958
Lookups Per Second (avg):1386812.4415858998
Lookups Per Second (avg):1354564.1707186862
Lookups Per Second (avg):1359661.824910908
Lookups Per Second (avg):1370092.4572642474
Lookups Per Second (avg):1425314.1621889044
Lookups Per Second (avg):1396533.6986199978
Lookups Per Second (avg):1433425.3652143858
---
Lookups Per Second (avg):3203045.8865182684
Lookups Per Second (avg):3679366.5202283696
Lookups Per Second (avg):3543986.9237656235
Lookups Per Second (avg):3438467.3375689522
Lookups Per Second (avg):3507171.650470981
Lookups Per Second (avg):3395670.7744378997
Lookups Per Second (avg):3533650.590608353
Lookups Per Second (avg):3519525.004905338
Lookups Per Second (avg):3654557.8058876945
Lookups Per Second (avg):3614513.899839109
```

</details>

<details>

<summary>Index + Cache (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):1444098.9310991995
Lookups Per Second (avg):1496161.8772343074
Lookups Per Second (avg):1486953.8394942146
Lookups Per Second (avg):1492377.216996311
Lookups Per Second (avg):1541030.514566254
Lookups Per Second (avg):1483817.8549126047
Lookups Per Second (avg):1467208.5312307258
Lookups Per Second (avg):1488864.3184918994
Lookups Per Second (avg):1495700.3289605912
Lookups Per Second (avg):1494598.8917603022
```

</details>

<details>

<summary>Index + Cache + .only (geolite2.City)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_lookup_cache -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 city \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):4451836.134660867
Lookups Per Second (avg):4050575.4855121044
Lookups Per Second (avg):4431733.582542121
Lookups Per Second (avg):4146379.6404466894
Lookups Per Second (avg):3939484.910457005
Lookups Per Second (avg):3882438.474036598
Lookups Per Second (avg):4045868.0055792523
Lookups Per Second (avg):4423041.0147885615
Lookups Per Second (avg):4416180.087160468
Lookups Per Second (avg):4231556.420700086
```

</details>

<details>

<summary>Index (MyCity)</summary>

```sh
$ for i in $(seq 1 10); do
    zig build benchmark_mycity -Doptimize=ReleaseFast -- GeoLite2-City.mmdb 1000000 \
      2>&1 | grep 'Lookups Per Second'
  done

Lookups Per Second (avg):3948691.367747637
Lookups Per Second (avg):3582300.7518590135
Lookups Per Second (avg):3746194.0915746056
Lookups Per Second (avg):3823500.210344129
Lookups Per Second (avg):3752182.7103458056
Lookups Per Second (avg):3652670.592391432
Lookups Per Second (avg):3937880.5951750535
Lookups Per Second (avg):3676047.680573454
Lookups Per Second (avg):3755736.3003650103
Lookups Per Second (avg):3723967.715404496
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

Lookups Per Second (avg):1292153.8260493241
Lookups Per Second (avg):1315646.2240460003
Lookups Per Second (avg):1283792.0827189141
Lookups Per Second (avg):1322878.5518209317
Lookups Per Second (avg):1305736.5188854444
Lookups Per Second (avg):1308686.1200057818
Lookups Per Second (avg):1329050.0266059202
Lookups Per Second (avg):1330518.7698937254
Lookups Per Second (avg):1265388.975832289
Lookups Per Second (avg):1250565.9467456145
---
Lookups Per Second (avg):3364560.6619773107
Lookups Per Second (avg):3590740.561622632
Lookups Per Second (avg):3559860.081408233
Lookups Per Second (avg):3344827.9236885
Lookups Per Second (avg):3467370.311681917
Lookups Per Second (avg):3230676.352303292
Lookups Per Second (avg):3207741.784715868
Lookups Per Second (avg):3505906.2143863477
Lookups Per Second (avg):3508850.9343734942
Lookups Per Second (avg):3277059.8473349554
```

</details>

### Scan

Full GeoLite2-City scan using `any.Value`.

| Optimization      | `any.Value` |
|---                |---          |
| Default           | ~1,068,000  |
| `.only`           | ~3,558,000  |
| `Cache`           | ~2,579,000  |
| `Cache` + `.only` | ~7,799,000  |

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

Records Per Second: 1076705.4971518253
Records Per Second: 1058870.81028544
Records Per Second: 1058166.349504646
Records Per Second: 1073577.6698382697
Records Per Second: 1064731.8799047165
Records Per Second: 1068167.8602854793
Records Per Second: 1065513.5335261833
Records Per Second: 1068416.3819943885
Records Per Second: 1069944.4530057767
Records Per Second: 1075483.1067097064
---
Records Per Second: 3631917.8481170367
Records Per Second: 3598413.288863994
Records Per Second: 3559782.361182007
Records Per Second: 3588856.078424154
Records Per Second: 3397936.02486265
Records Per Second: 3561811.2357230373
Records Per Second: 3592255.501881362
Records Per Second: 3588570.8187787766
Records Per Second: 3548492.7727530287
Records Per Second: 3511061.0591009255
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

Records Per Second: 2571685.51325415
Records Per Second: 2563574.4067045636
Records Per Second: 2599416.885376377
Records Per Second: 2554529.4216985353
Records Per Second: 2559527.3689032374
Records Per Second: 2568978.0639614197
Records Per Second: 2573363.130397515
Records Per Second: 2585632.532247565
Records Per Second: 2597590.831542499
Records Per Second: 2611067.934169342
---
Records Per Second: 7366914.642947414
Records Per Second: 7656009.853799868
Records Per Second: 7857783.4773936225
Records Per Second: 7955941.942384728
Records Per Second: 8076046.790968746
Records Per Second: 7896503.84574815
Records Per Second: 7799049.099727593
Records Per Second: 7683797.413866087
Records Per Second: 7843081.384596142
Records Per Second: 7853226.446407165
```

</details>
