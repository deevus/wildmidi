const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Yamaha MA-series FM synthesis for SMAF files.  On by default, but
    // consumers can opt out with -Dmafm=false (mirrors the WANT_MAFM CMake
    // option); the mafm sources then compile to their empty stubs.
    const want_mafm = b.option(bool, "mafm", "Enable Yamaha MA FM synthesis for SMAF files") orelse true;
    const mafm_define: ?i64 = if (want_mafm) 1 else null;

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    lib_mod.addIncludePath(b.path("include"));

    const lib = b.addLibrary(.{
        .name = "wildmidi",
        .root_module = lib_mod,
    });

    const source_files = .{
        "src/wm_error.c",
        "src/file_io.c",
        "src/lock.c",
        "src/wildmidi_lib.c",
        "src/reverb.c",
        "src/gus_pat.c",
        "src/internal_midi.c",
        "src/patches.c",
        "src/f_xmidi.c",
        "src/f_mus.c",
        "src/f_hmp.c",
        "src/f_hmi.c",
        "src/f_midi.c",
        "src/f_smaf.c",
        "src/sample.c",
        "src/synth.c",
        "src/opl3.c",
        "src/sf2.c",
        "src/mafm.c",
        "src/mafm/ma_fm_core.c",
        "src/mafm/smaf_voice.c",
        "src/mafm/yamaha_adpcm.c",
        "src/mus2mid.c",
        "src/xmi2mid.c",
        "src/hmp2mid.c",
        "src/hmi2mid.c",
        "src/smaf2mid.c",
    };

    const defaultFlags = .{
        "-DWILDMIDI_BUILD",
    };

    const config_header = b.addConfigHeader(
        .{
            .style = .{
                .cmake = b.path("include/config.h.cmake"),
            },
        },
        .{
            .WILDMIDI_CFG = b.pathFromRoot("cfg/wildmidi.cfg"),
            .WILDMIDI_VERSION = "0.4.6",
            .HAVE_C_INLINE = 1,
            .HAVE_C___INLINE = 1,
            .HAVE_C___INLINE__ = 1,
            .HAVE___BUILTIN_EXPECT = 1,
            .HAVE_STDINT_H = 1,
            .HAVE_INTTYPES_H = 1,
            .WORDS_BIGENDIAN = null,
            .WILDMIDI_AMIGA = null,
            .WILDMIDI_MAFM = mafm_define,
            .HAVE_SYS_SOUNDCARD_H = null,
            .AUDIODRV_ALSA = null,
            .AUDIODRV_OSS = null,
            .AUDIODRV_AHI = null,
            .AUDIODRV_OPENAL = null,
        },
    );

    lib_mod.addConfigHeader(config_header);

    switch (target.result.os.tag) {
        .windows => {
            lib_mod.addCSourceFiles(.{
                .files = &source_files,
                .flags = &(.{"-DWILDMIDI_STATIC"} ++ defaultFlags),
            });
            lib_mod.addIncludePath(b.path("mingw"));
        },
        .macos => {
            lib_mod.addCSourceFiles(.{
                .files = &source_files,
                .flags = &defaultFlags,
            });
            lib_mod.addIncludePath(b.path("macosx"));
        },
        else => {
            lib_mod.addCSourceFiles(.{
                .files = &source_files,
                .flags = &defaultFlags,
            });
        },
    }

    lib.installHeadersDirectory(b.path("include"), "", .{});

    b.installArtifact(lib);

    const mod = b.addModule("wildmidi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkLibrary(lib);

    const wm_error_tc = b.addTranslateC(.{
        .root_source_file = b.path("include/wm_error.h"),
        .target = target,
        .optimize = optimize,
    });
    wm_error_tc.addIncludePath(b.path("include"));
    mod.addImport("wm_error", wm_error_tc.createModule());

    // The fault-injection seam is present only in the test library, never in
    // the module installed by consumers.
    const test_lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_lib_mod.addIncludePath(b.path("include"));
    test_lib_mod.addConfigHeader(config_header);
    const testFlags = .{ "-DWILDMIDI_BUILD", "-DWILDMIDI_TESTING" };
    switch (target.result.os.tag) {
        .windows => {
            test_lib_mod.addCSourceFiles(.{ .files = &source_files, .flags = &(.{"-DWILDMIDI_STATIC"} ++ testFlags) });
            test_lib_mod.addIncludePath(b.path("mingw"));
        },
        .macos => {
            test_lib_mod.addCSourceFiles(.{ .files = &source_files, .flags = &testFlags });
            test_lib_mod.addIncludePath(b.path("macosx"));
        },
        else => test_lib_mod.addCSourceFiles(.{ .files = &source_files, .flags = &testFlags }),
    }
    const test_lib = b.addLibrary(.{ .name = "wildmidi_test", .root_module = test_lib_mod });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.linkLibrary(test_lib);
    test_mod.addImport("wm_error", wm_error_tc.createModule());
    const tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = true,
    });

    const run_lib_unit_tests = b.addRunArtifact(tests);
    const with_test_bank = b.option(bool, "test-with-freepats", "Run integration tests with the pinned FreePats bank") orelse false;
    if (with_test_bank) {
        const freepats = b.lazyDependency("freepats", .{}) orelse return;
        run_lib_unit_tests.setEnvironmentVariable("FREEPATS_PATH", freepats.builder.build_root.path.?);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
