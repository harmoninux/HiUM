/* swtpm NCP 子进程（libswtpm_child.so）的父进程侧 IPC 客户端。
 * 与 ncp_client 对称但独立一套状态（swtpm 与 qemu 各一个子进程，勿混排）。
 * 串行 spawn：同一时刻最多一个 swtpm 子进程在途。 */
#ifndef SWTPM_CLIENT_H
#define SWTPM_CLIENT_H

#include <string>

/* 拉起 swtpm 子进程并发 START(tpmDir/ctrlSock/logPath)。异步：0=已发起，
 * 就绪与否由 swtpm_start 轮询 ctrlSock 体现；该 vmId 已有活动 swtpm 则 -1。 */
int swtpm_client_start(const std::string &vmId, const std::string &tpmDir,
                       const std::string &ctrlSock, const std::string &logPath);
/* 发 kShutdown 让 swtpm 子进程优雅退出 */
void swtpm_client_shutdown(const std::string &vmId);
/* 子进程是否存活（kQuery 自愈；代理失效则清理并返回 false） */
bool swtpm_client_running(const std::string &vmId);

#endif /* SWTPM_CLIENT_H */
