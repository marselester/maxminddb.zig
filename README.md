# Zig MaxMind DB Reader

This Zig package reads the [MaxMind DB format](https://maxmind.github.io/MaxMind-DB/).
It's based on [maxminddb-rust](https://github.com/oschwald/maxminddb-rust) implementation.

⚠️ Note, that strings such as `geolite2.City.postal.code` are backed by the memory of an open database file.
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

Try `ArenaAllocator` to get ~3% improvement in lookups per second (639,848 vs 659,630) as
tested on Intel i5-10600, see [examples/benchmark.zig](./examples/benchmark.zig).

If you don't need all the struct fields, define your own one.
For example, commenting out all the `geolite2.City`'s fields but `geolite2.City.names`
increases throughput by 60% (639,848 vs 1,025,477 lookups per second).

```sh
$ zig build example_benchmark
```

<details>

<summary>Smp allocator</summary>

```sh
Benchmarking with:
  Database: GeoLite2-City.mmdb
  Lookups:  1000000
Opening database...
Database opened successfully in 0.086381 ms. Type: GeoLite2-City
Starting benchmark...

--- Benchmark Finished ---
Total Lookups Attempted: 1000000
Successful Lookups:      858992
IPs Not Found:           141008
Lookup Errors:           0
Elapsed Time:            1.562869106 s
Lookups Per Second (avg):639848.8498882644
```

</details>

<details>

<summary>Smp and Arena allocators</summary>

```sh
Benchmarking with:
  Database: GeoLite2-City.mmdb
  Lookups:  1000000
Opening database...
Database opened successfully in 0.051751 ms. Type: GeoLite2-City
Starting benchmark...

--- Benchmark Finished ---
Total Lookups Attempted: 1000000
Successful Lookups:      858715
IPs Not Found:           141285
Lookup Errors:           0
Elapsed Time:            1.516001233 s
Lookups Per Second (avg):659630.0703668359
```

</details>

<details>

<summary>Decoding names only</summary>

```sh
Benchmarking with:
  Database: GeoLite2-City.mmdb
  Lookups:  1000000
Opening database...
Database opened successfully in 0.061682 ms. Type: GeoLite2-City
Starting benchmark...

--- Benchmark Finished ---
Total Lookups Attempted: 1000000
Successful Lookups:      858516
IPs Not Found:           141484
Lookup Errors:           0
Elapsed Time:            0.975155208 s
Lookups Per Second (avg):1025477.7821993645
```

</details>
