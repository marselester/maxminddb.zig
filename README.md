# Zig MaxMind DB Reader

This Zig package reads the [MaxMind DB format](https://maxmind.github.io/MaxMind-DB/).
It's based on [maxminddb-rust](https://github.com/oschwald/maxminddb-rust) implementation.

⚠️ Note that strings such as `geolite2.City.postal.code` are backed by the memory of an open database file.
You must create a copy if you wish to continue using the string when the database is closed.

You'll need [MaxMind-DB/test-data](https://github.com/maxmind/MaxMind-DB/tree/main/test-data)
to run tests/examples and `GeoLite2-City.mmdb` to run the benchmark.

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

Use `ArenaAllocator` for best performance, see [benchmarks](./benchmarks/).

If you don't need all the fields, use `Options.only` to decode only the top-level fields you want.

```zig
const fields = &.{ "city", "country" };
const city = try db.lookup(allocator, maxminddb.geolite2.City, ip, .{ .only = fields });
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

const city = try db.lookup(allocator, MyCity, ip, .{});
```

Use `any.Value` to decode any record without knowing the schema.

```zig
const result = try db.lookup(allocator, maxminddb.any.Value, ip, .{ .only = fields });
if (result) |r| {
    // Formats as compact JSON.
    std.debug.print("{f}\n", .{r.value});
}
```

Here are reference results on Apple M2 Pro (1M random IPv4 lookups against GeoLite2-City):

| Benchmark       | All fields | Filtered (city) |
|---              |---         |---              |
| `geolite2.City` | ~1,189,000 | ~1,245,000      |
| `MyCity`        | ~1,228,000 | —               |
| `any.Value`     | ~1,150,000 | ~1,234,000      |

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

Lookups Per Second (avg):939020.9936331962
Lookups Per Second (avg):1202068.1587479531
Lookups Per Second (avg):1226191.8873913633
Lookups Per Second (avg):1190260.5152708234
Lookups Per Second (avg):1187237.1418382763
Lookups Per Second (avg):1180139.664667138
Lookups Per Second (avg):1184298.3951793911
Lookups Per Second (avg):1172927.7709424824
Lookups Per Second (avg):1192207.8482477544
Lookups Per Second (avg):1182672.4879777646
---
Lookups Per Second (avg):1255008.2012150432
Lookups Per Second (avg):1244663.9575842023
Lookups Per Second (avg):1255868.10809833
Lookups Per Second (avg):1244955.1445213587
Lookups Per Second (avg):1221882.1368531892
Lookups Per Second (avg):1255099.9559031925
Lookups Per Second (avg):1251926.597665689
Lookups Per Second (avg):1221997.1083589145
Lookups Per Second (avg):1186516.0167055523
Lookups Per Second (avg):1226974.481844842
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

Lookups Per Second (avg):975677.3396010846
Lookups Per Second (avg):1140100.8142809793
Lookups Per Second (avg):1148647.9154542664
Lookups Per Second (avg):1159945.4593645008
Lookups Per Second (avg):1146155.6701547962
Lookups Per Second (avg):1152253.0540916577
Lookups Per Second (avg):1168908.0392599553
Lookups Per Second (avg):1138716.2824329527
Lookups Per Second (avg):1150480.114967662
Lookups Per Second (avg):1161504.7700823087
---
Lookups Per Second (avg):1232606.0656379322
Lookups Per Second (avg):1234686.4799143772
Lookups Per Second (avg):1081398.2429103954
Lookups Per Second (avg):1243047.4800630722
Lookups Per Second (avg):1217435.2550309
Lookups Per Second (avg):1237809.9577944186
Lookups Per Second (avg):1232356.3798965935
Lookups Per Second (avg):1242459.8219555076
Lookups Per Second (avg):1213491.9682358333
Lookups Per Second (avg):1241524.1410712942
```

</details>
