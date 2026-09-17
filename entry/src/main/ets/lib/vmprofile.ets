// VM 配置数据模型（schema v2）：一份 JSON 存 filesDir/vms/<id>.json。
// v2 把扁平字段拆成 machine / runtime / media / net 四层，UI 只面对这套领域对象，
// buildArgs 是纯函数把它翻成 qemu 命令行。所有读取经 migrateProfile 统一做
// 版本判定 + 缺字段回填，不再在 load() 里逐字段塞 if。
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const SCHEMA_VERSION = 6;

const DOMAIN = 0x0210;
const TAG = 'QemuProf';

export type VmArch = 'x86_64' | 'i386' | 'aarch64' | 'arm' | 'loongarch64' | 'riscv64';
export type VgaType = 'std' | 'virtio' | 'cirrus' | 'vmware';
export type VmBoard = 'pc' | 'q35' | 'virt' | 'raspi2' | 'raspi3';
export type VmFirmware = 'seabios' | 'ovmf';

/* 机器层：架构/显卡 + 板卡/固件/CPU 模型。机器工坊按此生成 -machine/-cpu 参数 */
export interface VmMachine {
  arch: VmArch;
  vga: VgaType;
  machine: VmBoard;    /* 板卡：x86 pc/q35，arm64/arm virt/raspi2/raspi3，loongarch64/riscv64 virt */
  firmware: VmFirmware; /* 固件：seabios(BIOS) / ovmf(UEFI，暂需 OVMF 文件) */
  cpuModel: string;     /* '' = 自动（arm64/arm/loongarch64 给 max） */
  serialInteractive: boolean;   /* 串口走 socket 交互（默认 true）；false=落盘 file 日志 */
  cpuFlags: string;             /* v6：-cpu <模型>,<flags> 的 flags 部分，如 "+sse4a,-avx2"；''=无 */
  rtcLocal: boolean;            /* v6：-rtc base=localtime（guest RTC 随宿主时区） */
}

/* 板卡是否适配某架构（aarch64/loongarch64 只认 virt/raspi2；x86 只认 pc/q35） */
export function defaultBoard(arch: VmArch): VmBoard {
  return (arch === 'aarch64' || arch === 'arm' || arch === 'loongarch64' || arch === 'riscv64') ? 'virt' : 'pc';
}

/* 把 board 收紧成与 arch 兼容的值；不兼容则回退该架构默认板卡 */
export function fitBoard(arch: VmArch, board: string): VmBoard {
  const allowed: string[] = arch === 'aarch64' ? ['virt', 'raspi2', 'raspi3'] :
    arch === 'arm' ? ['virt', 'raspi2', 'raspi3'] :
    (arch === 'loongarch64' || arch === 'riscv64') ? ['virt'] : ['pc', 'q35'];
  return allowed.indexOf(board) >= 0 ? board as VmBoard : defaultBoard(arch);
}

/* 显卡收紧：cirrus/vmware 仅 x86 板卡（pc/q35）；virt/raspi 无传统 VGA，回落 std（virt 的
 * virtio-gpu 是构建强制，此处仅保证字段合法）。 */
export function fitVga(board: VmBoard, vga: string): VgaType {
  const allowed: string[] = (board === 'pc' || board === 'q35') ?
    ['std', 'virtio', 'cirrus', 'vmware'] : ['std'];
  return allowed.indexOf(vga) >= 0 ? vga as VgaType : 'std';
}

/* 主盘路径（disks[0]）；无盘返回 ''。快照/临时会话/启动盘只作用于主盘。 */
export function mainDiskPath(p: VmProfile): string {
  return p.media.disks.length > 0 ? p.media.disks[0].path : '';
}

/* 磁盘格式判定：.qcow2 = qcow2，其余(raw/.img)按 raw（与向导导入保留扩展名的语义一致） */
export function driveFmt(path: string): string {
  return path.toLowerCase().endsWith('.qcow2') ? 'qcow2' : 'raw';
}

/* 内置 Alpine ISO 的「文件名 ↔ 架构」映射（vmDataDir 下的文件名，按需下载）。
 * 官方 alpine-virt 精简版仅 4 架构；loongarch64/riscv64 只有 alpine-standard。
 * 文件名用镜像目录名（armv7/x86 而非 arm/i386），见 isoDl.ets 的下载 URL。 */
export function builtinIsoFor(arch: VmArch): string {
  switch (arch) {
    case 'x86_64': return 'alpine-virt-x86_64.iso';
    case 'i386': return 'alpine-virt-x86.iso';
    case 'aarch64': return 'alpine-virt-aarch64.iso';
    case 'arm': return 'alpine-virt-armv7.iso';
    case 'loongarch64': return 'alpine-standard-loongarch64.iso';
    case 'riscv64': return 'alpine-standard-riscv64.iso';
    default: return '';
  }
}

/* 运行时层：可被 JIT 性能预设覆盖（memory/cpus/accel）+ 系统增强设备（v4） */
export interface VmRuntime {
  memoryMB: number;
  cpus: number;
  mttcg: boolean;   /* TCG 多线程 */
  tbSize: number;
  rng: boolean;     /* virtio-rng-pci 熵源（Linux guest 自带驱动；raspi 无 PCI 构建期忽略） */
  balloon: boolean; /* virtio-balloon-pci 内存回收（同上） */
  audio: boolean;   /* v6：声音——-audiodev driver=ohos + 板卡对应声卡（raspi 无模拟声卡，构建期忽略） */
  gdbPort: number;  /* v6：GDB 调试后端端口，0=关闭；仅编辑页可配（向导不出现） */
}

/* 一张磁盘：path 为 vms/ 内资产路径（新建/导入时复制）或外部引用；readonly 挂 -drive readonly=on */
export interface VmDisk {
  path: string;
  readonly: boolean;
}

/* 介质层：全部磁盘数组化（v5）；disks[0] = 系统盘（启动/快照/临时会话对象），
 * 其余为数据盘。快照与临时会话只作用于系统盘，数据盘不参与回滚。 */
export interface VmMedia {
  disks: VmDisk[];
  cdromPaths: string[];  /* 有序 ISO 列表；空数组 = 无光盘；第一张为启动盘候选 */
  bootFromCdrom: boolean;
  /* 直接内核引导（v3 新增，均 '' = 不用）：kernel/initrd 在创建时已复制进 vms/，
   * append 透传 -append。kernelPath 非空即绕过固件引导流程（qemu -kernel） */
  kernelPath: string;
  initrdPath: string;
  kernelAppend: string;
}

/* 网络层 */
export interface VmNet {
  enabled: boolean;
  portForwards: string; /* "8080:80,2222:22"，空串 = 不转发 */
  sharedFolder: boolean; /* 9p 共享宿主目录 filesDir/shared → guest /shared（默认关） */
}

export interface VmProfile {
  schemaVersion: number;  /* = SCHEMA_VERSION */
  id: string;
  name: string;
  machine: VmMachine;
  runtime: VmRuntime;
  media: VmMedia;
  net: VmNet;
  temporarySession: boolean; /* 临时会话启动模式：开机前打会话起点内部快照，停机自动回滚丢弃 */
  extraArgs: string;  /* escape hatch：原样追加到 qemu 命令行 */
}

export function newProfileId(): string {
  return 'vm' + Date.now().toString(36) + Math.floor(Math.random() * 1296).toString(36);
}

export function blankProfile(id: string): VmProfile {
  return {
    schemaVersion: SCHEMA_VERSION,
    id: id,
    name: '新虚拟机',
    machine: {
      arch: 'x86_64', vga: 'std', machine: 'pc', firmware: 'seabios', cpuModel: '',
      serialInteractive: true, cpuFlags: '', rtcLocal: false,
    },
    runtime: { memoryMB: 1024, cpus: 2, mttcg: true, tbSize: 1024, rng: false, balloon: false, audio: true, gdbPort: 0 },
    media: {
      disks: [],
      cdromPaths: [], bootFromCdrom: false, kernelPath: '', initrdPath: '', kernelAppend: '',
    },
    net: { enabled: true, portForwards: '', sharedFolder: false },
    temporarySession: false,
    extraArgs: '',
  };
}

/* ========================= 迁移框架（所有读取的唯一入口） ========================= */
/* migrateProfile 是 VmProfile 只进不出的唯一入口：按 schemaVersion 分支，返回
 * 一份「净菜」v2 结构（层必在、字段齐全）。以后每升一版，往 switch 加一个 case
 * 写 vN→vN+1 迁移器即可，不改调用方。ArkTS 禁 any/unknown，动态 JSON 统一用
 * Record<string, Object> + 显式窄化助手读取。 */
export function migrateProfile(raw: Object): VmProfile {
  const o = raw as Record<string, Object>;
  const v = typeof o['schemaVersion'] === 'number' ? o['schemaVersion'] as number : 1;
  switch (v) {
    case 1:
      return migrateV1(o);
    case 2: /* v2+：kernel 三字段、v4/v5/v6 新字段统一由 normalizeV2 回填 */
    case 3:
    case 4:
    case 5:
    case SCHEMA_VERSION:
      return normalizeV2(o);
    default:
      return blankProfile(''); /* 更高版本：本版本不认识，兜底新开 */
  }
}

/* 动态 JSON 读取助手（ArkTS 禁 any/unknown，禁对字段下标访问，用 Record + 窄化） */
function jStr(o: Record<string, Object>, k: string): string {
  const v = o[k];
  return typeof v === 'string' ? v as string : '';
}
function jNum(o: Record<string, Object>, k: string, d: number): number {
  const v = o[k];
  return typeof v === 'number' ? v as number : d;
}
function jBool(o: Record<string, Object>, k: string, d: boolean): boolean {
  const v = o[k];
  return typeof v === 'boolean' ? v as boolean : d;
}
function jObj(o: Record<string, Object>, k: string): Record<string, Object> | undefined {
  const v = o[k];
  return typeof v === 'object' ? v as Record<string, Object> : undefined;
}
/* 读 VmDisk[]（动态 JSON 存的是 Object[]，逐项窄化；path 空的项丢弃） */
function jDiskArr(o: Record<string, Object>, k: string): VmDisk[] {
  const v = o[k];
  if (!Array.isArray(v)) {
    return [];
  }
  const raw = v as Object[];
  const out: VmDisk[] = [];
  for (const item of raw) {
    if (item == null) {
      continue;
    }
    const o2 = item as Record<string, Object>;
    const path = jStr(o2, 'path');
    if (path.length > 0) {
      out.push({ path: path, readonly: jBool(o2, 'readonly', false) });
    }
  }
  return out;
}

/* 读 string[]（动态 JSON 存的是 Object[]，逐项窄化；非法项丢弃） */
function jStrArr(o: Record<string, Object>, k: string): string[] {
  const v = o[k];
  if (!Array.isArray(v)) {
    return [];
  }
  const raw = v as Object[]; /* Array.isArray 会把 v 窄化成 any[]，显式转 Object[] 避免 any */
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item === 'string') {
      const s = item as string;
      if (s.length > 0) {
        out.push(s);
      }
    }
  }
  return out;
}

/* v1（开发期废弃）：旧扁平字段尽力映射进 v2 层，读不到的下默认。
 * 不承诺完整迁移（无线上历史数据），仅是「尽量捞、丢了不补」。 */
function migrateV1(o: Record<string, Object>): VmProfile {
  const p = blankProfile('');
  p.id = jStr(o, 'id') || newProfileId();
  p.name = jStr(o, 'name') || '未命名';
  const arch = jStr(o, 'arch');
  if (arch === 'i386' || arch === 'aarch64') {
    p.machine.arch = arch as VmArch;
  }
  p.machine.vga = jStr(o, 'vga') === 'virtio' ? 'virtio' : 'std';
  p.machine.machine = defaultBoard(p.machine.arch);
  p.machine.firmware = 'seabios';
  p.machine.cpuModel = '';
  p.runtime.memoryMB = jNum(o, 'memoryMB', 1024);
  p.runtime.cpus = jNum(o, 'cpus', 2);
  p.runtime.mttcg = jBool(o, 'mttcg', true);
  p.runtime.tbSize = jNum(o, 'tbSize', 1024);
  const legDisk = jStr(o, 'diskPath');
  if (legDisk.length > 0) {
    p.media.disks = [{ path: legDisk, readonly: false }];
  }
  p.media.cdromPaths = jStrArr(o, 'cdromPaths');
  if (p.media.cdromPaths.length === 0) {
    const leg = jStr(o, 'cdromPath');
    if (leg.length > 0) { p.media.cdromPaths = [leg]; }
  }
  p.media.bootFromCdrom = jBool(o, 'bootFromCdrom', false);
  p.net.enabled = jBool(o, 'netEnabled', true);
  p.net.portForwards = jStr(o, 'portForwards');
  p.extraArgs = jStr(o, 'extraArgs');
  return p;
}

/* v2 归一化：深校验 + 逐字段回填默认（承接原 load() 兜底职责，净菜输出） */
function normalizeV2(o: Record<string, Object>): VmProfile {
  const p = blankProfile('');
  p.id = jStr(o, 'id') || newProfileId();
  const nm = jStr(o, 'name');
  p.name = nm.length > 0 ? nm : '未命名';
  const m = jObj(o, 'machine');
  const r = jObj(o, 'runtime');
  const md = jObj(o, 'media');
  const n = jObj(o, 'net');

  if (m) {
    const arch = jStr(m, 'arch');
    if (arch === 'i386' || arch === 'aarch64' || arch === 'arm' || arch === 'loongarch64') {
      p.machine.arch = arch as VmArch;
    }
    p.machine.machine = fitBoard(p.machine.arch, jStr(m, 'machine'));
    p.machine.vga = fitVga(p.machine.machine, jStr(m, 'vga'));
    p.machine.firmware = jStr(m, 'firmware') === 'ovmf' ? 'ovmf' : 'seabios';
    p.machine.cpuModel = jStr(m, 'cpuModel');
    /* v4：串口模式，旧存档回填默认。
     * 旧存档残留的 mouse 键不再读取（输入模式已整体移除），按未知键静默忽略。 */
    p.machine.serialInteractive = jBool(m, 'serialInteractive', true);
    /* v6：CPU flags 原样透传（''=无）；RTC 本地时区默认关 */
    p.machine.cpuFlags = jStr(m, 'cpuFlags');
    p.machine.rtcLocal = jBool(m, 'rtcLocal', false);
  }
  if (r) {
    p.runtime.memoryMB = jNum(r, 'memoryMB', p.runtime.memoryMB);
    p.runtime.cpus = jNum(r, 'cpus', p.runtime.cpus);
    p.runtime.mttcg = jBool(r, 'mttcg', p.runtime.mttcg);
    p.runtime.tbSize = jNum(r, 'tbSize', p.runtime.tbSize);
    /* v4：系统增强设备开关 */
    p.runtime.rng = jBool(r, 'rng', false);
    p.runtime.balloon = jBool(r, 'balloon', false);
    /* v6：声音默认开；GDB 端口默认关 */
    p.runtime.audio = jBool(r, 'audio', true);
    p.runtime.gdbPort = jNum(r, 'gdbPort', 0);
  }
  if (md) {
    /* v5：磁盘数组化；disks[0] 为系统盘 */
    p.media.disks = jDiskArr(md, 'disks');
    p.media.cdromPaths = jStrArr(md, 'cdromPaths');
    if (p.media.cdromPaths.length === 0) {
      const leg = jStr(md, 'cdromPath');
      if (leg.length > 0) { p.media.cdromPaths = [leg]; }
    }
    p.media.bootFromCdrom = jBool(md, 'bootFromCdrom', p.media.bootFromCdrom);
    /* v3 新增：直接内核引导三件套，旧存档缺省回填 '' */
    p.media.kernelPath = jStr(md, 'kernelPath');
    p.media.initrdPath = jStr(md, 'initrdPath');
    p.media.kernelAppend = jStr(md, 'kernelAppend');
  }
  if (n) {
    p.net.enabled = jBool(n, 'enabled', p.net.enabled);
    p.net.portForwards = jStr(n, 'portForwards');
    p.net.sharedFolder = jBool(n, 'sharedFolder', p.net.sharedFolder);
  }
  p.temporarySession = jBool(o, 'temporarySession', false);
  /* 未知键（如旧存档残留的 guestOS/security）一律忽略：jStr/jObj 只取已知字段，
   * 旧 Windows 存档据此静默按 Linux 处理，不迁移也不崩。 */
  p.extraArgs = jStr(o, 'extraArgs');
  return p;
}

/* =============================== 命令行生成 =============================== */

/* 解析 "8080:80,2222:22" 形式的端口转发；非法条目直接跳过（向导内由
 * forwardErrors 提前暴露，运行期此处只保底不崩） */
function parseForwards(text: string): string[] {
  const out: string[] = [];
  for (const item of text.split(',')) {
    const kv = item.trim().split(':');
    if (kv.length !== 2) {
      continue;
    }
    const host = Number(kv[0]);
    const guest = Number(kv[1]);
    if (Number.isInteger(host) && Number.isInteger(guest) && host >= 1 && host <= 65535
      && guest >= 1 && guest <= 65535) {
      out.push(`hostfwd=tcp::${host}-:${guest}`);
    }
  }
  return out;
}

/* 组装 user 模式 netdev：自动挂 hostfwd（forward 条目由 parseForwards 产出） */
function userNetdev(portForwards: string): string {
  let netdev = 'user,id=n0';
  for (const fwd of parseForwards(portForwards)) {
    netdev += ',' + fwd;
  }
  return netdev;
}

/* 端口转发完整校验（向导即时提示用）：逐条检查 "宿主端口:客机端口" 格式、
 * 1-65535 范围、宿主端口不重复（多个 forward 抢同一宿主端口会 bind 失败），
 * 返回所有错误描述；空数组 = 全部合法。 */
export function forwardErrors(text: string): string[] {
  const errs: string[] = [];
  const seenHosts: number[] = [];
  for (const item of text.split(',')) {
    const s = item.trim();
    if (s.length === 0) {
      errs.push('条目为空');
      continue;
    }
    const kv = s.split(':');
    if (kv.length !== 2) {
      errs.push(`「${s}」应为 宿主端口:客机端口`);
      continue;
    }
    const host = Number(kv[0]);
    const guest = Number(kv[1]);
    if (!Number.isInteger(host) || !Number.isInteger(guest)) {
      errs.push(`「${s}」端口需为整数`);
      continue;
    }
    if (host < 1 || host > 65535 || guest < 1 || guest > 65535) {
      errs.push(`「${s}」端口需在 1-65535 之间`);
      continue;
    }
    if (seenHosts.indexOf(host) >= 0) {
      errs.push(`宿主端口 ${host} 重复`);
      continue;
    }
    seenHosts.push(host);
  }
  return errs;
}

/* 该 VM 的 QMP unix socket 路径（每 VM 一个，天然无端口冲突） */
export function qmpSockPath(p: VmProfile, vmDataDir: string): string {
  return `${vmDataDir}/qmp-${p.id}.sock`;
}

/* 交互式串口的 unix socket 路径（serialInteractive 时 qemu `-serial chardev:socket,server=on` 监听） */
export function serialSockPath(p: VmProfile, vmDataDir: string): string {
  return `${vmDataDir}/serial-${p.id}.sock`;
}

/* 9p 共享宿主目录：启动时经 picker 取到的 Download 目录（唯一可共享目录），guest 挂载为 /shared。
 * 读到 AppStorage（EntryAbility prepareSharedFolder 写入）；未取到则回退 app 数据目录下 shared/。 */
export function sharedDir(filesDir: string): string {
  const host = AppStorage.get<string>('sharedHost');
  return (host && host.length > 0) ? host : filesDir + '/shared';
}

export function buildArgs(p: VmProfile, vmDataDir: string, sharedDir: string = '', isoOverride?: string[]): string[] {
  const isos = isoOverride !== undefined ? isoOverride : p.media.cdromPaths;
  hilog.info(DOMAIN, TAG, 'buildArgs id=%{public}s arch=%{public}s memMB=%{public}d cpus=%{public}d isoCount=%{public}d',
    p.id, p.machine.arch, p.runtime.memoryMB, p.runtime.cpus, isos.length);
  let args: string[] = [
    '-L', vmDataDir,
    '-m', String(p.runtime.memoryMB),
    '-smp', String(p.runtime.cpus),
    '-accel', `tcg,thread=${p.runtime.mttcg ? 'multi' : 'single'},tb-size=${p.runtime.tbSize}`,
    '-display', 'none',
    '-qmp', `unix:${qmpSockPath(p, vmDataDir)},server=on,wait=off`,
  ];
  /* v6：GDB 调试后端（tcp 连接，编辑页配置；host 侧 gdb 经
   * `target remote :<port>` 接入）。端口 0 = 不挂 -gdb。 */
  if (p.runtime.gdbPort > 0) {
    args.push('-gdb', `tcp:127.0.0.1:${p.runtime.gdbPort}`);
  }
  /* v6：RTC 本地时区——guest 时钟随宿主时区显示（默认 utc 是 qemu 出厂行为） */
  if (p.machine.rtcLocal) {
    args.push('-rtc', 'base=localtime');
  }
  /* 板卡/固件/CPU：默认 pc(x86)/virt(arm64) 与旧行为一致（qemu 默认即 pc）；
   * 新板卡 q35/raspi2 走对应 -machine。aarch64 默认给 -cpu max，virt 挂 virtio-gpu。
   * aarch64 virt 现已接入 edk2-aarch64-code.fd（-bios）；x86 的 firmware=ovmf
   * 仍未接 pflash（需 OVMF_CODE/VARS 固件），缺件回落 seabios。 */
  const board = fitBoard(p.machine.arch, p.machine.machine);
  const isRaspi = board === 'raspi2' || board === 'raspi3';
  /* 输入设备：统一 virtio-tablet-pci（绝对注入，触摸精确）。四类板卡都挂同一个，
   * 与重构前 raspi / tablet 两条分支的合并结果逐字等价。
   * 注：pc/q35 的 i8042 另外自带 PS/2 鼠标与键盘，无需（也无法）用 -device 添加。 */
  args.push('-device', 'virtio-tablet-pci');
  if (isRaspi) {
    /* 树莓派：qemu 10.2 实际机器名 raspi2b/raspi3b（旧代码 'raspi2' 会报 unsupported machine）。
     * 树莓派 SoC 自带引导、不依赖 edk2/BIOS；无 PCI，故不挂 virtio-gpu/net；磁盘经 SD 卡控制器。 */
    args.push('-machine', board === 'raspi2' ? 'raspi2b' : 'raspi3b');
  } else if (board === 'virt') {
    args.push('-machine', board);
    args.push('-device', 'virtio-gpu-pci');
    /* virt 机器无 i8042 PS/2 控制器且默认不带 USB 控制器（pc/q35 才有 PS/2）。
     * 裸挂 usb-kbd 会因找不到 USB 总线而 qemu abort；须显式挂 USB EHCI 主机
     * 控制器再挂 USB 键盘，否则 aarch64/arm/loongarch64/riscv64 收不到按键。 */
    args.push('-device', 'usb-ehci,id=usb');
    args.push('-device', 'usb-kbd,bus=usb.0');
    /* aarch64 的 virt 机器必须提供 UEFI 固件才能引导客户机：edk2-aarch64-code.fd
     * 由 make deps 产出、bootstrap 解到 vmDir，qemu 经 -bios(绝对路径) 载入 flash0。
     * loongarch64/arm(32位) 同理，对应各自 edk2-*.fd。 */
    if (p.machine.arch === 'aarch64') {
      args.push('-bios', vmDataDir + '/edk2-aarch64-code.fd');
    } else if (p.machine.arch === 'loongarch64') {
      args.push('-bios', vmDataDir + '/edk2-loongarch64-code.fd');
    } else if (p.machine.arch === 'arm') {
      args.push('-bios', vmDataDir + '/edk2-arm-code.fd');
    } else if (p.machine.arch === 'riscv64') {
      /* RISC-V 的 edk2 固件必须走 pflash 加载，**不能用 -bios** —— 这是它与
       * aarch64/arm 的关键差异，实测踩过：画面永远停在 qemu 的占位符
       * "Display output is not active."、串口一条输出都没有、CPU 持续空转
       * （guest 一条指令都没执行过）。
       * 注意「串口没有输出」在这里只是**症状之一**：成因是 guest 压根没执行，
       * UART 与 virtconsole 都一样空，别把它当成串口接线的证据（这条误判过一轮）。
       * 源码依据（两条加载路径不同）：
       *  - arm: hw/arm/virt.c virt_firmware_init() 里，-bios 经 load_image_mr()
       *    灌进 sysbus_mmio_get_region(flash[0])，落点是 flash 的 MMIO 区，
       *    地址正确，所以 aarch64/arm 用 -bios 没问题；
       *  - riscv: hw/riscv/boot.c riscv_load_firmware() 走的是
       *    load_image_targphys_as(fw, *firmware_load_addr, ram_size)，而该地址
       *    初值是 memmap[VIRT_DRAM].base = 0x80000000(RAM)。edk2 的
       *    RISCV_VIRT_CODE.fd(32MB) 是按 flash 首块地址 0x20000000 链接的，
       *    挪到 RAM 后整段跑飞。
       * -drive if=pflash 才是正路：riscv virt 的 VIRT_FLASH 在 0x20000000、
       * 总 0x4000000 分两块，pflash0 的大小 32MB 恰好等于该 fd；qemu 官方
       * tests/qtest/bios-tables-test.c 的 riscv64 用例也是这么挂的（它还挂了
       * 第二块 pflash 放 edk2-riscv-vars.fd，见下）。
       * **改走 pflash 后固件链变成两级**：machine->firmware 为空时，qemu 会先加载
       * opensbi-riscv64-generic-fw_dynamic.bin 到 RAM 跑 M-mode，再由 OpenSBI 经
       * ROM reset vector 里的 kernel_entry(= flash base) 跳进本 pflash 中的 edk2。
       * 因此这份 OpenSBI 必须与 edk2-*.fd 一起解到 vmDataDir（qemu 靠 -L vmDataDir
       * 找固件）；缺了它按源码会打印 Unable to find the RISC-V BIOS
       * "opensbi-riscv64-generic-fw_dynamic.bin" 然后按空 firmware 继续跳空 RAM
       * （源码推得、未实测）。三处固件清单见 deps/libqemu/Makefile 的 FIRMWARE 注释。
       * ⚠️ 本修复只解决「固件压根没执行」：改完之后 edk2 确实会跑（能接管 scanout、
       * 也会写 vars pflash），但**仍会停下来且机制未查明**——最后打印的是 DxeCore 的
       * SetUefiImageMemoryAttributes 与 TimerDriverSetTimerPeriod（都属 DXE 阶段），
       * 之后画面静止、vCPU 单核 100% 自旋，同参数下运行间结果还不一致。别把本修复
       * 当成「riscv64 已可用」。 */
      args.push('-drive', `if=pflash,format=raw,readonly=on,file=${vmDataDir}/edk2-riscv-code.fd`);
      /* 第二块 pflash 作为变量存储（32MB）：edk2 的 RiscVVirt 把代码区与变量区分开，
       * 缺它时变量读写会失败（qemu 官方 riscv64 用例就是双 pflash）。**但它不是
       * 起不来的解药**——实测挂上它之后 edk2 照样会停，别把两者混为一谈。
       * 这里**不用 snapshot=on**（qemu 官方测试的写法）：曾归因于「snapshot 要写临时
       * overlay，而 OHOS 应用沙箱没有可写的 /tmp」，但后来发现**不开 snapshot 也同样
       * 停在占位符画面**，该归因已被证伪，留此备注以免再次照搬。故直接写这份镜像。
       * 注：它落在共享的 vmDir 下，多台 riscv64 VM 同时运行会争用同一份变量存储；
       * 真要并行需按 VM 各复制一份，目前先按单台用。 */
      args.push('-drive', `if=pflash,format=raw,file=${vmDataDir}/edk2-riscv-vars.fd`);
    }
    /* 串口（v4）：virt 板无 ISA UART，经 virtio-serial + virtconsole 接 socket 交互。
     * logfile 是 chardev 的通用选项（qemu_chr_parse_common，见 chardev/char.c）：
     * 交互之外把数据同时落盘，恢复 v4 之前 `-serial file:` 的可事后诊断能力——
     * 没有它，没人连 Console 串口视图时 guest 往串口写的东西会直接丢弃。
     * 与历史行为一致，该文件无轮转上限（guest 行为决定，非本应用可控）。 */
    if (p.machine.serialInteractive) {
      args.push('-chardev', `socket,path=${vmDataDir}/serial-${p.id}.sock,server=on,wait=off,id=chr0,logfile=${vmDataDir}/serial-${p.id}.log`);
      args.push('-device', 'virtio-serial-pci');
      args.push('-device', 'virtconsole,chardev=chr0');
    }
  } else {
    args.push('-machine', board);
    args.push('-vga', fitVga(board, p.machine.vga));
    /* 串口（v4）：默认 socket 交互（Console 串口视图读）+ logfile 同时落盘（见上）；
     * 关掉则维持纯落盘 file 日志 */
    if (p.machine.serialInteractive) {
      args.push('-chardev', `socket,path=${vmDataDir}/serial-${p.id}.sock,server=on,wait=off,id=chr0,logfile=${vmDataDir}/serial-${p.id}.log`);
      args.push('-serial', 'chardev:chr0');
    } else {
      args.push('-serial', `file:${vmDataDir}/serial-${p.id}.log`);
    }
  }
  /* -cpu（v6 关联增强）：cpuFlags（如 "+sse4a,-avx2"）与 cpuModel 合并成
   * `-cpu <模型>,<flags>`；模型为空时用 max 承载 flags（x86 TCG 的 max 合法，
   * 且行为与 virt 板的默认 max 一致）。两者皆空：pc/q35 交 qemu 默认，virt 给
   * max，raspi 固定 CPU 不支持自定义——三处都不产生 -cpu。 */
  if (!isRaspi) {
    const cpuModel = p.machine.cpuModel;
    const cpuFlags = p.machine.cpuFlags.trim();
    if (cpuModel.length > 0 || cpuFlags.length > 0) {
      let cpu = cpuModel.length > 0 ? cpuModel : 'max';
      if (cpuFlags.length > 0) {
        cpu += ',' + cpuFlags;
      }
      args.push('-cpu', cpu);
    } else if (board === 'virt') {
      args.push('-cpu', 'max');
    }
  }
  /* 全部磁盘（v5 数组化）：disks[0]=系统盘（快照/临时会话/启动对象），其余数据盘。
   * raspi 的 SD 卡控制器只挂一张（PC/arm 板卡经 virtio 可挂多张）。
   * 快照与临时会话只作用于系统盘，数据盘不参与回滚。 */
  let diskIdx = 0;
  for (const d of p.media.disks) {
    if (d.path.length === 0) {
      continue;
    }
    if (isRaspi && diskIdx > 0) {
      continue;
    }
    let ds = `file=${d.path},if=${isRaspi ? 'sd' : 'virtio'},format=${driveFmt(d.path)}`;
    if (d.readonly) {
      ds += ',readonly=on';
    }
    args.push('-drive', ds);
    diskIdx++;
  }
  /* 直接内核引导：-kernel 由 qemu 直接装载内核，绕过固件(SeaBIOS/EDK2)的
   * 引导流程；x86 经 linuxboot 固件（deps 已产出），virt/raspi 原生支持 */
  if (p.media.kernelPath.length > 0) {
    args.push('-kernel', p.media.kernelPath);
    if (p.media.initrdPath.length > 0) {
      args.push('-initrd', p.media.initrdPath);
    }
    if (p.media.kernelAppend.length > 0) {
      args.push('-append', p.media.kernelAppend);
    }
  }
  if (!isRaspi) {
    /* 多 ISO：第一张保持 -cdrom（linux 单盘行为不变）；附加盘按板卡挂 CD 设备
     * （pc/q35 用 ide-cd；virt 挂到已有 usb-ehci 的 usb-storage）。 */
    if (isos.length > 0) {
      args.push('-cdrom', isos[0]);
      for (let i = 1; i < isos.length; i++) {
        const id = 'cd' + i;
        args.push('-drive', `if=none,format=raw,file=${isos[i]},id=${id},media=cdrom,readonly=on`);
        if (board === 'virt') {
          args.push('-device', `usb-storage,drive=${id},bus=usb.0`);
        } else {
          args.push('-device', `ide-cd,drive=${id}`);
        }
      }
    }
    args.push('-boot', p.media.bootFromCdrom ? 'd' : 'c');
  }
  if (isRaspi) {
    /* 树莓派无 PCI，virtio-net 不可用；网络在 qemu 树莓派模拟下受限（实验性） */
    args.push('-nic', 'none');
  } else if (p.net.enabled) {
    args.push('-netdev', userNetdev(p.net.portForwards), '-device', 'virtio-net-pci,netdev=n0');
  } else {
    args.push('-nic', 'none');
  }
  if (p.net.sharedFolder && sharedDir.length > 0) {
    /* 9p 共享宿主目录到 guest /shared（宿主目录须已存在，由调用方 mkdir） */
    args.push('-virtfs', `local,path=${sharedDir},mount_tag=shared,security_model=none,multidevs=remap`);
  }
  /* 系统增强设备（v4）：RNG/balloon 均需 PCI；raspi 无 PCI 跳过 */
  if (!isRaspi) {
    if (p.runtime.rng) {
      args.push('-device', 'virtio-rng-pci');
    }
    if (p.runtime.balloon) {
      args.push('-device', 'virtio-balloon-pci');
    }
  }
  /* 声音（v6）：OHOS 音频后端（driver=ohos，见 libqemu 补丁）——
   * pc/q35 用 AC97（UTM 同款，guest 走 snd_intel8x0/ac97），virt 用
   * virtio-sound-pci（guest 走 snd_virtio）。每 VM 独立 qemu 进程，
   * audiodev id=ohos0 天然无冲突。raspi 无模拟声卡，忽略并 UI 禁用。 */
  if (!isRaspi) {
    if (p.runtime.audio) {
      args.push('-audiodev', 'driver=ohos,id=ohos0');
      args.push('-device', board === 'virt' ? 'virtio-sound-pci,audiodev=ohos0' : 'AC97,audiodev=ohos0');
    }
  }
  const extra = p.extraArgs.trim();
  if (extra.length > 0) {
    args = args.concat(extra.split(/\s+/));
  }
  return args;
}

export class VmStore {
  readonly dir: string;

  constructor(filesDir: string) {
    this.dir = filesDir + '/vms';
    if (!fs.accessSync(this.dir)) {
      fs.mkdirSync(this.dir, true);
    }
  }

  private profilePath(id: string): string {
    return `${this.dir}/${id}.json`;
  }

  list(): VmProfile[] {
    const out: VmProfile[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.dir);
    } catch {
      return out;
    }
    for (const name of names) {
      if (!name.endsWith('.json')) {
        continue;
      }
      const p = this.load(name.substring(0, name.length - 5));
      if (p) {
        out.push(p);
      }
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    return out;
  }

  load(id: string): VmProfile | null {
    try {
      const fd = fs.openSync(this.profilePath(id), fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(64 * 1024);
      const n = fs.readSync(fd.fd, buf);
      fs.closeSync(fd);
      const obj = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n))) as Object;
      return migrateProfile(obj);
    } catch {
      return null;
    }
  }

  save(p: VmProfile): void {
    p.schemaVersion = SCHEMA_VERSION;
    const fd = fs.openSync(this.profilePath(p.id),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(fd.fd, JSON.stringify(p, null, 2));
    fs.closeSync(fd);
  }

  /* ---- 「上次启动失败」标记（熔断）----
   * 背景：跑飞的 qemu 子进程会以 ~38MB/s 灌盘且不退；配置又落在应用私有目录，
   * 用户侧无手段自救（hdc shell rm 被 SELinux 拒）。若 console 一打开就自动重启，
   * 应用等于被锁死。故失败后落一个标记，下次进入不自动启动，由用户显式重试。
   * 文件名以 .bootfail 结尾，而 list() 只收 *.json —— 不会被误列成一台 VM。 */
  private bootFailPath(id: string): string {
    return `${this.dir}/${id}.bootfail`;
  }

  markBootFail(id: string, reason: string): void {
    try {
      const fd = fs.openSync(this.bootFailPath(id),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(fd.fd, JSON.stringify({ at: Date.now(), reason }));
      fs.closeSync(fd);
    } catch {
      /* best effort：写不进就不熔断，不能因为标记失败把正常使用挡住 */
    }
  }

  /* 上次失败原因；无标记返回 ''。读法同 load()：固定 4KB 缓冲 + UTF-8 解码。 */
  readBootFail(id: string): string {
    try {
      const path = this.bootFailPath(id);
      if (!fs.accessSync(path)) {
        return '';
      }
      const fd = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(4096);
      const n = fs.readSync(fd.fd, buf);
      fs.closeSync(fd);
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n));
      const obj = JSON.parse(text) as Record<string, Object>;
      const r = obj['reason'];
      return typeof r === 'string' ? r as string : '';
    } catch {
      return '';
    }
  }

  clearBootFail(id: string): void {
    try {
      const path = this.bootFailPath(id);
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch {
      /* best effort */
    }
  }

  /* 删配置以及位于 vms 目录内的全部磁盘镜像与内核/initrd 副本 */
  remove(p: VmProfile): void {
    this.clearBootFail(p.id);
    const paths: string[] = [this.profilePath(p.id), p.media.kernelPath, p.media.initrdPath];
    for (const d of p.media.disks) {
      paths.push(d.path);
    }
    for (const path of paths) {
      try {
        if (path.length > 0 && path.startsWith(this.dir) && fs.accessSync(path)) {
          fs.unlinkSync(path);
        }
      } catch {
        /* best effort */
      }
    }
  }
}
