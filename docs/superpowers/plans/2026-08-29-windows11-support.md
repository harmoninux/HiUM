# Windows 11 支持 实现计划（guestOS 类型 + 真 TPM）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 HiUM 能创建并启动 Windows 11 虚拟机（x64 与 ARM64），通过新增 `guestOS` 字段驱动 Windows 友好设备组 + OVMF/AAVMF UEFI（pflash CODE + 每 VM VARS）+ 真 TPM 2.0（swtpm）。

**Architecture:** `VmProfile` 增加 `guestOS: 'linux' | 'windows11'`；`buildArgs` 遇 `windows11` 交给新函数 `buildWinArgs`（Windows 设备组 + pflash 固件 + tpm-tis），linux 路径保持不动。固件用 fork 现成的 `edk2-x86_64-code.fd`/`edk2-i386-vars.fd`/`edk2-aarch64-code.fd`/`edk2-arm-vars.fd`，构建/解包补全它们。真 TPM 在 deps 新增 libtpms + swtpm 两个包，native 新增 `swtpm_start/swtpm_stop`，ArkTS 在 `VmConsole.doStart` 先启 swtpm 再 startVm。

**Tech Stack:** ArkTS/ArkUI（HarmonyOS）、NCP 子进程 + `dlopen` qemu、`fork/exec`（现有 `imgtool_run` 模式）、deps 交叉编译（`define_autotools_package` 宏）、swtpm/libtpms。

---

**前置事实（来自 spec + 调研，不再重复推导）：**
- QEMU fork：`harmoninux/qemu` 分支 `hish-libqemu`（HiVM 与本地一致），含 `edk2-x86_64-code.fd`、`edk2-i386-vars.fd`、`edk2-aarch64-code.fd`、`edk2-arm-vars.fd`、`edk2-arm-vars.fd`（均 `.bz2`）。
- Windows ARM 配方来自 HiVM `lib/startVm.ets`；x86 为其类比。Windows 11 需 `virt,acpi=on,gic-version=max,iommu=smmuv3,virtualization=on,memory-backend=mem0,usb=on,its=off,dump-guest-core=off,hmat=off,mem-merge=off,compact-highmem=on` + `-cpu max,pauth=on,pauth-impdef=on,sve=off,pmu=on` + `ramfb` + `usb-storage` ISO + `virtio-scsi`(512 扇区) + pflash `AAVMF_CODE`/VARS + `-fw_cfg name=opt/org.tianocore/UninstallMemAttrProtocol,string=y`。
- qemu 运行形态：`napi.startVm → ncp_client_start`（每 VM 一个 NCP 子进程，qemu 在子进程内 `dlopen` 跑）。swtpm 是额外独立进程。
- **风险 #2（真 TPM 构建/运行）是全程最大风险，HiVM 未做；无论如何，注册表绕过路径在 Plan 里完整实现，可独立交付。**

---

### Task 0: 风险冒烟验证（先做，验证 3 点，任一失败即据结果调整后续）

**Files:**
- 无（仅构建/运行验证）

意图：确认真 qemu 能否 parse HiVM 的 windows 命令行（尤其 `iommu=smmuv3,virtualization=on`）以及 x86 pflash 固化配对。**在 `make deps` 成功后、跑本任务；也可先用宿主机已编好的 `qemu-system-aarch64`/`qemu-system-x86_64` 直接验证。**

- [ ] **Step 1: aarch64 virt windows 机器属性冒烟**

在构建宿主上有 `libqemu-system-aarch64.so`（`deps/libqemu/build/`）后，跑：

```bash
# 用 dlopen 路径不方便直接跑，优先用宿主 qemu 二进制等价验证：
qemu-system-aarch64 \
  -machine virt,acpi=on,gic-version=max,iommu=smmuv3,virtualization=on,memory-backend=mem0,usb=on,its=off,dump-guest-core=off,hmat=off,mem-merge=off,compact-highmem=on \
  -cpu max,pauth=on,pauth-impdef=on,sve=off,pmu=on \
  -m 1024 -object memory-backend-ram,id=mem0,size=1024M,merge=off,prealloc=off \
  -display none -serial stdio -monitor none
```

预期：无 `unsupported machine` / 无 `unknown CPU` 报错，能进入固件/内核引导循环（`-serial stdio` 出现 UEFI 或内核输出）。若 `iommu=smmuv3,virtualization=on` 报不支持，则删除这两个属性再试，并在 spec 里标注——这将缩减 Windows ARM 的硬件可信度但保持可装。

- [ ] **Step 2: x86_64 q35 + OVMF pflash 冒烟**

```bash
qemu-system-x86_64 \
  -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file=/path/to/edk2-x86_64-code.fd \
  -drive if=pflash,format=raw,file=/path/to/vars.fd \
  -m 1024 -cpu max -display none -serial stdio -monitor none
```

`vars.fd` 先为 `edk2-i386-vars.fd` 的副本。预期：UEFI 启动进入（serial 出现 OVMF 或超时等待 boot）。若 qemu 报 pflash 尺寸不匹配，改试 `edk2-i386-code.fd`（配合 `edk2-i386-vars.fd`）作为 x86_64 的 CODE/VARS。**记录下配对，供 Task 2 `winFirmware()` 使用。**

- [ ] **Step 3: 记录结论**

把 Step 1/2 的实测配对与可用属性记到 `docs/superpowers/specs/2026-08-29-windows11-support-design.md` 的「风险点」段落（追加一行实测结论）。若 Step 2 失败，回退配对写进 `winFirmware()`。

---

### Task 1: vmprofile.ets — 加 `GuestOs` 类型 + `guestOS` 字段 + 迁移 + 固件/路径助手

**Files:**
- Modify: `entry/src/main/ets/lib/vmprofile.ets`

- [ ] **Step 1: 加类型与字段**

顶部 `VmArch` 定义旁新增：

```ts
export type GuestOs = 'linux' | 'windows11';
```

`VmProfile` 接口加：

```ts
export interface VmProfile {
  ...
  guestOS: GuestOs;   /* 驱动 buildArgs 设备组（linux/windows11） */
  ...
}
```

`blankProfile()` 加 `guestOS: 'linux'`。

`normalizeV2()` 末尾（`p.extraArgs = jStr(o,'extraArgs');` 前）加：

```ts
p.guestOS = jStr(o, 'guestOS') === 'windows11' ? 'windows11' : 'linux';
```

（`SCHEMA_VERSION` 保持 2；旧 json 缺字段走默认 `linux`。）

- [ ] **Step 2: 加 Windows 固件/路径助手（在 `builtinIsoFor` 附近）**

```ts
/* Windows 11 UEFI 固件：x64 用 x86_64 OVMF CODE + i386 VARS 模板；aarch64 用 AAVMF(aarch64 CODE) + arm VARS 模板。
 * CODE=fork pc-bios 现成；VARS 模板复制成每 VM 一份可写 VARS（qemu pflash 会改写 NVRAM）。 */
export function winFirmware(arch: VmArch): { code: string; varsTemplate: string } {
  if (arch === 'aarch64') {
    return { code: 'edk2-aarch64-code.fd', varsTemplate: 'edk2-arm-vars.fd' };
  }
  return { code: 'edk2-x86_64-code.fd', varsTemplate: 'edk2-i386-vars.fd' };
}

/* 每 VM 的可写 VARS 路径（模板复制至此，qemu pflash 挂它） */
export function winVarsPath(vmDataDir: string, id: string, arch: VmArch): string {
  const suffix = arch === 'aarch64' ? 'aavmf' : 'ovmf';
  return `${vmDataDir}/${id}-${suffix}-vars.fd`;
}

/* swtpm 控制 socket / tpmstate / pid 路径（qemu -chardev socket 与 native 共用） */
export function swtpmSockPath(vmDataDir: string, id: string): string {
  return `${vmDataDir}/swtpm-${id}.sock`;
}
export function swtpmPidPath(vmDataDir: string, id: string): string {
  return `${vmDataDir}/swtpm-${id}.pid`;
}
export function swtpmDir(vmDataDir: string, id: string): string {
  return `${vmDataDir}/tpm-${id}`;
}
```

- [ ] **Step 3: 校验迁移**

写不下单测框架；用一次性脚本逻辑断言：`migrateProfile({schemaVersion:2})` 的 `guestOS` 为 `'linux'`；`migrateProfile({schemaVersion:2, guestOS:'windows11'})` 的 `guestOS` 为 `'windows11'`。人工在 console 验证一次即可（或在 `VmWizard` 完成后看 profile json）。

- [ ] **Step 4: 提交**

```bash
git add entry/src/main/ets/lib/vmprofile.ets
git commit -m "feat(windows): VmProfile 增加 guestOS 字段与 win 固件/路径助手"
```

---

### Task 2: vmprofile.ets — `buildArgs` 的 Windows 分支（`buildWinArgs`）

**Files:**
- Modify: `entry/src/main/ets/lib/vmprofile.ets`

在 `buildArgs` 函数开头加一句分流，再新增 `buildWinArgs`：

- [ ] **Step 1: buildArgs 分流**

```ts
export function buildArgs(p: VmProfile, vmDataDir: string, sharedDir: string = ''): string[] {
  if (p.guestOS === 'windows11') {
    return buildWinArgs(p, vmDataDir);
  }
  /* ...以下保持原 linux 路径不动... */
}
```

- [ ] **Step 2: 新增 `buildWinArgs`**（放在 `buildArgs` 之后）

```ts
/* Windows 11 命令行：按架构自动选 Windows 最优设备组。
 *  x64   → q35 + SATA/AHCI 盘 + e1000 网卡 + std VGA（全 Windows 原生驱动，装时零驱动）
 *  arm64 → virt(smmuv3/virtualization=on) + virtio-scsi 盘 + virtio-net + ramfb（须 virtio-win 驱动）
 * 固件统一 OVMF/AAVMF pflash；TPM 由 swtpm（security.tpm）驱动。参考 HiVM startVm.ets。 */
export function buildWinArgs(p: VmProfile, vmDataDir: string): string[] {
  const mem = String(p.runtime.memoryMB);
  const cpus = String(p.runtime.cpus);
  const isArm = p.machine.arch === 'aarch64';
  const args: string[] = [
    '-L', vmDataDir,
    '-accel', `tcg,thread=${p.runtime.mttcg ? 'multi' : 'single'},tb-size=${p.runtime.tbSize}`,
    '-display', 'none',
    '-qmp', `unix:${qmpSockPath(p, vmDataDir)},server=on,wait=off`,
  ];
  /* 机器/CPU */
  if (isArm) {
    args.push(
      '-machine', 'virt,acpi=on,gic-version=max,iommu=smmuv3,virtualization=on,memory-backend=mem0,usb=on,its=off,dump-guest-core=off,hmat=off,mem-merge=off,compact-highmem=on',
      '-cpu', p.machine.cpuModel.length > 0 ? p.machine.cpuModel : 'max,pauth=on,pauth-impdef=on,sve=off,pmu=on',
      '-object', `memory-backend-ram,id=mem0,size=${mem}M,merge=off,prealloc=off`,
    );
  } else {
    args.push('-machine', 'q35');
    if (p.machine.cpuModel.length > 0) { args.push('-cpu', p.machine.cpuModel); }
  }
  args.push('-m', mem, '-smp', `cpus=${cpus},sockets=1,cores=${cpus},threads=1`);
  /* UEFI pflash：CODE(ro) + 每 VM 可写 VARS(rw) */
  const fw = winFirmware(p.machine.arch);
  const codePath = vmDataDir + '/' + fw.code;
  const varsPath = winVarsPath(vmDataDir, p.id, p.machine.arch);
  if (isArm) {
    args.push('-fw_cfg', 'name=opt/org.tianocore/UninstallMemAttrProtocol,string=y');
  }
  args.push(
    '-drive', `if=pflash,format=raw,file=${codePath},readonly=on`,
    '-drive', `if=pflash,format=raw,file=${varsPath}`,
  );
  /* 磁盘：x64 SATA/AHCI（原生驱动，免 virtio）；arm virtio-scsi 512 扇区（须 virtio-win） */
  if (p.media.diskPath.length > 0) {
    const fmt = p.media.diskPath.toLowerCase().endsWith('.qcow2') ? 'qcow2' : 'raw';
    if (isArm) {
      args.push(
        '-global', 'virtio-blk-pci.scsi=off',
        '-global', 'virtio-scsi-pci.cmd_per_lun=32',
        '-global', 'virtio-scsi-pci.packed=off',
        '-drive', `if=none,format=${fmt},file=${p.media.diskPath},id=hd0,cache=writeback,discard=unmap`,
        '-object', 'iothread,id=iothread0',
        '-device', `virtio-scsi-pci,id=scsi0,num_queues=${cpus},virtqueue_size=128,iothread=iothread0`,
        '-device', 'scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=512,physical_block_size=4096,rotation_rate=1,bootindex=1',
      );
    } else {
      args.push(
        '-device', 'ich9-ahci,id=sata',
        '-drive', `if=none,format=${fmt},file=${p.media.diskPath},id=hd0,cache=writeback`,
        '-device', 'ide-hd,drive=hd0,bus=sata.0',
      );
    }
  }
  /* 光盘 ISO：usb-storage 挂到全局 USB 控制器（Windows 安装阶段认 U 盘/光驱） */
  if (p.media.cdromPath.length > 0) {
    args.push(
      '-drive', `if=none,format=raw,file=${p.media.cdromPath},id=virtio_cd,media=cdrom,readonly=on`,
      '-device', 'usb-storage,drive=virtio_cd,bus=usb.0,bootindex=2',
    );
  }
  /* 键鼠：qemu-xhci + usb-kbd/tablet */
  args.push('-device', 'qemu-xhci,id=usb', '-device', 'usb-kbd,bus=usb.0', '-device', 'usb-tablet,bus=usb.0');
  /* 显示：x64 std VGA（原生驱动）；arm ramfb（HiVM 配方） */
  args.push(isArm ? '-device' : '-vga', isArm ? 'ramfb' : 'std');
  /* 网络：x64 e1000（原生驱动）；arm virtio-net（须 virtio-win） */
  if (p.net.enabled) {
    const netdev = userNetdev(p.net.portForwards);
    args.push('-netdev', netdev, '-device', isArm ? 'virtio-net-pci,netdev=n0' : 'e1000,netdev=n0');
  } else {
    args.push('-nic', 'none');
  }
  /* 真 TPM 2.0：外接 swtpm（qemu -tpmdev emulator 走 chardev socket 连 swtpm ctrl socket） */
  if (p.security && p.security.tpm) {
    const sock = swtpmSockPath(vmDataDir, p.id);
    const dev = isArm ? 'tpm-tis-device' : 'tpm-tis';
    args.push(
      '-chardev', `socket,id=chrtpm,path=${sock}`,
      '-tpmdev', 'emulator,id=tpm0,chardev=chrtpm',
      '-device', `${dev},tpmdev=tpm0`,
    );
  }
  /* Windows 不用 9p 共享（需 virtio-win 驱动），不挂 virtfs。自定义参数(escape hatch)追加到末尾。 */
  const extra = p.extraArgs.trim();
  if (extra.length > 0) {
    args = args.concat(extra.split(/\s+/));
  }
  return args;
}
```

> 说明：`userNetdev` 与 `parseForwards` 复用现有实现。把 `parseForwards` 的拼接抽成 `userNetdev(text)`（见 Step 3）。`p.security` 为 Task 3 新增字段（此处先按可选访问，避免编译报错——若先合 Task3 再合本任务更稳）。

- [ ] **Step 3: 新增 `userNetdev` 助手（供 buildArgs 与 buildWinArgs 复用）**

```ts
/* 组装 user 模式 netdev：自动挂 hostfwd（forward 条目由 parseForwards 产出） */
function userNetdev(portForwards: string): string {
  let netdev = 'user,id=n0';
  for (const fwd of parseForwards(portForwards)) {
    netdev += ',' + fwd;
  }
  return netdev;
}
```

并把 `buildArgs` 里 linux 路径的 netdev 组装改为复用 `userNetdev`（`let netdev = 'user,id=n0'; ...` 换成一行为 `const netdev = userNetdev(p.net.portForwards);`）（可选收敛，不改行为）。

- [ ] **Step 4: 无回归确认**

`VmWizard` 预览（`buildArgs`）对 linux 模板输出不变（`guestOS` 默认 `linux` 走原分支）。人工在向导第⑥步对比一次即可。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/lib/vmprofile.ets
git commit -m "feat(windows): buildArgs 新增 windows11 分支 buildWinArgs（设备组+pflash+TPM）"
```

---

### Task 3: vmprofile.ets — 加 `security.tpm` 字段（真 TPM 开关）

**Files:**
- Modify: `entry/src/main/ets/lib/vmprofile.ets`

`buildWinArgs` 里引用 `p.security.tpm`，先把这个字段落进模型（默认 false，避免深迁移；只有 Windows 模板才置 true。为使 Win11 无 TPM 兜底路径仍可跑，`tpm` 默认 false，装时靠注册表绕过；构建 `swtpm` 成功后由 UI/模板默认置 true）。

- [ ] **Step 1: 接口加字段**

```ts
export interface VmSecurity {
  tpm: boolean; /* 真 TPM 2.0：启动时额外 spawn swtpm 并挂 tpm-tis（默认 false） */
}
export interface VmProfile {
  ...
  security: VmSecurity;
  ...
}
```

`blankProfile()` 加 `security: { tpm: false }`。

`normalizeV2()` 加（复用 `jObj`）：

```ts
const sec = jObj(o, 'security');
if (sec) {
  p.security.tpm = jBool(sec, 'tpm', false);
}
```

- [ ] **Step 2: 提交**

```bash
git add entry/src/main/ets/lib/vmprofile.ets
git commit -m "feat(windows): VmProfile 增加 security.tpm 开关"
```

> 依赖说明：若先合 Task2 再合 Task3，Task2 里 `p.security` 暂为未定义字段；建议**按 Task2→3 顺序合**，或 Task2 里先写 `p.security && p.security.tpm`（ArkTS 对未定义接口字段访问会告警）。为稳妥：**先合 Task3（加字段）再合 Task2（引用它）**。把 Task2 里那行 `if (p.security && p.security.tpm)` 保留为空值安全写法即可。

---

### Task 4: fsutil.ets — 加 `copyFile`；vmprofile 加 `seedWinVars`

**Files:**
- Modify: `entry/src/main/ets/lib/fsutil.ets`
- Modify: `entry/src/main/ets/lib/vmprofile.ets`

- [ ] **Step 1: fsutil 加 `copyFile`**

```ts
/* 复制文件（vcms 内部复制固件模板 VARS → 每 VM 可写 VARS）。目标已存在则跳过；
 * 源缺失/复制失败返回 false，不抛。 */
export function copyFile(src: string, dst: string): boolean {
  try {
    if (!fs.accessSync(src)) { return false; }
    if (fs.accessSync(dst)) { return true; } /* 已存在，视为已就绪 */
    const inFd = fs.openSync(src, fs.OpenMode.READ_ONLY);
    const outFd = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    const buf = new ArrayBuffer(4 * 1024 * 1024);
    let n = 0;
    do {
      n = fs.readSync(inFd.fd, buf);
      if (n > 0) {
        fs.writeSync(outFd.fd, buf.slice(0, n), { offset: 0 });
      }
    } while (n > 0);
    fs.closeSync(inFd);
    fs.closeSync(outFd);
    return true;
  } catch {
    return false;
  }
}
```

- [ ] **Step 2: vmprofile 加 `seedWinVars`**

```ts
import { copyFile } from './fsutil';

/* 确保每 VM 的可写 VARS 存在：缺则从 winFirmware().varsTemplate 复制。
 * qemu pflash 的 VARS 会被改写，必须每 VM 一份（代码/模板是只读资产）。 */
export function seedWinVars(vmDataDir: string, id: string, arch: VmArch): boolean {
  const fw = winFirmware(arch);
  const src = vmDataDir + '/' + fw.varsTemplate;
  const dst = winVarsPath(vmDataDir, id, arch);
  return copyFile(src, dst);
}
```

> 注：VmWizard `finish()` / VmConsole `doStart()` 都调用它（幂等）。

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/lib/fsutil.ets entry/src/main/ets/lib/vmprofile.ets
git commit -m "feat(windows): fsutil 加 copyFile，vmprofile 加 seedWinVars"
```

---

### Task 5: deps + bootstrap — 打包 Windows UEFI 固件

**Files:**
- Modify: `deps/libqemu/Makefile`
- Modify: `deps/Makefile`
- Modify: `entry/src/main/ets/lib/bootstrap.ets`

- [ ] **Step 1: deps/libqemu/Makefile 的 FIRMWARE_OPT 加 x86 固件与 VARS**

`FIRMWARE_OPT :=` 行追加（它按 `.bz2` 解压到 `./build/`）：

```
edk2-x86_64-code.fd edk2-i386-vars.fd edk2-arm-vars.fd
```

（`edk2-aarch64-code.fd` 已在列表中。）

- [ ] **Step 2: deps/Makefile 的 copy 循环加对应文件名**

`for fw in ... edk2-aarch64-code.fd edk2-arm-code.fd edk2-loongarch64-code.fd edk2-riscv-code.fd; do cp output/$$fw ...` —— 在 `edk2-aarch64-code.fd` 前补 `edk2-x86_64-code.fd edk2-i386-vars.fd edk2-arm-vars.fd`。目标 `entry/src/main/resources/rawfile/vm/firmware/`。

- [ ] **Step 3: bootstrap.ets 的 FIRMWARE_FILES 加同名条目**

`FIRMWARE_FILES` 数组在 `'edk2-aarch64-code.fd'` 前加：

```ts
'edk2-x86_64-code.fd',   /* Windows x64 OVMF CODE（pflash） */
'edk2-i386-vars.fd',     /* x86 OVMF VARS 模板（复制成每 VM VARS） */
'edk2-arm-vars.fd',      /* aarch64 AAVMF VARS 模板 */
```

- [ ] **Step 4: 解包确认**

`make deps` 后，`entry/src/main/resources/rawfile/vm/firmware/` 应出现三个新文件；真机启动 app 后 `filesDir/vm/` 下也应出现。

- [ ] **Step 5: 提交**

```bash
git add deps/libqemu/Makefile deps/Makefile entry/src/main/ets/lib/bootstrap.ets
git commit -m "build(windows): 打包 x86 OVMF/VARS 与 arm VARS 固件"
```

---

### Task 6: deps — 新增 libtpms + swtpm 包（真 TPM，风险 #2）

**Files:**
- Create: `deps/libtpms/Makefile`
- Create: `deps/swtpm/Makefile`
- Modify: `deps/Makefile`

**风险提示：这是全程最大风险点。** 需交叉编译 libtpms（依赖 openssl，buildroot 现无 openssl）与 swtpm（依赖 libtpms + glib + openssl）。可能需再补 openssl 包。Swtpm 以「可执行」打进 HAP，须确认 HarmonyOS 沙箱允许执行该 ELF。**若此任务卡住，功能仍可交付：把 `security.tpm` 保持 false，走注册表绕过（Task 2/9 已完整实现）。**

- [ ] **Step 1: 先补 openssl（若 buildroot 无）**

现有 buildroot 无 openssl（qemu 用 `--disable-gnutls --disable-nettle`）。检查 `deps/buildroot/lib` 是否有 `libcrypto`：

```bash
ls deps/buildroot/lib | grep -i "crypto\|ssl" || echo "需新增 openssl"
```

若缺，新建 `deps/openssl/Makefile`（`define_autotools_package`）；在 `deps/Makefile` PKGS 里加 `openssl`：

```make
PKGS := zstd zlib pcre2 libglib pixman openssl libqemu
```

`deps/openssl/Makefile`：

```make
include ../utils/Makefrag

SOURCE_URL = https://www.openssl.org/source/openssl-3.0.16.tar.gz
SOURCE_FILE = openssl-3.0.16.tar.gz
SOURCE_DIR = openssl-3.0.16
CONFIG_ARGS = --prefix=$(PREFIX) --cross-compile-prefix=$(OHOS_SDK_HOME)/native/llvm/bin/$(OHOS_ARCH)-unknown-linux-ohos- --shared --with-rand-seed=devrandom

$(eval $(call define_autotools_package))
```

> 注：`define_autotools_package` 用 configure；openssl 的 Configure 脚本与 base 的不同，实际可能不走本宏。**若失败，把 openssl 替换为编译进 libtpms 的替代或改用 libtpms 内置 mbedtls 路径。** 本步为分支验证。

- [ ] **Step 2: libtpms 包**

`deps/libtpms/Makefile`：

```make
include ../utils/Makefrag

SOURCE_URL = https://github.com/stefanberger/libtpms/archive/refs/tags/v0.9.8.tar.gz
SOURCE_FILE = libtpms-0.9.8.tar.gz
SOURCE_DIR = libtpms-0.9.8
CONFIG_ARGS = --prefix=$(PREFIX) --enable-tpm2 --enable-shared --with-openssl

$(eval $(call define_autotools_package))
```

`deps/Makefile` PKGS 加 `libtpms`。

- [ ] **Step 3: swtpm 包**

`deps/swtpm/Makefile`：

```make
include ../utils/Makefrag

SOURCE_URL = https://github.com/stefanberger/swtpm/archive/refs/tags/v0.10.0.tar.gz
SOURCE_FILE = swtpm-0.10.0.tar.gz
SOURCE_DIR = swtpm-0.10.0
CONFIG_ARGS = --prefix=$(PREFIX) --with-libtpms=$(shell pwd)/../buildroot --with-openssl

$(eval $(call define_autotools_package))
```

`deps/Makefile` PKGS 加 `swtpm`。

- [ ] **Step 4: swtpm 打包进 HAP**

`deps/Makefile` 的 `copy` 目标里，把产出的 `swtpm` 可执行拷到 rawfile/bin：

```make
cd temp/swtpm-0.10.0 && make install DESTDIR=$(shell pwd)/build   # define_autotools_package 已做
mkdir -p ../entry/src/main/resources/rawfile/bin
cp output/swtpm ../entry/src/main/resources/rawfile/bin/swtpm
```

（`define_autotools_package` 的 `cp -rfv build$(PREFIX)/. ../buildroot` 会把 swtpm 装到 buildroot/bin；再从此拷到 bin/ 即可。）

- [ ] **Step 5: bootstrap 解包 swtpm 二进制**

`bootstrap.ets` 新增（在 `FIRMWARE_FILES` 解包后）：

```ts
tryWriteRaw(resMgr, 'bin/swtpm', ctx.filesDir + '/vm/swtpm');
```

并 `chmod`（若 API 支持）在 `writeRaw` 后加：`fs.chmod(dst, 0o755)` 用 try 包裹。

- [ ] **Step 6: 验证（关键门）**

```bash
# 在构建宿主验证交叉编译产物可执行（先 buildroot 里跑原生版，真机上再验壳）
file deps/buildroot/bin/swtpm   # 应显示 aarch64 ELF
```

真机部署后启动一个 windows VM，确认 swtpm 进程起来、socket 出现、qemu 无 tpm 报错。**若 Step 6 失败 → 本任务降级：`security.tpm` 保持 false（Win11 走注册表绕过）。** 在 spec 风险点记录结果。

- [ ] **Step 7: 提交**

```bash
git add deps/openssl deps/libtpms deps/swtpm deps/Makefile entry/src/main/ets/lib/bootstrap.ets
git commit -m "build(windows): 新增 libtpms/swtpm 交叉编译并打包"
```

---

### Task 7: native — 新增 `swtpm_start`/`swtpm_stop` + napi

**Files:**
- Create: `entry/src/main/cpp/swtpm.h`
- Create: `entry/src/main/cpp/swtpm.cpp`
- Modify: `entry/src/main/cpp/napi_init.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt`

- [ ] **Step 1: swtpm.h**

```cpp
#pragma once
#include <string>

/* fork/exec 拉起 swtpm（--daemon --pid），轮询 ctrl socket 与 pid 文件；0=就绪。
 * tpmDir 为 tpmstate 目录（不存在则创建）。 */
int swtpm_start(const std::string &binPath, const std::string &tpmDir,
                const std::string &ctrlSock, const std::string &logPath,
                const std::string &pidPath, int timeoutMs);
/* 读 pid 文件 kill 并清理残留 socket/pid 文件 */
void swtpm_stop(const std::string &pidPath);
```

- [ ] **Step 2: swtpm.cpp**

```cpp
#include "swtpm.h"
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0006
#define LOG_TAG "QemuSwtpm"

static bool exists(const std::string &p) { return access(p.c_str(), F_OK) == 0; }

int swtpm_start(const std::string &binPath, const std::string &tpmDir,
                const std::string &ctrlSock, const std::string &logPath,
                const std::string &pidPath, int timeoutMs)
{
    if (access(binPath.c_str(), X_OK) != 0) {
        OH_LOG_ERROR(LOG_APP, "swtpm bin not executable: %{public}s", binPath.c_str());
        return -1;
    }
    if (!exists(tpmDir)) {
        mkdir(tpmDir.c_str(), 0700);
    }
    pid_t pid = fork();
    if (pid < 0) { OH_LOG_ERROR(LOG_APP, "swtpm fork failed errno=%{public}d", errno); return -1; }
    if (pid == 0) {
        /* 子进程：exec swtpm（--daemon 自行再 fork 一次，原 child 随之退出） */
        execl(binPath.c_str(), "swtpm",
              "socket", "--tpm2",
              "--tpmstate", ("dir=" + tpmDir).c_str(),
              "--ctrl", ("type=unixio,path=" + ctrlSock).c_str(),
              "--log", ("file=" + logPath).c_str(),
              "--daemon", "--pid", ("file=" + pidPath).c_str(),
              (char *)nullptr);
        _exit(127);
    }
    /* 父进程：不 wait（swtpm --daemon 会让 child 快速退出）。轮询 pid 文件 + ctrl socket。 */
    int waited = 0;
    for (; waited < timeoutMs; waited += 100) {
        if (exists(pidPath) && exists(ctrlSock)) { return 0; }
        usleep(100 * 1000);
    }
    OH_LOG_ERROR(LOG_APP, "swtpm start timeout errno=%{public}d", errno);
    swtpm_stop(pidPath);
    return -1;
}

void swtpm_stop(const std::string &pidPath)
{
    std::ifstream f(pidPath);
    if (f.is_open()) {
        pid_t p = 0; f >> p;
        if (p > 1) { kill(p, SIGTERM); }
        f.close();
    }
    unlink(pidPath.c_str());
}
```

- [ ] **Step 3: napi 暴露 startSwtpm/stopSwtpm**

在 `napi_init.cpp` 加：

```cpp
#include "swtpm.h"

/* startSwtpm(binPath: string, tpmDir: string, ctrlSock: string, logPath: string, pidPath: string): number */
static napi_value StartSwtpm(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string bin = stringArg(env, args[0]);
    std::string dir = stringArg(env, args[1]);
    std::string ctrl = stringArg(env, args[2]);
    std::string log = stringArg(env, args[3]);
    std::string pid = stringArg(env, args[4]);
    return intResult(env, swtpm_start(bin, dir, ctrl, log, pid, 5000));
}

/* stopSwtpm(pidPath: string) */
static napi_value StopSwtpm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    swtpm_stop(stringArg(env, args[0]));
    return nullptr;
}
```

`Init` 的 `desc[]` 里加两项：

```cpp
{ "startSwtpm", nullptr, StartSwtpm, nullptr, nullptr, nullptr, napi_default, nullptr },
{ "stopSwtpm", nullptr, StopSwtpm, nullptr, nullptr, nullptr, napi_default, nullptr },
```

- [ ] **Step 4: CMakeLists 加 swtpm.cpp**

在 `entry/src/main/cpp/CMakeLists.txt` 的源文件列表加 `"swtpm.cpp"`。

- [ ] **Step 5: 编译**

```bash
make hap
```

预期：无 undefined `swtpm_start`。

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/cpp/swtpm.h entry/src/main/cpp/swtpm.cpp entry/src/main/cpp/napi_init.cpp entry/src/main/cpp/CMakeLists.txt
git commit -m "feat(windows): native 新增 swtpm_start/swtpm_stop 与 napi 接口"
```

---

### Task 8: VmConsole — 启动时 spawn swtpm + seed VARS，退出回收；Windows 引导

**Files:**
- Modify: `entry/src/main/ets/pages/VmConsole.ets`

- [ ] **Step 1: imports**

增加 `winFirmware` 相关不需要（`seedWinVars`）、`swtpmPidPath/swtpmSockPath/swtpmDir`：

```ts
import { VmProfile, VmStore, buildArgs, qmpSockPath, sharedDir, builtinIsoFor, seedWinVars, swtpmPidPath, swtpmSockPath, swtpmDir } from '../lib/vmprofile';
```

`QemuNapi` 接口加：

```ts
startSwtpm: (binPath: string, tpmDir: string, ctrlSock: string, logPath: string, pidPath: string) => number;
stopSwtpm: (pidPath: string) => void;
```

- [ ] **Step 2: doStart 先起 swtpm**

在 `doStart` 里 `const args = buildArgs(...)` 之前插入（windows + 启用了 tpm 才起）：

```ts
const isWin = this.profile.guestOS === 'windows11';
if (isWin) {
  if (!seedWinVars(this.vmDataDir, this.profile.id, this.profile.machine.arch)) {
    this.status = 'UEFI 变量文件缺失';
    return;
  }
}
if (isWin && this.profile.security && this.profile.security.tpm) {
  const binPath = this.vmDataDir + '/swtpm';
  const tpmDir = swtpmDir(this.vmDataDir, this.profile.id);
  const sock = swtpmSockPath(this.vmDataDir, this.profile.id);
  const log = this.vmDataDir + '/swtpm-' + this.profile.id + '.log';
  const pid = swtpmPidPath(this.vmDataDir, this.profile.id);
  const rc = napi.startSwtpm(binPath, tpmDir, sock, log, pid);
  if (rc !== 0) {
    this.status = 'TPM 启动失败';
    promptAction.showToast({ message: 'TPM 启动失败，已改用注册表绕过安装' });
    this.profile.security.tpm = false; /* 降级：不再挂 tpm-tis */
  }
}
```

确保降级后 `buildWinArgs` 不挂 tpm（`security.tpm` 已被置 false）。

- [ ] **Step 3: VM 退出回收 swtpm**

在 `onQmpEvent` 的 `SHUTDOWN`/`QMP_DISCONNECT` 分支（`this.closeWindow();` 之前）加：

```ts
if (this.profile && this.profile.guestOS === 'windows11') {
  napi.stopSwtpm(swtpmPidPath(this.vmDataDir, this.profile.id));
}
```

（`closeWindow` 里 `terminateSelf` 前也调用一次，双保险：在 `closeWindow()` 开头加同样调用，见 Step 4。）

- [ ] **Step 4: closeWindow 兜底回收**

`closeWindow()` 开头（`if (this.closed) return;` 之后）加：

```ts
if (this.profile && this.profile.guestOS === 'windows11') {
  napi.stopSwtpm(swtpmPidPath(this.vmDataDir, this.profile.id));
}
```

- [ ] **Step 5: 启动失败分支回收**

`doStart` 中若 `napi.startVm` 返回非 0：回收已起的 swtpm：

```ts
const ret = napi.startVm(...);
if (ret !== 0) {
  if (isWin && this.profile.security && this.profile.security.tpm) {
    napi.stopSwtpm(swtpmPidPath(this.vmDataDir, this.profile.id));
  }
  this.failStart('启动失败');
  return;
}
```

- [ ] **Step 6: 编译**

```bash
make hap
```

- [ ] **Step 7: 提交**

```bash
git add entry/src/main/ets/pages/VmConsole.ets
git commit -m "feat(windows): VmConsole 启动时起 swtpm/seed VARS，退出回收"
```

---

### Task 9: VmWizard — guestOS 选择 + Windows 默认值 + seed VARS

**Files:**
- Modify: `entry/src/main/ets/pages/VmWizard.ets`

- [ ] **Step 1: import + state**

```ts
import { VmProfile, VmStore, VmArch, VmBoard, VmFirmware, VgaType, GuestOs, ... } from '../lib/vmprofile';
import { seedWinVars } from '../lib/vmprofile';
```

加：

```ts
@State guestOS: GuestOs = 'linux';
```

`aboutToAppear()` 重置：`this.guestOS = 'linux';`

- [ ] **Step 2: 添加 guestOS 切换（放在 stepArch 顶部）**

在 `stepArch` Builder 的 `Column` 顶部加：

```ts
Row({ space: sp2 }) {
  Row({ space: sp1 }) {
    Radio({ value: 'linux', group: 'guestOS' })
      .checked(this.guestOS === 'linux')
      .onChange((c: boolean) => { if (c) { this.applyGuestOS('linux'); } })
    Text('Linux').fontSize(tBody).fontColor(cText)
  }
  Row({ space: sp1 }) {
    Radio({ value: 'windows11', group: 'guestOS' })
      .checked(this.guestOS === 'windows11')
      .onChange((c: boolean) => { if (c) { this.applyGuestOS('windows11'); } })
    Text('Windows 11').fontSize(tBody).fontColor(cText)
  }
  Blank()
}
.width('100%')
```

- [ ] **Step 3: `applyGuestOS` 方法（套默认值）**

```ts
/* 切 guestOS 时套模板默认：windows 用 q35/virt + 大内存/核数 + 64G 盘；linux 回默认。 */
private applyGuestOS(g: GuestOs): void {
  this.guestOS = g;
  if (g === 'windows11') {
    /* windows 只走 x86_64/aarch64 */
    if (this.arch !== 'x86_64' && this.arch !== 'aarch64') { this.arch = 'x86_64'; }
    this.board = this.arch === 'aarch64' ? 'virt' : 'q35';
    this.memoryMB = 8192;
    this.cpus = 4;
    this.diskGB = 64;
    this.portForwards = '';
  } else {
    this.arch = 'x86_64';
    this.board = 'pc';
    this.memoryMB = 1024;
    this.cpus = 2;
    this.diskGB = 8;
  }
}
```

且在 `stepArch` 的 `onClick`（点架构卡）里，若 `guestOS==='windows11'` 且选到的 arch 非 x86_64/aarch64，则回退并 toast：

```ts
.onClick(() => {
  this.arch = a;
  this.board = fitBoard(a, this.board);
  if (this.guestOS === 'windows11' && a !== 'x86_64' && a !== 'aarch64') {
    promptAction.showToast({ message: 'Windows 11 仅支持 x86_64 / aarch64' });
    this.arch = a; /* 仍允许切走，UI 层用 guestOS 限制；此处提示即可 */
  }
})
```

- [ ] **Step 4: assemble() 带 guestOS/security**

```ts
guestOS: this.guestOS,
security: { tpm: this.guestOS === 'windows11' },
```

（真 TPM 默认对 windows 模板开启；swtpm 构建失败则由 VmConsole 降级置 false。）

- [ ] **Step 5: finish() seed VARS**

`finish()` 在 `new VmStore(...).save(p)` 之后加：

```ts
if (this.guestOS === 'windows11') {
  if (!seedWinVars(this.vmDataDir, id, this.arch)) {
    promptAction.showToast({ message: 'UEFI 变量文件缺失，可能无法启动 Windows' });
  }
}
```

- [ ] **Step 6: stepNet 里 Windows 下禁用 9p 共享**

`stepNet` 的共享目录 Toggle 加：

```ts
.enabled(this.guestOS !== 'windows11')
```

并在选中共享时若 windows 则提示。简单起见：windows 下该 Toggle 禁灰即可。

- [ ] **Step 7: 编译 + 提交**

```bash
make hap
git add entry/src/main/ets/pages/VmWizard.ets
git commit -m "feat(windows): 向导加 guestOS 选择/Windows 默认值/seed VARS"
```

---

### Task 10: VmEdit + VmStorage — guestOS 展示与 Windows 限制

**Files:**
- Modify: `entry/src/main/ets/pages/VmEdit.ets`
- Modify: `entry/src/main/ets/pages/VmStorage.ets`

- [ ] **Step 1: VmEdit import + 展示 guestOS**

`VmEdit` 加 `import { GuestOs, seedWinVars, swtpmPidPath } ...`（若需）。`aboutToAppear` 读 `this.guestOS = p.guestOS；`（加 `@State guestOS: GuestOs = 'linux';`）。在「基础」节「架构」行下方加一行：

```ts
Row() {
  Text('系统').fontSize(tLabel).width(72)
  Text(this.guestOS === 'windows11' ? 'Windows 11' : 'Linux').fontSize(tBody).fontColor(cSub)
}.padding({ top: sp1, bottom: sp1 })
```

- [ ] **Step 2: VmEdit 保存时带 guestOS/security**

`save()` 构建 profile 加：

```ts
guestOS: this.guestOS,
security: { tpm: this.guestOS === 'windows11' },
```

且保存前若 `guestOS==='windows11'` 则 `seedWinVars`。

- [ ] **Step 3: VmEdit 共享目录置灰**

`VmEdit` 网络节共享目录 Toggle 加 `.enabled(this.guestOS !== 'windows11')`；Windows 下副标题显示「Windows 需 virtio-win 驱动，暂不支持」。

- [ ] **Step 4: VmStorage ISO 提示**

`secCdrom` 的「未引用光盘」空态，若 profile 是 windows 加一句提示文案「Windows 11 安装请使用官方 ISO（光盘经 USB 存储挂载）」。仅文案，不改逻辑。

- [ ] **Step 5: 编译 + 提交**

```bash
make hap
git add entry/src/main/ets/pages/VmEdit.ets entry/src/main/ets/pages/VmStorage.ets
git commit -m "feat(windows): 编辑/存储页展示 guestOS 并禁用 Windows 9p共享"
```

---

### Task 11: 端到端构建部署验证

**Files:**
- 无（验证）

- [ ] **Step 1: 全量构建**

```bash
make deps && make hap
```

预期：deps 编出 swtpm、libtpms、openssl；hap 通过。

- [ ] **Step 2: 部署**

```bash
HDC=/apps/harmony/sdk/default/openharmony/toolchains/hdc
$HDC -t 192.168.1.4:44959 shell "aa force-stop app.hackeris.hium" || true
$HDC -t 192.168.1.4:44959 file send entry/build/default/outputs/default/entry-default-unsigned.hap /data/local/tmp/hium.hap
$HDC -t 192.168.1.4:44959 shell "bm install -p /data/local/tmp/hium.hap"
```

- [ ] **Step 3: 创建 Windows 11 模板**

向导：guestOS=Windows 11 → 选 x86_64 或 aarch64 → 命名 → 完成。确认 profile json 含 `guestOS: windows11`、`security.tpm: true`，且 `filesDir/vm/` 下有 `<id>-ovmf-vars.fd`/`<id>-aavmf-vars.fd`。

- [ ] **Step 4: 挂官方 ISO 并启动**

存储页/向导挂 `Windows11*` ARM64 或 x64 官方 ISO（`可从 http://www.microsoft.com/en-us/software-download/windows11arm64` 获取 ARM），另挂 virtio-win 驱动 ISO。启动：

- ARM：应进 AAVMF UEFI 引导，serials/log 无 `unsupported machine`。
- x64：应进 OVMF UEFI。
- `swtpm-<id>.sock` 文件存在、`qemu-<id>.log` 无 tpm 报错。

- [ ] **Step 5: 安装验证**

进安装界面 `Shift+F10 → regedit → HKEY_LOCAL_MACHINE\SYSTEM\Setup → 新建 LabConfig → BypassTPMCheck=1/BypassSecureBootCheck=1`（真 TPM 就绪则不必）。确认能进入分盘、安装。（预计 4h，TCG 慢属预期。）

- [ ] **Step 6: 回归 linux**

各 linux 模板（x86_64/aarch64/arm/loongarch64/riscv64）启动不受 guestOS 分支影响；`buildArgs` 预览与旧一致。

- [ ] **Step 7: 记录**

在 spec 风险点追加实测结果；若 TPM 降级则说明原因。

---

## Self-Review 对照

- **Spec coverage**：guestOS 字段(T1/T2/T3) ✔ 固件打包(T5) ✔ Windows 设备组(T2) ✔ 真 TPM(T3/T6/T7/T8) ✔ 向导(UIT9) ✔ 编辑/存储(T10) ✔ 安装引导/风险验证(T0/T11) ✔
- **类型一致**：`GuestOs`、`security.tpm`、`winFirmware/winVarsPath/seedWinVars/swtpmSockPath/swtpmPidPath/swtpmDir` 在 T1/T2/T4 定义，T8/T9 引用，签名一致。
- **占位符**：除 swtpm 交叉编译具体 configure 需实测调整（Task 6 已标注为分支验证 + 降级路径）外，其余均含可执行代码。Task 0/6 是显式验证门，不是占位。
