/* napi 入口（父进程/ArkUI 侧）。VM 实际运行在 NCP 子进程（libqemu_child.so），
 * 本文件的 VM/渲染/输入绑定全部经 ncp_client 走 IPC；QMP 走 qemu 在子进程里
 * 监听的 unix socket（父进程直连，无需转发）。所有接口按 vmId 路由到对应实例。 */
#include "napi/native_api.h"
#include "imgtool.h"
#include "ncp_client.h"
#include "qmp.h"
#include "swtpm.h"

#include <hilog/log.h>

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

/* startSwtpm(vmId: string, tpmDir: string, ctrlSock: string, logPath: string): number
 * 拉起 libswtpm_child.so 子进程（dlopen libswtpm.so + swtpm_entry），轮询 ctrlSock 就绪 */
static napi_value StartSwtpm(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string vmId = stringArg(env, args[0]);
    std::string dir = stringArg(env, args[1]);
    std::string ctrl = stringArg(env, args[2]);
    std::string log = stringArg(env, args[3]);
    int rc = swtpm_start(vmId, dir, ctrl, log, 5000);
    OH_LOG_INFO(LOG_APP, "startSwtpm vm=%{public}s rc=%{public}d sock=%{public}s tpmdir=%{public}s", vmId.c_str(), rc, ctrl.c_str(), dir.c_str());
    return intResult(env, rc);
}

/* stopSwtpm(vmId: string) */
static napi_value StopSwtpm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string vmId = stringArg(env, args[0]);
    swtpm_stop(vmId);
    OH_LOG_INFO(LOG_APP, "stopSwtpm vm=%{public}s done", vmId.c_str());
    return nullptr;
}

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

/* vmSnapshot(vmIds: string[]): { [vmId]: { running: boolean, w: number, h: number } }
 * VMRegistry 批量取运行态：一次聚合一组 vmId，供 ArkTS 反应式 runningMap 刷新，
 * 避免各页面各自轮询 napi.vmRunning。 */
static napi_value VmSnapshot(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result;
    napi_create_object(env, &result);

    uint32_t n = 0;
    napi_get_array_length(env, args[0], &n);
    for (uint32_t i = 0; i < n; i++) {
        napi_value el = nullptr;
        napi_get_element(env, args[0], i, &el);
        if (el == nullptr) {
            continue;
        }
        std::string vmId = stringArg(env, el);
        int w = 0, h = 0;
        bool running = ncp_client_running(vmId); /* 含自愈（子进程死则清理） */
        ncp_client_query_display(vmId, &w, &h);

        napi_value st;
        napi_create_object(env, &st);
        napi_value r, wv, hv;
        napi_get_boolean(env, running, &r);
        napi_create_int32(env, w, &wv);
        napi_create_int32(env, h, &hv);
        napi_set_named_property(env, st, "running", r);
        napi_set_named_property(env, st, "w", wv);
        napi_set_named_property(env, st, "h", hv);
        napi_set_named_property(env, result, vmId.c_str(), st);
    }
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

/* scroll(vmId: string, dx: number, dy: number) —— 滚轮步进（dy>0 下滚，dy<0 上滚） */
static napi_value Scroll(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string vmId = stringArg(env, args[0]);
    int32_t dx = 0, dy = 0;
    napi_get_value_int32(env, args[1], &dx);
    napi_get_value_int32(env, args[2], &dy);
    ncp_client_scroll(vmId, dx, dy);
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

/* createDisk(path: string, sizeMB: number, alloc?: 'dynamic' | 'fixed'): number
 * qemu-img create -f qcow2 [-o preallocation=off|falloc] <path> <sizeM>.
 * 默认动态分配（稀疏，省空间）；固定大小预留全部（falloc，快，免中途 ENOSPC）。
 * qemu_img_entry 不可再入 → 经 imgtool_run 在一次性 fork 子进程里执行。 */
static napi_value CreateDisk(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = stringArg(env, args[0]);
    int32_t sizeMB = 0;
    napi_get_value_int32(env, args[1], &sizeMB);
    std::string alloc = "dynamic";
    if (argc >= 3) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, args[2], &t);
        if (t == napi_string) {
            alloc = stringArg(env, args[2]);
        }
    }

    std::vector<std::string> argv;
    argv.push_back("create");
    argv.push_back("-f");
    argv.push_back("qcow2");
    if (alloc == "fixed") {
        argv.push_back("-o");
        argv.push_back("preallocation=falloc");
    }
    argv.push_back(path);
    argv.push_back(std::to_string(sizeMB) + "M");

    std::string out;
    int rc = imgtool_run(argv, out);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "createDisk %{public}s failed rc=%{public}d: %{public}s",
                     path.c_str(), rc, out.c_str());
    }
    return intResult(env, rc);
}

/* diskInfo(path: string): string — qemu-img info --output=json 原始文本；失败返回空串 */
static napi_value DiskInfo(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = stringArg(env, args[0]);

    std::vector<std::string> argv;
    argv.push_back("info");
    argv.push_back("-U"); /* force-share：VM 运行时 qcow2 带独占锁，不加会读不了（返回空串→UI 显示 ?） */
    argv.push_back("--output=json");
    argv.push_back(path);

    std::string out;
    int rc = imgtool_run(argv, out);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "diskInfo %{public}s failed rc=%{public}d", path.c_str(), rc);
        napi_value result;
        napi_create_string_utf8(env, "", 0, &result);
        return result;
    }
    napi_value result;
    napi_create_string_utf8(env, out.c_str(), out.size(), &result);
    return result;
}

/* diskResize(path: string, sizeMB: number): number — qemu-img resize 到绝对大小。
 * qcow2 只支持扩大：目标须大于当前 virtual-size，交给调用方校验。 */
static napi_value DiskResize(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = stringArg(env, args[0]);
    int32_t sizeMB = 0;
    napi_get_value_int32(env, args[1], &sizeMB);
    if (sizeMB <= 0) {
        return intResult(env, -1);
    }

    std::vector<std::string> argv;
    argv.push_back("resize");
    argv.push_back(path);
    argv.push_back(std::to_string(sizeMB) + "M");

    std::string out;
    int rc = imgtool_run(argv, out);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "diskResize %{public}s -> %{public}dMB failed rc=%{public}d: %{public}s",
                     path.c_str(), sizeMB, rc, out.c_str());
    }
    return intResult(env, rc);
}

/* snapshotCreate(path: string, name: string): number — 给系统盘打一个内部快照。
 * qemu-img snapshot -c <name> <path>。快照是磁盘自身状态（qcow2 内部快照），
 * 必须离线：VM 停止后才能改盘，运行中调用会因盘被 qemu 锁定而失败。 */
static napi_value SnapshotCreate(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = stringArg(env, args[0]);
    std::string name = stringArg(env, args[1]);
    if (path.empty() || name.empty()) {
        return intResult(env, -1);
    }
    std::vector<std::string> argv;
    argv.push_back("snapshot");
    argv.push_back("-c");
    argv.push_back(name);
    argv.push_back(path);

    std::string out;
    int rc = imgtool_run(argv, out);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "snapshotCreate %{public}s name=%{public}s rc=%{public}d: %{public}s",
                     path.c_str(), name.c_str(), rc, out.c_str());
    }
    return intResult(env, rc);
}

/* snapshotApply(path: string, name: string): number — 回滚到某快照（覆盖当前内容，之后写入丢失）。
 * qemu-img snapshot -a <name> <path>；同样须离线。 */
static napi_value SnapshotApply(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = stringArg(env, args[0]);
    std::string name = stringArg(env, args[1]);
    if (path.empty() || name.empty()) {
        return intResult(env, -1);
    }
    std::vector<std::string> argv;
    argv.push_back("snapshot");
    argv.push_back("-a");
    argv.push_back(name);
    argv.push_back(path);

    std::string out;
    int rc = imgtool_run(argv, out);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "snapshotApply %{public}s name=%{public}s rc=%{public}d: %{public}s",
                     path.c_str(), name.c_str(), rc, out.c_str());
    }
    return intResult(env, rc);
}

/* snapshotDelete(path: string, name: string): number — 删除某快照（不触碰其他快照/当前数据）。 */
static napi_value SnapshotDelete(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = stringArg(env, args[0]);
    std::string name = stringArg(env, args[1]);
    if (path.empty() || name.empty()) {
        return intResult(env, -1);
    }
    std::vector<std::string> argv;
    argv.push_back("snapshot");
    argv.push_back("-d");
    argv.push_back(name);
    argv.push_back(path);

    std::string out;
    int rc = imgtool_run(argv, out);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "snapshotDelete %{public}s name=%{public}s rc=%{public}d: %{public}s",
                     path.c_str(), name.c_str(), rc, out.c_str());
    }
    return intResult(env, rc);
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "startVm", nullptr, StartVm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startSwtpm", nullptr, StartSwtpm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopSwtpm", nullptr, StopSwtpm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "vmRunning", nullptr, VmRunning, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "vmSnapshot", nullptr, VmSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createSurface", nullptr, CreateSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resizeSurface", nullptr, ResizeSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "destroySurface", nullptr, DestroySurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendPointer", nullptr, SendPointer, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendKey", nullptr, SendKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "scroll", nullptr, Scroll, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpConnect", nullptr, QmpConnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpCommand", nullptr, QmpCommand, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpDisconnect", nullptr, QmpDisconnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "qmpConnected", nullptr, QmpConnected, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setQmpEventCallback", nullptr, SetQmpEventCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "captureScreen", nullptr, CaptureScreen, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createDisk", nullptr, CreateDisk, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "diskInfo", nullptr, DiskInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "diskResize", nullptr, DiskResize, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "snapshotCreate", nullptr, SnapshotCreate, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "snapshotApply", nullptr, SnapshotApply, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "snapshotDelete", nullptr, SnapshotDelete, nullptr, nullptr, nullptr, napi_default, nullptr },
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
