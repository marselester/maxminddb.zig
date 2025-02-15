const std = @import("std");
const decoder = @import("decoder.zig");
const mmap = @import("mmap.zig");

pub const ReadError = error{
    MetadataStartNotFound,
    InvalidTreeNode,
    CorruptedTree,
    AddressNotFound,
    UnknownRecordSize,
};

/// Metadata holds the metadata decoded from the MaxMind DB file.
/// In particular it has the format version, the build time as Unix epoch time,
/// the database type and description, the IP version supported,
/// and an array of the natural languages included.
pub const Metadata = struct {
    binary_format_major_version: u16,
    binary_format_minor_version: u16,
    build_epoch: u64,
    database_type: []const u8,
    description: std.hash_map.StringHashMap([]const u8),
    ip_version: u16,
    languages: std.ArrayList([]const u8),
    node_count: u32,
    record_size: u16,

    _arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Metadata {
        const arena = std.heap.ArenaAllocator.init(allocator);

        return .{
            .binary_format_major_version = 0,
            .binary_format_minor_version = 0,
            .build_epoch = 0,
            .database_type = "",
            .description = undefined,
            .ip_version = 0,
            .languages = undefined,
            .node_count = 0,
            .record_size = 0,

            ._arena = arena,
        };
    }

    pub fn deinit(self: *const Metadata) void {
        self._arena.deinit();
    }
};

const data_section_separator_size = 16;

pub const Reader = struct {
    mapped_file: ?std.fs.File,
    src: []u8,
    offset: usize,
    ipv4_start: usize,
    metadata: Metadata,
    allocator: std.mem.Allocator,

    // Loads a MaxMind DB file into memory.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, max_db_size: usize) !Reader {
        var f = try std.fs.cwd().openFile(path, .{});
        defer f.close();

        const src = try f.reader().readAllAlloc(allocator, max_db_size);
        errdefer allocator.free(src);

        // Decode database metadata which is stored as a separate data section,
        // see https://maxmind.github.io/MaxMind-DB/#database-metadata.
        const metadata_start = try findMetadataStart(src);
        var d = decoder.Decoder{
            .src = src[metadata_start..],
            .offset = 0,
        };
        const metadata = try d.decodeRecord(allocator, Metadata);
        errdefer metadata.deinit();

        const search_tree_size: usize = metadata.node_count * metadata.record_size / 4;

        var r = Reader{
            .mapped_file = null,
            .src = src,
            .offset = search_tree_size + data_section_separator_size,
            .ipv4_start = 0,
            .metadata = metadata,
            .allocator = allocator,
        };

        r.ipv4_start = try r.findIPv4Start();

        return r;
    }

    // Maps a MaxMind DB file into memory.
    pub fn open_mmap(allocator: std.mem.Allocator, path: []const u8) !Reader {
        var f = try std.fs.cwd().openFile(path, .{});
        errdefer f.close();

        const src = try mmap.map(f);
        errdefer mmap.unmap(src);

        // Decode database metadata which is stored as a separate data section,
        // see https://maxmind.github.io/MaxMind-DB/#database-metadata.
        const metadata_start = try findMetadataStart(src);
        var d = decoder.Decoder{
            .src = src[metadata_start..],
            .offset = 0,
        };
        const metadata = try d.decodeRecord(allocator, Metadata);
        errdefer metadata.deinit();

        const search_tree_size: usize = metadata.node_count * metadata.record_size / 4;

        var r = Reader{
            .mapped_file = f,
            .src = src,
            .offset = search_tree_size + data_section_separator_size,
            .ipv4_start = 0,
            .metadata = metadata,
            .allocator = allocator,
        };

        r.ipv4_start = try r.findIPv4Start();

        return r;
    }

    // Frees the memory occupied by the DB file.
    // From this point all the DB records are unusable because their fields were backed by the same memory.
    // Note, the records still have to be deinited since they might contain arrays or maps.
    pub fn close(self: *Reader) void {
        self.metadata.deinit();

        if (self.mapped_file == null) {
            self.allocator.free(self.src);
            return;
        }

        mmap.unmap(self.src);
        self.mapped_file.?.close();
    }

    // Looks up a record by an IP address.
    pub fn lookup(self: *Reader, comptime T: type, address: *const std.net.Address) !T {
        const ip_bytes = ipToBytes(address);
        const pointer, _ = try self.findAddressInTree(ip_bytes);
        if (pointer == 0) {
            return ReadError.AddressNotFound;
        }

        const record_offset = try self.resolveDataPointer(pointer);

        var d = decoder.Decoder{
            .src = self.src[self.offset..],
            .offset = record_offset,
        };
        return try d.decodeRecord(self.allocator, T);
    }

    fn findAddressInTree(self: *Reader, ip_address: []const u8) !struct { usize, usize } {
        const bit_count: usize = ip_address.len * 8;
        var node = self.startNode(bit_count);

        const node_count: usize = self.metadata.node_count;
        var prefix_len = bit_count;

        for (0..bit_count) |i| {
            if (node >= node_count) {
                prefix_len = i;
                break;
            }

            const bit = 1 & std.math.shr(usize, ip_address[i >> 3], 7 - (i % 8));

            node = try self.readNode(node, bit);
        }

        if (node == node_count) {
            return .{ 0, prefix_len };
        }

        if (node > node_count) {
            return .{ node, prefix_len };
        }

        return ReadError.InvalidTreeNode;
    }

    fn startNode(self: *Reader, length: usize) usize {
        return if (length == 128) 0 else self.ipv4_start;
    }

    fn findIPv4Start(self: *Reader) !usize {
        if (self.metadata.ip_version != 6) {
            return 0;
        }

        // We are looking up an IPv4 address in an IPv6 tree.
        // Skip over the first 96 nodes.
        var node: usize = 0;
        for (0..96) |_| {
            if (node >= self.metadata.node_count) {
                break;
            }

            node = try self.readNode(node, 0);
        }

        return node;
    }

    fn readNode(self: *Reader, node_number: usize, index: usize) !usize {
        const src = self.src;
        const base_offset: usize = node_number * self.metadata.record_size / 4;

        return switch (self.metadata.record_size) {
            24 => {
                const offset = base_offset + index * 3;
                return decoder.toUsize(src[offset .. offset + 3], 0);
            },
            28 => {
                var middle = src[base_offset + 3];
                if (index != 0) {
                    middle &= 0x0F;
                } else {
                    middle = (0xF0 & middle) >> 4;
                }

                const offset = base_offset + index * 4;
                return decoder.toUsize(src[offset .. offset + 3], middle);
            },
            32 => {
                const offset = base_offset + index * 4;
                return decoder.toUsize(src[offset .. offset + 4], 0);
            },
            else => ReadError.UnknownRecordSize,
        };
    }

    fn resolveDataPointer(self: *Reader, pointer: usize) !usize {
        const resolved: usize = pointer - self.metadata.node_count - data_section_separator_size;

        if (resolved > self.src.len) {
            return ReadError.CorruptedTree;
        }

        return resolved;
    }

    fn findMetadataStart(src: []u8) !usize {
        // The last occurrence of this string in the file marks the end of the data section
        // and the beginning of the metadata.
        const metadata_start_marker = "\xAB\xCD\xEFMaxMind.com";

        var metadata_start = std.mem.lastIndexOf(u8, src, metadata_start_marker) orelse {
            return ReadError.MetadataStartNotFound;
        };
        metadata_start += metadata_start_marker.len;

        return metadata_start;
    }
};

// Converts an IP address into bytes slice, e.g., IPv6 address
// 1000:0ac3:22a2:0000:0000:4b3c:0504:1234 is converted into
// [16 0 10 195 34 162 0 0 0 0 75 60 5 4 18 52].
fn ipToBytes(address: *const std.net.Address) []const u8 {
    return switch (address.any.family) {
        std.posix.AF.INET => {
            const b = std.mem.asBytes(&address.in.sa.addr).*;
            return &b;
        },
        std.posix.AF.INET6 => &address.in6.sa.addr,
        else => unreachable,
    };
}

test "ipToBytes" {
    const tests = [_]struct {
        addr: []const u8,
        want: []const u8,
    }{
        .{
            .addr = "89.160.20.128",
            .want = &.{ 89, 160, 20, 128 },
        },
        .{
            .addr = "1000:0ac3:22a2:0000:0000:4b3c:0504:1234",
            .want = &.{ 16, 0, 10, 195, 34, 162, 0, 0, 0, 0, 75, 60, 5, 4, 18, 52 },
        },
    };

    for (tests) |tc| {
        const addr = try std.net.Address.parseIp(tc.addr, 0);
        try std.testing.expectEqualStrings(tc.want, ipToBytes(&addr));
    }
}
