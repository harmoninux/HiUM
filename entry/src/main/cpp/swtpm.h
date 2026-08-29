#pragma once
#include <string>

/* fork/exec 拉起 swtpm（--daemon --pid），轮询 ctrl socket 与 pid 文件；0=就绪，-1=失败。
 * libDir 为 swtpm 运行库目录（spawn 前设 LD_LIBRARY_PATH，避免依赖系统缺失库）。
 * tpmDir 为 tpmstate 目录（不存在则创建）。 */
int swtpm_start(const std::string &binPath, const std::string &libDir,
                const std::string &tpmDir, const std::string &ctrlSock,
                const std::string &logPath, const std::string &pidPath, int timeoutMs);
/* 读 pid 文件 kill 并清理残留 socket/pid 文件 */
void swtpm_stop(const std::string &pidPath);
