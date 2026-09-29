/* Regression: config-directory allocation failure must release a VIO buffer
 * through its owner's callback, not through free(). */
#undef NDEBUG /* Keep the assertions enabled in Release builds. */
#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "wildmidi_lib.h"
#include "wm_error.h"

extern void WildMidi_TestFailConfigDirAlloc(void);

static unsigned int allocations;
static unsigned int frees;
/* load_config writes a trailing byte; this storage must never reach free(). */
static unsigned char config_buffer[2] = { '\n', 0 };

static void *allocate_file(const char *path, uint32_t *size) {
    assert(strcmp(path, "vio/config.cfg") == 0);
    config_buffer[0] = '\n';
    config_buffer[1] = 0;
    *size = 1;
    allocations++;
    return config_buffer;
}

static void free_file(void *buffer) {
    assert(buffer == config_buffer);
    frees++;
    assert(frees <= allocations);
}

int main(void) {
    struct _WM_VIO callbacks = { allocate_file, free_file };
    unsigned int before_retry;

    WildMidi_ClearError();
    WildMidi_TestFailConfigDirAlloc();
    assert(WildMidi_InitVIO(&callbacks, "vio/config.cfg", 44100, 0) == -1);
    assert(_WM_Global_ErrorI == WM_ERR_MEM);
    assert(allocations > 0);
    assert(frees == allocations);

    /* The failure hook is one-shot and failed initialization must allow retry. */
    before_retry = allocations;
    WildMidi_ClearError();
    assert(WildMidi_InitVIO(&callbacks, "vio/config.cfg", 44100, 0) == 0);
    assert(allocations > before_retry);
    assert(frees == allocations);
    assert(WildMidi_Shutdown() == 0);
    assert(frees == allocations);

    return 0;
}
