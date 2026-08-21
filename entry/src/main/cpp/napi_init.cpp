#include "napi/native_api.h"
#include "vm.h"
#include "renderer.h"
#include "input.h"
#include "fb.h"
#include "qmp.h"

#include <fcntl.h>
#include <hilog/log.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0007
#define LOG_TAG "QemuNapi"

/* startVm(arch: string, args: string[]): number */
static napi_value StartVm(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char archBuf[32] = {0};
    size_t archLen = 0;
    napi_get_value_string_utf8(env, args[0], archBuf, sizeof(archBuf) - 1, &archLen);

    std::vector<std::string> argList;
    uint32_t arrLen = 0;
    napi_get_array_length(env, args[1], &arrLen);
    for (uint32_t i = 0; i < arrLen; i++) {
        napi_value el = nullptr;
        napi_get_element(env, args[1], i, &el);
        size_t len = 0;
        napi_get_value_string_utf8(env, el, nullptr, 0, &len);
        std::string s(len, '\0');
        napi_get_value_string_utf8(env, el, &s[0], len + 1, &len);
        argList.push_back(std::move(s));
    }

    int ret = vm_start(archBuf, argList);
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/* vmRunning(): boolean */
static napi_value VmRunning(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_get_boolean(env, vm_running(), &result);
    return result;
}

/* vmSpent(): boolean — true 后必须重启进程才能再跑 VM */
static napi_value VmSpent(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_get_boolean(env, vm_spent(), &result);
    return result;
}

/* createSurface(surfaceId: bigint): number */
static napi_value CreateSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t surfaceId = 0;
    bool lossless = false;
    napi_get_value_bigint_int64(env, args[0], &surfaceId, &lossless);

    int ret = renderer_create_surface(surfaceId);
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/* resizeSurface(surfaceId: bigint, w: number, h: number): number */
static napi_value ResizeSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t surfaceId = 0;
    bool lossless = false;
    napi_get_value_bigint_int64(env, args[0], &surfaceId, &lossless);
    int32_t w = 0, h = 0;
    napi_get_value_int32(env, args[1], &w);
    napi_get_value_int32(env, args[2], &h);

    int ret = renderer_resize_surface(surfaceId, w, h);
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/* destroySurface(surfaceId: bigint): number */
static napi_value DestroySurface(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t surfaceId = 0;
    bool lossless = false;
    napi_get_value_bigint_int64(env, args[0], &surfaceId, &lossless);

    int ret = renderer_destroy_surface(surfaceId);
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/* sendPointer(x: number, y: number, buttons: number) */
static napi_value SendPointer(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t x = 0, y = 0, buttons = 0;
    napi_get_value_int32(env, args[0], &x);
    napi_get_value_int32(env, args[1], &y);
    napi_get_value_int32(env, args[2], &buttons);
    input_send_pointer(x, y, buttons);
    return nullptr;
}

/* sendKey(qcode: number, down: boolean) */
static napi_value SendKey(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t qcode = 0;
    bool down = false;
    napi_get_value_int32(env, args[0], &qcode);
    napi_get_value_bool(env, args[1], &down);
    input_send_key(qcode, down);
    return nullptr;
}

/* qmpConnect(port: number): number */
static napi_value QmpConnect(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t port = 0;
    napi_get_value_int32(env, args[0], &port);

    int ret = qmp_connect(port);
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/* qmpCommand(cmd: string): string — raw JSON response, "" on failure */
static napi_value QmpCommand(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string cmd(len, '\0');
    napi_get_value_string_utf8(env, args[0], &cmd[0], len + 1, &len);

    std::string resp = qmp_command(cmd);
    napi_value result;
    napi_create_string_utf8(env, resp.c_str(), resp.size(), &result);
    return result;
}

/* qmpDisconnect() */
static napi_value QmpDisconnect(napi_env env, napi_callback_info info)
{
    qmp_disconnect();
    return nullptr;
}

/* qmpConnected(): boolean */
static napi_value QmpConnected(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_get_boolean(env, qmp_connected(), &result);
    return result;
}

/* setQmpEventCallback(cb: ((evt: string) => void) | null) */
static napi_value SetQmpEventCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    qmp_set_event_callback(env, type == napi_function ? args[0] : nullptr);
    return nullptr;
}

/* captureScreen(): { width, height, pixels: ArrayBuffer(RGBA_8888) } | null */
static napi_value CaptureScreen(napi_env env, napi_callback_info info)
{
    std::lock_guard<std::mutex> lk(g_fb.mu);
    if (g_fb.w <= 0 || g_fb.h <= 0 || g_fb.back.empty()) {
        napi_value result;
        napi_get_null(env, &result);
        return result;
    }
    size_t npix = g_fb.back.size();
    void *data = nullptr;
    napi_value buffer;
    napi_create_arraybuffer(env, npix * sizeof(uint32_t), &data, &buffer);
    /* back is X8R8G8B8; ArkTS PixelMap wants RGBA_8888: swap R/B, force A=0xff */
    const uint32_t *src = g_fb.back.data();
    uint32_t *dst = static_cast<uint32_t *>(data);
    for (size_t i = 0; i < npix; i++) {
        uint32_t p = src[i];
        dst[i] = 0xff000000u | (p & 0x0000ff00u) | ((p >> 16) & 0xffu) | ((p & 0xffu) << 16);
    }

    napi_value result;
    napi_create_object(env, &result);
    napi_value w, h;
    napi_create_int32(env, g_fb.w, &w);
    napi_create_int32(env, g_fb.h, &h);
    napi_set_named_property(env, result, "width", w);
    napi_set_named_property(env, result, "height", h);
    napi_set_named_property(env, result, "pixels", buffer);
    return result;
}

/* createDisk(path: string, sizeMB: number): number — sparse raw image */
static napi_value CreateDisk(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string path(len, '\0');
    napi_get_value_string_utf8(env, args[0], &path[0], len + 1, &len);
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
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "startVm", nullptr, StartVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "vmRunning", nullptr, VmRunning, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "vmSpent", nullptr, VmSpent, nullptr, nullptr, nullptr, napi_default, nullptr },
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
