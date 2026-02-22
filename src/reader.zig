const std = @import("std");
const decoder = @import("decoder.zig");
const memorymap = @import("mmap.zig");
const net = @import("net.zig");

pub const ReadError = error{
    MetadataStartNotFound,
    InvalidTreeNode,
    CorruptedTree,
    UnknownRecordSize,
    InvalidPrefixLen,
};

/// Metadata holds the metadata decoded from the MaxMind DB file.
/// In particular it has the format version, the build time as Unix epoch time,
/// the database type and description, the IP version supported,
/// and an array of the natural languages included.
pub const Metadata = struct {
    binary_format_major_version: u16 = 0,
    binary_format_minor_version: u16 = 0,
    build_epoch: u64 = 0,
    database_type: []const u8 = "",
    description: ?std.StringArrayHashMap([]const u8) = null,
    ip_version: u16 = 0,
    languages: ?std.ArrayList([]const u8) = null,
    node_count: u32 = 0,
    record_size: u16 = 0,
};

const data_section_separator_size = 16;

pub const Options = struct {
    only: ?decoder.Fields = null,
};

pub const Reader = struct {
    mapped_file: ?std.fs.File,
    src: []const u8,
    offset: usize,
    ipv4_start: usize,
    metadata: Metadata,
    metadata_arena: std.heap.ArenaAllocator,

    // Loads a MaxMind DB file into memory.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, max_db_size: usize) !Reader {
        var f = try std.fs.cwd().openFile(path, .{});
        defer f.close();

        const src = try f.readToEndAlloc(allocator, max_db_size);
        errdefer allocator.free(src);

        var metadata_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer metadata_arena.deinit();
        const metadata = try decodeMetadata(metadata_arena.allocator(), src);

        const search_tree_size = try std.math.mul(
            usize,
            metadata.node_count,
            metadata.record_size / 4,
        );
        const data_offset = search_tree_size + data_section_separator_size;
        if (data_offset > src.len) {
            return ReadError.CorruptedTree;
        }

        var r = Reader{
            .mapped_file = null,
            .src = src,
            .offset = data_offset,
            .ipv4_start = 0,
            .metadata = metadata,
            .metadata_arena = metadata_arena,
        };

        r.ipv4_start = try r.findIPv4Start();

        return r;
    }

    // Frees the memory occupied by the DB file.
    // From this point all the DB records are unusable because their fields were backed by the same memory.
    // Note, the records still have to be deinited since they might contain arrays or maps.
    pub fn close(self: *Reader, allocator: std.mem.Allocator) void {
        self.metadata_arena.deinit();
        allocator.free(self.src);
    }

    // Maps a MaxMind DB file into memory.
    pub fn mmap(allocator: std.mem.Allocator, path: []const u8) !Reader {
        var f = try std.fs.cwd().openFile(path, .{});
        errdefer f.close();

        const src = try memorymap.map(f);
        errdefer memorymap.unmap(src);

        var metadata_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer metadata_arena.deinit();
        const metadata = try decodeMetadata(metadata_arena.allocator(), src);

        const search_tree_size = try std.math.mul(
            usize,
            metadata.node_count,
            metadata.record_size / 4,
        );
        const data_offset = search_tree_size + data_section_separator_size;
        if (data_offset > src.len) {
            return ReadError.CorruptedTree;
        }

        var r = Reader{
            .mapped_file = f,
            .src = src,
            .offset = data_offset,
            .ipv4_start = 0,
            .metadata = metadata,
            .metadata_arena = metadata_arena,
        };

        r.ipv4_start = try r.findIPv4Start();

        return r;
    }

    // Unmaps the DB file.
    // From this point all the DB records are unusable because their fields were backed by the same memory.
    // Note, the records still have to be deinited since they might contain arrays or maps.
    pub fn unmap(self: *Reader) void {
        self.metadata_arena.deinit();

        memorymap.unmap(self.src);
        self.mapped_file.?.close();
    }

    // Looks up a value by an IP address.
    // The returned Result owns an arena with all decoded allocations.
    pub fn lookup(
        self: *Reader,
        allocator: std.mem.Allocator,
        T: type,
        address: std.net.Address,
        options: Options,
    ) !?Result(T) {
        const ip = net.IP.init(address);
        const pointer, const prefix_len = try self.findAddressInTree(ip);
        if (pointer == 0) {
            return null;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const value = try self.resolveDataPointerAndDecode(
            arena.allocator(),
            T,
            pointer,
            options.only,
        );

        return .{
            .network = ip.mask(prefix_len).network(prefix_len),
            .value = value,
            .arena = arena,
        };
    }

    // Iterates over blocks of IP networks.
    pub fn within(
        self: *Reader,
        allocator: std.mem.Allocator,
        T: type,
        network: net.Network,
        options: Options,
    ) !Iterator(T) {
        const ip_bytes = net.IP.init(network.ip);
        const prefix_len: usize = network.prefix_len;
        const bit_count: usize = ip_bytes.bitCount();

        if (prefix_len > bit_count) {
            return ReadError.InvalidPrefixLen;
        }

        var node = self.startNode(bit_count);
        const node_count = self.metadata.node_count;

        var stack = try std.ArrayList(WithinNode).initCapacity(allocator, bit_count - prefix_len + 1);
        errdefer stack.deinit(allocator);

        // Traverse down the tree to the level that matches the CIDR mark.
        var i: usize = 0;
        while (i < prefix_len) {
            const bit = ip_bytes.bitAt(i);

            node = try self.readNode(node, bit);
            // We've hit a dead end before we exhausted our prefix.
            if (node >= node_count) {
                break;
            }

            i += 1;
        }

        // Now anything that's below node in the tree is "within",
        // start with the node we traversed to as our to be processed stack.
        // Else the stack will be empty and we'll be returning an iterator that visits nothing.
        if (node < node_count) {
            stack.appendAssumeCapacity(WithinNode{
                .node = node,
                .ip_bytes = ip_bytes,
                .prefix_len = prefix_len,
            });
        }

        return .{
            .reader = self,
            .node_count = node_count,
            .stack = stack,
            .allocator = allocator,
            .cache = .{},
            .fields = options.only,
        };
    }

    // Decodes database metadata which is stored as a separate data section,
    // see https://maxmind.github.io/MaxMind-DB/#database-metadata.
    fn decodeMetadata(allocator: std.mem.Allocator, src: []const u8) !Metadata {
        const metadata_start = try findMetadataStart(src);

        var d = decoder.Decoder{
            .src = src[metadata_start..],
            .offset = 0,
        };

        return try d.decodeRecord(allocator, Metadata, null);
    }

    fn resolveDataPointerAndDecode(
        self: *Reader,
        allocator: std.mem.Allocator,
        T: type,
        pointer: usize,
        fields: ?decoder.Fields,
    ) !T {
        const record_offset = try self.resolveDataPointer(pointer);

        var d = decoder.Decoder{
            .src = self.src[self.offset..],
            .offset = record_offset,
        };

        return try d.decodeRecord(allocator, T, fields);
    }

    fn resolveDataPointer(self: *Reader, pointer: usize) !usize {
        const min_pointer = self.metadata.node_count + data_section_separator_size;
        if (pointer < min_pointer) {
            return ReadError.CorruptedTree;
        }

        const resolved: usize = pointer - min_pointer;
        if (self.offset > self.src.len or resolved >= self.src.len - self.offset) {
            return ReadError.CorruptedTree;
        }

        return resolved;
    }

    fn findAddressInTree(self: *Reader, ip: net.IP) !struct { usize, usize } {
        const bit_count = ip.bitCount();
        var node = self.startNode(bit_count);

        const node_count: usize = self.metadata.node_count;
        var prefix_len = bit_count;

        for (0..bit_count) |i| {
            if (node >= node_count) {
                prefix_len = i;
                break;
            }

            node = try self.readNode(node, ip.bitAt(i));
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

    fn findMetadataStart(src: []const u8) !usize {
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

/// Result wraps a decoded value with an arena that owns all its allocations.
/// Use deinit() to free the result's memory, or skip it when using an outer arena.
pub fn Result(comptime T: type) type {
    return struct {
        network: net.Network,
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: @This()) void {
            self.arena.deinit();
        }
    };
}

const WithinNode = struct {
    ip_bytes: net.IP,
    prefix_len: usize,
    node: usize,
};

pub fn Iterator(T: type) type {
    return struct {
        reader: *Reader,
        node_count: usize,
        stack: std.ArrayList(WithinNode),
        allocator: std.mem.Allocator,
        fields: ?decoder.Fields,
        cache: Cache,

        // Ring buffer cache of recently decoded records.
        // Many adjacent networks in the tree share the same data pointer,
        // so caching avoids re-decoding the same record repeatedly.
        // Once full, new entries overwrite the oldest slot in a circular fashion.
        // Each entry owns an arena that backs the decoded value's allocations;
        // the arena is freed on eviction.
        const Cache = struct {
            const Entry = struct {
                pointer: usize,
                value: T,
                arena: std.heap.ArenaAllocator,
            };

            // 16 showed a good tradeoff in DuckDB table scan,
            // see https://github.com/marselester/duckdb-maxmind.
            const cache_size = 16;
            entries: [cache_size]Entry = undefined,
            // Indicates number of entries in the cache.
            len: usize = 0,
            // It's an index in the entries array where a new item will be written at.
            write_pos: usize = 0,

            fn lookup(self: *Cache, pointer: usize) ?T {
                for (self.entries[0..self.len]) |e| {
                    if (e.pointer == pointer) {
                        return e.value;
                    }
                }

                return null;
            }

            fn insert(
                self: *Cache,
                pointer: usize,
                value: T,
                arena: std.heap.ArenaAllocator,
            ) void {
                if (self.len < cache_size) {
                    self.entries[self.len] = .{
                        .pointer = pointer,
                        .value = value,
                        .arena = arena,
                    };
                    self.len += 1;

                    return;
                }

                // Evict oldest entry.
                self.entries[self.write_pos].arena.deinit();
                self.entries[self.write_pos] = .{
                    .pointer = pointer,
                    .value = value,
                    .arena = arena,
                };
                self.write_pos = (self.write_pos + 1) % cache_size;
            }

            fn deinit(self: *Cache) void {
                for (self.entries[0..self.len]) |*e| {
                    e.arena.deinit();
                }
            }
        };

        const Self = @This();

        pub const Item = struct {
            network: net.Network,
            value: T,
        };

        /// Returns the next network and its value.
        /// The iterator owns the value; each call eventually invalidates the previous Item.
        pub fn next(self: *Self) !?Item {
            while (self.stack.pop()) |current| {
                const reader = self.reader;
                const bit_count = current.ip_bytes.bitCount();

                // Skip networks that are aliases for the IPv4 network.
                if (reader.ipv4_start != 0 and
                    reader.ipv4_start == current.node and
                    bit_count == 128 and
                    !current.ip_bytes.isV4InV6())
                {
                    continue;
                }

                // Found a data node to decode a record, e.g., geolite2.City.
                if (current.node > self.node_count) {
                    const ip_net = current.ip_bytes.network(current.prefix_len);

                    // Check the ring buffer cache.
                    // Recently decoded records are reused.
                    if (self.cache.lookup(current.node)) |cached_value| {
                        return Item{
                            .network = ip_net,
                            .value = cached_value,
                        };
                    }

                    var entry_arena = std.heap.ArenaAllocator.init(self.allocator);
                    errdefer entry_arena.deinit();

                    const value = try reader.resolveDataPointerAndDecode(
                        entry_arena.allocator(),
                        T,
                        current.node,
                        self.fields,
                    );

                    self.cache.insert(current.node, value, entry_arena);

                    return Item{
                        .network = ip_net,
                        .value = value,
                    };
                } else if (current.node < self.node_count) {
                    // In order traversal of the children on the right (1-bit).
                    var node = try reader.readNode(current.node, 1);
                    var right_ip_bytes = current.ip_bytes;

                    if (current.prefix_len < bit_count) {
                        const bit = current.prefix_len;
                        switch (right_ip_bytes) {
                            .v4 => |*b| b[bit >> 3] |= std.math.shl(u8, 1, (bit_count - bit - 1) % 8),
                            .v6 => |*b| b[bit >> 3] |= std.math.shl(u8, 1, (bit_count - bit - 1) % 8),
                        }
                    }

                    self.stack.appendAssumeCapacity(WithinNode{
                        .node = node,
                        .ip_bytes = right_ip_bytes,
                        .prefix_len = current.prefix_len + 1,
                    });

                    // In order traversal of the children on the left (0-bit).
                    node = try reader.readNode(current.node, 0);
                    self.stack.appendAssumeCapacity(WithinNode{
                        .node = node,
                        .ip_bytes = current.ip_bytes,
                        .prefix_len = current.prefix_len + 1,
                    });
                }
            }

            return null;
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit();
            self.stack.deinit(self.allocator);
        }
    };
}
