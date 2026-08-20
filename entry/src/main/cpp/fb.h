// Framebuffer state shared between qemu display-listener callbacks (called on
// qemu threads) and the GLES render thread. All pixels are converted to
// X8R8G8B8 (== GL_BGRA_EXT byte order on little-endian) into `back`.
#ifndef FB_H
#define FB_H

#include "qemu_abi.h"
#include <mutex>
#include <vector>

struct Framebuffer {
    std::mutex mu;
    DisplaySurface *surface = nullptr; // owned by qemu, deref only under mu
    int w = 0;
    int h = 0;
    std::vector<uint32_t> back;        // converted X8R8G8B8 pixels
    bool dirty = false;                // dirty band [dirtyY0, dirtyY1) full width
    int dirtyY0 = 0;
    int dirtyY1 = 0;
    bool resized = false;              // surface geometry changed
    uint64_t frames = 0;               // completed update counter
};

extern Framebuffer g_fb;

/* qemu DCL ops implementation (called from qemu threads) */
extern DisplayChangeListener g_dcl;

/* convert+merge a dirty rect from the current qemu surface into back buffer.
 * must be called with g_fb.mu held. */
void fb_update_rect(int x, int y, int w, int h);

#endif /* FB_H */
