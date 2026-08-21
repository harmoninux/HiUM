#include "ncp_client.h"
#include "qemu_ipc.h"

#include <native_window/external_window.h>
#include <AbilityKit/native_child_process.h>
#include <IPCKit/ipc_cremote_object.h>
#include <IPCKit/ipc_cparcel.h>
#include <IPCKit/ipc_error_code.h>
#include <hilog/log.h>

#include <mutex>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0007
#define LOG_TAG "QemuNapi"

namespace {

using namespace qemu_ipc;

struct ChildState {
    std::mutex mu;
    OHIPCRemoteProxy *proxy = nullptr; /* 单实例：任何时刻最多一个子进程 */
    bool vmRunning = false;
    bool attached = false;
    std::string arch;
    std::vector<std::string> args;
    int64_t surfaceId = 0;
};
ChildState g_ch;

/* NCP 不给 pid↔proxy 对应关系；单实例设计下，任何子进程退出都视为当前 child */
void onChildExit(int32_t pid, int32_t signal)
{
    OH_LOG_INFO(LOG_APP, "child exit callback pid=%{public}d signal=%{public}d", pid, signal);
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy != nullptr) {
        OH_IPCRemoteProxy_Destroy(g_ch.proxy);
        g_ch.proxy = nullptr;
        g_ch.vmRunning = false;
        g_ch.attached = false;
    }
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

/* 调用方须持有 g_ch.mu。返回 reply parcel（调用方负责 Destroy），失败返回 nullptr。 */
OHIPCParcel *sendLocked(uint32_t code, OHIPCParcel *req)
{
    if (g_ch.proxy == nullptr || req == nullptr) {
        return nullptr;
    }
    OHIPCParcel *reply = OH_IPCParcel_Create();
    if (reply == nullptr) {
        return nullptr;
    }
    OH_IPC_MessageOption option = {OH_IPC_REQUEST_MODE_SYNC, 0, nullptr};
    int32_t ret = OH_IPCRemoteProxy_SendRequest(g_ch.proxy, code, req, reply, &option);
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

/* NCP 启动回调（独立线程）：发送 START（参数 + 窗口） */
void onChildStarted(int errCode, OHIPCRemoteProxy *proxy)
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (errCode != NCP_NO_ERROR || proxy == nullptr) {
        OH_LOG_ERROR(LOG_APP, "child start failed errCode=%{public}d", errCode);
        g_ch.proxy = nullptr;
        g_ch.vmRunning = false;
        return;
    }
    g_ch.proxy = proxy;

    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteString(req, g_ch.arch.c_str());
    OH_IPCParcel_WriteInt32(req, (int32_t)g_ch.args.size());
    for (const auto &a : g_ch.args) {
        OH_IPCParcel_WriteString(req, a.c_str());
    }
    OHNativeWindow *win = windowFromSurfaceId(g_ch.surfaceId);
    int32_t childRet = -1;
    if (win != nullptr) {
        OH_NativeWindow_WriteToParcel(win, req);
        childRet = replyCode(sendLocked(kStart, req));
        OH_NativeWindow_DestroyNativeWindow(win);
    }
    OH_LOG_INFO(LOG_APP, "START %{public}s → child ret=%{public}d", g_ch.arch.c_str(), childRet);
    if (childRet == 0) {
        g_ch.vmRunning = true;
        g_ch.attached = true;
    } else {
        /* VM 没起来：让子进程退出，别留着空转 */
        OHIPCParcel *sd = newRequest();
        replyCode(sendLocked(kShutdown, sd));
        if (sd) {
            OH_IPCParcel_Destroy(sd);
        }
        OH_IPCRemoteProxy_Destroy(g_ch.proxy);
        g_ch.proxy = nullptr;
        g_ch.vmRunning = false;
        g_ch.attached = false;
    }
    OH_IPCParcel_Destroy(req);
}

/* 状态清理（proxy 已空或 VM 已结束）；调用方持锁 */
void cleanupLocked()
{
    if (g_ch.proxy != nullptr) {
        OH_IPCRemoteProxy_Destroy(g_ch.proxy);
        g_ch.proxy = nullptr;
    }
    g_ch.vmRunning = false;
    g_ch.attached = false;
}

} // namespace

int ncp_client_start(const std::string &arch, const std::vector<std::string> &args,
                     int64_t surfaceId)
{
    ensureExitCallback();
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy != nullptr || g_ch.vmRunning) {
        OH_LOG_WARN(LOG_APP, "qemu child already active");
        return -1;
    }
    g_ch.arch = arch;
    g_ch.args = args;
    g_ch.surfaceId = surfaceId;
    int ret = OH_Ability_CreateNativeChildProcess(kChildLib, onChildStarted);
    OH_LOG_INFO(LOG_APP, "CreateNativeChildProcess ret=%{public}d", ret);
    return ret;
}

int ncp_client_attach(int64_t surfaceId)
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    g_ch.surfaceId = surfaceId;
    if (g_ch.proxy == nullptr || !g_ch.vmRunning || g_ch.attached) {
        return 0; /* 无子进程（VM 未启动）或已挂窗：START 会带上窗口 */
    }
    OHNativeWindow *win = windowFromSurfaceId(surfaceId);
    if (win == nullptr) {
        return -1;
    }
    OHIPCParcel *req = newRequest();
    OH_NativeWindow_WriteToParcel(win, req);
    int32_t childRet = replyCode(sendLocked(kAttachSurface, req));
    OH_IPCParcel_Destroy(req);
    OH_NativeWindow_DestroyNativeWindow(win);
    OH_LOG_INFO(LOG_APP, "attach surface → child ret=%{public}d", childRet);
    if (childRet == 0) {
        g_ch.attached = true;
    }
    return childRet;
}

void ncp_client_detach()
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr || !g_ch.attached) {
        return;
    }
    OHIPCParcel *req = newRequest();
    replyCode(sendLocked(kDetachSurface, req));
    OH_IPCParcel_Destroy(req);
    g_ch.attached = false;
}

void ncp_client_resize(int32_t w, int32_t h)
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr || !g_ch.attached) {
        return;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, w);
    OH_IPCParcel_WriteInt32(req, h);
    replyCode(sendLocked(kResizeSurface, req));
    OH_IPCParcel_Destroy(req);
}

void ncp_client_pointer(int32_t x, int32_t y, int32_t buttons)
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr || !g_ch.vmRunning) {
        return;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, x);
    OH_IPCParcel_WriteInt32(req, y);
    OH_IPCParcel_WriteInt32(req, buttons);
    replyCode(sendLocked(kPointer, req));
    OH_IPCParcel_Destroy(req);
}

void ncp_client_key(int32_t qcode, bool down)
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr || !g_ch.vmRunning) {
        return;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, qcode);
    OH_IPCParcel_WriteInt32(req, down ? 1 : 0);
    replyCode(sendLocked(kKey, req));
    OH_IPCParcel_Destroy(req);
}

bool ncp_client_running()
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr || !g_ch.vmRunning) {
        return false;
    }
    /* 自愈：exit 回调未必可靠（实测有不触发的情况），主动向子进程 QUERY；
     * 子进程已死（发送失败）或 VM 已退出（running=0）就清理状态 */
    OHIPCParcel *req = newRequest();
    OHIPCParcel *reply = sendLocked(kQuery, req);
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
    OH_LOG_INFO(LOG_APP, "qemu child no longer running (query %{public}s), cleanup",
                reply != nullptr ? "replied 0" : "failed");
    cleanupLocked();
    return false;
}

int ncp_client_query_display(int *w, int *h)
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr) {
        return -1;
    }
    OHIPCParcel *req = newRequest();
    OHIPCParcel *reply = sendLocked(kQuery, req);
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

int ncp_client_screenshot(int maxW, int *w, int *h, std::vector<uint8_t> &pixels)
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr) {
        return -1;
    }
    OHIPCParcel *req = newRequest();
    OH_IPCParcel_WriteInt32(req, maxW);
    OHIPCParcel *reply = sendLocked(kScreenshot, req);
    OH_IPCParcel_Destroy(req);
    if (reply == nullptr) {
        return -1;
    }
    int32_t ver = 0;
    OH_IPCParcel_ReadInt32(reply, &ver);
    OH_IPCParcel_ReadInt32(reply, w);
    OH_IPCParcel_ReadInt32(reply, h);
    if (*w > 0 && *h > 0) {
        int32_t expect = (*w) * (*h) * 4;
        const uint8_t *buf = OH_IPCParcel_ReadBuffer(reply, expect); /* len 不符返回 nullptr */
        if (buf != nullptr) {
            pixels.assign(buf, buf + expect);
        } else {
            *w = 0;
            *h = 0;
        }
    }
    OH_IPCParcel_Destroy(reply);
    return pixels.empty() ? -1 : 0;
}

void ncp_client_shutdown()
{
    std::lock_guard<std::mutex> lock(g_ch.mu);
    if (g_ch.proxy == nullptr) {
        return;
    }
    OHIPCParcel *req = newRequest();
    replyCode(sendLocked(kShutdown, req));
    OH_IPCParcel_Destroy(req);
    /* 不在这里清状态：等 onChildExit 回调清，避免重用已销毁 proxy */
}
