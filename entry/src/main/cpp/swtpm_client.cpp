/* swtpm NCP 子进程的父进程侧 IPC 客户端（独立于 ncp_client 的 qemu 子进程管理）。
 * 复用 qemu_ipc 的 kStart/kQuery/kShutdown/kProtoVersion；descriptor = kSwtpmDescriptor。 */
#include "swtpm_client.h"
#include "qemu_ipc.h"

#include <AbilityKit/native_child_process.h>
#include <IPCKit/ipc_cremote_object.h>
#include <IPCKit/ipc_cparcel.h>
#include <IPCKit/ipc_error_code.h>
#include <hilog/log.h>

#include <deque>
#include <map>
#include <mutex>
#include <string>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0007
#define LOG_TAG "QemuNapi"

namespace {

using namespace qemu_ipc;

struct SwtpmState {
    std::mutex mu;
    OHIPCRemoteProxy *proxy = nullptr;
    bool running = false;
};

struct StartReq {
    std::string vmId;
    std::string tpmDir;
    std::string ctrlSock;
    std::string logPath;
};

std::mutex g_mu;
std::map<std::string, SwtpmState> g_states;
std::deque<StartReq> g_pending;
bool g_inFlight = false;

SwtpmState *getState(const std::string &vmId)
{
    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_states.find(vmId);
    return it == g_states.end() ? nullptr : &it->second;
}

SwtpmState *createStateLocked(const std::string &vmId)
{
    return &g_states[vmId];
}

OHIPCParcel *newRequest()
{
    OHIPCParcel *req = OH_IPCParcel_Create();
    if (req) {
        OH_IPCParcel_WriteInt32(req, kProtoVersion);
    }
    return req;
}

/* 调用方须持有 ch.mu。返回 reply（调用方负责 Destroy），失败返回 nullptr。 */
OHIPCParcel *sendTo(SwtpmState &ch, uint32_t code, OHIPCParcel *req)
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
        OH_LOG_ERROR(LOG_APP, "swtpm ipc code=%{public}u failed ret=%{public}d", code, ret);
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

void spawnNextSwtpmLocked(); /* 前向声明；调用方须持 g_mu */

void onSwtpmStarted(int errCode, OHIPCRemoteProxy *proxy)
{
    StartReq req;
    SwtpmState *chp = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_pending.empty()) {
            OH_LOG_ERROR(LOG_APP, "swtpm child started but no pending req, drop proxy");
            if (proxy) {
                OH_IPCRemoteProxy_Destroy(proxy);
            }
            g_inFlight = false;
            return;
        }
        req = std::move(g_pending.front());
        g_pending.pop_front();
        if (errCode != NCP_NO_ERROR || proxy == nullptr) {
            OH_LOG_ERROR(LOG_APP, "swtpm child start failed errCode=%{public}d vm=%{public}s",
                         errCode, req.vmId.c_str());
            spawnNextSwtpmLocked();
            return;
        }
        chp = createStateLocked(req.vmId);
    }

    {
        std::lock_guard<std::mutex> chLock(chp->mu);
        chp->proxy = proxy;
        chp->running = false;
        OHIPCParcel *parcel = newRequest();
        OH_IPCParcel_WriteString(parcel, req.tpmDir.c_str());
        OH_IPCParcel_WriteString(parcel, req.ctrlSock.c_str());
        OH_IPCParcel_WriteString(parcel, req.logPath.c_str());
        int32_t childRet = replyCode(sendTo(*chp, kStart, parcel));
        OH_IPCParcel_Destroy(parcel);
        OH_LOG_INFO(LOG_APP, "swtpm START vm=%{public}s → child ret=%{public}d",
                    req.vmId.c_str(), childRet);
        if (childRet == 0) {
            chp->running = true;
        } else {
            if (chp->proxy) {
                OH_IPCRemoteProxy_Destroy(chp->proxy);
                chp->proxy = nullptr;
            }
            chp->running = false;
        }
    }

    std::lock_guard<std::mutex> lock(g_mu);
    spawnNextSwtpmLocked();
}

/* 调用方须持有 g_mu。 */
void spawnNextSwtpmLocked()
{
    if (g_pending.empty()) {
        g_inFlight = false;
        return;
    }
    g_inFlight = true;
    int ret = OH_Ability_CreateNativeChildProcess(kSwtpmChildLib, onSwtpmStarted);
    OH_LOG_INFO(LOG_APP, "CreateNativeChildProcess swtpm vm=%{public}s ret=%{public}d",
                g_pending.front().vmId.c_str(), ret);
    if (ret != NCP_NO_ERROR) {
        OH_LOG_ERROR(LOG_APP, "spawn swtpm %{public}s rejected ret=%{public}d",
                     g_pending.front().vmId.c_str(), ret);
        g_pending.pop_front();
        spawnNextSwtpmLocked();
    }
}

} // namespace

int swtpm_client_start(const std::string &vmId, const std::string &tpmDir,
                       const std::string &ctrlSock, const std::string &logPath)
{
    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_states.find(vmId);
    if (it != g_states.end() && (it->second.proxy != nullptr || it->second.running)) {
        OH_LOG_WARN(LOG_APP, "swtpm child already active vm=%{public}s", vmId.c_str());
        return -1;
    }
    for (const auto &p : g_pending) {
        if (p.vmId == vmId) {
            return -1; /* 已在拉起队列里 */
        }
    }
    g_pending.push_back({vmId, tpmDir, ctrlSock, logPath});
    if (!g_inFlight) {
        spawnNextSwtpmLocked();
    }
    return 0;
}

void swtpm_client_shutdown(const std::string &vmId)
{
    SwtpmState *chp = getState(vmId);
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
    OH_LOG_INFO(LOG_APP, "swtpm shutdown vm=%{public}s sent", vmId.c_str());
    /* 不在此清理：等下一次 RUNNING/QUERY 自愈清，避免重用已销毁 proxy */
}

bool swtpm_client_running(const std::string &vmId)
{
    SwtpmState *chp = getState(vmId);
    if (chp == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> chLock(chp->mu);
    if (chp->proxy == nullptr || !chp->running) {
        return false;
    }
    OHIPCParcel *req = newRequest();
    OHIPCParcel *reply = sendTo(*chp, kQuery, req);
    OH_IPCParcel_Destroy(req);
    int32_t running = -1;
    if (reply != nullptr) {
        int32_t ver = 0;
        OH_IPCParcel_ReadInt32(reply, &ver);
        OH_IPCParcel_ReadInt32(reply, &running);
        OH_IPCParcel_Destroy(reply);
    }
    if (running == 1) {
        return true;
    }
    OH_LOG_INFO(LOG_APP, "swtpm child no longer running vm=%{public}s (query %{public}d), cleanup",
                vmId.c_str(), running);
    if (chp->proxy) {
        OH_IPCRemoteProxy_Destroy(chp->proxy);
        chp->proxy = nullptr;
    }
    chp->running = false;
    return false;
}
