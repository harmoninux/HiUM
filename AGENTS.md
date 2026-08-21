# AGENTS.md

HarmonyOS 上的 QEMU TCG 模拟器 PoC。架构与方案细节见 `docs/DESIGN.md`。

## 构建

```bash
export TOOL_HOME=/apps/harmony   # HarmonyOS 命令行工具根目录

make deps     # 交叉编译 qemu（deps/，产物进 entry/libs/<abi>/ 与 rawfile/vm/）
make hap      # 构建 HAP：entry/build/default/outputs/default/entry-default-unsigned.hap
make deploy   # hap + 推送安装到测试设备并启动
make log      # 过滤抓取应用 hilog
```

- 设备（当前为 x86_64 模拟器，API 24）：经 `hdc -s 192.168.1.3:8710 -t 127.0.0.1:5555` 访问，**无需签名**（未签名的 entry-default-unsigned.hap 可直接 `bm install`）。
- `deps/` 子包单独构建：`make -C deps/<pkg> OHOS_ARCH=x86_64 OHOS_ABI=x86_64`，
  需要环境里有 `OHOS_SDK_HOME=$TOOL_HOME/sdk/default/openharmony`（直接调子包
  Makefile 时 deps/Makefile 里的导出不会生效）。
- 网络不稳定时给 wget/git 加重试；曾有代理 `192.168.1.3:7897`（临时，可能已失效）。

## 代码结构

- `entry/src/main/cpp/`：native 层。`vm.cpp`（dlopen qemu .so + DCL 注册轮询）、
  `fb.cpp`（DCL 回调 + 像素格式转换）、`renderer.cpp`（NativeWindow/EGL/GLES
  渲染线程）、`input.cpp`（输入注入）、`qmp.cpp`（QMP TCP 客户端，电源控制/
  事件推送）、`qemu_abi.h`（qemu 内部结构/符号的最小 ABI 复刻）、
  `qkeycode_gen.h`（从 qemu 构建产物生成的 QKeyCode 值）。
- `entry/src/main/ets/`：`EntryAbility.ets`（rawfile 固件/ISO 解压到
  filesDir/vm）、`pages/VmList.ets`（VM 列表）、`pages/VmEdit.ets`（配置
  表单）、`pages/Console.ets`（XComponent 画面 + 电源/截图工具条）、
  `lib/vmprofile.ets`（VmProfile 模型/VmStore 持久化/buildArgs）、
  `lib/keymap.ets`（HarmonyOS KeyCode → QKeyCode 生成表）。
- 改 ArkTS 或 cpp 只需 `make deploy`；只有改了 deps 才需要 `make deps`（很慢）。

## 注意

- `entry/src/main/resources/rawfile/vm/` 和 `entry/libs/` 由 deps/构建产物
  填充（含 ~66MB Alpine ISO），不入 git（见 .gitignore）。没有跑过
  `make deps` 的干净 checkout 需要先 `make deps` 才能出可运行的包。
- native 日志 tag：QemuEntry/QemuUI/QemuRender/QemuVM/QemuFB/QemuNapi/
  QemuInput/QemuQmp（hilog domain 0x0001-0x0008；自定义大 domain 不会输出）。
- 更新 qemu 版本时：`qemu_abi.h` 的结构体布局需要与 qemu 源码重新核对
  （DisplayChangeListenerOps / DisplaySurface，CONFIG_OPENGL=off 变体）。
- 一进程只能跑一轮 VM（qemu 静态 config 数组重复注册会 abort）；VM 退出后
  再启动走 `vms/.autostart` 标记 + `appRecovery.restartApp()` 重启进程，
  restartApp 被平台限频时是静默 no-op，手动重开应用等效（详见
  docs/DESIGN.md「一进程一轮 VM 的限制」）。
