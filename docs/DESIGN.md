# qemuohos —— HarmonyOS 上基于 QEMU TCG 的模拟器（PoC）

在 HarmonyOS 设备上用 QEMU TCG 纯软件模拟运行 x86 / x86_64 / arm64 guest，
并将 guest 屏幕**直接渲染**到 ArkUI（XComponent），不经过 VNC。

## 总体架构

```
┌──────────────────── 应用进程（ArkUI，libentry.so）────────────────────┐
│ ArkTS (VmList/VmEdit/Console)                                        │
│   └─ XComponent(SURFACE) ── surfaceId ─┐                             │
│ napi_init.cpp                          │                             │
│   ├─ ncp_client.cpp ── IPC (IPCKit/Binder, qemu_ipc.h 协议) ─┐       │
│   └─ qmp.cpp ── QMP loopback TCP ──────────────────────┐     │       │
└────────────────────────────────────────────────────────┼─────┼───────┘
                                                          │     │
┌──────────── qemu 子进程（NCP，libqemu_child.so）────────┼─────┼───────┐
│ qemu_child.cpp  IPC 分发 + 生命周期（一进程一轮 VM）     │     │       │
│   ├─ vm.cpp      VM 线程: dlopen(libqemu-system-*.so) ◄─┘     │       │
│   │              调用 qemu_system_entry(argc, argv)           │       │
│   ├─ fb.cpp      DCL 回调: qemu 显存 → X8R8G8B8 back buffer   │       │
│   ├─ renderer.cpp 渲染线程: back buffer → GL 纹理 → EGL 上屏  │       │
│   │              （窗口经 parcel 传来；letterbox，脏带合并）   │       │
│   └─ input.cpp   触摸/键盘 → qemu_input_*（IPC 转发）         │       │
│        ▲ OHNativeWindow 由父进程创建、WriteToParcel 传入 ◄────┘       │
│        QMP server 在子进程监听 127.0.0.1，父进程直连 ◄────────────────┘
└───────────────────────────────────────────────────────────────────────┘
```

VM 退出（QMP quit / guest 关机）→ qemu_system_entry 返回 → 子进程
MainProc 退出 → 进程结束。再次启动 = 父进程另起一个**全新的 NCP 子进程**，
因此不再有「一进程一轮 VM」的进程重启问题。

## 关键技术决策

### 1. QEMU 维护方式（参考 HiSH）

- QEMU 源码：`harmoninux/qemu` 的 `hish-libqemu` 分支（qemu 10.2），
  其改造点是把 `qemu-system-*`/`qemu-img` 构建为**动态库**（导出
  `qemu_system_entry`/`qemu_img_entry`），可被应用进程 dlopen。
- 交叉编译：`deps/` 下的 Makefile 体系（zstd → zlib → pcre2 → glib →
  pixman → libqemu），工具链用 OHOS NDK clang（`$TOOL_HOME/sdk/default/
  openharmony/native/llvm/bin/<arch>-unknown-linux-ohos-clang`）。
- 产物拷入 `entry/libs/<abi>/`（.so）与 `entry/src/main/resources/
  rawfile/vm/`（BIOS 固件、keymaps），随 HAP 打包。
- TCG：`--enable-tcg`，启动参数 `-accel tcg,thread=multi,tb-size=1024`；
  KVM/Xen/SDL/GTK/VNC/spice 等全部裁剪。TCG JIT 需要可执行内存权限
  （module.json5 声明 `kernel.ALLOW_WRITABLE_CODE_MEMORY` 等）；若目标
  设备不允许 JIT，回退方案是 configure 加 `--enable-tcg-interpreter`
  构建 TCI 版本（HiSH 在手机形态上即如此处理）。
- coroutine 用 `sigaltstack`（OHOS 无 ucontext）。

### 2. 直接渲染（不用 VNC）

QEMU 的显示子系统基于 `DisplayChangeListener`（DCL）回调模型——VNC、
GTK、SDL 都只是 DCL 的一种实现。qemu 构建出的 `.so` **未做符号隐藏**
（无 version script / 无 `-fvisibility=hidden`），因此 App 可以直接
dlsym 到内部 API：

- `register_displaychangelistener()` / `qemu_console_lookup_default()`
- `graphic_hw_update()`（主动拉一帧，驱动设备重绘回调）
- `qemu_input_queue_abs/btn()`、`qemu_input_event_send_key_qcode()`、
  `qemu_input_event_sync()`（输入注入）
- `pixman_image_get_*()`（pixman 静态链接进 qemu .so，符号同样可见，
  用来读取 DisplaySurface 的几何/像素指针）

渲染数据通路：

```
VGA/virtio-gpu 设备显存 (pixman image)
  → dpy_gfx_update(x,y,w,h) 回调（qemu 线程，push）
  → 格式转换为 X8R8G8B8 写入 back buffer（mutex 保护，脏行带合并）
  → 渲染线程 glTexSubImage2D 上传脏带 → 画全屏 quad → eglSwapBuffers
```

`-display none` 下 QEMU 不会创建任何平台窗口；只要注册的 DCL 带
`dpy_refresh` 回调，console.c 的 `gui_setup_refresh()` 就会自建
30fps 定时器驱动刷新，因此**无需给 QEMU 打任何补丁**。

线程模型：

| 线程 | 职责 |
|------|------|
| ArkUI 主线程 | ArkTS 页面、触摸/键盘事件 → napi |
| qemu-main | `qemu_system_entry()`，整个 VM 运行于此 |
| qemu-dcl-bind | 轮询 `qemu_console_lookup_default()` 直到 console 出现后注册 DCL |
| qemu-render | EGL 上下文所在线程，脏帧上传 + 上屏 |

### 3. 屏幕输出到 ArkUI（参考 Termony）

ArkTS 侧 `XComponent({ type: XComponentType.SURFACE })`，在
`XComponentController.onSurfaceCreated` 中把 `surfaceId`（BigInt）传给
napi；native 用 `OH_NativeWindow_CreateNativeWindowFromSurfaceId()`
创建 NativeWindow，再 `eglCreateWindowSurface` 建 EGL 上下文，渲染
线程在其上 `eglSwapBuffers` 上屏。

### 4. 输入

- 触摸：ArkTS `onTouch` → vp 坐标换算为 surface 物理像素 →
  `sendPointer` → native 按 letterbox 视口换算为 guest 像素坐标 →
  `qemu_input_queue_abs`（需要 guest 侧绝对指针设备：x86 用
  `-device virtio-tablet-pci`）。
- 键盘：`qemu_input_event_send_key_qcode`（QKeyCode 值取自 qemu
  qapi 生成的 `qapi-types-ui.h`）。

### 5. 虚拟机管理 UI（第一版）

三个页面（`entry/src/main/ets/pages/`）：

- **VmList**：VM 卡片列表（缩略图、架构/内存/核数/介质摘要、运行中
  标记），新建/删除/启动/进入。`lib/vmprofile.ets` 的 `VmStore`
  把 profile 以 JSON 存 `filesDir/vms/<id>.json`，缩略图
  `vms/<id>.jpg`。
- **VmEdit**：配置表单——名称、架构（x86_64/i386/aarch64）、内存、
  CPU 核数、光盘/磁盘（qcow2 可经 napi `createDisk` 调
  `qemu_img_entry` 创建）、QMP 端口等，保存时由 `buildArgs()`
  翻译成 qemu 命令行。
- **Console**：XComponent 画面 + 工具条（电源菜单、Ctrl+Alt+Del、
  截图、状态文本）。返回列表时 VM 继续在后台跑。

**QMP 通道**：VM 启动参数带 `-qmp tcp:127.0.0.1:<port>,server=on,
wait=off`；父进程 `qmp.cpp` 是极简 QMP TCP 客户端（每端口一条
连接、命令串行、events 经 tsfn 推给 ArkTS），直连子进程里 qemu 的
loopback 监听（NCP NORMAL 隔离共享网络）。UI 包装的电源功能：
暂停/恢复（`stop`/`cont`）、复位（`system_reset`）、强制断电
（`quit`）、Ctrl+Alt+Del（`send-key ctrl-alt-delete`）。SHUTDOWN /
STOP / RESUME 等事件驱动 UI 状态。**必须声明
`ohos.permission.INTERNET`**，否则 qemu 建 socket 即 EPERM 退出。

**截图**：napi `captureScreen()` 经 IPC 让子进程把 back buffer 当前帧
缩放到 ≤512 宽转 RGBA_8888 回传（binder 事务大小限制），ArkTS 侧包成
PixelMap `packToFile` 存为列表页缩略图。

**一进程一轮 VM 的限制（已由 NCP 子进程架构解决）**：qemu 的
`qemu_add_opts`/`qemu_add_drive_opts` 向静态数组重复注册会 `abort()`，
且 dlclose 后 TLS 析构会跳到已卸载代码——同一进程无法安全地第二次
进入 `qemu_system_entry`。因此每次启动 VM 都拉起一个**新的 NCP 子进程**
（见下节），VM 退出子进程随之退出，再启动无需任何重启。

### 6. 子进程架构（NCP）：选型与实施

目标：qemu 放进独立子进程（每次启动 VM 都是干净进程，绕开「一进程
一轮 VM」），且子进程**直接渲染**到应用 XComponent，不走共享内存
帧缓冲。选型做过三轮 spike（spike 代码已删，结论保留）：

1. **裸 fork + surfaceId**：排除。fork 本身可用，子进程里
   `CreateNativeWindowFromSurfaceId` 也能成功（命中的是 fork 继承的
   进程内 surface 注册表），但首次 `RequestBuffer` 时 SIGSEGV——
   Binder 应答 parcel 带 fd（`Parcel::InjectOffsets`），继承自父进程
   的 libipc_single 状态在子进程里是残缺的（崩溃栈：
   `BinderInvoker::HandleReply → BufferClientProducer::RequestBufferCommon`）。
2. **NCP + 裸 surfaceId**：排除。`OH_Ability_StartNativeChildProcess`
   拉起的干净子进程里 `CreateNativeWindowFromSurfaceId` 返回
   `NATIVE_ERROR_INVALID_ARGUMENTS`（40001000）——surfaceId 的查找
   依赖进程内注册表，对三方应用跨进程不成立（相机/AVPlayer 的跨进程
   渲染是框架在应用进程内建 window 再 parcel 给系统服务，不是裸 id）。
3. **NCP + IPC parcel 传窗口对象**：**可行，即现行架构**（spike 截图
   docs/screenshot-ncp-render.jpeg）。

wineohos 的 virgl_child 走的也是第 3 条（其 C6 协议）；注意他们记录
phone 形态下 OHNativeWindow 不能跨 Binder 传（退化为 shm 渲染），
2in1/Pad/模拟器形态可用。

**实施**（已落地）：

- 父进程（`libentry.so`）：`ncp_client.cpp` 封装
  `OH_Ability_CreateNativeChildProcess("libqemu_child.so")` 与全部
  IPC 请求；`qmp.cpp` 不变（QMP 走 loopback TCP 直连子进程里的 qemu，
  `NCP_ISOLATION_MODE_NORMAL` 共享网络与沙箱）。
- 子进程（`libqemu_child.so`）：`qemu_child.cpp` 导出
  `NativeChildProcess_OnConnect`/`MainProc`，跑 vm/fb/renderer/input
  全套；`MainProc` 阻塞到「VM 一轮结束」或收到 kShutdown 或父进程
  消失（stub destroy 回调），返回后进程退出。
- IPC 协议（`qemu_ipc.h`，每请求带版本号）：START（arch+argv+窗口
  parcel）/ATTACH/DETACH/RESIZE/POINTER/KEY/QUERY/SCREENSHOT（子进程
  缩放到 ≤512 宽 RGBA 回传，受 binder 事务大小限制）/SHUTDOWN。
- 窗口传递：父进程用 surfaceId `CreateNativeWindowFromSurfaceId` 建
  OHNativeWindow → `OH_NativeWindow_WriteToParcel` 发给子进程 → 子进程
  `ReadFromParcel` 取出后建 EGL 渲染（GL letterbox，与原先同一代码）。
- TCG JIT 的可执行内存 ACL 在子进程正常生效（module.json5 的
  `kernel.ALLOW_WRITABLE_CODE_MEMORY` 等按 uid 继承）。
- `vmRunning()` 自愈：NCP 的 exit 回调实测不可靠（有不触发的情况），
  改为每次调用都向子进程发 QUERY，子进程死了（发送失败）或 VM 已退出
  （running=0）就就地清理状态——关机后再启动因此总能拉起新子进程。

实施期踩到的三个新坑（都已修，见「踩坑记录」）：转场期挂窗必崩、
resize 早于子进程启动会丢失、EGL swap 失败需重建 surface 重试。

## 目录

```
deps/            QEMU 及依赖的交叉编译（HiSH 体系）
entry/libs/      deps 产物：libqemu-system-{x86_64,i386,aarch64}.so 等
entry/src/main/cpp/    父进程 libentry.so：napi_init / qmp / ncp_client
                       （+ qemu_ipc.h 协议）；
                       子进程 libqemu_child.so：qemu_child / vm / fb /
                       renderer / input（+ qemu_abi.h 等）
entry/src/main/ets/    EntryAbility（固件解压）+ pages/{VmList,VmEdit,Console}
                       + lib/{vmprofile,keymap}
images/          guest 镜像（本地缓存，不进 HAP）
Makefile         顶层构建入口：make deps | hap | install | deploy | log
```

## 构建与验证

```bash
export TOOL_HOME=/apps/harmony
make deps          # 交叉编译 qemu（首次较久，依赖网络下载 tar 包）
make hap           # 构建 HAP（x86_64 ABI）
make install       # 经 hdc（192.168.1.3:8710 上的 127.0.0.1:5555）安装启动
make log           # 抓取应用日志
```

首次启动先不带盘验证 SeaBIOS「No bootable device」画面，即可证明
显示链路端到端打通；随后用 `-cdrom alpine-virt-x86_64.iso` 启动
Alpine Linux 验证完整引导。

## PoC 验证结果（2026-08-21，x86_64 模拟器 api24）

已端到端验证通过（截图见 docs/screenshot-*.jpeg）：

- 管理 UI：列表页（种子 profile、缩略图、运行中标记、启动/进入）、
  配置页表单、Console 页工具条（电源菜单/Ctrl+Alt+Del/截图）。
- Alpine Linux 3.21 (kernel 6.12) 从 ISO 引导到 `localhost login`
  （TCG 下约 50s），键盘输入可进 shell。
- QMP 电源控制：暂停/恢复（STOP/RESUME 事件驱动状态）、强制断电
  （quit → SHUTDOWN → 状态变"已关机"）。
- 截图缩略图：Console 点"截图"或返回列表时自动更新卡片缩略图
  （子进程缩放到 ≤512 宽经 IPC 回传）。
- **关机后再启动：无任何重启**——QMP quit → 子进程退出 → 再点启动
  拉起全新 NCP 子进程，引导到 login（对比旧架构：需重启应用进程）。
- 离开 Console 再进入：VM 后台继续跑，重进时重新挂窗画面即恢复。
- 显示模式切换正常：SeaBIOS 640x480 → VGA 文本 720x400 →
  bochs-drm 1280x800（gfx_switch 回调驱动纹理重建）。
- 键盘：HarmonyOS KeyCode → QKeyCode 映射表由脚本从 SDK d.ts 与
  qemu 生成的 qapi-types-ui.h 生成（entry/src/main/ets/lib/keymap.ets
  + entry/src/main/cpp/qkeycode_gen.h）。

### 踩坑记录

- `pixman_format_code_t` 编码是 `(bpp<<24)|(type<<16)|(a<<12)|(r<<8)|
  (g<<4)|b`，手算易错（第一字段是 bpp 不是 type）；已改为从 pixman.h
  计算的数值常量。遇到未识别格式会先涂 magenta（0xffff00ff）兜底。
- `fs.mkdirSync(dir, true)` 在目录已存在时抛 13900015 (EEXIST)，需先
  `fs.accessSync` 判断。
- hilog 自定义大 domain（0xD0039xx）不输出，用 0x0001~0x0007 小 domain。
- `uitest uiInput click` 坐标点击不稳定（可能因焦点/时序），PoC 阶段用
  XComponent onSurfaceCreated 回调自动 startVm 规避。
- Select/Button 需 `.focusable(false)`，否则按键焦点落在 Select 上，
  Enter 会打开下拉框而不是发给 guest。
- hdc shell 非 root，不能直接写应用沙箱；guest 镜像走 rawfile 打包 +
  首启解压（ISO ~66MB 会使每次 HAP 打包变慢，后续可换 DocumentPicker
  或 qemu-img 在线创建方案）。
- QMP 走 loopback TCP 也必须声明 `ohos.permission.INTERNET`，否则
  qemu 建 socket 时 EPERM 直接退出（表象是 VM 一启动就 SIGABRT）。
- qemu 同进程不能二次进入 `qemu_system_entry`：`qemu_add_opts`/
  `qemu_add_drive_opts`（util/qemu-config.c）对静态数组重复注册会
  `abort()`；dlclose 也不可行（本线程退出时执行 qemu 注册的 TLS
  析构会跳到已卸载代码）。解法：NCP 子进程一进程一轮（见第 6 节）。
- 裸 fork 的子进程不能做 NativeWindow 渲染：继承的 Binder 状态在
  带 fd 的 parcel 应答（`Parcel::InjectOffsets`）上 SIGSEGV；
  干净进程里裸 surfaceId 查找返回 40001000（进程内注册表）。
  跨进程传窗口必须父进程建 OHNativeWindow 再 WriteToParcel。
- 页面转场期间立刻给子进程挂窗，EGLSurface 首次 swap 必报
  EGL_BAD_SURFACE(0x300d) 且不可自愈（重建 EGLSurface 也救不回来）；
  修复：onSurfaceCreated 后延迟 ~500ms 再挂窗（Console.ets）。
- 父进程发给子进程的 resize 若早于子进程启动会丢失：渲染线程启动时
  用 `eglQuerySurface(EGL_WIDTH/HEIGHT)` 兜底拿窗口实际尺寸。
- NCP 的 `OH_Ability_RegisterNativeChildProcessExitCallback` 实测
  不可靠（有子进程退出但不触发的情况）；`vmRunning()` 改为向子进程
  发 QUERY 自愈（发送失败或 running=0 即清理状态）。
- 二次注册 DCL 前必须 `fb_reset()` 清掉 g_dcl.ds/con，否则触发
  qemu `assert(!dcl->ds)`。
- 重新进入 Console（surface 销毁重建）后黑屏：渲染线程只在脏帧时上传
  纹理，而新建的 GL 纹理是空的、旧纹理尺寸缓存又使全量分支不命中，
  guest 无输出时就永远不上传。修复：attach 时重置 `texW/texH` 为 0，
  强制首轮从 back buffer 全量回传。
