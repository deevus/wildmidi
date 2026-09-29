//! Shared MIDI fixtures, FreePats paths, and fault injection for tests.

const std = @import("std");
const testing = std.testing;

/// Allocate the required FreePats config path; the caller frees the result.
pub fn freepatsConfig(allocator: std.mem.Allocator) ![:0]u8 {
    const freepats_path = try testing.environ.getAlloc(allocator, "FREEPATS_PATH");
    defer allocator.free(freepats_path);
    return std.fs.path.joinZ(allocator, &.{ freepats_path, "freepats.cfg" });
}

/// Read the shared MIDI fixture into an allocation owned by the caller.
pub fn midiBytes(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, "test/test.mid", allocator, .unlimited);
}

extern fn WildMidi_TestFailConfigDirAlloc() void;

/// Make the next C config-directory allocation fail to exercise VIO cleanup.
pub fn failConfigDirAllocation() void {
    WildMidi_TestFailConfigDirAlloc();
}
