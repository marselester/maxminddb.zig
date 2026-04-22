const std = @import("std");

const decoder = @import("decoder.zig");
const filter = @import("filter.zig");

/// Decodes any.Value at the decoder's current offset.
///
/// When field_names is null, all map entries are decoded.
/// When field_names is non-empty, only top-level map entries matching those names are decoded.
/// Nested values are always fully decoded.
/// When field_names is empty, no entries are decoded.
pub fn decode(
    d: *decoder.Decoder,
    allocator: std.mem.Allocator,
    field_names: ?[]const []const u8,
) !Value {
    if (field_names != null and field_names.?.len == 0) {
        return .{ .map = &.{} };
    }

    return try decodeAny(d, allocator, field_names);
}

fn decodeAny(
    d: *decoder.Decoder,
    allocator: std.mem.Allocator,
    field_names: ?[]const []const u8,
) !Value {
    const field = try d.decodeFieldSizeAndType();

    if (field.type == .Pointer) {
        const next_offset = d.decodePointer(field.size);
        const prev_offset = d.offset;

        d.offset = next_offset;
        const v = try decodeAny(d, allocator, field_names);
        d.offset = prev_offset;

        return v;
    }

    return switch (field.type) {
        .String, .Bytes => .{ .string = d.decodeBytes(field.size) },
        .Double => .{ .double = try d.decodeDouble(field.size) },
        .Float => .{ .float = try d.decodeFloat(field.size) },
        .Uint16 => .{ .uint16 = try d.decodeInteger(u16, field.size) },
        .Uint32 => .{ .uint32 = try d.decodeInteger(u32, field.size) },
        .Int32 => .{ .int32 = try d.decodeInteger(i32, field.size) },
        .Uint64 => .{ .uint64 = try d.decodeInteger(u64, field.size) },
        .Uint128 => .{ .uint128 = try d.decodeInteger(u128, field.size) },
        .Bool => .{ .boolean = try d.decodeBool(field.size) },
        .Array => {
            const items = try allocator.alloc(Value, field.size);
            for (items) |*item| {
                item.* = try decodeAny(d, allocator, null);
            }
            return .{ .array = items };
        },
        .Map => {
            const entries = try allocator.alloc(Value.Entry, field.size);
            var n: usize = 0;
            for (0..field.size) |_| {
                const key = try decodeMapKey(d);

                if (!filter.matches(field_names, key)) {
                    try d.skipValue();
                    continue;
                }

                entries[n] = .{
                    .key = key,
                    .value = try decodeAny(d, allocator, null),
                };
                n += 1;
            }

            return .{ .map = entries[0..n] };
        },
        else => decoder.DecodeError.UnsupportedFieldType,
    };
}

fn decodeMapKey(d: *decoder.Decoder) ![]const u8 {
    const field = try d.decodeFieldSizeAndType();

    if (field.type == .Pointer) {
        const next_offset = d.decodePointer(field.size);
        const prev_offset = d.offset;

        d.offset = next_offset;
        const key = try decodeMapKey(d);
        d.offset = prev_offset;

        return key;
    }

    if (field.type != .String and field.type != .Bytes) {
        return decoder.DecodeError.ExpectedStringOrBytes;
    }

    return d.decodeBytes(field.size);
}

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

    // Checks if a string contains bytes that must be escaped in JSON:
    // control characters (0x00-0x1F), double quote, or backslash.
    fn jsonStringNeedsEscape(s: []const u8) bool {
        for (s) |c| {
            if (c < 0x20 or c == '"' or c == '\\') {
                return true;
            }
        }

        return false;
    }

    /// Formats the Value as JSON using a writer.
    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |s| {
                if (!jsonStringNeedsEscape(s)) {
                    try writer.writeByte('"');
                    try writer.writeAll(s);
                    try writer.writeByte('"');
                } else {
                    try std.json.Stringify.encodeJsonString(s, .{}, writer);
                }
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

                    // No need to escape field names, e.g., "city", "names",
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
            .value = .{ .string = "\"VOLZ\" LLC" },
            .want = "\"\\\"VOLZ\\\" LLC\"",
        },
        .{
            .value = .{ .string = "back\\slash" },
            .want = "\"back\\\\slash\"",
        },
        .{
            .value = .{ .string = "line\nnewline" },
            .want = "\"line\\nnewline\"",
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

    try std.testing.expectEqual(1, map.get("a").?.uint16);
    try std.testing.expectEqual(null, map.get("b"));
    try std.testing.expectEqual(null, (Value{ .uint16 = 1 }).get("a"));
}
