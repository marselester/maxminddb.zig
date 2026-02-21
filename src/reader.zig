const std = @import("std");

const decoder = @import("decoder.zig");
const collection = @import("collection.zig");
const memorymap = @import("mmap.zig");
const net = @import("net.zig");

pub const ReadError = error{
    MetadataStartNotFound,
    InvalidTreeNode,
    CorruptedTree,
    UnknownRecordSize,
    InvalidPrefixLen,
    IPv6AddressInIPv4Database,
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
    description: ?collection.Map([]const u8) = null,
    ip_version: u16 = 0,
    languages: ?collection.Array([]const u8) = null,
    node_count: u32 = 0,
    record_size: u16 = 0,
};

const data_section_separator_size = 16;

pub const LookupOptions = struct {
    only: ?[]const []const u8 = null,
};

pub const WithinOptions = struct {
    only: ?[]const []const u8 = null,
    include_empty_values: bool = true,
};

pub const Reader = struct {
    src: []const u8,
    offset: usize,
    ipv4_start: usize,
    // ipv4_index contains a mix of node IDs and data offsets
    // for fast lookup of IPv4 addresses by their first N bits.
    // Instead of fetching the start node, then its right child, and so on,
    // these paths are flattened into ipv4_index array for direct access with Eytzinger layout.
    ipv4_index_first_n_bits: usize,
    ipv4_index: ?[]usize,
    metadata: Metadata,

    is_mapped: bool,
    arena: *std.heap.ArenaAllocator,

    fn init(arena: *std.heap.ArenaAllocator, src: []const u8) !Reader {
        const metadata = try decodeMetadata(arena.allocator(), src);

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
            .src = src,
            .offset = data_offset,
            .ipv4_start = 0,
            .ipv4_index_first_n_bits = 0,
            .ipv4_index = null,
            .metadata = metadata,
            .is_mapped = false,
            .arena = arena,
        };

        try r.setIPv4Start();

        return r;
    }

    /// Loads a MaxMind DB file into memory.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, max_db_size: usize) !Reader {
        var f = try std.fs.cwd().openFile(path, .{});
        defer f.close();

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);

        const src = try f.readToEndAlloc(arena.allocator(), max_db_size);

        return try init(arena, src);
    }

    /// Maps a MaxMind DB file into memory.
    pub fn mmap(allocator: std.mem.Allocator, path: []const u8) !Reader {
        const src = try memorymap.map(path);
        errdefer memorymap.unmap(src);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);

        var r = try init(arena, src);
        r.is_mapped = true;

        return r;
    }

    /// Frees the memory occupied by the DB file.
    /// From this point all the DB records are unusable because their fields were backed by the same memory.
    /// Note, the records still have to be deinited since they might contain arrays or maps.
    pub fn close(self: *Reader) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);

        if (self.is_mapped) {
            memorymap.unmap(self.src);
        }
    }

    /// Looks up a value by an IP address.
    /// The returned Result owns an arena with all decoded allocations.
    pub fn lookup(
        self: *Reader,
        allocator: std.mem.Allocator,
        T: type,
        address: std.net.Address,
        options: LookupOptions,
    ) !?Result(T) {
        const ip = net.IP.init(address);
        if (ip.bitCount() == 128 and self.metadata.ip_version == 4) {
            return ReadError.IPv6AddressInIPv4Database;
        }

        var pointer: usize = 0;
        var prefix_len: usize = 0;
        if (self.ipv4_index != null and ip == .v4) {
            pointer, prefix_len = try self.findAddressInTreeWithIndex(ip);
        } else {
            const start_node = self.startNode(ip.bitCount());
            pointer, prefix_len = try self.findAddressInTree(ip, start_node, 0);
        }

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

    /// Iterates over blocks of IP networks.
    pub fn within(
        self: *Reader,
        allocator: std.mem.Allocator,
        T: type,
        network: net.Network,
        options: WithinOptions,
    ) !Iterator(T) {
        const prefix_len: usize = network.prefix_len;
        const ip_raw = net.IP.init(network.ip);
        const bit_count: usize = ip_raw.bitCount();

        if (prefix_len > bit_count) {
            return ReadError.InvalidPrefixLen;
        }
        if (bit_count == 128 and self.metadata.ip_version == 4) {
            return ReadError.IPv6AddressInIPv4Database;
        }

        var node = self.startNode(bit_count);
        const node_count = self.metadata.node_count;

        var stack = try std.ArrayList(WithinNode).initCapacity(allocator, bit_count - prefix_len + 1);
        errdefer stack.deinit(allocator);

        const ip_bytes = ip_raw.mask(prefix_len);
        // Traverse down the tree to the level that matches the CIDR mark.
        // Track depth as number of tree edges traversed (becomes the network prefix length).
        var depth: usize = 0;
        if (node < node_count) {
            while (depth < prefix_len) {
                node = try self.readNode(node, ip_bytes.bitAt(depth));
                depth += 1;
                if (node >= node_count) {
                    break;
                }
            }
        }

        // Push the node to the stack unless it's "not found" (equal to node_count).
        // Data pointer (> node_count) indicates that record's network contains the query prefix.
        // Internal node (< node_count) indicates that we need to explore its subtree.
        if (node != node_count) {
            stack.appendAssumeCapacity(WithinNode{
                .node = node,
                .ip_bytes = ip_bytes.mask(depth),
                .prefix_len = depth,
            });
        }

        return .{
            .reader = self,
            .node_count = node_count,
            .stack = stack,
            .allocator = allocator,
            .cache = .{},
            .field_names = options.only,
            .include_empty_values = options.include_empty_values,
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

    // Builds an IPv4 index that could yield almost 30% faster lookups for IPv4 addresses,
    // but increases memory usage, e.g., if we index first 16 bits, the index size is ~1 MB.
    pub fn buildIPv4Index(self: *Reader, index_first_n_bits: usize) !void {
        self.ipv4_index_first_n_bits = index_first_n_bits;

        self.ipv4_index = try self.arena.allocator().alloc(
            usize,
            std.math.shl(usize, 1, index_first_n_bits + 1),
        );
        errdefer self.ipv4_index = null;

        try self.populateIndex(self.ipv4_start, 1, 0);
    }

    fn populateIndex(
        self: *Reader,
        node: usize,
        index_pos: usize,
        bit_depth: usize,
    ) !void {
        // If we've reached the max bit index depth, store the node.
        if (bit_depth == self.ipv4_index_first_n_bits) {
            self.ipv4_index.?[index_pos] = node;
            return;
        }

        // If the node is terminal (it's a data pointer or empty),
        // fill all descendants at the max bit index depth with that node ID.
        if (node >= self.metadata.node_count) {
            const start: usize = std.math.shl(
                usize,
                index_pos,
                self.ipv4_index_first_n_bits - bit_depth,
            );
            const count: usize = std.math.shl(
                usize,
                1,
                self.ipv4_index_first_n_bits - bit_depth,
            );

            var i: usize = 0;
            while (i < count) : (i += 1) {
                self.ipv4_index.?[start + i] = node;
            }

            return;
        }

        const left_node = try self.readNode(node, 0);
        try self.populateIndex(left_node, index_pos * 2, bit_depth + 1);

        const right_node = try self.readNode(node, 1);
        try self.populateIndex(right_node, index_pos * 2 + 1, bit_depth + 1);
    }

    fn resolveDataPointerAndDecode(
        self: *Reader,
        allocator: std.mem.Allocator,
        T: type,
        pointer: usize,
        field_names: ?[]const []const u8,
    ) !T {
        const record_offset = try self.resolveDataPointer(pointer);

        var d = decoder.Decoder{
            .src = self.src[self.offset..],
            .offset = record_offset,
        };

        return try d.decodeRecord(allocator, T, field_names);
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

    // Checks if the record at the given data pointer is an empty map (zero entries).
    fn isEmptyRecord(self: *Reader, pointer: usize) !bool {
        const record_offset = try self.resolveDataPointer(pointer);
        var d = decoder.Decoder{
            .src = self.src[self.offset..],
            .offset = record_offset,
        };

        return d.isEmptyMap();
    }

    // Uses the Eytzinger index for fast IPv4 lookups.
    // The index covers the first N bits of the IPv4 address, allowing us to
    // skip directly to the node at depth N instead of traversing bit by bit.
    fn findAddressInTreeWithIndex(self: *Reader, ip: net.IP) !struct { usize, usize } {
        const ip_int = std.mem.readInt(u32, &ip.v4, .big);
        const first_n_bits = std.math.shr(
            usize,
            ip_int,
            32 - self.ipv4_index_first_n_bits,
        );
        const index_pos = std.math.shl(usize, 1, self.ipv4_index_first_n_bits) + first_n_bits;

        var node = self.ipv4_index.?[index_pos];

        // If we hit a terminal at or before bit N of IPv4, fall back to regular
        // traversal to get the accurate prefix length.
        if (node >= self.metadata.node_count) {
            node = self.ipv4_start;
            return try self.findAddressInTree(ip, node, 0);
        }

        // Continue traversal from where the index ends (bit N of IPv4 portion).
        return try self.findAddressInTree(ip, node, self.ipv4_index_first_n_bits);
    }

    fn findAddressInTree(
        self: *Reader,
        ip: net.IP,
        start_node: usize,
        start_bit: usize,
    ) !struct { usize, usize } {
        const stop_bit = ip.bitCount();
        const node_count: usize = self.metadata.node_count;

        var node = start_node;
        var prefix_len = stop_bit;
        for (start_bit..stop_bit) |i| {
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

    fn setIPv4Start(self: *Reader) !void {
        if (self.metadata.ip_version != 6) {
            return;
        }

        const node_count: usize = self.metadata.node_count;

        // We are looking up an IPv4 address in an IPv6 tree.
        // Skip over the first 96 nodes.
        var node: usize = 0;
        var i: usize = 0;
        while (i < 96 and node < node_count) : (i += 1) {
            node = try self.readNode(node, 0);
        }

        self.ipv4_start = node;
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
        field_names: ?[]const []const u8,
        include_empty_values: bool,
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

                    // Skip empty records (map with zero entries) unless requested.
                    // Checked after cache lookup because skipped records are never decoded or cached.
                    if (!self.include_empty_values and try reader.isEmptyRecord(current.node)) {
                        continue;
                    }

                    var entry_arena = std.heap.ArenaAllocator.init(self.allocator);
                    errdefer entry_arena.deinit();

                    const value = try reader.resolveDataPointerAndDecode(
                        entry_arena.allocator(),
                        T,
                        current.node,
                        self.field_names,
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
