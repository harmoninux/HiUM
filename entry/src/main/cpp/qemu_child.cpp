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
#include <unistd.h>
#include <atomic>
#include <string>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0005
#define LOG_TAG "QemuChild"

namespace {

using namespace qemu_ipc;

std::atomic<bool> g_quit{false};

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
    /* 子进程侧复刻关键设备组：确认 qemu 真正要跑的命令行（tpm/pflash/机器/显示）完整到达。 */
    {
        bool hasTpm = false, hasPflash = false, hasQmp = false, hasIso = false;
        for (const auto &a : args) {
            if (a.rfind("-tpmdev", 0) == 0) { hasTpm = true; }
            if (a.rfind("-drive", 0) == 0 && a.find("pflash") != std::string::npos) { hasPflash = true; }
            if (a == "-qmp") { hasQmp = true; }
            if (a.rfind("-device", 0) == 0 && a.find("usb-storage") != std::string::npos) { hasIso = true; }
        }
        OH_LOG_INFO(LOG_APP, "child: START arch=%{public}s argc=%{public}d tpm=%{public}d pflash=%{public}d qmp=%{public}d iso=%{public}d",
                    arch, argc, hasTpm ? 1 : 0, hasPflash ? 1 : 0, hasQmp ? 1 : 0, hasIso ? 1 : 0);
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
            int32_t maxW = 0;
            OH_IPCParcel_ReadInt32(data, &maxW);
            int w = 0, h = 0;
            std::vector<uint32_t> px = fb_capture_rgba(maxW > 0 ? maxW : 512, &w, &h);
            if (reply) {
                OH_IPCParcel_WriteInt32(reply, kProtoVersion);
                OH_IPCParcel_WriteInt32(reply, w);
                OH_IPCParcel_WriteInt32(reply, h);
                if (!px.empty()) {
                    OH_IPCParcel_WriteBuffer(reply, reinterpret_cast<const uint8_t *>(px.data()),
                                             static_cast<int32_t>(px.size() * sizeof(uint32_t)));
                }
            }
            return 0;
        }
        case kShutdown:
            replyInt(reply, 0);
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
    while (!g_quit.load()) {
        bool r = vm_running();
        if (r) {
            wasRunning = true;
        } else if (wasRunning) {
            break;
        }
        usleep(200 * 1000);
    }
    OH_LOG_INFO(LOG_APP, "child: MainProc exiting (wasRunning=%{public}d quit=%{public}d)",
                wasRunning ? 1 : 0, g_quit.load() ? 1 : 0);
    renderer_detach_window();
}
