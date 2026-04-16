const std = @import("std");

/// A tagged union that can hold any MaxMind DB data type.
/// Use instead of a predefined struct to decode any record without knowing the schema.
pub const Value = union(enum) {
    string: []const u8,
    double: f64,
    uint16: u16,
    uint32: u32,
    int32: i32,
    uint64: u64,
    uint128: u128,
    boolean: bool,
    float: f32,
    array: []const Value,
    map: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    /// Returns the value for the given key if this Value is a map, or null otherwise.
    pub fn get(self: Value, key: []const u8) ?Value {
        switch (self) {
            .map => |entries| {
                for (entries) |e| {
                    if (std.mem.eql(u8, e.key, key)) {
                        return e.value;
                    }
                }

                return null;
            },
            else => return null,
        }
    }

    /// Formats the Value as JSON using a writer (unbounded output).
    /// Strings are not escaped.
    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .int32 => |v| try writer.print("{}", .{v}),
            .uint16, .uint32, .uint64 => |v| try writer.print("{}", .{v}),
            .uint128 => |v| try writer.print("\"{}\"", .{v}),
            .double => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .array => |items| {
                try writer.writeByte('[');

                for (items, 0..) |item, i| {
                    if (i > 0) {
                        try writer.writeByte(',');
                    }

                    try item.format(writer);
                }

                try writer.writeByte(']');
            },
            .map => |entries| {
                try writer.writeByte('{');

                for (entries, 0..) |entry, i| {
                    if (i > 0) {
                        try writer.writeByte(',');
                    }

                    try writer.writeByte('"');
                    try writer.writeAll(entry.key);
                    try writer.writeByte('"');
                    try writer.writeByte(':');
                    try entry.value.format(writer);
                }

                try writer.writeByte('}');
            },
        }
    }
};

fn expectJSON(expected: []const u8, v: Value) !void {
    var out: [4096]u8 = undefined;

    var w = std.Io.Writer.fixed(&out);
    try v.format(&w);
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "encode scalars" {
    const tests = [_]struct {
        value: Value,
        want: []const u8,
    }{
        .{
            .value = .{ .string = "hello" },
            .want = "\"hello\"",
        },
        .{
            .value = .{ .string = "" },
            .want = "\"\"",
        },
        .{
            .value = .{ .int32 = 0 },
            .want = "0",
        },
        .{
            .value = .{ .int32 = 42 },
            .want = "42",
        },
        .{
            .value = .{ .int32 = -1 },
            .want = "-1",
        },
        .{
            .value = .{ .int32 = std.math.minInt(i32) },
            .want = "-2147483648",
        },
        .{
            .value = .{ .int32 = std.math.maxInt(i32) },
            .want = "2147483647",
        },
        .{
            .value = .{ .uint16 = 0 },
            .want = "0",
        },
        .{
            .value = .{ .uint16 = 65535 },
            .want = "65535",
        },
        .{
            .value = .{ .uint32 = std.math.maxInt(u32) },
            .want = "4294967295",
        },
        .{
            .value = .{ .uint64 = std.math.maxInt(u64) },
            .want = "18446744073709551615",
        },
        .{
            .value = .{ .uint128 = 0 },
            .want = "\"0\"",
        },
        .{
            .value = .{ .uint128 = std.math.maxInt(u128) },
            .want = "\"340282366920938463463374607431768211455\"",
        },
        .{
            .value = .{ .boolean = true },
            .want = "true",
        },
        .{
            .value = .{ .boolean = false },
            .want = "false",
        },
        .{
            .value = .{ .double = 1.5 },
            .want = "1.5",
        },
        .{
            .value = .{ .float = 1.5 },
            .want = "1.5",
        },
        .{
            .value = .{ .double = -0.0 },
            .want = "-0",
        },
        .{
            .value = .{ .double = std.math.nan(f64) },
            .want = "nan",
        },
        .{
            .value = .{ .double = std.math.inf(f64) },
            .want = "inf",
        },
    };

    for (tests) |tc| {
        try expectJSON(tc.want, tc.value);
    }
}

test "encode array" {
    try expectJSON("[]", .{ .array = &.{} });
    try expectJSON(
        "[1]",
        .{
            .array = &[_]Value{
                .{ .uint16 = 1 },
            },
        },
    );
    try expectJSON(
        "[1,2,3]",
        .{
            .array = &[_]Value{
                .{ .uint16 = 1 },
                .{ .uint16 = 2 },
                .{ .uint16 = 3 },
            },
        },
    );
}

test "encode map" {
    try expectJSON("{}", .{ .map = &.{} });
    try expectJSON(
        "{\"a\":1}",
        .{
            .map = &[_]Value.Entry{
                .{
                    .key = "a",
                    .value = .{ .uint16 = 1 },
                },
            },
        },
    );
    try expectJSON(
        "{\"a\":1,\"b\":\"c\"}",
        .{
            .map = &[_]Value.Entry{
                .{
                    .key = "a",
                    .value = .{ .uint16 = 1 },
                },
                .{
                    .key = "b",
                    .value = .{ .string = "c" },
                },
            },
        },
    );
}

test "encode nested" {
    try expectJSON("{\"names\":[\"en\",\"de\"],\"id\":42}", .{
        .map = &[_]Value.Entry{
            .{
                .key = "names",
                .value = .{
                    .array = &[_]Value{
                        .{ .string = "en" },
                        .{ .string = "de" },
                    },
                },
            },
            .{
                .key = "id",
                .value = .{ .uint32 = 42 },
            },
        },
    });
}

test "get" {
    const map = Value{
        .map = &[_]Value.Entry{
            .{ .key = "a", .value = .{ .uint16 = 1 } },
        },
    };

    try std.testing.expectEqual(@as(u16, 1), map.get("a").?.uint16);
    try std.testing.expectEqual(null, map.get("b"));
    try std.testing.expectEqual(null, (Value{ .uint16 = 1 }).get("a"));
}
