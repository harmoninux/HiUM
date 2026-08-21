/* napi 入口（父进程/ArkUI 侧）。VM 实际运行在 NCP 子进程（libqemu_child.so），
 * 本文件的 VM/渲染/输入绑定全部经 ncp_client 走 IPC；QMP 走 qemu 在子进程里
 * 监听的 unix socket（父进程直连，无需转发）。所有接口按 vmId 路由到对应实例。 */
#include "napi/native_api.h"
#include "ncp_client.h"
#include "qmp.h"

#include <fcntl.h>
#include <hilog/log.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <string>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0007
#define LOG_TAG "QemuNapi"

namespace {

std::string stringArg(napi_env env, napi_value arg)
{
    size_t len = 0;
    napi_get_value_string_utf8(env, arg, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, arg, &s[0], len + 1, &len);
    return s;
}

napi_value intResult(napi_env env, int v)
{
    napi_value result;
    napi_create_int32(env, v, &result);
    return result;
}

} // namespace

/* startVm(vmId: string, arch: string, args: string[], surfaceId: bigint): number
 * 拉起 NCP 子进程跑 VM（异步；结果经 vmRunning(vmId)/日志体现） */
static napi_value StartVm(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string vmId = stringArg(env, args[0]);
    std::string arch = stringArg(env, args[1]);

    std::vector<std::string> argList;
    uint32_t arrLen = 0;
    napi_get_array_length(env, args[2], &arrLen);
    for (uint32_t i = 0; i < arrLen; i++) {
        napi_value el = nullptr;
        napi_get_element(env, args[2], i, &el);
        argList.push_back(stringArg(env, el));
    }

    int64_t surfaceId = 0;
    bool lossless = false;
    napi_get_value_bigint_int64(env, args[3], &surfaceId, &lossless);

    return intResult(env, ncp_client_start(vmId, arch, argList, surfaceId));
}

/* vmRunning(vmId: string): boolean */
static napi_value VmRunning(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string vmId = stringArg(env, args[0]);

    napi_value result;
    napi_get_boolean(env, ncp_client_running(vmId), &result);
    return result;
}

/* createSurface(vmId: string, surfaceId: bigint): number —— 给活动子进程挂窗（或仅记录） */
static napi_value CreateSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string vmId = stringArg(env, args[0]);
    int64_t surfaceId = 0;
    bool lossless = false;
    napi_get_value_bigint_int64(env, args[1], &surfaceId, &lossless);

    return intResult(env, ncp_client_attach(vmId, surfaceId));
}

/* resizeSurface(vmId: string, w: number, h: number): number */
static napi_value ResizeSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string vmId = stringArg(env, args[0]);
    int32_t w = 0, h = 0;
    napi_get_value_int32(env, args[1], &w);
    napi_get_value_int32(env, args[2], &h);

    ncp_client_resize(vmId, w, h);
    return intResult(env, 0);
}

/* destroySurface(vmId: string): number —— Console 离开，子进程摘窗（VM 继续后台跑） */
static napi_value DestroySurface(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    ncp_client_detach(stringArg(env, args[0]));
    return intResult(env, 0);
}

/* sendPointer(vmId: string, x: number, y: number, buttons: number) */
static napi_value SendPointer(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string vmId = stringArg(env, args[0]);
    int32_t x = 0, y = 0, buttons = 0;
    napi_get_value_int32(env, args[1], &x);
    napi_get_value_int32(env, args[2], &y);
    napi_get_value_int32(env, args[3], &buttons);
    ncp_client_pointer(vmId, x, y, buttons);
    return nullptr;
}

/* sendKey(vmId: string, qcode: number, down: boolean) */
static napi_value SendKey(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string vmId = stringArg(env, args[0]);
    int32_t qcode = 0;
    bool down = false;
    napi_get_value_int32(env, args[1], &qcode);
    napi_get_value_bool(env, args[2], &down);
    ncp_client_key(vmId, qcode, down);
    return nullptr;
}

/* qmpConnect(vmId: string, sockPath: string): number */
static napi_value QmpConnect(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    return intResult(env, qmp_connect(stringArg(env, args[0]), stringArg(env, args[1])));
}

/* qmpCommand(vmId: string, cmd: string): string — raw JSON response, "" on failure */
static napi_value QmpCommand(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string resp = qmp_command(stringArg(env, args[0]), stringArg(env, args[1]));
    napi_value result;
    napi_create_string_utf8(env, resp.c_str(), resp.size(), &result);
    return result;
}

/* qmpDisconnect(vmId: string) */
static napi_value QmpDisconnect(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    qmp_disconnect(stringArg(env, args[0]));
    return nullptr;
}

/* qmpConnected(vmId: string): boolean */
static napi_value QmpConnected(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result;
    napi_get_boolean(env, qmp_connected(stringArg(env, args[0])), &result);
    return result;
}

/* setQmpEventCallback(vmId: string, cb: ((evt: string) => void) | null) */
static napi_value SetQmpEventCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string vmId = stringArg(env, args[0]);
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[1], &type);
    qmp_set_event_callback(vmId, env, type == napi_function ? args[1] : nullptr);
    return nullptr;
}

/* captureScreen(vmId: string): { width, height, pixels: ArrayBuffer(RGBA_8888) } | null
 * 子进程缩放到 ≤512 宽后回传（缩略图足够，且受 binder 事务大小限制） */
static napi_value CaptureScreen(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string vmId = stringArg(env, args[0]);

    int w = 0, h = 0;
    std::vector<uint8_t> pixels;
    if (ncp_client_screenshot(vmId, 512, &w, &h, pixels) != 0) {
        napi_value result;
        napi_get_null(env, &result);
        return result;
    }
    void *data = nullptr;
    napi_value buffer;
    napi_create_arraybuffer(env, pixels.size(), &data, &buffer);
    memcpy(data, pixels.data(), pixels.size());

    napi_value result;
    napi_create_object(env, &result);
    napi_value wv, hv;
    napi_create_int32(env, w, &wv);
    napi_create_int32(env, h, &hv);
    napi_set_named_property(env, result, "width", wv);
    napi_set_named_property(env, result, "height", hv);
    napi_set_named_property(env, result, "pixels", buffer);
    return result;
}

/* createDisk(path: string, sizeMB: number): number — sparse raw image */
static napi_value CreateDisk(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = stringArg(env, args[0]);
    int32_t sizeMB = 0;
    napi_get_value_int32(env, args[1], &sizeMB);

    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int ret = 0;
    if (fd < 0 || ftruncate(fd, (off_t)sizeMB * 1024 * 1024) != 0) {
        OH_LOG_ERROR(LOG_APP, "createDisk %{public}s failed: %{public}s", path.c_str(), strerror(errno));
        ret = -1;
    }
    if (fd >= 0) {
        close(fd);
    }
    return intResult(env, ret);
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "startVm", nullptr, StartVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "vmRunning", nullptr, VmRunning, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createSurface", nullptr, CreateSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resizeSurface", nullptr, ResizeSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "destroySurface", nullptr, DestroySurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendPointer", nullptr, SendPointer, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendKey", nullptr, SendKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpConnect", nullptr, QmpConnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpCommand", nullptr, QmpCommand, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpDisconnect", nullptr, QmpDisconnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpConnected", nullptr, QmpConnected, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setQmpEventCallback", nullptr, SetQmpEventCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "captureScreen", nullptr, CaptureScreen, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createDisk", nullptr, CreateDisk, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module entryModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&entryModule);
}
