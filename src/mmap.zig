const std = @import("std");

pub fn map(f: std.fs.File) ![]const u8 {
    // TODO: We probably need CreateFileMapping, MapViewOfFile to support Windows,
    // see https://github.com/ziglang/zig/pull/21083.

    const file_size = (try f.stat()).size;
    const page_size = std.heap.pageSize();
    const aligned_file_size = std.mem.alignForward(usize, file_size, page_size);
    const src = try std.posix.mmap(
        null,
        aligned_file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        f.handle,
        0,
    );

    return src[0..file_size];
}

pub fn unmap(src: []const u8) void {
    const page_size = std.heap.pageSize();
    const aligned_src_len = std.mem.alignForward(usize, src.len, page_size);
    std.posix.munmap(@alignCast(src.ptr[0..aligned_src_len]));
}
