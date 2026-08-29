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

int swtpm_start(const std::string &binPath, const std::string &tpmDir,
                const std::string &ctrlSock, const std::string &logPath,
                const std::string &pidPath, int timeoutMs)
{
    if (access(binPath.c_str(), X_OK) != 0) {
        OH_LOG_ERROR(LOG_APP, "swtpm bin not executable: %{public}s", binPath.c_str());
        return -1;
    }
    if (!fileExists(tpmDir)) {
        mkdir(tpmDir.c_str(), 0700);
    }
    pid_t pid = fork();
    if (pid < 0) {
        OH_LOG_ERROR(LOG_APP, "swtpm fork failed errno=%{public}d", errno);
        return -1;
    }
    if (pid == 0) {
        /* 子进程：exec swtpm（--daemon 自行再 fork，原 child 随之退出）。先物化临时串保证 c_str 稳定。 */
        std::string tpmStateArg = "dir=" + tpmDir;
        std::string ctrlArg = "type=unixio,path=" + ctrlSock;
        std::string logArg = "file=" + logPath;
        std::string pidArg = "file=" + pidPath;
        execl(binPath.c_str(), "swtpm",
              "socket", "--tpm2",
              "--tpmstate", tpmStateArg.c_str(),
              "--ctrl", ctrlArg.c_str(),
              "--log", logArg.c_str(),
              "--daemon", "--pid", pidArg.c_str(),
              (char *)nullptr);
        _exit(127);
    }
    /* 父进程：不 wait（swtpm --daemon 让 child 快速退出）。轮询 pid 文件 + ctrl socket 就绪。 */
    int waited = 0;
    for (; waited < timeoutMs; waited += 100) {
        if (fileExists(pidPath) && fileExists(ctrlSock)) {
            return 0;
        }
        usleep(100 * 1000);
    }
    OH_LOG_ERROR(LOG_APP, "swtpm start timeout errno=%{public}d", errno);
    swtpm_stop(pidPath);
    return -1;
}

void swtpm_stop(const std::string &pidPath)
{
    std::ifstream f(pidPath);
    if (f.is_open()) {
        pid_t p = 0;
        f >> p;
        if (p > 1) { kill(p, SIGTERM); }
        f.close();
    }
    unlink(pidPath.c_str());
}
