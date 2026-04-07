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
    IndexAlreadyBuilt,
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

// Maximum db size for Reader.open().
// 64-bit: 20GB covers ~2.3B nodes (record_size=32) with ~2GB data section.
// 32-bit: 2GB matches the user-space address limit.
const max_db_size: usize = if (@sizeOf(usize) >= 8)
    20 * 1024 * 1024 * 1024
else
    2 * 1024 * 1024 * 1024;

pub const Reader = struct {
    metadata: Metadata,
    src: []const u8,
    offset: usize,
    ipv4_start: usize,
    // ipv4_index is a flat array of tree node IDs and data offsets
    // for fast lookup of IPv4 addresses by their first N bits.
    // Instead of traversing the tree bit by bit from the root,
    // the first N levels are pre-computed into a direct-access array.
    ipv4_index_first_n_bits: u8,
    ipv4_index: ?[]u32,
    // ipv4_index_prefix_len stores the prefix length at which
    // each terminal was reached during the index construction.
    // This lets us return the correct prefix length
    // without re-traversing the tree for terminal nodes in the index.
    ipv4_index_prefix_len: ?[]u8,
    is_mapped: bool,
    arena: *std.heap.ArenaAllocator,

    pub const Options = struct {
        /// Builds an index of the first N bits of IPv4 addresses to speed up lookups,
        /// but not the scan() iterator.
        ///
        /// It adds a one-time build cost of ~1-4ms and uses memory proportional to 2^N.
        /// The first open is slower (~10-120ms) because page faults load the tree from disk.
        /// Best suited for long-lived Readers with many lookups.
        ///
        /// Sparse databases such as Anonymous-IP or ISP benefit more (~70%-140%)
        /// because tree traversal dominates whereas dense databases (City, Enterprise)
        /// benefit less (~12%-18%) because record decoding is the bottleneck.
        ///
        /// The recommended value is 16 (~320KB, fits L2 cache), or 12 (~20KB) for constrained devices.
        /// The valid range is between 0 and 24 where 0 disables the index.
        ipv4_index_first_n_bits: u8 = 0,
    };

    /// A located entry in the database, returned by find().
    /// Contains a pointer into the data section and the network that matched.
    /// Pass it to decode() to get the record value.
    pub const Entry = struct {
        pointer: usize,
        network: net.Network,
    };

    /// Options for decoding records from the data section.
    pub const DecodeOptions = struct {
        /// Decode only the specified top-level fields, e.g., &.{"city", "country"}.
        /// Null means decode all fields.
        only: ?[]const []const u8 = null,
        /// Include records that are empty maps. Skipped by default.
        include_empty_values: bool = false,
    };

    fn init(arena: *std.heap.ArenaAllocator, src: []const u8, options: Options) !Reader {
        const metadata = try decodeMetadata(Metadata, arena.allocator(), src);

        switch (metadata.record_size) {
            24, 28, 32 => {},
            else => return ReadError.UnknownRecordSize,
        }

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
            .metadata = metadata,
            .src = src,
            .offset = data_offset,
            .ipv4_start = 0,
            .ipv4_index_first_n_bits = options.ipv4_index_first_n_bits,
            .ipv4_index = null,
            .ipv4_index_prefix_len = null,
            .is_mapped = false,
            .arena = arena,
        };

        r.setIPv4Start();

        if (r.ipv4_index_first_n_bits > 0) {
            try r.buildIPv4Index();
        }

        return r;
    }

    /// Loads a MaxMind DB file into memory.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: Options) !Reader {
        var f = try std.fs.cwd().openFile(path, .{});
        defer f.close();

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);

        const src = try f.readToEndAlloc(arena.allocator(), max_db_size);

        return try init(arena, src, options);
    }

    /// Maps a MaxMind DB file into memory.
    pub fn mmap(allocator: std.mem.Allocator, path: []const u8, options: Options) !Reader {
        const src = try memorymap.map(path);
        errdefer memorymap.unmap(src);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);

        var r = try init(arena, src, options);
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
    ///
    /// The returned Result owns an arena, so you should call deinit() to free it.
    pub fn lookup(
        self: *Reader,
        T: type,
        allocator: std.mem.Allocator,
        address: std.net.Address,
        options: DecodeOptions,
    ) !?Result(T) {
        const entry = try self.find(address) orelse return null;
        return try self.decode(T, allocator, entry, options);
    }

    /// Looks up a value by an IP address, using a cache.
    ///
    /// The cache owns the decoded memory, free it with cache.deinit().
    pub fn lookupWithCache(
        self: *Reader,
        T: type,
        cache: *Cache(T),
        address: std.net.Address,
        options: DecodeOptions,
    ) !?Result(T) {
        const entry = try self.find(address) orelse return null;

        if (cache.get(entry.pointer)) |v| {
            return .{
                .network = entry.network,
                .value = v,
                .arena = null,
                .pointer = entry.pointer,
            };
        }

        if (!options.include_empty_values and try self.isEmptyRecord(entry.pointer)) {
            return null;
        }

        var arena = std.heap.ArenaAllocator.init(cache.allocator);
        errdefer arena.deinit();

        const value = try self.resolveDataPointerAndDecode(
            arena.allocator(),
            T,
            entry.pointer,
            options.only,
        );

        cache.insert(.{
            .pointer = entry.pointer,
            .value = value,
            .arena = arena,
        });

        return .{
            .network = entry.network,
            .value = value,
            .arena = null,
            .pointer = entry.pointer,
        };
    }

    /// Finds an entry by an IP address (tree traversal only, no decoding).
    /// Returns null if the IP address is not found.
    pub fn find(self: *Reader, address: std.net.Address) !?Entry {
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

        return .{
            .pointer = pointer,
            .network = ip.mask(prefix_len).network(prefix_len),
        };
    }

    /// Decodes an entry from the data section.
    /// The returned Result owns an arena, so you should call deinit() to free it.
    pub fn decode(
        self: *Reader,
        T: type,
        allocator: std.mem.Allocator,
        entry: Entry,
        options: DecodeOptions,
    ) !?Result(T) {
        if (!options.include_empty_values and try self.isEmptyRecord(entry.pointer)) {
            return null;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const value = try self.resolveDataPointerAndDecode(
            arena.allocator(),
            T,
            entry.pointer,
            options.only,
        );

        return .{
            .network = entry.network,
            .value = value,
            .arena = arena,
            .pointer = entry.pointer,
        };
    }

    /// Scans networks within the given IP range.
    ///
    /// Each returned Result owns an arena, so you should call deinit() to free it.
    pub fn scan(
        self: *Reader,
        T: type,
        allocator: std.mem.Allocator,
        network: net.Network,
        options: DecodeOptions,
    ) !Iterator(T) {
        return self.initIterator(allocator, T, network, null, options);
    }

    /// Scans networks within the given IP range, using a cache.
    ///
    /// Adjacent networks often share the same record, so using a cache avoids redundant decoding.
    /// The cache owns the decoded memory, free it with cache.deinit().
    pub fn scanWithCache(
        self: *Reader,
        T: type,
        cache: *Cache(T),
        network: net.Network,
        options: DecodeOptions,
    ) !Iterator(T) {
        return self.initIterator(cache.allocator, T, network, cache, options);
    }

    fn initIterator(
        self: *Reader,
        allocator: std.mem.Allocator,
        T: type,
        network: net.Network,
        cache: ?*Cache(T),
        options: DecodeOptions,
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

        const ip_bytes = ip_raw.mask(prefix_len);
        // Traverse down the tree to the level that matches the CIDR mark.
        // Track depth as number of tree edges traversed (becomes the network prefix length).
        var depth: usize = 0;
        if (node < node_count) {
            while (depth < prefix_len) {
                node = self.readNode(node, ip_bytes.bitAt(depth));
                depth += 1;
                if (node >= node_count) {
                    break;
                }
            }
        }

        var it = Iterator(T){
            .reader = self,
            .node_count = node_count,
            .allocator = allocator,
            .cache = cache,
            .field_names = options.only,
            .include_empty_values = options.include_empty_values,
        };

        // Push the node to the stack unless it's "not found" (equal to node_count).
        // Data pointer (> node_count) indicates that record's network contains the query prefix.
        // Internal node (< node_count) indicates that we need to explore its subtree.
        if (node != node_count) {
            it.push(.{
                .node = node,
                .ip_bytes = ip_bytes.mask(depth),
                .prefix_len = depth,
            });
        }

        return it;
    }

    /// Decodes database metadata which is stored as a separate data section,
    /// see https://maxmind.github.io/MaxMind-DB/#database-metadata.
    pub fn decodeMetadata(T: type, allocator: std.mem.Allocator, src: []const u8) !T {
        const metadata_start = try findMetadataStart(src);

        var d = decoder.Decoder{
            .src = src[metadata_start..],
            .offset = 0,
        };

        return try d.decodeRecord(allocator, T, null);
    }

    fn buildIPv4Index(self: *Reader) !void {
        if (self.ipv4_index_first_n_bits > 24) {
            return ReadError.InvalidPrefixLen;
        }
        if (self.ipv4_index != null) {
            return ReadError.IndexAlreadyBuilt;
        }

        const index_size = std.math.shl(usize, 1, self.ipv4_index_first_n_bits);
        self.ipv4_index = try self.arena.allocator().alloc(u32, index_size);
        errdefer self.ipv4_index = null;

        self.ipv4_index_prefix_len = try self.arena.allocator().alloc(u8, index_size);
        errdefer self.ipv4_index_prefix_len = null;

        self.populateIndex(self.ipv4_start, 0, index_size, 0);
    }

    // Recursively traverses the first N levels of the search tree and fills the flat index array.
    // Each index slot corresponds to an N-bit prefix, for example,
    // slot 0000 covers all IPs starting with 0000.
    //
    // The range [start, start+count) tracks which slots belong to the current subtree.
    // At each level we split in half: left child (0-bit) gets the lower half,
    // right child (1-bit) gets the upper half.
    //
    // This works because the array is indexed by the N-bit prefix as a binary number:
    // prefixes starting with 0 occupy the lower half of any range,
    // prefixes starting with 1 occupy the upper half.
    //
    // When a node is terminal (data pointer or not-found) before depth N,
    // we fill all remaining slots in the range with that node because
    // every IP prefix in that range resolves to the same record.
    fn populateIndex(
        self: *Reader,
        node: usize,
        start: usize,
        count: usize,
        bit_depth: usize,
    ) void {
        // If the node is terminal or we've reached the max index depth,
        // fill the range with this node.
        if (count == 1 or node >= self.metadata.node_count) {
            const node_u32: u32 = @intCast(node);
            const prefix_len: u8 = @intCast(bit_depth);

            @memset(self.ipv4_index.?[start..][0..count], node_u32);
            @memset(self.ipv4_index_prefix_len.?[start..][0..count], prefix_len);

            return;
        }

        const half = count / 2;
        const left_node = self.readNode(node, 0);
        self.populateIndex(left_node, start, half, bit_depth + 1);

        const right_node = self.readNode(node, 1);
        self.populateIndex(right_node, start + half, half, bit_depth + 1);
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

    // Uses the IPv4 index for fast lookups.
    // The index covers the first N bits of the IPv4 address, allowing us to
    // skip directly to the node at depth N instead of traversing bit by bit.
    fn findAddressInTreeWithIndex(self: *Reader, ip: net.IP) !struct { usize, usize } {
        const ip_int = std.mem.readInt(u32, &ip.v4, .big);
        const index_pos = std.math.shr(usize, ip_int, 32 - self.ipv4_index_first_n_bits);

        const node: usize = self.ipv4_index.?[index_pos];

        // If we hit a terminal at or before bit N of IPv4, return the prefix length
        // that was stored during index construction.
        if (node >= self.metadata.node_count) {
            const prefix_len: usize = self.ipv4_index_prefix_len.?[index_pos];
            if (node == self.metadata.node_count) {
                return .{ 0, prefix_len };
            }
            return .{ node, prefix_len };
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

            node = self.readNode(node, ip.bitAt(i));
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

    fn setIPv4Start(self: *Reader) void {
        if (self.metadata.ip_version != 6) {
            return;
        }

        const node_count: usize = self.metadata.node_count;

        // We are looking up an IPv4 address in an IPv6 tree.
        // Skip over the first 96 nodes.
        var node: usize = 0;
        var i: usize = 0;
        while (i < 96 and node < node_count) : (i += 1) {
            node = self.readNode(node, 0);
        }

        self.ipv4_start = node;
    }

    fn readNode(self: *Reader, node_number: usize, index: usize) usize {
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
            else => unreachable,
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

/// Ring buffer cache of recently decoded records.
/// The cache owns the memory that backs decoded values,
/// so each value is valid until its cache entry is evicted.
///
/// The default size of 16 is good for most databases.
/// Country databases benefit from larger sizes, e.g., 64 or larger.
pub fn Cache(comptime T: type) type {
    return struct {
        entries: []Entry,
        // Indicates number of entries in the cache.
        len: usize = 0,
        // It's an index in the entries array where a new item will be written at.
        write_pos: usize = 0,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub const Options = struct {
            size: usize = 16,
        };

        pub fn init(allocator: std.mem.Allocator, options: Self.Options) !Self {
            if (options.size == 0) {
                return error.InvalidCacheSize;
            }

            return .{
                .entries = try allocator.alloc(Entry, options.size),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries[0..self.len]) |*e| {
                e.arena.deinit();
            }

            self.allocator.free(self.entries);
        }

        const Entry = struct {
            pointer: usize,
            value: T,
            arena: std.heap.ArenaAllocator,
        };

        fn get(self: *Self, pointer: usize) ?T {
            for (self.entries[0..self.len]) |*e| {
                if (e.pointer == pointer) {
                    return e.value;
                }
            }

            return null;
        }

        fn insert(self: *Self, e: Entry) void {
            if (self.len < self.entries.len) {
                self.entries[self.len] = e;
                self.len += 1;

                return;
            }

            // Evict the oldest entry and insert the new one.
            self.entries[self.write_pos].arena.deinit();
            self.entries[self.write_pos] = e;
            self.write_pos = (self.write_pos + 1) % self.entries.len;
        }
    };
}

/// Result wraps a decoded value with an arena that owns all its allocations.
/// When a cache is used, the cache owns the memory and arena is null.
pub fn Result(comptime T: type) type {
    return struct {
        /// Raw pointer into the data section as stored in the search tree.
        /// Two results with the same pointer reference the same data record.
        /// This is the same value as Entry.pointer and Cache.Entry.pointer.
        pointer: usize,
        network: net.Network,
        value: T,
        arena: ?std.heap.ArenaAllocator,

        pub fn deinit(self: @This()) void {
            if (self.arena) |a| {
                a.deinit();
            }
        }
    };
}

const ScanNode = struct {
    ip_bytes: net.IP,
    prefix_len: usize,
    node: usize,
};

pub fn Iterator(T: type) type {
    return struct {
        reader: *Reader,
        node_count: usize,
        // Fixed-capacity stack for DFS traversal.
        stack: [max_stack_size]ScanNode = undefined,
        stack_len: usize = 0,
        allocator: std.mem.Allocator,
        field_names: ?[]const []const u8,
        include_empty_values: bool,
        cache: ?*Cache(T),

        // Max depth is bit_count - prefix_len + 1 (129 for IPv6 /0).
        const max_stack_size = 129;
        const Self = @This();

        /// Returns the next network and its value.
        ///
        /// Without a cache the returned Result owns an arena, so you should call deinit() to free it.
        /// Otherwise the cache owns the memory, free it with cache.deinit().
        pub fn next(self: *Self) !?Result(T) {
            while (self.pop()) |current| {
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

                    if (self.cache) |cache| {
                        if (cache.get(current.node)) |v| {
                            return .{
                                .network = ip_net,
                                .value = v,
                                .arena = null,
                                .pointer = current.node,
                            };
                        }
                    }

                    // Skip empty records (map with zero entries) unless requested.
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

                    if (self.cache) |cache| {
                        cache.insert(.{
                            .pointer = current.node,
                            .value = value,
                            .arena = entry_arena,
                        });

                        return .{
                            .network = ip_net,
                            .value = value,
                            .arena = null,
                            .pointer = current.node,
                        };
                    }

                    return .{
                        .network = ip_net,
                        .value = value,
                        .arena = entry_arena,
                        .pointer = current.node,
                    };
                } else if (current.node < self.node_count) {
                    // In order traversal of the children on the right (1-bit).
                    var node = reader.readNode(current.node, 1);
                    var right_ip_bytes = current.ip_bytes;

                    if (current.prefix_len < bit_count) {
                        const bit = current.prefix_len;
                        switch (right_ip_bytes) {
                            .v4 => |*b| b[bit >> 3] |= std.math.shl(u8, 1, (bit_count - bit - 1) % 8),
                            .v6 => |*b| b[bit >> 3] |= std.math.shl(u8, 1, (bit_count - bit - 1) % 8),
                        }
                    }

                    self.push(.{
                        .node = node,
                        .ip_bytes = right_ip_bytes,
                        .prefix_len = current.prefix_len + 1,
                    });

                    // In order traversal of the children on the left (0-bit).
                    node = reader.readNode(current.node, 0);
                    self.push(.{
                        .node = node,
                        .ip_bytes = current.ip_bytes,
                        .prefix_len = current.prefix_len + 1,
                    });
                }
            }

            return null;
        }

        fn push(self: *Self, node: ScanNode) void {
            self.stack[self.stack_len] = node;
            self.stack_len += 1;
        }

        fn pop(self: *Self) ?ScanNode {
            if (self.stack_len == 0) {
                return null;
            }

            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }
    };
}
