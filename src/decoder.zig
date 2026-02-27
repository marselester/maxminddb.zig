const std = @import("std");

const any = @import("any.zig");

pub const DecodeError = error{
    ExpectedStructType,
    ExpectedStringOrBytes,
    ExpectedDouble,
    ExpectedUint16,
    ExpectedUint32,
    ExpectedMap,
    ExpectedInt32,
    ExpectedUint64,
    ExpectedUint128,
    ExpectedArray,
    ExpectedBool,
    ExpectedFloat,
    UnsupportedFieldType,
    InvalidIntegerSize,
    InvalidBoolSize,
    InvalidDoubleSize,
    InvalidFloatSize,
};

// These are database field types as defined in the spec.
const FieldType = enum {
    Extended,
    Pointer,
    String,
    Double,
    Bytes,
    Uint16,
    Uint32,
    Map,
    Int32,
    Uint64,
    Uint128,
    Array,
    // We don't use Container and Marker types.
    Container,
    Marker,
    Bool,
    Float,
};

// DataField represents the field's data type and payload size decoded from the database.
const DataField = struct {
    size: usize,
    type: FieldType,
};

pub const Decoder = struct {
    src: []const u8,
    offset: usize,

    // Decodes a record of a given type, e.g., geolite2.City, from the current offset in the src.
    // It allocates maps and arrays, but it doesn't duplicate byte slices to save memory.
    // This means that strings such as geolite2.City.postal.code are backed by the src's array,
    // so the caller should create a copy of the record when the src is freed (when the database is closed).
    //
    // When field_names is non-empty, only top-level fields matching the given names are decoded.
    pub fn decodeRecord(
        self: *Decoder,
        allocator: std.mem.Allocator,
        T: type,
        field_names: []const []const u8,
    ) !T {
        if (T == any.Value) {
            return try self.decodeAnyValue(allocator, field_names);
        }

        const data_field = try self.decodeFieldSizeAndType();
        return try self.decodeStruct(allocator, T, data_field, field_names);
    }

    fn decodeStruct(
        self: *Decoder,
        allocator: std.mem.Allocator,
        T: type,
        data_field: DataField,
        field_names: []const []const u8,
    ) !T {
        if (data_field.type != FieldType.Map) {
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
            const map_key = try self.decodeValue(allocator, []const u8);

            var found = false;
            inline for (std.meta.fields(T)) |f| {
                // Skip struct fields whose name starts with an underscore.
                if (f.name[0] == '_') {
                    continue;
                }

                if (std.mem.eql(u8, map_key, f.name)) {
                    if (!matchesFilter(field_names, f.name)) {
                        try self.skipValue();
                        found = true;
                        break;
                    }

                    const map_value = try self.decodeValue(allocator, f.type);
                    @field(record, f.name) = map_value;
                    found = true;
                    break;
                }
            }

            // If the field wasn't found in the struct, skip the value in the database.
            if (!found) {
                try self.skipValue();
            }
        }

        return record;
    }

    // Skips a value in the database without decoding it.
    // This is used when the database has fields that don't exist in the target struct
    // or are excluded by field name filtering.
    fn skipValue(self: *Decoder) !void {
        const field = try self.decodeFieldSizeAndType();

        if (field.type == FieldType.Pointer) {
            const next_offset = self.decodePointer(field.size);
            const prev_offset = self.offset;

            self.offset = next_offset;
            try self.skipValue();
            self.offset = prev_offset;

            return;
        }

        switch (field.type) {
            // Bool has no payload, size is encoded in the control byte.
            .Bool => {},
            // Skip each array element.
            .Array => {
                for (0..field.size) |_| {
                    try self.skipValue();
                }
            },
            // Skip each map key-value pair.
            .Map => {
                for (0..field.size) |_| {
                    try self.skipValue();
                    try self.skipValue();
                }
            },
            // For other types, just advance the offset.
            else => {
                self.offset += field.size;
            },
        }
    }

    // Decodes a struct's field value which can be a built-in data type or another struct.
    fn decodeValue(self: *Decoder, allocator: std.mem.Allocator, T: type) !T {
        const field = try self.decodeFieldSizeAndType();

        // Pointer
        if (field.type == FieldType.Pointer) {
            const next_offset = self.decodePointer(field.size);
            const prev_offset = self.offset;

            self.offset = next_offset;
            const v = try self.decodeValue(allocator, T);
            self.offset = prev_offset;

            return v;
        }

        return switch (T) {
            // String or Bytes
            []const u8 => if (field.type == FieldType.String or field.type == FieldType.Bytes) self.decodeBytes(field.size) else DecodeError.ExpectedStringOrBytes,
            // Double
            f64 => if (field.type == FieldType.Double) try self.decodeDouble(field.size) else DecodeError.ExpectedDouble,
            // Uint16
            u16 => if (field.type == FieldType.Uint16) try self.decodeInteger(u16, field.size) else DecodeError.ExpectedUint16,
            // Uint32
            u32 => if (field.type == FieldType.Uint32) try self.decodeInteger(u32, field.size) else DecodeError.ExpectedUint32,
            // Int32
            i32 => if (field.type == FieldType.Int32) try self.decodeInteger(i32, field.size) else DecodeError.ExpectedInt32,
            // Uint64
            u64 => if (field.type == FieldType.Uint64) try self.decodeInteger(u64, field.size) else DecodeError.ExpectedUint64,
            // Uint128
            u128 => if (field.type == FieldType.Uint128) try self.decodeInteger(u128, field.size) else DecodeError.ExpectedUint128,
            // Bool
            bool => if (field.type == FieldType.Bool) try self.decodeBool(field.size) else DecodeError.ExpectedBool,
            // Float
            f32 => if (field.type == FieldType.Float) try self.decodeFloat(field.size) else DecodeError.ExpectedFloat,
            else => {
                // We support Structs or Optional Structs only to safely decode arrays and maps.
                comptime var DecodedType: type = T;
                switch (@typeInfo(DecodedType)) {
                    .@"struct" => {},
                    .optional => |opt| {
                        DecodedType = opt.child;
                        switch (@typeInfo(DecodedType)) {
                            .@"struct" => {},
                            else => return DecodeError.UnsupportedFieldType,
                        }
                    },
                    else => return DecodeError.UnsupportedFieldType,
                }

                // Decode Map into []Entry slice.
                if (@hasDecl(DecodedType, "map_marker")) {
                    if (field.type != FieldType.Map) {
                        return DecodeError.ExpectedMap;
                    }

                    const entries = try allocator.alloc(DecodedType.Entry, field.size);
                    for (entries) |*e| {
                        e.key = try self.decodeValue(allocator, []const u8);
                        e.value = try self.decodeValue(
                            allocator,
                            std.meta.fieldInfo(DecodedType.Entry, .value).type,
                        );
                    }

                    return DecodedType{ .entries = entries };
                }

                // Decode Array into a slice.
                if (@hasDecl(DecodedType, "array_marker")) {
                    if (field.type != FieldType.Array) {
                        return DecodeError.ExpectedArray;
                    }

                    const ChildType = @typeInfo(
                        std.meta.fieldInfo(DecodedType, .items).type,
                    ).pointer.child;
                    const items = try allocator.alloc(ChildType, field.size);
                    for (items) |*item| {
                        item.* = try self.decodeValue(allocator, ChildType);
                    }

                    return DecodedType{ .items = items };
                }

                // Decode Map into a struct, e.g., geolite2.City.continent.
                // Nested structs are always fully decoded (no field filtering).
                return try self.decodeStruct(allocator, T, field, &.{});
            },
        };
    }

    // Decodes a value into the Value union based on the database field type.
    // When field_names is non-empty, only top-level map entries matching those names are decoded;
    // the rest are skipped. Nested values are always fully decoded.
    fn decodeAnyValue(
        self: *Decoder,
        allocator: std.mem.Allocator,
        field_names: []const []const u8,
    ) !any.Value {
        const field = try self.decodeFieldSizeAndType();

        if (field.type == FieldType.Pointer) {
            const next_offset = self.decodePointer(field.size);
            const prev_offset = self.offset;

            self.offset = next_offset;
            const v = try self.decodeAnyValue(allocator, field_names);
            self.offset = prev_offset;

            return v;
        }

        return switch (field.type) {
            .String, .Bytes => .{ .string = self.decodeBytes(field.size) },
            .Double => .{ .double = try self.decodeDouble(field.size) },
            .Float => .{ .float = try self.decodeFloat(field.size) },
            .Uint16 => .{ .uint16 = try self.decodeInteger(u16, field.size) },
            .Uint32 => .{ .uint32 = try self.decodeInteger(u32, field.size) },
            .Int32 => .{ .int32 = try self.decodeInteger(i32, field.size) },
            .Uint64 => .{ .uint64 = try self.decodeInteger(u64, field.size) },
            .Uint128 => .{ .uint128 = try self.decodeInteger(u128, field.size) },
            .Bool => .{ .boolean = try self.decodeBool(field.size) },
            .Array => {
                const items = try allocator.alloc(any.Value, field.size);
                for (items) |*item| {
                    item.* = try self.decodeAnyValue(allocator, &.{});
                }

                return .{ .array = items };
            },
            .Map => {
                const entries = try allocator.alloc(any.Value.Entry, field.size);
                var n: usize = 0;
                for (0..field.size) |_| {
                    const key = try self.decodeValue(allocator, []const u8);

                    if (!matchesFilter(field_names, key)) {
                        try self.skipValue();
                        continue;
                    }

                    entries[n] = .{
                        .key = key,
                        .value = try self.decodeAnyValue(allocator, &.{}),
                    };
                    n += 1;
                }

                return .{ .map = entries[0..n] };
            },
            else => DecodeError.UnsupportedFieldType,
        };
    }

    // Decodes a pointer to another part of the data section's address space.
    // The pointer will point to the beginning of a field.
    // It is illegal for a pointer to point to another pointer.
    // Pointer values start from the beginning of the data section, not the beginning of the file.
    // Pointers in the metadata start from the beginning of the metadata section.
    fn decodePointer(self: *Decoder, field_size: usize) usize {
        const pointer_value_offset = [_]usize{ 0, 0, 2048, 526_336, 0 };
        const pointer_size = ((field_size >> 3) & 0x3) + 1;
        const offset = self.offset;
        const new_offset = offset + pointer_size;
        const pointer_bytes = self.src[offset..new_offset];
        self.offset = new_offset;

        const base = if (pointer_size == 4) 0 else field_size & 0x7;
        const unpacked = toUsize(pointer_bytes, base);

        return unpacked + pointer_value_offset[pointer_size];
    }

    // Decodes a variable length byte sequence containing any sort of binary data.
    // If the length is zero then this a zero-length byte sequence.
    fn decodeBytes(self: *Decoder, field_size: usize) []const u8 {
        const offset = self.offset;
        const new_offset = offset + field_size;
        self.offset = new_offset;

        return self.src[offset..new_offset];
    }

    // Decodes IEEE-754 double (binary64) in big-endian format.
    fn decodeDouble(self: *Decoder, field_size: usize) !f64 {
        if (field_size != 8) {
            return DecodeError.InvalidDoubleSize;
        }

        const new_offset = self.offset + field_size;
        const double_bytes = self.src[self.offset..new_offset];
        self.offset = new_offset;

        const double_value: f64 = @bitCast([8]u8{
            double_bytes[7],
            double_bytes[6],
            double_bytes[5],
            double_bytes[4],
            double_bytes[3],
            double_bytes[2],
            double_bytes[1],
            double_bytes[0],
        });

        return double_value;
    }

    // Decodes an IEEE-754 float (binary32) stored in big-endian format.
    fn decodeFloat(self: *Decoder, field_size: usize) !f32 {
        if (field_size != 4) {
            return DecodeError.InvalidFloatSize;
        }

        const new_offset = self.offset + field_size;
        const float_bytes = self.src[self.offset..new_offset];
        self.offset = new_offset;

        const float_value: f32 = @bitCast([4]u8{
            float_bytes[3],
            float_bytes[2],
            float_bytes[1],
            float_bytes[0],
        });

        return float_value;
    }

    // Decodes 16-bit, 32-bit, 64-bit, and 128-bit unsigned integers.
    // It also supports 32-bit signed integers.
    // See https://maxmind.github.io/MaxMind-DB/#integer-formats.
    fn decodeInteger(self: *Decoder, T: type, field_size: usize) !T {
        if (field_size > @sizeOf(T)) {
            return DecodeError.InvalidIntegerSize;
        }

        const offset = self.offset;
        const new_offset = offset + field_size;

        var integer_value: T = 0;
        for (self.src[offset..new_offset]) |b| {
            integer_value = (integer_value << 8) | b;
        }

        self.offset = new_offset;

        return integer_value;
    }

    // Decodes a boolean value.
    fn decodeBool(_: *Decoder, field_size: usize) !bool {
        // The length information for a boolean type will always be 0 or 1, indicating the value.
        // There is no payload for this field.
        return switch (field_size) {
            0, 1 => field_size != 0,
            else => DecodeError.InvalidBoolSize,
        };
    }

    // Decodes a control byte that provides information about the field's data type and payload size,
    // see https://maxmind.github.io/MaxMind-DB/#data-field-format.
    fn decodeFieldSizeAndType(self: *Decoder) !DataField {
        const src = self.src;
        var offset = self.offset;

        const control_byte = src[offset];
        offset += 1;

        // The first three bits of the control byte tell you what type the field is.
        // If these bits are all 0, then this is an "extended" type,
        // which means that the next byte contains the actual type.
        // Otherwise, the first three bits will contain a number from 1 to 7,
        // the actual type for the field.
        var field_type: FieldType = @enumFromInt(control_byte >> 5);
        if (field_type == FieldType.Extended) {
            // Extended types are 7 (Map) through 15 (Float), so valid extended byte values are 0-8.
            const ext_byte = src[offset];
            if (ext_byte > 8) {
                return DecodeError.UnsupportedFieldType;
            }

            field_type = @enumFromInt(ext_byte + 7);
            offset += 1;
        }

        self.offset = offset;

        return .{
            .size = self.decodeFieldSize(control_byte, field_type),
            .type = field_type,
        };
    }

    // Decodes the field size in bytes, see https://maxmind.github.io/MaxMind-DB/#payload-size.
    fn decodeFieldSize(self: *Decoder, control_byte: u8, field_type: FieldType) usize {
        // The next five bits in the control byte tell you how long the data field's payload is,
        // except for maps and pointers.
        const field_size: usize = control_byte & 0b11111;
        if (field_type == FieldType.Pointer) {
            return field_size;
        }

        const bytes_to_read = if (field_size > 28) field_size - 28 else 0;

        const offset = self.offset;
        const new_offset = offset + bytes_to_read;
        const size_bytes = self.src[offset..new_offset];
        self.offset = new_offset;

        return switch (field_size) {
            0...28 => field_size,
            29 => 29 + size_bytes[0],
            30 => 285 + toUsize(size_bytes, 0),
            else => 65_821 + toUsize(size_bytes, 0),
        };
    }
};

fn matchesFilter(field_names: []const []const u8, name: []const u8) bool {
    if (field_names.len == 0) {
        return true;
    }

    for (field_names) |n| {
        if (std.mem.eql(u8, n, name)) {
            return true;
        }
    }

    return false;
}

test "decodeFieldSize returns raw size for pointer type" {
    // The pointer control byte layout is 001SSVVV where SS is the pointer size
    // indicator (0-3) and VVV are the 3 value bits used for 1-3 byte pointers.
    // For 4-byte pointers (SS=11) the spec says VVV bits are ignored,
    // meaning a writer may set them to any value.
    //
    // The lower 5 bits (SSVVV) must not go through the payload size extension
    // logic (which triggers at values 29, 30, 31) because they encode pointer
    // metadata, not a payload size.
    //
    // Previously decodeFieldSize had a dead code check for FieldType.Extended
    // (which was already resolved by decodeFieldSizeAndType before this call).
    // It was replaced with FieldType.Pointer to skip the size extension.
    //
    // This test uses SS=11, VVV=101 giving the 5-bit value 11_101=29.
    // Without the Pointer check, size extension would read 0xAA as an extra
    // byte, corrupt the size, and advance the offset.
    var d = Decoder{
        .src = &.{ 0b001_11_101, 0xAA, 0xBB, 0xCC },
        .offset = 0,
    };
    const size = d.decodeFieldSize(0b001_11_101, .Pointer);
    try std.testing.expectEqual(29, size);
    // Offset must not advance, i.e., no extra bytes read for size extension.
    try std.testing.expectEqual(0, d.offset);
}

// Converts the bytes slice to usize.
pub fn toUsize(bytes: []const u8, prefix: usize) usize {
    var val = prefix;
    for (bytes) |b| {
        val = (val << 8) | b;
    }

    return val;
}
