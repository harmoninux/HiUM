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

/* ---- DisplaySurface (ui/surface.h, CONFIG_OPENGL disabled) ---- */
typedef struct DisplaySurface {
    pixman_image_t *image;
    uint8_t flags;
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
    /* GL ops follow; unused, keep NULL placeholders to preserve layout */
    void *dpy_gl_scanout_disable;
    void *dpy_gl_scanout_texture;
    void *dpy_has_dmabuf;
    void *dpy_gl_scanout_dmabuf;
    void *dpy_gl_cursor_dmabuf;
    void *dpy_gl_cursor_position;
    void *dpy_gl_release_dmabuf;
    void *dpy_gl_update;
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
typedef void (*qemu_input_event_send_key_qcode_fn)(QemuConsole *src, int q, bool down);
typedef void (*qemu_input_queue_abs_fn)(QemuConsole *src, int axis, int value, int min_in, int max_in);
typedef void (*qemu_input_queue_btn_fn)(QemuConsole *src, int btn, bool down);
typedef void (*qemu_input_event_sync_fn)(void);
typedef bool (*qemu_input_is_absolute_fn)(QemuConsole *con);
typedef int (*qemu_input_scale_axis_fn)(int value, int min_in, int max_in, int min_out, int max_out);

/* resolved symbols of the currently loaded qemu .so (set by vm.cpp) */
extern qemu_system_entry_fn qe_system_entry;
extern register_displaychangelistener_fn qe_register_dcl;
extern qemu_console_lookup_default_fn qe_console_lookup_default;
extern graphic_hw_update_fn qe_graphic_hw_update;
extern qemu_input_event_send_key_qcode_fn qe_input_send_key;
extern qemu_input_queue_abs_fn qe_input_queue_abs;
extern qemu_input_queue_btn_fn qe_input_queue_btn;
extern qemu_input_event_sync_fn qe_input_event_sync;
extern qemu_input_is_absolute_fn qe_input_is_absolute;
extern qemu_input_scale_axis_fn qe_input_scale_axis;
extern pixman_image_get_width_fn qe_surface_width;
extern pixman_image_get_height_fn qe_surface_height;
extern pixman_image_get_stride_fn qe_surface_stride;
extern pixman_image_get_data_fn qe_surface_data;
extern pixman_image_get_format_fn qe_surface_format;

#ifdef __cplusplus
}
#endif

#endif /* QEMU_ABI_H */
