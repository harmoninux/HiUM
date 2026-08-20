// GLES renderer: draws Framebuffer.back (X8R8G8B8) as a texture onto the
// XComponent surface (NativeWindow + EGL), letterboxed. Runs on its own
// thread; uploads only the dirty band.
#ifndef RENDERER_H
#define RENDERER_H

#include <stdint.h>

int renderer_create_surface(int64_t surfaceId);
int renderer_resize_surface(int64_t surfaceId, int32_t w, int32_t h);
int renderer_destroy_surface(int64_t surfaceId);

/* letterbox viewport of the guest framebuffer inside the window (px) */
void renderer_get_viewport(int *x, int *y, int *w, int *h);

#endif /* RENDERER_H */
