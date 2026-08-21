#include "fb.h"
#include <hilog/log.h>
#include <cstring>
#include <climits>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0003
#define LOG_TAG "QemuFB"

Framebuffer g_fb;

static inline uint32_t conv_r5g6b5(uint16_t v)
{
    uint32_t r = (v >> 11) & 0x1f, g = (v >> 5) & 0x3f, b = v & 0x1f;
    return 0xff000000u | ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2));
}

static inline uint32_t conv_x1r5g5b5(uint16_t v)
{
    uint32_t r = (v >> 10) & 0x1f, g = (v >> 5) & 0x1f, b = v & 0x1f;
    return 0xff000000u | ((r << 3) | (r >> 2)) << 16 | ((g << 3) | (g >> 2)) << 8 | ((b << 3) | (b >> 2));
}

/* g_fb.mu must be held by caller */
void fb_update_rect(int x, int y, int w, int h)
{
    Framebuffer &f = g_fb;
    if (!f.surface || f.w <= 0 || f.h <= 0) {
        return;
    }
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + w > f.w) w = f.w - x;
    if (y + h > f.h) h = f.h - y;
    if (w <= 0 || h <= 0) {
        return;
    }

    pixman_format_code_t fmt = qe_surface_format(f.surface->image);
    int bpp = PIXMAN_FORMAT_BPP(fmt);
    int stride = qe_surface_stride(f.surface->image); /* bytes */
    const uint8_t *srcBase = (const uint8_t *)qe_surface_data(f.surface->image);

    for (int row = y; row < y + h; row++) {
        uint32_t *dst = &f.back[(size_t)row * f.w + x];
        const uint8_t *src = srcBase + (size_t)row * stride;
        if (fmt == PIXMAN_FORMAT_CODE_x8r8g8b8) {
            memcpy(dst, src + (size_t)x * 4, (size_t)w * 4);
        } else if (fmt == PIXMAN_FORMAT_CODE_r8g8b8x8) {
            const uint32_t *s = (const uint32_t *)(src + (size_t)x * 4);
            for (int i = 0; i < w; i++) dst[i] = s[i] >> 8;
        } else if (fmt == PIXMAN_FORMAT_CODE_b8g8r8x8) {
            const uint32_t *s = (const uint32_t *)(src + (size_t)x * 4);
            for (int i = 0; i < w; i++) {
                uint32_t v = s[i]; /* 0xBBGGRRXX -> 0xFFRRGGBB */
                dst[i] = 0xff000000u | (((v >> 8) & 0xff) << 16) | ((v >> 8) & 0xff00u) | ((v >> 24) & 0xff);
            }
        } else if (fmt == PIXMAN_FORMAT_CODE_r5g6b5 && bpp == 16) {
            const uint16_t *s = (const uint16_t *)(src + (size_t)x * 2);
            for (int i = 0; i < w; i++) dst[i] = conv_r5g6b5(s[i]);
        } else if (fmt == PIXMAN_FORMAT_CODE_x1r5g5b5 && bpp == 16) {
            const uint16_t *s = (const uint16_t *)(src + (size_t)x * 2);
            for (int i = 0; i < w; i++) dst[i] = conv_x1r5g5b5(s[i]);
        } else {
            /* unknown format: paint magenta once, log */
            for (int i = 0; i < w; i++) dst[i] = 0xffff00ff;
        }
    }

    if (!f.dirty) {
        f.dirtyY0 = y;
        f.dirtyY1 = y + h;
    } else {
        if (y < f.dirtyY0) f.dirtyY0 = y;
        if (y + h > f.dirtyY1) f.dirtyY1 = y + h;
    }
    f.dirty = true;
    f.frames++;
}

static void ohos_gfx_update(DisplayChangeListener *dcl, int x, int y, int w, int h)
{
    std::lock_guard<std::mutex> lock(g_fb.mu);
    fb_update_rect(x, y, w, h);
    g_fb.cv.notify_one(); /* 唤醒渲染线程立即上传新帧 */
}

static void ohos_gfx_switch(DisplayChangeListener *dcl, DisplaySurface *new_surface)
{
    std::lock_guard<std::mutex> lock(g_fb.mu);
    g_fb.surface = new_surface;
    int w = qe_surface_width(new_surface->image);
    int h = qe_surface_height(new_surface->image);
    pixman_format_code_t fmt = qe_surface_format(new_surface->image);
    OH_LOG_INFO(LOG_APP, "gfx_switch: %{public}dx%{public}d fmt=0x%{public}x stride=%{public}d",
                w, h, (unsigned)fmt, qe_surface_stride(new_surface->image));
    if (w != g_fb.w || h != g_fb.h) {
        g_fb.w = w;
        g_fb.h = h;
        g_fb.back.resize((size_t)w * h, 0xff000000u);
        g_fb.resized = true;
    }
    g_fb.dirty = true;
    g_fb.dirtyY0 = 0;
    g_fb.dirtyY1 = h;
    g_fb.cv.notify_one(); /* 分辨率切换醒渲染线程做全量重传 */
}

static bool ohos_gfx_check_format(DisplayChangeListener *dcl, pixman_format_code_t format)
{
    switch (format) {
    case PIXMAN_FORMAT_CODE_x8r8g8b8:
    case PIXMAN_FORMAT_CODE_r8g8b8x8:
    case PIXMAN_FORMAT_CODE_b8g8r8x8:
    case PIXMAN_FORMAT_CODE_r5g6b5:
    case PIXMAN_FORMAT_CODE_x1r5g5b5:
        return true;
    default:
        return false;
    }
}

static void ohos_refresh(DisplayChangeListener *dcl)
{
    /* pull model like vnc_refresh: ask the device to redraw, which ends up
     * calling our gfx_update for changed regions */
    if (dcl->con && qe_graphic_hw_update) {
        qe_graphic_hw_update(dcl->con);
    }
}

static const DisplayChangeListenerOps g_dcl_ops = {
    /* dpy_name */ "ohos-direct",
    /* dpy_refresh */ ohos_refresh,
    /* dpy_gfx_update */ ohos_gfx_update,
    /* dpy_gfx_switch */ ohos_gfx_switch,
    /* dpy_gfx_check_format */ ohos_gfx_check_format,
    /* dpy_text_cursor */ nullptr,
    /* dpy_text_resize */ nullptr,
    /* dpy_text_update */ nullptr,
    /* dpy_mouse_set */ nullptr,
    /* dpy_cursor_define */ nullptr,
    /* GL ops */ nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
};

DisplayChangeListener g_dcl = {
    /* update_interval (ms) */ 30,
    /* ops */ &g_dcl_ops,
    /* ds */ nullptr,
    /* con */ nullptr,
    /* next, prev */ nullptr, nullptr,
};

void fb_reset()
{
    std::lock_guard<std::mutex> lock(g_fb.mu);
    g_dcl.ds = nullptr;
    g_dcl.con = nullptr;
    g_dcl.next = nullptr;
    g_dcl.prev = nullptr;
    g_fb.surface = nullptr;
    g_fb.w = 0;
    g_fb.h = 0;
    g_fb.back.clear();
    g_fb.dirty = false;
    g_fb.resized = false;
    g_fb.cv.notify_one(); /* 唤醒渲染线程以观察清空后的状态（VM 结束） */
}

std::vector<uint32_t> fb_capture_rgba(int maxW, int *outW, int *outH)
{
    std::lock_guard<std::mutex> lock(g_fb.mu);
    if (g_fb.w <= 0 || g_fb.h <= 0 || g_fb.back.empty()) {
        return {};
    }
    int sw = g_fb.w, sh = g_fb.h;
    int dw = sw, dh = sh;
    if (maxW > 0 && sw > maxW) {
        dw = maxW;
        dh = (int)((int64_t)sh * maxW / sw);
    }
    std::vector<uint32_t> out((size_t)dw * (size_t)dh);
    for (int y = 0; y < dh; y++) {
        int sy = (int)((int64_t)y * sh / dh);
        for (int x = 0; x < dw; x++) {
            int sx = (int)((int64_t)x * sw / dw);
            uint32_t p = g_fb.back[(size_t)sy * (size_t)sw + (size_t)sx];
            /* back 是 X8R8G8B8；调用方（PixelMap/parcel）要 RGBA_8888：换 R/B、A=0xff */
            out[(size_t)y * (size_t)dw + (size_t)x] =
                0xff000000u | (p & 0x0000ff00u) | ((p >> 16) & 0xffu) | ((p & 0xffu) << 16);
        }
    }
    *outW = dw;
    *outH = dh;
    return out;
}
