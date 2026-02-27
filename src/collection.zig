const std = @import("std");

/// A decoded MaxMind DB array with elements of type T.
/// Use as a field type in record structs to decode MaxMind DB arrays.
pub fn Array(comptime T: type) type {
    return struct {
        items: []const T = &.{},

        pub const array_marker: void = {};
    };
}

/// A decoded MaxMind DB map with string keys and values of type V.
/// Use as a field type in record structs to decode MaxMind DB maps.
/// The MaxMind DB format requires all map keys to be UTF-8 strings.
pub fn Map(comptime V: type) type {
    return struct {
        entries: []const Entry = &.{},

        pub const Entry = struct {
            key: []const u8,
            value: V,
        };

        pub const map_marker: void = {};

        pub fn get(self: @This(), key: []const u8) ?V {
            for (self.entries) |e| {
                if (std.mem.eql(u8, e.key, key)) {
                    return e.value;
                }
            }

            return null;
        }
    };
}
