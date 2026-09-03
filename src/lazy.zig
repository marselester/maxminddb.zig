const std = @import("std");

const decoder = @import("decoder.zig");

/// A value cursor into an MMDB record that defers decoding container contents (maps, arrays)
/// until you actually navigate into them, rather than decoding everything up front.
/// Primitives carry their decoded value directly.
pub const Value = union(enum) {
    // .none is the C-ABI "not present" sentinel MMDB_V_NONE.
    // It's unreachable in Zig code.
    none,
    string: []const u8,
    bytes: []const u8,
    uint16: u16,
    uint32: u32,
    int32: i32,
    uint64: u64,
    uint128: u128,
    float: f32,
    double: f64,
    boolean: bool,
    array: Array,
    map: Map,

    /// Decodes the value at the decoder's current position, following pointer chains.
    fn decode(d: *decoder.Decoder) !Value {
        const field = try d.resolveField();
        const payload_offset = d.offset;

        const v: Value = switch (field.type) {
            .String => .{ .string = try d.decodeBytes(field.size) },
            .Bytes => .{ .bytes = try d.decodeBytes(field.size) },
            .Uint16 => .{ .uint16 = try d.decodeInteger(u16, field.size) },
            .Uint32 => .{ .uint32 = try d.decodeInteger(u32, field.size) },
            .Int32 => .{ .int32 = try d.decodeInteger(i32, field.size) },
            .Uint64 => .{ .uint64 = try d.decodeInteger(u64, field.size) },
            .Uint128 => .{ .uint128 = try d.decodeInteger(u128, field.size) },
            .Float => .{ .float = try d.decodeFloat(field.size) },
            .Double => .{ .double = try d.decodeDouble(field.size) },
            .Bool => .{ .boolean = try d.decodeBool(field.size) },
            .Array => .{
                .array = .{
                    .src = d.src,
                    .payload_offset = payload_offset,
                    .len = field.size,
                    .strict = d.strict,
                },
            },
            .Map => .{
                .map = .{
                    .src = d.src,
                    .payload_offset = payload_offset,
                    .len = field.size,
                    .strict = d.strict,
                },
            },
            else => return decoder.DecodeError.UnsupportedFieldType,
        };

        return v;
    }
};

/// A lazy reference to an MMDB map record.
pub const Map = struct {
    src: []const u8,
    payload_offset: usize,
    len: usize,
    strict: bool = true,

    /// Returns the value for the key or null if the key is absent.
    /// Deliberately no indexed iteration on the lazy side because enumeration is slow.
    pub fn get(self: Map, key: []const u8) !?Value {
        var d = decoder.Decoder{
            .src = self.src,
            .offset = self.payload_offset,
            .strict = self.strict,
        };
        if (!try seekKey(&d, self.len, key)) {
            return null;
        }

        return try Value.decode(&d);
    }
};

/// A lazy reference to an MMDB array record.
pub const Array = struct {
    src: []const u8,
    payload_offset: usize,
    len: usize,
    strict: bool = true,

    /// Returns the i-th item or null if i is out of bounds.
    pub fn at(self: Array, i: usize) !?Value {
        var d = decoder.Decoder{
            .src = self.src,
            .offset = self.payload_offset,
            .strict = self.strict,
        };
        if (!try seekIndex(&d, self.len, i)) {
            return null;
        }

        return try Value.decode(&d);
    }
};

/// Walks a path from the decoder's position.
/// Each step is a map key or an array index ("-1" is the last element).
/// Returns null if any step does not resolve.
pub fn walkPath(d: *decoder.Decoder, path: []const []const u8) !?Value {
    for (path) |step| {
        // Descend into the container at the current position (walking moves forward only).
        const field = try d.resolveField();
        switch (field.type) {
            .Map => {
                if (!try seekKey(d, field.size, step)) {
                    return null;
                }
            },
            .Array => {
                const index = arrayIndex(step, field.size) orelse return null;
                if (!try seekIndex(d, field.size, index)) {
                    return null;
                }
            },
            else => return null,
        }
    }

    return try Value.decode(d);
}

/// Parses a decimal array index for an array of len elements,
/// resolving a negative value from the end (-1 is the last element).
/// Returns null on a non-numeric step or a negative index before the start.
pub fn arrayIndex(step: []const u8, len: usize) ?usize {
    const i = std.fmt.parseInt(isize, step, 10) catch return null;
    if (i >= 0) {
        return @intCast(i);
    }

    // Negative counts from the end: -1 is the last element.
    const back: usize = @abs(i);
    return if (back > len) null else len - back;
}

/// Advances the decoder to the value whose key matches,
/// within a map of len entries starting at the decoder's position.
/// Returns false if the key is absent.
fn seekKey(d: *decoder.Decoder, len: usize, key: []const u8) !bool {
    for (0..len) |_| {
        const map_key = try d.decodeStringKey();
        if (std.mem.eql(u8, map_key, key)) {
            return true;
        }

        try d.skipValue();
    }

    return false;
}

/// Advances the decoder to the i-th element of an array of len elements
/// starting at the decoder's position.
/// Returns false if the index is out of bounds.
fn seekIndex(d: *decoder.Decoder, len: usize, index: usize) !bool {
    if (index >= len) {
        return false;
    }

    for (0..index) |_| {
        try d.skipValue();
    }

    return true;
}

test "resolveField rejects a pointer to a pointer" {
    // The pointer at offset 0 targets offset 2, which is itself a pointer (illegal).
    var d = decoder.Decoder{
        .src = &.{ 0x20, 0x02, 0x20, 0x00 },
        .offset = 0,
    };
    try std.testing.expectError(
        error.InvalidPointer,
        walkPath(&d, &.{}),
    );
}
