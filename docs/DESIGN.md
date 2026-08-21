# HiUM 正式版设计 —— HarmonyOS 上基于 QEMU 的「多形态虚拟机」

在 HarmonyOS 平板 / 2in1 上，用 QEMU TCG 纯软件模拟运行 x86 / arm64 等异构
guest 系统，并把 guest 屏幕**直接渲染**到 ArkUI（XComponent，不走 VNC）。
定位不是一个「跑 Linux 的壳」，而是一台**能装进平板的异构虚拟机 + 硬件实验室 +
时光机**。

## 0. 范围与硬约束

- **设备形态**：仅 `tablet` / `2in1`（触摸优先 + 可外接键鼠）。
- **accel**：**纯 TCG JIT**（默认 multi-thread），不接 KVM。TCI 解释器仅作为
  「设备禁止可写内存时」的应急备注，不作为设计支柱。
- **guest 集成**：**纯 virtio 优先，无 guest-agent**。凡是 guest 侧要装我们
  agent 才能给的能力，一律后置，改用纯 virtio / 纯 QEMU 原生机制先兑现。

### 能力范围（ABCDEFGH，去 G 并简化 F）

| 簇 | 能力 | 保留 | 关键机制 |
|---|---|---|---|
| A | 跑异构 OS | ✅ | 多架构库 + OS 模板 + ISO 导入 |
| B | 时光机（快照/回滚） | ✅ | 快照树 + 手动/关窗自动快照 + 回滚 |
| C | 私有服务器 | ✅ | hostfwd 结构化 + 9p 共享目录 |
| D | 开发者实验室 | ✅ | 串口 tail + QMP 工具页 + PXE + 直启内核 |
| E | 硬件实验室 | ✅ | 板卡模板（pc/q35/virt/raspi 等） |
| F | 临时会话（安全） | ✅ 简化 | 首启快照 + 关闭即回滚，**允许 hostfwd/联网** |
| G | 状态持久（savevm/loadvm） | ❌ 暂不需要 | 无 |
| H | 教学 | ✅ | 最小内核预设 + 启动拆解 |

## 1. 能力全景与诚实边界

### 1.1 纯 virtio + 无 guest-agent 可达矩阵

| 能力 | 可达？ | 机制 |
|---|---|---|
| 跑多架构 OS / 复古 OS / Android-x86 | ✅ | TCG + machine 模板 |
| 快照 / 回滚 | ✅ | QMP `blockdev-snapshot` + backing 管理（宿主侧纯 QEMU 原生） |
| 宿主↔guest 共享文件夹 | ✅ 先给 | **virtio-9p / virtfs**（Linux guest 内核内置，无需 agent） |
| 端口转发 / NAT / 网卡配置 | ✅ | user-mode net + `hostfwd`（结构化） |
| PXE 网络引导 / 直启内核 | ✅ | `-boot n`+Etherboot / `-kernel -initrd -append` |
| 串口 / QMP monitor 脚本化 | ✅ | `-serial` + QMP（Tools 页直接敲原始命令） |
| 指定板卡跑「无硬件 lab」 | ✅ | virt/raspi/pc/q35 各带默认设备图 |
| 临时会话 / 烧毁即弃 | ✅ | 首启快照 + 关闭即回滚（可联网/可转发） |
| 剪贴板双向 | ❌ | 需 guest agent，**后置**（当前走 9p 共享目录兑现「交换文件」） |
| guest 自动时间同步 | ⚠️ 弱 | 无宿主导入通道，靠 guest 自 NTP，后置 |
| 音频 | ⚠️ 视宿主 | QEMU 需 OHOS 侧音频后端，Phase 2 试探 |
| virtio-gpu 3D（virgl） | ⚠️ 视 guest | 依赖 guest 侧 virgl 驱动，后置 stretch |
| Windows 客机完整体验 | ⚠️ 受限 | 9p 需 WinFsp 驱动；先只保证 Linux/Alpine/Android-x86/DOS，后置 |

### 1.2 后置清单（需要 guest agent / 驱动，暂不做）

- 剪贴板宿主↔guest 双向
- 桌面级文件拖放
- guest 自动时间同步
- virgl 3D 加速
- Windows 客机完整体验
- 音频（视 OHOS 音频后端可达性，Phase 2 试探）

## 2. 总体架构（分层）

```
┌─ 表现层 ArkTS ──────────────────────────────────────────────┐
│ 视图库(首页) │ 机器工坊(配置向导) │ Console 独立窗口(沉浸式) │ 设置 │
├─ 领域/服务层 ArkTS ─────────────────────────────────────────┤
│ VmStore(配置v2)  MediaStore(镜像/ISO库)  SnapshotManager     │
│ VMRegistry(运行态权威源+事件总线)  NetworkProfile  BoardProfile│
├─ 原生核心 libentry.so ──────────────────────────────────────┤
│ 生命周期状态机+进程监督者 │ IPC客户端(NCP)  QMP客户端          │
│ qemu-img 工具链(create/info/resize/snapshot/commit)          │
├─ 子进程 libqemu_child.so（每 VM 一个）───┬───────────────────┤
│ QEMU(dlopen run-once)  DCL→FB  EGL渲染  输入  事件泵          │
│ 可选后续：音频 / 额外设备                                      │
└─────────────────────────────────────────────────────────────┘
```

**架构判断（不推翻）**：qemu 有 run-once 硬约束，必须把每台 VM 放进独立
NCP 子进程（`libqemu_child.so`），一个子进程跑一轮 VM，退出后另起新子进程。
这同时带来崩溃隔离与内存隔离，正式版保留。所有 ArkUI 进程同进程，native 的
vmId 路由注册表天然共享。

## 3. 已验证且保留的技术地基

以下为 POC 阶段已验证、正式版直接沿用的结论（不再展开历史）：

- **run-once 约束**：`qemu_add_opts`/`qemu_add_drive_opts` 对静态数组重复注册
  会 `abort()`；`dlclose` 后本线程 TCL 析构会跳到已卸载代码。⇒ 结论：**一进程
  一轮 VM**，用 NCP 子进程实现。**无 dlclose**。
- **直接渲染**：QEMU 显示子系统基于 `DisplayChangeListener`（DCL）。`-display none`
  下不建平台窗口，注册带 `dpy_refresh` 的 DCL 即可自建 30fps 刷新。数据通路：
  `VGA/virtio-gpu 显存 → dpy_gfx_update → 转换为 X8R8G8B8 back buffer →
  渲染线程 glTexSubImage2D 脏带 → 全屏 quad → eglSwapBuffers`。
- **跨进程窗口**：裸 surfaceId 跨进程查找返回 `NATIVE_ERROR_INVALID_ARGUMENTS`
  （进程内注册表，对三方应用跨进程不成立）。⇒ **父进程用 surfaceId 建
  `OHNativeWindow`，再 `OH_NativeWindow_WriteToParcel` 传给子进程**。
- **QMP 走 unix socket**：每 VM 一条 `qmp-<vmId>.sock`，沙箱文件系统路径，
  天然无端口冲突。UI 电源功能 = `stop/cont/system_reset/quit/send-key`。
- **每 VM 独立窗口**：`VmConsoleAbility` 用 `launchType: "specified"`，
  `MyAbilityStage.onAcceptWant` 返回 `vmconsole_<vmId>` 归并；配
  `removeMissionAfterTerminate: true`。窗口语义收敛为「存活 VM 的视图」：
  VM 死亡（`SHUTDOWN`/`QMP_DISCONNECT`）→ `terminateSelf()` 销毁窗口，下次
  从列表「进入」走全新窗口自动重启。
- **qemu-img 工具链**：`qemu_img_entry`（从 `libqemu-img.so` 导出）不可再入，
  本质是一次性 CLI ⇒ 每条命令（create/info/…）都在 `fork` 出的**一次性子进程**里
  `dlopen` + 跑入口、`_exit`，经 pipe 回收输出、`waitpid` 吃退出码。不用 native
  child process / IPC，直接在 fork 前把参数准备好当 argv 传入即可。默认 qcow2：
  `create -f qcow2 [-o preallocation=off|falloc] <path> <sizeM>`，
  `info --output=json <path>`（virtual-size/actual-size/format）。
- **性能基线**：Alpine 3.21 (kernel 6.12) 从 ISO 引导到 `localhost login` 约 50s
  （TCG），键盘可进 shell，显示模式切换（640x480 → 720x400 → 1280x800）正常。

### 线程模型

| 线程 | 职责 |
|---|---|
| ArkUI 主线程 | ArkTS 页面、触摸/键盘 → napi |
| qemu-main | `qemu_system_entry()`，整个 VM 运行于此 |
| qemu-dcl-bind | 轮询 console 出现后注册 DCL |
| qemu-render | EGL 上下文，脏帧上传 + 上屏 |

## 4. 模块划分（九个边界清晰的模块）

| 模块 | 职责 |
|---|---|
| 视图库（首页） | VM 卡片（缩略图/状态/磁盘用量/快照数/IP）+ 媒体库 + OS 模板库 |
| 机器工坊 | 架构→机器(板卡)→固件→介质→硬件→网络→运行时 向导 + 快速预设/高级 |
| 运行/Console（独立窗口） | 沉浸式画面 + 面向客机工具条（电源/快照/共享/软键/串口/QMP/HUD） |
| 时光机 | 快照树 + 手动/关窗自动快照 + 回滚 |
| 网络 | hostfwd 列表 + 9p 共享配置 + 网卡/隔离策略 |
| 存储 | MediaStore（基镜像/ISO 导入/qcow2 create/resize/convert）+ 配额 |
| 工具 | QMP 脚本化 + 串口 tail + PXE + 直启内核 + 板卡硬广 |
| 安全 | 临时会话（首启快照 + 关闭即回滚，可联网/可转发） |
| 设置 | JIT 性能预设（thread/tb-size/核数/内存）+ 默认值 + 存储位置 |

## 5. 快照引擎（唯一底座）

B（时光机）与 F（临时会话）共用同一份快照引擎，不造两条存储路径：

```
快照引擎（唯一底座）：qemu-img 的 backing 链 + QMP blockdev-snapshot
   ├─ B 时光机：关闭 = 「自动打点」→ 下次可回滚/存档
   └─ F 临时会话：关闭 = 「自动回滚到出厂点」→ 抛弃本次改动
```

底层：`blockdev-snapshot-sync` 打点 / 切 backing / `qemu-img` 管理快照树；
按 VM 属性（`SessionPolicy = persist | ephemeral`）选择关闭动作。网络
（hostfwd/9p）两种模式下都可用。

## 6. 数据模型（schema v2）

配置分层，UI 只面对领域对象，`buildArgs` 是纯函数归档：

- **机器定义**：arch / machine（pc/q35/virt/raspi…）/ firmware（SeaBIOS/OVMF）/
  cpu 模型 / 设备图。
- **运行时**：memory / cpus / accel（可被性能预设覆盖）。
- **介质**：disk / cdrom / boot 顺序。

`VmProfile` v2 带 schema 版本号 + 迁移器（v1→v2 自动迁移）。持久化到
`filesDir/vms/<id>.json`；缩略图 `vms/<id>.jpg`。

MediaStore 集中管理：基础镜像（base）+ 差分快照（backing_file）+ ISO 导入
（文件选择器）+ 存储配额。

## 7. 里程碑路线图

**Phase 0 · 地基（无它寸步难行）**
qcow2 + qemu-img 接线 · MediaStore · 配置 schema v2 + 迁移 · per-VM 锁 +
VMRegistry · 事件驱动渲染 · 真备份/恢复（启用 EntryBackupAbility）。

> **系统盘延迟创建**：配置页「创建」只是标记意图（diskNew），真正
> `qemu-img create` 在「保存」那一刻执行；取消/返回不留孤儿磁盘文件。已确认：默认
> 动态分配（稀疏，实占≈0）、可切固定大小（falloc 预留整块，免中途 ENOSPC）。

> 标注：**开发阶段 host 固定 x86_64**（走 api24 模拟器）；arm64-v8a 宿主库
> 后置到真机发布前再做，暂不阻塞开发。

**Phase 1 · 点亮 A–H 的最薄垂直切片**（每条只做到「能用」）
机器工坊向导 + OS 模板库（Alpine/Android-x86/DOS/裸内核）；Console virtio
触摸/键盘 + 手势（长按右键/双指滚轮）+ 沉浸式 + 快照/9p 共享/串口尾随/QMP
工具页；时光机（快照树 + 回滚 + 关窗自动快照）；临时会话（关闭即回滚）；
网络（hostfwd + 9p）；设置（JIT 性能预设）。

**Phase 2 · 深化**
软键盘/输入法 · 音频（视 OHOS 后端）· 运行态 HUD · 板卡硬广矩阵 · 多屏 ·
更精细手势。

**Phase 3 · 后置项**（需 guest agent / 驱动）
剪贴板双向 · 桌面级文件拖放 · guest 时间同步 · virgl 3D · Windows 客机完整体验。

## 8. 构建与验证

```bash
export TOOL_HOME=/apps/harmony
make deps          # 交叉编译 qemu（arm64-v8a / x86_64）
make hap           # 构建 HAP（按设备 arch 选 ABI）
make install       # 经 hdc 安装启动
make log           # 抓取应用日志
```

设备矩阵：开发阶段跑在 `api24` 模拟器（x86_64 宿主）；真机 arm64 平板/2in1
（双 ABI + 触摸/手势）在发布前验证。

## 9. 关键风险与对策

- **性能天花板**（TCG 纯软）：产品价值的确定性高地 = 对性能不敏感、而吃 QEMU
  原生能力最强的「复古 OS + 开发者实验室 + 临时会话/时光机」。GUI/实时类
  期望要调低。
- **可写内存权限**（JIT 需要 `kernel.ALLOW_WRITABLE_CODE_MEMORY` 等）可能卡
  AppGallery 审核：文档化说明，TCI 解释器作为后备（应急，非设计支柱）。
- **从 ISO 打到 rawfile 的方式**不适合用户自带镜像：改用文件选择器导入，
  rawfile 只留固件。
