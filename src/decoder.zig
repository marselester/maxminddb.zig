const std = @import("std");

pub const DecodeError = error{
    UnsupportedFieldType,
    ExpectedString,
    ExpectedStringOrBytes,
    InvalidIntegerSize,
    InvalidBoolSize,
    InvalidDoubleSize,
    InvalidFloatSize,
    TooDeep,
    TooManyPointers,
    InvalidPointer,
    InvalidDataOffset,
};

// Maximum nesting depth for decoded data structures.
pub const max_data_structure_depth: usize = 512;

// Maximum pointers followed while decoding one record.
// Bounds pointer amplification and cycles to prevent a runaway decode.
pub const max_pointer_follows: usize = 1 << 20;

// These are database field types as defined in the spec.
pub const FieldType = enum {
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
pub const DataField = struct {
    size: usize,
    type: FieldType,
};

// A single control byte in the MMDB wire format,
// see https://maxmind.github.io/MaxMind-DB/#data-field-format.
//
// The type 0 means the real type is encoded in the next byte.
// The size in 29..31 means extension bytes follow to encode the real size.
const ControlByte = packed struct(u8) {
    size: u5,
    type: u3,
};

pub const Decoder = struct {
    src: []const u8,
    offset: usize,
    depth: usize = 0,
    // Remaining pointers this decode may follow, decremented per follow.
    budget: usize = max_pointer_follows,

    // Ensures at least n bytes remain from the current offset.
    pub inline fn requireBytes(self: *const Decoder, n: usize) DecodeError!void {
        // Saturating subtraction avoids underflow when offset is past the end.
        if (n > self.src.len -| self.offset) {
            return DecodeError.InvalidDataOffset;
        }
    }

    // Enter one nesting level or fail if that would exceed the depth limit.
    pub fn descend(self: *Decoder) DecodeError!void {
        if (self.depth >= max_data_structure_depth) {
            return DecodeError.TooDeep;
        }

        self.depth += 1;
    }

    pub fn ascend(self: *Decoder) void {
        self.depth -= 1;
    }

    // Resolves a pointer to its target offset.
    // Rejects a target that lands past the data section or that begins with another pointer:
    // both indicate a corrupt DB.
    pub fn followPointer(self: *Decoder, field_size: usize) DecodeError!usize {
        // Charge the traversal budget per pointer followed.
        if (self.budget == 0) {
            return DecodeError.TooManyPointers;
        }
        self.budget -= 1;

        const next = self.decodePointer(field_size);
        if (next >= self.src.len) {
            return DecodeError.InvalidPointer;
        }

        const cb: ControlByte = @bitCast(self.src[next]);
        if (cb.type == @intFromEnum(FieldType.Pointer)) {
            return DecodeError.InvalidPointer;
        }

        return next;
    }

    // Reads a map key, following a pointer to it if present.
    // Map keys are always strings per the spec.
    pub inline fn decodeStringKey(self: *Decoder) DecodeError![]const u8 {
        const field = try self.decodeFieldSizeAndType();
        if (field.type == .String) {
            return self.decodeBytes(field.size);
        }

        // A pointer key resolves to a string elsewhere.
        // The value follows the pointer bytes,
        // so rewind to that position after reading the key.
        if (field.type == .Pointer) {
            const target = try self.followPointer(field.size);
            const restore = self.offset;
            self.offset = target;

            const key_field = try self.decodeFieldSizeAndType();
            if (key_field.type != .String) {
                return DecodeError.ExpectedString;
            }

            const key = try self.decodeBytes(key_field.size);

            self.offset = restore;

            return key;
        }

        return DecodeError.ExpectedString;
    }

    // Skips a value in the database without decoding it.
    // This is used when the database has fields that don't exist in the target struct
    // or are excluded by field name filtering.
    pub fn skipValue(self: *Decoder) !void {
        const field = try self.decodeFieldSizeAndType();

        switch (field.type) {
            // Consume the pointer bytes, don't follow to its payload.
            .Pointer => _ = self.decodePointer(field.size),
            // Bool has no payload, size is encoded in the control byte.
            .Bool => {},
            // Skip each array element.
            .Array => {
                try self.descend();
                defer self.ascend();

                for (0..field.size) |_| {
                    try self.skipValue();
                }
            },
            // Skip each map key-value pair.
            .Map => {
                try self.descend();
                defer self.ascend();

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

    // Decodes a pointer to another part of the data section's address space.
    // The pointer will point to the beginning of a field.
    // It is illegal for a pointer to point to another pointer.
    // Pointer values start from the beginning of the data section, not the beginning of the file.
    // Pointers in the metadata start from the beginning of the metadata section.
    pub fn decodePointer(self: *Decoder, field_size: usize) usize {
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
    pub fn decodeBytes(self: *Decoder, field_size: usize) DecodeError![]const u8 {
        // Must not over-read adjacent memory into the returned slice.
        try self.requireBytes(field_size);

        const offset = self.offset;
        const new_offset = offset + field_size;
        self.offset = new_offset;

        return self.src[offset..new_offset];
    }

    // Decodes IEEE-754 double (binary64) in big-endian format.
    pub fn decodeDouble(self: *Decoder, field_size: usize) !f64 {
        if (field_size != 8) {
            return DecodeError.InvalidDoubleSize;
        }

        try self.requireBytes(field_size);

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
    pub fn decodeFloat(self: *Decoder, field_size: usize) !f32 {
        if (field_size != 4) {
            return DecodeError.InvalidFloatSize;
        }

        try self.requireBytes(field_size);

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
    pub fn decodeInteger(self: *Decoder, T: type, field_size: usize) !T {
        if (field_size > @sizeOf(T)) {
            return DecodeError.InvalidIntegerSize;
        }

        try self.requireBytes(field_size);

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
    pub fn decodeBool(_: *Decoder, field_size: usize) !bool {
        // The length information for a boolean type will always be 0 or 1, indicating the value.
        // There is no payload for this field.
        return switch (field_size) {
            0, 1 => field_size != 0,
            else => DecodeError.InvalidBoolSize,
        };
    }

    // Reads a field header, following any pointer chain to the target's payload,
    // and returns the resolved (non-pointer) field.
    pub inline fn resolveField(self: *Decoder) DecodeError!DataField {
        var field = try self.decodeFieldSizeAndType();
        while (field.type == .Pointer) {
            self.offset = try self.followPointer(field.size);
            field = try self.decodeFieldSizeAndType();
        }

        return field;
    }

    // Checks whether the value at the current offset is an empty map, following any pointers.
    pub fn isEmptyMap(self: *Decoder) !bool {
        const field = try self.resolveField();
        return field.type == .Map and field.size == 0;
    }

    // Decodes a control byte into a field type and payload size.
    pub fn decodeFieldSizeAndType(self: *Decoder) !DataField {
        const cb: ControlByte = @bitCast(self.src[self.offset]);
        self.offset += 1;

        // Non-extended type, size fits in the 5 control-byte bits.
        if (cb.type != 0 and cb.size < 29) {
            @branchHint(.likely);
            return .{
                .size = cb.size,
                .type = @enumFromInt(cb.type),
            };
        }

        // Extended type or size-extension bytes.
        var field_type: FieldType = @enumFromInt(cb.type);
        if (field_type == FieldType.Extended) {
            // Extended types are 7 (Map) through 15 (Float), so valid extended byte values are 0-8.
            const ext_byte = self.src[self.offset];
            if (ext_byte > 8) {
                return DecodeError.UnsupportedFieldType;
            }

            field_type = @enumFromInt(ext_byte + 7);
            self.offset += 1;
        }

        return .{
            .size = self.decodeFieldSize(cb, field_type),
            .type = field_type,
        };
    }

    // Decodes the field size in bytes, see https://maxmind.github.io/MaxMind-DB/#payload-size.
    fn decodeFieldSize(self: *Decoder, cb: ControlByte, field_type: FieldType) usize {
        // Pointer types use the raw 5-bit size without extension.
        const field_size: usize = cb.size;
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
            29 => 29 + toUsize(size_bytes, 0),
            30 => 285 + toUsize(size_bytes, 0),
            else => 65_821 + toUsize(size_bytes, 0),
        };
    }
};

// Converts the bytes slice to usize.
pub fn toUsize(bytes: []const u8, prefix: usize) usize {
    var val = prefix;
    for (bytes) |b| {
        val = (val << 8) | b;
    }

    return val;
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
    const cb: ControlByte = .{
        .type = 0b001,
        .size = 0b11_101,
    };
    const size = d.decodeFieldSize(cb, .Pointer);
    try std.testing.expectEqual(29, size);
    // Offset must not advance, i.e., no extra bytes read for size extension.
    try std.testing.expectEqual(0, d.offset);
}

test "isEmptyMap rejects a pointer to a pointer" {
    // 0x20 is a 1-byte pointer whose payload byte is the target offset.
    // The pointer at offset 0 resolves to offset 2, which is itself a pointer (illegal).
    // The empty-record check follows pointers via followPointer,
    // so it rejects this rather than chasing it.
    var d = Decoder{
        .src = &.{ 0x20, 0x02, 0x20, 0x00 },
        .offset = 0,
    };

    try std.testing.expectError(error.InvalidPointer, d.isEmptyMap());
}

test "followPointer enforces the traversal budget" {
    // Each followed pointer costs one budget unit.
    var d = Decoder{
        .src = &.{
            0x01, // 1-byte pointer to offset 1
            0x00, // non-pointer
        },
        .offset = 0,
        .budget = 1, // permits one follow, the next trips.
    };

    _ = try d.followPointer(0);
    try std.testing.expectError(error.TooManyPointers, d.followPointer(0));
}

test "decodeStringKey rejects a non-string key" {
    var d = Decoder{
        .src = &.{
            0x81, // Bytes value (type 4, size 1).
            0xAA,
        },
        .offset = 0,
    };
    try std.testing.expectError(error.ExpectedString, d.decodeStringKey());
}

test "decodeStringKey follows a pointer key and rewinds to the value" {
    // The key at offset 0 is a pointer to offset 4, where "hi" (0x42 = String, size 2) lives.
    // The value would begin at offset 2, right after the pointer bytes.
    var d = Decoder{
        .src = &.{ 0x20, 0x04, 0xAB, 0xCD, 0x42, 0x68, 0x69 },
        .offset = 0,
    };

    const key = try d.decodeStringKey();
    try std.testing.expectEqualStrings("hi", key);
    try std.testing.expectEqual(@as(usize, 2), d.offset);
}
