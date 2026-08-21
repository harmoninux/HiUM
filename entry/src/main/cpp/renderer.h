// GLES renderer: draws Framebuffer.back (X8R8G8B8) as a texture onto the
// XComponent surface (NativeWindow + EGL), letterboxed. Runs on its own
// thread; uploads only the dirty band. Lives in the qemu child process;
// the OHNativeWindow arrives via IPC parcel from the app process.
#ifndef RENDERER_H
#define RENDERER_H

#include <stdint.h>
#include <native_window/external_window.h>

/* attach a NativeWindow (takes ownership) and start the render thread;
 * detaches any previous window first */
int renderer_attach_window(OHNativeWindow *win);
/* stop the render thread, tear down EGL, destroy the attached window */
int renderer_detach_window();
int renderer_resize_surface(int32_t w, int32_t h);

/* letterbox viewport of the guest framebuffer inside the window (px) */
void renderer_get_viewport(int *x, int *y, int *w, int *h);

#endif /* RENDERER_H */
