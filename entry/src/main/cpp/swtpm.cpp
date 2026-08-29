#include "swtpm.h"
#include "swtpm_client.h"
#include <unistd.h>
#include <sys/stat.h>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0006
#define LOG_TAG "QemuSwtpm"

static bool fileExists(const std::string &p) { return access(p.c_str(), F_OK) == 0; }

/* 经 NCP 拉起 swtpm 子进程（libswtpm_child.so 内 dlopen libswtpm.so + swtpm_entry），
 * 轮询 ctrlSock 就绪后返回。退出由父进程 swtpm_stop → kShutdown 触发。
 * 注意：不再 fork/exec——走与 qemu 相同的系统原生子进程（避开沙箱 noexec 分区）。 */
int swtpm_start(const std::string &vmId, const std::string &tpmDir,
                const std::string &ctrlSock, const std::string &logPath, int timeoutMs)
{
    OH_LOG_INFO(LOG_APP, "swtpm_start vm=%{public}s tpmdir=%{public}s sock=%{public}s log=%{public}s timeout=%{public}dms",
                vmId.c_str(), tpmDir.c_str(), ctrlSock.c_str(), logPath.c_str(), timeoutMs);
    /* 上次异常退出可能残留 ctrl socket（swtpm SIGTERM 未必清），先清避免 bind 占端口 */
    unlink(ctrlSock.c_str());
    if (!fileExists(tpmDir)) {
        int mk = mkdir(tpmDir.c_str(), 0700);
        OH_LOG_INFO(LOG_APP, "swtpm mkdir %{public}s -> %{public}d", tpmDir.c_str(), mk);
    } else {
        OH_LOG_INFO(LOG_APP, "swtpm tpmdir already exists: %{public}s", tpmDir.c_str());
    }
    if (swtpm_client_start(vmId, tpmDir, ctrlSock, logPath) != 0) {
        OH_LOG_ERROR(LOG_APP, "swtpm_client_start failed vm=%{public}s", vmId.c_str());
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "swtpm child spawn initiated vm=%{public}s, polling ctrl socket", vmId.c_str());
    int waited = 0;
    for (; waited < timeoutMs; waited += 100) {
        if (fileExists(ctrlSock)) {
            OH_LOG_INFO(LOG_APP, "swtpm ready after %{public}dms (ctrl socket present)", waited);
            return 0;
        }
        usleep(100 * 1000);
    }
    OH_LOG_ERROR(LOG_APP, "swtpm start timeout after %{public}dms: sockExists=%{public}d",
                 waited, fileExists(ctrlSock));
    swtpm_client_shutdown(vmId);
    return -1;
}

void swtpm_stop(const std::string &vmId)
{
    OH_LOG_INFO(LOG_APP, "swtpm_stop vm=%{public}s", vmId.c_str());
    swtpm_client_shutdown(vmId);
}
