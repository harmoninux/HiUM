#include "ncp_client.h"
#include "qemu_ipc.h"

#include <native_window/external_window.h>
#include <AbilityKit/native_child_process.h>
#include <IPCKit/ipc_cremote_object.h>
#include <IPCKit/ipc_cparcel.h>
#include <IPCKit/ipc_error_code.h>
#include <hilog/log.h>

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

#include <deque>
#include <map>
#include <mutex>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0007
#define LOG_TAG "QemuNapi"

namespace {

using namespace qemu_ipc;

/* ---- TEMP: /proc 读取探针（HUD 数据面可行性实测，结论入 spec 后移除）----
 * 父进程视角两问：① 子进程在 /proc 里可见吗（pid 发现——NCP 不给 pid，
 * ChildState 无 pid 字段，ppid 扫描是唯一自助途径）；② 可见时
 * task/comm/status/io 读得动吗（errno 说话）。 */
void procProbeParent()
{
    DIR *d = opendir("/proc");
    if (d == nullptr) {
        OH_LOG_ERROR(LOG_APP, "PROBE-PARENT opendir /proc errno=%{public}d", errno);
        return;
    }
    pid_t self = getpid();
    std::vector<std::string> kids;
    struct dirent *e;
    while ((e = readdir(d)) != nullptr) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') {
            continue;
        }
        FILE *f = fopen((std::string("/proc/") + e->d_name + "/stat").c_str(), "r");
        if (f == nullptr) {
            continue; /* 看不见别人的进程是常态，不算异常 */
        }
        char buf[512];
        if (fgets(buf, sizeof(buf), f) != nullptr) {
            char *rp = strrchr(buf, ')');
            int ppid = 0;
            if (rp != nullptr && sscanf(rp + 1, " %*c %d", &ppid) == 1 && ppid == (int)self) {
                kids.push_back(e->d_name);
            }
        }
        fclose(f);
    }
    closedir(d);
    if (kids.empty()) {
        OH_LOG_ERROR(LOG_APP, "PROBE-PARENT: 子进程在 /proc 不可见 → pid 发现不可行，读子进程数据必走 IPC 上报");
        return;
    }
    for (const std::string &k : kids) {
        OH_LOG_INFO(LOG_APP, "PROBE-PARENT: 看见子进程 pid=%{public}s", k.c_str());
        char path[128];
        snprintf(path, sizeof(path), "/proc/%s/task", k.c_str());
        int threads = 0;
        DIR *td = opendir(path);
        if (td != nullptr) {
            struct dirent *te;
            while ((te = readdir(td)) != nullptr) {
                if (te->d_name[0] < '0' || te->d_name[0] > '9') {
                    continue;
                }
                threads++;
                if (threads > 4) {
                    continue; /* 样本只打前 4 个线程 */
                }
                char p2[160];
                char comm[64] = "";
                unsigned long utime = 0, stime = 0;
                snprintf(p2, sizeof(p2), "/proc/%s/task/%s/comm", k.c_str(), te->d_name);
                FILE *f = fopen(p2, "r");
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
                } else {
                    OH_LOG_ERROR(LOG_APP, "PROBE-PARENT comm open errno=%{public}d", errno);
                }
                snprintf(p2, sizeof(p2), "/proc/%s/task/%s/stat", k.c_str(), te->d_name);
                f = fopen(p2, "r");
                if (f != nullptr) {
                    char b[512];
                    if (fgets(b, sizeof(b), f) != nullptr) {
                        char *rp = strrchr(b, ')');
                        if (rp != nullptr) {
                            sscanf(rp + 1, " %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lu %lu",
                                   &utime, &stime);
                        }
                    }
                    fclose(f);
                } else {
                    OH_LOG_ERROR(LOG_APP, "PROBE-PARENT task stat open errno=%{public}d", errno);
                }
                OH_LOG_INFO(LOG_APP, "PROBE-PARENT tid=%{public}s comm=%{public}s utime=%{public}lu stime=%{public}lu",
                            te->d_name, comm, utime, stime);
            }
            closedir(td);
            OH_LOG_INFO(LOG_APP, "PROBE-PARENT 子进程 task 目录可列 threads=%{public}d", threads);
        } else {
            OH_LOG_ERROR(LOG_APP, "PROBE-PARENT task opendir errno=%{public}d", errno);
        }
        snprintf(path, sizeof(path), "/proc/%s/status", k.c_str());
        FILE *f = fopen(path, "r");
        if (f != nullptr) {
            char b[256];
            while (fgets(b, sizeof(b), f) != nullptr) {
                if (strncmp(b, "VmRSS", 5) == 0) {
                    OH_LOG_INFO(LOG_APP, "PROBE-PARENT status: %{public}s", b);
                    break;
                }
            }
            fclose(f);
        } else {
            OH_LOG_ERROR(LOG_APP, "PROBE-PARENT status open errno=%{public}d", errno);
        }
        snprintf(path, sizeof(path), "/proc/%s/io", k.c_str());
        f = fopen(path, "r");
        if (f != nullptr) {
            char b[256];
            while (fgets(b, sizeof(b), f) != nullptr) {
                if (strncmp(b, "rchar", 5) == 0 || strncmp(b, "wchar", 5) == 0) {
                    OH_LOG_INFO(LOG_APP, "PROBE-PARENT io: %{public}s", b);
                }
            }
            fclose(f);
        } else {
            OH_LOG_ERROR(LOG_APP, "PROBE-PARENT io open errno=%{public}d", errno);
        }
    }
}

/* 一台 VM 的子进程状态。条目创建后常驻 map（数量=VM 数，很小），
 * 地址稳定，因此可以安全地先取 ChildState*、释放全局锁、再持 child 自己的
 * mutex 做 IPC——不同 VM 之间不再互相阻塞。 */
struct ChildState {
    std::mutex mu;                    /* 护住 proxy/vmRunning/attached/surfaceId */
    OHIPCRemoteProxy *proxy = nullptr;
    bool vmRunning = false;
    bool attached = false;
    int64_t surfaceId = 0;
};

/* NCP 拉起请求。CreateNativeChildProcess 的回调不带任何可关联信息，
 * 多实例下无法区分并发拉起，因此串行化：任何时刻最多一个在途。 */
struct StartReq {
    std::string vmId;
    std::string arch;
    std::vector<std::string> args;
    int64_t surfaceId = 0;
};

/* 本文件两把锁，锁序固定：**先 g_mu、后 child->mu**，绝不反向，无死锁。
 * g_mu 只护 g_children 这个 map 结构 + g_pending 队列 + g_spawnInFlight；
 * 真正的 IPC 发送与 VM 字段访问走各自的 child->mu。 */
std::mutex g_mu;
std::map<std::string, ChildState> g_children;
std::deque<StartReq> g_pending;
bool g_spawnInFlight = false;

/* 取（不创建）一个已入库 ChildState 的稳定指针；不存在返回 nullptr。
 * 调用方拿到后即可释放 g_mu —— 条目常驻，指针不回退。调用方须持 child->mu 访问其字段。 */
ChildState *getChild(const std::string &vmId)
{
    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_children.find(vmId);
    return it == g_children.end() ? nullptr : &it->second;
}

/* 若要创建条目（attach 记录 surfaceId 或 onChildStarted 建表），须持 g_mu 用
 * g_children[vmId]；返回稳定指针，随后可释放 g_mu。 */
ChildState *createChildLocked(const std::string &vmId)
{
    return &g_children[vmId];
}

/* NCP 不给 pid↔proxy 对应关系，多实例下无法把 exit 事件归到具体 vmId；
 * 且该回调实测不可靠（有不触发的情况）。这里只记日志，清理由各 vmId 的
 * QUERY 自愈完成（见 ncp_client_running）。 */
void onChildExit(int32_t pid, int32_t signal)
{
    OH_LOG_INFO(LOG_APP, "child exit callback pid=%{public}d signal=%{public}d", pid, signal);
}

void ensureExitCallback()
{
    static std::once_flag once;
    std::call_once(once, []() {
        int ret = OH_Ability_RegisterNativeChildProcessExitCallback(onChildExit);
        OH_LOG_INFO(LOG_APP, "register exit callback ret=%{public}d", ret);
    });
}

OHIPCParcel *newRequest()
{
    OHIPCParcel *req = OH_IPCParcel_Create();
    if (req) {
        OH_IPCParcel_WriteInt32(req, kProtoVersion);
    }
    return req;
}

/* 调用方须持有 ch.mu。返回 reply parcel（调用方负责 Destroy），失败返回 nullptr。 */
OHIPCParcel *sendTo(ChildState &ch, uint32_t code, OHIPCParcel *req)
{
    if (ch.proxy == nullptr || req == nullptr) {
        return nullptr;
    }
    OHIPCParcel *reply = OH_IPCParcel_Create();
    if (reply == nullptr) {
        return nullptr;
    }
    OH_IPC_MessageOption option = {OH_IPC_REQUEST_MODE_SYNC, 0, nullptr};
    int32_t ret = OH_IPCRemoteProxy_SendRequest(ch.proxy, code, req, reply, &option);
    if (ret != OH_IPC_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "ipc send code=%{public}u failed ret=%{public}d", code, ret);
        OH_IPCParcel_Destroy(reply);
        return nullptr;
    }
    return reply;
}

int32_t replyCode(OHIPCParcel *reply)
{
    int32_t v = -1;
    if (reply) {
        OH_IPCParcel_ReadInt32(reply, &v);
        OH_IPCParcel_Destroy(reply);
    }
    return v;
}

OHNativeWindow *windowFromSurfaceId(int64_t surfaceId)
{
    OHNativeWindow *win = nullptr;
    int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId((uint64_t)surfaceId, &win);
    if (ret != 0 || win == nullptr) {
        OH_LOG_ERROR(LOG_APP, "CreateNativeWindowFromSurfaceId failed ret=%{public}d", ret);
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "window from surfaceId=%{public}llu → %{public}p",
                (unsigned long long)surfaceId, win);
    return win;
}

void spawnNextLocked(); /* 前向声明；调用方须持 g_mu */

/* NCP 启动回调（独立线程）：给队首请求建子进程条目并发送 START（参数 + 窗口）。
 * 只在 g_mu 下取请求 / 建条目 / 推进队列；发送 START 持 ch.mu（不同 VM 互不阻塞）。 */
void onChildStarted(int errCode, OHIPCRemoteProxy *proxy)
{
    StartReq req;
    ChildState *chp = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_pending.empty()) {
            OH_LOG_ERROR(LOG_APP, "child started but no pending request, dropping proxy");
            if (proxy) {
                OH_IPCRemoteProxy_Destroy(proxy);
            }
            g_spawnInFlight = false;
            return;
        }
        req = std::move(g_pending.front());
        g_pending.pop_front();

        if (errCode != NCP_NO_ERROR || proxy == nullptr) {
            OH_LOG_ERROR(LOG_APP, "child start failed errCode=%{public}d vm=%{public}s",
                         errCode, req.vmId.c_str());
            spawnNextLocked();
            return;
        }
        chp = createChildLocked(req.vmId);
    } /* 释放 g_mu，以下只动这个 VM 的 child */

    {
        /* 发送 START 只持 ch.mu：不同 VM 互不阻塞。锁序 = 先 g_mu 后 ch.mu；
         * 这里用内层作用域保证 ch.mu 先放、再取 g_mu 推进队列，避免反向嵌套。 */
        std::lock_guard<std::mutex> chLock(chp->mu);
        chp->proxy = proxy;
        chp->vmRunning = false;
        chp->attached = false;
        chp->surfaceId = req.surfaceId;

        OHIPCParcel *parcel = newRequest();
        OH_IPCParcel_WriteString(parcel, req.arch.c_str());
        OH_IPCParcel_WriteInt32(parcel, (int32_t)req.args.size());
        for (const auto &a : req.args) {
            OH_IPCParcel_WriteString(parcel, a.c_str());
        }
        OHNativeWindow *win = windowFromSurfaceId(req.surfaceId);
        int32_t childRet = -1;
        if (win != nullptr) {
            OH_NativeWindow_WriteToParcel(win, parcel);
            childRet = replyCode(sendTo(*chp, kStart, parcel));
            OH_NativeWindow_DestroyNativeWindow(win);
        }
        OH_LOG_INFO(LOG_APP, "START %{public}s vm=%{public}s → child ret=%{public}d",
                    req.arch.c_str(), req.vmId.c_str(), childRet);
        if (childRet == 0) {
            chp->vmRunning = true;
            chp->attached = true;
            /* TEMP 探针：START 成功 6s 后父进程试读子进程 /proc（结论入 spec 后移除） */
            std::thread([]() {
                usleep(6 * 1000 * 1000);
                procProbeParent();
            }).detach();
        } else {
            /* VM 没起来：让子进程退出，别留着空转 */
            OHIPCParcel *sd = newRequest();
            replyCode(sendTo(*chp, kShutdown, sd));
            if (sd) {
                OH_IPCParcel_Destroy(sd);
            }
            if (chp->proxy) {
                OH_IPCRemoteProxy_Destroy(chp->proxy);
                chp->proxy = nullptr;
            }
            chp->attached = false;
        }
        OH_IPCParcel_Destroy(parcel);
    }

    std::lock_guard<std::mutex> lock(g_mu);
    spawnNextLocked();
}

/* 调用方须持有 g_mu。 */
void spawnNextLocked()
{
    if (g_pending.empty()) {
        g_spawnInFlight = false;
        return;
    }
    g_spawnInFlight = true;
    int ret = OH_Ability_CreateNativeChildProcess(kChildLib, onChildStarted);
    OH_LOG_INFO(LOG_APP, "CreateNativeChildProcess vm=%{public}s ret=%{public}d",
                g_pending.front().vmId.c_str(), ret);
    if (ret != NCP_NO_ERROR) {
        /* 拉起即失败：丢掉这条，继续后面的 */
        OH_LOG_ERROR(LOG_APP, "spawn %{public}s rejected ret=%{public}d",
                     g_pending.front().vmId.c_str(), ret);
        g_pending.pop_front();
        spawnNextLocked();
    }
}

/* 状态清理（proxy 已空或 VM 已结束）；调用方须持 ch.mu */
void cleanupLocked(ChildState &ch)
{
    if (ch.proxy != nullptr) {
        OH_IPCRemoteProxy_Destroy(ch.proxy);
        ch.proxy = nullptr;
    }
    ch.vmRunning = false;
    ch.attached = false;
}

} // namespace

int ncp_client_start(const std::string &vmId, const std::string &arch,
                     const std::vector<std::string> &args, int64_t surfaceId)
{
    ensureExitCallback();
    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_children.find(vmId);
    if (it != g_children.end() && (it->second.proxy != nullptr || it->second.vmRunning)) {
        OH_LOG_WARN(LOG_APP, "qemu child already active vm=%{public}s", vmId.c_str());
        return -1;
    }
    for (const auto &p : g_pending) {
        if (p.vmId == vmId) {
            return -1; /* 已在拉起队列里 */
        }
    }
    g_pending.push_back({vmId, arch, args, surfaceId});
    if (!g_spawnInFlight) {
        spawnNextLocked();
    }
    return 0;
}

int ncp_client_attach(const std::string &vmId, int64_t surfaceId)
{
    ChildState *chp = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        chp = createChildLocked(vmId);
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    chp->surfaceId = surfaceId;
    if (chp->proxy == nullptr || !chp->vmRunning || chp->attached) {
        return 0; /* 无子进程（VM 未启动）或已挂窗：START 会带上窗口 */
    }
    OHNativeWindow *win = windowFromSurfaceId(surfaceId);
    if (win == nullptr) {
        return -1;
    }
    OHIPCParcel *req = newRequest();
    OH_NativeWindow_WriteToParcel(win, req);
    int32_t childRet = replyCode(sendTo(*chp, kAttachSurface, req));
    OH_IPCParcel_Destroy(req);
    OH_NativeWindow_DestroyNativeWindow(win);
    OH_LOG_INFO(LOG_APP, "attach vm=%{public}s → child ret=%{public}d", vmId.c_str(), childRet);
    if (childRet == 0) {
        chp->attached = true;
    }
    return childRet;
}

void ncp_client_detach(const std::string &vmId)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr || !chp->attached) {
        return;
    }
    OHIPCParcel *req = newRequest();
    replyCode(sendTo(*chp, kDetachSurface, req));
    OH_IPCParcel_Destroy(req);
    chp->attached = false;
}

void ncp_client_resize(const std::string &vmId, int32_t w, int32_t h)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr || !chp->attached) {
        return;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, w);
    OH_IPCParcel_WriteInt32(req, h);
    replyCode(sendTo(*chp, kResizeSurface, req));
    OH_IPCParcel_Destroy(req);
}

void ncp_client_pointer(const std::string &vmId, int32_t x, int32_t y, int32_t buttons)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr || !chp->vmRunning) {
        return;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, x);
    OH_IPCParcel_WriteInt32(req, y);
    OH_IPCParcel_WriteInt32(req, buttons);
    replyCode(sendTo(*chp, kPointer, req));
    OH_IPCParcel_Destroy(req);
}

void ncp_client_key(const std::string &vmId, int32_t qcode, bool down)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr || !chp->vmRunning) {
        return;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, qcode);
    OH_IPCParcel_WriteInt32(req, down ? 1 : 0);
    replyCode(sendTo(*chp, kKey, req));
    OH_IPCParcel_Destroy(req);
}

void ncp_client_scroll(const std::string &vmId, int32_t dx, int32_t dy)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr || !chp->vmRunning) {
        return;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, dx);
    OH_IPCParcel_WriteInt32(req, dy);
    replyCode(sendTo(*chp, kScroll, req));
    OH_IPCParcel_Destroy(req);
}

bool ncp_client_running(const std::string &vmId)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr || !chp->vmRunning) {
        return false;
    }
    /* 自愈：exit 回调未必可靠，主动向子进程 QUERY；子进程已死（发送失败）
     * 或 VM 已退出（running=0）就清理状态 */
    OHIPCParcel *req = newRequest();
    OHIPCParcel *reply = sendTo(*chp, kQuery, req);
    OH_IPCParcel_Destroy(req);
    int32_t running = -1;
    if (reply != nullptr) {
        int32_t ver = 0, w = 0, h = 0;
        OH_IPCParcel_ReadInt32(reply, &ver);
        OH_IPCParcel_ReadInt32(reply, &w);
        OH_IPCParcel_ReadInt32(reply, &h);
        OH_IPCParcel_ReadInt32(reply, &running);
        OH_IPCParcel_Destroy(reply);
    }
    if (running == 1) {
        return true;
    }
    OH_LOG_INFO(LOG_APP, "qemu child no longer running vm=%{public}s (query %{public}s), cleanup",
                vmId.c_str(), reply != nullptr ? "replied 0" : "failed");
    cleanupLocked(*chp);
    return false;
}

int ncp_client_query_display(const std::string &vmId, int *w, int *h)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return -1;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr) {
        return -1;
    }
    OHIPCParcel *req = newRequest();
    OHIPCParcel *reply = sendTo(*chp, kQuery, req);
    OH_IPCParcel_Destroy(req);
    if (reply == nullptr) {
        return -1;
    }
    int32_t ver = 0;
    OH_IPCParcel_ReadInt32(reply, &ver);
    OH_IPCParcel_ReadInt32(reply, w);
    OH_IPCParcel_ReadInt32(reply, h);
    int32_t running = 0;
    OH_IPCParcel_ReadInt32(reply, &running);
    OH_IPCParcel_Destroy(reply);
    return 0;
}

int ncp_client_screenshot(const std::string &vmId, int maxW, const std::string &path,
                          int *w, int *h)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return -1;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr) {
        return -1;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, maxW);
    OH_IPCParcel_WriteString(req, path.c_str());
    OHIPCParcel *reply = sendTo(*chp, kScreenshot, req);
    OH_IPCParcel_Destroy(req);
    if (reply == nullptr) {
        return -1;
    }
    int32_t ver = 0;
    OH_IPCParcel_ReadInt32(reply, &ver);
    OH_IPCParcel_ReadInt32(reply, w);
    OH_IPCParcel_ReadInt32(reply, h);
    int32_t written = 0;
    OH_IPCParcel_ReadInt32(reply, &written);
    OH_IPCParcel_Destroy(reply);
    if (*w <= 0 || *h <= 0 || !written) {
        *w = 0;
        *h = 0;
        return -1;
    }
    return 0;
}

void ncp_client_shutdown(const std::string &vmId)
{
    ChildState *chp = getChild(vmId);
    if (chp == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr) {
        return;
    }
    OHIPCParcel *req = newRequest();
    replyCode(sendTo(*chp, kShutdown, req));
    OH_IPCParcel_Destroy(req);
    /* 不在这里清状态：等下一次 QUERY 自愈清，避免重用已销毁 proxy */
}
