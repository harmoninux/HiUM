#include "napi/native_api.h"
#include "vm.h"
#include "renderer.h"
#include "input.h"

#include <hilog/log.h>
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
