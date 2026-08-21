#include "qmp.h"

#include <hilog/log.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0008
#define LOG_TAG "QemuQmp"

namespace {

/* 一台 VM 的 QMP 连接。条目创建后常驻 map（不随断开释放）：reader 线程
 * detach 运行，释放 State 有 UAF 风险；vmId 数量小，泄漏可忽略。 */
struct QmpState {
    std::atomic<int> fd{-1};
    std::atomic<bool> readerRunning{false};
    std::thread reader;

    /* one command in flight: cmdMu serializes qmp_command callers, the
     * reader thread fills resp + signals cv */
    std::mutex cmdMu;
    std::mutex respMu;
    std::condition_variable respCv;
    std::string resp;
    bool hasResp = false;

    napi_threadsafe_function tsfn = nullptr;
    std::mutex tsfnMu;
};

std::mutex g_mapMu;
std::map<std::string, std::unique_ptr<QmpState>> g_qmp;

/* 获取或创建 vmId 的状态；返回的指针常驻有效 */
QmpState *stateOf(const std::string &vmId)
{
    std::lock_guard<std::mutex> lk(g_mapMu);
    auto &slot = g_qmp[vmId];
    if (!slot) {
        slot = std::make_unique<QmpState>();
    }
    return slot.get();
}

void dispatchEvent(QmpState *st, const std::string &evt)
{
    std::lock_guard<std::mutex> lk(st->tsfnMu);
    if (!st->tsfn) {
        return;
    }
    napi_call_threadsafe_function(st->tsfn, new std::string(evt), napi_tsfn_nonblocking);
}

/* a line is a command response if it carries "return"/"error"; QMP async
 * messages carry "event" instead. good enough for the monitor dialect we
 * use (no events embed those keys). */
bool isResponse(const std::string &line)
{
    return line.find("\"return\"") != std::string::npos ||
           line.find("\"error\"") != std::string::npos;
}

void handleLine(QmpState *st, const std::string &line)
{
    if (line.empty() || line.find("\"QMP\"") != std::string::npos) {
        return; /* greeting */
    }
    if (isResponse(line)) {
        std::lock_guard<std::mutex> lk(st->respMu);
        st->resp = line;
        st->hasResp = true;
        st->respCv.notify_all();
        return;
    }
    dispatchEvent(st, line);
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

bool connectOnce(QmpState *st, const std::string &path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
        OH_LOG_ERROR(LOG_APP, "qmp sock path too long (%{public}zu)", path.size());
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

void readerMain(QmpState *st, std::string path)
{
    pthread_setname_np(pthread_self(), "qmp-reader");
    /* qemu needs a moment to set up the monitor after vm_start */
    for (int i = 0; i < 300 && st->readerRunning.load(); i++) {
        if (connectOnce(st, path)) {
            break;
        }
        usleep(200 * 1000);
    }
    int fd = st->fd.load();
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "qmp connect to %{public}s failed", path.c_str());
        st->readerRunning.store(false);
        return;
    }
    OH_LOG_INFO(LOG_APP, "qmp connected on %{public}s", path.c_str());

    /* capability negotiation: greeting is read in the main loop below */
    static const char caps[] = "{\"execute\":\"qmp_capabilities\"}\n";
    sendAll(fd, caps, sizeof(caps) - 1);

    std::string buf;
    char chunk[4096];
    while (st->readerRunning.load()) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) {
            break;
        }
        buf.append(chunk, (size_t)n);
        size_t pos;
        while ((pos = buf.find('\n')) != std::string::npos) {
            handleLine(st, buf.substr(0, pos));
            buf.erase(0, pos + 1);
        }
    }

    close(fd);
    st->fd.store(-1);
    /* wake any blocked command, then tell ArkTS the monitor is gone */
    {
        std::lock_guard<std::mutex> lk(st->respMu);
        st->hasResp = true;
        st->resp.clear();
        st->respCv.notify_all();
    }
    dispatchEvent(st, "{\"event\":\"QMP_DISCONNECT\"}");
    OH_LOG_INFO(LOG_APP, "qmp disconnected");
    st->readerRunning.store(false);
}

void callJs(napi_env env, napi_value cb, void * /*context*/, void *data)
{
    std::string *evt = static_cast<std::string *>(data);
    napi_value arg;
    napi_create_string_utf8(env, evt->c_str(), evt->size(), &arg);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, cb, 1, &arg, nullptr);
    delete evt;
}
} // namespace

int qmp_connect(const std::string &vmId, const std::string &sockPath)
{
    QmpState *st = stateOf(vmId);
    bool expected = false;
    if (!st->readerRunning.compare_exchange_strong(expected, true)) {
        return 0; /* already running */
    }
    st->reader = std::thread(readerMain, st, sockPath);
    st->reader.detach();
    return 0;
}

std::string qmp_command(const std::string &vmId, const std::string &json)
{
    QmpState *st = stateOf(vmId);
    std::lock_guard<std::mutex> cmdLk(st->cmdMu);
    int fd = st->fd.load();
    if (fd < 0) {
        return "";
    }
    {
        std::lock_guard<std::mutex> lk(st->respMu);
        st->hasResp = false;
        st->resp.clear();
    }
    std::string wire = json + "\n";
    if (!sendAll(fd, wire.c_str(), wire.size())) {
        return "";
    }
    std::unique_lock<std::mutex> lk(st->respMu);
    if (!st->respCv.wait_for(lk, std::chrono::seconds(5), [st] { return st->hasResp; })) {
        OH_LOG_WARN(LOG_APP, "qmp command timed out: %{public}s", json.c_str());
        return "";
    }
    return st->resp;
}

void qmp_disconnect(const std::string &vmId)
{
    QmpState *st = stateOf(vmId);
    st->readerRunning.store(false);
    int fd = st->fd.exchange(-1);
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
}

bool qmp_connected(const std::string &vmId)
{
    return stateOf(vmId)->fd.load() >= 0;
}

void qmp_set_event_callback(const std::string &vmId, napi_env env, napi_value cb)
{
    QmpState *st = stateOf(vmId);
    std::lock_guard<std::mutex> lk(st->tsfnMu);
    if (st->tsfn) {
        napi_release_threadsafe_function(st->tsfn, napi_tsfn_release);
        st->tsfn = nullptr;
    }
    if (!cb) {
        return;
    }
    napi_value name;
    napi_create_string_utf8(env, "qmpEvent", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, cb, nullptr, name, 0, 1, nullptr, nullptr, nullptr,
                                    callJs, &st->tsfn);
}
