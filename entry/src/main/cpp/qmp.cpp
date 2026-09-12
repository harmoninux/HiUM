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
    /* 已建连但 qmp_capabilities 的回复还没回来 */
    std::atomic<bool> capsPending{false};
    /* 已完成一次成功的命令往返 = qemu 主循环确认活着（见 qmp.h 的说明） */
    std::atomic<bool> ready{false};
    std::mutex readyMu;
    std::condition_variable readyCv;
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
        /* qmp_capabilities 的回复 = 第一次成功往返 → 此后才算「qemu 起来了」。
         * handleLine 由 reader 线程自己调用，所以这里只能用标志位、不能阻塞等
         * 回复（在 reader 线程上 wait 会把 recv 循环卡死，永远等不到这行）。
         *
         * 这条回复**不能**写进 resp：它与并发的普通命令共用一个响应槽，写进去就
         * 会被 qmp_command 的等待者当成自己的结果拿走。协商回复没有任何命令在等，
         * 直接消化掉即可——此前的实现把它当普通回复投递，是既有的抢答缺陷。 */
        if (st->capsPending.exchange(false)) {
            if (line.find("\"return\"") != std::string::npos) {
                st->ready.store(true);
                OH_LOG_INFO(LOG_APP, "qmp ready (capabilities negotiated)");
                std::lock_guard<std::mutex> lk(st->readyMu);
                st->readyCv.notify_all();
            } else {
                OH_LOG_ERROR(LOG_APP, "qmp_capabilities rejected: %{public}s", line.c_str());
            }
            return;
        }
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

    /* capability negotiation: greeting is read in the main loop below。
     * capsPending 必须在 send 之前置位——回复可能在同一轮 recv 里就到达。 */
    static const char caps[] = "{\"execute\":\"qmp_capabilities\"}\n";
    st->capsPending.store(true);
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
    st->ready.store(false);
    st->capsPending.store(false);
    {
        /* 唤醒等在「就绪」上的命令：连接已死，它不该再干等满超时 */
        std::lock_guard<std::mutex> lk(st->readyMu);
        st->readyCv.notify_all();
    }
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
    /* 协商之前 qemu 的 QMP 只认 qmp_capabilities，别的命令一律 CommandNotFound；
     * 调用方（列表页关机）连上 150ms 就发，那时协商多半还没跑完，所以等一下。
     * 上限 2s：本函数是 napi 同步调用，跑在 ArkTS 主线程上，不能无限等。 */
    if (!st->ready.load()) {
        std::unique_lock<std::mutex> lk(st->readyMu);
        st->readyCv.wait_for(lk, std::chrono::seconds(2),
                             [st] { return st->ready.load() || st->fd.load() < 0; });
    }
    if (!st->ready.load()) {
        OH_LOG_WARN(LOG_APP, "qmp not ready, dropping: %{public}s", json.c_str());
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
    st->ready.store(false);
    int fd = st->fd.exchange(-1);
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
    std::lock_guard<std::mutex> lk(st->readyMu);
    st->readyCv.notify_all();
}

bool qmp_connected(const std::string &vmId)
{
    return stateOf(vmId)->fd.load() >= 0;
}

bool qmp_ready(const std::string &vmId)
{
    return stateOf(vmId)->ready.load();
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
