#include "vm.h"
#include "qemu_abi.h"
#include "fb.h"

#include <dlfcn.h>
#include <hilog/log.h>
#include <pthread.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0005
#define LOG_TAG "QemuVM"

qemu_system_entry_fn qe_system_entry;
register_displaychangelistener_fn qe_register_dcl;
qemu_console_lookup_default_fn qe_console_lookup_default;
graphic_hw_update_fn qe_graphic_hw_update;
qemu_input_event_send_key_qcode_fn qe_input_send_key;
qemu_input_queue_abs_fn qe_input_queue_abs;
qemu_input_queue_btn_fn qe_input_queue_btn;
qemu_input_event_sync_fn qe_input_event_sync;
qemu_input_is_absolute_fn qe_input_is_absolute;
qemu_input_scale_axis_fn qe_input_scale_axis;
pixman_image_get_width_fn qe_surface_width;
pixman_image_get_height_fn qe_surface_height;
pixman_image_get_stride_fn qe_surface_stride;
pixman_image_get_data_fn qe_surface_data;
pixman_image_get_format_fn qe_surface_format;

/* console the DCL is bound to; used by input injection */
QemuConsole *g_qemu_con;

namespace {
struct VmState {
    std::atomic<bool> running{false};
    void *so = nullptr;
    std::thread vmThread;
    std::thread bindThread;
    std::vector<std::string> argStrings;
    std::vector<char *> argPtrs;
};
VmState g_vm;

template <typename T>
bool resolveSym(void *so, const char *name, T *out)
{
    *out = (T)dlsym(so, name);
    if (!*out) {
        OH_LOG_ERROR(LOG_APP, "dlsym %{public}s failed: %{public}s", name, dlerror());
        return false;
    }
    return true;
}

void vmMain(VmState *vm)
{
    pthread_setname_np(pthread_self(), "qemu-main");
    int argc = (int)vm->argPtrs.size();
    OH_LOG_INFO(LOG_APP, "qemu_system_entry start, argc=%{public}d", argc);
    int ret = qe_system_entry(argc, vm->argPtrs.data());
    OH_LOG_INFO(LOG_APP, "qemu_system_entry exited, ret=%{public}d", ret);
    vm->running.store(false);
}

void bindDisplay(VmState *vm)
{
    pthread_setname_np(pthread_self(), "qemu-dcl-bind");
    /* wait until the machine has created its graphic console */
    for (int i = 0; i < 600 && vm->running.load(); i++) { /* up to 60s */
        QemuConsole *con = qe_console_lookup_default();
        if (con) {
            g_dcl.con = con;
            qe_register_dcl(&g_dcl);
            g_qemu_con = con;
            OH_LOG_INFO(LOG_APP, "display listener registered after %{public}d ms", i * 100);
            return;
        }
        usleep(100 * 1000);
    }
    OH_LOG_ERROR(LOG_APP, "timed out waiting for qemu console");
}
} // namespace

bool vm_running()
{
    return g_vm.running.load();
}

int vm_start(const std::string &arch, const std::vector<std::string> &args)
{
    if (g_vm.running.load()) {
        OH_LOG_WARN(LOG_APP, "vm already running");
        return -1;
    }

    std::string soName = "libqemu-system-" + arch + ".so";
    void *so = dlopen(soName.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!so) {
        OH_LOG_ERROR(LOG_APP, "dlopen %{public}s failed: %{public}s", soName.c_str(), dlerror());
        return -1;
    }
    g_vm.so = so;

    bool ok = true;
    ok &= resolveSym(so, "qemu_system_entry", &qe_system_entry);
    ok &= resolveSym(so, "register_displaychangelistener", &qe_register_dcl);
    ok &= resolveSym(so, "qemu_console_lookup_default", &qe_console_lookup_default);
    ok &= resolveSym(so, "graphic_hw_update", &qe_graphic_hw_update);
    ok &= resolveSym(so, "qemu_input_event_send_key_qcode", &qe_input_send_key);
    ok &= resolveSym(so, "qemu_input_queue_abs", &qe_input_queue_abs);
    ok &= resolveSym(so, "qemu_input_queue_btn", &qe_input_queue_btn);
    ok &= resolveSym(so, "qemu_input_event_sync", &qe_input_event_sync);
    ok &= resolveSym(so, "qemu_input_is_absolute", &qe_input_is_absolute);
    ok &= resolveSym(so, "qemu_input_scale_axis", &qe_input_scale_axis);
    /* pixman is statically linked into the qemu .so: reuse its accessors */
    ok &= resolveSym(so, "pixman_image_get_width", &qe_surface_width);
    ok &= resolveSym(so, "pixman_image_get_height", &qe_surface_height);
    ok &= resolveSym(so, "pixman_image_get_stride", &qe_surface_stride);
    ok &= resolveSym(so, "pixman_image_get_data", &qe_surface_data);
    ok &= resolveSym(so, "pixman_image_get_format", &qe_surface_format);
    if (!ok) {
        dlclose(so);
        g_vm.so = nullptr;
        return -1;
    }

    std::string argv0 = "qemu-system-" + arch;
    g_vm.argStrings.clear();
    g_vm.argStrings.push_back(argv0);
    for (const auto &a : args) {
        g_vm.argStrings.push_back(a);
    }
    g_vm.argPtrs.clear();
    for (auto &s : g_vm.argStrings) {
        g_vm.argPtrs.push_back(&s[0]);
    }

    {
        std::string cmdline;
        for (auto &s : g_vm.argStrings) {
            cmdline += s;
            cmdline += ' ';
        }
        OH_LOG_INFO(LOG_APP, "starting vm: %{public}s", cmdline.c_str());
    }

    g_vm.running.store(true);
    g_vm.vmThread = std::thread(vmMain, &g_vm);
    g_vm.vmThread.detach();
    g_vm.bindThread = std::thread(bindDisplay, &g_vm);
    g_vm.bindThread.detach();
    return 0;
}
