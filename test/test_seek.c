/* Regression for seeking to approximate EOF, including clamping and replay.
 * Generate a short MIDI through the existing serializer and use the built-in
 * bank so this native test needs no external music or soundbank files. */
#undef NDEBUG
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "wildmidi_lib.h"
#include "internal_midi.h"
#include "f_midi.h"
#include "synth.h"

static midi *open_song(void) {
    const uint8_t program[] = {0xc0, 0};
    const uint8_t note_on[] = {0x90, 60, 96};
    struct _mdi *mdi = _WM_initMDI();
    uint8_t *bytes = NULL;
    uint32_t size = 0;
    midi *handle;
    assert(mdi != NULL);
    assert(_WM_midi_setup_divisions(mdi, 96) == 0);
    assert(_WM_midi_setup_tempo(mdi, 500000) == 0);
    assert(_WM_SetupMidiEvent(mdi, program, sizeof(program), 0) == sizeof(program));
    assert(_WM_SetupMidiEvent(mdi, note_on, sizeof(note_on), 0) == sizeof(note_on));
    mdi->events[mdi->event_count - 1].samples_to_next = 22050;
    assert(_WM_midi_setup_noteoff(mdi, 0, 60, 0) == 0);
    assert(_WM_midi_setup_endoftrack(mdi) == 0);
    _WM_ResetToStart(mdi);
    assert(_WM_Event2Midi(mdi, &bytes, &size) == 0);
    _WM_freeMDI(mdi);
    handle = WildMidi_OpenBuffer(bytes, size);
    free(bytes);
    assert(handle != NULL);
    return handle;
}

static void seek_to(midi *handle, unsigned long requested, unsigned long expected) {
    struct _WM_Info *info;
    assert(WildMidi_FastSeek(handle, &requested) == 0);
    assert(requested == expected);
    info = WildMidi_GetInfo(handle);
    assert(info != NULL && info->current_sample == expected);
}

static void check_seeking(uint16_t options) {
    midi *handle;
    struct _WM_Info *info;
    unsigned long end;
    int8_t initial[4096], replay[4096];
    int bytes, first_bytes;
    unsigned blocks = 0;
    assert(WildMidi_Init(WM_OPL3_CONFIG, 44100, options) == 0);
    handle = open_song();
    info = WildMidi_GetInfo(handle);
    assert(info != NULL);
    end = info->approx_total_samples;
    assert(end > 2048);

    /* The old early return reported EOF without moving the handle. */
    seek_to(handle, end, end);
    seek_to(handle, 0, 0);
    first_bytes = WildMidi_GetOutput(handle, initial, sizeof(initial));
    assert(first_bytes > 0);
    seek_to(handle, ULONG_MAX, end);
    seek_to(handle, 0, 0);
    bytes = WildMidi_GetOutput(handle, replay, sizeof(replay));
    assert(bytes == first_bytes && memcmp(initial, replay, bytes) == 0);

    /* Rewind after natural EOF must remain playable as well. */
    while ((bytes = WildMidi_GetOutput(handle, replay, sizeof(replay))) > 0)
        assert(++blocks < 1000);
    assert(bytes == 0);
    seek_to(handle, 0, 0);
    bytes = WildMidi_GetOutput(handle, replay, sizeof(replay));
    assert(bytes == first_bytes && memcmp(initial, replay, bytes) == 0);
    assert(WildMidi_Close(handle) == 0);
    assert(WildMidi_Shutdown() == 0);
}

int main(void) {
    check_seeking(0);
    check_seeking(WM_MO_REVERB);
    return 0;
}
