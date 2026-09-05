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

- 设备（2in1 真机，API 24）：`hdc -t 192.168.1.4:44959`（已 `tconn` 过）。
  **该设备要求签名包**：`make deploy` 会先经 `sign.py`（借自 wineohos，用
  `.ohos/` 下调试证书 + hap-sign-tool 本地签名）产出 entry-default-signed.hap
  再安装。
- 沙箱路径映射（hdc 视角 → 应用内视角；hdc shell/file 用左列可直接读写）：
  - `/data/app/el2/100/base/app.hackeris.hium/haps/entry/files/` → 应用内
    `/data/storage/el2/base/haps/entry/files/`（vms/ 配置与镜像、vm/ 固件与日志）
  - 用户 Download 目录：`/storage/media/100/local/files/Docs/Download/app.hackeris.hium/`
    （DocumentPicker 里显示为应用名「HiUM」；picker 解析出的真实路径是
    `/storage/Users/currentUser/Download/app.hackeris.hium/...`）
- `deps/` 子包单独构建：`make -C deps/<pkg> OHOS_ARCH=x86_64 OHOS_ABI=x86_64`，
  需要环境里有 `OHOS_SDK_HOME=$TOOL_HOME/sdk/default/openharmony`（直接调子包
  Makefile 时 deps/Makefile 里的导出不会生效）。
- 网络不稳定时给 wget/git 加重试；曾有代理 `192.168.1.3:7897`（临时，可能已失效）。

## 代码结构

- `entry/src/main/cpp/`：两个 so 目标。**父进程 libentry.so**（ArkUI 进程）：
  `napi_init.cpp`（napi 绑定，接口按 vmId 路由）、`ncp_client.{h,cpp}`
  （vmId → NCP 子进程注册表 + IPC 客户端，拉起串行化）、`qmp.cpp`
  （QMP unix socket 客户端，每 VM 一条，直连子进程里的 qemu）、
  `qemu_ipc.h`（父子进程 IPC 协议，带版本号）。**子进程 libqemu_child.so**
  （NCP，一进程一台 VM，多实例并存）：`qemu_child.cpp`（OnConnect/MainProc/
  IPC 分发）、`vm.cpp`（dlopen qemu .so + DCL 注册轮询）、`fb.cpp`（DCL 回调 +
  像素格式转换 + 截图缩放）、`renderer.cpp`（NativeWindow/EGL/GLES 渲染线程，
  窗口经 IPC parcel 传入）、`input.cpp`（输入注入）、`qemu_abi.h`（qemu 内部
  结构/符号的最小 ABI 复刻）、`qkeycode_gen.h`（从 qemu 构建产物生成的
  QKeyCode 值）。
- `entry/src/main/ets/`：`entryability/EntryAbility.ets`（入口，初始化走
  `lib/bootstrap.ets` 幂等引导：rawfile 固件解压到 filesDir/vm + AppStorage 公共键）、
  `myabilitystage/MyAbilityStage.ets`（specified 模式按 vmId 归并窗口实例）、
  `vmconsoleability/VmConsoleAbility.ets`（每台 VM 一个独立沉浸式窗口，
  loadContent 前经 `lib/vmwindows.ets` 的 pending FIFO 传 vmId）、
  `pages/Index.ets`（导航壳 + 各弹窗宿主）、`pages/VmList.ets`（VM 列表）、
  `pages/VmWizard.ets`（创建向导：介质步支持新建空白盘/导入 qcow2·img·raw
  （创建时复制进 vms/）与直接内核引导（kernel/initrd/append，同样复制进 vms/））、
  `pages/VmEdit.ets`（配置表单）、`pages/VmManage.ets`（详情）、
  `pages/VmStorage.ets`（存储/快照弹窗）、`pages/VmConsole.ets`（独立窗口内的
  XComponent 画面 + 工具条；挂窗在 surface 创建后延迟 500ms，见 DESIGN.md 踩坑记录）、
  `lib/vmprofile.ets`（VmProfile schema v3 模型/VmStore 持久化/buildArgs）、
  `lib/isoPick.ets`（picker 文件选择，URI→真实路径）、`lib/fsutil.ets`（路径守卫 +
  复制；writeSync 切勿传 offset:0，详见 DESIGN.md 踩坑记录）、
  `lib/keymap.ets`（HarmonyOS KeyCode → QKeyCode 生成表）。
- 改 ArkTS 或 cpp 只需 `make deploy`；只有改了 deps 才需要 `make deps`（很慢）。

## 注意

- `entry/src/main/resources/rawfile/vm/` 和 `entry/libs/` 由 deps/构建产物
  填充（含 ~66MB Alpine ISO），不入 git（见 .gitignore）。没有跑过
  `make deps` 的干净 checkout 需要先 `make deps` 才能出可运行的包。
- native 日志 tag：QemuEntry/QemuUI/QemuRender/QemuVM/QemuFB/QemuNapi/
  QemuInput/QemuQmp/QemuChild（hilog domain 0x0001-0x0008；自定义大
  domain 不会输出）。
- 更新 qemu 版本时：`qemu_abi.h` 的结构体布局需要与 qemu 源码重新核对
  （DisplayChangeListenerOps / DisplaySurface，CONFIG_OPENGL=off 变体）。
- VM 跑在 NCP 子进程（libqemu_child.so），一进程一台 VM、可多台并行：
  退出后父进程另起新子进程即可再启动，无需重启应用。窗口经
  `OH_NativeWindow_WriteToParcel` 跨进程传（裸 surfaceId 跨进程不可用，
  裸 fork 更不行，详见 docs/DESIGN.md「子进程架构」与踩坑记录）。
  QMP 走每 VM 一条的 unix socket（`filesDir/vm/qmp-<vmId>.sock`），
  不再有端口冲突问题。
