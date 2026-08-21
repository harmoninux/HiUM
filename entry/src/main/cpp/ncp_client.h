/* 父进程侧 IPC 客户端：管理 qemu 子进程（NCP）的生命周期与请求收发。
 * 多实例：按 vmId 各管一个子进程（= 一台运行中的 VM），NCP 拉起动作串行化。 */
#ifndef NCP_CLIENT_H
#define NCP_CLIENT_H

#include <stdint.h>
#include <string>
#include <vector>

/* 拉起子进程并发送 START（含 surfaceId 对应的窗口与 qemu 参数）。
 * 异步：返回 0 表示已发起，结果经 ncp_client_running()/日志体现；
 * 该 vmId 已有活动子进程时返回 -1。 */
int ncp_client_start(const std::string &vmId, const std::string &arch,
                     const std::vector<std::string> &args, int64_t surfaceId);
/* Console 重建 surface 后重新挂窗（有活动子进程才真发；否则只记住 id） */
int ncp_client_attach(const std::string &vmId, int64_t surfaceId);
/* Console surface 销毁（VM 继续在后台跑） */
void ncp_client_detach(const std::string &vmId);
void ncp_client_resize(const std::string &vmId, int32_t w, int32_t h);
void ncp_client_pointer(const std::string &vmId, int32_t x, int32_t y, int32_t buttons);
void ncp_client_key(const std::string &vmId, int32_t qcode, bool down);
bool ncp_client_running(const std::string &vmId);
/* 子进程侧当前 guest 分辨率；无子进程返回 -1 */
int ncp_client_query_display(const std::string &vmId, int *w, int *h);
/* 截图（子进程缩放到 ≤maxW 宽的 RGBA_8888）；无帧返回 -1 */
int ncp_client_screenshot(const std::string &vmId, int maxW, int *w, int *h,
                          std::vector<uint8_t> &pixels);
/* 让子进程整体退出（VM 随之消失） */
void ncp_client_shutdown(const std::string &vmId);

#endif /* NCP_CLIENT_H */
