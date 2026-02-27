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
    array: []Value,
    map: []Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .double => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .uint16 => |v| try writer.print("{}", .{v}),
            .uint32 => |v| try writer.print("{}", .{v}),
            .int32 => |v| try writer.print("{}", .{v}),
            .uint64 => |v| try writer.print("{}", .{v}),
            .uint128 => |v| try writer.print("{}", .{v}),
            .boolean => |v| try writer.print("{}", .{v}),
            .array => |a| {
                try writer.writeAll("[");

                for (a, 0..) |item, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }

                    try item.format(writer);
                }

                try writer.writeAll("]");
            },
            .map => |entries| {
                try writer.writeAll("{");

                for (entries, 0..) |entry, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }

                    try writer.print("\"{s}\": ", .{entry.key});
                    try entry.value.format(writer);
                }

                try writer.writeAll("}");
            },
        }
    }
};
