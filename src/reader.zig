const std = @import("std");

const decoder = @import("decoder.zig");
const collection = @import("collection.zig");
const net = @import("net.zig");
const typed = @import("typed.zig");
const any = @import("any.zig");
const lazy = @import("lazy.zig");

pub const ReadError = error{
    MetadataStartNotFound,
    InvalidTreeNode,
    CorruptedTree,
    UnknownRecordSize,
    UnknownIPVersion,
    UnsupportedBinaryFormat,
    EmptyDatabase,
    InvalidPrefixLen,
    InvalidIndexBits,
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

    // The last occurrence of this string in the file marks the end of the data section
    // and the beginning of the metadata.
    const start_marker = "\xAB\xCD\xEFMaxMind.com";

    /// Decodes database metadata which is stored as a separate data section,
    /// see https://maxmind.github.io/MaxMind-DB/#database-metadata.
    pub fn decode(allocator: std.mem.Allocator, src: []const u8) !Metadata {
        return decodeAs(Metadata, allocator, src);
    }

    /// Decodes metadata into an arbitrary type, e.g., any.Value.
    pub fn decodeAs(T: type, allocator: std.mem.Allocator, src: []const u8) !T {
        const metadata_start = try findMetadataStart(src);

        var d = decoder.Decoder{
            .src = src[metadata_start..],
            .offset = 0,
        };

        if (comptime T == any.Value) {
            return try any.decode(&d, allocator, null);
        }

        return try typed.decode(&d, allocator, T, null);
    }

    fn findMetadataStart(src: []const u8) !usize {
        var metadata_start = std.mem.findLast(u8, src, start_marker) orelse {
            return ReadError.MetadataStartNotFound;
        };
        metadata_start += start_marker.len;

        return metadata_start;
    }
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
    data_start: usize,
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
    strict: bool = true,
    memory_map: ?struct {
        map: std.Io.File.MemoryMap,
        io: std.Io,
    },
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
        /// Bounds-check the offsets that decoding follows.
        /// Turning it off is faster, but a maliciously crafted database can then crash the process.
        /// Reads that return data are bounds-checked either way,
        /// so no payload byte comes from outside the database.
        strict: bool = true,
    };

    /// Options for lookup() and networks().
    pub const ResultOptions = struct {
        /// Include records that are empty maps. Skipped by default.
        include_empty_values: bool = false,
    };

    /// Options for decode() and decodeUnmanaged().
    pub const DecodeOptions = struct {
        /// Decode only the specified top-level fields, e.g., &.{"city", "country"}.
        /// Null means decode all fields.
        only: ?[]const []const u8 = null,
    };

    /// Options for query() and scan().
    pub const QueryOptions = struct {
        /// Decode only the specified top-level fields, e.g., &.{"city", "country"}.
        /// Null means decode all fields.
        only: ?[]const []const u8 = null,
        /// Include records that are empty maps. Skipped by default.
        include_empty_values: bool = false,
    };

    /// Raw pointer into the data section as stored in the search tree.
    /// Two results with the same pointer reference the same data record.
    /// Use as a cache key to avoid redundant decoding.
    pub const DataPointer = enum(usize) {
        /// No record. A record value of 0 denotes node 0, so the search tree
        /// never stores it as a data pointer.
        none = 0,
        _,
    };

    /// A located result in the database, returned by lookup() and NetworkIterator.next().
    /// Contains a pointer into the data section and the network that matched.
    /// Pass it to decode() or Cache.decode() to get the record value.
    pub const Result = struct {
        pointer: DataPointer,
        network: net.Network,
    };

    /// Decoded wraps a value with an arena that owns all its allocations.
    pub fn Decoded(comptime T: type) type {
        return struct {
            network: net.Network,
            value: T,
            arena: std.heap.ArenaAllocator,

            pub fn deinit(self: @This()) void {
                self.arena.deinit();
            }
        };
    }

    fn init(
        arena: *std.heap.ArenaAllocator,
        src: []const u8,
        options: Options,
    ) !Reader {
        const metadata = try Metadata.decode(arena.allocator(), src);

        if (metadata.binary_format_major_version != 2) {
            return ReadError.UnsupportedBinaryFormat;
        }

        if (metadata.node_count == 0) {
            return ReadError.EmptyDatabase;
        }

        switch (metadata.record_size) {
            24, 28, 32 => {},
            else => return ReadError.UnknownRecordSize,
        }

        switch (metadata.ip_version) {
            4, 6 => {},
            else => return ReadError.UnknownIPVersion,
        }

        const search_tree_size = std.math.mul(
            usize,
            metadata.node_count,
            metadata.record_size / 4,
        ) catch return ReadError.CorruptedTree;
        const data_offset = std.math.add(
            usize,
            search_tree_size,
            data_section_separator_size,
        ) catch return ReadError.CorruptedTree;
        if (data_offset > src.len) {
            return ReadError.CorruptedTree;
        }

        var r = Reader{
            .metadata = metadata,
            .src = src,
            .data_start = data_offset,
            .strict = options.strict,
            .ipv4_start = 0,
            .ipv4_index_first_n_bits = options.ipv4_index_first_n_bits,
            .ipv4_index = null,
            .ipv4_index_prefix_len = null,
            .memory_map = null,
            .arena = arena,
        };

        r.setIPv4Start();

        if (r.ipv4_index_first_n_bits > 0) {
            try r.buildIPv4Index();
        }

        return r;
    }

    /// Constructs a reader from a byte slice.
    pub fn fromBytes(
        allocator: std.mem.Allocator,
        src: []const u8,
        options: Options,
    ) !Reader {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);

        return try init(arena, src, options);
    }

    /// Loads a MaxMind DB file into memory.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        options: Options,
    ) !Reader {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);

        const src = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            arena.allocator(),
            .limited(max_db_size),
        );

        return try init(arena, src, options);
    }

    /// Maps a MaxMind DB file into memory.
    pub fn mmap(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        options: Options,
    ) !Reader {
        var f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);

        const file_size: usize = @intCast(try f.length(io));
        if (file_size == 0) {
            return error.FileEmpty;
        }

        var map = try f.createMemoryMap(
            io,
            .{
                .len = file_size,
                .protection = .{ .read = true },
            },
        );
        errdefer map.destroy(io);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        arena.* = std.heap.ArenaAllocator.init(allocator);

        var r = try init(arena, map.memory, options);
        r.memory_map = .{ .map = map, .io = io };

        return r;
    }

    /// Frees the memory occupied by the DB file.
    /// From this point all the DB records are unusable because their fields were backed by the same memory.
    /// Note, the records still have to be deinited since they might contain arrays or maps.
    pub fn close(self: *Reader) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);

        if (self.memory_map) |*mapped| {
            mapped.map.destroy(mapped.io);
        }
    }

    /// Looks up an IP address and decodes the record into T.
    /// Returns null when the IP address is not found or the record is empty.
    ///
    /// The returned result owns an arena, so you should call deinit() to free it.
    pub fn query(
        self: *const Reader,
        T: type,
        allocator: std.mem.Allocator,
        address: std.Io.net.IpAddress,
        options: QueryOptions,
    ) !?Decoded(T) {
        const result = try self.lookup(
            address,
            .{ .include_empty_values = options.include_empty_values },
        ) orelse return null;

        return try self.decode(T, allocator, result, .{ .only = options.only });
    }

    /// Looks up the record for an IP address (no decoding).
    /// Returns null if the IP address is not found or the record is empty.
    /// Empty records are skipped by default.
    /// Use include_empty_values = true to return them.
    pub fn lookup(self: *const Reader, address: std.Io.net.IpAddress, options: ResultOptions) !?Result {
        const ip = net.IP.from(address);
        if (ip.bitCount() == 128 and self.metadata.ip_version == 4) {
            return ReadError.IPv6AddressInIPv4Database;
        }

        var pointer: DataPointer = .none;
        var prefix_len: usize = 0;
        if (self.ipv4_index != null and ip == .v4) {
            pointer, prefix_len = try self.findAddressInTreeWithIndex(ip);
        } else {
            const start_node = self.startNode(ip.bitCount());
            pointer, prefix_len = try self.findAddressInTree(ip, start_node, 0);
        }

        if (pointer == .none) {
            return null;
        }

        if (!options.include_empty_values and try self.isEmptyRecord(pointer)) {
            return null;
        }

        return .{
            .pointer = pointer,
            .network = ip.mask(prefix_len).network(prefix_len),
        };
    }

    /// Decodes a record from the data section.
    /// The returned result owns an arena, so you should call deinit() to free it.
    pub fn decode(
        self: *const Reader,
        T: type,
        allocator: std.mem.Allocator,
        result: Result,
        options: DecodeOptions,
    ) !Decoded(T) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const value = try self.decodeUnmanaged(T, arena.allocator(), result, options);

        return .{
            .network = result.network,
            .value = value,
            .arena = arena,
        };
    }

    /// Decodes a record and returns the bare value.
    /// Use this when you manage the arena yourself, e.g., Cache, DecodedIterator.
    /// For one-shot lookups, prefer decode() which bundles an arena with the result.
    ///
    /// Use ArenaAllocator or similar because individual allocations aren't tracked
    /// and can't be freed individually.
    pub fn decodeUnmanaged(
        self: *const Reader,
        T: type,
        allocator: std.mem.Allocator,
        result: Result,
        options: DecodeOptions,
    ) !T {
        return try self.resolveDataPointerAndDecode(
            allocator,
            T,
            result.pointer,
            options.only,
        );
    }

    /// Scans networks within the given IP range, decoding each record into T.
    /// A null range covers every network in the database.
    ///
    /// Each returned result owns an arena, so you should call deinit() to free it.
    pub fn scan(
        self: *const Reader,
        T: type,
        allocator: std.mem.Allocator,
        range: ?net.Network,
        options: QueryOptions,
    ) !DecodedIterator(T) {
        return .{
            .it = try self.networks(
                range,
                .{ .include_empty_values = options.include_empty_values },
            ),
            .field_names = options.only,
            .allocator = allocator,
        };
    }

    /// Iterates over results (pointer + network) within the given IP range without decoding.
    /// A null range covers every network in the database.
    /// Use with decode() or Cache.decode() to control when decoding happens.
    ///
    /// Empty records are skipped by default.
    /// Use include_empty_values = true to yield them.
    pub fn networks(self: *const Reader, range: ?net.Network, options: ResultOptions) !NetworkIterator {
        const network = range orelse self.fullRange();
        const prefix_len: usize = network.prefix_len;
        const ip = net.IP.from(network.ip);
        const bit_count: usize = ip.bitCount();

        if (prefix_len > bit_count) {
            return ReadError.InvalidPrefixLen;
        }
        if (bit_count == 128 and self.metadata.ip_version == 4) {
            return ReadError.IPv6AddressInIPv4Database;
        }

        var node = self.startNode(bit_count);
        const node_count = self.metadata.node_count;

        // Traverse down the tree to the level that matches the CIDR prefix.
        // Track depth as number of tree edges traversed (becomes the network prefix length).
        const ip_bytes = ip.mask(prefix_len);
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

        var it = NetworkIterator{
            .reader = self,
            .node_count = node_count,
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

    /// Walks a flat map-key path from a result's root with zero allocations.
    /// Returns the value at the terminal, or null if any step does not resolve, e.g., missing key.
    /// An empty path resolves to the record root, which is non-null for a valid result.
    pub fn getPath(
        self: *const Reader,
        result: Result,
        path: []const []const u8,
    ) !?lazy.Value {
        const record_offset = try self.resolveDataPointer(result.pointer);
        var d = self.recordDecoder(record_offset);

        return try lazy.walkPath(&d, path);
    }

    /// The range covering every network in the database.
    fn fullRange(self: *const Reader) net.Network {
        return if (self.metadata.ip_version == 4) net.Network.all_ipv4 else net.Network.all_ipv6;
    }

    fn buildIPv4Index(self: *Reader) !void {
        if (self.ipv4_index_first_n_bits > 24) {
            return ReadError.InvalidIndexBits;
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
        self: *const Reader,
        allocator: std.mem.Allocator,
        T: type,
        pointer: DataPointer,
        field_names: ?[]const []const u8,
    ) !T {
        const record_offset = try self.resolveDataPointer(pointer);

        var d = self.recordDecoder(record_offset);

        if (comptime T == any.Value) {
            return try any.decode(&d, allocator, field_names);
        }

        return try typed.decode(&d, allocator, T, field_names);
    }

    fn resolveDataPointer(self: *const Reader, pointer: DataPointer) !usize {
        const raw = @intFromEnum(pointer);
        const min_pointer = self.metadata.node_count + data_section_separator_size;
        if (raw < min_pointer) {
            return ReadError.CorruptedTree;
        }

        const resolved: usize = raw - min_pointer;
        if (self.data_start > self.src.len or resolved >= self.src.len - self.data_start) {
            return ReadError.CorruptedTree;
        }

        return resolved;
    }

    // Builds a decoder positioned at a record in the data section.
    fn recordDecoder(self: *const Reader, record_offset: usize) decoder.Decoder {
        return .{
            .src = self.src[self.data_start..],
            .offset = record_offset,
            .strict = self.strict,
        };
    }

    // Checks if the record at the given data pointer is an empty map (zero entries).
    fn isEmptyRecord(self: *const Reader, pointer: DataPointer) !bool {
        const record_offset = try self.resolveDataPointer(pointer);
        var d = self.recordDecoder(record_offset);

        return d.isEmptyMap();
    }

    // Uses the IPv4 index for fast lookups.
    // The index covers the first N bits of the IPv4 address, allowing us to
    // skip directly to the node at depth N instead of traversing bit by bit.
    fn findAddressInTreeWithIndex(self: *const Reader, ip: net.IP) !struct { DataPointer, usize } {
        const ip_int = std.mem.readInt(u32, &ip.v4, .big);
        const index_pos = std.math.shr(usize, ip_int, 32 - self.ipv4_index_first_n_bits);

        const node: usize = self.ipv4_index.?[index_pos];

        // If we hit a terminal at or before bit N of IPv4, return the prefix length
        // that was stored during index construction.
        if (node >= self.metadata.node_count) {
            const prefix_len: usize = self.ipv4_index_prefix_len.?[index_pos];
            if (node == self.metadata.node_count) {
                return .{ .none, prefix_len };
            }
            return .{ @enumFromInt(node), prefix_len };
        }

        // Continue traversal from where the index ends (bit N of IPv4 portion).
        return try self.findAddressInTree(ip, node, self.ipv4_index_first_n_bits);
    }

    fn findAddressInTree(
        self: *const Reader,
        ip: net.IP,
        start_node: usize,
        start_bit: usize,
    ) !struct { DataPointer, usize } {
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
            return .{ .none, prefix_len };
        }

        if (node > node_count) {
            return .{ @enumFromInt(node), prefix_len };
        }

        return ReadError.InvalidTreeNode;
    }

    fn startNode(self: *const Reader, length: usize) usize {
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

    fn readNode(self: *const Reader, node_number: usize, index: usize) usize {
        const src = self.src;
        const base_offset: usize = node_number * (self.metadata.record_size / 4);

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
};

/// Ring buffer cache of recently decoded records.
/// The cache owns the memory that backs decoded values,
/// so each value is valid until its slot is evicted.
///
/// The default size of 16 is good for most databases.
/// Country databases benefit from larger sizes, e.g., 64 or larger.
pub fn Cache(comptime T: type) type {
    return struct {
        slots: []Slot,
        // Number of slots in use.
        filled: usize = 0,
        // Index in the slots array where the next record will be written.
        write_pos: usize = 0,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub const Options = struct {
            size: usize = 16,
        };

        const Slot = struct {
            pointer: Reader.DataPointer,
            value: T,
            arena: std.heap.ArenaAllocator,
        };

        pub fn init(allocator: std.mem.Allocator, options: Self.Options) !Self {
            if (options.size == 0) {
                return error.InvalidCacheSize;
            }

            return .{
                .slots = try allocator.alloc(Slot, options.size),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.reset();
            self.allocator.free(self.slots);
        }

        /// Drops every cached record, freeing arenas, and leaves the cache
        /// ready to refill at the same capacity.
        /// Use when the decode filter changes and cached trees are stale.
        pub fn reset(self: *Self) void {
            for (self.slots[0..self.filled]) |*slot| {
                slot.arena.deinit();
            }

            self.filled = 0;
            self.write_pos = 0;
        }

        /// Returns a cached value for the given data pointer, or null on cache miss.
        pub fn get(self: *Self, pointer: Reader.DataPointer) ?T {
            for (self.slots[0..self.filled]) |*slot| {
                if (slot.pointer == pointer) {
                    return slot.value;
                }
            }

            return null;
        }

        /// Decodes a record, using the cache to avoid redundant decoding.
        /// Returns the cached value on hit, or decodes and caches on miss.
        /// The cache owns the decoded memory.
        /// The returned value is valid until its slot is evicted or cache.deinit() is called.
        pub fn decode(
            self: *Self,
            db: *const Reader,
            result: Reader.Result,
            options: Reader.DecodeOptions,
        ) !T {
            if (self.get(result.pointer)) |v| {
                return v;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();

            const value = try db.decodeUnmanaged(T, arena.allocator(), result, options);

            self.insert(.{
                .pointer = result.pointer,
                .value = value,
                .arena = arena,
            });

            return value;
        }

        fn insert(self: *Self, slot: Slot) void {
            if (self.filled < self.slots.len) {
                self.slots[self.filled] = slot;
                self.filled += 1;

                return;
            }

            // Evict the oldest record and take its slot.
            self.slots[self.write_pos].arena.deinit();
            self.slots[self.write_pos] = slot;
            self.write_pos = (self.write_pos + 1) % self.slots.len;
        }
    };
}

pub fn DecodedIterator(T: type) type {
    return struct {
        it: NetworkIterator,
        field_names: ?[]const []const u8,
        allocator: std.mem.Allocator,

        /// Returns the next network and its value.
        ///
        /// The returned result owns an arena, so you should call deinit() to free it.
        pub fn next(self: *@This()) !?Reader.Decoded(T) {
            const result = try self.it.next() orelse return null;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();

            const value = try self.it.reader.decodeUnmanaged(
                T,
                arena.allocator(),
                result,
                .{ .only = self.field_names },
            );

            return .{
                .network = result.network,
                .value = value,
                .arena = arena,
            };
        }
    };
}

/// Iterates over results (pointer + network) without decoding records.
/// Empty records are skipped unless include_empty_values is set.
/// Use Reader.decode() or Cache.decode() to decode individual results.
pub const NetworkIterator = struct {
    reader: *const Reader,
    node_count: usize,
    stack: [max_stack_size]ScanNode = undefined,
    stack_len: usize = 0,
    include_empty_values: bool,

    // Max depth is bit_count - prefix_len + 1 (129 for IPv6 /0).
    const max_stack_size = 129;

    const Self = @This();

    const ScanNode = struct {
        ip_bytes: net.IP,
        prefix_len: usize,
        node: usize,
    };

    /// Returns the next result (pointer + network) or null when exhausted.
    pub fn next(self: *Self) !?Reader.Result {
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

            // Data pointer (> node_count) means this node holds a record.
            if (current.node > self.node_count) {
                const pointer: Reader.DataPointer = @enumFromInt(current.node);
                if (!self.include_empty_values and try reader.isEmptyRecord(pointer)) {
                    continue;
                }

                return .{
                    .pointer = pointer,
                    .network = current.ip_bytes.network(current.prefix_len),
                };
            } else if (current.node < self.node_count) {
                // A valid tree resolves within bit_count levels.
                // A deeper internal node is cyclic or malformed.
                if (current.prefix_len >= bit_count) {
                    return ReadError.CorruptedTree;
                }

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
