# qemuohos —— HarmonyOS 上基于 QEMU TCG 的模拟器（PoC）

在 HarmonyOS 设备上用 QEMU TCG 纯软件模拟运行 x86 / x86_64 / arm64 guest，
并将 guest 屏幕**直接渲染**到 ArkUI（XComponent），不经过 VNC。

## 总体架构

```
┌────────────────────────────── 应用进程 ──────────────────────────────┐
│ ArkTS (Index.ets)                                                    │
│   └─ XComponent(SURFACE) ── surfaceId ──┐                            │
│                                          ▼                           │
│ libentry.so (napi)                       renderer.cpp                │
│   ├─ vm.cpp      VM 线程: dlopen(libqemu-system-<arch>.so)           │
│   │              调用 qemu_system_entry(argc, argv)                   │
│   ├─ fb.cpp      DCL 回调: gfx_switch/gfx_update/refresh              │
│   │              qemu 显存 → X8R8G8B8 back buffer（脏带合并）          │
│   ├─ renderer.cpp 渲染线程: back buffer → GL 纹理 → EGL 上屏          │
│   │              （letterbox 保持纵横比，vsync 限帧，无脏帧不 swap）    │
│   └─ input.cpp   触摸/键盘 → qemu_input_queue_abs/btn /               │
│                             qemu_input_event_send_key_qcode           │
└───────────────────────────────────────────────────────────────────────┘
```

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

## 目录

```
deps/            QEMU 及依赖的交叉编译（HiSH 体系）
entry/libs/      deps 产物：libqemu-system-{x86_64,i386,aarch64}.so 等
entry/src/main/cpp/    napi / vm / fb / renderer / input
entry/src/main/ets/    EntryAbility（固件解压）+ Index 页面
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

## PoC 验证结果（2026-08-20，x86_64 模拟器 api24）

已端到端验证通过（截图见 docs/screenshot-alpine-*.jpeg）：

- Alpine Linux 3.21 (kernel 6.12) 从 ISO 引导到 `localhost login`，
  键盘输入 `root` + Enter 进入 shell。TCG JIT 在模拟器上正常工作。
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
