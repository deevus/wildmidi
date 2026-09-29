//! End-to-end checks across library initialization, file loading, and playback.

const std = @import("std");
const testing = std.testing;
const root = @import("root.zig");
const WildMidi = root.WildMidi;
const MidiFile = root.MidiFile;
const VioOptions = root.VioOptions;
const getError = root.getError;
const getVersion = root.getVersion;

const test_support = @import("testing.zig");

test "getVersion returns non-zero" {
    try testing.expect(getVersion() != 0);
}

test "getError returns a message after a failure" {
    try testing.expectError(error.LibraryNotInitialized, WildMidi.masterVolume(.{}, 100));
    const msg = getError();
    try testing.expect(msg != null);
    try testing.expect(std.mem.span(msg).len > 0);
}

test "session owns initialization, playback, and shutdown" {
    const session = try WildMidi.init(.{ .config_file = "@opl3" });
    defer session.deinit();

    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    const midi = try session.openBuffer(bytes);
    defer midi.close();
    var output: [4096]u8 = undefined;
    try testing.expect(try midi.getOutput(&output) > 0);
    try session.masterVolume(100);
    try testing.expectError(error.LibraryAlreadyInitialized, WildMidi.init(.{ .config_file = "@opl3" }));
}

test "VIO session reads config and MIDI through a standard Zig directory" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "config.cfg", .data = "\n" });
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "track.mid", .data = bytes });

    const session = try WildMidi.initVio(testing.io, testing.allocator, .{
        .config_file = "config.cfg",
        .dir = temp.dir,
    });
    defer session.deinit();
    const file = try temp.dir.openFile(testing.io, "track.mid", .{});
    const midi = try session.open(testing.io, testing.allocator, file);
    file.close(testing.io);
    defer midi.close();
    var output: [4096]u8 = undefined;
    try testing.expect(try midi.getOutput(&output) > 0);
    const through_vio = try MidiFile.open("track.mid");
    defer through_vio.close();
    try testing.expect(try through_vio.getOutput(&output) > 0);
}

test "cached missing patches remain failures across repeated opens" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{
        .sub_path = "config.cfg",
        .data = "bank 0\n0 absent.pat\n",
    });
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "track.mid", .data = bytes });

    for (0..2) |_| {
        const session = try WildMidi.initVio(testing.io, testing.allocator, .{
            .config_file = "config.cfg",
            .dir = temp.dir,
        });
        defer session.deinit();
        for (0..3) |_| {
            // Each open clears native diagnostics, but not the failed cache.
            try testing.expectError(error.UnableToLoad, session.openBuffer(bytes));
            const message = getError() orelse return error.MissingPatchDiagnostic;
            try testing.expect(std.mem.indexOf(u8, std.mem.span(message), "absent.pat") != null);
        }
        try testing.expectError(error.UnableToLoad, MidiFile.open("track.mid"));
    }
}

test "patch allocation failure stays visible after the allocator recovers" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{
        .sub_path = "config.cfg",
        .data = "bank 0\n0 patch.pat\n",
    });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "patch.pat", .data = "not a patch" });
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const session = try WildMidi.initVio(testing.io, failing.allocator(), .{
        .config_file = "config.cfg",
        .dir = temp.dir,
    });
    defer session.deinit();

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.UnableToLoad, session.openBuffer(bytes));
    try testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    const allocation_count = failing.allocations;
    try testing.expectError(error.UnableToLoad, session.openBuffer(bytes));
    try testing.expectEqual(allocation_count, failing.allocations);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "standard I/O VIO loads FreePats instruments" {
    const config = try test_support.freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);
    const session = try WildMidi.initVio(testing.io, testing.allocator, .{ .config_file = config });
    defer session.deinit();
    const midi = try MidiFile.open("test/test.mid");
    defer midi.close();
    var buffer: [16384]u8 = undefined;
    try testing.expect(try midi.getOutput(&buffer) > 0);
}

test "standard I/O VIO maps missing config and allocation failures and permits retry" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const opts: VioOptions = .{ .config_file = "config.cfg", .dir = temp.dir };
    try testing.expectError(error.UnableToOpen, WildMidi.initVio(testing.io, testing.allocator, opts));
    try temp.dir.writeFile(testing.io, .{ .sub_path = "config.cfg", .data = "\n" });
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.UnableToAllocateMemory, WildMidi.initVio(testing.io, failing.allocator(), opts));
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "track.mid", .data = bytes });
    const session = try WildMidi.initVio(testing.io, testing.allocator, opts);
    defer session.deinit();
    try testing.expectError(error.UnableToOpen, MidiFile.open("missing.mid"));
    const midi = try MidiFile.open("track.mid");
    defer midi.close();
}

test "rejected VIO initialization retains the first directory" {
    var first_dir = testing.tmpDir(.{});
    defer first_dir.cleanup();
    var second_dir = testing.tmpDir(.{});
    defer second_dir.cleanup();
    try first_dir.dir.writeFile(testing.io, .{ .sub_path = "config.cfg", .data = "\n" });
    try second_dir.dir.writeFile(testing.io, .{ .sub_path = "config.cfg", .data = "\n" });
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    try first_dir.dir.writeFile(testing.io, .{ .sub_path = "only-first.mid", .data = bytes });
    const session = try WildMidi.initVio(testing.io, testing.allocator, .{ .config_file = "config.cfg", .dir = first_dir.dir });
    defer session.deinit();
    try testing.expectError(error.LibraryAlreadyInitialized, WildMidi.initVio(testing.io, testing.allocator, .{ .config_file = "config.cfg", .dir = second_dir.dir }));
    const midi = try MidiFile.open("only-first.mid");
    defer midi.close();
}

test "ordinary and VIO sessions can follow one another" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "config.cfg", .data = "\n" });
    const ordinary = try WildMidi.init(.{ .config_file = "@opl3" });
    try testing.expectError(error.LibraryAlreadyInitialized, WildMidi.initVio(testing.io, testing.allocator, .{ .config_file = "config.cfg", .dir = temp.dir }));
    ordinary.deinit();
    const virtual = try WildMidi.initVio(testing.io, testing.allocator, .{ .config_file = "config.cfg", .dir = temp.dir });
    try testing.expectError(error.LibraryAlreadyInitialized, WildMidi.init(.{ .config_file = "@opl3" }));
    virtual.deinit();
    const again = try WildMidi.init(.{ .config_file = "@opl3" });
    again.deinit();
}

test "renders test.mid end to end" {
    const config = try test_support.freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    const session = try WildMidi.init(.{ .config_file = config });
    defer session.deinit();

    try testing.expect(getVersion() != 0);

    const midi_file = try MidiFile.open("test/test.mid");
    defer midi_file.close();
    try testing.expect(midi_file.handle != null);

    const info = (try midi_file.getInfo());
    try testing.expect(info.copyright == null);
    try testing.expect(info.approx_total_samples > 0);

    var buffer: [16384]u8 = undefined;
    const rendered = try midi_file.getOutput(&buffer);
    try testing.expect(rendered > 0);

    try session.masterVolume(100);
}

test "init twice returns LibraryAlreadyInitialized" {
    const config = try test_support.freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    const session = try WildMidi.init(.{ .config_file = config });
    defer session.deinit();

    try testing.expectError(error.LibraryAlreadyInitialized, WildMidi.init(.{ .config_file = config }));
}

test "open missing file returns UnableToStat" {
    const config = try test_support.freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);

    const session = try WildMidi.init(.{ .config_file = config });
    defer session.deinit();

    try testing.expectError(error.UnableToStat, MidiFile.open("does/not/exist.mid"));
}

test "failure recovery, seek boundaries, and playback rewind" {
    const config = try test_support.freepatsConfig(testing.allocator);
    defer testing.allocator.free(config);
    const session = try WildMidi.init(.{ .config_file = config });
    defer session.deinit();

    try testing.expectError(error.UnableToStat, MidiFile.open("does/not/exist.mid"));
    try testing.expectError(error.InvalidArgument, session.masterVolume(200));
    const bytes = try test_support.midiBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    const midi_file = try session.openBuffer(bytes);
    defer midi_file.close();
    const info = (try midi_file.getInfo());
    const end: u64 = info.approx_total_samples;
    try testing.expect(end > 4096);
    const halfway = try midi_file.seekFrames(end / 2);
    try testing.expectEqual(end / 2, halfway);
    try testing.expectEqual(halfway, @as(u64, (try midi_file.getInfo()).current_sample));
    try testing.expectEqual(@as(u64, 0), try midi_file.seekFrames(0));
    var buffer: [4096]u8 = undefined;
    try testing.expect(try midi_file.getOutput(&buffer) > 0);
    try testing.expectEqual(end, try midi_file.seekFrames(end));
    try testing.expectEqual(end, @as(u64, (try midi_file.getInfo()).current_sample));
    try testing.expectEqual(end, try midi_file.seekFrames(end + 1234));
    try testing.expectEqual(end, @as(u64, (try midi_file.getInfo()).current_sample));
    try testing.expectEqual(@as(u64, 0), try midi_file.seekFrames(0));
    try testing.expect(try midi_file.getOutput(&buffer) > 0);
}
