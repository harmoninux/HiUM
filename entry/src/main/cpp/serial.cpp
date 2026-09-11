#include "serial.h"

#include <hilog/log.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0009
#define LOG_TAG "QemuSerial"

namespace {

/* 一台 VM 的串口连接（仿 qmp.cpp 的 QmpState 生命周期：条目录常驻 map，
 * reader 线程 detach；vmId 数量小，不释放可接受）。 */
struct SerialState {
    std::atomic<int> fd{-1};
    std::atomic<bool> readerRunning{false};
    std::thread reader;
    std::mutex writeMu; /* serial_write 串行化 send */

    napi_threadsafe_function tsfn = nullptr;
    std::mutex tsfnMu;
};

std::mutex g_mapMu;
std::map<std::string, std::unique_ptr<SerialState>> g_serial;

SerialState *stateOf(const std::string &vmId)
{
    std::lock_guard<std::mutex> lk(g_mapMu);
    auto &slot = g_serial[vmId];
    if (!slot) {
        slot = std::make_unique<SerialState>();
    }
    return slot.get();
}

void dispatch(SerialState *st, const std::string &text)
{
    /* 空串是「断线合成标记」，照推给 UI */
    std::lock_guard<std::mutex> lk(st->tsfnMu);
    if (!st->tsfn) {
        return;
    }
    napi_call_threadsafe_function(st->tsfn, new std::string(text), napi_tsfn_nonblocking);
}

bool sendAll(int fd, const char *data, size_t len)
{
    while (len > 0) {
        ssize_t n = send(fd, data, len, 0);
        if (n <= 0) {
            return false;
        }
        data += n;
        len -= (size_t)n;
    }
    return true;
}

bool connectOnce(SerialState *st, const std::string &path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
        OH_LOG_ERROR(LOG_APP, "serial sock path too long (%{public}zu)", path.size());
        close(fd);
        return false;
    }
    strcpy(addr.sun_path, path.c_str());
    if (connect(fd, (sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return false;
    }
    st->fd.store(fd);
    return true;
}

void readerMain(SerialState *st, std::string path)
{
    pthread_setname_np(pthread_self(), "serial-reader");
    /* qemu 与 socket chardev 的建立比 qmp 更晚（-serial 解析在全局启动），多等等 */
    for (int i = 0; i < 500 && st->readerRunning.load(); i++) {
        if (connectOnce(st, path)) {
            break;
        }
        usleep(200 * 1000);
    }
    int fd = st->fd.load();
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "serial connect to %{public}s failed", path.c_str());
        st->readerRunning.store(false);
        return;
    }
    OH_LOG_INFO(LOG_APP, "serial connected on %{public}s", path.c_str());

    char chunk[2048];
    while (st->readerRunning.load()) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) {
            break;
        }
        dispatch(st, std::string(chunk, (size_t)n));
    }

    close(fd);
    st->fd.store(-1);
    dispatch(st, "<SERIAL_DISCONNECT>");
    OH_LOG_INFO(LOG_APP, "serial disconnected");
    st->readerRunning.store(false);
}

void callJs(napi_env env, napi_value cb, void * /*context*/, void *data)
{
    std::string *text = static_cast<std::string *>(data);
    napi_value arg;
    napi_create_string_utf8(env, text->c_str(), text->size(), &arg);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, cb, 1, &arg, nullptr);
    delete text;
}
} // namespace

int serial_open(const std::string &vmId, const std::string &sockPath)
{
    SerialState *st = stateOf(vmId);
    bool expected = false;
    if (!st->readerRunning.compare_exchange_strong(expected, true)) {
        return 0; /* already running */
    }
    st->reader = std::thread(readerMain, st, sockPath);
    st->reader.detach();
    return 0;
}

int serial_write(const std::string &vmId, const std::string &text)
{
    SerialState *st = stateOf(vmId);
    std::lock_guard<std::mutex> wrtLk(st->writeMu);
    int fd = st->fd.load();
    if (fd < 0 || text.empty()) {
        return -1;
    }
    return sendAll(fd, text.c_str(), text.size()) ? (int)text.size() : -1;
}

void serial_close(const std::string &vmId)
{
    SerialState *st = stateOf(vmId);
    st->readerRunning.store(false);
    int fd = st->fd.exchange(-1);
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
}

void serial_set_callback(const std::string &vmId, napi_env env, napi_value cb)
{
    SerialState *st = stateOf(vmId);
    std::lock_guard<std::mutex> lk(st->tsfnMu);
    if (st->tsfn) {
        napi_release_threadsafe_function(st->tsfn, napi_tsfn_release);
        st->tsfn = nullptr;
    }
    if (!cb) {
        return;
    }
    napi_value name;
    napi_create_string_utf8(env, "serialEvent", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, cb, nullptr, name, 0, 1, nullptr, nullptr, nullptr,
                                    callJs, &st->tsfn);
}
