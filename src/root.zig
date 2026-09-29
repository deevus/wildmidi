pub const WildMidiError = error{
    NoError,
    UnableToAllocateMemory,
    UnableToStat,
    UnableToLoad,
    UnableToOpen,
    UnableToRead,
    InvalidOrUnsupportedFileFormat,
    FileCorrupt,
    LibraryNotInitialized,
    InvalidArgument,
    LibraryAlreadyInitialized,
    NotAMidiFile,
    RefusingToLoadUnusuallyLongFile,
    NotAnHmpFile,
    NotAnHmiFile,
    UnableToConvert,
    NotAMusFile,
    NotAnXmiFile,
    NotASmafFile,
    InvalidErrorCode,
};

fn handleError(error_status: c_int) WildMidiError!void {
    if (error_status == 0) return;
    return switch (_WM_Global_ErrorI) {
        wm_error.WM_ERR_MEM => error.UnableToAllocateMemory,
        wm_error.WM_ERR_STAT => error.UnableToStat,
        wm_error.WM_ERR_LOAD => error.UnableToLoad,
        wm_error.WM_ERR_OPEN => error.UnableToOpen,
        wm_error.WM_ERR_READ => error.UnableToRead,
        wm_error.WM_ERR_INVALID => error.InvalidOrUnsupportedFileFormat,
        wm_error.WM_ERR_CORUPT => error.FileCorrupt,
        wm_error.WM_ERR_NOT_INIT => error.LibraryNotInitialized,
        wm_error.WM_ERR_INVALID_ARG => error.InvalidArgument,
        wm_error.WM_ERR_ALR_INIT => error.LibraryAlreadyInitialized,
        wm_error.WM_ERR_NOT_MIDI => error.NotAMidiFile,
        wm_error.WM_ERR_LONGFIL => error.RefusingToLoadUnusuallyLongFile,
        wm_error.WM_ERR_NOT_HMP => error.NotAnHmpFile,
        wm_error.WM_ERR_NOT_HMI => error.NotAnHmiFile,
        wm_error.WM_ERR_CONVERT => error.UnableToConvert,
        wm_error.WM_ERR_NOT_MUS => error.NotAMusFile,
        wm_error.WM_ERR_NOT_XMI => error.NotAnXmiFile,
        wm_error.WM_ERR_NOT_SMAF => error.NotASmafFile,
        else => error.InvalidErrorCode,
    };
}

fn handleGlobalError() WildMidiError!void {
    try handleError(_WM_Global_ErrorI);
}

pub fn init(config_file: [:0]const u8, rate: u16, options: InitOptions) WildMidiError!void {
    WildMidi_ClearError();
    return handleError(WildMidi_Init(config_file, rate, @intFromEnum(options)));
}

pub const Vio = extern struct {
    allocate_file: ?*const fn ([*:0]const u8, *u32) callconv(.c) ?*anyopaque,
    free_file: ?*const fn (?*anyopaque) callconv(.c) void,
};

pub fn initVio(vio: *Vio, config_file: [:0]const u8, rate: u16, options: InitOptions) WildMidiError!void {
    WildMidi_ClearError();
    return handleError(WildMidi_InitVIO(vio, config_file, rate, @intFromEnum(options)));
}

pub fn shutdown() WildMidiError!void {
    WildMidi_ClearError();
    return handleError(WildMidi_Shutdown());
}

pub fn getVersion() c_long {
    return WildMidi_GetVersion();
}

pub const MidiFile = struct {
    handle: ?*anyopaque,

    pub fn open(midi_file: [:0]const u8) WildMidiError!MidiFile {
        WildMidi_ClearError();
        const handle = WildMidi_Open(midi_file);
        if (handle == null) {
            try handleGlobalError();
            return error.UnableToOpen;
        }
        return .{ .handle = handle };
    }

    pub fn getOutput(self: MidiFile, buffer: []u8) WildMidiError!usize {
        WildMidi_ClearError();
        const written = WildMidi_GetOutput(self.handle, @ptrCast(buffer.ptr), @intCast(buffer.len));
        if (written < 0) {
            try handleGlobalError();
            return error.UnableToConvert;
        }
        return @intCast(written);
    }

    pub fn getInfo(self: MidiFile) !?*WildMidiInfo {
        WildMidi_ClearError();
        const info = WildMidi_GetInfo(self.handle);
        if (info == null) {
            try handleGlobalError();
            return error.UnableToOpen;
        }
        return info;
    }

    pub fn setOption(self: MidiFile, options: u16, setting: u16) WildMidiError!void {
        WildMidi_ClearError();
        return handleError(WildMidi_SetOption(self.handle, options, setting));
    }

    pub fn seekFrames(self: MidiFile, requested: u64) WildMidiError!u64 {
        if (requested > std.math.maxInt(c_ulong)) return error.InvalidArgument;
        var reached: c_ulong = @intCast(requested);
        WildMidi_ClearError();
        try handleError(WildMidi_FastSeek(self.handle, &reached));
        return @intCast(reached);
    }

    pub fn close(self: MidiFile) void {
        WildMidi_ClearError();
        _ = WildMidi_Close(self.handle);
    }
};

pub fn openBuffer(midi_buffer: [*c]const u8, size: c_uint) WildMidiError!MidiFile {
    WildMidi_ClearError();
    const handle = WildMidi_OpenBuffer(midi_buffer, size);
    if (handle == null) {
        try handleGlobalError();
        return error.UnableToOpen;
    }
    return .{ .handle = handle };
}

pub fn getError() [*c]u8 {
    return WildMidi_GetError();
}

pub fn masterVolume(master_volume: u8) WildMidiError!void {
    WildMidi_ClearError();
    return handleError(WildMidi_MasterVolume(master_volume));
}

pub const InitOptions = enum(u16) {
    default = 0x0,
    log_volume = 0x1,
    enhanced_resampling = 0x2,
    reverb = 0x4,
    loop = 0x8,
    save_as_type0 = 0x1000,
    round_tempo = 0x2000,
    strip_silence = 0x4000,
    text_as_lyric = 0x8000,
};

pub const WildMidiInfo = extern struct {
    copyright: [*c]u8,
    current_sample: c_uint,
    approx_total_samples: c_uint,
    mixer_options: c_ushort,
    total_midi_time: c_uint,
};

extern fn WildMidi_Init(config_file: [*c]const u8, rate: u16, options: u16) c_int;
extern fn WildMidi_InitVIO(vio: *Vio, config_file: [*:0]const u8, rate: u16, options: u16) c_int;
extern fn WildMidi_FastSeek(handle: ?*anyopaque, position: *c_ulong) c_int;
extern fn WildMidi_ClearError() void;
extern fn WildMidi_GetVersion() c_long;
extern fn WildMidi_Open(midi_file: [*c]const u8) ?*anyopaque;
extern fn WildMidi_OpenBuffer(midi_buffer: [*c]const u8, size: c_uint) ?*anyopaque;
extern fn WildMidi_Close(handle: ?*anyopaque) c_int;
extern fn WildMidi_GetOutput(handle: ?*anyopaque, buffer: [*c]i8, size: c_uint) c_int;
extern fn WildMidi_GetInfo(handle: ?*anyopaque) [*c]WildMidiInfo;
extern fn WildMidi_GetError() [*c]u8;
extern fn WildMidi_MasterVolume(master_volume: u8) c_int;
extern fn WildMidi_SetOption(handle: ?*anyopaque, options: u16, setting: u16) c_int;
extern fn WildMidi_Shutdown() c_int;

extern const _WM_Global_ErrorI: c_int;

const std = @import("std");
const wm_error = @import("wm_error");
const StaticStringMap = std.StaticStringMap;
const logger = std.log.scoped(.wildmidi);
const testing = std.testing;

fn freepatsConfig(allocator: std.mem.Allocator) ![:0]u8 {
    const freepats_path = testing.environ.getAlloc(allocator, "FREEPATS_PATH") catch {
        return error.SkipZigTest;
    };
    defer allocator.free(freepats_path);
    return std.fs.path.joinZ(allocator, &.{ freepats_path, "freepats.cfg" });
}

test "getVersion returns non-zero" {
    try testing.expect(getVersion() != 0);
}

test "open before init returns LibraryNotInitialized" {
    try testing.expectError(error.LibraryNotInitialized, MidiFile.open("test/test.mid"));
}

test "masterVolume before init returns LibraryNotInitialized" {
    try testing.expectError(error.LibraryNotInitialized, masterVolume(100));
}

test "getInfo before init returns LibraryNotInitialized" {
    const mf = MidiFile{ .handle = null };
    try testing.expectError(error.LibraryNotInitialized, mf.getInfo());
}

test "setOption before init returns LibraryNotInitialized" {
    const mf = MidiFile{ .handle = null };
    try testing.expectError(error.LibraryNotInitialized, mf.setOption(0, 0));
}

test "getOutput before init returns LibraryNotInitialized" {
    const mf = MidiFile{ .handle = null };
    var buffer: [64]u8 = undefined;
    try testing.expectError(error.LibraryNotInitialized, mf.getOutput(&buffer));
}

test "getError returns a message after a failure" {
    try testing.expectError(error.LibraryNotInitialized, masterVolume(100));
    const msg = getError();
    try testing.expect(msg != null);
    try testing.expect(std.mem.span(msg).len > 0);
}

test "openBuffer before init returns LibraryNotInitialized" {
    const buffer = [_]u8{0} ** 16;
    try testing.expectError(error.LibraryNotInitialized, openBuffer(&buffer, buffer.len));
}

test "VIO validates callbacks before init" {
    var vio: Vio = .{ .allocate_file = null, .free_file = null };
    try testing.expectError(error.InvalidArgument, initVio(&vio, "unused.cfg", 44100, .default));
}

test "seek before init reports the current operation" {
    const mf: MidiFile = .{ .handle = null };
    try testing.expectError(error.LibraryNotInitialized, mf.seekFrames(0));
    if (comptime @sizeOf(c_ulong) < @sizeOf(u64)) {
        try testing.expectError(error.InvalidArgument, mf.seekFrames(std.math.maxInt(u64)));
    }
}

test "integration: renders test.mid end to end" {
    const config = try freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    try init(config, 44100, .default);
    defer shutdown() catch {};

    try testing.expect(getVersion() != 0);

    const midi_file = try MidiFile.open("test/test.mid");
    defer midi_file.close();
    try testing.expect(midi_file.handle != null);

    const info = (try midi_file.getInfo()).?;
    try testing.expect(info.copyright == null);
    try testing.expect(info.approx_total_samples > 0);

    var buffer: [16384]u8 = undefined;
    const rendered = try midi_file.getOutput(&buffer);
    try testing.expect(rendered > 0);

    try masterVolume(100);
}

test "integration: init twice returns LibraryAlreadyInitialized" {
    const config = try freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    try init(config, 44100, .default);
    defer shutdown() catch {};

    try testing.expectError(error.LibraryAlreadyInitialized, init(config, 44100, .default));
}

test "integration: open missing file returns UnableToStat" {
    const config = try freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    try init(config, 44100, .default);
    defer shutdown() catch {};

    try testing.expectError(error.UnableToStat, MidiFile.open("does/not/exist.mid"));
}

test "integration: failure recovery, seek boundaries, and playback rewind" {
    const config = try freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);
    try init(config, 44100, .default);
    defer shutdown() catch {};

    try testing.expectError(error.UnableToStat, MidiFile.open("does/not/exist.mid"));
    try testing.expectError(error.InvalidArgument, masterVolume(200));
    var size: u32 = 0;
    const bytes = _WM_BufferFileImpl("test/test.mid", &size) orelse return error.UnableToRead;
    defer _WM_FreeBufferFileImpl(bytes);
    const midi_file = try openBuffer(@ptrCast(bytes), size);
    defer midi_file.close();
    const info = (try midi_file.getInfo()).?;
    const end: u64 = info.approx_total_samples;
    try testing.expect(end > 4096);
    const halfway = try midi_file.seekFrames(end / 2);
    try testing.expectEqual(end / 2, halfway);
    try testing.expectEqual(halfway, @as(u64, (try midi_file.getInfo()).?.current_sample));
    try testing.expectEqual(@as(u64, 0), try midi_file.seekFrames(0));
    var buffer: [4096]u8 = undefined;
    try testing.expect(try midi_file.getOutput(&buffer) > 0);
    try testing.expectEqual(end, try midi_file.seekFrames(end));
    try testing.expectEqual(end, @as(u64, (try midi_file.getInfo()).?.current_sample));
    try testing.expectEqual(end, try midi_file.seekFrames(end + 1234));
    try testing.expectEqual(end, @as(u64, (try midi_file.getInfo()).?.current_sample));
    try testing.expectEqual(@as(u64, 0), try midi_file.seekFrames(0));
    try testing.expect(try midi_file.getOutput(&buffer) > 0);
}

var vio_allocations: usize = 0;
var vio_frees: usize = 0;
var vio_config_bytes = [_]u8{ '\n', 0 }; // Includes writable trailing byte for load_config.

extern fn WildMidi_TestFailConfigDirAlloc() void;

fn testVioAllocate(name: [*:0]const u8, size: *u32) callconv(.c) ?*anyopaque {
    if (std.mem.eql(u8, std.mem.span(name), "vio/missing.mid")) return null;
    if (std.mem.eql(u8, std.mem.span(name), "vio/config.cfg")) {
        size.* = 1;
        vio_allocations += 1;
        return @ptrCast(&vio_config_bytes);
    }
    const result = _WM_BufferFileImpl(name, size);
    if (result != null) vio_allocations += 1;
    return result;
}

fn testVioFree(ptr: ?*anyopaque) callconv(.c) void {
    vio_frees += 1;
    if (ptr == @as(?*anyopaque, @ptrCast(&vio_config_bytes))) return;
    _WM_FreeBufferFileImpl(ptr);
}

extern fn _WM_BufferFileImpl([*:0]const u8, *u32) callconv(.c) ?*anyopaque;
extern fn _WM_FreeBufferFileImpl(?*anyopaque) callconv(.c) void;

test "VIO config directory allocation failure frees callback-owned buffer" {
    vio_allocations = 0;
    vio_frees = 0;
    var vio: Vio = .{ .allocate_file = testVioAllocate, .free_file = testVioFree };
    WildMidi_TestFailConfigDirAlloc();
    try testing.expectError(error.UnableToAllocateMemory, initVio(&vio, "vio/config.cfg", 44100, .default));
    try testing.expectEqual(@as(usize, 2), vio_allocations);
    try testing.expectEqual(vio_allocations, vio_frees);
    try initVio(&vio, "vio/config.cfg", 44100, .default);
    try shutdown();
    try testing.expectEqual(vio_allocations, vio_frees);
}

test "integration: VIO ownership and callback read failure" {
    const config = try freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);
    vio_allocations = 0;
    vio_frees = 0;
    var vio: Vio = .{ .allocate_file = testVioAllocate, .free_file = testVioFree };
    try initVio(&vio, config, 44100, .default);
    defer shutdown() catch {};

    try testing.expectError(error.UnableToOpen, MidiFile.open("vio/missing.mid"));
    const midi_file = try MidiFile.open("test/test.mid");
    defer midi_file.close();
    var buffer: [4096]u8 = undefined;
    try testing.expect(try midi_file.getOutput(&buffer) > 0);
    try testing.expect(vio_allocations > 0);
    try testing.expectEqual(vio_allocations, vio_frees);
}

test "integration: setOption on a live handle succeeds" {
    const config = try freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    try init(config, 44100, .default);
    defer shutdown() catch {};

    const midi_file = try MidiFile.open("test/test.mid");
    defer midi_file.close();

    // WM_MO_LOG_VOLUME = 0x0001 — enable it.
    try midi_file.setOption(0x0001, 0x0001);
}
