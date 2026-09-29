#include "renderer.h"
#include "fb.h"

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <native_image/native_image.h>
#include <native_window/external_window.h>
#include <native_image/graphic_error_code.h>
#include <hilog/log.h>

#include <atomic>
#include <chrono>
#include <thread>
#include <unistd.h>
#include <cstring>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "QemuRender"

namespace {

struct RenderState {
    std::atomic<bool> running{false};
    std::thread thread;
    OHNativeWindow *nativeWin = nullptr; /* XComponent 窗口（EGL surface 的宿主） */
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    EGLConfig config = nullptr;
    int winW = 0, winH = 0;
    std::atomic<bool> surfaceRecreate{false}; /* resize 时重建 EGL surface，跟上 nativeWin 缓冲尺寸 */
    GLuint prog = 0;
    GLuint vbo = 0;
    GLuint tex = 0;                   /* OH_NativeImage 的消费目标纹理 */
    OH_NativeImage *nImage = nullptr; /* bufferqueue 消费者：新 buffer 直接上纹理 */
    EGLContext virglCtx = EGL_NO_CONTEXT; /* virgl 纹理的共享采样 ctx（见 ensureVirglCtx） */
    EGLContext curCtx = EGL_NO_CONTEXT;   /* 当前 current 的 ctx（路径切换簿记） */
    GLuint vboNoFlip = 0;             /* v 不翻转的 quad：virgl y0top 纹理用 */
};

RenderState g_rs;

const char *VERT = R"(#version 300 es
layout(location=0) in vec2 aPos;
layout(location=1) in vec2 aTex;
out vec2 vTex;
void main() {
    gl_Position = vec4(aPos, 0.0, 1.0);
    vTex = aTex;
})";

const char *FRAG = R"(#version 300 es
precision mediump float;
in vec2 vTex;
uniform sampler2D uTex;
out vec4 fragColor;
void main() {
    fragColor = texture(uTex, vTex);
})";

GLuint compileShader(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[512];
        glGetShaderInfoLog(s, sizeof(buf), nullptr, buf);
        OH_LOG_ERROR(LOG_APP, "shader compile failed: %{public}s", buf);
    }
    return s;
}

void setupGl()
{
    GLuint vs = compileShader(GL_VERTEX_SHADER, VERT);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER, FRAG);
    g_rs.prog = glCreateProgram();
    glAttachShader(g_rs.prog, vs);
    glAttachShader(g_rs.prog, fs);
    glLinkProgram(g_rs.prog);
    glDeleteShader(vs);
    glDeleteShader(fs);

    /* fullscreen quad, V flipped: qemu surface row 0 is the top line */
    const float quad[] = {
        // x, y,        u, v
        -1.f, -1.f,    0.f, 1.f,
         1.f, -1.f,    1.f, 1.f,
        -1.f,  1.f,    0.f, 0.f,
         1.f,  1.f,    1.f, 0.f,
    };
    glGenBuffers(1, &g_rs.vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_rs.vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    /* 同 quad 但 v 不翻转：virgl 的 y0top 纹理 row0 是画面底部（GL 惯例），
     * 直接按 GL 方向采样即正立 */
    const float quadNoFlip[] = {
        -1.f, -1.f,    0.f, 0.f,
         1.f, -1.f,    1.f, 0.f,
        -1.f,  1.f,    0.f, 1.f,
         1.f,  1.f,    1.f, 1.f,
    };
    glGenBuffers(1, &g_rs.vboNoFlip);
    glBindBuffer(GL_ARRAY_BUFFER, g_rs.vboNoFlip);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quadNoFlip), quadNoFlip, GL_STATIC_DRAW);

    glGenTextures(1, &g_rs.tex);
    glBindTexture(GL_TEXTURE_2D, g_rs.tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

/* letterbox viewport：等比缩放（取 min 保证两个方向都装得下）+ 居中，比例不一致
 * 的部分留给外层清黑的边。**渲染与输入反查共用这一个源**：drawFrame 用它摆画面，
 * input.cpp 经 renderer_get_viewport 用它把点击坐标反算回 guest 像素。两处各算
 * 一份迟早漂移，症状是「画面在这、点下去却偏了」——viewport 是两边的公共契约。
 * guest 尺寸或窗口尺寸未就绪时返回 false，出参退化为全窗口（w/h 可能为 0）。 */
bool computeViewport(int *x, int *y, int *w, int *h)
{
    int fbW, fbH;
    if (g_fb.virglValid.load(std::memory_order_acquire)) {
        /* virgl 时无 CPU surface 记账（帧走 GL 纹理），尺寸在 virgl 字段 */
        fbW = (int)g_fb.virglW.load(std::memory_order_acquire);
        fbH = (int)g_fb.virglH.load(std::memory_order_acquire);
    } else {
        std::lock_guard<std::mutex> lock(g_fb.mu);
        fbW = g_fb.w;
        fbH = g_fb.h;
    }
    if (fbW <= 0 || fbH <= 0 || g_rs.winW <= 0 || g_rs.winH <= 0) {
        *x = 0;
        *y = 0;
        *w = g_rs.winW;
        *h = g_rs.winH;
        return false;
    }
    float scaleX = (float)g_rs.winW / fbW;
    float scaleY = (float)g_rs.winH / fbH;
    float scale = scaleX < scaleY ? scaleX : scaleY;
    *w = (int)(fbW * scale);
    *h = (int)(fbH * scale);
    *x = (g_rs.winW - *w) / 2;
    *y = (g_rs.winH - *h) / 2;
    return true;
}

/* ctx 切换簿记：路径切换（CPU/virgl）或 surface 重建后重挂。current 是
 * per-thread 状态，只在本渲染线程触碰。 */
bool renderer_make_ctx(bool virgl)
{
    EGLContext target = virgl ? g_rs.virglCtx : g_rs.context;
    if (target == EGL_NO_CONTEXT) {
        return false;
    }
    if (g_rs.curCtx == target) {
        return true;
    }
    if (!eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, target)) {
        OH_LOG_ERROR(LOG_APP, "make ctx(%{public}d) failed: 0x%{public}x", virgl,
                     eglGetError());
        return false;
    }
    g_rs.curCtx = target;
    return true;
}

/* 渲染线程：按需建 virgl 采样 ctx（share = dgc 的 create/make_current 记录的
 * guest ctx 句柄）。跨线程拿句柄建 ctx 是 EGL 规范语义（句柄不绑定线程）；
 * config 用渲染侧自己的——share 只关联纹理/程序等资源，不要求同 config。
 * 失败重试由调用方每帧驱动（EGL/virgl 未就绪时会短暂失败）。 */
bool ensureVirglCtx()
{
    if (g_rs.virglCtx != EGL_NO_CONTEXT) {
        return true;
    }
    EGLContext share =
        (EGLContext)g_fb.virglShareCtx.load(std::memory_order_acquire);
    if (share == EGL_NO_CONTEXT || g_rs.display == EGL_NO_DISPLAY ||
        g_rs.config == nullptr) {
        return false;
    }
    const EGLint es3[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    const EGLint es2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(g_rs.display, g_rs.config, share, es3);
    if (ctx == EGL_NO_CONTEXT) {
        ctx = eglCreateContext(g_rs.display, g_rs.config, share, es2);
    }
    if (ctx == EGL_NO_CONTEXT) {
        static int failed = 0;
        if (++failed == 1 || failed % 60 == 0) {
            OH_LOG_ERROR(LOG_APP, "virgl share ctx create failed: 0x%{public}x",
                         eglGetError());
        }
        return false;
    }
    g_rs.virglCtx = ctx;
    g_rs.curCtx = EGL_NO_CONTEXT; /* 下一帧强制重挂 */
    OH_LOG_INFO(LOG_APP, "virgl share ctx created");
    return true;
}

void drawFrame()
{
    bool virgl = g_fb.virglValid.load(std::memory_order_acquire);
    if (virgl && !ensureVirglCtx()) {
        return; /* 共享 ctx 尚未建好（dgc 记录前）：黑屏等下一帧 */
    }
    if (!renderer_make_ctx(virgl)) {
        return;
    }

    int vpX, vpY, vpW, vpH;
    if (!computeViewport(&vpX, &vpY, &vpW, &vpH)) {
        /* 尺寸还没到（窗口刚建 / guest 尚未出帧）：整屏清黑 */
        glClearColor(0.f, 0.f, 0.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT);
        return;
    }

    glViewport(0, 0, g_rs.winW, g_rs.winH);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glViewport(vpX, vpY, vpW, vpH);
    glUseProgram(g_rs.prog);
    glBindBuffer(GL_ARRAY_BUFFER,
                 virgl && g_fb.virglY0Top.load() ? g_rs.vboNoFlip : g_rs.vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          (void *)(2 * sizeof(float)));
    glBindTexture(GL_TEXTURE_2D,
                  virgl ? (GLuint)g_fb.virglTexId.load() : g_rs.tex);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void renderLoop()
{
    pthread_setname_np(pthread_self(), "qemu-render");
    if (!eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, g_rs.context)) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed: 0x%{public}x", eglGetError());
        return;
    }
    g_rs.curCtx = g_rs.context;

    /* 父进程的 resize 可能早于子进程启动（丢失）：先从 EGL 拿窗口实际尺寸兜底 */
    if (g_rs.winW <= 0 || g_rs.winH <= 0) {
        EGLint w = 0, h = 0;
        eglQuerySurface(g_rs.display, g_rs.surface, EGL_WIDTH, &w);
        eglQuerySurface(g_rs.display, g_rs.surface, EGL_HEIGHT, &h);
        if (w > 0 && h > 0) {
            g_rs.winW = w;
            g_rs.winH = h;
        }
        OH_LOG_INFO(LOG_APP, "window size from EGL: %{public}dx%{public}d", w, h);
    }
    setupGl();

    /* NativeImage：本纹理为消费目标，acquire 的窗口交给拷贝线程当生产者——
     * guest 帧经 bufferqueue 直达纹理（UpdateSurfaceImage 系统内部绑定，
     * 无 CPU→GPU 上传 memcpy）。 */
    g_rs.nImage = OH_NativeImage_Create(g_rs.tex, GL_TEXTURE_2D);
    if (g_rs.nImage == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_NativeImage_Create failed");
    } else {
        OHNativeWindow *win = OH_NativeImage_AcquireNativeWindow(g_rs.nImage);
        if (win == nullptr) {
            OH_LOG_ERROR(LOG_APP, "AcquireNativeWindow failed");
        } else {
            {
                std::lock_guard<std::mutex> lock(g_fb.mu);
                g_fb.producerWin = win;
            }
            fb_start_copy_thread(); /* 生产者就位，拷贝线程开始取帧 */
            OH_LOG_INFO(LOG_APP, "producer window ready (NativeImage)");
        }
    }

    uint64_t consumedSeq = 0;
    std::chrono::steady_clock::time_point lastConsume = std::chrono::steady_clock::now();
    /* 消费端激活：bufferqueue 的 RequestBuffer 需要 consumer 已连接（listener
     * 注册）。第一次 UpdateSurfaceImage 之前生产者 dequeue 会持续失败（实测
     * 鸡生蛋：flush 失败 → seq 不动 → 不 Update → 消费者不激活）。此时队列
     * 为空，Update 返回错误无害，但连接就此建立。 */
    OH_NativeImage_UpdateSurfaceImage(g_rs.nImage);
    int swapRetries = 0;
    while (g_rs.running.load()) {
        if (g_rs.surfaceRecreate.exchange(false)) {
            /* 窗口 resize：重建 EGL surface，让它绑定到 nativeWin 的新缓冲尺寸，
             * 否则 egl 仍停留在旧尺寸，viewport 按 win 计算会把画面放大/错位。
             * 重建会清空显示 buffer——渲染是恒定节拍，本帧立即重画恢复。 */
            eglMakeCurrent(g_rs.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (g_rs.surface != EGL_NO_SURFACE) {
                eglDestroySurface(g_rs.display, g_rs.surface);
            }
            g_rs.surface = eglCreateWindowSurface(g_rs.display, g_rs.config,
                                                  (EGLNativeWindowType)g_rs.nativeWin, nullptr);
            if (g_rs.surface == EGL_NO_SURFACE) {
                OH_LOG_ERROR(LOG_APP, "recreate surface failed: 0x%{public}x", eglGetError());
            } else if (eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, g_rs.context)) {
                g_rs.curCtx = g_rs.context;
                OH_LOG_INFO(LOG_APP, "surface recreated for resize");
            }
        }

        /* 消费：跟随生产（seq 变化才 Update），加短兜底。为什么不能每轮
         * 无条件 Update：静止画面时队列为空，绝大多数调用返回 NO_BUFFER——
         * consumer 侧的 acquire 失败路径会扰动已绑定的纹理状态，表现为画面
         * 来回闪烁（实测）。而完全按 seq 门控又会死锁：consumer 的 buffer
         * release 只发生在下一次 acquire，队列深度只有 2（实测）——consumer
         * 持 1 + 队列积 1 就耗尽，producer 报 NO_BUFFER 重试。兜底周期就是
         * 队列积帧的最长滞留时间：500ms 时实测 dirty 挂起数百 ms（更新瞬间
         * 旧画面滞留），120ms 压住它；再短会回到高频 NO_BUFFER 扰动。 */
        uint64_t seq = g_fb.frameSeq.load(std::memory_order_acquire);
        auto now = std::chrono::steady_clock::now();
        /* virgl 时帧不经 bufferqueue（纹理直采），UpdateSurfaceImage 无意义 */
        bool virgl = g_fb.virglValid.load(std::memory_order_acquire);
        bool needUpdate = !virgl && (seq != consumedSeq ||
                          now - lastConsume >= std::chrono::milliseconds(120));
        if (needUpdate) {
            int32_t ret = OH_NativeImage_UpdateSurfaceImage(g_rs.nImage);
            lastConsume = now;
            if (ret == 0) {
                g_fb.consumedSeq.store(seq, std::memory_order_release);
                g_fb.cv.notify_all();
            } else if (ret != NATIVE_ERROR_NO_BUFFER) {
                static int consumeFailStreak = 0;
                if (++consumeFailStreak == 1 || consumeFailStreak % 60 == 0) {
                    OH_LOG_ERROR(LOG_APP, "UpdateSurfaceImage failed: %{public}d", ret);
                }
            }
            consumedSeq = seq;
        }

        {
            std::unique_lock<std::mutex> lock(g_fb.mu);
            if (g_fb.frameSeq.load(std::memory_order_acquire) == consumedSeq &&
                g_rs.running.load()) {
                /* 无新帧：等 33ms（渲染恒定节拍）。新帧或 shutdown 提前醒。
                 * draw+swap 每循环都做（<1ms）：EGL surface 重建清空显示
                 * buffer、guest 静止无脏帧——靠恒定重画自动收敛，不存在
                 * 「等下一个脏帧才恢复」的黑屏/闪烁窗口。 */
                g_fb.cv.wait_for(lock, std::chrono::milliseconds(33), [&] {
                    return g_fb.frameSeq.load(std::memory_order_acquire) != consumedSeq ||
                           !g_rs.running.load();
                });
            }
        }
        drawFrame();
        if (!eglSwapBuffers(g_rs.display, g_rs.surface)) {
            EGLint err = eglGetError();
            OH_LOG_ERROR(LOG_APP, "eglSwapBuffers failed: 0x%{public}x (retry %{public}d)",
                         err, swapRetries);
            if (err == EGL_BAD_SURFACE && swapRetries < 20) {
                /* 重挂窗后底层 queue 可能尚未就绪：重建 EGLSurface 自愈 */
                swapRetries++;
                eglMakeCurrent(g_rs.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
                eglDestroySurface(g_rs.display, g_rs.surface);
                usleep(100 * 1000);
                g_rs.surface = eglCreateWindowSurface(g_rs.display, g_rs.config,
                                                      (EGLNativeWindowType)g_rs.nativeWin, nullptr);
                if (g_rs.surface == EGL_NO_SURFACE ||
                    !eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, g_rs.context)) {
                    OH_LOG_ERROR(LOG_APP, "recreate surface failed: 0x%{public}x", eglGetError());
                    break;
                }
                g_rs.curCtx = g_rs.context;
                continue;
            }
            break;
        }
        swapRetries = 0;
    }

    eglMakeCurrent(g_rs.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

} // namespace

/* ---- virgl 的宿主 GL 上下文工厂（DisplayGLCtx）----
 * 为什么由我们挂：qemu 的 egl-headless 在 qemu_display_init 时遍历 console
 * 挂 dgc，而 display_init 早于设备初始化（system/vl.c：machine_run_board_init
 * 与 -device 的创建都在其后）——那时 console 还不存在，它的循环直接放弃，
 * con->gl 永远为空。virtio-gpu-gl 的 console 带 GL 标志，我们注册 DCL 时
 * console_compatible_with 就会致命报错（"The console requires a GL context"，
 * 实测）。故在 console 就绪后由本模块自挂一份 dgc，ops 全委托 qemu 的 EGL
 * 工厂（ui/egl-context.c 的非 static 符号，dlsym 取得）。 */

/* 指针日志统一走 snprintf：hilog 的 %p 受隐私过滤，不可靠。 */
static void logPtr(const char *what, const void *a, const void *b)
{
    char s[128];
    snprintf(s, sizeof(s), "%s a=%p b=%p", what, a, b);
    OH_LOG_INFO(LOG_APP, "%{public}s", s);
}

static bool ohos_gl_ctx_is_compatible_dcl(DisplayGLCtx *dgc,
                                          DisplayChangeListener *dcl)
{
    /* 采样与渲染都在本进程内闭环，对 DCL 形状无要求（qemu 的 egl-headless
     * 会限定自家 DCL；我们自己的 DCL 是唯一消费者） */
    logPtr("dgc is_compatible_dcl", dgc, dcl);
    return true;
}

/* dgc 的 EGL 操作全部走渲染线程已验证的这套 EGL 对象（g_rs.display/config/
 * surface/context），不委托 qemu 的 ui/egl-context.c——那里用
 * eglMakeCurrent(EGL_NO_SURFACE) 做 surfaceless 切换，OHOS 的 EGL 实现不支持
 * （egl-headless 初始化即挂，实测：EglWrapperHookLayer init Failed /
 * EGLDislay is invalid，随后整进程在 vCPU 线程里 SIGSEGV pc=0）。共享链：
 * 渲染 root ctx ←(share) guest ctx ←(share) 采样 ctx。 */
bool renderer_egl_export(void **displaySlot, void **config, void **ctx)
{
    if (g_rs.display == EGL_NO_DISPLAY || g_rs.context == EGL_NO_CONTEXT) {
        return false;
    }
    /* 按值写：qemu 的 qemu_egl_display 虽然声明成 EGLDisplay*，但代码里当
     * EGLDisplay 值用（egl-helpers.c: qemu_egl_display = qemu_egl_get_display(...)） */
    *displaySlot = (void *)g_rs.display;
    *config = (void *)g_rs.config;
    *ctx = (void *)g_rs.context;
    return true;
}

bool renderer_egl_make_current_root()
{
    if (g_rs.display == EGL_NO_DISPLAY || g_rs.context == EGL_NO_CONTEXT) {
        return false;
    }
    /* OHOS EGL 不允许跨线程复用渲染线程的 window surface（实测：直接
     * makeCurrent 与新 ctx 配原 surface 都失败），但 surfaceless + 本线程
     * 新建的共享 ctx 可以——这是 qemu 线程能持有 GL 上下文的唯一形态。 */
    if (eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, g_rs.context)) {
        OH_LOG_INFO(LOG_APP, "root ctx current (shared surface+ctx)");
        return true;
    }
    EGLint attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext c = eglCreateContext(g_rs.display, g_rs.config, g_rs.context, attrs);
    if (c != EGL_NO_CONTEXT &&
        eglMakeCurrent(g_rs.display, EGL_NO_SURFACE, EGL_NO_SURFACE, c)) {
        OH_LOG_INFO(LOG_APP, "root ctx current (fresh ctx, surfaceless)");
        return true;
    }
    OH_LOG_ERROR(LOG_APP, "make_current root failed: 0x%{public}x", eglGetError());
    return false;
}

static QEMUGLContext ohos_gl_ctx_create(DisplayGLCtx *dgc, QEMUGLParams *params)
{
    /* virglrenderer 在 create_gl_context 之后立刻在当前线程调 GL（vrend 初始化、
     * 纹理操作），本线程必须先有 current context——qemu 的 egl_create_context
     * 也是这么做的（先 makeCurrent 根上下文再 create）。 */
    if (!eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, g_rs.context)) {
        OH_LOG_ERROR(LOG_APP, "virgl create make_current failed: 0x%{public}x",
                     eglGetError());
    }
    EGLint attrs[] = {EGL_CONTEXT_CLIENT_VERSION,
                      params != nullptr ? params->major_ver : 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(g_rs.display, g_rs.config, g_rs.context, attrs);
    if (ctx != EGL_NO_CONTEXT) {
        g_fb.virglShareCtx.store((void *)ctx, std::memory_order_release);
        OH_LOG_INFO(LOG_APP, "virgl guest ctx created");
    } else {
        OH_LOG_ERROR(LOG_APP, "virgl guest ctx failed: 0x%{public}x", eglGetError());
    }
    return ctx;
}

static void ohos_gl_ctx_destroy(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
    if (ctx != nullptr) {
        eglDestroyContext(g_rs.display, (EGLContext)ctx);
    }
}

static int ohos_gl_ctx_make_current(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
    /* window surface（而非 qemu 的 surfaceless）——OHOS EGL 只支持前者 */
    if (!eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, (EGLContext)ctx)) {
        OH_LOG_ERROR(LOG_APP, "virgl make_current failed: 0x%{public}x", eglGetError());
        return -1;
    }
    if (ctx != nullptr) {
        g_fb.virglShareCtx.store(ctx, std::memory_order_release);
    }
    return 0;
}

static const DisplayGLCtxOps g_glctx_ops = {
    /* dpy_gl_ctx_is_compatible_dcl */ ohos_gl_ctx_is_compatible_dcl,
    /* dpy_gl_ctx_create */ ohos_gl_ctx_create,
    /* dpy_gl_ctx_destroy */ ohos_gl_ctx_destroy,
    /* dpy_gl_ctx_make_current */ ohos_gl_ctx_make_current,
    /* dpy_gl_ctx_create_texture */ nullptr,
    /* dpy_gl_ctx_destroy_texture */ nullptr,
    /* dpy_gl_ctx_update_texture */ nullptr,
};

static DisplayGLCtx g_glctx;

DisplayGLCtx *renderer_gl_ctx()
{
    g_glctx.ops = &g_glctx_ops;
    g_glctx.gls = nullptr;
    return &g_glctx;
}

/* 输入侧入口：与 drawFrame 同一份 viewport（见 computeViewport 的说明），
 * input.cpp 拿它把 surface 坐标反算回 guest 像素坐标。 */
void renderer_get_viewport(int *x, int *y, int *w, int *h)
{
    computeViewport(x, y, w, h);
}

int renderer_attach_window(OHNativeWindow *win)
{
    if (win == nullptr) {
        return -1;
    }
    if (g_rs.running.load()) {
        renderer_detach_window();
    }
    g_rs.nativeWin = win; /* 接管所有权（来自 IPC parcel） */

    /* buffer 几何必须在 createWindowSurface 之前落到 nativeWin 上：surface 一旦
     * 创建，系统就按组件物理尺寸分配了 buffer，之后再 SET 只能靠销毁重建来追。
     * 本页下发的权威尺寸（winW/winH，= guest 分辨率）常在 attach 前到达（那时
     * nativeWin 还不存在，resizeSurface 只能先记账），这里是唯一既持有 nativeWin、
     * 又还没建 surface 的时序点——把 buffer 一步做对，画面天生就在正确几何上。 */
    if (g_rs.winW > 0 && g_rs.winH > 0) {
        OH_NativeWindow_NativeWindowHandleOpt(g_rs.nativeWin, SET_BUFFER_GEOMETRY,
                                              g_rs.winW, g_rs.winH);
    }

    g_rs.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_rs.display == EGL_NO_DISPLAY || !eglInitialize(g_rs.display, nullptr, nullptr)) {
        OH_LOG_ERROR(LOG_APP, "eglInitialize failed");
        return -1;
    }

    const EGLint attribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(g_rs.display, attribs, &config, 1, &numConfigs) || numConfigs < 1) {
        /* retry with ES2 renderable in case ES3 bit is missing */
        const EGLint attribs2[] = {
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_NONE,
        };
        if (!eglChooseConfig(g_rs.display, attribs2, &config, 1, &numConfigs) || numConfigs < 1) {
            OH_LOG_ERROR(LOG_APP, "eglChooseConfig failed");
            return -1;
        }
    }

    g_rs.surface = eglCreateWindowSurface(g_rs.display, config,
                                          (EGLNativeWindowType)g_rs.nativeWin, nullptr);
    if (g_rs.surface == EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "eglCreateWindowSurface failed: 0x%{public}x", eglGetError());
        return -1;
    }
    g_rs.config = config;

    const EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    g_rs.context = eglCreateContext(g_rs.display, config, EGL_NO_CONTEXT, ctxAttribs);
    if (g_rs.context == EGL_NO_CONTEXT) {
        const EGLint ctxAttribs2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
        g_rs.context = eglCreateContext(g_rs.display, config, EGL_NO_CONTEXT, ctxAttribs2);
    }
    if (g_rs.context == EGL_NO_CONTEXT) {
        OH_LOG_ERROR(LOG_APP, "eglCreateContext failed: 0x%{public}x", eglGetError());
        return -1;
    }

    g_rs.running.store(true);
    g_rs.thread = std::thread(renderLoop);
    OH_LOG_INFO(LOG_APP, "renderer started on attached window");
    return 0;
}

int renderer_resize_surface(int32_t w, int32_t h)
{
    g_rs.winW = w;
    g_rs.winH = h;
    /* 主动把 native buffer 物理尺寸设成下发的几何，否则 XComponent buffer 仍停留
     * 在创建时尺寸，renderer 按 win 计算 viewport 会放大/错位；随后重建 EGL
     * surface 应用（渲染恒定节拍会立即重画恢复，无黑屏窗口）。 */
    if (g_rs.nativeWin) {
        OH_NativeWindow_NativeWindowHandleOpt(g_rs.nativeWin, SET_BUFFER_GEOMETRY, w, h);
    }
    g_rs.surfaceRecreate.store(true);
    OH_LOG_INFO(LOG_APP, "surface resize: %{public}dx%{public}d", w, h);
    return 0;
}

int renderer_detach_window()
{
    g_rs.running.store(false);
    if (g_rs.thread.joinable()) {
        g_rs.thread.join();
    }
    fb_stop_copy_thread(); /* 拷贝线程在 producerWin 失效前停 */
    /* 渲染线程已停：断 fb 侧生产者引用并销毁 NativeImage（其内部 buffer 与
     * EGL 资源要在 eglTerminate 之前释放）。 */
    {
        std::lock_guard<std::mutex> lock(g_fb.mu);
        g_fb.producerWin = nullptr;
        g_fb.wbuf = nullptr;
        g_fb.wbufMap = nullptr;
        g_fb.wbufStride = 0;
        g_fb.dirty = false;
        g_fb.resized = false;
    }
    if (g_rs.nImage != nullptr) {
        OH_NativeImage_Destroy(&g_rs.nImage);
        g_rs.nImage = nullptr;
    }
    if (g_rs.display != EGL_NO_DISPLAY) {
        if (g_rs.virglCtx != EGL_NO_CONTEXT) {
            eglDestroyContext(g_rs.display, g_rs.virglCtx);
            g_rs.virglCtx = EGL_NO_CONTEXT;
        }
        g_rs.curCtx = EGL_NO_CONTEXT;
        if (g_rs.surface != EGL_NO_SURFACE) {
            eglDestroySurface(g_rs.display, g_rs.surface);
            g_rs.surface = EGL_NO_SURFACE;
        }
        if (g_rs.context != EGL_NO_CONTEXT) {
            eglDestroyContext(g_rs.display, g_rs.context);
            g_rs.context = EGL_NO_CONTEXT;
        }
        eglTerminate(g_rs.display);
        g_rs.display = EGL_NO_DISPLAY;
    }
    if (g_rs.nativeWin) {
        OH_NativeWindow_DestroyNativeWindow(g_rs.nativeWin);
        g_rs.nativeWin = nullptr;
    }
    return 0;
}
