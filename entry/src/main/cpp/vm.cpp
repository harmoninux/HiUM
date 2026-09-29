#include "vm.h"
#include "qemu_abi.h"
#include "fb.h"
#include "renderer.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <pthread.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <execinfo.h>
#include <fstream>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <thread>
#include <time.h>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0005
#define LOG_TAG "QemuVM"

qemu_system_entry_fn qe_system_entry;
register_displaychangelistener_fn qe_register_dcl;
qemu_console_lookup_default_fn qe_console_lookup_default;
graphic_hw_update_fn qe_graphic_hw_update;
graphic_hw_invalidate_fn qe_graphic_hw_invalidate;
qemu_input_event_send_key_qcode_fn qe_input_send_key;
qemu_input_queue_abs_fn qe_input_queue_abs;
qemu_input_queue_btn_fn qe_input_queue_btn;
qemu_input_event_sync_fn qe_input_event_sync;
qemu_input_is_absolute_fn qe_input_is_absolute;
bql_lock_impl_fn qe_bql_lock;
bql_unlock_fn qe_bql_unlock;
qemu_console_surface_fn qe_console_surface;
console_set_display_gl_ctx_fn qe_set_display_gl_ctx;
void **qe_egl_display_p;
void **qe_egl_config_p;
void **qe_egl_rn_ctx_p;
int *qe_display_opengl_p;
pixman_image_get_width_fn qe_surface_width;
pixman_image_get_height_fn qe_surface_height;
pixman_image_get_stride_fn qe_surface_stride;
pixman_image_get_data_fn qe_surface_data;
pixman_image_get_format_fn qe_surface_format;

/* console the DCL is bound to; used by input injection */
QemuConsole *g_qemu_con;

namespace {
struct VmState {
    std::atomic<bool> running{false};
    void *so = nullptr;
    std::thread vmThread;
    std::thread bindThread;
    std::vector<std::string> argStrings;
    std::vector<char *> argPtrs;
};
VmState g_vm;

/* qemu stderr 的镜像文件路径（qemu-<vmId>.log）。正常退出路径在 vmMain 尾部
 * 读回抬 hilog；崩溃时 qe_system_entry 不返回、那段不执行，crashSigHandler
 * 里补一次读回（见下），否则 abort 前的最后文本只能躺在沙箱文件里，hdc
 * shell 无权读。 */
std::string g_qemuLogPath;

/* qemu 把 run-once 状态放在自身 .so 的静态区（vm_config_groups、DCL 链表
 * ……），同一份映射无法二次进入（qemu_add_opts 重复注册会 abort）；
 * dlclose 重载也不行：本线程持有 qemu 注册的 TLS 析构，卸载后线程退出会
 * 跳到已卸载代码（实测必崩）。因此本文件只支持一进程一轮 VM——本工程里
 * 本代码运行在 NCP 子进程（libqemu_child.so）中，一轮 VM 一个子进程，
 * 退出后由父进程另起新子进程。 */

template <typename T>
bool resolveSym(void *so, const char *name, T *out)
{
    *out = (T)dlsym(so, name);
    if (!*out) {
        OH_LOG_ERROR(LOG_APP, "dlsym %{public}s failed: %{public}s", name, dlerror());
        return false;
    }
    return true;
}

void installCrashHandlers(); /* 定义在文件尾（匿名命名空间内），此处前置声明供 vmMain 用 */
void relayQemuLogThread(const std::string &logPath, std::atomic<bool> *stop);
void logFloodWatchdogThread(const std::string &logPath, std::atomic<bool> *stop);

void vmMain(VmState *vm)
{
    pthread_setname_np(pthread_self(), "qemu-main");
    /* qemu 自己的错误走 stdout/stderr：重定向到 <vmDataDir>/qemu-<vmId>.log 以便诊断。
     * 文件名带 vmId（从 -qmp unix:.../qmp-<id>.sock 反解——vmId 本身不传给子进程），
     * 多实例并跑时各子进程写各自文件、互不 O_TRUNC 覆盖/写交错，与 qmp-<id>.sock /
     * serial-<id>.log 命名对齐；解析不到 id 时回退全局 qemu.log。 */
    std::string dataDir;
    std::string vmId;
    for (size_t i = 0; i + 1 < vm->argStrings.size(); i++) {
        if (vm->argStrings[i] == "-L" && dataDir.empty()) {
            dataDir = vm->argStrings[i + 1];
        }
        if (vm->argStrings[i] == "-qmp") {
            const std::string &v = vm->argStrings[i + 1];
            auto s = v.find("qmp-");
            if (s != std::string::npos) {
                auto e = v.find(".sock", s);
                if (e != std::string::npos) {
                    vmId = v.substr(s + 4, e - s - 4);
                }
            }
        }
    }
    if (!dataDir.empty()) {
        std::string log = vmId.empty() ? dataDir + "/qemu.log" : dataDir + "/qemu-" + vmId + ".log";
        int fd = open(log.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            if (fd > STDERR_FILENO) {
                close(fd);
            }
        }
    }
    /* logPath 供日志转发线程 + 退出时镜像读取 */
    std::string logPath = dataDir.empty() ? std::string() :
        (vmId.empty() ? dataDir + "/qemu.log" : dataDir + "/qemu-" + vmId + ".log");
    g_qemuLogPath = logPath; /* 崩溃 handler 用（qe_system_entry 不返回时兜底读回） */
    installCrashHandlers();
    std::atomic<bool> stopRelay{false};
    std::thread relay;
    std::thread floodWd;
    if (!logPath.empty()) {
        relay = std::thread(relayQemuLogThread, logPath, &stopRelay);
        floodWd = std::thread(logFloodWatchdogThread, logPath, &stopRelay);
    }
    /* EGL 注入：qemu 的 GL 全局指向渲染线程已建好的 EGL 对象。qemu 自带的
     * egl-headless 在 OHOS 上初始化即崩（surfaceless makeCurrent 不被支持：
     * 实测 EglWrapperHookLayer init Failed / EGLDislay is invalid，随后 vCPU
     * 线程在该状态上 SIGSEGV pc=0），故命令行不再带 -display egl-headless；
     * display_opengl 由这里置位让 virtio-gpu-gl 通过「display 支持 GL」检查，
     * GL 上下文全部由我们的 dgc（renderer_gl_ctx）提供。 */
    {
        void *dpySlot = nullptr;
        void *cfg = nullptr;
        void *rootCtx = nullptr;
        bool ok = renderer_egl_export(&dpySlot, &cfg, &rootCtx);
        for (int i = 0; !ok && i < 50; i++) {
            usleep(100 * 1000); /* renderer 在 IPC 线程建 EGL，等它就绪（≤5s） */
            ok = renderer_egl_export(&dpySlot, &cfg, &rootCtx);
        }
        if (ok) {
            if (qe_egl_display_p != nullptr) {
                *qe_egl_display_p = dpySlot;
            }
            if (qe_egl_config_p != nullptr) {
                *qe_egl_config_p = cfg;
            }
            if (qe_egl_rn_ctx_p != nullptr) {
                *qe_egl_rn_ctx_p = rootCtx;
            }
            if (qe_display_opengl_p != nullptr) {
                *qe_display_opengl_p = 1;
            }
            /* 本线程即将跑 qemu_init（virtio-gpu-gl 的 realize 在其中）：
             * virglrenderer 会在创建 context 前先做 GL 能力探测，此线程必须
             * 已经持有 current context。 */
            if (renderer_egl_make_current_root()) {
                OH_LOG_INFO(LOG_APP, "egl globals injected, root ctx current");
            } else {
                OH_LOG_INFO(LOG_APP, "egl globals injected, make_current failed");
            }
        } else {
            OH_LOG_ERROR(LOG_APP, "renderer egl not ready; virtio-gl will fail");
        }
    }
    int argc = (int)vm->argPtrs.size();
    OH_LOG_INFO(LOG_APP, "qemu_system_entry start, argc=%{public}d", argc);
    int ret = qe_system_entry(argc, vm->argPtrs.data());
    OH_LOG_INFO(LOG_APP, "qemu_system_entry exited, ret=%{public}d", ret);
    vm->running.store(false);
    stopRelay.store(true);
    if (relay.joinable()) {
        relay.join();
    }
    if (floodWd.joinable()) {
        floodWd.join();
    }

    /* 读回 qemu 日志尾部，抬到 hilog：qemu 的 stderr（fatal error/无法打开镜像等）
     * 已被上面 dup2 重定向到 qemu-<vmId>.log（app 沙箱内，hdc shell 读不到），
     * 这里补一条让崩溃原因直接进 hilog，供真机诊断。 */
    std::ifstream flog(logPath);
    if (flog.is_open()) {
        std::string line;
        std::vector<std::string> lines;
        while (std::getline(flog, line)) {
            if (!line.empty()) { lines.push_back(line); }
        }
        flog.close();
        size_t start = lines.size() > 40 ? lines.size() - 40 : 0;
        for (size_t i = start; i < lines.size(); i++) {
            OH_LOG_ERROR(LOG_APP, "qemu-log[%{public}zu]: %{public}s", i, lines[i].c_str());
        }
        if (lines.empty()) {
            OH_LOG_WARN(LOG_APP, "qemu log is empty (no stderr captured)");
        }
    } else {
        OH_LOG_WARN(LOG_APP, "cannot open qemu log %{public}s", logPath.c_str());
    }

    /* cleanup: drop our pointers into the qemu .so, then stop the bind
     * thread (it polls qemu symbols). no dlclose — TLS 析构会跳到已卸载
     * 代码；子进程随后整体退出，由父进程另起新子进程跑下一轮。 */
    fb_reset();
    g_qemu_con = nullptr;
    if (vm->bindThread.joinable()) {
        vm->bindThread.join();
    }
    vm->so = nullptr;
}

void bindDisplay(VmState *vm)
{
    pthread_setname_np(pthread_self(), "qemu-dcl-bind");
    /* wait until the machine has created its graphic console */
    for (int i = 0; i < 600 && vm->running.load(); i++) { /* up to 60s */
        QemuConsole *con = qe_console_lookup_default();
        if (con) {
            /* 先挂 GL 上下文工厂：virtio-gpu-gl 的 console 带 GL 标志，注册
             * DCL 时的 console_compatible_with 要求 con->gl 非空——qemu 的
             * egl-headless 因时序（display_init 早于设备初始化）挂不上，
             * 由我们补挂（见 renderer.h / renderer_gl_ctx）。非 GL 设备无害。 */
            if (qe_set_display_gl_ctx != nullptr) {
                DisplayGLCtx *dgc = renderer_gl_ctx();
                qe_set_display_gl_ctx(con, dgc);
                char loc[128];
                snprintf(loc, sizeof(loc), "gl ctx bound: con=%p dgc=%p ops=%p",
                         (void *)con, (void *)dgc, (const void *)dgc->ops);
                OH_LOG_INFO(LOG_APP, "%{public}s", loc);
            }
            g_dcl.con = con;
            qe_register_dcl(&g_dcl);
            g_qemu_con = con;
            OH_LOG_INFO(LOG_APP, "display listener registered after %{public}d ms", i * 100);
            return;
        }
        usleep(100 * 1000);
    }
    OH_LOG_ERROR(LOG_APP, "timed out waiting for qemu console");
}

/* 崩溃 handler 的磁盘输出走 STDERR（已被 dup2 到 qemu-<id>.log，relay 线程
 * 60ms 轮询会把落盘行抬到 hilog）。注意：信号 handler 里禁止 OH_LOG/hilog ——
 * hilog 是 IPC/带锁路径，在 SIGABRT 上下文调用会丢行甚至死锁，之前
 * OH_LOG_ERROR("crash-log...") 未出现即此故。backtrace_symbols_fd 是
 * async-signal-safe 的；这里的所有写文件/输出只用 syscall：write/read/open。 */
static void dumpQemuLogTail(int fd)
{
    /* 读回 log 尾部 ≤16KB，写 STDERR。qemu 崩溃前的 stderr 文本随 dup2 落盘，
     * 正常退出路径在 vmMain 尾部才读回——崩溃时 qe_system_entry 不返回，不执行。 */
    if (g_qemuLogPath.empty()) {
        return;
    }
    int lfd = open(g_qemuLogPath.c_str(), O_RDONLY);
    if (lfd < 0) {
        return;
    }
    off_t end = lseek(lfd, 0, SEEK_END);
    off_t start = end > (off_t)0x4000 ? end - (off_t)0x4000 : 0;
    lseek(lfd, start, SEEK_SET);
    char buf[2048];
    ssize_t n;
    while ((n = read(lfd, buf, sizeof(buf))) > 0) {
        ssize_t w = write(fd, buf, n);
        (void)w;
    }
    close(lfd);
}

/* SIGSEGV/SIGABRT/SIGBUS/FPE/ILL：
 * 1) 镜像 qemu-<id>.log 尾部到 STDERR（relay 抬 hilog，abort 前文本）；
 * 2) 打印 backtrace（musl 内部帧常挡断 qemu 地址，故从 ucontext 提取“中断瞬间
 *    PC/LR/FO”——那个数是指向 qemu 栈帧的硬证据，本地 addr2line 即解出函数）；
 * 3) 退出。 */
/* 手写 hex 解析：sscanf/strtoul 在信号上下文有 locale/stdio 锁风险。 */
static uint64_t hexToU64(const char **pp)
{
    uint64_t v = 0;
    const char *p = *pp;
    for (;;) {
        char c = *p;
        uint64_t d;
        if (c >= '0' && c <= '9') {
            d = (uint64_t)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            d = (uint64_t)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            d = (uint64_t)(c - 'A' + 10);
        } else {
            break;
        }
        v = v * 16 + d;
        p++;
    }
    *pp = p;
    return v;
}

/* 在 /proc/self/maps 里定位 addr 所属模块，输出 "<路径>+0x<文件偏移>"。
 * 崩溃时 pc=0（跳空指针）无法定位，而 lr 是「谁调用了我」的唯一硬证据；
 * backtrace 常被 musl 帧截断。流式逐行扫（不整体缓冲——qemu 的 guest RAM
 * 映射可达 GB 级，maps 近千行，固定缓冲截断会丢掉高地址段）。未命中时给出
 * 最近的低地址映射，用于区分「落在模块间空洞」与「读取/解析失败」。 */
static void mapsResolve(uint64_t addr, char *out, size_t outn)
{
    static char chunk[4096];
    static char line[512];
    static char bestPath[192];
    size_t linelen = 0;
    uint64_t bestE = 0;
    bestPath[0] = '\0';
    int fd = open("/proc/self/maps", O_RDONLY);
    if (fd < 0) {
        snprintf(out, outn, "maps-open-fail");
        return;
    }
    ssize_t n;
    while ((n = read(fd, chunk, sizeof(chunk))) > 0) {
        for (ssize_t i = 0; i < n; i++) {
            char c = chunk[i];
            if (c != '\n') {
                if (linelen < sizeof(line) - 1) {
                    line[linelen++] = c;
                }
                continue;
            }
            line[linelen] = '\0';
            linelen = 0;
            const char *q = line;
            uint64_t s = hexToU64(&q);
            if (*q != '-') {
                continue;
            }
            q++;
            uint64_t e = hexToU64(&q);
            while (*q == ' ') q++;          /* perms */
            while (*q != ' ' && *q) q++;
            while (*q == ' ') q++;
            uint64_t fo = hexToU64(&q);     /* 文件内偏移 */
            const char *path = strchr(line, '/');
            if (addr >= s && addr < e) {
                snprintf(out, outn, "%s+0x%llx", path ? path : "(anon)",
                         (unsigned long long)(addr - s + fo));
                close(fd);
                return;
            }
            if (e <= addr) {
                bestE = e;
                if (path != nullptr) {
                    snprintf(bestPath, sizeof(bestPath), "%s", path);
                } else {
                    bestPath[0] = '\0';
                }
            }
        }
    }
    close(fd);
    snprintf(out, outn, "no-map; nearest-below=%s end=0x%llx gap=0x%llx",
             bestPath[0] ? bestPath : "(anon)", (unsigned long long)bestE,
             (unsigned long long)(addr - bestE));
}

void crashSigHandler(int sig, siginfo_t *info, void *ucontext)
{
    char buf[160];
    int fd = STDERR_FILENO;

    dumpQemuLogTail(fd);

    /* 崩溃线程名：qemu 的内部线程（vCPU/定时器）各有名字，名即身份，
     * 免去「这个 tid 是谁」的二次猜测。 */
    {
        char commPath[64];
        snprintf(commPath, sizeof(commPath), "/proc/self/task/%d/comm",
                 (int)syscall(SYS_gettid));
        int cf = open(commPath, O_RDONLY);
        if (cf >= 0) {
            char cbuf[48];
            ssize_t cn = read(cf, cbuf, sizeof(cbuf) - 1);
            close(cf);
            if (cn > 0) {
                while (cn > 0 && (cbuf[cn - 1] == '\n' || cbuf[cn - 1] == '\0')) {
                    cn--;
                }
                cbuf[cn] = '\0';
                int clen = snprintf(buf, sizeof(buf), "crash-thread=%s\n", cbuf);
                if (clen > 0) {
                    ssize_t w = write(fd, buf, (size_t)clen);
                    (void)w;
                }
            }
        }
    }

    ucontext_t *uctx = (ucontext_t *)ucontext;
    if (uctx != nullptr) {
#if defined(__aarch64__)
        const uint64_t pc = (uint64_t)uctx->uc_mcontext.pc;
        const uint64_t lr = (uint64_t)uctx->uc_mcontext.regs[30];
#elif defined(__arm__)
        const uint64_t pc = (uint64_t)uctx->uc_mcontext.arm_pc;
        const uint64_t lr = (uint64_t)uctx->uc_mcontext.arm_lr;
#else /* x86_64 */
        const uint64_t pc = (uint64_t)uctx->uc_mcontext.gregs[REG_RIP];
        const uint64_t lr = (uint64_t)uctx->uc_mcontext.gregs[REG_RSP];
#endif
        int len = snprintf(buf, sizeof(buf), "crash-sig=%d pc=0x%llx lr=0x%llx\n",
                           sig, (unsigned long long)pc, (unsigned long long)lr);
        if (len > 0) {
            ssize_t w = write(fd, buf, len);
            (void)w;
        }
#if defined(__aarch64__)
        /* lr 归属：pc=0 时它指出「执行到哪条调用指令撞上 NULL」——拿着
         * 路径+偏移本地 addr2line 即得调用者函数（system so 未导出内部符号，
         * 只能这么拿）。 */
        {
            char lrloc[256];
            mapsResolve(lr, lrloc, sizeof(lrloc));
            len = snprintf(buf, sizeof(buf), "lr-at: %s\n", lrloc);
            if (len > 0) {
                ssize_t w = write(fd, buf, (size_t)len);
                (void)w;
            }
        }
        /* 全寄存器：pc=0 时「取函数指针的寄存器」（x2/x8/x9…）必然为 0，
         * 它旁边的寄存器还指着源表——只靠 pc/lr 反推调用点已两轮落空。 */
        for (int i = 0; i < 31; i += 3) {
            const uint64_t *r = uctx->uc_mcontext.regs;
            int cnt = (i + 3 <= 31) ? 3 : 31 - i;
            len = snprintf(buf, sizeof(buf), "x%-2d..x%-2d: %llx %llx %llx\n", i,
                           i + cnt - 1, (unsigned long long)r[i],
                           (unsigned long long)(cnt > 1 ? r[i + 1] : 0),
                           (unsigned long long)(cnt > 2 ? r[i + 2] : 0));
            if (len > 0) {
                ssize_t w = write(fd, buf, (size_t)len);
                (void)w;
            }
        }
        len = snprintf(buf, sizeof(buf), "sp=0x%llx pstate=0x%llx\n",
                       (unsigned long long)uctx->uc_mcontext.sp,
                       (unsigned long long)uctx->uc_mcontext.pstate);
        if (len > 0) {
            ssize_t w = write(fd, buf, (size_t)len);
            (void)w;
        }
        /* lr 附近的运行时指令：LTO 把多个函数合并进同一节，nm 的符号边界
         * 不可靠（「lr 属于哪个函数」不能只看符号表）。读运行内存里的指令、
         * 本地反汇编，才能确认「跳 0 之前最后执行的是什么」。 */
        if (lr > 0x1000) {
            const uint64_t base = lr & ~0x3ULL;
            const uint32_t *c0 = (const uint32_t *)(base - 32);
            len = snprintf(buf, sizeof(buf),
                           "code@lr-32: %08x %08x %08x %08x %08x %08x %08x %08x\n",
                           c0[0], c0[1], c0[2], c0[3], c0[4], c0[5], c0[6], c0[7]);
            if (len > 0) {
                ssize_t w = write(fd, buf, (size_t)len);
                (void)w;
            }
            const uint32_t *c1 = (const uint32_t *)base;
            len = snprintf(buf, sizeof(buf), "code@lr+0 : %08x %08x %08x %08x\n",
                           c1[0], c1[1], c1[2], c1[3]);
            if (len > 0) {
                ssize_t w = write(fd, buf, (size_t)len);
                (void)w;
            }
        }
        /* 栈邻域：SP 实测可读时扫 32 槽，把落在模块内的值解出归属——调用链
         * 残缺时这是唯一的重建来源。 */
        {
            char sloc[256];
            mapsResolve(uctx->uc_mcontext.sp, sloc, sizeof(sloc));
            if (sloc[0] != 'n') { /* 未命中以 no-map 开头 */
                const uint64_t *stk = (const uint64_t *)uctx->uc_mcontext.sp;
                for (int k = 0; k < 32; k++) {
                    char loc[256];
                    mapsResolve(stk[k], loc, sizeof(loc));
                    if (loc[0] != 'n' && loc[0] != '(') { /* 只打有归属的 */
                        len = snprintf(buf, sizeof(buf), "sp[%d]@ %s\n", k, loc);
                        if (len > 0) {
                            ssize_t w = write(fd, buf, (size_t)len);
                            (void)w;
                        }
                    }
                }
            }
        }
#endif
    }

    void *bt[64];
    int n = backtrace(bt, 64);
    /* 帧缓冲现场在 backtrace 之前落盘：SEGV 高发于 fb_update_rect 的
     * memcpy，没有几何快照就无法区分写越界（producer buffer）与读越界
     * （qemu surface）。脏读（见 fb_crash_dump 注释）。 */
    char fbbuf[512];
    fb_crash_dump(fbbuf, sizeof(fbbuf));
    int len = snprintf(buf, sizeof(buf), "%s\n", fbbuf);
    if (len > 0) {
        ssize_t w = write(fd, buf, (size_t)len);
        (void)w;
    }
    /* bt 帧的模块归属：兼作 mapsResolve 自检（这些地址必有归属，若也报
     * no-map 说明解析不可信），并补齐 musl 截断掉的调用链。 */
    for (int k = 0; k < n && k < 5; k++) {
        char loc[256];
        mapsResolve((uint64_t)(uintptr_t)bt[k], loc, sizeof(loc));
        int blen = snprintf(buf, sizeof(buf), "bt[%d]@ %s\n", k, loc);
        if (blen > 0) {
            ssize_t w = write(fd, buf, (size_t)blen);
            (void)w;
        }
    }
    backtrace_symbols_fd(bt, n, fd);
    /* hold 一下让日志转发线程把上面落盘的内容实时抬到 hilog，再退出。 */
    usleep(200 * 1000);
    _exit(128 + sig);
}

void installCrashHandlers()
{
    struct sigaction sa{};
    sa.sa_sigaction = crashSigHandler;
    sa.sa_flags = SA_RESETHAND | SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGABRT, &sa, nullptr);
    sigaction(SIGBUS, &sa, nullptr);
    sigaction(SIGFPE, &sa, nullptr);
    sigaction(SIGILL, &sa, nullptr);
}

/* ---- 日志速率熔断（防 GB 级灌盘）----
 * 背景：qemu 启动失败时会陷入「重复打印同一行错误、且不退」的状态，实测
 * 38MB/s 灌盘，几秒就 GB 级——典型触发是非法 -device（error_fatal 路径）。
 * 父进程侧的「强制断电」兜底要用户点一下才生效，这里做进程内自止，让失控
 * 自行结束。挂在现成的 relay 线程上（本就每 60ms 读一次文件尾），不新起线程。
 *
 * 判据前提：本项目 guest 输出不落 stderr —— 串口走 -serial file:/socket、
 * 画面走 DCL，所以 stderr 的增长率就代表 qemu 自己的报错刷屏。正常启动日志是
 * KB 量级；唯一现实噪声源是 -audiodev driver=ohos 的告警（约 10KB/s），比阈值
 * 低两个数量级。
 *
 * 退出只能 _exit：崩溃/跑飞路径上 exit() 已经不返回（实测探针 0 命中），
 * 且不能碰 hilog（IPC 带锁路径，在失控进程里可能自己卡住）。哨兵行写 fd 2 ——
 * fd 2 已被 dup2 到同一份 qemu-<id>.log，所以它会成为日志的最后一行，
 * 由父进程的失败弹窗（只读尾部 64KB）呈现给用户。 */
constexpr double kFloodBps = 4.0 * 1024 * 1024;      /* 4MB/s */
constexpr int kFloodStreak = 2;                      /* 连续 2 个采样窗口 */
constexpr long long kFloodTotal = 256LL * 1024 * 1024; /* 单文件累计 256MB（抓慢速刷屏） */
constexpr long long kFloodChunk = 1LL * 1024 * 1024;   /* 单轮读入上限 1MB：防滞后时一次分配 GB 级 */
constexpr int kFloodExitCode = 70;                   /* EX_SOFTWARE */

void logFloodExit(const char *reason, long long bytes)
{
    char buf[192];
    int n = snprintf(buf, sizeof(buf), "\nHIUM-FAULT: reason=%s bytes=%lld\n", reason, bytes);
    if (n > 0) {
        ssize_t w = write(STDERR_FILENO, buf, (size_t)n);
        (void)w;
    }
    _exit(kFloodExitCode);
}

/* 洪泛看门狗：独立线程，只做 stat + _exit，绝不调 hilog。
 * 为什么不能只靠 relay 线程的判据：判据要在循环里跑，而循环里的 OH_LOG_INFO
 * 在洪流下会被 hilog 背压阻塞（实测一次转发就能把循环卡住数秒到数分钟），
 * 判据于是永远轮不到执行——256MB 上限失效，日志涨到 2GB 进程仍活着。
 * 本线程与转发彻底解耦：200ms 一次 stat 是纯本地 syscall，任何情况下都能落地。 */
constexpr long long kWatchdogDelta = 1LL * 1024 * 1024; /* 200ms 增长 >1MB ≈ 5MB/s */
void logFloodWatchdogThread(const std::string &logPath, std::atomic<bool> *stop)
{
    pthread_setname_np(pthread_self(), "qemu-log-wd");
    long long last = 0;
    while (!stop->load()) {
        usleep(200 * 1000);
        struct stat st{};
        if (stat(logPath.c_str(), &st) != 0) {
            continue;
        }
        long long sz = (long long)st.st_size;
        if (sz > kFloodTotal) {
            logFloodExit("logflood-total", sz);
        }
        if (sz - last > kWatchdogDelta) {
            logFloodExit("logflood-rate", sz);
        }
        last = sz;
    }
}

/* 后台线程：轮询读取 qemu-<vmId>.log 的新增内容，按行转发到 hilog（QemuVM 域）。
 * qemu 的 stderr 已被 dup2 到该文件——正常退出的报错与崩溃时的 backtrace 都落在
 * 这里；实时转发让 hdc 直接可见，无需访问 app 沙箱 nor 等 qemu 退出。 */
void relayQemuLogThread(const std::string &logPath, std::atomic<bool> *stop)
{
    pthread_setname_np(pthread_self(), "qemu-log-relay");
    off_t pos = 0;
    std::string partial;
    /* 熔断统计：1s 一个采样窗口，窗口内字节数换算成速率 */
    long long total = 0;
    long long winBytes = 0;
    int streak = 0;
    struct timespec winStart{};
    clock_gettime(CLOCK_MONOTONIC, &winStart);
    while (!stop->load()) {
        long long grew = 0;
        std::string chunk;
        std::ifstream f(logPath, std::ios::in | std::ios::binary);
        if (f.is_open()) {
            f.seekg(0, std::ios::end);
            std::streamoff end = f.tellg();
            /* 单轮读入上限：线程若被 hilog 阻塞或调度延迟拖住，pos 会落后很远，
             * 不设上限就会出现「一次分配 + 读入 GB 级缓冲」，判据还没轮到就被拖死 */
            if (end > pos + kFloodChunk) {
                end = pos + kFloodChunk;
            }
            if (end > pos) {
                f.seekg(pos);
                chunk.assign(static_cast<size_t>(end - pos), '\0');
                f.read(&chunk[0], static_cast<std::streamsize>(end - pos));
                grew = (long long)(end - pos);
                total += grew;
                winBytes += grew;
                pos = end;
            }
            f.close();
        }
        /* 速率结算放在转发之前：OH_LOG_INFO 在洪流下会被 hilog 背压阻塞数秒到数
         * 分钟，实测「转发在前」使整个循环停摆，速率/总量判据永远轮不到执行——
         * 256MB 熔断失效，日志涨到 2.48GB 进程仍活着。先判后转，判据与转发解耦。 */
        struct timespec now{};
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (double)(now.tv_sec - winStart.tv_sec) +
                         (double)(now.tv_nsec - winStart.tv_nsec) / 1e9;
        if (elapsed >= 1.0) {
            double bps = (double)winBytes / elapsed;
            streak = (bps > kFloodBps) ? streak + 1 : 0;
            if (streak >= kFloodStreak) {
                logFloodExit("logflood-rate", total);
            }
            winStart = now;
            winBytes = 0;
        }
        /* 累计超限：抓「速率不高但一直写」的慢速刷屏，不必等窗口结算 */
        if (total > kFloodTotal) {
            logFloodExit("logflood-total", total);
        }
        /* 已连续一个窗口超阈值：疑似失控，停止转发（转发是熔断失效的根源），
         * 丢弃缓冲避免 partial 无界增长；下一窗口结算决定是否 _exit。 */
        if (streak > 0) {
            partial.clear();
        } else if (grew > 0) {
            partial += chunk;
            std::string line;
            size_t nl;
            int forwarded = 0;
            /* 每轮限量转发：正常 KB 级启动日志照常可见，洪流下也不至于把循环
             * 拖死（保底 <20 行/轮 ≈ 320 行/s）。 */
            while ((nl = partial.find('\n')) != std::string::npos) {
                line = partial.substr(0, nl);
                partial.erase(0, nl + 1);
                if (!line.empty() && forwarded < 20) {
                    OH_LOG_INFO(LOG_APP, "qemu-log: %{public}s", line.c_str());
                    forwarded++;
                }
            }
        }
        usleep(60 * 1000); /* 快速轮询，捕捉崩溃瞬间写入的 abort/backtrace */
    }
    if (!partial.empty()) {
        OH_LOG_INFO(LOG_APP, "qemu-log: %{public}s", partial.c_str());
    }
}
} // namespace

bool vm_running()
{
    return g_vm.running.load();
}

int vm_start(const std::string &arch, const std::vector<std::string> &args)
{
    /* so != nullptr means the previous run is still cleaning up */
    if (g_vm.running.load() || g_vm.so != nullptr) {
        OH_LOG_WARN(LOG_APP, "vm already running or cleaning up");
        return -1;
    }

    std::string soName = "libqemu-system-" + arch + ".so";
    OH_LOG_INFO(LOG_APP, "vm_start arch=%{public}s dlopen %{public}s argc=%{public}zu",
                arch.c_str(), soName.c_str(), args.size());
    void *so = dlopen(soName.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!so) {
        OH_LOG_ERROR(LOG_APP, "dlopen %{public}s failed: %{public}s", soName.c_str(), dlerror());
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "dlopen %{public}s ok, resolving symbols...", soName.c_str());
    g_vm.so = so;

    bool ok = true;
    ok &= resolveSym(so, "qemu_system_entry", &qe_system_entry);
    ok &= resolveSym(so, "register_displaychangelistener", &qe_register_dcl);
    ok &= resolveSym(so, "qemu_console_lookup_default", &qe_console_lookup_default);
    ok &= resolveSym(so, "graphic_hw_update", &qe_graphic_hw_update);
    /* invalidate 不强制要求（老 .so 缺失时槽重建后靠下一次自然脏区恢复画面） */
    resolveSym(so, "graphic_hw_invalidate", &qe_graphic_hw_invalidate);
    /* surface 真值查询不强制要求（缺失时 fb 跳过对齐，行为同旧版） */
    resolveSym(so, "qemu_console_surface", &qe_console_surface);
    /* virgl 的宿主 GL 工厂（仅 virtio-gl 需要）：console 挂 dgc 用
     * set_display_gl_ctx，ops 委托 egl-* 工厂；rn_ctx 是 share 链源头 */
    resolveSym(so, "qemu_console_set_display_gl_ctx", &qe_set_display_gl_ctx);
    /* qemu 的 EGL/GL 全局：地址直接 dlsym（都是非 static 全局变量） */
    qe_egl_display_p = (void **)dlsym(so, "qemu_egl_display");
    qe_egl_config_p = (void **)dlsym(so, "qemu_egl_config");
    qe_egl_rn_ctx_p = (void **)dlsym(so, "qemu_egl_rn_ctx");
    qe_display_opengl_p = (int *)dlsym(so, "display_opengl");
    ok &= resolveSym(so, "qemu_input_event_send_key_qcode", &qe_input_send_key);
    ok &= resolveSym(so, "qemu_input_queue_abs", &qe_input_queue_abs);
    ok &= resolveSym(so, "qemu_input_queue_btn", &qe_input_queue_btn);
    ok &= resolveSym(so, "qemu_input_event_sync", &qe_input_event_sync);
    ok &= resolveSym(so, "qemu_input_is_absolute", &qe_input_is_absolute);
    /* 注入线程必须持 BQL：官方前端（VNC/GTK）调 input 队列接口时都在主循环线程
     * （天然持锁）；我们从注入线程直调，事件经 usb-tablet 的 usb_wakeup 走中断
     * 路径会命中 cpu_interrupt 的 g_assert(bql_locked())，qemu 直接自杀
     * （OVMF 使能 USB remote wakeup 后实测必现，xp/seabios 不开 wakeup 所以无感）。
     * qemu 10.x 的符号本体是 bql_lock_impl/bql_unlock（qemu_mutex_lock_iothread
     * 只是头文件兼容宏，so 里不存在）。这两个**不进 ok 链**——解析失败只降级为
     * 无锁注入（BqlGuard 判空跳过），不能像必需符号那样让整个 qemu 起不来。 */
    resolveSym(so, "bql_lock_impl", &qe_bql_lock);
    resolveSym(so, "bql_unlock", &qe_bql_unlock);
    /* pixman is statically linked into the qemu .so: reuse its accessors */
    ok &= resolveSym(so, "pixman_image_get_width", &qe_surface_width);
    ok &= resolveSym(so, "pixman_image_get_height", &qe_surface_height);
    ok &= resolveSym(so, "pixman_image_get_stride", &qe_surface_stride);
    ok &= resolveSym(so, "pixman_image_get_data", &qe_surface_data);
    ok &= resolveSym(so, "pixman_image_get_format", &qe_surface_format);
    if (!ok) {
        dlclose(so);
        g_vm.so = nullptr;
        return -1;
    }

    std::string argv0 = "qemu-system-" + arch;
    g_vm.argStrings.clear();
    g_vm.argStrings.push_back(argv0);
    for (const auto &a : args) {
        g_vm.argStrings.push_back(a);
    }
    g_vm.argPtrs.clear();
    for (auto &s : g_vm.argStrings) {
        g_vm.argPtrs.push_back(&s[0]);
    }

    {
        std::string cmdline;
        for (auto &s : g_vm.argStrings) {
            cmdline += s;
            cmdline += ' ';
        }
        OH_LOG_INFO(LOG_APP, "starting vm: %{public}s", cmdline.c_str());
    }

    g_vm.running.store(true);
    g_vm.vmThread = std::thread(vmMain, &g_vm);
    g_vm.vmThread.detach();
    /* not detached: vmMain joins it during cleanup */
    g_vm.bindThread = std::thread(bindDisplay, &g_vm);
    return 0;
}
