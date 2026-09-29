//! WildMIDI initialization, file opening, and master volume.

const std = @import("std");
const c = @import("c.zig");
const vio = @import("vio.zig");
const MidiFile = @import("MidiFile.zig").MidiFile;
const WildMidiError = c.WildMidiError;
const logger = std.log.scoped(.wildmidi);

pub const Options = struct {
    config_file: [:0]const u8,
    sample_rate: u16 = 44100,
    mixer_options: c.InitOptions = .{},
};

pub const VioOptions = struct {
    config_file: [:0]const u8,
    sample_rate: u16 = 44100,
    mixer_options: c.InitOptions = .{},
    dir: ?std.Io.Dir = null,
};

var session_active = false;

pub const WildMidi = struct {
    /// Initialize WildMIDI using configuration and instrument files on the local filesystem.
    pub fn init(options: Options) WildMidiError!WildMidi {
        c.lib.WildMidi_ClearError();
        try c.handleError(c.lib.WildMidi_Init(options.config_file, options.sample_rate, options.mixer_options.bits()));
        session_active = true;
        return .{};
    }

    /// Initialize with virtual I/O (VIO), which routes file reads through `io`.
    /// Keep `io`, `allocator`, and `options.dir` valid until `deinit`.
    pub fn initVio(io: std.Io, allocator: std.mem.Allocator, options: VioOptions) WildMidiError!WildMidi {
        if (session_active) return error.LibraryAlreadyInitialized;
        c.lib.WildMidi_ClearError();
        vio.stage(io, allocator, options.dir);
        errdefer vio.reset();
        var callbacks = vio.callbacks();
        const result = c.lib.WildMidi_InitVIO(&callbacks, options.config_file, options.sample_rate, options.mixer_options.bits());
        if (result != 0 and c._WM_Global_ErrorI == 0) return vio.lastError() orelse error.UnableToOpen;
        try c.handleError(result);
        session_active = true;
        return .{};
    }

    /// Shut down WildMIDI.
    ///
    /// Close all MIDI files before calling this method.
    pub fn deinit(_: WildMidi) void {
        if (!session_active) return;
        shutdown() catch |err| {
            logger.err("WildMidi session shutdown failed: {s}", .{@errorName(err)});
            vio.reset();
            session_active = false;
        };
    }

    /// Open MIDI data from memory.
    /// The caller may change or free `bytes` after this method returns.
    pub fn openBuffer(_: WildMidi, bytes: []const u8) WildMidiError!MidiFile {
        if (bytes.len > std.math.maxInt(u32)) return error.InvalidArgument;
        c.lib.WildMidi_ClearError();
        const handle = c.lib.WildMidi_OpenBuffer(bytes.ptr, @intCast(bytes.len));
        if (handle == null) {
            try c.handleGlobalError();
            return error.UnableToOpen;
        }
        return .{ .handle = handle };
    }

    /// Read MIDI data from the file's current position.
    /// The caller must close `file`; it can be closed as soon as this method returns.
    pub fn open(self: WildMidi, io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) WildMidiError!MidiFile {
        var reader = file.readerStreaming(io, &.{});
        const bytes = reader.interface.allocRemaining(allocator, .limited(c.max_file_size)) catch |err| switch (err) {
            error.OutOfMemory => return error.UnableToAllocateMemory,
            error.StreamTooLong => return error.RefusingToLoadUnusuallyLongFile,
            error.ReadFailed => return error.UnableToRead,
        };
        defer allocator.free(bytes);
        return self.openBuffer(bytes);
    }

    /// Set the library-wide master volume in the range 0 through 127.
    pub fn masterVolume(_: WildMidi, volume: u8) WildMidiError!void {
        c.lib.WildMidi_ClearError();
        return c.handleError(c.lib.WildMidi_MasterVolume(volume));
    }
};

// Internal raw callback path exercised by the integration tests.
fn initVioRaw(callbacks: *c.CVio, config_file: [:0]const u8, rate: u16, options: c.InitOptions) WildMidiError!WildMidi {
    c.lib.WildMidi_ClearError();
    const result = c.lib.WildMidi_InitVIO(callbacks, config_file, rate, options.bits());
    if (result != 0 and c._WM_Global_ErrorI == 0) return error.UnableToOpen;
    try c.handleError(result);
    session_active = true;
    return .{};
}

fn shutdown() WildMidiError!void {
    c.lib.WildMidi_ClearError();
    try c.handleError(c.lib.WildMidi_Shutdown());
    vio.reset();
    session_active = false;
}

const testing = std.testing;
const test_support = @import("testing.zig");
var vio_allocations: usize = 0;
var vio_frees: usize = 0;

extern fn _WM_BufferFileImpl([*:0]const u8, *u32) callconv(.c) ?*anyopaque;
extern fn _WM_FreeBufferFileImpl(?*anyopaque) callconv(.c) void;

fn missingAllocate(_: [*c]const u8, _: [*c]u32) callconv(.c) ?*anyopaque {
    return null;
}

fn testVioAllocate(name: [*c]const u8, size: [*c]u32) callconv(.c) ?*anyopaque {
    if (std.mem.eql(u8, std.mem.span(name), "vio/missing.mid")) return null;
    const result = _WM_BufferFileImpl(@ptrCast(name), @ptrCast(size));
    if (result != null) vio_allocations += 1;
    return result;
}

fn testVioFree(ptr: ?*anyopaque) callconv(.c) void {
    vio_frees += 1;
    _WM_FreeBufferFileImpl(ptr);
}

test "C VIO validates callbacks before init" {
    var callbacks: c.CVio = .{ .allocate_file = null, .free_file = null };
    try testing.expectError(error.InvalidArgument, initVioRaw(&callbacks, "unused.cfg", 44100, .{}));
}

test "null C VIO allocation has a meaningful error and permits retry" {
    var callbacks: c.CVio = .{ .allocate_file = missingAllocate, .free_file = testVioFree };
    try testing.expectError(error.UnableToOpen, initVioRaw(&callbacks, "missing.cfg", 44100, .{}));
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    session.deinit();
}

test "integration: VIO ownership and callback read failure" {
    const config = try test_support.freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);
    vio_allocations = 0;
    vio_frees = 0;
    var callbacks: c.CVio = .{ .allocate_file = testVioAllocate, .free_file = testVioFree };
    const session = try initVioRaw(&callbacks, config, 44100, .{});
    defer session.deinit();

    try testing.expectError(error.UnableToOpen, MidiFile.open("vio/missing.mid"));
    const midi_file = try MidiFile.open("test/test.mid");
    defer midi_file.close();
    var buffer: [4096]u8 = undefined;
    try testing.expect(try midi_file.getOutput(&buffer) > 0);
    try testing.expect(vio_allocations > 0);
    try testing.expectEqual(vio_allocations, vio_frees);
}

test "masterVolume before init returns LibraryNotInitialized" {
    try testing.expectError(error.LibraryNotInitialized, WildMidi.masterVolume(.{}, 100));
}

test "openBuffer before init returns LibraryNotInitialized" {
    const buffer = [_]u8{0} ** 16;
    try testing.expectError(error.LibraryNotInitialized, (WildMidi{}).openBuffer(&buffer));
}

test "session can initialize again after teardown" {
    const first = try WildMidi.init(.{ .config_file = "@opl3" });
    first.deinit();
    const second = try WildMidi.init(.{ .config_file = "@opl3" });
    second.deinit();
}

test "session rejects buffers that cannot fit the C size" {
    if (comptime @sizeOf(usize) > @sizeOf(c_uint)) {
        const session = try WildMidi.init(.{ .config_file = "@opl3" });
        defer session.deinit();
        const too_large: [*]const u8 = @ptrFromInt(1);
        try testing.expectError(error.InvalidArgument, session.openBuffer(too_large[0 .. @as(usize, std.math.maxInt(c_uint)) + 1]));
    }
}

test "session opens a borrowed Zig file and owns parsed MIDI independently" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const file = try std.Io.Dir.cwd().openFile(testing.io, "test/test.mid", .{});
    const midi = try session.open(testing.io, testing.allocator, file);
    file.close(testing.io);
    defer midi.close();
    var output: [4096]u8 = undefined;
    try testing.expect(try midi.getOutput(&output) > 0);
}

test "session reads a Zig file from its current cursor" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    const with_prefix = try std.mem.concat(testing.allocator, u8, &.{ "prefix!", bytes });
    defer testing.allocator.free(with_prefix);
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "prefixed.mid", .data = with_prefix });
    const file = try temp.dir.openFile(testing.io, "prefixed.mid", .{});
    defer file.close(testing.io);
    var prefix: [7]u8 = undefined;
    try testing.expectEqual(@as(usize, 7), try file.readStreaming(testing.io, &.{&prefix}));
    const midi = try session.open(testing.io, testing.allocator, file);
    defer midi.close();
    var output: [4096]u8 = undefined;
    try testing.expect(try midi.getOutput(&output) > 0);
}

test "session file opening reports corrupt input and read failures" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "empty.mid", .data = "" });
    const empty = try temp.dir.openFile(testing.io, "empty.mid", .{});
    try testing.expectError(error.FileCorrupt, session.open(testing.io, testing.allocator, empty));
    empty.close(testing.io);
    try testing.expectError(error.UnableToRead, session.open(testing.io, testing.allocator, empty));
}

test "session file opening reports allocator failure" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const file = try std.Io.Dir.cwd().openFile(testing.io, "test/test.mid", .{});
    defer file.close(testing.io);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.UnableToAllocateMemory, session.open(testing.io, failing.allocator(), file));
}
