#include "fb.h"
#include <hilog/log.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <poll.h>
#include <unistd.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0003
#define LOG_TAG "QemuFB"

Framebuffer g_fb;

/* queue 配置可能被消费者重置（NativeImage 连接建立时实测）：dequeue 拿到的
 * buffer 几何对不上就置位，下一轮重发 SET_BUFFER_GEOMETRY。初始为 true 保证
 * 首帧一定把几何落到 queue 上。 */
static bool s_needSet = true;

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

/* ---- 拷贝线程的 producer buffer 操作（私有，无锁）---- */

/* dequeue 失败限频留证：静默重试会让「dirty 长期挂起」无从归因（实测 hb 里
 * dirty=1 挂 20s+，最后定位是队列耗尽等消费者 release）。 */
static void fb_dequeue_fail_log(const char *where)
{
    static int n = 0;
    if (++n == 1 || n % 60 == 0) {
        OH_LOG_WARN(LOG_APP, "dequeue fail (%{public}s) n=%{public}d", where, n);
    }
}

static bool fb_dequeue_priv()
{
    Framebuffer &f = g_fb;
    int fence = -1;
    if (OH_NativeWindow_NativeWindowRequestBuffer(f.producerWin, &f.wbuf, &fence) != 0 ||
        f.wbuf == nullptr) {
        fb_dequeue_fail_log("request");
        return false;
    }
    /* fence 表示消费者尚在读该 buffer 的上一轮内容。必须等它 signaled 再写：
     * 覆盖写与 GPU 读并发 = 画面更新时的内容错乱/闪烁（实测）。高负载下
     * GPU 读通常微秒级完成，100ms 上限只是异常兜底——超时仍写但留下证据，
     * 否则「等没等到位」无从排查。fence fd 属权在系统。 */
    if (fence >= 0) {
        struct pollfd pfd = {fence, POLLIN, 0};
        int pr = poll(&pfd, 1, 100);
        if (pr <= 0) {
            static int fenceTimeout = 0;
            if (++fenceTimeout == 1 || fenceTimeout % 60 == 0) {
                OH_LOG_WARN(LOG_APP, "fence wait timeout/err: poll=%{public}d n=%{public}d", pr, fenceTimeout);
            }
        }
    }
    OH_NativeBuffer *nb = nullptr;
    if (OH_NativeBuffer_FromNativeWindowBuffer(f.wbuf, &nb) != 0 || nb == nullptr) {
        fb_dequeue_fail_log("frombuf");
        return false;
    }
    OH_NativeBuffer_Config cfg = {};
    OH_NativeBuffer_GetConfig(nb, &cfg);
    bool ok = OH_NativeBuffer_Map(nb, &f.wbufMap) == 0 && f.wbufMap != nullptr;
    if (ok) {
        /* buffer 实际几何必须与待写帧一致：SET_BUFFER_GEOMETRY 由我们异步
         * 落地，落地前 RequestBuffer 仍会拿到旧尺寸 buffer，按新尺寸写就是
         * 越界。不匹配就归还丢帧，并置位 s_needSet 触发下一轮重发 SET。 */
        if (cfg.width != f.w || cfg.height != f.h) {
            ok = false;
            s_needSet = true;
            fb_dequeue_fail_log("geom");
        } else {
            f.wbufStride = cfg.stride;
        }
    }
    if (!ok) {
        /* bufferqueue 没有 cancel：拿到的 buffer 只能 flush 归还。留着不还
         * 会让它游离出队列，耗尽后 RequestBuffer 阻塞。 */
        Region region = {};
        Region::Rect r = {0, 0, (uint32_t)cfg.width, (uint32_t)cfg.height};
        region.rects = &r;
        region.rectNumber = 1;
        OH_NativeWindow_NativeWindowFlushBuffer(f.producerWin, f.wbuf, -1, region);
        f.wbuf = nullptr;
        f.wbufMap = nullptr;
        f.wbufStride = 0;
    }
    /* 注意：FromNativeWindowBuffer 是借用转换、不持引用（官方示例用完即弃、
     * 无 Unreference）。多余的 Unreference 会放掉 buffer 的持有计数，队列
     * 清理时提前销毁+munmap，写 wbufMap 即 UAF（实测 SIGSEGV in memcpy）。 */
    return ok;
}

static void fb_flush_priv()
{
    Framebuffer &f = g_fb;
    if (f.wbuf == nullptr) {
        return;
    }
    Region region = {};
    Region::Rect r = {0, 0, (uint32_t)f.w, (uint32_t)f.h};
    region.rects = &r;
    region.rectNumber = 1;
    OH_NativeWindow_NativeWindowFlushBuffer(f.producerWin, f.wbuf, -1, region);
    f.wbuf = nullptr;
    f.wbufMap = nullptr;
    f.wbufStride = 0;
}

/* pixman surface → producer buffer 的映射内存（x8r8g8b8，即 BGRA 字节序）。
 * must hold BQL（surface 生命周期受其保护）；这是帧路径上唯一一次 CPU 拷贝
 * ——buffer→纹理由 NativeImage 在系统内零拷贝绑定。dst 步进用 buffer 的
 * stride（含对齐，可大于 w*4）。 */
static void fb_convert_to_buffer(pixman_image_t *img, uint8_t *dstBase,
                                 int32_t dstStride, int w, int h)
{
    pixman_format_code_t fmt = qe_surface_format(img);
    int stride = qe_surface_stride(img); /* bytes */
    const uint8_t *srcBase = (const uint8_t *)qe_surface_data(img);
    int bpp = PIXMAN_FORMAT_BPP(fmt);

    for (int row = 0; row < h; row++) {
        uint32_t *dst = (uint32_t *)(dstBase + (size_t)row * dstStride);
        const uint8_t *src = srcBase + (size_t)row * stride;
        if (fmt == PIXMAN_FORMAT_CODE_x8r8g8b8) {
            memcpy(dst, src, (size_t)w * 4);
        } else if (fmt == PIXMAN_FORMAT_CODE_r8g8b8x8) {
            const uint32_t *s = (const uint32_t *)src;
            for (int i = 0; i < w; i++) dst[i] = s[i] >> 8;
        } else if (fmt == PIXMAN_FORMAT_CODE_b8g8r8x8) {
            const uint32_t *s = (const uint32_t *)src;
            for (int i = 0; i < w; i++) {
                uint32_t v = s[i]; /* 0xBBGGRRXX -> 0xFFRRGGBB */
                dst[i] = 0xff000000u | (((v >> 8) & 0xff) << 16) | ((v >> 8) & 0xff00u) | ((v >> 24) & 0xff);
            }
        } else if (fmt == PIXMAN_FORMAT_CODE_r5g6b5 && bpp == 16) {
            const uint16_t *s = (const uint16_t *)src;
            for (int i = 0; i < w; i++) dst[i] = conv_r5g6b5(s[i]);
        } else if (fmt == PIXMAN_FORMAT_CODE_x1r5g5b5 && bpp == 16) {
            const uint16_t *s = (const uint16_t *)src;
            for (int i = 0; i < w; i++) dst[i] = conv_x1r5g5b5(s[i]);
        } else {
            for (int i = 0; i < w; i++) dst[i] = 0xffff00ff; /* unknown: magenta */
        }
    }
}

/* 拷贝线程：唯一读 qemu surface 的地方，且始终持 BQL。
 * 每帧从 con->surface 真值出发（qemu_console_surface），不依赖 gfx_switch
 * 通知的可达性——surface 生命周期全程处于 BQL 保护之下。 */
static void fb_copy_loop()
{
    pthread_setname_np(pthread_self(), "qemu-fbcopy");
    Framebuffer &f = g_fb;
    while (f.copyRunning.load()) {
        bool need = false;
        {
            std::unique_lock<std::mutex> lock(f.mu);
            /* virgl 有效时不接活：帧走 GL 纹理路径、CPU surface 拷贝没有消费者
             * （渲染线程不消费 frameSeq）。判断放谓词里，否则 dirty 恒真会
             * wait 穿透空转；scanout 切回 CPU（scanout_disable）后自愈。 */
            f.cv.wait_for(lock, std::chrono::milliseconds(33), [] {
                return ((g_fb.dirty || g_fb.resized) &&
                        !g_fb.virglValid.load(std::memory_order_acquire)) ||
                       !g_fb.copyRunning.load();
            });
            need = (f.dirty || f.resized) &&
                   !f.virglValid.load(std::memory_order_acquire);
        }
        if (!f.copyRunning.load()) {
            break;
        }
        /* 无脏帧必须空手返回：谓词里的 producerWin!=nullptr 是为了在窗口发布
         * 时唤醒，但它恒真后 wait 穿透——不挡的话空闲时也会全速拷贝+flush
         * （实测 28 帧/s 的无谓 memcpy 与 binder，靠下游握手才没失控）。queue
         * 几何初始化不依赖这里：来帧时 geomChanged(nw != f.w=0) 自己会走 SET。 */
        if (!need || f.producerWin == nullptr) {
            continue;
        }

        {
            /* 低频心跳：画面停滞时区分「guest 没推帧」与「拷贝/消费断了」 */
            static std::chrono::steady_clock::time_point lastHb =
                std::chrono::steady_clock::now();
            auto now = std::chrono::steady_clock::now();
            if (now - lastHb >= std::chrono::seconds(5)) {
                lastHb = now;
                int curW = 0, curH = 0;
                if (qe_console_surface && g_dcl.con) {
                    qe_bql_lock(__FILE__, __LINE__);
                    DisplaySurface *c = qe_console_surface(g_dcl.con);
                    if (c) {
                        curW = qe_surface_width(c->image);
                        curH = qe_surface_height(c->image);
                    }
                    qe_bql_unlock();
                }
                OH_LOG_INFO(LOG_APP, "fbcopy hb: dirty=%{public}d dclUpd=%{public}llu live=%{public}dx%{public}d q=%{public}dx%{public}d frames=%{public}llu",
                            (int)f.dirty,
                            (unsigned long long)f.dclUpdates.load(),
                            curW, curH, f.w, f.h,
                            (unsigned long long)f.frames);
            }
        }

        /* —— BQL 段：取真值 surface 并转换（纯 CPU，无 binder）—— */
        DisplaySurface *cur = nullptr;
        int nw = 0, nh = 0;
        if (qe_console_surface && g_dcl.con) {
            qe_bql_lock(__FILE__, __LINE__);
            cur = qe_console_surface(g_dcl.con);
            if (cur != nullptr) {
                nw = qe_surface_width(cur->image);
                nh = qe_surface_height(cur->image);
            }
            qe_bql_unlock();
        }
        if (cur == nullptr || nw <= 0 || nh <= 0) {
            /* scanout 非 SURFACE（如 console 未激活）：无帧可取 */
            static bool loggedNoSurface = false;
            if (!loggedNoSurface) {
                loggedNoSurface = true;
                OH_LOG_WARN(LOG_APP, "no surface yet: con=%{public}p sym=%{public}p cur=%{public}p",
                            (void *)g_dcl.con, (void *)qe_console_surface, (void *)cur);
            }
            std::lock_guard<std::mutex> lock(f.mu);
            f.dirty = false;
            f.resized = false;
            continue;
        }

        bool geomChanged = s_needSet || nw != f.w || nh != f.h;
        if (geomChanged) {
            /* 几何变化：归还可能持有的旧 buffer，重设生产者几何。Mu 外做 binder
             * ——不与 fb.mu 交织。CPU_READ/WRITE usage 是 Map 可用的前提（文档：
             * FromNativeWindowBuffer 的 CPU 访问要求 usage 带它）。新 buffer 是
             * 空内存，静止画面无脏区会黑屏——invalidate 让 guest 全屏重推一帧。 */
            fb_flush_priv();
            {
                std::lock_guard<std::mutex> lock(f.mu);
                f.w = nw;
                f.h = nh;
                f.resized = true;
            }
            uint64_t usage = NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE;
            OH_NativeWindow_NativeWindowHandleOpt(f.producerWin, SET_BUFFER_GEOMETRY, nw, nh);
            OH_NativeWindow_NativeWindowHandleOpt(f.producerWin, SET_USAGE, usage);
            int fmt = NATIVEBUFFER_PIXEL_FMT_BGRA_8888;
            OH_NativeWindow_NativeWindowHandleOpt(f.producerWin, SET_FORMAT, fmt);
            s_needSet = false;
            if (qe_graphic_hw_invalidate && g_dcl.con) {
                qe_bql_lock(__FILE__, __LINE__);
                qe_graphic_hw_invalidate(g_dcl.con);
                qe_bql_unlock();
            }
            OH_LOG_INFO(LOG_APP, "fb geometry: %{public}dx%{public}d", nw, nh);
        }

        /* 生产不超前消费 1 帧以上：等渲染线程消费掉上一帧（consumedSeq 追上
         * frameSeq）再拷下一帧。队列由此恒定处于「consumer 持 1 + producer
         * 在写 1」之内，不积压——渲染每次 Update 都拿到最新帧（旧帧滞留/
         * 新旧交替闪烁的根源就是超前积压），dequeue 也永远有空闲 buffer。
         * 100ms 超时降级：渲染停摆（窗口隐藏等）时不停产，恢复旧节奏。 */
        {
            std::unique_lock<std::mutex> lock(f.mu);
            f.cv.wait_for(lock, std::chrono::milliseconds(100), [&] {
                return f.frameSeq.load(std::memory_order_acquire) ==
                           f.consumedSeq.load(std::memory_order_acquire) ||
                       !f.copyRunning.load();
            });
            if (!f.copyRunning.load()) {
                break;
            }
        }

        /* —— 零拷贝帧路径 ——
         * dequeue（BQL 外）→ BQL 内 surface 直写 buffer 映射（唯一一次 CPU
         * 拷贝）→ flush（BQL 外）→ 渲染线程 NativeImage 零上传上纹理。
         * buffer 持有跨 BQL 段是安全的：未 flush 的 buffer 不在队列里，
         * consumer 不会碰到；队列深度 3 覆盖 consumer 1 + producer 1 + 空闲。 */
        bool pushed = false;
        if (fb_dequeue_priv()) {
            {
                qe_bql_lock(__FILE__, __LINE__);
                /* 真值可能在 dequeue 期间又变：不一致就放弃本帧（下轮按新
                 * 几何重来），避免把旧 surface 写进新几何的 buffer。 */
                DisplaySurface *now = (qe_console_surface && g_dcl.con)
                                          ? qe_console_surface(g_dcl.con) : cur;
                if (now == cur) {
                    fb_convert_to_buffer(cur->image, (uint8_t *)f.wbufMap,
                                         f.wbufStride, f.w, f.h);
                }
                qe_bql_unlock();
                if (now != cur) {
                    fb_flush_priv();
                    continue;
                }
            }
            fb_flush_priv();
            f.frames++;
            uint64_t seq = f.frameSeq.fetch_add(1, std::memory_order_release) + 1;
            /* 新帧就绪立刻唤醒渲染线程消费：不 notify 的话消费要等它的 33ms
             * 节拍轮询，端到端延迟白添均摊 ~16ms（更新瞬间的滞留感来源之一）。 */
            f.cv.notify_all();
            static bool loggedFirst = false;
            if (!loggedFirst) {
                loggedFirst = true;
                OH_LOG_INFO(LOG_APP, "first frame copied %{public}dx%{public}d", f.w, f.h);
            } else if (seq % 300 == 0) {
                OH_LOG_INFO(LOG_APP, "flushed %{public}llu frames (%{public}dx%{public}d)",
                            (unsigned long long)seq, f.w, f.h);
            }
            pushed = true;
        } else {
            /* 队列满（consumer 尚未 release）或几何未落地：保留 dirty 待重试。
             * 稍等防忙转——consumer 的 release 由渲染恒定节拍的 Update 驱动。 */
            usleep(8 * 1000);
        }

        {
            std::lock_guard<std::mutex> lock(f.mu);
            /* 只有成功入队才清 dirty/resized：失败保留标记，consumer 释放
             * buffer 后下一轮重试——清早了会永久冻结帧流（seq 不动 → 不
             * Update → 不 release → NO_BUFFER 死锁，实测）。 */
            if (pushed) {
                f.dirty = false;
                f.resized = false;
            }
        }
    }
    /* 退出前归还可能持有的 buffer，避免游离 */
    fb_flush_priv();
}

void fb_start_copy_thread()
{
    Framebuffer &f = g_fb;
    if (f.copyRunning.load()) {
        return;
    }
    f.copyRunning.store(true);
    f.copyThread = std::thread(fb_copy_loop);
}

void fb_stop_copy_thread()
{
    Framebuffer &f = g_fb;
    if (!f.copyRunning.exchange(false)) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(f.mu);
        f.cv.notify_all();
    }
    if (f.copyThread.joinable()) {
        f.copyThread.join();
    }
}

/* ---- DCL ops（qemu 线程、BQL 内）：只记账，零 binder、零像素访问 ---- */

static void ohos_gfx_update(DisplayChangeListener *dcl, int x, int y, int w, int h)
{
    std::lock_guard<std::mutex> lock(g_fb.mu);
    (void)x;
    (void)y;
    (void)w;
    (void)h; /* 脏区粒度=全帧：guest 尺寸转换 ~0.3ms，逐 rect 合并由拷贝线程完成 */
    g_fb.dclUpdates.fetch_add(1, std::memory_order_relaxed);
    g_fb.dirty = true;
    g_fb.cv.notify_one();
}

static void ohos_gfx_switch(DisplayChangeListener *dcl, DisplaySurface *new_surface)
{
    std::lock_guard<std::mutex> lock(g_fb.mu);
    g_fb.surface = new_surface;
    /* 只记录；真值与几何由拷贝线程从 con->surface 出发处理 */
    g_fb.dirty = true;
    g_fb.cv.notify_one();
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

/* ---- virgl 路径（virtio-gpu-gl）：DCL GL 回调，BQL 线程、只记账 ----
 * guest 的 3D 帧由 virgl 渲染成 GL 纹理，scanout_texture 把纹理 id 交给我们；
 * 渲染线程用共享 ctx 采样直上屏（无 readback）。ctx 的获取与 dgc 的挂载见
 * renderer.cpp / vm.cpp。 */

static void ohos_gl_scanout_disable(DisplayChangeListener *dcl)
{
    /* 切回 CPU surface / console 释放：渲染线程回到 NativeImage 路径 */
    g_fb.virglValid.store(false, std::memory_order_release);
    g_fb.cv.notify_all();
}

static void ohos_gl_scanout_texture(DisplayChangeListener *dcl,
                                    uint32_t backing_id, bool y0top,
                                    uint32_t bw, uint32_t bh,
                                    uint32_t x, uint32_t y,
                                    uint32_t w, uint32_t h, void *d3d)
{
    g_fb.virglTexId.store(backing_id, std::memory_order_relaxed);
    g_fb.virglW.store(bw, std::memory_order_relaxed);
    g_fb.virglH.store(bh, std::memory_order_relaxed);
    g_fb.virglY0Top.store(y0top, std::memory_order_relaxed);
    g_fb.virglValid.store(true, std::memory_order_release);
    g_fb.dclUpdates.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_fb.mu);
    g_fb.cv.notify_all();
}

static void ohos_gl_update(DisplayChangeListener *dcl, uint32_t x, uint32_t y,
                           uint32_t w, uint32_t h)
{
    /* virgl 帧渲染完成：驱动渲染线程重画（纹理内容已就绪）。不递增 frameSeq
     * ——那是拷贝线程的进度，virgl 帧不走 bufferqueue。 */
    g_fb.dclUpdates.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_fb.mu);
    g_fb.cv.notify_all();
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
    /* GL ops（顺序必须与 qemu 10.2 一致）：virgl 纹理记账 + 帧驱动。
     * 兼容性：console_compatible_with 用**我们自己挂的 dgc** 的
     * is_compatible_dcl（renderer.cpp，恒 true），不受这里的 GL ops 影响。 */
    /* dpy_gl_scanout_disable */ ohos_gl_scanout_disable,
    /* dpy_gl_scanout_texture */ ohos_gl_scanout_texture,
    /* dpy_has_dmabuf */ nullptr,
    /* dpy_gl_scanout_dmabuf */ nullptr,
    /* dpy_gl_cursor_dmabuf */ nullptr,
    /* dpy_gl_cursor_position */ nullptr,
    /* dpy_gl_release_dmabuf */ nullptr,
    /* dpy_gl_update */ ohos_gl_update,
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
    /* producerWin 归 renderer（detach 销毁）；buffer 私有状态随线程退出清理 */
    g_fb.dirty = false;
    g_fb.resized = false;
    g_fb.frameSeq.store(0);
    g_fb.consumedSeq.store(0);
    g_fb.virglTexId.store(0);
    g_fb.virglW.store(0);
    g_fb.virglH.store(0);
    g_fb.virglY0Top.store(false);
    g_fb.virglValid.store(false);
    g_fb.virglShareCtx.store(nullptr); /* qemu 会 dlclose：旧句柄悬垂 */
    s_needSet = true;
    g_fb.cv.notify_all();
}

void fb_crash_dump(char *buf, size_t n)
{
    Framebuffer &f = g_fb;
    snprintf(buf, n,
             "fb-crash: fb=%dx%d wbuf=%d frames=%llu seq=%llu consumed=%llu copy=%d",
             f.w, f.h,
             f.wbufMap != nullptr ? 1 : 0,
             (unsigned long long)f.frames,
             (unsigned long long)f.frameSeq.load(),
             (unsigned long long)f.consumedSeq.load(),
             (int)f.copyRunning.load());
}

/* 截图：直接从 producer bufferqueue 借读（RequestBuffer → Map → 读 → 归还）。
 * 与拷贝线程各自的 wbuf 互不干扰（队列多 buffer）；binder 调用方是 IPC 线程，
 * 不持 fb.mu 做。 */
std::vector<uint32_t> fb_capture_rgba(int maxW, int *outW, int *outH)
{
    int sw, sh;
    OHNativeWindow *win;
    {
        std::lock_guard<std::mutex> lock(g_fb.mu);
        sw = g_fb.w;
        sh = g_fb.h;
        win = g_fb.producerWin;
    }
    if (sw <= 0 || sh <= 0 || win == nullptr) {
        return {};
    }

    int fence = -1;
    OHNativeWindowBuffer *wbuf = nullptr;
    if (OH_NativeWindow_NativeWindowRequestBuffer(win, &wbuf, &fence) != 0 || wbuf == nullptr) {
        return {};
    }
    if (fence >= 0) {
        struct pollfd pfd = {fence, POLLIN, 0};
        poll(&pfd, 1, 100);
    }
    OH_NativeBuffer *nb = nullptr;
    if (OH_NativeBuffer_FromNativeWindowBuffer(wbuf, &nb) != 0 || nb == nullptr) {
        Region region = {};
        Region::Rect r = {0, 0, 1, 1};
        region.rects = &r;
        region.rectNumber = 1;
        OH_NativeWindow_NativeWindowFlushBuffer(win, wbuf, -1, region);
        return {};
    }
    OH_NativeBuffer_Config cfg = {};
    OH_NativeBuffer_GetConfig(nb, &cfg);
    void *map = nullptr;
    bool mapped = OH_NativeBuffer_Map(nb, &map) == 0 && map != nullptr;
    if (!mapped) {
        Region region = {};
        Region::Rect r = {0, 0, (uint32_t)cfg.width, (uint32_t)cfg.height};
        region.rects = &r;
        region.rectNumber = 1;
        OH_NativeWindow_NativeWindowFlushBuffer(win, wbuf, -1, region);
        return {};
    }

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
            uint32_t p = ((const uint32_t *)((const uint8_t *)map + (size_t)sy * cfg.stride))[sx];
            /* buffer 是 x8r8g8b8（BGRA 字节序）；调用方（PixelMap/parcel）要
             * RGBA_8888：换 R/B、A=0xff */
            out[(size_t)y * (size_t)dw + (size_t)x] =
                0xff000000u | (p & 0x0000ff00u) | ((p >> 16) & 0xffu) | ((p & 0xffu) << 16);
        }
    }

    /* 借用转换：不 Unmap/Unreference（见 fb_dequeue_priv 的说明） */
    Region region = {};
    Region::Rect r = {0, 0, (uint32_t)cfg.width, (uint32_t)cfg.height};
    region.rects = &r;
    region.rectNumber = 1;
    OH_NativeWindow_NativeWindowFlushBuffer(win, wbuf, -1, region);
    *outW = dw;
    *outH = dh;
    return out;
}
