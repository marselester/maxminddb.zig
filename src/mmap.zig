const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub fn map(f: std.fs.File) ![]const u8 {
    const stat = try f.stat();
    if (stat.kind != .file) {
        return error.NotFile;
    }

    const file_size = stat.size;
    if (file_size == 0) {
        return error.FileEmpty;
    }

    return switch (builtin.os.tag) {
        .windows => mapWindows(f, file_size),
        else => posixMap(f, file_size),
    };
}

pub fn unmap(src: []const u8) void {
    switch (builtin.os.tag) {
        .windows => unmapWindows(src),
        else => posixUnmap(src),
    }
}

fn posixMap(f: std.fs.File, file_size: usize) ![]const u8 {
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

fn posixUnmap(src: []const u8) void {
    const page_size = std.heap.pageSize();
    const aligned_src_len = std.mem.alignForward(usize, src.len, page_size);
    std.posix.munmap(@alignCast(src.ptr[0..aligned_src_len]));
}

// Maps a file into memory using the NT API.
// The section handle is closed after mapping, but the view remains valid until unmapped.
// See https://github.com/ziglang/zig/blob/0.15.x/lib/std/debug/SelfInfo.zig.
fn mapWindows(f: std.fs.File, file_size: usize) ![]const u8 {
    // Create a section object backed by the file.
    var section_handle: windows.HANDLE = undefined;
    const create_status = windows.ntdll.NtCreateSection(
        &section_handle,
        windows.STANDARD_RIGHTS_REQUIRED | windows.SECTION_QUERY | windows.SECTION_MAP_READ,
        null,
        null,
        windows.PAGE_READONLY,
        windows.SEC_COMMIT,
        f.handle,
    );
    if (create_status != .SUCCESS) {
        return error.CreateSectionFailed;
    }
    errdefer windows.CloseHandle(section_handle);

    // Map the section into the current process address space.
    var base_ptr: usize = 0;
    var view_size: usize = 0;
    const map_status = windows.ntdll.NtMapViewOfSection(
        section_handle,
        windows.GetCurrentProcess(),
        @ptrCast(&base_ptr),
        null,
        0,
        null,
        &view_size,
        .ViewUnmap,
        0,
        windows.PAGE_READONLY,
    );
    if (map_status != .SUCCESS) {
        return error.MapViewFailed;
    }

    windows.CloseHandle(section_handle);

    return @as([*]const u8, @ptrFromInt(base_ptr))[0..file_size];
}

fn unmapWindows(src: []const u8) void {
    const status = windows.ntdll.NtUnmapViewOfSection(
        windows.GetCurrentProcess(),
        @ptrCast(@constCast(src.ptr)),
    );
    std.debug.assert(status == .SUCCESS);
}
