// 帧管线：qemu DCL 回调（qemu BQL 线程）→ 拷贝线程（持 BQL）→ NativeImage
// 生产者 bufferqueue → 渲染线程（GL 消费）。
//
// 职责分层（见 docs/DESIGN.md 渲染链路一节）：
//  * DCL 回调只记账（surface 指针/尺寸/dirty 标志），µs 级返回——BQL 内
//    绝不做 binder 或像素访问，guest 速度不受显示影响。
//  * 拷贝线程是唯一读 qemu surface 的地方，且始终持 BQL：每次拷贝前用
//    qemu_console_surface(con) 取真值——surface 生命周期完全处于 BQL
//    保护下，不存在「读到已释放 data」的窗口。
//  * producer buffer（NativeImage 的 bufferqueue）归拷贝线程私有：BQL 外
//    自由 RequestBuffer/FlushBuffer，不与任何锁交织。
//  * 渲染线程只消费（UpdateSurfaceImage + draw），与 fb 状态仅通过原子
//    帧序号耦合，不持 fb.mu 做任何 binder。
#ifndef FB_H
#define FB_H

#include "qemu_abi.h"
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <thread>
#include <vector>

struct Framebuffer {
    std::mutex mu;
    std::condition_variable cv;
    /* —— DCL 回调（BQL）写，拷贝线程持 mu 快照 —— */
    DisplaySurface *surface = nullptr; // 最近一次 gfx_switch 的 surface（变化检测用；
                                       // 像素访问永远走 qe_console_surface 真值）
    int w = 0, h = 0;                  // 最近 switch 的 guest 尺寸
    bool dirty = false;                // 有未拷贝的脏区（粒度=全帧）
    bool resized = false;              // guest 分辨率变化，拷贝线程需重设生产者几何
    /* —— 拷贝线程私有（无锁）—— */
    OHNativeWindow *producerWin = nullptr; // 渲染线程创建（NativeImage acquire），
                                           // 拷贝线程只读引用；生命周期归 renderer
    OHNativeWindowBuffer *wbuf = nullptr;
    void *wbufMap = nullptr;
    int32_t wbufStride = 0;
    /* —— 拷贝线程 ⇄ 渲染线程的帧握手 —— */
    std::atomic<uint64_t> frameSeq{0};    // 每成功 flush 一帧 +1（生产进度）
    std::atomic<uint64_t> consumedSeq{0}; // 渲染线程已消费到的帧（消费进度）。
                                          // 拷贝线程 flush 下一帧前等它追上
                                          // frameSeq：生产不超前消费 1 帧以上，
                                          // 队列不积压，渲染永远拿最新帧
    std::atomic<uint64_t> dclUpdates{0}; // DCL update 回调计数（qemu 推帧观测）
    /* —— virgl 路径（virtio-gpu-gl 的 scanout_texture 记账，BQL 线程写）——
     * 帧不经 bufferqueue：virgl 把 guest GL 渲染的内部纹理 id 交给我们，
     * 渲染线程用共享 context（renderer 的 dgc 在 create/make_current 时记录
     * 的句柄）采样上屏。撕裂说明：纹理单缓冲，guest 下一帧写入与我们的
     * 读取可能并发；刷新率同量级时冲突窗口小，实测有问题再加 fence。 */
    std::atomic<uint32_t> virglTexId{0};
    std::atomic<uint32_t> virglW{0};
    std::atomic<uint32_t> virglH{0};
    std::atomic<bool> virglY0Top{false};  // 纹理 row0 是否为画面底部（GL 惯例）
    std::atomic<bool> virglValid{false};  // 当前 scanout 是 GL 纹理（非 CPU surface）
    std::atomic<void *> virglShareCtx{nullptr}; // virgl guest ctx 句柄（dgc 记录）
    std::atomic<bool> copyRunning{false};
    std::thread copyThread;
    /* —— 诊断：crash handler 脏读（见 fb_crash_dump）—— */
    uint64_t frames = 0;               // 完成帧计数
};

extern Framebuffer g_fb;

/* qemu DCL ops implementation (called from qemu threads, inside BQL) */
extern DisplayChangeListener g_dcl;

/* clear all qemu-bound state after a VM run ends: g_dcl keeps dangling
 * pointers (ds/con) into the qemu .so otherwise, and re-registering with a
 * stale ds trips qemu's assert(!dcl->ds). safe to call anytime. */
void fb_reset();

/* 拷贝线程生命周期：renderer attach（producerWin 发布）后启动、detach 前停止。 */
void fb_start_copy_thread();
void fb_stop_copy_thread();

/* crash handler 专用：不持锁脏读崩溃现场的关键几何（崩溃线程可能正持锁）。 */
void fb_crash_dump(char *buf, size_t n);

/* 当前帧转 RGBA_8888（含最近邻缩放到 ≤maxW 宽，maxW<=0 不缩放）。
 * 从 producer bufferqueue 借读，无帧时返回空 vector。 */
std::vector<uint32_t> fb_capture_rgba(int maxW, int *outW, int *outH);

#endif /* FB_H */
