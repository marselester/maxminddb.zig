const std = @import("std");

// Maximum nesting depth for decoded data structures.
pub const max_data_structure_depth: usize = 512;

// Maximum values materialized for one decode, recommended by the MaxMind DB spec.
pub const max_decoded_values: usize = 1 << 16;

// Maximum string and bytes payload materialized for one decode.
pub const max_payload_bytes: usize = 1 << 21;

// Maximum pointers followed for one decode.
// Bounds paths that traverse without allocating, which the value budget never sees.
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

// FieldHeader represents the field's data type and payload size decoded from the database.
// The payload itself starts at the decoder's offset.
pub const FieldHeader = struct {
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

    // How many of those extension bytes follow, see https://maxmind.github.io/MaxMind-DB/#payload-size.
    // A pointer encodes its size in the raw 5 bits, so it never has any.
    // The real type is a parameter because an extended one lives in the next byte.
    fn sizeExtensionBytes(self: ControlByte, field_type: FieldType) usize {
        if (field_type == .Pointer or self.size <= 28) {
            return 0;
        }

        return @as(usize, self.size) - 28;
    }
};

pub const Decoder = struct {
    src: []const u8,
    offset: usize,
    depth: usize = 0,
    pointer_follows: usize = 0,
    payload_bytes: usize = 0,
    // Starts at one: the root value is an occurrence too, so a container holding
    // exactly the limit's worth of entries is one over.
    decoded_values: usize = 1,
    strict: bool = true,

    /// The data does not decode, or a decode limit was hit.
    pub const Error = error{
        UnknownFieldType,
        InvalidMapKey,
        InvalidIntegerSize,
        InvalidBoolSize,
        InvalidDoubleSize,
        InvalidFloatSize,
        InvalidPointer,
        InvalidDataOffset,
        TooDeep,
        TooManyPointers,
        TooManyValues,
        PayloadTooLarge,
    };

    // Bounds an array's declared item count.
    // An item needs at least one byte.
    pub fn boundArray(self: *Decoder, items: usize) Error!void {
        try self.requireBytes(items);
        return self.chargeEntries(items);
    }

    // Bounds a map's declared pair count.
    // A pair needs at least two bytes, and charges one.
    // The spec counts its key and value separately, which is one of the accountings it permits.
    pub fn boundMap(self: *Decoder, pairs: usize) Error!void {
        try self.requireBytes(pairs * 2);
        return self.chargeEntries(pairs);
    }

    // Adds to this decode's running total and fails past the limit.
    // A shared pointer target is charged every time it expands,
    // which is what stops a small record from describing a huge structure.
    fn chargeEntries(self: *Decoder, entries: usize) Error!void {
        self.decoded_values += entries;
        if (self.decoded_values > max_decoded_values) {
            return error.TooManyValues;
        }
    }

    // Ensures at least n bytes remain from the current offset.
    pub inline fn requireBytes(self: *const Decoder, n: usize) Error!void {
        // Saturating subtraction avoids underflow when offset is past the end.
        if (n > self.src.len -| self.offset) {
            return error.InvalidDataOffset;
        }
    }

    // Enter one nesting level or fail if that would exceed the depth limit.
    pub fn descend(self: *Decoder) Error!void {
        if (self.depth >= max_data_structure_depth) {
            return error.TooDeep;
        }

        self.depth += 1;
    }

    pub fn ascend(self: *Decoder) void {
        self.depth -= 1;
    }

    // Resolves a pointer to its target offset.
    // Rejects a target that lands past the data section or that begins with another pointer:
    // both indicate a corrupt DB.
    pub fn followPointer(self: *Decoder, field_size: usize) Error!usize {
        self.pointer_follows += 1;
        if (self.pointer_follows > max_pointer_follows) {
            return error.TooManyPointers;
        }

        const next = try self.decodePointer(field_size);
        if (next >= self.src.len) {
            return error.InvalidPointer;
        }

        const control: ControlByte = @bitCast(self.src[next]);
        if (control.type == @intFromEnum(FieldType.Pointer)) {
            return error.InvalidPointer;
        }

        return next;
    }

    // Reads a map key, following a pointer to it if present.
    // Map keys are always strings per the spec.
    pub inline fn decodeStringKey(self: *Decoder) Error![]const u8 {
        const field = try self.decodeFieldHeader();
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

            const key_field = try self.decodeFieldHeader();
            if (key_field.type != .String) {
                return error.InvalidMapKey;
            }

            const key = try self.decodeBytes(key_field.size);

            self.offset = restore;

            return key;
        }

        return error.InvalidMapKey;
    }

    // Skips a value in the database without decoding it.
    // This is used when the database has fields that don't exist in the target struct
    // or are excluded by field name filtering.
    pub fn skipValue(self: *Decoder) Error!void {
        const field = try self.decodeFieldHeader();

        switch (field.type) {
            // Consume the pointer bytes, don't follow to its payload.
            .Pointer => _ = try self.decodePointer(field.size),
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
            // For other types, just advance the offset past the payload.
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
    // field_size is the raw 5 control-byte bits, NOT a payload byte count as in
    // the value decoders: bits 3-4 give the pointer size, bits 0-2 its high bits.
    pub fn decodePointer(self: *Decoder, field_size: usize) Error!usize {
        const pointer_value_offset = [_]usize{ 0, 0, 2048, 526_336, 0 };
        const pointer_size = ((field_size >> 3) & 0x3) + 1;
        if (self.strict) {
            try self.requireBytes(pointer_size);
        }

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
    pub fn decodeBytes(self: *Decoder, field_size: usize) Error![]const u8 {
        // Must not over-read adjacent memory into the returned slice.
        try self.requireBytes(field_size);

        // Charged per occurrence, so re-expanding a shared target charges again.
        self.payload_bytes += field_size;
        if (self.payload_bytes > max_payload_bytes) {
            return error.PayloadTooLarge;
        }

        const offset = self.offset;
        const new_offset = offset + field_size;
        self.offset = new_offset;

        return self.src[offset..new_offset];
    }

    // Decodes IEEE-754 double (binary64) in big-endian format.
    pub fn decodeDouble(self: *Decoder, field_size: usize) Error!f64 {
        if (field_size != 8) {
            return error.InvalidDoubleSize;
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
    pub fn decodeFloat(self: *Decoder, field_size: usize) Error!f32 {
        if (field_size != 4) {
            return error.InvalidFloatSize;
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
    pub fn decodeInteger(self: *Decoder, T: type, field_size: usize) Error!T {
        if (field_size > @sizeOf(T)) {
            return error.InvalidIntegerSize;
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
    pub fn decodeBool(_: *Decoder, field_size: usize) Error!bool {
        // The length information for a boolean type will always be 0 or 1, indicating the value.
        // There is no payload for this field.
        return switch (field_size) {
            0, 1 => field_size != 0,
            else => error.InvalidBoolSize,
        };
    }

    // Reads a field header, following any pointer chain to the target's payload,
    // and returns the resolved (non-pointer) field.
    pub inline fn resolveField(self: *Decoder) Error!FieldHeader {
        const field = try self.decodeFieldHeader();
        if (field.type != .Pointer) {
            return field;
        }

        // The spec forbids a target to be itself a pointer.
        self.offset = try self.followPointer(field.size);

        return try self.decodeFieldHeader();
    }

    // Checks whether the value at the current offset is an empty map, following any pointers.
    pub fn isEmptyMap(self: *Decoder) Error!bool {
        const field = try self.resolveField();
        return field.type == .Map and field.size == 0;
    }

    // Decodes a control byte into a field type and payload size.
    pub fn decodeFieldHeader(self: *Decoder) Error!FieldHeader {
        if (self.strict) {
            try self.requireBytes(1);
        }

        const control: ControlByte = @bitCast(self.src[self.offset]);
        self.offset += 1;

        // Non-extended type, size fits in the 5 control-byte bits.
        if (control.type != 0 and control.size < 29) {
            @branchHint(.likely);
            return .{
                .size = control.size,
                .type = @enumFromInt(control.type),
            };
        }

        // Extended type or size-extension bytes.
        var field_type: FieldType = @enumFromInt(control.type);
        if (field_type == FieldType.Extended) {
            if (self.strict) {
                try self.requireBytes(1);
            }

            // Extended types are 7 (Map) through 15 (Float), so valid extended byte values are 0-8.
            const ext_byte = self.src[self.offset];
            if (ext_byte > 8) {
                return error.UnknownFieldType;
            }

            field_type = @enumFromInt(ext_byte + 7);
            self.offset += 1;
        }

        const extension_bytes = control.sizeExtensionBytes(field_type);
        if (self.strict and extension_bytes > 0) {
            try self.requireBytes(extension_bytes);
        }

        return .{
            .size = self.decodeFieldSize(control, extension_bytes),
            .type = field_type,
        };
    }

    // Decodes the field size in bytes, see https://maxmind.github.io/MaxMind-DB/#payload-size.
    fn decodeFieldSize(self: *Decoder, control: ControlByte, extension_bytes: usize) usize {
        const field_size: usize = control.size;
        if (extension_bytes == 0) {
            return field_size;
        }

        const offset = self.offset;
        const new_offset = offset + extension_bytes;
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
    // This test uses SS=11, VVV=101 giving the 5-bit value 11_101=29.
    // Without the Pointer check, size extension would read 0xAA as an extra
    // byte, corrupt the size, and advance the offset.
    var d = Decoder{
        .src = &.{ 0b001_11_101, 0xAA, 0xBB, 0xCC },
        .offset = 0,
    };
    const control: ControlByte = .{
        .type = 0b001,
        .size = 0b11_101,
    };
    // A pointer never has size-extension bytes, even at 29.
    try std.testing.expectEqual(0, control.sizeExtensionBytes(.Pointer));

    const size = d.decodeFieldSize(control, control.sizeExtensionBytes(.Pointer));
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

test "followPointer enforces the follow limit" {
    // Each followed pointer counts once.
    var d = Decoder{
        .src = &.{
            0x01, // 1-byte pointer to offset 1
            0x00, // non-pointer
        },
        .offset = 0,
        .pointer_follows = max_pointer_follows - 1, // one follow left.
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
    try std.testing.expectError(error.InvalidMapKey, d.decodeStringKey());
}

test "decodeStringKey follows a pointer key and rewinds to the value" {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test-data/test-data/maps-with-pointers.raw",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(raw);

    // The map starts at 0x16, so its pointer key sits at 0x17.
    var d = Decoder{ .src = raw, .offset = 0x17 };

    const key = try d.decodeStringKey();
    try std.testing.expectEqualStrings("long_key", key);
    // The value begins right after the pointer bytes, not at the target.
    try std.testing.expectEqual(@as(usize, 0x19), d.offset);
}
