// GLES renderer: draws Framebuffer.back (X8R8G8B8) as a texture onto the
// XComponent surface (NativeWindow + EGL), letterboxed. Runs on its own
// thread; uploads only the dirty band. Lives in the qemu child process;
// the OHNativeWindow arrives via IPC parcel from the app process.
#ifndef RENDERER_H
#define RENDERER_H

#include <stdint.h>
#include <EGL/egl.h>
#include <native_window/external_window.h>

#include "qemu_abi.h"

/* attach a NativeWindow (takes ownership) and start the render thread;
 * detaches any previous window first */
int renderer_attach_window(OHNativeWindow *win);
/* stop the render thread, tear down EGL, destroy the attached window */
int renderer_detach_window();
int renderer_resize_surface(int32_t w, int32_t h);

/* letterbox viewport of the guest framebuffer inside the window (px) */
void renderer_get_viewport(int *x, int *y, int *w, int *h);

/* virgl 的宿主 GL 上下文工厂（DisplayGLCtx）：vm.cpp 在 console 就绪后挂到
 * console 上（qemu_console_set_display_gl_ctx）——qemu 自己的 egl-headless
 * 因时序（display_init 早于设备 realize）挂不上，见 fb.cpp 的说明。
 * ops 委托 qemu 的非 static EGL 工厂；create/make_current 时记录 ctx 句柄，
 * 渲染线程据此建共享采样 ctx（virgl 纹理直采上屏，无 readback）。 */
DisplayGLCtx *renderer_gl_ctx();

/* 把渲染线程已验证的 EGL 对象交给 qemu 的 GL 全局（qemu_egl_display/
 * qemu_egl_config/qemu_egl_rn_ctx）：virglrenderer 通过 qemu 的
 * get_egl_display 回调拿 display 建上下文，必须指向这套可用的 EGL。
 * 未就绪（EGL 还没初始化）返回 false。vm.cpp 在 qemu_system_entry 前调用。 */
bool renderer_egl_export(void **displaySlot, void **config, void **ctx);
/* 让调用线程持有 root ctx：virglrenderer 的初始 GL 能力探测发生在
 * create_gl_context 之前，那时该线程必须已有 current context。 */
bool renderer_egl_make_current_root();

#endif /* RENDERER_H */
