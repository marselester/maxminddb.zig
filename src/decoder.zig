const std = @import("std");

pub const DecodeError = error{
    ExpectedStructType,
    ExpectedString,
    ExpectedBytes,
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

// Field represents the field's data type and payload size decoded from the database.
const Field = struct {
    size: usize,
    type: FieldType,
};

pub const Decoder = struct {
    src: []u8,
    offset: usize,

    // Decodes a record of a given type (e.g., geolite2.City) from the current offset in the src.
    // It allocates maps and arrays, but it doesn't duplicate byte slices to save memory.
    // This means that strings such as geolite2.City.postal.code are backed by the src's array,
    // so the caller should create a copy of the record when the src is freed (when the database is closed).
    pub fn decodeRecord(self: *Decoder, allocator: std.mem.Allocator, comptime T: type) !T {
        const field = self.decodeFieldSizeAndType();
        return try self.decodeStruct(allocator, T, field);
    }

    fn decodeStruct(self: *Decoder, parent_allocator: std.mem.Allocator, comptime T: type, field: Field) !T {
        if (field.type != FieldType.Map) {
            return DecodeError.ExpectedStructType;
        }

        // The decoded record (e.g., geolite2.City) must be initialized with an allocator,
        // so the caller could free the memory when the record is no longer needed.
        // Record's inner structs will use the same allocator.
        //
        // Note, all the record's fields must be defined, i.e., .{ .some_field = undefined }
        // could contain garbage if the field wasn't found in the database and therefore not decoded.
        var record: T = undefined;
        var allocator = parent_allocator;
        if (@hasDecl(T, "init")) {
            record = T.init(allocator);
            allocator = record._arena.allocator();
        } else {
            record = .{};
        }
        // Free the record if decoding has failed.
        errdefer if (@hasDecl(T, "init")) record.deinit();

        // Maps use the size in the control byte (and any following bytes) to indicate
        // the number of key/value pairs in the map, not the size of the payload in bytes.
        //
        // Maps are laid out with each key followed by its value, followed by the next pair, etc.
        // Once we know the number of pairs, we can look at each pair in turn to determine
        // the size of the key and the key name, as well as the value's type and payload.
        const map_len = field.size;
        var map_key: ?[]const u8 = null;
        var field_count: usize = 0;
        inline for (std.meta.fields(T)) |f| next_field: {
            // Skip struct fields whose name starts with an underscore, e.g., _allocator.
            if (f.name[0] == '_') {
                break :next_field;
            }

            // Don't decode more struct fields than the number of the map entries.
            if (field_count >= map_len) {
                break;
            }

            // The map key is nulled to advance the map decoding to the next key.
            // Otherwise the key is used to decode the next struct field.
            if (map_key == null) {
                map_key = try self.decodeValue(allocator, []const u8);
            }
            // Struct fields must match the layout (names and order) in the database.
            // When the names don't match, the struct field is skipped.
            // This is usefull for optional fields, e.g., some db records have city.is_in_european_union flag.
            if (!std.mem.eql(u8, map_key.?, f.name)) {
                break :next_field;
            }

            const map_value = try self.decodeValue(allocator, f.type);
            @field(record, f.name) = map_value;

            field_count += 1;
            map_key = null;
        }

        return record;
    }

    // Decodes a struct's field value which can be a built-in data type or another struct.
    fn decodeValue(self: *Decoder, allocator: std.mem.Allocator, comptime T: type) !T {
        const field = self.decodeFieldSizeAndType();

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
            // String
            []const u8 => if (field.type == FieldType.String) self.decodeBytes(field.size) else DecodeError.ExpectedString,
            // Double
            f64 => if (field.type == FieldType.Double) self.decodeDouble(field.size) else DecodeError.ExpectedDouble,
            // Bytes
            []u8 => if (field.type == FieldType.Bytes) self.decodeBytes(field.size) else DecodeError.ExpectedBytes,
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
            f32 => if (field.type == FieldType.Float) self.decodeFloat(field.size) else DecodeError.ExpectedFloat,
            else => {
                // We support Structs or Optional Structs only to safely decode arrays and hashmaps.
                comptime var DecodedType: type = T;
                switch (@typeInfo(DecodedType)) {
                    .Struct => {},
                    .Optional => |opt| {
                        DecodedType = opt.child;
                        switch (@typeInfo(DecodedType)) {
                            .Struct => {},
                            else => {
                                std.debug.print("expected field {any} got optional {any}\n", .{ field, DecodedType });
                                return DecodeError.UnsupportedFieldType;
                            },
                        }
                    },
                    else => {
                        std.debug.print("expected field {any} got {any}\n", .{ field, DecodedType });
                        return DecodeError.UnsupportedFieldType;
                    },
                }

                // Decode Map into std.hash_map.HashMap.
                if (@hasDecl(DecodedType, "KV")) {
                    if (field.type != FieldType.Map) {
                        return DecodeError.ExpectedMap;
                    }

                    const Key = std.meta.FieldType(DecodedType.KV, .key);
                    const Value = std.meta.FieldType(DecodedType.KV, .value);
                    var map = DecodedType.init(allocator);
                    const map_len = field.size;
                    for (0..map_len) |_| {
                        const key = try self.decodeValue(allocator, Key);
                        const value = try self.decodeValue(allocator, Value);
                        try map.put(key, value);
                    }

                    return map;
                }

                // Decode Array into std.ArrayList.
                if (@hasDecl(DecodedType, "Slice")) {
                    if (field.type != FieldType.Array) {
                        return DecodeError.ExpectedArray;
                    }

                    const Value = std.meta.Child(DecodedType.Slice);
                    var array = std.ArrayList(Value).init(allocator);
                    const array_len = field.size;
                    for (0..array_len) |_| {
                        const value = try self.decodeValue(allocator, Value);
                        try array.append(value);
                    }

                    return array;
                }

                // Decode Map into a struct, e.g., geolite2.City.continent.
                return try self.decodeStruct(allocator, T, field);
            },
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
    fn decodeBytes(self: *Decoder, field_size: usize) []u8 {
        const offset = self.offset;
        const new_offset = offset + field_size;
        self.offset = new_offset;

        return self.src[offset..new_offset];
    }

    // Decodes IEEE-754 double (binary64) in big-endian format.
    fn decodeDouble(self: *Decoder, field_size: usize) f64 {
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
    fn decodeFloat(self: *Decoder, field_size: usize) f32 {
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
    // It also support 32-bit signed integers.
    // See https://maxmind.github.io/MaxMind-DB/#integer-formats.
    fn decodeInteger(self: *Decoder, comptime T: type, field_size: usize) !T {
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
    fn decodeFieldSizeAndType(self: *Decoder) Field {
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
            field_type = @enumFromInt(src[offset] + 7);
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
        if (field_type == FieldType.Extended) {
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

// Converts the bytes slice to usize.
pub fn toUsize(bytes: []u8, prefix: usize) usize {
    var val = prefix;
    for (bytes) |b| {
        val = (val << 8) | b;
    }

    return val;
}
