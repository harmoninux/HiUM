# Windows 11 支持设计（guestOS 类型 + 真 TPM）

> 日期：2026-08-29
> 类型：设计备忘（feature spec）
> 触发：用户需要虚拟机支持跑 Windows 11。调研 HiVM（gitee.com/yhmong/HiVM，同一作者 HiSH 分支）证实：**Windows 11 ARM64 与 x64 都能在本工程的 QEMU fork（`harmoninux/qemu` 分支 `hish-libqemu`）上装起并启动**，只是 TCG 软模拟下很慢。用户最终拍板：**一次性全做**（guestOS 类型驱动 + 真 TPM 2.0），不做分期交付。

## 结论一句话

**给 VmProfile 增加 `guestOS` 字段（`linux` / `windows11`），`buildArgs` 按它切换到「Windows 友好设备组 + OVMF/AAVMF UEFI（pflash CODE+VARS）+ 真 TPM 2.0（swtpm）」。选 Windows 11 即用官方 ISO + virtio-win 驱动装；真 TPM 就绪后免注册表绕过，绕过仅作兜底。**

## 调研结论（支撑可行性的关键事实）

参考 **HiVM**（`/data/share/qemuohos/.temp/HiVM`，已 depth=1 克隆）：

1. **同一 QEMU fork**：HiVM 的 `deps/libqemu/Makefile` 与本地完全一致 —— `git clone -b hish-libqemu https://github.com/harmoninux/qemu`。故**无需换 QEMU、无需 Windows 补丁**，现有 `libqemu-system-{aarch64,x86_64}.so` 即可支持。
2. **Windows 11 ARM64 配置（`HiVM/.../lib/startVm.ets`）**，逐项为：
   - 机器：`-machine virt,acpi=on,gic-version=max,iommu=smmuv3,virtualization=on,memory-backend=mem0,usb=on,its=off,dump-guest-core=off,hmat=off,mem-merge=off,compact-highmem=on`（linux 用 `iommu=none,virtualization=off`）
   - CPU：`-cpu max,pauth=on,pauth-impdef=on,sve=off,pmu=on`
   - 内存：`-object memory-backend-ram,id=mem0,size=<X>M,merge=off,prealloc=off` + `-m <X>M`
   - 固件：pflash `AAVMF_CODE.secboot.fd`(ro) + 每 VM 可写 `<id>AAVMF_VARS.fd`，另加 `-fw_cfg name=opt/org.tianocore/UninstallMemAttrProtocol,string=y`
   - ISO：`qemu-xhci` + `usb-storage`
   - 磁盘：`virtio-scsi-pci`（windows 用 `cmd_per_lun=32,packed=off,iothread=iothread0`）+ `scsi-hd`，`logical_block_size=512`
   - 显示：`ramfb`（不是 virtio-gpu）
   - 键鼠：`usb-kbd` + `usb-tablet`
   - 安装：**官方 MS ISO**（精简版进不了安装界面）+ **virtio-win 驱动 ISO** + 注册表绕过
3. **固件来源（`HiVM/README.md:55`）**：`AAVMF_CODE.secboot.fd` 与 `AAVMF_VARS.fd` 可**由 `edk2-aarch64-code.fd` 与 `edk2-arm-vars.fd` 改名得到**。本工程 fork 的 `pc-bios` 已含：`edk2-aarch64-code.fd`、`edk2-arm-vars.fd`、`edk2-x86_64-code.fd`、`edk2-i386-vars.fd`。**固件全部现成，无需外部下载。**
4. **性能现实**（`HiVM/INSTALL-Windows11.md`）：安装约 4 小时、量产「流畅度未达可实用程度」。TCG 软模拟固有，不当作失败。
5. **注册表绕过**（HiVM 验证可行）：安装界面 `Shift+F10 → regedit → HKEY_LOCAL_MACHINE\SYSTEM\Setup → 新建 LabConfig → BypassTPMCheck=1 / BypassSecureBootCheck=1`，返回点下一步即可跳过 TPM/SecureBoot。真 TPM 就绪后此步可不做，仅作兜底。

## QEMU 运行形态（本工程与 HiVM 的差异）

- 本工程 qemu 不是独立进程：**`napi.startVm(vmId,arch,args,surfaceId)` → `ncp_client_start()` 由 ArkUI 父进程拉起「每 VM 一个 NCP 子进程」，qemu 在子进程内 `dlopen libqemu-system-<arch>.so` + `qemu_system_entry` 线程跑**（`cpp/vm.cpp`）。显示走 DCL 直连 XComponent surface（非 HiVM 的 VNC/noVNC）。
- 由此：**swtpm 必须是一个额外 spawn 的独立进程**（qemu `-tpmdev emulator` 经 chardev unix socket 连它）。native 侧已有 `imgtool_run`（fork/exec 一次性子进程）先例，可复用其机制。显示路径沿用本工程 DCL（`ramfb` 产生 pixman surface，DCL 能收到）。
- 虚拟键盘：本工程自研 `VirtualKeyboard` overlay + QMP 输入注入，Windows 走 `usb-kbd/tablet` 即可，无需 VNC。

## 方案

### 1. VmProfile 增加 `guestOS` 字段

```ts
export type GuestOs = 'linux' | 'windows11';
export interface VmProfile {
  ...
  guestOS: GuestOs;            // 新增，驱动 buildArgs 设备组
}
```

- `blankProfile()` 默认 `'linux'`。
- `normalizeV2()` 增加读入：`if (jStr(o,'guestOS')==='windows11') p.guestOS='windows11';` 缺省回填 `'linux'`。**SCHEMA_VERSION 保持 2**（沿用「新增字段 + 默认回填」模式，向后兼容）。
- 前端状态：向导/编辑页各加 `@State guestOS`，随所选 OS 切换默认值。

### 2. `buildArgs` 按 guestOS 分支（核心改动）

把 `buildArgs(p, vmDataDir, sharedDir)` 拆成「公共骨架 + linux 设备组 + windows 设备组」。设备组差异表：

| 维度 | linux（现状，不动） | windows11 |
|---|---|---|
| 系统盘 | `-drive if=virtio,format=qcow2` | `-global virtio-blk-pci.scsi=off` + `-drive if=none,format=qcow2,file=...,id=hd0,cache=writeback,discard=unmap` + `-object iothread,...` + `-device virtio-scsi-pci,id=scsi0,num_queues=2,virtqueue_size=128,iothread=iothread0` + `-device scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=512,physical_block_size=4096,rotation_rate=1,bootindex=1` |
| 网卡 | `-netdev user` + `virtio-net-pci` | x64 默认 `e1000`（安装阶段免驱动）；arm 用 `virtio-net-pci`（装时挂 virtio-win 驱动） |
| 显卡 | `virtio-gpu`(virt) / `-vga std`(pc) | **`ramfb`** |
| 键鼠 | `usb-ehci` + `usb-kbd` | **`qemu-xhci,id=usb`** + `usb-kbd,bus=usb.0` + `usb-tablet,bus=usb.0` |
| ISO | `-cdrom <path>` | `-drive if=none,format=raw,file=ISO,id=virtio_cd,media=cdrom,readonly=on` + `-device usb-storage,drive=virtio_cd,bus=usb.0,bootindex=2` |
| TPM | 无 | `-chardev socket,id=chrtpm,path=<ctrl>` + `-tpmdev emulator,id=tpm0,chardev=chrtpm` + `-device tpm-tis,tpmdev=tpm0` |
| ARM 机器 | `-machine virt` | `-machine virt,acpi=on,gic-version=max,iommu=smmuv3,virtualization=on,memory-backend=mem0,usb=on,its=off,dump-guest-core=off,hmat=off,mem-merge=off,compact-highmem=on` + `-object memory-backend-ram,id=mem0,size=<X>M,merge=off,prealloc=off` |
| CPU | `-cpu max` | `-cpu max,pauth=on,pauth-impdef=on,sve=off,pmu=on` |
| 固件 | `-bios edk2-*.fd`(arm) / seabios(x86) | **pflash** CODE(ro) + 每 VM VARS(rw) |

common（两态共用）：`-L vmDataDir -m -smp -accel tcg -display none -qmp ...`。

**固件接线（windows 分支）**：
- x86_64：CODE=`vmDataDir/edk2-x86_64-code.fd`，VARS=`vmDataDir/<id>-ovmf-vars.fd`
- aarch64：CODE=`vmDataDir/edk2-aarch64-code.fd`（即 AAVMF_CODE），VARS=`vmDataDir/<id>-aavmf-vars.fd`
- 生成：
```
-drive if=pflash,format=raw,file=<CODE>,readonly=on
-drive if=pflash,format=raw,file=<VARS>
```
- ARM windows 另加：`-fw_cfg name=opt/org.tianocore/UninstallMemAttrProtocol,string=y`

**每 VM 可写 VARS 的创建**：VM 新建（`VmWizard` 保存）/ 从 linux 模板切到 windows 时，把模板 VARS（x64=`edk2-i386-vars.fd`，arm=`edk2-arm-vars.fd`）复制成 `<id>-{ovmf|aavmf}-vars.fd`（`fs.copy`/native）。qemu pflash 的 VARS 由 qemu 改写（boot 配置、TPM 状态），须每 VM 独立，避免多 VM 共享同一份被写坏。

### 3. 真 TPM 2.0（swtpm）

**依赖（deps）**：往 `deps/libqemu/Makefile` 的构建链加两个新包并交叉编译产出 `swtpm` 可执行：
- `libtpms`（软件 TPM 实现）
- `swtpm`（TPM 守护进程）

打包进 HAP（`entry/src/main/resources/rawfile/bin/swtpm`），`bootstrap.ets` 解包到 `vmDir/swtpm`。

**进程管理（native 层）**：
- 新增 napi：`startSwtpm(vmId, ctrlSock, tpmDir): number` 与 `stopSwtpm(vmId): void`（内部按 pidfile 管理）。
- 启动流（`VmConsole.startVm` + native）：**先** spawn swtpm，再 ncp_client_start 跑 qemu：
  ```
  swtpm socket --tpm2 --tpmstate dir=<vmDataDir>/tpm-<id>/ \
    --ctrl type=unixio,path=<vmDataDir>/swtpm-<id>.sock \
    --log file=<vmDataDir>/swtpm-<id>.log --daemon --pid file=<vmDataDir>/swtpm-<id>.pid
  ```
- 等 ctrl socket 就绪（bounded，如 5s；超时则报错取消启动）。
- 把 `<vmDataDir>/swtpm-<id>.sock` 作为 chardev path 塞进 qemu argv（`-chardev socket,id=chrtpm,path=...`）。
- 退出（`VmConsole` 停止/销毁）：`stopSwtpm(vmId)`（pidfile kill + 进程组级联）。

**独立进程的必要性**：qemu `-tpmdev emulator` 后端经 chardev socket 连外部 swtpm，不是进程内 libtpms（`cpp` 调研确认 `backends/tpm/tpm_emulator.c` 走 chardev+PTM 协议）。故真 TPM 必须多一个进程。

### 4. Windows 11 模板与向导/UI

- 向导新增 **guestOS 选择**（`Linux` / `Windows 11`），选 `windows11` 时自动带默认：
  - arch 可选 `x86_64` / `aarch64`（Windows 11 两平台都有）
  - board=`q35`(x64) / `virt`(arm)；firmware=`ovmf`
  - memory 默认 `8192`（Win11 ≥4GB 建议 8GB；滑块上限 8192）
  - cpus 默认 `4`
  - 系统盘尺寸默认 ≥64GB（Win11 建议装完需 >64GB）
  - 从光盘启动 `true`（默认走 ISO）
- 存储/配置页：`guestOS` 决定 ISO 走 usb-storage；「共享目录(9p)」在 windows 下**置灰**（需 virtio-win 驱动，暂不支持）。
- **安装引导**：windows11 模板首次启动弹说明弹窗：官方 ISO 地址、virtio-win 驱动地址、注册表绕过步骤（真 TPM 就绪后此项为「如需可跳过」兜底）。

### 5. 错误处理

- swtpm spawn 失败 / socket 超时 → toast「TPM 启动失败」取消启动（不让 qemu 挂空 root；同时保留「无 TPM + 注册表绕过」提示）。
- 模板 VARS 缺失 / 固件未解包 → 启动前拦截，提示重新选 Windows 模板。
- Windows 慢启动属预期（TCG），不当作失败；语义错仍走 `qemu-<id>.log` 弹窗（`VmConsole.failStart`）。

## 实现位置清单

| 文件 | 职责 |
|---|---|
| `lib/vmprofile.ets` | 加 `GuestOs` 类型 + `guestOS` 字段；`buildArgs` 按 guestOS 分支（windows 设备组/固件/TPM） |
| `lib/fsutil.ets` | 加 `copyFile`（模板 VARS → 每 VM VARS） |
| `deps/libqemu/Makefile` | FIRMWARE 列表加 `edk2-x86_64-code.fd`、`edk2-i386-vars.fd`、`edk2-arm-vars.fd`；构建 `libtpms`/`swtpm` |
| `deps/*` | 新增 libtpms、swtpm 两个构建子目录 |
| `lib/bootstrap.ets` | FIRMWARE_FILES 加 x86 OVMF/arm VARS；解包 `swtpm` 二进制 |
| `cpp/napi_init.cpp` | 新增 `startSwtpm`/`stopSwtpm` napi；`startVm` 接收 windows 参数 |
| `cpp/vm.cpp` | swtpm spawn/回收链路（复用 `imgtool_run` 的 fork/exec） |
| `pages/VmWizard.ets` | guestOS 选择 + windows 默认值 + 模板 VARS 复制 + 安装引导 |
| `pages/VmEdit.ets` | guestOS 展示/切换 + windows 下共享目录置灰 |
| `pages/VmStorage.ets` | ISO usb-storage 说明 |
| `pages/VmConsole.ets` | `startVm` 先 spawn swtpm；停止时回收；windows 引导弹窗 |
| `README` / `docs` | Windows 11 安装手册（参考 HiVM INSTALL-Windows11.md 改写） |

## 风险点（实现前先验证）

### 实测结论（2026-08-29 已完成验证）
- **ARM 机器属性 + AAVMF pflash（风险 #4）**：宿主 `qemu-system-aarch64` 冒烟通过——`-machine virt,acpi=on,gic-version=max,iommu=smmuv3,virtualization=on,memory-backend=mem0,...` + `-cpu max,pauth=on,...` + pflash `edk2-aarch64-code.fd` + VARS 被 qemu 完整接受（无 `unsupported machine`/`unknown CPU`，进程跑满 25s）。真机上 windows VM 也用该命令行拉起成功。
- **x86 OVMF pflash 配对（风险 #1）**：宿主无 `qemu-system-x86_64` 无法冒烟；真机 `edk2-x86_64-code.fd` 已正常解包。x64 OVMF 生效需真机装 Windows 时确认（已按 `edk2-i386-vars.fd` 作为 VARS 模板）。**属待真机验证项。**
- **swtpm 交叉编译（风险 #2）**：**可行且已落地**——成功把 `swtpm`（aarch64, musl）连同 `libtpms.so.0`/`libswtpm_libtpms.so.0`/`libjson-glib-1.0.so.0`/`libcrypto.so.3`（+复制的 `libpcre2-8.so.0`/`libz.so.1`）交叉编译，打进 `rawfile/bin/swtpm/`，bootstrap 解包、native `swtpm_start` 设 `LD_LIBRARY_PATH`+`chmod`。QEMU 已内建 `-tpmdev emulator`+`tpm-tis`（只缺外部 swtpm 进程）。**真机解包成功（日志 `swtpm unpacked ok=true`）；swtpm 实际运行 + qemu tpm-tis 连接需用户启动一个 windows VM（security.tpm=true）验证——无法纯程序化自动做（需 UI 交互/4h 安装）。**
- **QEMU 机器属性 parse**：宿主 qemu 冒烟通过，无报错。

## 风险点（实现前先验证）

1. **x86 OVMF 固件配对**：`edk2-x86_64-code.fd` + `edk2-i386-vars.fd` 是否被本 fork 接受。HiVM 只在 ARM 验证过。→ 用真 qemu 冒烟 `-machine q35 -drive if=pflash,...` 测 pflash 可 boot。若 i386-vars 不合，尝试 `edk2-i386-code.fd` 或自造空 VARS。
2. **swtpm 能否在 HarmonyOS aarch64 交叉编译 + 沙箱 spawn**：这是 C 失败的最大可能处。→ 先在小棒上交叉编译 `swtpm socket --tpm2` 验证能起、能被 qemu `-tpmdev emulator` 连接。若失败，兜底：真 TPM 降级为「注册表绕过 + 无 TPM」跑 Win11（功能仍可用，仅安装多一步）。
3. **x64 网卡驱动**：Windows 11 x64 用 `virtio-net` 需 virtio-win 驱动；`e1000` 有原生驱动但慢。→ 安装阶段默认 `e1000`（免驱动），装完可提示换 virtio。
4. **qemu 机器属性 parse**：本 fork 的 `virt` 是否接受 `iommu=smmuv3,virtualization=on`（HiVM 未在本工程 fork 实机验证）。→ 用真 qemu `-machine virt,...` 冒烟。

## 测试

- 编译：`make deps`（含新包）+ `make hap` 通过。
- 真机 192.168.1.4:44959：建「Windows 11 x64」「Windows 11 ARM64」模板 → 启动出 UEFI 提示（OVMF/AAVMF logo）→ 挂官方 ISO 进安装界面 → Shift+F10 注册表绕过（或真 TPM 免绕过）→ 装完进系统、usb-kbd/tablet、ramfb 显示、QMP 关机生效。
- swtpm：日志无报错、`-tpmdev emulator` 连接成功、VM 退出后 swtpm 进程被回收。
- 回归：linux 各模板（x86_64/aarch64/arm/loongarch64/riscv64）启动不受 guestOS 分支影响。

## 相关文档

- HiVM 参考：`/data/share/qemuohos/.temp/HiVM`（`lib/startVm.ets` Windows ARM 配置、`INSTALL-Windows11.md` 安装流程、`README.md:55` 固件改名法）。
- 本工程现有：`2026-08-29-vm-param-validation-design.md`（qemu 语义错走 `qemu-<id>.log` 兜底）；`vmprofile.ets buildArgs`、`bootstrap.ets`、`cpp/vm.cpp`（NCP 进程/单线程 qemu）。
