#include "imgtool.h"

#include <dlfcn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <cerrno>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0006
#define LOG_TAG "QemuImg"

typedef int (*qemu_img_entry_fn)(int argc, char **argv);

/* 子进程里 dlopen libqemu-img.so 并跑 qemu_img_entry（argv[0]=“qemu-img”）。
 * 不可再入 + 输出可能较长（info --output=json），一律在一次性子进程执行。
 * 子进程继承父进程内存，argv 字符串在 fork 前已就绪、_exit 前始终有效，
 * 因此无需 IPC，直接把 argv 当参数传进来。 */
int imgtool_run(const std::vector<std::string> &args, std::string &out)
{
    out.clear();
    int pipefd[2] = {-1, -1};
    if (pipe(pipefd) != 0) {
        OH_LOG_ERROR(LOG_APP, "imgtool: pipe failed errno=%{public}d", errno);
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        OH_LOG_ERROR(LOG_APP, "imgtool: fork failed errno=%{public}d", errno);
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }

    if (pid == 0) {
        /* ---- 子进程 ---- */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);

        void *so = dlopen("libqemu-img.so", RTLD_NOW | RTLD_LOCAL);
        if (!so) {
            _exit(2);
        }
        auto entry = (qemu_img_entry_fn)dlsym(so, "qemu_img_entry");
        if (!entry) {
            _exit(3);
        }
        std::vector<char *> argv;
        argv.reserve(args.size() + 2);
        argv.push_back(const_cast<char *>("qemu-img"));
        for (const auto &a : args) {
            argv.push_back(const_cast<char *>(a.c_str()));
        }
        argv.push_back(nullptr);
        int rc = entry((int)argv.size() - 1, argv.data());
        _exit(rc);
    }

    /* ---- 父进程 ---- */
    close(pipefd[1]);
    char buf[4096];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) {
        out.append(buf, (size_t)n);
    }
    close(pipefd[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        OH_LOG_ERROR(LOG_APP, "imgtool: waitpid failed errno=%{public}d", errno);
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}
