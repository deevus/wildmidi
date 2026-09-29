//! Translated C bindings, error mapping, and conversion between named flags and masks.

const wm_error = @import("wm_error");
const wm_file_io = @import("wm_file_io");
pub const lib = @import("wm_lib");

pub const max_file_size: usize = wm_file_io.WM_MAXFILESIZE;

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

/// Translate a nonzero C status using the library's current error code.
pub fn handleError(error_status: c_int) WildMidiError!void {
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

/// Translate the library's current error code, returning success when none is set.
pub fn handleGlobalError() WildMidiError!void {
    try handleError(_WM_Global_ErrorI);
}

pub const InitOptions = struct {
    log_volume: bool = false,
    enhanced_resampling: bool = false,
    reverb: bool = false,
    loop: bool = false,
    save_as_type0: bool = false,
    round_tempo: bool = false,
    strip_silence: bool = false,
    text_as_lyric: bool = false,

    /// Encode the named mixer flags using constants from the C header.
    pub fn bits(self: @This()) u16 {
        var value: u16 = 0;
        if (self.log_volume) value |= @intCast(lib.WM_MO_LOG_VOLUME);
        if (self.enhanced_resampling) value |= @intCast(lib.WM_MO_ENHANCED_RESAMPLING);
        if (self.reverb) value |= @intCast(lib.WM_MO_REVERB);
        if (self.loop) value |= @intCast(lib.WM_MO_LOOP);
        if (self.save_as_type0) value |= @intCast(lib.WM_MO_SAVEASTYPE0);
        if (self.round_tempo) value |= @intCast(lib.WM_MO_ROUNDTEMPO);
        if (self.strip_silence) value |= @intCast(lib.WM_MO_STRIPSILENCE);
        if (self.text_as_lyric) value |= @intCast(lib.WM_MO_TEXTASLYRIC);
        return value;
    }

    /// Decode supported C mixer flags, ignoring bits not represented by this struct.
    pub fn fromBits(value: u16) @This() {
        return .{
            .log_volume = value & @as(u16, @intCast(lib.WM_MO_LOG_VOLUME)) != 0,
            .enhanced_resampling = value & @as(u16, @intCast(lib.WM_MO_ENHANCED_RESAMPLING)) != 0,
            .reverb = value & @as(u16, @intCast(lib.WM_MO_REVERB)) != 0,
            .loop = value & @as(u16, @intCast(lib.WM_MO_LOOP)) != 0,
            .save_as_type0 = value & @as(u16, @intCast(lib.WM_MO_SAVEASTYPE0)) != 0,
            .round_tempo = value & @as(u16, @intCast(lib.WM_MO_ROUNDTEMPO)) != 0,
            .strip_silence = value & @as(u16, @intCast(lib.WM_MO_STRIPSILENCE)) != 0,
            .text_as_lyric = value & @as(u16, @intCast(lib.WM_MO_TEXTASLYRIC)) != 0,
        };
    }
};

pub const CVio = lib.struct__WM_VIO;
pub extern var _WM_Global_ErrorI: c_int;

/// Return the library version packed as major, minor, and micro bytes.
pub fn getVersion() c_long {
    return lib.WildMidi_GetVersion();
}

/// Borrow the C error string until the error is cleared or replaced; it may be null.
pub fn getError() [*c]u8 {
    return lib.WildMidi_GetError();
}

test "initialization flags use translated C constants" {
    const testing = @import("std").testing;
    const all: InitOptions = .{ .log_volume = true, .enhanced_resampling = true, .reverb = true, .loop = true, .save_as_type0 = true, .round_tempo = true, .strip_silence = true, .text_as_lyric = true };
    try testing.expectEqual(@as(u16, 0xf00f), all.bits());
    try testing.expectEqual(@as(u16, 0), (InitOptions{}).bits());
    try testing.expectEqualDeep(all, InitOptions.fromBits(all.bits()));
    try testing.expectEqualDeep(InitOptions{ .reverb = true, .loop = true }, InitOptions.fromBits(@intCast(lib.WM_MO_REVERB | lib.WM_MO_LOOP)));
}
