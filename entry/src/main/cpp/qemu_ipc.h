/* qemuohos 父子进程 IPC 协议（IPCKit/Binder parcel）。
 * 父进程（libentry.so，ArkUI）经 OH_Ability_CreateNativeChildProcess 拉起
 * 子进程（libqemu_child.so，跑 qemu + DCL + GL 渲染）；一个子进程跑一轮 VM，
 * 退出后再启动就另起新子进程（绕开 qemu .so 的 run-once 限制）。
 * 每个请求 parcel 第一个 int32 必须是 kProtoVersion；回复第一个 int32 是
 * 子进程结果码（QUERY/SCREENSHOT 例外，回复带版本号+数据）。 */
#pragma once

#include <stdint.h>

namespace qemu_ipc {

constexpr int32_t kProtoVersion = 1;
constexpr const char *kDescriptor = "qemuohos.qemu.Runtime";
constexpr const char *kChildLib = "libqemu_child.so";

/* request codes */
constexpr uint32_t kStart = 1;         /* [ver][arch][argc][argv...][window parcel] → int32 */
constexpr uint32_t kAttachSurface = 2; /* [ver][window parcel] → int32 */
constexpr uint32_t kDetachSurface = 3; /* [ver] → int32 */
constexpr uint32_t kResizeSurface = 4; /* [ver][w][h] → int32 */
constexpr uint32_t kPointer = 5;       /* [ver][x][y][buttons] → int32 */
constexpr uint32_t kKey = 6;           /* [ver][qcode][down] → int32 */
constexpr uint32_t kQuery = 7;         /* [ver] → [ver][fbW][fbH][running] */
constexpr uint32_t kScreenshot = 8;    /* [ver][maxW] → [ver][w][h][rgba bytes] */
constexpr uint32_t kShutdown = 9;      /* [ver] → int32，随后子进程退出 */
constexpr uint32_t kScroll = 10;       /* [ver][dx][dy] → int32 滚轮步进（dy>0 下滚，dy<0 上滚） */

} // namespace qemu_ipc
