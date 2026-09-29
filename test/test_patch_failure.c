/* Public-open regression for cached patch failures. MIDI inputs are generated
 * with the library's event serializer, not copied from external music fixtures. */
#undef NDEBUG
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wildmidi_lib.h"
#include "internal_midi.h"
#include "f_midi.h"
#include "patches.h"
#include "synth.h"

struct song {
    uint8_t *data;
    uint32_t size;
};

static struct song file_song;
static unsigned patch_reads, allocations, frees;
static int corrupt_patch;
static char patch_name[512] = "unavailable.pat";

static void *copy_file(const void *data, uint32_t len, uint32_t *size) {
    uint8_t *copy = (uint8_t *) malloc((size_t) len + 1);
    assert(copy != NULL);
    memcpy(copy, data, len);
    copy[len] = 0;
    *size = len;
    allocations++;
    return copy;
}

static void *read_file(const char *name, uint32_t *size) {
    static const uint8_t corrupt[32] = {0};
    if (strcmp(name, "song.mid") == 0)
        return copy_file(file_song.data, file_song.size, size);
    assert(strcmp(name, patch_name) == 0);
    patch_reads++;
    *size = 0;
    if (corrupt_patch) return copy_file(corrupt, sizeof(corrupt), size);
    return NULL;
}

static void free_file(void *data) {
    assert(data != NULL);
    frees++;
    free(data);
}

static struct _WM_VIO vio = {read_file, free_file};

static void event(struct _mdi *mdi, uint8_t status, uint8_t a, uint8_t b) {
    uint8_t bytes[3] = {status, a, b};
    uint32_t len = (status & 0xf0) == 0xc0 ? 2 : 3;
    assert(_WM_SetupMidiEvent(mdi, bytes, len, 0) == len);
}

static const uint8_t gm_reset[] = {0xf0, 5, 0x7e, 0x7f, 9, 1, 0xf7};
static const uint8_t gs_reset[] = {0xf0, 10, 0x41, 0x10, 0x42, 0x12,
                                 0x40, 0, 0x7f, 0, 0x41, 0xf7};
static const uint8_t xg_reset[] = {0xf0, 8, 0x43, 0x10, 0x4c, 0, 0, 0x7e, 0, 0xf7};
static const uint8_t drum_off[] = {0xf0, 10, 0x41, 0x10, 0x42, 0x12,
                                 0x40, 0x10, 0x15, 0, 0x1b, 0xf7};

static void sysex(struct _mdi *mdi, const uint8_t *bytes, uint32_t len) {
    assert(_WM_SetupMidiEvent(mdi, bytes, len, 0) == len);
}

static void check_reset_state(void) {
    const uint8_t *resets[] = {gm_reset, gs_reset, xg_reset};
    const uint32_t sizes[] = {sizeof(gm_reset), sizeof(gs_reset), sizeof(xg_reset)};
    struct _mdi *mdi = _WM_initMDI();
    unsigned i;
    assert(mdi != NULL);
    for (i = 0; i < 3; i++) {
        event(mdi, 0xc0, 1, 0);
        event(mdi, 0xb0, 0, 5);
        sysex(mdi, resets[i], sizes[i]);
        assert(mdi->channel[0].bank == 0);
        assert(mdi->channel[0].patch == _WM_get_patch_data(mdi, 0));
        assert(mdi->channel[9].isdrum);
    }
    sysex(mdi, drum_off, sizeof(drum_off));
    assert(!mdi->channel[9].isdrum);
    assert(mdi->channel[9].patch == _WM_get_patch_data(mdi, 0));
    _WM_freeMDI(mdi);
}

static struct song make_song(int program, unsigned repeats, int drum,
                             int healthy_first, int reset) {
    struct song song = {NULL, 0};
    struct _mdi *mdi = _WM_initMDI();
    unsigned i;
    uint8_t channel = drum || reset == 2 ? 9 : 0;
    assert(mdi != NULL);
    assert(_WM_midi_setup_divisions(mdi, 96) == 0);
    assert(_WM_midi_setup_tempo(mdi, 500000) == 0);
    if (healthy_first) {
        event(mdi, 0xc0, 1, 0);
        event(mdi, 0x90, 64, 96);
        mdi->events[mdi->event_count - 1].samples_to_next = 2205;
        event(mdi, 0x80, 64, 0);
    }
    if (reset == 1) {
        event(mdi, 0xc0, 1, 0);
        sysex(mdi, gm_reset, sizeof(gm_reset));
    }
    for (i = 0; i < repeats; i++) {
        if (program >= 0) event(mdi, 0xc0 | channel, (uint8_t) program, 0);
        event(mdi, 0x90 | channel, 60, 96);
        mdi->events[mdi->event_count - 1].samples_to_next = 2205;
        event(mdi, 0x80 | channel, 60, 0);
    }
    assert(_WM_midi_setup_endoftrack(mdi) == 0);
    _WM_ResetToStart(mdi);
    assert(_WM_Event2Midi(mdi, &song.data, &song.size) == 0);
    if (reset == 2) {
        /* The existing serializer omits the drum-track message's checksum.
         * Insert the complete command before the generated track events. */
        uint32_t extra = 1 + sizeof(drum_off);
        uint32_t track_size;
        song.data = (uint8_t *) realloc(song.data, song.size + extra);
        assert(song.data != NULL);
        memmove(song.data + 22 + extra, song.data + 22, song.size - 22);
        song.data[22] = 0; /* zero delta */
        memcpy(song.data + 23, drum_off, sizeof(drum_off));
        song.size += extra;
        track_size = song.size - 22;
        for (i = 0; i < 4; i++)
            song.data[18 + i] = (uint8_t) (track_size >> (24 - i * 8));
    }
    _WM_freeMDI(mdi);
    return song;
}

/* Keep the built-in healthy bank, but route one configured patch through VIO.
 * This isolates failures without adding a soundbank fixture or dependency. */
static void make_unavailable(uint16_t patchid) {
    struct _patch *patch = _WM_get_patch_data(NULL, patchid);
    size_t name_size = strlen(patch_name) + 1;
    assert(patch != NULL && patch->patchid == patchid);
    assert(patch->first_sample == NULL && patch->inuse_count == 0);
    free(patch->filename);
    patch->filename = (char *) malloc(name_size);
    assert(patch->filename != NULL);
    memcpy(patch->filename, patch_name, name_size);
}

static void expect_failure(struct song song, int from_file) {
    midi *handle;
    const char *error;
    WildMidi_ClearError();
    file_song = song;
    handle = from_file ? WildMidi_Open("song.mid")
                       : WildMidi_OpenBuffer(song.data, song.size);
    assert(handle == NULL);
    error = WildMidi_GetError();
    assert(error != NULL && strstr(error, "Unable to load") != NULL);
    if (strlen(patch_name) < 128)
        assert(strstr(error, patch_name) != NULL);
    assert(allocations == frees);
}

static void expect_audio(struct song song) {
    midi *handle;
    int16_t pcm[2048];
    int bytes, audible = 0;
    unsigned blocks = 0, i;
    WildMidi_ClearError();
    handle = WildMidi_OpenBuffer(song.data, song.size);
    assert(handle != NULL);
    assert(WildMidi_GetError() == NULL);
    while ((bytes = WildMidi_GetOutput(handle, (int8_t *) pcm, sizeof(pcm))) > 0) {
        for (i = 0; i < (unsigned) bytes / sizeof(*pcm); i++)
            if (pcm[i] != 0) audible = 1;
        assert(++blocks < 1000);
    }
    assert(bytes == 0 && audible);
    assert(WildMidi_Close(handle) == 0);
}

int main(int argc, char **argv) {
    struct song song, healthy;
    unsigned cycle;
    int implicit, drum, healthy_case, cleanup, reset;
    assert(argc == 2);
    implicit = strcmp(argv[1], "implicit") == 0;
    drum = strcmp(argv[1], "drum") == 0;
    healthy_case = strcmp(argv[1], "healthy") == 0;
    cleanup = strcmp(argv[1], "cleanup") == 0;
    reset = strcmp(argv[1], "reset") == 0 ? 1 :
            strcmp(argv[1], "drum_off") == 0 ? 2 : 0;
    corrupt_patch = strcmp(argv[1], "corrupt") == 0;
    if (strcmp(argv[1], "long_name") == 0) {
        memset(patch_name, 'a', sizeof(patch_name) - 1);
        patch_name[sizeof(patch_name) - 1] = '\0';
    }

    assert(WildMidi_InitVIO(&vio, WM_OPL3_CONFIG, 44100, 0) == 0);
    if (strcmp(argv[1], "reset_state") == 0) check_reset_state();
    song = make_song(implicit || drum || reset ? -1 : 0,
                     strcmp(argv[1], "repeated") == 0 || drum ? 64 : 1,
                     drum, cleanup, reset);
    healthy = make_song(1, 1, 0, 0, 0);
    assert(WildMidi_Shutdown() == 0);

    for (cycle = 0; cycle < 2; cycle++) {
        patch_reads = allocations = frees = 0;
        assert(WildMidi_InitVIO(&vio, WM_OPL3_CONFIG, 44100, 0) == 0);
        make_unavailable(drum ? 0x80 | 60 : 0);
        if (healthy_case) {
            expect_audio(healthy);
            assert(patch_reads == 0); /* unused default must not be fetched */
        }
        expect_failure(song, 0);
        assert(patch_reads == 1);
        expect_failure(song, 0);
        expect_failure(song, 1);
        assert(patch_reads == 1); /* failed cache is visible, without retries */
        expect_audio(healthy);
        if (cleanup) {
            struct _patch *patch = _WM_get_patch_data(NULL, 1);
            assert(patch->inuse_count == 0 && patch->first_sample == NULL);
        }
        assert(WildMidi_Shutdown() == 0);
        assert(allocations == frees);
    }
    free(song.data);
    free(healthy.data);
    WildMidi_ClearError();
    return 0;
}
