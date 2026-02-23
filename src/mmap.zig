const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

// Maps a file into memory.
// The file handle is closed after mapping.
// The caller must call unmap() to release the mapped memory.
pub fn map(path: []const u8) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => mapWindows(path),
        else => posixMap(path),
    };
}

pub fn unmap(src: []const u8) void {
    switch (builtin.os.tag) {
        .windows => unmapWindows(src),
        else => posixUnmap(src),
    }
}

// The file is closed after mmap (POSIX guarantees the mapping survives),
// see https://man7.org/linux/man-pages/man2/mmap.2.html.
fn posixMap(path: []const u8) ![]const u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const stat = try f.stat();
    if (stat.kind != .file) {
        return error.NotFile;
    }

    const file_size = stat.size;
    if (file_size == 0) {
        return error.FileEmpty;
    }

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

// Maps a file into memory using the Win32 API.
// The file and mapping handles are closed after mapping.
// The mapped view remains valid until unmapped, see
// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-unmapviewoffile.
fn mapWindows(path: []const u8) ![]const u8 {
    // Null-terminate the path for CreateFileA (that's what std.posix.toPosixPath() does).
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) {
        return error.NameTooLong;
    }

    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    // Open the file for reading.
    const handle = CreateFileA(
        buf[0..path.len :0],
        windows.GENERIC_READ,
        windows.FILE_SHARE_READ,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return switch (windows.kernel32.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .SHARING_VIOLATION => error.SharingViolation,
            else => error.Unexpected,
        };
    }
    defer windows.CloseHandle(handle);

    var file_size: i64 = undefined;
    if (windows.kernel32.GetFileSizeEx(handle, &file_size) == 0) {
        return error.Unexpected;
    }
    if (file_size == 0) {
        return error.FileEmpty;
    }

    // Create a read-only file mapping object backed by the file.
    // Passing 0 for size means "map the entire file".
    const mapping = CreateFileMappingW(
        handle,
        null,
        windows.PAGE_READONLY,
        0,
        0,
        null,
    ) orelse return error.Unexpected;
    defer windows.CloseHandle(mapping);

    // Map the file into the process address space.
    // The view stays valid after both handles are closed.
    const ptr: [*]const u8 = @ptrCast(
        MapViewOfFile(
            mapping,
            FILE_MAP_READ,
            0,
            0,
            0,
        ) orelse return error.Unexpected,
    );

    return ptr[0..@intCast(file_size)];
}

fn unmapWindows(src: []const u8) void {
    _ = UnmapViewOfFile(src.ptr);
}

const FILE_MAP_READ: u32 = 4;

// Zig's standard library doesn't provide bindings for the following Win32 functions.

// Creates or opens a file or I/O device, see
// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilea.
extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

// Creates or opens a named or unnamed file mapping object for a specified file, see
// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-createfilemappingw.
extern "kernel32" fn CreateFileMappingW(
    hFile: windows.HANDLE,
    lpFileMappingAttributes: ?*anyopaque,
    flProtect: u32,
    dwMaximumSizeHigh: u32,
    dwMaximumSizeLow: u32,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;

// Maps a view of a file mapping into the address space of a calling process, see
// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-mapviewoffile.
extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: windows.HANDLE,
    dwDesiredAccess: u32,
    dwFileOffsetHigh: u32,
    dwFileOffsetLow: u32,
    dwNumberOfBytesToMap: usize,
) callconv(.winapi) ?*anyopaque;

// Unmaps a mapped view of a file from the calling process's address space, see
// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-unmapviewoffile.
extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: *const anyopaque,
) callconv(.winapi) windows.BOOL;
