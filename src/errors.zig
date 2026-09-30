const std = @import("std");

const reader = @import("reader.zig");
const typed = @import("typed.zig");
const net = @import("net.zig");
const cache = @import("cache.zig");
const filter = @import("filter.zig");

/// Every error this library defines, without OutOfMemory or OS errors.
pub const Error = reader.Reader.InvalidDatabaseError ||
    reader.Reader.CorruptDataError ||
    typed.SchemaError ||
    reader.Reader.AddressError ||
    net.Network.ParseError ||
    reader.Reader.OptionsError ||
    cache.Cache(void).Error ||
    filter.Fields(0).Error;

/// The kind of an error, grouped by what a caller does about it.
pub const ErrorCategory = enum {
    /// The file is not a MaxMind DB this reader supports.
    invalid_database,
    /// The metadata, the search tree, or the data section does not decode.
    corrupt_data,
    /// Fix the Zig type the record is decoded into.
    schema,
    /// Fix the query.
    address,
    /// Fix the configuration.
    options,
    /// Retry later or fail the operation.
    out_of_memory,
    /// Check the path and the permissions.
    file_system,
};

/// Classifies an error so a caller can switch on the category.
pub fn errorCategory(err: (Error || reader.Reader.OpenError)) ErrorCategory {
    return switch (err) {
        error.EmptyFile,
        error.MetadataStartNotFound,
        error.InvalidMetadata,
        error.UnsupportedBinaryFormat,
        error.EmptyDatabase,
        error.UnknownRecordSize,
        error.UnknownIPVersion,
        => .invalid_database,

        error.CorruptedTree,
        error.InvalidTreeNode,
        error.UnknownFieldType,
        error.InvalidMapKey,
        error.InvalidIntegerSize,
        error.InvalidBoolSize,
        error.InvalidDoubleSize,
        error.InvalidFloatSize,
        error.InvalidPointer,
        error.InvalidDataOffset,
        error.TooDeep,
        error.TooManyPointers,
        error.TooManyValues,
        error.PayloadTooLarge,
        => .corrupt_data,

        error.ExpectedStructType,
        error.ExpectedMap,
        error.ExpectedArray,
        error.ExpectedDouble,
        error.ExpectedFloat,
        error.ExpectedUint16,
        error.ExpectedUint32,
        error.ExpectedInt32,
        error.ExpectedUint64,
        error.ExpectedUint128,
        error.ExpectedBool,
        error.ExpectedStringOrBytes,
        error.UnsupportedType,
        => .schema,

        error.IPv6AddressInIPv4Database,
        error.InvalidPrefixLen,
        error.InvalidAddress,
        => .address,

        error.InvalidIndexBits,
        error.InvalidCacheSize,
        error.TooManyFields,
        => .options,

        error.OutOfMemory => .out_of_memory,

        else => .file_system,
    };
}

test "errorCategory maps a sample of every category" {
    const tests = [_]struct {
        err: (Error || reader.Reader.OpenError),
        want: ErrorCategory,
    }{
        .{
            .err = error.InvalidMetadata,
            .want = .invalid_database,
        },
        .{
            .err = error.EmptyFile,
            .want = .invalid_database,
        },
        .{
            .err = error.CorruptedTree,
            .want = .corrupt_data,
        },
        .{
            .err = error.TooManyPointers,
            .want = .corrupt_data,
        },
        .{
            .err = error.ExpectedUint16,
            .want = .schema,
        },
        .{
            .err = error.IPv6AddressInIPv4Database,
            .want = .address,
        },
        .{
            .err = error.InvalidPrefixLen,
            .want = .address,
        },
        .{
            .err = error.InvalidCacheSize,
            .want = .options,
        },
        .{
            .err = error.OutOfMemory,
            .want = .out_of_memory,
        },
        .{
            .err = error.FileNotFound,
            .want = .file_system,
        },
        .{
            .err = error.Unexpected,
            .want = .file_system,
        },
    };

    for (tests) |tc| {
        const got = errorCategory(tc.err);
        try std.testing.expectEqual(tc.want, got);
    }
}
