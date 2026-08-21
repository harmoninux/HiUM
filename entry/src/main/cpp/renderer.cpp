#include "renderer.h"
#include "fb.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <native_window/external_window.h>
#include <hilog/log.h>

#include <atomic>
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
    OHNativeWindow *nativeWin = nullptr;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    EGLConfig config = nullptr;
    int winW = 0, winH = 0;
    GLuint tex = 0;
    GLuint prog = 0;
    GLuint vbo = 0;
    int texW = 0, texH = 0;
    GLint texFormat = GL_BGRA_EXT; /* GL_BGRA_EXT if ext present, else GL_RGBA */
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

    glGenTextures(1, &g_rs.tex);
    glBindTexture(GL_TEXTURE_2D, g_rs.tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

void drawFrame()
{
    int fbW, fbH;
    {
        std::lock_guard<std::mutex> lock(g_fb.mu);
        fbW = g_fb.w;
        fbH = g_fb.h;
    }
    if (fbW <= 0 || fbH <= 0 || g_rs.winW <= 0 || g_rs.winH <= 0) {
        glClearColor(0.f, 0.f, 0.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT);
        return;
    }

    /* letterbox viewport keeping the guest aspect ratio */
    float scaleX = (float)g_rs.winW / fbW;
    float scaleY = (float)g_rs.winH / fbH;
    float scale = scaleX < scaleY ? scaleX : scaleY;
    int vpW = (int)(fbW * scale);
    int vpH = (int)(fbH * scale);
    int vpX = (g_rs.winW - vpW) / 2;
    int vpY = (g_rs.winH - vpH) / 2;

    glViewport(0, 0, g_rs.winW, g_rs.winH);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glViewport(vpX, vpY, vpW, vpH);
    glUseProgram(g_rs.prog);
    glBindBuffer(GL_ARRAY_BUFFER, g_rs.vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          (void *)(2 * sizeof(float)));
    glBindTexture(GL_TEXTURE_2D, g_rs.tex);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void renderLoop()
{
    pthread_setname_np(pthread_self(), "qemu-render");
    if (!eglMakeCurrent(g_rs.display, g_rs.surface, g_rs.surface, g_rs.context)) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed: 0x%{public}x", eglGetError());
        return;
    }

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

    const char *exts = (const char *)glGetString(GL_EXTENSIONS);
    if (exts && strstr(exts, "GL_EXT_texture_format_BGRA8888")) {
        g_rs.texFormat = GL_BGRA_EXT;
    } else {
        g_rs.texFormat = GL_RGBA;
        OH_LOG_WARN(LOG_APP, "no BGRA ext, falling back to RGBA (colors will be off)");
    }
    setupGl();

    int swapRetries = 0;
    while (g_rs.running.load()) {
        bool didWork = false;
        int curFbW = 0, curFbH = 0;
        {
            std::lock_guard<std::mutex> lock(g_fb.mu);
            curFbW = g_fb.w;
            curFbH = g_fb.h;
            if (g_fb.w > 0 && g_fb.h > 0) {
                if (g_fb.resized || g_rs.texW != g_fb.w || g_rs.texH != g_fb.h) {
                    glBindTexture(GL_TEXTURE_2D, g_rs.tex);
                    glTexImage2D(GL_TEXTURE_2D, 0, g_rs.texFormat, g_fb.w, g_fb.h, 0,
                                 g_rs.texFormat, GL_UNSIGNED_BYTE, g_fb.back.data());
                    g_rs.texW = g_fb.w;
                    g_rs.texH = g_fb.h;
                    g_fb.resized = false;
                    g_fb.dirty = false;
                    didWork = true;
                } else if (g_fb.dirty && g_fb.dirtyY1 > g_fb.dirtyY0) {
                    /* upload the dirty band (full width rows) */
                    int y0 = g_fb.dirtyY0, y1 = g_fb.dirtyY1;
                    glBindTexture(GL_TEXTURE_2D, g_rs.tex);
                    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y0, g_fb.w, y1 - y0,
                                    g_rs.texFormat, GL_UNSIGNED_BYTE,
                                    g_fb.back.data() + (size_t)y0 * g_fb.w);
                    g_fb.dirty = false;
                    didWork = true;
                }
            }
        }
        if (didWork) {
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
                    continue;
                }
                break;
            }
            swapRetries = 0;
            static bool loggedFirstFrame = false;
            if (!loggedFirstFrame) {
                OH_LOG_INFO(LOG_APP, "first frame presented, fb=%{public}dx%{public}d win=%{public}dx%{public}d",
                            curFbW, curFbH, g_rs.winW, g_rs.winH);
                loggedFirstFrame = true;
            }
        } else {
            usleep(8000); /* nothing new: ~120Hz poll */
        }
    }

    eglMakeCurrent(g_rs.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

} // namespace

void renderer_get_viewport(int *x, int *y, int *w, int *h)
{
    int fbW, fbH;
    {
        std::lock_guard<std::mutex> lock(g_fb.mu);
        fbW = g_fb.w;
        fbH = g_fb.h;
    }
    if (fbW <= 0 || fbH <= 0 || g_rs.winW <= 0 || g_rs.winH <= 0) {
        *x = *y = 0;
        *w = g_rs.winW;
        *h = g_rs.winH;
        return;
    }
    float scaleX = (float)g_rs.winW / fbW;
    float scaleY = (float)g_rs.winH / fbH;
    float scale = scaleX < scaleY ? scaleX : scaleY;
    *w = (int)(fbW * scale);
    *h = (int)(fbH * scale);
    *x = (g_rs.winW - *w) / 2;
    *y = (g_rs.winH - *h) / 2;
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

    /* 新 surface（重建的 EGL 纹理是空的）：强制首轮全量回传 back buffer，
     * 否则 guest 无脏帧时（如停在 login）重新进入 Console 会一直黑屏 */
    g_rs.texW = 0;
    g_rs.texH = 0;

    g_rs.running.store(true);
    g_rs.thread = std::thread(renderLoop);
    OH_LOG_INFO(LOG_APP, "renderer started on attached window");
    return 0;
}

int renderer_resize_surface(int32_t w, int32_t h)
{
    g_rs.winW = w;
    g_rs.winH = h;
    OH_LOG_INFO(LOG_APP, "surface resize: %{public}dx%{public}d", w, h);
    return 0;
}

int renderer_detach_window()
{
    g_rs.running.store(false);
    if (g_rs.thread.joinable()) {
        g_rs.thread.join();
    }
    if (g_rs.display != EGL_NO_DISPLAY) {
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
