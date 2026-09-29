// Minimal ABI declarations matching qemu 10.2 (hish-libqemu fork) internal
// structures. The fork builds qemu-system-* as shared libraries with default
// symbol visibility (no version script), so we dlsym these functions and
// reproduce only the struct layouts we touch. Keep in sync with
// deps/download/qemu when bumping qemu.
//
// Reference: include/ui/console.h, include/ui/surface.h, include/ui/input.h
#ifndef QEMU_ABI_H
#define QEMU_ABI_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void QemuConsole;
typedef void QemuGLCtx;

/* ---- pixman forward decls (we convert manually, no pixman link) ---- */
typedef struct pixman_image pixman_image_t;
typedef int32_t pixman_format_code_t;

/* pixman format codes we care about (PIXMAN_FORMAT(bpp,type,a,r,g,b) =
 * (bpp<<24)|(type<<16)|(a<<12)|(r<<8)|(g<<4)|b ; types: ARGB=2, BGRA=8, RGBA=9) */
#define PIXMAN_FORMAT_CODE_x8r8g8b8 0x20020888
#define PIXMAN_FORMAT_CODE_r8g8b8x8 0x20098880
#define PIXMAN_FORMAT_CODE_b8g8r8x8 0x20080888
#define PIXMAN_FORMAT_CODE_r5g6b5   0x10020565
#define PIXMAN_FORMAT_CODE_x1r5g5b5 0x10020155
#define PIXMAN_FORMAT_BPP(f) (((f) >> 24) & 0x3f)

/* ---- DisplaySurface (ui/surface.h, CONFIG_OPENGL=y 变体) ----
 * 启用 OpenGL（virgl 构建）后中间多出 glformat/gltype/texture/mem_obj 四个
 * GL 字段，share_handle 的偏移随之后移。本进程只访问 offset 0 的 image
 * （fb.cpp 全部走 ->image），故字段差异无害；此处按真实布局补齐，改字段
 * 访问前先核对 qemu 的 include/ui/surface.h。 */
typedef struct DisplaySurface {
    pixman_image_t *image;
    uint8_t flags;
    uint32_t glformat;
    uint32_t gltype;
    uint32_t texture;
    uint32_t mem_obj;
    /* qemu_pixman_shareable share_handle = int on POSIX */
    int share_handle;
    uint32_t share_handle_offset;
} DisplaySurface;

/* accessors implemented via dlsym'd pixman (they live inside libqemu .so) */
typedef int (*pixman_image_get_width_fn)(pixman_image_t *);
typedef int (*pixman_image_get_height_fn)(pixman_image_t *);
typedef int (*pixman_image_get_stride_fn)(pixman_image_t *);
typedef uint32_t *(*pixman_image_get_data_fn)(pixman_image_t *);
typedef pixman_format_code_t (*pixman_image_get_format_fn)(pixman_image_t *);

/* ---- DisplayChangeListener (ui/console.h) ---- */
typedef struct DisplayChangeListener DisplayChangeListener;

typedef struct DisplayChangeListenerOps {
    const char *dpy_name;
    void (*dpy_refresh)(DisplayChangeListener *dcl);
    void (*dpy_gfx_update)(DisplayChangeListener *dcl, int x, int y, int w, int h);
    void (*dpy_gfx_switch)(DisplayChangeListener *dcl, DisplaySurface *new_surface);
    bool (*dpy_gfx_check_format)(DisplayChangeListener *dcl, pixman_format_code_t format);
    void (*dpy_text_cursor)(DisplayChangeListener *dcl, int x, int y);
    void (*dpy_text_resize)(DisplayChangeListener *dcl, int w, int h);
    void (*dpy_text_update)(DisplayChangeListener *dcl, int x, int y, int w, int h);
    void (*dpy_mouse_set)(DisplayChangeListener *dcl, int x, int y, bool on);
    void (*dpy_cursor_define)(DisplayChangeListener *dcl, void *cursor);
    /* GL ops follow；virgl 路径用 scanout_texture/scanout_disable/update 三个，
     * 其余保持 NULL 占位。字段顺序必须与 qemu 10.2 include/ui/console.h 的
     * DisplayChangeListenerOps 完全一致。 */
    void (*dpy_gl_scanout_disable)(DisplayChangeListener *dcl);
    void (*dpy_gl_scanout_texture)(DisplayChangeListener *dcl,
                                   uint32_t backing_id, bool backing_y_0_top,
                                   uint32_t backing_width,
                                   uint32_t backing_height,
                                   uint32_t x, uint32_t y,
                                   uint32_t w, uint32_t h,
                                   void *d3d_tex2d);
    bool (*dpy_has_dmabuf)(DisplayChangeListener *dcl);
    void (*dpy_gl_scanout_dmabuf)(DisplayChangeListener *dcl, void *dmabuf);
    void (*dpy_gl_cursor_dmabuf)(DisplayChangeListener *dcl, void *dmabuf,
                                 bool have_hot, uint32_t hot_x, uint32_t hot_y);
    void (*dpy_gl_cursor_position)(DisplayChangeListener *dcl, uint32_t pos_x,
                                   uint32_t pos_y);
    void (*dpy_gl_release_dmabuf)(DisplayChangeListener *dcl, void *dmabuf);
    void (*dpy_gl_update)(DisplayChangeListener *dcl, uint32_t x, uint32_t y,
                          uint32_t w, uint32_t h);
} DisplayChangeListenerOps;

struct DisplayChangeListener {
    uint64_t update_interval;
    const DisplayChangeListenerOps *ops;
    void *ds;          /* DisplayState */
    QemuConsole *con;
    /* QLIST_ENTRY */
    DisplayChangeListener *next;
    DisplayChangeListener **prev;
};

/* ---- DisplayGLCtx（ui/console.h）：virgl 的宿主 GL 上下文工厂 ----
 * guest 的 3D 命令要经它落到宿主 GL。qemu 的 egl-headless 在
 * qemu_display_init 时才挂它，而那时显示设备还没 realize（console 还不存在，
 * 见 system/vl.c：display_init 在 machine_run_board_init/设备初始化之前）——
 * 它的循环直接 break，con->gl 永远为空（实测 console_compatible_with 报
 * "The console requires a GL context"）。故由我们在 console 就绪后自挂一份：
 * ops 全委托 qemu 的 EGL 工厂（符号非 static，可 dlsym）。 */
typedef void *QEMUGLContext;
typedef struct QEMUGLParams {
    int major_ver;
    int minor_ver;
} QEMUGLParams;

typedef struct DisplayGLCtx DisplayGLCtx;
typedef struct DisplayGLCtxOps {
    bool (*dpy_gl_ctx_is_compatible_dcl)(DisplayGLCtx *dgc, DisplayChangeListener *dcl);
    QEMUGLContext (*dpy_gl_ctx_create)(DisplayGLCtx *dgc, QEMUGLParams *params);
    void (*dpy_gl_ctx_destroy)(DisplayGLCtx *dgc, QEMUGLContext ctx);
    int (*dpy_gl_ctx_make_current)(DisplayGLCtx *dgc, QEMUGLContext ctx);
    void (*dpy_gl_ctx_create_texture)(DisplayGLCtx *dgc, DisplaySurface *surface);
    void (*dpy_gl_ctx_destroy_texture)(DisplayGLCtx *dgc, DisplaySurface *surface);
    void (*dpy_gl_ctx_update_texture)(DisplayGLCtx *dgc, DisplaySurface *surface,
                                      int x, int y, int w, int h);
} DisplayGLCtxOps;

struct DisplayGLCtx {
    const DisplayGLCtxOps *ops;
    void *gls; /* CONFIG_OPENGL 变体里的 QemuGLShader*（不使用） */
};

/* ---- input enums (qapi/ui.json) ---- */
#define INPUT_AXIS_X 0
#define INPUT_AXIS_Y 1
#define INPUT_BUTTON_LEFT   0
#define INPUT_BUTTON_MIDDLE 1
#define INPUT_BUTTON_RIGHT  2
#define INPUT_BUTTON_WHEEL_UP   3
#define INPUT_BUTTON_WHEEL_DOWN 4

/* ---- dlsym'd qemu entry points ---- */
typedef int (*qemu_system_entry_fn)(int argc, char **argv);
typedef void (*register_displaychangelistener_fn)(DisplayChangeListener *dcl);
typedef QemuConsole *(*qemu_console_lookup_default_fn)(void);
typedef void (*graphic_hw_update_fn)(QemuConsole *con);
typedef void (*graphic_hw_invalidate_fn)(QemuConsole *con);
typedef void (*qemu_input_event_send_key_qcode_fn)(QemuConsole *src, int q, bool down);
typedef void (*qemu_input_queue_abs_fn)(QemuConsole *src, int axis, int value, int min_in, int max_in);
typedef void (*qemu_input_queue_btn_fn)(QemuConsole *src, int btn, bool down);
typedef void (*qemu_input_event_sync_fn)(void);
typedef bool (*qemu_input_is_absolute_fn)(QemuConsole *con);
typedef void (*bql_lock_impl_fn)(const char *file, int line);
typedef void (*bql_unlock_fn)(void);
typedef DisplaySurface *(*qemu_console_surface_fn)(QemuConsole *con);
typedef void (*console_set_display_gl_ctx_fn)(QemuConsole *con, DisplayGLCtx *gl);
typedef QEMUGLContext (*egl_create_context_fn)(DisplayGLCtx *dgc, QEMUGLParams *params);
typedef void (*egl_destroy_context_fn)(DisplayGLCtx *dgc, QEMUGLContext ctx);
typedef int (*egl_make_context_current_fn)(DisplayGLCtx *dgc, QEMUGLContext ctx);

/* resolved symbols of the currently loaded qemu .so (set by vm.cpp) */
extern qemu_system_entry_fn qe_system_entry;
extern register_displaychangelistener_fn qe_register_dcl;
extern qemu_console_lookup_default_fn qe_console_lookup_default;
extern graphic_hw_update_fn qe_graphic_hw_update;
extern graphic_hw_invalidate_fn qe_graphic_hw_invalidate;
extern qemu_input_event_send_key_qcode_fn qe_input_send_key;
extern qemu_input_queue_abs_fn qe_input_queue_abs;
extern qemu_input_queue_btn_fn qe_input_queue_btn;
extern qemu_input_event_sync_fn qe_input_event_sync;
extern qemu_input_is_absolute_fn qe_input_is_absolute;
extern bql_lock_impl_fn qe_bql_lock;
extern bql_unlock_fn qe_bql_unlock;
extern qemu_console_surface_fn qe_console_surface;
extern console_set_display_gl_ctx_fn qe_set_display_gl_ctx;
/* qemu 的 GL/EGL 全局（vm_start 里把渲染线程已验证的 EGL 对象注入进去，
 * 见 renderer_egl_export；类型用 void* 系避免在此头引入 EGL 头）：
 *  qemu_egl_display 是 EGLDisplay*（指向存储），其余为值槽。 */
extern void **qe_egl_display_p;    /* &qemu_egl_display */
extern void **qe_egl_config_p;     /* &qemu_egl_config */
extern void **qe_egl_rn_ctx_p;     /* &qemu_egl_rn_ctx */
extern int *qe_display_opengl_p;   /* &display_opengl */
extern pixman_image_get_width_fn qe_surface_width;
extern pixman_image_get_height_fn qe_surface_height;
extern pixman_image_get_stride_fn qe_surface_stride;
extern pixman_image_get_data_fn qe_surface_data;
extern pixman_image_get_format_fn qe_surface_format;

#ifdef __cplusplus
}
#endif

#endif /* QEMU_ABI_H */
