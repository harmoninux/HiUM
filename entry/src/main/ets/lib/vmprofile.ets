// VM 配置数据模型（schema v2）：一份 JSON 存 filesDir/vms/<id>.json。
// v2 把扁平字段拆成 machine / runtime / media / net 四层，UI 只面对这套领域对象，
// buildArgs 是纯函数把它翻成 qemu 命令行。所有读取经 migrateProfile 统一做
// 版本判定 + 缺字段回填，不再在 load() 里逐字段塞 if。
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const SCHEMA_VERSION = 3;

const DOMAIN = 0x0210;
const TAG = 'QemuProf';

export type VmArch = 'x86_64' | 'i386' | 'aarch64' | 'arm' | 'loongarch64' | 'riscv64';
export type VgaType = 'std' | 'virtio';
export type VmBoard = 'pc' | 'q35' | 'virt' | 'raspi2' | 'raspi3';
export type VmFirmware = 'seabios' | 'ovmf';

/* 机器层：架构/显卡 + 板卡/固件/CPU 模型。机器工坊按此生成 -machine/-cpu 参数 */
export interface VmMachine {
  arch: VmArch;
  vga: VgaType;
  machine: VmBoard;    /* 板卡：x86 pc/q35，arm64/arm virt/raspi2/raspi3，loongarch64/riscv64 virt */
  firmware: VmFirmware; /* 固件：seabios(BIOS) / ovmf(UEFI，暂需 OVMF 文件) */
  cpuModel: string;     /* '' = 自动（arm64/arm/loongarch64 给 max） */
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

/* 运行时层：可被 JIT 性能预设覆盖（memory/cpus/accel） */
export interface VmRuntime {
  memoryMB: number;
  cpus: number;
  mttcg: boolean;   /* TCG 多线程 */
  tbSize: number;
}

/* 介质层 */
export interface VmMedia {
  diskPath: string;     /* 系统盘必配：新建/编辑均在标准位置生成 qcow2；创建时也可导入镜像（复制进 vms/） */
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
    machine: { arch: 'x86_64', vga: 'std', machine: 'pc', firmware: 'seabios', cpuModel: '' },
    runtime: { memoryMB: 1024, cpus: 2, mttcg: true, tbSize: 1024 },
    media: { diskPath: '', cdromPaths: [], bootFromCdrom: false, kernelPath: '', initrdPath: '', kernelAppend: '' },
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
    case 2: /* v2→v3：media 新增 kernel 三字段，统一由归一化回填 '' */
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
  p.media.diskPath = jStr(o, 'diskPath');
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
    if (jStr(m, 'vga') === 'virtio') {
      p.machine.vga = 'virtio';
    }
    p.machine.machine = fitBoard(p.machine.arch, jStr(m, 'machine'));
    p.machine.firmware = jStr(m, 'firmware') === 'ovmf' ? 'ovmf' : 'seabios';
    p.machine.cpuModel = jStr(m, 'cpuModel');
  }
  if (r) {
    p.runtime.memoryMB = jNum(r, 'memoryMB', p.runtime.memoryMB);
    p.runtime.cpus = jNum(r, 'cpus', p.runtime.cpus);
    p.runtime.mttcg = jBool(r, 'mttcg', p.runtime.mttcg);
    p.runtime.tbSize = jNum(r, 'tbSize', p.runtime.tbSize);
  }
  if (md) {
    p.media.diskPath = jStr(md, 'diskPath');
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
    '-device', 'virtio-tablet-pci',
    '-qmp', `unix:${qmpSockPath(p, vmDataDir)},server=on,wait=off`,
  ];
  /* 板卡/固件/CPU：默认 pc(x86)/virt(arm64) 与旧行为一致（qemu 默认即 pc）；
   * 新板卡 q35/raspi2 走对应 -machine。aarch64 默认给 -cpu max，virt 挂 virtio-gpu。
   * aarch64 virt 现已接入 edk2-aarch64-code.fd（-bios）；x86 的 firmware=ovmf
   * 仍未接 pflash（需 OVMF_CODE/VARS 固件），缺件回落 seabios。 */
  const board = fitBoard(p.machine.arch, p.machine.machine);
  const isRaspi = board === 'raspi2' || board === 'raspi3';
  if (isRaspi) {
    /* 树莓派：qemu 10.2 实际机器名 raspi2b/raspi3b（旧代码 'raspi2' 会报 unsupported machine）。
     * 树莓派 SoC 自带引导、不依赖 edk2/BIOS；无 PCI，故不挂 virtio-gpu/net；磁盘经 SD 卡控制器。 */
    args.push('-machine', board === 'raspi2' ? 'raspi2b' : 'raspi3b');
  } else if (board === 'virt') {
    args.push('-machine', board);
    args.push('-cpu', p.machine.cpuModel.length > 0 ? p.machine.cpuModel : 'max');
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
      args.push('-bios', vmDataDir + '/edk2-riscv-code.fd');
    }
  } else {
    args.push('-machine', board);
    if (p.machine.cpuModel.length > 0) {
      args.push('-cpu', p.machine.cpuModel);
    }
    args.push('-vga', p.machine.vga);
    args.push('-serial', `file:${vmDataDir}/serial-${p.id}.log`);
  }
  if (p.media.diskPath.length > 0) {
    /* 默认新建的是 qcow2；导入的 raw 镜像仍按扩展名回退到 raw */
    const fmt = p.media.diskPath.toLowerCase().endsWith('.qcow2') ? 'qcow2' : 'raw';
    const bus = isRaspi ? 'sd' : 'virtio'; /* 树莓派经 SD 卡控制器，非 virtio-blk */
    args.push('-drive', `file=${p.media.diskPath},if=${bus},format=${fmt}`);
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

  /* 删配置以及位于 vms 目录内的磁盘镜像与内核/initrd 副本 */
  remove(p: VmProfile): void {
    for (const path of [this.profilePath(p.id), p.media.diskPath,
      p.media.kernelPath, p.media.initrdPath]) {
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
