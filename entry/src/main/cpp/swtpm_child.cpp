/* swtpm 子进程入口：由父进程 OH_Ability_CreateNativeChildProcess("libswtpm_child.so")
 * 拉起。导出 NativeChildProcess_OnConnect（IPC stub）与
 * NativeChildProcess_MainProc（dlopen libswtpm.so 并前台跑 swtpm_entry 主循环，
 * 收到 kShutdown 时 SIGTERM 触发 swtpm 内建处理优雅退出）。
 * swtpm 与 qemu 各自一个 NCP 子进程，二者靠 <vmDataDir>/swtpm-<id>.sock unix socket 对接。 */
#include "qemu_ipc.h"

#include <AbilityKit/native_child_process.h>
#include <IPCKit/ipc_cremote_object.h>
#include <IPCKit/ipc_cparcel.h>
#include <IPCKit/ipc_error_code.h>
#include <hilog/log.h>

#include <dlfcn.h>
#include <unistd.h>
#include <signal.h>
#include <atomic>
#include <string>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0006
#define LOG_TAG "QemuSwtpmChild"

namespace {

using namespace qemu_ipc;

std::atomic<bool> g_quit{false};
std::string g_tpmDir;     /* tpmstate dir */
std::string g_ctrlSock;   /* unix ctrl socket（qemu -tpmdev 连接目标） */
std::string g_logPath;    /* swtpm --log file */

/* libswtpm.so 导出的入口（等价 qemu 的 qemu_system_entry） */
typedef int (*swtpm_entry_fn)(int argc, char **argv);

int replyInt(OHIPCParcel *reply, int32_t v)
{
    return reply ? OH_IPCParcel_WriteInt32(reply, v) : OH_IPC_CHECK_PARAM_ERROR;
}

/* START: [ver][tpmDir][ctrlSock][logPath]（三字符串，与 qemu_child 的 START 布局不同，通道独立） */
int32_t onStart(const OHIPCParcel *data)
{
    const char *tpmDir = OH_IPCParcel_ReadString(data);
    const char *ctrlSock = OH_IPCParcel_ReadString(data);
    const char *logPath = OH_IPCParcel_ReadString(data);
    if (tpmDir == nullptr || ctrlSock == nullptr || logPath == nullptr) {
        OH_LOG_ERROR(LOG_APP, "swtpm child: bad START payload");
        return -2;
    }
    g_tpmDir = tpmDir;
    g_ctrlSock = ctrlSock;
    g_logPath = logPath;
    OH_LOG_INFO(LOG_APP, "swtpm child: START tpmdir=%{public}s sock=%{public}s log=%{public}s",
                g_tpmDir.c_str(), g_ctrlSock.c_str(), g_logPath.c_str());
    return 0;
}

int onRequest(uint32_t code, const OHIPCParcel *data, OHIPCParcel *reply, void *userData)
{
    int32_t version = 0;
    if (data == nullptr || OH_IPCParcel_ReadInt32(data, &version) != OH_IPC_SUCCESS ||
        version != kProtoVersion) {
        OH_LOG_ERROR(LOG_APP, "swtpm child: bad request code=%{public}u version=%{public}d", code, version);
        return replyInt(reply, -1);
    }
    switch (code) {
        case kStart:
            return replyInt(reply, onStart(data));
        case kQuery:
            /* alive if it answers; reply [ver][running] */
            if (reply) {
                OH_IPCParcel_WriteInt32(reply, kProtoVersion);
                OH_IPCParcel_WriteInt32(reply, g_quit.load() ? 0 : 1);
            }
            return 0;
        case kShutdown:
            replyInt(reply, 0);
            OH_LOG_INFO(LOG_APP, "swtpm child: shutdown requested, SIGTERM to exit swtpm");
            g_quit.store(true);
            kill(getpid(), SIGTERM); /* 触发 swtpm 内建 SIGTERM handler，让 swtpm_entry 返回 */
            return 0;
        default:
            return replyInt(reply, -6);
    }
}

void onStubDestroy(void *userData)
{
    OH_LOG_INFO(LOG_APP, "swtpm child: IPC stub destroyed (parent gone?), quitting");
    g_quit.store(true);
    kill(getpid(), SIGTERM);
}

} // namespace

extern "C" __attribute__((visibility("default"))) OHIPCRemoteStub *NativeChildProcess_OnConnect()
{
    OHIPCRemoteStub *stub = OH_IPCRemoteStub_Create(kSwtpmDescriptor, onRequest, onStubDestroy, nullptr);
    OH_LOG_INFO(LOG_APP, "swtpm child: OnConnect stub=%{public}s pid=%{public}d",
                stub ? "ok" : "null", getpid());
    return stub;
}

extern "C" __attribute__((visibility("default"))) void NativeChildProcess_MainProc()
{
    OH_LOG_INFO(LOG_APP, "swtpm child: MainProc entered pid=%{public}d", getpid());
    void *so = dlopen("libswtpm.so", RTLD_NOW | RTLD_LOCAL);
    if (so == nullptr) {
        OH_LOG_ERROR(LOG_APP, "swtpm child: dlopen libswtpm.so failed: %{public}s", dlerror());
        _exit(127);
    }
    swtpm_entry_fn entry = (swtpm_entry_fn)dlsym(so, "swtpm_entry");
    if (entry == nullptr) {
        OH_LOG_ERROR(LOG_APP, "swtpm child: dlsym swtpm_entry failed: %{public}s", dlerror());
        _exit(127);
    }
    OH_LOG_INFO(LOG_APP, "swtpm child: dlopen+entry ok, running swtpm_entry foreground");

    std::string tpmStateArg = "dir=" + g_tpmDir;
    std::string ctrlArg = "type=unixio,path=" + g_ctrlSock;
    std::string logArg = "file=" + g_logPath;
    char *argv[] = { (char *)"swtpm", (char *)"socket", (char *)"--tpm2",
                     (char *)"--tpmstate", (char *)tpmStateArg.c_str(),
                     (char *)"--ctrl", (char *)ctrlArg.c_str(),
                     (char *)"--log", (char *)logArg.c_str(), nullptr };

    std::atomic<bool> done{false};
    std::thread t([&]() {
        int rc = entry(9, argv);
        OH_LOG_INFO(LOG_APP, "swtpm_entry exited rc=%{public}d", rc);
        done.store(true);
    });

    /* Swtpm_entry 阻塞在 socket 主循环，正常退出由 kShutdown 的 SIGTERM 触发。
     * 主循环：等 swtpm 自然退出；收到退出请求(SIGTERM)后给宽限；超时则 _exit 兜底。 */
    bool forced = false;
    int waited = 0;
    const int kHardLimitMs = 30000;
    while (!done.load()) {
        if (!forced && g_quit.load()) {
            forced = true;
            kill(getpid(), SIGTERM); /* 幂等：再次确保 SIGTERM 下发 */
        }
        usleep(50 * 1000);
        waited += 50;
        if (waited > kHardLimitMs) {
            OH_LOG_ERROR(LOG_APP, "swtpm child: swtpm_entry stuck, _exit(0) force quit");
            t.detach();
            _exit(0);
        }
    }
    if (t.joinable()) {
        t.join();
    }
    OH_LOG_INFO(LOG_APP, "swtpm child: MainProc exiting");
}
