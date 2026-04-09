const std = @import("std");

pub fn Fields(comptime capacity: usize) type {
    return struct {
        items: [capacity][]const u8 = undefined,
        len: usize = 0,
        buf: ?[]u8 = null,

        const Self = @This();
        pub const Error = error{TooManyFields};

        /// Parses a string into field names.
        pub fn parse(str: []const u8, sep: u8) Error!Self {
            var f: Self = .{};

            var it = std.mem.splitScalar(u8, str, sep);
            while (it.next()) |part| {
                try f.append(part);
            }

            return f;
        }

        /// Parses a string, copying bytes into a heap-allocated buffer.
        /// Use this when the Fields must outlive the input string.
        /// Call deinit() to free the buffer.
        pub fn parseAlloc(allocator: std.mem.Allocator, str: []const u8, sep: u8) !Self {
            const buf = try allocator.dupe(u8, str);
            errdefer allocator.free(buf);

            var f = try parse(buf, sep);
            // Don't keep the buffer if no fields were parsed, e.g., empty string.
            if (f.len == 0) {
                allocator.free(buf);
                return .{};
            }

            f.buf = buf;

            return f;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.buf) |buf| {
                allocator.free(buf);
                self.buf = null;
            }
        }

        pub fn append(self: *Self, raw_name: []const u8) Error!void {
            const name = std.mem.trim(u8, raw_name, &std.ascii.whitespace);
            if (name.len == 0) return;
            if (self.len >= capacity) return error.TooManyFields;

            self.items[self.len] = name;
            self.len += 1;
        }

        /// Returns the stored field names, or null if none were added.
        /// null means "decode all fields" - no filter was specified.
        pub fn only(self: *const Self) ?[]const []const u8 {
            return if (self.len > 0) self.items[0..self.len] else null;
        }
    };
}

test "parse" {
    const tests = [_]struct {
        input: []const u8,
        want: ?[]const []const u8,
    }{
        .{ .input = "city, country, postal", .want = &.{ "city", "country", "postal" } },
        .{ .input = "  city ,  country  ", .want = &.{ "city", "country" } },
        .{ .input = ",city,,country,", .want = &.{ "city", "country" } },
        .{ .input = "", .want = null },
    };

    for (tests) |tc| {
        const f = try Fields(4).parse(tc.input, ',');
        const got = f.only();

        if (tc.want) |want| {
            try std.testing.expectEqual(want.len, got.?.len);
            for (want, got.?) |w, g| {
                try std.testing.expectEqualStrings(w, g);
            }
        } else {
            try std.testing.expectEqual(null, got);
        }
    }
}

test "parse stops at capacity" {
    const result = Fields(2).parse("a,b,c,d", ',');
    try std.testing.expectError(error.TooManyFields, result);
}

test "append and only" {
    var f: Fields(3) = .{};
    try f.append("city");
    try f.append("country");
    const s = f.only() orelse return error.UnexpectedNull;

    try std.testing.expectEqual(2, s.len);
    try std.testing.expectEqualStrings("city", s[0]);
    try std.testing.expectEqualStrings("country", s[1]);
}

test "append trims whitespace-only to no-op" {
    var f: Fields(3) = .{};
    try f.append("   ");
    try f.append("");
    try f.append("\t");
    try f.append("\n");
    try std.testing.expectEqual(null, f.only());
}

test "parseAlloc empty string does not allocate" {
    var f = try Fields(4).parseAlloc(std.testing.allocator, "", ',');
    defer f.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, f.only());
    try std.testing.expectEqual(null, f.buf);
}

test "parseAlloc whitespace-only does not allocate" {
    var f = try Fields(4).parseAlloc(std.testing.allocator, "  ,  ,  ", ',');
    defer f.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, f.only());
    try std.testing.expectEqual(null, f.buf);
}

test "parseAlloc frees buffer on TooManyFields" {
    const result = Fields(1).parseAlloc(std.testing.allocator, "a,b", ',');
    try std.testing.expectError(error.TooManyFields, result);
}

test "parseAlloc copies bytes" {
    var input = "city, country".*;
    var f = try Fields(4).parseAlloc(std.testing.allocator, &input, ',');
    defer f.deinit(std.testing.allocator);

    // Overwrite input to prove fields don't borrow it.
    @memset(&input, 'x');

    const got = f.only().?;
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqualStrings("city", got[0]);
    try std.testing.expectEqualStrings("country", got[1]);
}
