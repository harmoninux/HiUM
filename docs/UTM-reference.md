# UTM 功能设计研究与 HiUM 模仿方案报告

> 研究对象：https://github.com/utmapp/utm（clone depth=1，位于 `.temp/utm/`，commit b6f7475）
> 研究方式：iOS 前端 UX / 配置模型与服务层 / 现代模块（Remote·Scripting·CLI·下载 VM·JIT 策略）三路并行
> 结论服务对象：HiUM（HarmonyOS 纯 TCG QEMU app，DESIGN.md 的 P0/P1/P2 路线）

---

## 0. 一句话结论

UTM 与 HiUM 是**同一个技术母题**（QEMU 前台），但 UTM 多走了两步：① 用**统一 SPICE 客户端栈**承载显示/输入/USB/剪贴板，验证了「移动端 QEMU 前台」的完整功能面；② 用 **UTM SE（threaded interpreter）** 证明了「去 JIT 也能上架商店」。HiUM 当前**功能骨架已与 UTM 对齐**（配置模型、分步向导、快照、一次性会话、9p、hostfwd、直启内核），**差距集中在：声音、交互终端、全局设置、显示/网络细调、体验层（状态/空态/引导）**。下文给出逐项模仿方案。

---

## 1. UTM 功能全景

### 1.1 虚拟机配置（QEMU 后端，10 类）

| 类别 | 关键配置项 |
|---|---|
| System | architecture / machine(target) / cpu 模型+features 增删 / cpuCount(0=跟随宿主) / memorySize / jitCacheSize |
| QEMU 高级 | UEFI / RNG / balloon / **TPM(swtpm)** / HVF / TSO / RTC localtime / PS2 / debug log / machine property override / **additionalArguments(自定义参数数组)** / 运行时: isDisposable |
| Display（数组） | 显卡型号（按架构枚举: virtio-vga/virtio-gpu-gl/cirrus/…）/ vgaRamMib / **动态分辨率**(vdagent) / **缩放滤镜**(linear/nearest) / native resolution；显示器数组为空 → **-nographic 纯文本终端** |
| Input | usbBus(2.0/3.0) / usbSharing(重定向) / maxUsbShare |
| Network（数组） | mode: emulated(user)/shared(vmnet)/host/bridged / 网卡型号 / **MAC 地址** / **隔离(isIsolateFromHost)** / vlan 网段·网关·DHCP·DNS·域名全参数 / hostfwd(TCP/UDP × host/guest 地址端口) / hostNetUuid |
| Serial（数组） | mode: **builtin(内建终端)**/tcpClient/tcpServer/ptty / target: auto/gdb/monitor / 终端主题·字体·**resizeCommand**·光标 |
| Sound | 硬件: AC97 / Intel HDA / **SB16 / screamer / asc / pcspk** |
| Sharing | 模式: none / **webdav**(SPICE+agent) / **virtfs(9p)** / 只读 / **clipboard sharing** |
| Drive（数组） | imageType: disk/cd/bios/linuxKernel/linuxInitrd/linuxDtb / interface(ide/scsi/.../nvme/pflash) / interfaceVersion / 只读 / 外部盘 |
| Info / Terminal | 名称/后端/配置版本号；终端外观(配色/字体) |

### 1.2 运行与 UX（iOS）

- **VM 列表卡片**：图标+标题+架构副标题；右侧状态键（stopped=播放/busy=Spinner）；双击直启；左滑删除；**长按 contextMenu**：Run/Stop/Edit/**「Run without saving changes（一次性）」**/Clone/New from template/Share/Install Guest Tools。
- **详情页**：大截图+状态/架构/机台/内存/**占用大小(ByteCountFormatter)**/网络模式+MAC/**实时 guest IP(agent 每10s轮询)**/端口转发/串口地址，文本可长按复制。
- **配置编辑**：编辑=Form+导航卡片（Information/System/QEMU/Input/Sharing）+「Devices」区（Display/Serial/Network/Sound **实例列表可增删**）+「Drives」区（Import/New Drive，EFI 变量盘特殊命名）；新建=分步向导（Start→OS→Boot→Hardware→Drives→Sharing→Summary）。切换架构弹 Reset 确认；RAM 超 90% 物理内存弹警告。
- **运行时工具栏**：毛玻璃悬浮圆钮，可拖四角/折叠/5s 变淡 15s 自动隐藏；Power(软关/强杀)/Pause/Resume/Restart/Zoom/Drive(运行中换镜像/eject/共享目录)/Display(切 display/serial/**新窗口/外接屏**)/Keyboard(长按呼出快捷键编辑)/USB 菜单。
- **状态分层**：busy 毛玻璃+Spinner；paused/stopped 中央大播放键；headless 空态提示；关键操作确认 Alert；错误分类（致命/非致命/低内存自动存快照）。
- **下载 VM**：URL scheme `utm://downloadVM?url=` → Gallery 网页 → 下载 zip → **只解压第一个 .utm 包**（路径穿越防护/symlink 拒绝/重名加后缀）→ 列表顶部 Pending 分区卡片（进度/速度/ETA/可取消）。
- **引导**：无独立 onboarding，靠 TipKit 逐点提示（空列表 Start Here、启动3次后捐款、工具栏折叠提示）+ 空态欢迎四宫格（Create/Gallery/User Guide/Support）+ release notes 首次弹窗 + 向导首页 Gallery 链接。
- **设置页**（Settings.bundle）：Background(后台继续运行/后台自动保存)、Idle(禁熄屏/不存截图)、Devices(USB 不弹窗/优先麦克风)、**Graphics**(渲染后端 Metal/ANGLE GL、FPS 限制)、**Gestures**(长按/双指轻点/双指平移/双指滑动/三指平移 → 各自映射为右键/滚轮/移动屏幕)、**Cursor**(触摸模式；拖拽光标/隐显/Pencil/拖拽速度/反转滚轮)、**Gamepad**(按键逐键重映射)、JitStreamer。
- **输入**：软键盘=自定义 ASCII 键盘 + **inputAccessoryView 附 Ctrl/Alt/Esc/Tab/Paste/Done 键帽** + 扫描码注入；硬件键盘 presses 事件直通；**可配置快捷键组**（默认 Ctrl+Alt+Del）；Pencil 双击；手柄。
- **窗口**：SessionState(会话级) 与 WindowState(窗口级，持久化缩放/键盘状态) 分离；macOS 每 display/serial 独立窗口，iOS 单窗口设备切换+Stage Manager 外接屏窗口。

### 1.3 现代扩展

- **UTM Remote**：同一 Xcode 工程第三 target（iOS Remote 瘦客户端变体），mac 端 server + iOS 端 client；native TCP + **Bonjour mDNS+UPnP** 自动发现；**双向 TLS（自签 RSA 证书+设备指纹肉眼配对）**；RPC version=1；客户端**直连 QEMU 的 SPICE**（TLS 公钥+随机 32 位密码）→ 全功能（显示/输入/USB/剪贴板）；`isTakeoverAllowed` 会话接管；断线 5s 自动重连。
- **Scripting**：sdef → ScriptingBridge 生成（macOS AppleScript）+ AppIntents（iOS Shortcuts/Siri）。能力：VM 生命周期（make/import/export/duplicate/delete/start(--disposable)/suspend/stop(force/kill/request)）、快照全套、**配置树可整体读写**、guest 文件/进程/IP（**依赖 guest agent**）、输入注入（scan code/keystroke/mouse click 走 SPICE）、USB。
- **utmctl CLI**：version/list/status/start/suspend/stop/file pull/push/exec/ip-address/clone/delete/usb/snapshot create/list/restore/delete —— 与 Scripting 同一层,是「结构化接口面的两个消费者」。
- **JIT/加速策略**（对 HiUM 最关键）：

| 路线 | 机制 | 上架性 |
|---|---|---|
| 普通 UTM iOS | 5 级探测（ptrace child/JIT entitlement/CS_KILL off/CS_EXECSEG/PTRACE hack）+ AltJIT/JitStreamer/Tethered Launch | ❌ 需越狱或外部辅助 |
| **UTM SE** | `--enable-tcg-threaded-interpreter`（**TCTI：threaded code 解释器**，把 guest TB 编译成解释器指令跳转链而非宿主机器码），仅 ARM/PPC/RISC-V/x86 32+64 | ✅ App Store 正规上架，“slow edition” |
| macOS | Hypervisor.framework / Virtualization.framework | — |

---

## 2. UTM 设计方法（可复用的六条）

1. **配置即序列化格式**：`UTMQemuConfiguration` 聚合 10 个子对象、`@Published+Codable`、配置版本号+`Legacy/` 一次性迁移器。（HiUM schema v3+迁移器=Cousin）
2. **参数生成纯函数**：`QEMUArgumentBuilder` resultBuilder DSL；fragment 机制按 `,` 合并（QEMU key=value 语法）；**argv 数组直传，无 shell 转义**；URL 自动提取进 `fileUrls`（资源作用域解耦）。（HiUM buildArgs=同理念）
3. **统一 SPICE 通道**：显示/输入/USB/剪贴板/WebDAV 全部走 SPICE 协议客户端，QEMU 侧只是 `-spice` + 设备；文本终端=builtin 串口经 spiceport→SwiftTerm。（HiUM 无 SPICE：DCL 直渲染=自选架构，只借鉴功能面，不照搬通道）
4. **状态机 + Registry**：`UTMVirtualMachineState` 十态异步机；`UTMRegistry` 按 VM id 存运行时状态（外部盘书签/窗口/终端设置/isSuspended），debounce 落盘，config↔registry 双向同步。
5. **Session/Window 状态分层**：会话级（跨窗口）+窗口级（缩放/键盘态持久化）。
6. **能力协议化**：`UTMVirtualMachine` 协议+静态 Capabilities（supportsSnapshots/supportsRemoteSession），UI 只面向协议；SWTPM 以 `UTMProcess` 进程抽象统一（iOS 线程内 dlopen `swtpm_main`）。

---

## 3. HiUM ↔ UTM 对照矩阵

### 3.1 已对齐/已具备（无需行动）

| HiUM | UTM 对应 | 备注 |
|---|---|---|
| VmProfile schema v3+迁移 | 配置版本号+Legacy 迁移 | 同构 |
| buildArgs 纯函数 | QEMUArgumentBuilder | 同理念（HiUM 无 fragment 合并，但参数量小） |
| 分步向导（VmWizard 模板+高级） | VMWizard / VMSettings | 对齐 |
| OS 模板库（4 套） | wizard OS 选择 + Gallery 下载 | HiUM 内置 Alpine ISO=「开箱即起」更进一步 |
| 临时会话（`__temp__` 快照回滚） | **Run without saving changes / `--disposable`** | **同一个概念**，UTM 验证了它是普适需求 |
| 快照引擎（qemu-img backing 链） | savevm/loadvm + UTMSnapshotService | HiUM 的离线方案更简单可靠 |
| 直启内核（kernelPath/initrd/append） | drive imageType=linuxKernel/… | 对齐 |
| 9p 共享 / hostfwd | virtfs / portForward | 对齐 |
| 串口 tail | builtin 终端 | **HiUM 只有读，UTM 能写（差异点）** |
| 虚拟键盘+手势（长按右键/双指滚轮） | 软键盘+附键帽 / 可配置手势 | HiUM 手势硬编码（差异点） |
| 独立窗口每 VM | macOS 每 display 一窗 | HiUM 更简洁 |

### 3.2 UTM 有而 HiUM 无 → 可模仿（核心清单）

| # | 功能 | UTM 的做法 | HiUM 的适配路径 | 优先级 |
|---|---|---|---|---|
| 1 | **全局设置页** | Settings: 后台策略/渲染后端/FPS 限制/**手势映射**/**光标模式**/手柄 | HiUM 无设置模块（DESIGN.md 已规划）。先做：渲染(FPS 上限/滤镜默认)、手势映射表、光标模式、性能默认值(tbSize/memory 模板级 override)、关于+隐私政策（**上架合规硬项**） | **P0** |
| 2 | **声音** | Sound 硬件选择(AC97/HDA/SB16/screamer/asc/pcspk)+SPICE 音频通道 | HiUM 最大功能缺口。QEMU 音频后端在 OHOS 沙箱不可用（无 ALSA/PA）→ **先行可行性 probe**：自编 OHOS 音频桥（AudioRenderer API，三方可达）或 wav 兜底；UI 先行（设备选择入 profile，后端未通时静音兜底） | **P0（含 probe 风险）** |
| 3 | **交互式串口终端** | builtin 串口 → SwiftTerm（双向+主题+resizeCommand） | ✅ **已实现（2026-09-08）**：`-chardev socket,server=on` + serial.cpp 桥 + Console 串口视图（只读滚动区 + Ctrl/Esc/Enter 键帽 + 输入行），pc/q35 与 virt（virtconsole）双路径 | — |
| 4 | **临时会话入口 UX** | contextMenu 一次性开关（每次启动决策） | HiUM 现为 profile 持久开关 → **启动弹窗二选一（正常/临时）**，小改、体验大增 | **P0** |
| 5 | **详情页信息补齐** | 占用大小/MAC/端口/串口地址可复制 | ⛳ 部分：第二盘行/只读徽标/显卡/鼠标/增强/串口 chips 已实现；磁盘实际占用已有展示（qemu-img info） | **P1 余** |
| 6 | **显示设置增强** | 多显示器数组/滤镜(linear|nearest)/VGA 型号枚举/vgaRam | ⛳ 部分：VGA 型号枚举（std/cirrus/vmware/virtio，仅 x86 板卡）已实现；滤镜/显存未做 | **P1 余** |
| 7 | **网络细调** | vlan 网段/DNS/隔离(restrict)/网卡型号筛选 | HiUM user 模式加：网段/DNS/restrict 隔离/网卡型号（virtio-net/e1000） | **P1** |
| 8 | **可配置快捷键/宏** | KeyboardShortcuts（默认 Ctrl+Alt+Del） | HiUM keymap 只做映射 → 加宏配置（复古 OS 常用组合）。QEMUComboBox/QKeyCode 列表 | **P1** |
| 9 | **硬件高级结构项** | RNG/balloon/PS2/machinePropertyOverride 单选 | ⛳ 部分：RNG/balloon 结构化开关已实现；PS2/keyboard 与 machinePropertyOverride 仍走 extraArgs | **P1 余** |
| 10 | **镜像 URL 下载导入** | Gallery 网页+zip 导入（防穿越/symlink/重名） | HiUM 内置 ISO 已解决 Alpine；补 **URL→zip/qcow2 导入器**（Pending 进度卡可参考），画廊服务自建后置 | **P2** |
| 11 | **Gamepad / Pencil** | MFI 手柄逐键映射；Pencil 点击=鼠标 | OHOS 有笔事件 API、手柄 API 待核；**都列为试探** | P2 |
| 12 | **QMP 工具页增强→「命令预设」** | Scripting/utmctl 的格式化接口 | HiUM QMP 工具页已存在；OHOS 无 AppleScript/Shortcuts 等价物 → 做**命令收藏/预设**（等价于脚本层的局部形态） | P2 |

### 3.3 UTM 有而 HiUM 不做（诚实边界）

| 功能 | 不做原因 |
|---|---|
| 剪贴板双向 / WebDAV 共享 / 动态分辨率 | 依赖 SPICE vdagent + guest 安装 tools —— 违反「无 guest-agent」原则，维持 Phase 3 |
| 网络 bridged/shared 模式 | vmnet 需宿主系统网卡控制，OHOS 三方不可达 |
| UTM Remote（远控） | HiUM 宿主即移动端，无人供端；若做「平板 server/手机 client」需网络权限+服务常驻+审核风险，**far-future 备选** |
| 真实 USB 透传（usbredir） | 三方拿 OTG/USB 设备权限在 OHOS 不可行；只保留 QEMU 模拟 USB 控制器 |
| guest agent 族（IP 查询/文件/进程代理） | 违反设计原则，后置 |
| 多显示器窗口 | 单 DCL 后端；Phase 2 调研后定 |
| swtpm/Secure Boot | HiUM 已移除（Win11 已删）；若做「安全启动教学」再启用 |

---

## 4. 特别借鉴：UTM SE（存档参考，已确认不再需要）

> **决策记录（2026-09-07）**：JIT 权限（`kernel.ALLOW_WRITABLE_CODE_MEMORY`）已确认可获取、
> 无审核风险，UTM SE 的 TCTI 后备**不再作为 HiUM 行动项**。本条仅作 UTM 研究方向存档。

UTM SE = `--enable-tcg-threaded-interpreter`（**TCTI**：每个 guest TB 编译成解释器指令的跳转链，
而不是宿主机器码），不需要可写可执行内存，无需越狱可上架 App Store；代价是「slow edition」。
若未来权限生变，可回到本路线：做「threaded interpreter 编译开关 + 架构集裁剪
（仅 x86_64/i386/aarch64/arm）」的可切换构建，在 deps 构建链中预研开关即可。

---

## 5. 落地节奏建议

**P0（发布前必做）**：① 全局设置页（含关于/隐私合规）→ ② 交互式串口终端 → ③ 临时会话启动弹窗 → ④ 声音可行性 probe（成功则入 P0，失败则 UI+静音兜底）。

**P1（首版本后快速迭代）**：详情页信息补齐 → 显示缩放/滤镜 → 网络细调 → 快捷键宏。

**P2（差异化打磨）**：URL 镜像导入 → Gamepad/Pencil 试探 → QMP 命令预设 → 多屏调研。

**架构备注**：所有模仿项均不触碰 HiUM 现有地基（NCP 子进程/DCL 直渲染/QMP socket/9p），除声音需要新增音频后端探路。UTM 的 SPICE 栈不复制——HiUM 用 DCL+GLES、9p、socket、QMP 四件套天然覆盖了更多 UTM 功能面且无 guest-agent 依赖。
