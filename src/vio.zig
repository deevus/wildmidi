//! Adapts borrowed Zig I/O to C file callbacks and tracks their allocation ownership.

const std = @import("std");
const c = @import("c.zig");

const VioState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
};

const allocation_header_size = @sizeOf(usize);
var active_vio: ?VioState = null;
var callback_error: ?c.WildMidiError = null;

var adapter_allocations: usize = 0;
var adapter_frees: usize = 0;

/// Bind borrowed I/O resources for the next VIO initialization.
pub fn stage(io: std.Io, allocator: std.mem.Allocator, dir: ?std.Io.Dir) void {
    callback_error = null;
    active_vio = .{ .io = io, .allocator = allocator, .dir = dir orelse std.Io.Dir.cwd() };
}

/// Discard adapter state after shutdown or initialization failure has freed its buffers.
pub fn reset() void {
    active_vio = null;
    callback_error = null;
}

/// Clear the previous callback error before starting a new file operation.
pub fn clearCallbackError() void {
    callback_error = null;
}

/// Return the last captured callback error without clearing it.
pub fn lastError() ?c.WildMidiError {
    return callback_error;
}

/// Return the C file callbacks backed by the currently staged Zig I/O resources.
pub fn callbacks() c.CVio {
    return .{ .allocate_file = allocateFileC, .free_file = freeFileC };
}

fn allocateFileC(path: [*c]const u8, size: [*c]u32) callconv(.c) ?*anyopaque {
    callback_error = null;
    if (path == null or size == null) {
        callback_error = error.InvalidArgument;
        return null;
    }
    const vio = active_vio orelse {
        callback_error = error.LibraryNotInitialized;
        return null;
    };
    const bytes = vio.dir.readFileAlloc(vio.io, std.mem.span(path), vio.allocator, .limited(c.max_file_size)) catch |err| {
        callback_error = switch (err) {
            error.OutOfMemory => error.UnableToAllocateMemory,
            error.FileNotFound => error.UnableToOpen,
            error.StreamTooLong => error.RefusingToLoadUnusuallyLongFile,
            else => error.UnableToRead,
        };
        return null;
    };
    defer vio.allocator.free(bytes);
    if (bytes.len > c.max_file_size) {
        callback_error = error.RefusingToLoadUnusuallyLongFile;
        return null;
    }
    const stored_len = allocation_header_size + bytes.len + 1;
    const storage = vio.allocator.alloc(u8, stored_len) catch {
        callback_error = error.UnableToAllocateMemory;
        return null;
    };
    std.mem.writeInt(usize, storage[0..allocation_header_size], stored_len, .little);
    @memcpy(storage[allocation_header_size..][0..bytes.len], bytes);
    storage[allocation_header_size + bytes.len] = 0;
    size.* = @intCast(bytes.len);
    if (comptime @import("builtin").is_test) adapter_allocations += 1;
    return storage.ptr + allocation_header_size;
}

fn freeFileC(ptr: ?*anyopaque) callconv(.c) void {
    const data_ptr = ptr orelse return;
    const vio = active_vio orelse return;
    const storage_ptr: [*]u8 = @ptrFromInt(@intFromPtr(data_ptr) - allocation_header_size);
    const stored_len = std.mem.readInt(usize, storage_ptr[0..allocation_header_size], .little);
    vio.allocator.free(storage_ptr[0..stored_len]);
    if (comptime @import("builtin").is_test) adapter_frees += 1;
}

const test_support = @import("testing.zig");

test "standard I/O adapter balances C buffers on config failure and retry" {
    const testing = std.testing;
    const library = @import("WildMidi.zig");
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(testing.io, "nested", .default_dir);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "nested/config.cfg", .data = "\n" });
    adapter_allocations = 0;
    adapter_frees = 0;
    test_support.failConfigDirAllocation();
    const opts: library.VioOptions = .{ .config_file = "nested/config.cfg", .dir = temp.dir };
    try testing.expectError(error.UnableToAllocateMemory, library.WildMidi.initVio(testing.io, testing.allocator, opts));
    try testing.expect(adapter_allocations > 0);
    try testing.expectEqual(adapter_allocations, adapter_frees);
    const session = try library.WildMidi.initVio(testing.io, testing.allocator, opts);
    session.deinit();
    try testing.expectEqual(adapter_allocations, adapter_frees);
}
