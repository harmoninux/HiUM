// VM 配置数据模型：一份 JSON 存 filesDir/vms/<id>.json，buildArgs 把它翻成
// qemu 命令行。UI 只面对这个模型，不直接拼 qemu 参数。
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export type VmArch = 'x86_64' | 'i386' | 'aarch64';
export type VgaType = 'std' | 'virtio';

export interface VmProfile {
  id: string;
  name: string;
  arch: VmArch;
  memoryMB: number;
  cpus: number;
  diskPath: string;   /* '' = 无系统盘；当前只支持 raw 稀疏镜像 */
  cdromPath: string;  /* '' = 无光盘 */
  bootFromCdrom: boolean;
  vga: VgaType;
  netEnabled: boolean;
  portForwards: string; /* "8080:80,2222:22"，空串 = 不转发 */
  mttcg: boolean;
  tbSize: number;
  extraArgs: string;  /* escape hatch：原样追加到 qemu 命令行 */
  qmpPort: number;
}

export function newProfileId(): string {
  return 'vm' + Date.now().toString(36) + Math.floor(Math.random() * 1296).toString(36);
}

export function blankProfile(id: string): VmProfile {
  return {
    id: id,
    name: '新虚拟机',
    arch: 'x86_64',
    memoryMB: 1024,
    cpus: 2,
    diskPath: '',
    cdromPath: '',
    bootFromCdrom: false,
    vga: 'std',
    netEnabled: true,
    portForwards: '',
    mttcg: true,
    tbSize: 1024,
    extraArgs: '',
    qmpPort: 4444,
  };
}

/* 内置 Alpine ISO 的快捷预设 */
export function alpineProfile(id: string, vmDataDir: string): VmProfile {
  const p = blankProfile(id);
  p.name = 'Alpine Linux (x86_64)';
  p.cdromPath = vmDataDir + '/alpine-virt.iso';
  p.bootFromCdrom = true;
  return p;
}

/* 解析 "8080:80,2222:22" 形式的端口转发；非法条目直接跳过 */
function parseForwards(text: string): string[] {
  const out: string[] = [];
  for (const item of text.split(',')) {
    const kv = item.trim().split(':');
    if (kv.length !== 2) {
      continue;
    }
    const host = Number(kv[0]);
    const guest = Number(kv[1]);
    if (Number.isInteger(host) && Number.isInteger(guest) && host > 0 && guest > 0) {
      out.push(`hostfwd=tcp::${host}-:${guest}`);
    }
  }
  return out;
}

export function buildArgs(p: VmProfile, vmDataDir: string): string[] {
  let args: string[] = [
    '-L', vmDataDir,
    '-m', String(p.memoryMB),
    '-smp', String(p.cpus),
    '-accel', `tcg,thread=${p.mttcg ? 'multi' : 'single'},tb-size=${p.tbSize}`,
    '-display', 'none',
    '-device', 'virtio-tablet-pci',
    '-qmp', `tcp:127.0.0.1:${p.qmpPort},server=on,wait=off`,
  ];
  if (p.arch === 'aarch64') {
    args = args.concat(['-machine', 'virt', '-cpu', 'max', '-device', 'virtio-gpu-pci']);
  } else {
    args.push('-vga', p.vga);
    args.push('-serial', 'file:' + vmDataDir + '/serial.log');
  }
  if (p.diskPath.length > 0) {
    args.push('-drive', `file=${p.diskPath},if=virtio,format=raw`);
  }
  if (p.cdromPath.length > 0) {
    args.push('-cdrom', p.cdromPath);
  }
  args.push('-boot', p.bootFromCdrom ? 'd' : 'c');
  if (p.netEnabled) {
    let netdev = 'user,id=n0';
    for (const fwd of parseForwards(p.portForwards)) {
      netdev += ',' + fwd;
    }
    args.push('-netdev', netdev, '-device', 'virtio-net-pci,netdev=n0');
  } else {
    args.push('-nic', 'none');
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

  thumbPath(id: string): string {
    return `${this.dir}/${id}.jpg`;
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
      const obj = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n))) as VmProfile;
      if (!obj.name || !obj.arch || typeof obj.memoryMB !== 'number') {
        return null;
      }
      /* 旧版本缺字段时回填默认（arkts 不允许对象 spread，逐字段来） */
      const d = blankProfile(id);
      if (obj.cpus === undefined) obj.cpus = d.cpus;
      if (obj.diskPath === undefined) obj.diskPath = d.diskPath;
      if (obj.cdromPath === undefined) obj.cdromPath = d.cdromPath;
      if (obj.bootFromCdrom === undefined) obj.bootFromCdrom = d.bootFromCdrom;
      if (obj.vga === undefined) obj.vga = d.vga;
      if (obj.netEnabled === undefined) obj.netEnabled = d.netEnabled;
      if (obj.portForwards === undefined) obj.portForwards = d.portForwards;
      if (obj.mttcg === undefined) obj.mttcg = d.mttcg;
      if (obj.tbSize === undefined) obj.tbSize = d.tbSize;
      if (obj.extraArgs === undefined) obj.extraArgs = d.extraArgs;
      if (obj.qmpPort === undefined) obj.qmpPort = d.qmpPort;
      obj.id = id;
      return obj;
    } catch {
      return null;
    }
  }

  save(p: VmProfile): void {
    const fd = fs.openSync(this.profilePath(p.id),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(fd.fd, JSON.stringify(p, null, 2));
    fs.closeSync(fd);
  }

  /* 删配置、缩略图以及位于 vms 目录内的磁盘镜像 */
  remove(p: VmProfile): void {
    for (const path of [this.profilePath(p.id), this.thumbPath(p.id), p.diskPath]) {
      try {
        if (path.length > 0 && path.startsWith(this.dir) && fs.accessSync(path)) {
          fs.unlinkSync(path);
        }
      } catch {
        /* best effort */
      }
    }
  }

  /* qemu .so 一进程只能用一轮：二次启动前记录待启动 VM，由上层重启进程后
   * 自动接管（见 VmList/Console） */
  setAutostart(id: string): void {
    const fd = fs.openSync(`${this.dir}/.autostart`,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(fd.fd, id);
    fs.closeSync(fd);
  }

  /* 读取并清除 autostart 标记；无标记返回 '' */
  takeAutostart(): string {
    const path = `${this.dir}/.autostart`;
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      const fd = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(128);
      const n = fs.readSync(fd.fd, buf);
      fs.closeSync(fd);
      fs.unlinkSync(path);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n)).trim();
    } catch {
      return '';
    }
  }
}
