#include "swtpm.h"
#include <unistd.h>
#include <sys/stat.h>
#include <signal.h>
#include <cerrno>
#include <fstream>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0006
#define LOG_TAG "QemuSwtpm"

static bool fileExists(const std::string &p) { return access(p.c_str(), F_OK) == 0; }

int swtpm_start(const std::string &binPath, const std::string &libDir,
                const std::string &tpmDir, const std::string &ctrlSock,
                const std::string &logPath, const std::string &pidPath, int timeoutMs)
{
    OH_LOG_INFO(LOG_APP, "swtpm_start bin=%{public}s lib=%{public}s tpmdir=%{public}s sock=%{public}s log=%{public}s pid=%{public}s timeout=%{public}dms",
                binPath.c_str(), libDir.c_str(), tpmDir.c_str(), ctrlSock.c_str(),
                logPath.c_str(), pidPath.c_str(), timeoutMs);
    /* rawfile 解包不保留可执行位、且 @ohos.file.fs 无 chmod → 这里 best-effort 补 chmod 再校验。 */
    int cm = chmod(binPath.c_str(), 0755);
    OH_LOG_INFO(LOG_APP, "swtpm chmod(%{public}s,0755)=%{public}d", binPath.c_str(), cm);
    if (access(binPath.c_str(), X_OK) != 0) {
        OH_LOG_ERROR(LOG_APP, "swtpm bin not executable: %{public}s", binPath.c_str());
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "swtpm bin executable ok");
    if (!fileExists(tpmDir)) {
        int mk = mkdir(tpmDir.c_str(), 0700);
        OH_LOG_INFO(LOG_APP, "swtpm mkdir %{public}s -> %{public}d", tpmDir.c_str(), mk);
    } else {
        OH_LOG_INFO(LOG_APP, "swtpm tpmdir already exists: %{public}s", tpmDir.c_str());
    }
    pid_t pid = fork();
    if (pid < 0) {
        OH_LOG_ERROR(LOG_APP, "swtpm fork failed errno=%{public}d", errno);
        return -1;
    }
    if (pid == 0) {
        /* 子进程：exec swtpm（--daemon 自行再 fork，原 child 随之退出）。先物化临时串保证 c_str 稳定。 */
        setenv("LD_LIBRARY_PATH", libDir.c_str(), 1);
        std::string tpmStateArg = "dir=" + tpmDir;
        std::string ctrlArg = "type=unixio,path=" + ctrlSock;
        std::string logArg = "file=" + logPath;
        std::string pidArg = "file=" + pidPath;
        OH_LOG_INFO(LOG_APP, "swtpm exec child pid=%{public}d LD_LIBRARY_PATH=%{public}s", getpid(), libDir.c_str());
        execl(binPath.c_str(), "swtpm",
              "socket", "--tpm2",
              "--tpmstate", tpmStateArg.c_str(),
              "--ctrl", ctrlArg.c_str(),
              "--log", logArg.c_str(),
              "--daemon", "--pid", pidArg.c_str(),
              (char *)nullptr);
        OH_LOG_ERROR(LOG_APP, "swtpm execl failed errno=%{public}d", errno);
        _exit(127);
    }
    OH_LOG_INFO(LOG_APP, "swtpm forked launcher pid=%{public}d, polling socket+pid", pid);
    /* 父进程：不 wait（swtpm --daemon 让 child 快速退出）。轮询 pid 文件 + ctrl socket 就绪。 */
    int waited = 0;
    for (; waited < timeoutMs; waited += 100) {
        if (fileExists(pidPath) && fileExists(ctrlSock)) {
            OH_LOG_INFO(LOG_APP, "swtpm ready after %{public}dms (pid file + ctrl socket present)", waited);
            return 0;
        }
        usleep(100 * 1000);
    }
    OH_LOG_ERROR(LOG_APP, "swtpm start timeout after %{public}dms: pidFile=%{public}d sockExists=%{public}d errno=%{public}d",
                 waited, fileExists(pidPath), fileExists(ctrlSock), errno);
    swtpm_stop(pidPath);
    return -1;
}

void swtpm_stop(const std::string &pidPath)
{
    OH_LOG_INFO(LOG_APP, "swtpm_stop pidPath=%{public}s", pidPath.c_str());
    std::ifstream f(pidPath);
    if (f.is_open()) {
        pid_t p = 0;
        f >> p;
        if (p > 1) {
            OH_LOG_INFO(LOG_APP, "swtpm_stop kill SIGTERM pid=%{public}d", p);
            kill(p, SIGTERM);
        } else {
            OH_LOG_WARN(LOG_APP, "swtpm_stop no valid pid (read %{public}d)", p);
        }
        f.close();
    } else {
        OH_LOG_WARN(LOG_APP, "swtpm_stop pid file missing: %{public}s", pidPath.c_str());
    }
    unlink(pidPath.c_str());
}
