const std = @import("std");

const decoder = @import("decoder.zig");
const filter = @import("filter.zig");

pub const DecodeError = error{
    ExpectedStructType,
    ExpectedMap,
    ExpectedArray,
    ExpectedDouble,
    ExpectedFloat,
    ExpectedUint16,
    ExpectedUint32,
    ExpectedInt32,
    ExpectedUint64,
    ExpectedUint128,
    ExpectedBool,
};

/// Decodes a typed record such as geolite2.City at the decoder's current offset.
///
/// When field_names is null, all fields are decoded.
/// When field_names is non-empty, only top-level fields matching the given names are decoded,
/// others are left at their default values.
/// When field_names is empty, no fields are decoded.
pub fn decode(
    d: *decoder.Decoder,
    allocator: std.mem.Allocator,
    T: type,
    field_names: ?[]const []const u8,
) !T {
    if (field_names != null and field_names.?.len == 0) {
        return .{};
    }

    const data_field = try d.decodeFieldSizeAndType();
    return try decodeStruct(d, allocator, T, data_field, field_names);
}

fn decodeStruct(
    d: *decoder.Decoder,
    allocator: std.mem.Allocator,
    T: type,
    data_field: decoder.DataField,
    field_names: ?[]const []const u8,
) !T {
    if (data_field.type != .Map) {
        return DecodeError.ExpectedStructType;
    }

    // Note, all the record's fields must be defined, i.e., .{ .some_field = undefined }
    // could contain garbage if the field wasn't found in the database and therefore not decoded.
    var record: T = .{};

    // Maps use the size in the control byte (and any following bytes) to indicate
    // the number of key/value pairs in the map, not the size of the payload in bytes.
    //
    // Maps are laid out with each key followed by its value, followed by the next pair, etc.
    // Once we know the number of pairs, we can look at each pair in turn to determine
    // the size of the key and the key name, as well as the value's type and payload.
    const map_len = data_field.size;
    var field_count: usize = 0;
    while (field_count < map_len) : (field_count += 1) {
        const map_key = try decodeValue(d, allocator, []const u8);

        var found = false;
        inline for (std.meta.fields(T)) |f| {
            if (std.mem.eql(u8, map_key, f.name)) {
                if (!filter.matches(field_names, f.name)) {
                    try d.skipValue();
                    found = true;
                    break;
                }

                const map_value = try decodeValue(d, allocator, f.type);
                @field(record, f.name) = map_value;
                found = true;
                break;
            }
        }

        // Unknown field in the database — skip its value.
        if (!found) {
            try d.skipValue();
        }
    }

    return record;
}

fn decodeValue(d: *decoder.Decoder, allocator: std.mem.Allocator, T: type) !T {
    const field = try d.decodeFieldSizeAndType();

    if (field.type == .Pointer) {
        const next_offset = d.decodePointer(field.size);
        const prev_offset = d.offset;

        d.offset = next_offset;
        const v = try decodeValue(d, allocator, T);
        d.offset = prev_offset;

        return v;
    }

    return switch (T) {
        []const u8, ?[]const u8 => if (field.type == .String or field.type == .Bytes)
            d.decodeBytes(field.size)
        else
            decoder.DecodeError.ExpectedStringOrBytes,
        f64, ?f64 => if (field.type == .Double) try d.decodeDouble(field.size) else DecodeError.ExpectedDouble,
        u16, ?u16 => if (field.type == .Uint16) try d.decodeInteger(u16, field.size) else DecodeError.ExpectedUint16,
        u32, ?u32 => if (field.type == .Uint32) try d.decodeInteger(u32, field.size) else DecodeError.ExpectedUint32,
        i32, ?i32 => if (field.type == .Int32) try d.decodeInteger(i32, field.size) else DecodeError.ExpectedInt32,
        u64, ?u64 => if (field.type == .Uint64) try d.decodeInteger(u64, field.size) else DecodeError.ExpectedUint64,
        u128, ?u128 => if (field.type == .Uint128) try d.decodeInteger(u128, field.size) else DecodeError.ExpectedUint128,
        bool, ?bool => if (field.type == .Bool) try d.decodeBool(field.size) else DecodeError.ExpectedBool,
        f32, ?f32 => if (field.type == .Float) try d.decodeFloat(field.size) else DecodeError.ExpectedFloat,
        else => {
            // We support Structs or Optional Structs only to safely decode arrays and maps.
            comptime var DecodedType: type = T;
            switch (@typeInfo(DecodedType)) {
                .@"struct" => {},
                .optional => |opt| {
                    DecodedType = opt.child;
                    switch (@typeInfo(DecodedType)) {
                        .@"struct" => {},
                        else => return decoder.DecodeError.UnsupportedFieldType,
                    }
                },
                else => return decoder.DecodeError.UnsupportedFieldType,
            }

            // Decode Map into a []Entry slice, e.g., collection.Map.
            if (@hasDecl(DecodedType, "map_marker")) {
                if (field.type != .Map) {
                    return DecodeError.ExpectedMap;
                }

                const entries = try allocator.alloc(DecodedType.Entry, field.size);
                for (entries) |*e| {
                    e.key = try decodeValue(d, allocator, []const u8);
                    e.value = try decodeValue(
                        d,
                        allocator,
                        std.meta.fieldInfo(DecodedType.Entry, .value).type,
                    );
                }

                return DecodedType{ .entries = entries };
            }

            // Decode Array into a slice, e.g., collection.Array.
            if (@hasDecl(DecodedType, "array_marker")) {
                if (field.type != .Array) {
                    return DecodeError.ExpectedArray;
                }

                const ChildType = std.meta.Elem(
                    std.meta.fieldInfo(DecodedType, .items).type,
                );
                const items = try allocator.alloc(ChildType, field.size);
                for (items) |*item| {
                    item.* = try decodeValue(d, allocator, ChildType);
                }

                return DecodedType{ .items = items };
            }

            // Decode Map into a nested struct, e.g., geolite2.City.continent.
            // Nested structs are always fully decoded (no field filtering).
            return try decodeStruct(d, allocator, T, field, null);
        },
    };
}
