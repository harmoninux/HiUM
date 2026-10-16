/* qemu 子进程入口：由父进程 OH_Ability_CreateNativeChildProcess("libqemu_child.so")
 * 拉起。导出 NativeChildProcess_OnConnect（IPC stub）与
 * NativeChildProcess_MainProc（阻塞至一轮 VM 结束或收到 shutdown）。
 * 一个子进程跑一轮 VM；退出后父进程另起新子进程（见 qemu_ipc.h）。 */
#include "qemu_ipc.h"
#include "vm.h"
#include "fb.h"
#include "renderer.h"
#include "input.h"

#include <native_window/external_window.h>
#include <AbilityKit/native_child_process.h>
#include <IPCKit/ipc_cremote_object.h>
#include <IPCKit/ipc_cparcel.h>
#include <IPCKit/ipc_error_code.h>
#include <hilog/log.h>

#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <atomic>
#include <string>
#include <vector>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0005
#define LOG_TAG "QemuChild"

namespace {

using namespace qemu_ipc;

std::atomic<bool> g_quit{false};
/* kShutdown（父进程「强制断电」）置位：MainProc 直接 _exit，跳过 renderer_detach_window()。
 * 正常退出时要 detach（join 渲染线程 + EGL teardown）；强制路径不能等——qemu 已经卡死时
 * 那个 join 可能永不返回，而进程不死的代价是 qcow2 写锁不释放，下次启动必撞
 * "Failed to get write lock"。进程整体消失是内核保证的，_exit 是不依赖任何线程合作的兜底。 */
std::atomic<bool> g_force{false};

int replyInt(OHIPCParcel *reply, int32_t v)
{
    return reply ? OH_IPCParcel_WriteInt32(reply, v) : OH_IPC_CHECK_PARAM_ERROR;
}

/* START: [ver][arch][argc][argv...][window parcel] */
int32_t onStart(const OHIPCParcel *data)
{
    const char *arch = OH_IPCParcel_ReadString(data);
    int32_t argc = 0;
    if (OH_IPCParcel_ReadInt32(data, &argc) != OH_IPC_SUCCESS) {
        argc = 0;
    }
    if (arch == nullptr || argc <= 0 || argc > 128) {
        OH_LOG_ERROR(LOG_APP, "child: bad START payload arch=%{public}s argc=%{public}d",
                     arch ? arch : "(null)", argc);
        return -2;
    }
    std::vector<std::string> args;
    for (int32_t i = 0; i < argc; i++) {
        const char *a = OH_IPCParcel_ReadString(data);
        if (a == nullptr) {
            return -2;
        }
        args.emplace_back(a);
    }
    OHNativeWindow *win = nullptr;
    if (OH_NativeWindow_ReadFromParcel(const_cast<OHIPCParcel *>(data), &win) != 0 ||
        win == nullptr) {
        OH_LOG_ERROR(LOG_APP, "child: START without window");
        return -3;
    }
    renderer_attach_window(win); /* 接管 window 所有权 */
    int ret = vm_start(arch, args);
    if (ret != 0) {
        renderer_detach_window();
    }
    OH_LOG_INFO(LOG_APP, "child: START %{public}s ret=%{public}d", arch, ret);
    return ret;
}

/* ATTACH: [ver][window parcel] —— Console 重建 surface 后重新挂窗 */
int32_t onAttach(const OHIPCParcel *data)
{
    OHNativeWindow *win = nullptr;
    if (OH_NativeWindow_ReadFromParcel(const_cast<OHIPCParcel *>(data), &win) != 0 ||
        win == nullptr) {
        return -3;
    }
    renderer_attach_window(win);
    OH_LOG_INFO(LOG_APP, "child: surface attached");
    return 0;
}

int onRequest(uint32_t code, const OHIPCParcel *data, OHIPCParcel *reply, void *userData)
{
    int32_t version = 0;
    if (data == nullptr || OH_IPCParcel_ReadInt32(data, &version) != OH_IPC_SUCCESS ||
        version != kProtoVersion) {
        OH_LOG_ERROR(LOG_APP, "child: bad request code=%{public}u version=%{public}d", code, version);
        return replyInt(reply, -1);
    }
    switch (code) {
        case kStart:
            return replyInt(reply, onStart(data));
        case kAttachSurface:
            return replyInt(reply, onAttach(data));
        case kDetachSurface:
            renderer_detach_window();
            return replyInt(reply, 0);
        case kResizeSurface: {
            int32_t w = 0, h = 0;
            OH_IPCParcel_ReadInt32(data, &w);
            OH_IPCParcel_ReadInt32(data, &h);
            renderer_resize_surface(w, h);
            return replyInt(reply, 0);
        }
        case kPointer: {
            int32_t x = 0, y = 0, buttons = 0;
            OH_IPCParcel_ReadInt32(data, &x);
            OH_IPCParcel_ReadInt32(data, &y);
            OH_IPCParcel_ReadInt32(data, &buttons);
            input_send_pointer(x, y, buttons);
            return replyInt(reply, 0);
        }
        case kKey: {
            int32_t qcode = 0, down = 0;
            OH_IPCParcel_ReadInt32(data, &qcode);
            OH_IPCParcel_ReadInt32(data, &down);
            input_send_key(qcode, down != 0);
            return replyInt(reply, 0);
        }
        case kScroll: {
            int32_t dx = 0, dy = 0;
            OH_IPCParcel_ReadInt32(data, &dx);
            OH_IPCParcel_ReadInt32(data, &dy);
            input_send_scroll(dx, dy);
            return replyInt(reply, 0);
        }
        case kQuery: {
            int fbW = 0, fbH = 0;
            {
                std::lock_guard<std::mutex> lock(g_fb.mu);
                fbW = g_fb.w;
                fbH = g_fb.h;
            }
            if (reply) {
                OH_IPCParcel_WriteInt32(reply, kProtoVersion);
                OH_IPCParcel_WriteInt32(reply, fbW);
                OH_IPCParcel_WriteInt32(reply, fbH);
                OH_IPCParcel_WriteInt32(reply, vm_running() ? 1 : 0);
            }
            return 0;
        }
        case kScreenshot: {
            /* [ver][maxW][path] → [ver][w][h][written]。数据直接落盘（协议注释：
             * parcel 装不下整幅 RGBA），父进程凭 [w][h][written] 即可。
             * 全黑帧不落盘：就绪判定只说明 QMP 活了，慢引导 guest（Windows）
             * 这时往往还在黑屏期，抓到的是纯黑——存进缓存会在详情页顶着一个
             * 「假画面」卡到下一次抓帧。抽样 RGB 分量全小于阈值即视为黑。 */
            int32_t maxW = 0;
            OH_IPCParcel_ReadInt32(data, &maxW);
            const char *path = OH_IPCParcel_ReadString(data);
            int w = 0, h = 0;
            std::vector<uint32_t> px = fb_capture_rgba(maxW > 0 ? maxW : 1024, &w, &h);
            int32_t written = 0;
            bool allBlack = true;
            for (size_t i = 0; i < px.size(); i += 16) {
                uint32_t p = px[i];
                int r = (p >> 16) & 0xff, g = (p >> 8) & 0xff, b = p & 0xff;
                if (r > 8 || g > 8 || b > 8) {
                    allBlack = false;
                    break;
                }
            }
            if (path != nullptr && !px.empty() && !allBlack) {
                /* 8 字节小端宽高头 + RGBA_8888 裸像素，与读取侧（VmManage.loadThumb）
                 * 的既有约定一致 */
                const uint32_t hdr[2] = {static_cast<uint32_t>(w), static_cast<uint32_t>(h)};
                int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0664);
                if (fd >= 0) {
                    written = write(fd, hdr, sizeof(hdr)) == static_cast<ssize_t>(sizeof(hdr)) &&
                              write(fd, px.data(), px.size() * sizeof(uint32_t)) ==
                                  static_cast<ssize_t>(px.size() * sizeof(uint32_t));
                    close(fd);
                }
            }
            if (!written && !allBlack) {
                OH_LOG_ERROR(LOG_APP, "screenshot: write failed path=%{public}s w=%{public}d h=%{public}d px=%{public}zu",
                             path ? path : "(null)", w, h, px.size());
            }
            if (reply) {
                OH_IPCParcel_WriteInt32(reply, kProtoVersion);
                OH_IPCParcel_WriteInt32(reply, w);
                OH_IPCParcel_WriteInt32(reply, h);
                OH_IPCParcel_WriteInt32(reply, written);
            }
            return 0;
        }
        case kShutdown:
            replyInt(reply, 0);
            g_force.store(true);
            g_quit.store(true);
            return 0;
        default:
            return replyInt(reply, -6);
    }
}

void onStubDestroy(void *userData)
{
    OH_LOG_INFO(LOG_APP, "child: IPC stub destroyed (parent gone?), quitting");
    g_quit.store(true);
}

/* ---- TEMP: /proc 读取探针（HUD 数据面可行性实测，结论入 spec 后移除）----
 * 子进程自读 /proc/self 下文件，给「字段存在与格式」打地面真值：
 * 线程名与 ticks（task 目录下 comm、stat）、内存（status VmRSS）、IO（io rchar/wchar）。 */
void procProbeSelf()
{
    int threads = 0;
    DIR *d = opendir("/proc/self/task");
    if (d != nullptr) {
        struct dirent *e;
        while ((e = readdir(d)) != nullptr) {
            if (e->d_name[0] < '0' || e->d_name[0] > '9') {
                continue;
            }
            threads++;
            if (threads > 8) {
                continue; /* 样本只打前 8 个线程，够认格式 */
            }
            char path[96];
            char comm[64] = "";
            unsigned long utime = 0, stime = 0;
            snprintf(path, sizeof(path), "/proc/self/task/%s/comm", e->d_name);
            FILE *f = fopen(path, "r");
            if (f != nullptr) {
                size_t n = fread(comm, 1, sizeof(comm) - 1, f);
                comm[n] = '\0';
                for (size_t i = 0; i < n; i++) {
                    if (comm[i] == '\n') {
                        comm[i] = '\0';
                        break;
                    }
                }
                fclose(f);
            }
            snprintf(path, sizeof(path), "/proc/self/task/%s/stat", e->d_name);
            f = fopen(path, "r");
            if (f != nullptr) {
                char buf[512];
                if (fgets(buf, sizeof(buf), f) != nullptr) {
                    /* 字段 14/15 = utime/stime；comm 可含空格，取最后一个 ')' 之后数 */
                    char *rp = strrchr(buf, ')');
                    if (rp != nullptr) {
                        sscanf(rp + 1, " %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lu %lu",
                               &utime, &stime);
                    }
                }
                fclose(f);
            }
            OH_LOG_INFO(LOG_APP, "PROBE-SELF tid=%{public}s comm=%{public}s utime=%{public}lu stime=%{public}lu",
                        e->d_name, comm, utime, stime);
        }
        closedir(d);
    } else {
        OH_LOG_ERROR(LOG_APP, "PROBE-SELF opendir task errno=%{public}d", errno);
    }
    FILE *f = fopen("/proc/self/status", "r");
    if (f != nullptr) {
        char buf[256];
        while (fgets(buf, sizeof(buf), f) != nullptr) {
            if (strncmp(buf, "VmRSS", 5) == 0) {
                OH_LOG_INFO(LOG_APP, "PROBE-SELF status: %{public}s", buf);
                break;
            }
        }
        fclose(f);
    }
    f = fopen("/proc/self/io", "r");
    if (f != nullptr) {
        char buf[256];
        while (fgets(buf, sizeof(buf), f) != nullptr) {
            if (strncmp(buf, "rchar", 5) == 0 || strncmp(buf, "wchar", 5) == 0) {
                OH_LOG_INFO(LOG_APP, "PROBE-SELF io: %{public}s", buf);
            }
        }
        fclose(f);
    } else {
        OH_LOG_ERROR(LOG_APP, "PROBE-SELF open io errno=%{public}d", errno);
    }
    OH_LOG_INFO(LOG_APP, "PROBE-SELF done threads=%{public}d pid=%{public}d", threads, getpid());
}

} // namespace

extern "C" __attribute__((visibility("default"))) OHIPCRemoteStub *NativeChildProcess_OnConnect()
{
    OHIPCRemoteStub *stub = OH_IPCRemoteStub_Create(kDescriptor, onRequest, onStubDestroy, nullptr);
    OH_LOG_INFO(LOG_APP, "child: OnConnect stub=%{public}s pid=%{public}d",
                stub ? "ok" : "null", getpid());
    return stub;
}

extern "C" __attribute__((visibility("default"))) void NativeChildProcess_MainProc()
{
    OH_LOG_INFO(LOG_APP, "child: MainProc entered");
    /* VM 跑完一轮（running 由真转假）或收到 shutdown/父进程消失时退出 */
    bool wasRunning = false;
    bool probed = false;
    while (!g_quit.load()) {
        bool r = vm_running();
        if (r) {
            if (!probed) {
                /* TEMP 探针：起来 2s 后自读 /proc/self 打地面真值（结论入 spec 后移除） */
                probed = true;
                std::thread([]() {
                    usleep(2 * 1000 * 1000);
                    procProbeSelf();
                }).detach();
            }
            wasRunning = true;
        } else if (wasRunning) {
            break;
        }
        usleep(200 * 1000);
    }
    OH_LOG_INFO(LOG_APP, "child: MainProc exiting (wasRunning=%{public}d quit=%{public}d force=%{public}d)",
                wasRunning ? 1 : 0, g_quit.load() ? 1 : 0, g_force.load() ? 1 : 0);
    if (g_force.load()) {
        _exit(0); /* 强制断电：不等渲染线程（见 g_force 注释） */
    }
    renderer_detach_window();
}
