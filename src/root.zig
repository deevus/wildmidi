pub const WildMidiError = @import("c.zig").WildMidiError;
pub const InitOptions = @import("c.zig").InitOptions;
pub const Options = @import("WildMidi.zig").Options;
pub const VioOptions = @import("WildMidi.zig").VioOptions;
pub const WildMidi = @import("WildMidi.zig").WildMidi;
pub const MidiFile = @import("MidiFile.zig").MidiFile;
pub const getVersion = @import("c.zig").getVersion;
pub const getError = @import("c.zig").getError;

comptime {
    if (@import("builtin").is_test) _ = @import("integration_test.zig");
}
