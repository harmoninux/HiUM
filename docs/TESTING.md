# HiUM 测试清单（2026-09-09）

本文件记录**已修复特性待回归**与**未完成验证项**，全部在真机（HarmonyOS 平板/桌面，走无线调试）验证。
背景：VM 启动 SIGABRT 根因已定位修复（见 DESIGN.md §1.1 / patches 0001），本次音频修复涉及两处
QEMU 源码 switch（audio.c 的 audio_create_pdos + audio_template.h 的 audio_get_pdo_in/out），
**这两处任一缺失都会导致带 `-audiodev driver=ohos` 的 VM 启动裸 abort**，修复后需按序回归。

## 测试环境与手法

- 设备：HarmonyOS 真机（平板/2in1），无线调试连接；具体地址不入库
  （`make install HDC_TARGET=<ip>:<port>` 显式指定）。
- 自动化：`uitest dumpLayout -p /data/local/tmp/ui.xml` 取坐标（物理像素），
  `uitest uiInput click x y` 注入点击；hilog 用 `hilog -x | grep -a X`。
- 注意：设备上其它应用可能抢占前台，测试前先 force-stop 置顶 HiUM
  （`aa force-stop <包名>`、`aa start -a EntryAbility -b app.hackeris.hium`）。
- VM 启动按钮 = 管理页详情头部 play 图标；vmconsole 窗口打开后自动启动 VM。
- 判活：`ps -ef | grep qemu_child`；崩溃诊断：abort 打点补丁（0002）已移除，
  需要时从 git 历史（commit f3a4159）恢复（输出 caller 符号 + 基址 + 偏移）。
- 点击坐标务必按「节点自身 attributes」解析（`uitest dumpLayout` 的文本与 bounds
  在嵌套布局里容易跨节点错配，曾多次点错按钮）。

## 1. 启动/音频回归（本次修复核心）

- [ ] 新建 VM（向导默认声音开）→ 启动 → 子进程存活 >30s、无 `qemu abort` 打点 → Console 见画面/串口
- [ ] 编辑页关「声音」→ 保存 → 启动/重连 → 正常
- [ ] 编辑页开「声音」→ 保存 → 重启 VM → 正常（验证音频参数装配 + 两处 case 修复覆盖）
- [ ] 音频驱动生命周期：VM 关机 → 再启动 → 声音 Toggle 状态保持、日志无错误
- [ ] 各板卡（pc/q35/virt/raspi 若可用）启动回归（raspi 不支持声音——确认 UI 禁用+启动正常）

## 2. v6 特性回归（vmclone / gdb / cpu flags / rtc）

- [ ] 克隆：右键/卡片「克隆」→ 进度条 → 副本出现在列表、磁盘为独立文件（vms/<newid>.qcow2）
- [ ] 克隆 VM 启动正常；删除副本不残留 disk 文件
- [ ] GDB 后端：编辑页开 GDB + 端口 → 启动 → `-gdb tcp:127.0.0.1:<port>` 出现在参数预览；
      用宿主 gdb `target remote` 连不上（预期，QEMU 在设备侧）；至少验证参数干净、VM 不阻塞启动
- [ ] CPU flags：`-cpu max,+sse4a,-avx2` 类组合出现在参数；guest 内 cat /proc/cpuinfo 反映 flags
- [ ] RTC 本地时区：rtcLocal=true → 参数含 `-rtc base=localtime`；guest date 与宿主一致

## 3. v5 特性排查（此前已部分通过，本轮受音频修复影响需重跑）

- [ ] 鼠标：absolute/relative 切换后启动（relative 依赖 ps2/usb-mouse 参数，raspi 禁用）
- [ ] 串口交互：交互串口开 → Console 串口视图收发（`-serial chardev:chr0` + socket）
- [ ] 系统增强：RNG/balloon 开关 → 参数含 virtio-rng/balloon；guest GUI 不卡顿
- [ ] 第二磁盘：新建/导入/只读/扩容；快照只作用于主盘（第二盘不受影响）

## 4. 已决事项

- [x] 0002 诊断打点补丁（`--wrap=abort` + util/qemu-hium.c）：**已彻底移除**（2026-09-11）。
      音频两处 case 修复后无已知 abort 路径；如未来再遇无文本 SIGABRT，从 git 历史
      （commit f3a4159 引入）恢复该补丁即可。
- 设备地址：随 DHCP 变化，不固化在仓库；Makefile 已参数化为
  `HDC_TARGET=<ip>:<port>`（未指定时用 hdc 自身默认目标）。
  无线调试会话失效时，需在设备端重新开启授权后再 `hdc tconn`。

## 5. 已知未决/观察

- 修复前观察到「每 28ms 一次 abort 打点」循环（`__real_abort` LTO no-op 所致），修复模板 switch 后
  完全消失——后续若再出现，优先怀疑音频 pdo 与 driver case 的新增点。
- 每轮验证前先 `make deps`（rm 重建，保证补丁都是从零应用——补丁链是否完整是这类 bug 的老坑）。
