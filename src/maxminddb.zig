const reader = @import("reader.zig");
const decoder = @import("decoder.zig");

pub const geolite2 = @import("geolite2.zig");

pub const Error = reader.ReadError || decoder.DecodeError;
pub const Reader = reader.Reader;
pub const Metadata = reader.Metadata;

test {
    @import("std").testing.refAllDecls(@This());
}
