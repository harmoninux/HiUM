#pragma once
#include <string>

/* 通过 NCP 拉起 swtpm 子进程（libswtpm_child.so，内部 dlopen libswtpm.so + swtpm_entry）。
 * swtpm_start：发起子进程并轮询 ctrlSock 就绪；0=就绪，-1=失败。tpmDir 为 tpmstate
 * 目录（不存在则创建）；ctrlSock 为 unix ctrl socket（qemu -tpmdev 连接目标）。 */
int swtpm_start(const std::string &vmId, const std::string &tpmDir,
                const std::string &ctrlSock, const std::string &logPath, int timeoutMs);
/* 发 kShutdown 让 swtpm 子进程优雅退出 */
void swtpm_stop(const std::string &vmId);
