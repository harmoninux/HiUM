#include "qmp.h"

#include <arpa/inet.h>
#include <hilog/log.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0008
#define LOG_TAG "QemuQmp"

namespace {
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
QmpState g_qmp;

void dispatchEvent(const std::string &evt)
{
    std::lock_guard<std::mutex> lk(g_qmp.tsfnMu);
    if (!g_qmp.tsfn) {
        return;
    }
    napi_call_threadsafe_function(g_qmp.tsfn, new std::string(evt), napi_tsfn_nonblocking);
}

/* a line is a command response if it carries "return"/"error"; QMP async
 * messages carry "event" instead. good enough for the monitor dialect we
 * use (no events embed those keys). */
bool isResponse(const std::string &line)
{
    return line.find("\"return\"") != std::string::npos ||
           line.find("\"error\"") != std::string::npos;
}

void handleLine(const std::string &line)
{
    if (line.empty() || line.find("\"QMP\"") != std::string::npos) {
        return; /* greeting */
    }
    if (isResponse(line)) {
        std::lock_guard<std::mutex> lk(g_qmp.respMu);
        g_qmp.resp = line;
        g_qmp.hasResp = true;
        g_qmp.respCv.notify_all();
        return;
    }
    dispatchEvent(line);
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

bool connectOnce(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(fd, (sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return false;
    }
    g_qmp.fd.store(fd);
    return true;
}

void readerMain(int port)
{
    pthread_setname_np(pthread_self(), "qmp-reader");
    /* qemu needs a moment to set up the monitor after vm_start */
    for (int i = 0; i < 300 && g_qmp.readerRunning.load(); i++) {
        if (connectOnce(port)) {
            break;
        }
        usleep(200 * 1000);
    }
    int fd = g_qmp.fd.load();
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "qmp connect to port %{public}d failed", port);
        g_qmp.readerRunning.store(false);
        return;
    }
    OH_LOG_INFO(LOG_APP, "qmp connected on port %{public}d", port);

    /* capability negotiation: greeting is read in the main loop below */
    static const char caps[] = "{\"execute\":\"qmp_capabilities\"}\n";
    sendAll(fd, caps, sizeof(caps) - 1);

    std::string buf;
    char chunk[4096];
    while (g_qmp.readerRunning.load()) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) {
            break;
        }
        buf.append(chunk, (size_t)n);
        size_t pos;
        while ((pos = buf.find('\n')) != std::string::npos) {
            handleLine(buf.substr(0, pos));
            buf.erase(0, pos + 1);
        }
    }

    close(fd);
    g_qmp.fd.store(-1);
    /* wake any blocked command, then tell ArkTS the monitor is gone */
    {
        std::lock_guard<std::mutex> lk(g_qmp.respMu);
        g_qmp.hasResp = true;
        g_qmp.resp.clear();
        g_qmp.respCv.notify_all();
    }
    dispatchEvent("{\"event\":\"QMP_DISCONNECT\"}");
    OH_LOG_INFO(LOG_APP, "qmp disconnected");
    g_qmp.readerRunning.store(false);
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

int qmp_connect(int port)
{
    bool expected = false;
    if (!g_qmp.readerRunning.compare_exchange_strong(expected, true)) {
        return 0; /* already running */
    }
    g_qmp.reader = std::thread(readerMain, port);
    g_qmp.reader.detach();
    return 0;
}

std::string qmp_command(const std::string &json)
{
    std::lock_guard<std::mutex> cmdLk(g_qmp.cmdMu);
    int fd = g_qmp.fd.load();
    if (fd < 0) {
        return "";
    }
    {
        std::lock_guard<std::mutex> lk(g_qmp.respMu);
        g_qmp.hasResp = false;
        g_qmp.resp.clear();
    }
    std::string wire = json + "\n";
    if (!sendAll(fd, wire.c_str(), wire.size())) {
        return "";
    }
    std::unique_lock<std::mutex> lk(g_qmp.respMu);
    if (!g_qmp.respCv.wait_for(lk, std::chrono::seconds(5), [] { return g_qmp.hasResp; })) {
        OH_LOG_WARN(LOG_APP, "qmp command timed out: %{public}s", json.c_str());
        return "";
    }
    return g_qmp.resp;
}

void qmp_disconnect()
{
    g_qmp.readerRunning.store(false);
    int fd = g_qmp.fd.exchange(-1);
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
}

bool qmp_connected()
{
    return g_qmp.fd.load() >= 0;
}

void qmp_set_event_callback(napi_env env, napi_value cb)
{
    std::lock_guard<std::mutex> lk(g_qmp.tsfnMu);
    if (g_qmp.tsfn) {
        napi_release_threadsafe_function(g_qmp.tsfn, napi_tsfn_release);
        g_qmp.tsfn = nullptr;
    }
    if (!cb) {
        return;
    }
    napi_value name;
    napi_create_string_utf8(env, "qmpEvent", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, cb, nullptr, name, 0, 1, nullptr, nullptr, nullptr, callJs, &g_qmp.tsfn);
}
