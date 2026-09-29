//! MIDI playback, audio rendering, and seeking.

const std = @import("std");
const c = @import("c.zig");
const vio = @import("vio.zig");
const WildMidiError = c.WildMidiError;
const OutputError = WildMidiError || error{EndOfStream};
pub const MidiFile = struct {
    handle: ?*c.lib.midi,

    pub const Info = struct {
        /// Borrowed from the C handle; valid until the next getInfo or close.
        copyright: ?[]const u8,
        current_sample: u32,
        approx_total_samples: u32,
        mixer_options: c.InitOptions,
        total_midi_time: u32,
    };

    pub const Options = struct {
        log_volume: ?bool = null,
        enhanced_resampling: ?bool = null,
        reverb: ?bool = null,
        loop: ?bool = null,
        text_as_lyric: ?bool = null,

        fn mask(self: @This()) u16 {
            var value: u16 = 0;
            if (self.log_volume != null) value |= @intCast(c.lib.WM_MO_LOG_VOLUME);
            if (self.enhanced_resampling != null) value |= @intCast(c.lib.WM_MO_ENHANCED_RESAMPLING);
            if (self.reverb != null) value |= @intCast(c.lib.WM_MO_REVERB);
            if (self.loop != null) value |= @intCast(c.lib.WM_MO_LOOP);
            if (self.text_as_lyric != null) value |= @intCast(c.lib.WM_MO_TEXTASLYRIC);
            return value;
        }

        fn setting(self: @This()) u16 {
            var value: u16 = 0;
            if (self.log_volume orelse false) value |= @intCast(c.lib.WM_MO_LOG_VOLUME);
            if (self.enhanced_resampling orelse false) value |= @intCast(c.lib.WM_MO_ENHANCED_RESAMPLING);
            if (self.reverb orelse false) value |= @intCast(c.lib.WM_MO_REVERB);
            if (self.loop orelse false) value |= @intCast(c.lib.WM_MO_LOOP);
            if (self.text_as_lyric orelse false) value |= @intCast(c.lib.WM_MO_TEXTASLYRIC);
            return value;
        }
    };

    /// Open a MIDI file by path using the file access configured at initialization.
    pub fn open(midi_file: [:0]const u8) WildMidiError!MidiFile {
        c.lib.WildMidi_ClearError();
        vio.clearCallbackError();
        const handle = c.lib.WildMidi_Open(midi_file);
        if (handle == null) {
            try c.handleGlobalError();
            return vio.lastError() orelse error.UnableToOpen;
        }
        return .{ .handle = handle };
    }

    /// Render stereo PCM and return bytes written, or error.EndOfStream when finished.
    /// A final partial chunk succeeds; an empty buffer returns zero without advancing playback.
    pub fn getOutput(self: MidiFile, buffer: []u8) OutputError!usize {
        if (buffer.len > std.math.maxInt(u32)) return error.InvalidArgument;
        c.lib.WildMidi_ClearError();
        const written = c.lib.WildMidi_GetOutput(self.handle, @ptrCast(buffer.ptr), @intCast(buffer.len));
        if (written < 0) {
            try c.handleGlobalError();
            return error.UnableToConvert;
        }
        if (written == 0 and buffer.len != 0) return error.EndOfStream;
        return @intCast(written);
    }

    /// Allocate one stereo PCM chunk, or return error.EndOfStream when finished.
    /// The caller frees the returned slice; zero capacity returns an empty slice without rendering.
    pub fn getOutputAlloc(self: MidiFile, allocator: std.mem.Allocator, max_bytes: usize) OutputError![]u8 {
        if (max_bytes % 4 != 0 or max_bytes > std.math.maxInt(c_int)) return error.InvalidArgument;
        const buffer = allocator.alloc(u8, max_bytes) catch return error.UnableToAllocateMemory;
        errdefer allocator.free(buffer);
        if (max_bytes == 0) return buffer;
        const written = try self.getOutput(buffer);
        return allocator.realloc(buffer, written) catch return error.UnableToAllocateMemory;
    }

    /// Snapshot playback info; copyright text is borrowed until getInfo or close.
    pub fn getInfo(self: MidiFile) WildMidiError!Info {
        c.lib.WildMidi_ClearError();
        const info = c.lib.WildMidi_GetInfo(self.handle);
        if (info == null) {
            try c.handleGlobalError();
            return error.UnableToOpen;
        }
        return .{
            .copyright = if (info.*.copyright == null) null else std.mem.span(info.*.copyright),
            .current_sample = info.*.current_sample,
            .approx_total_samples = info.*.approx_total_samples,
            .mixer_options = c.InitOptions.fromBits(info.*.mixer_options),
            .total_midi_time = info.*.total_midi_time,
        };
    }

    /// Null leaves a flag unchanged; an entirely empty update is a no-op.
    pub fn setOptions(self: MidiFile, options: Options) WildMidiError!void {
        const mask = options.mask();
        if (mask == 0) return;
        c.lib.WildMidi_ClearError();
        return c.handleError(c.lib.WildMidi_SetOption(self.handle, mask, options.setting()));
    }

    /// Seek to an absolute stereo frame and return the position reached, clamped to EOF.
    pub fn seekFrames(self: MidiFile, requested: u64) WildMidiError!u64 {
        if (requested > std.math.maxInt(c_ulong)) return error.InvalidArgument;
        var reached: c_ulong = @intCast(requested);
        c.lib.WildMidi_ClearError();
        try c.handleError(c.lib.WildMidi_FastSeek(self.handle, &reached));
        return @intCast(reached);
    }

    /// Release the MIDI handle and its borrowed info storage before library shutdown.
    pub fn close(self: MidiFile) void {
        c.lib.WildMidi_ClearError();
        _ = c.lib.WildMidi_Close(self.handle);
    }
};

const testing = std.testing;
const WildMidi = @import("WildMidi.zig").WildMidi;

const test_support = @import("testing.zig");

test "runtime option masks and info value expose Zig types" {
    const update: MidiFile.Options = .{ .log_volume = true, .reverb = false, .loop = true };
    try testing.expectEqual(@as(u16, 0x000d), update.mask());
    try testing.expectEqual(@as(u16, 0x0009), update.setting());
    try testing.expectEqual(@as(u16, 0), (MidiFile.Options{}).mask());
    try testing.expectEqual(@as(u16, 0x800f), (MidiFile.Options{ .log_volume = false, .enhanced_resampling = true, .reverb = false, .loop = true, .text_as_lyric = false }).mask());
    try testing.expectEqual(@as(u16, 0x000a), (MidiFile.Options{ .log_volume = false, .enhanced_resampling = true, .reverb = false, .loop = true, .text_as_lyric = false }).setting());
    const info: MidiFile.Info = .{ .copyright = null, .current_sample = 3, .approx_total_samples = 10, .mixer_options = .{}, .total_midi_time = 200 };
    try testing.expectEqual(@as(u32, 3), info.current_sample);
}

test "info copyright borrows storage owned by the MIDI handle" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const bytes = [_]u8{
        'M', 'T', 'h',  'd',  0, 0, 0, 6,  0, 0,    0,    1, 0,   96,
        'M', 'T', 'r',  'k',  0, 0, 0, 11, 0, 0xff, 0x02, 3, 'A', 'B',
        'C', 0,   0xff, 0x2f, 0,
    };
    const file = try session.openBuffer(&bytes);
    defer file.close();
    const before = try file.getInfo();
    try testing.expectEqualStrings("ABC", before.copyright.?);
    const snapshot = try file.getInfo();
    try testing.expectEqualStrings("ABC", snapshot.copyright.?);
    try testing.expectEqual(@as(u32, 0), snapshot.current_sample);
}

test "typed runtime updates preserve untouched flags and snapshot MIDI info" {
    const session = try WildMidi.init(.{ .config_file = "@opl3", .mixer_options = .{ .reverb = true, .loop = true } });
    defer session.deinit();
    const midi_file = try MidiFile.open("test/test.mid");
    defer midi_file.close();
    const initial = try midi_file.getInfo();
    try testing.expect(initial.approx_total_samples > 0);
    try testing.expect(initial.mixer_options.reverb and initial.mixer_options.loop);
    try testing.expect(initial.copyright == null);
    try midi_file.setOptions(.{ .reverb = false });
    const updated = try midi_file.getInfo();
    try testing.expect(!updated.mixer_options.reverb and updated.mixer_options.loop);
    try midi_file.setOptions(.{});
    try midi_file.setOptions(.{ .loop = false, .log_volume = true });
    const final_info = try midi_file.getInfo();
    try testing.expect(!final_info.mixer_options.loop and final_info.mixer_options.log_volume);
    try testing.expectEqual(initial.approx_total_samples, final_info.approx_total_samples);
    try testing.expectEqual(@as(u32, 0), final_info.current_sample);
}

test "open before init returns LibraryNotInitialized" {
    try testing.expectError(error.LibraryNotInitialized, MidiFile.open("test/test.mid"));
}

test "getInfo before init returns LibraryNotInitialized" {
    const mf = MidiFile{ .handle = null };
    try testing.expectError(error.LibraryNotInitialized, mf.getInfo());
}

test "setOptions with an empty update is a no-op even before init" {
    const mf = MidiFile{ .handle = null };
    try mf.setOptions(.{});
    try testing.expectError(error.LibraryNotInitialized, mf.setOptions(.{ .reverb = true }));
}

test "getOutput before init returns LibraryNotInitialized" {
    const mf = MidiFile{ .handle = null };
    var buffer: [64]u8 = undefined;
    try testing.expectError(error.LibraryNotInitialized, mf.getOutput(&buffer));
    if (comptime @sizeOf(usize) > @sizeOf(u32)) {
        const too_large: [*]u8 = @ptrFromInt(1);
        try testing.expectError(error.InvalidArgument, mf.getOutput(too_large[0 .. @as(usize, std.math.maxInt(u32)) + 1]));
    }
}

test "seek before init reports the current operation" {
    const mf: MidiFile = .{ .handle = null };
    try testing.expectError(error.LibraryNotInitialized, mf.seekFrames(0));
    if (comptime @sizeOf(c_ulong) < @sizeOf(u64)) {
        try testing.expectError(error.InvalidArgument, mf.seekFrames(std.math.maxInt(u64)));
    }
}

test "getOutputAlloc matches non-allocating output and frees by returned length" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    const first = try session.openBuffer(bytes);
    defer first.close();
    const second = try session.openBuffer(bytes);
    defer second.close();
    var expected: [4096]u8 = undefined;
    const count = try first.getOutput(&expected);
    const actual = try second.getOutputAlloc(testing.allocator, expected.len);
    defer testing.allocator.free(actual);
    try testing.expectEqual(count, actual.len);
    try testing.expectEqualSlices(u8, expected[0..count], actual);

    const end = (try second.getInfo()).approx_total_samples;
    _ = try second.seekFrames(end - 64);
    const last = try second.getOutputAlloc(testing.allocator, 4096);
    defer testing.allocator.free(last);
    try testing.expect(last.len > 0 and last.len < 4096);
    try testing.expectError(error.EndOfStream, second.getOutputAlloc(testing.allocator, 4096));
    try testing.expectError(error.EndOfStream, second.getOutputAlloc(testing.allocator, 4096));
    const empty = try second.getOutputAlloc(testing.allocator, 0);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    _ = try second.seekFrames(0);
    const restarted = try second.getOutputAlloc(testing.allocator, 4096);
    defer testing.allocator.free(restarted);
    try testing.expect(restarted.len > 0);
}

test "getOutput returns short final chunks then EndOfStream until rewind" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    const midi = try session.openBuffer(bytes);
    defer midi.close();
    const end = (try midi.getInfo()).approx_total_samples;
    _ = try midi.seekFrames(end - 64);
    var buffer: [4096]u8 = undefined;
    const last = try midi.getOutput(&buffer);
    try testing.expect(last > 0 and last < buffer.len);
    try testing.expectError(error.EndOfStream, midi.getOutput(&buffer));
    try testing.expectError(error.EndOfStream, midi.getOutput(&buffer));
    try testing.expectEqual(@as(usize, 0), try midi.getOutput(buffer[0..0]));
    _ = try midi.seekFrames(0);
    try testing.expectEqual(@as(usize, 0), try midi.getOutput(buffer[0..0]));
    try testing.expectEqual(@as(u32, 0), (try midi.getInfo()).current_sample);
    try testing.expect(try midi.getOutput(&buffer) > 0);
}

test "getOutputAlloc validates capacity and allocation failures" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const invalid: MidiFile = .{ .handle = null };
    try testing.expectError(error.InvalidArgument, invalid.getOutputAlloc(testing.allocator, 3));
    try testing.expectError(error.InvalidArgument, invalid.getOutputAlloc(testing.allocator, @as(usize, std.math.maxInt(c_int)) + 1));
    const empty = try invalid.getOutputAlloc(testing.allocator, 0);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expectError(error.InvalidArgument, invalid.getOutputAlloc(testing.allocator, 4));
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.UnableToAllocateMemory, invalid.getOutputAlloc(failing.allocator(), 4096));
}

test "getOutputAlloc frees the buffer if its final resize fails" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    const midi = try session.openBuffer(bytes);
    defer midi.close();
    const end = (try midi.getInfo()).approx_total_samples;
    _ = try midi.seekFrames(end - 64);
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    try testing.expectError(error.UnableToAllocateMemory, midi.getOutputAlloc(failing.allocator(), 4096));
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "integration: setOptions on a live handle succeeds" {
    const config = try test_support.freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    const session = try WildMidi.init(.{ .config_file = config });
    defer session.deinit();

    const midi_file = try MidiFile.open("test/test.mid");
    defer midi_file.close();

    try midi_file.setOptions(.{ .log_volume = true });
}
