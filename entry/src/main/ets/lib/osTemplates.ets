// OS 模板库：预置四套异构 OS 的参数模板 + 工厂函数。
// 模板只定义「参数意图」——板卡/固件/CPU/内存/介质形态，不直接落盘。
// 创建者（列表页「从模板新建」/ 机器工坊向导）拿 buildTemplateProfile 产出 VmProfile，
// 再按 diskMB>0 创建系统盘、按 isoName 内置 ISO 指引补镜像。imageNeeded 供卡片灰字标注。
import {
  VmProfile, VmArch, VmBoard, VmFirmware, VgaType, blankProfile,
} from './vmprofile';

export interface OsTemplate {
  id: string;          /* 'alpine' | 'android-x86' | 'free-dos' | 'bare-kernel' */
  icon?: string;       /* 磁贴 emoji；缺省回落 💿 */
  name: string;
  arch: VmArch;
  desc: string;        /* 卡片一句话 */
  imageNeeded: boolean;/* true = 需自备镜像 */
  imageLabel: string;  /* 卡片镜像状态文案 */
  diskMB: number;      /* 系统盘大小(MB)；0 = 无系统盘 */
  board: VmBoard;
  firmware: VmFirmware;
  vga: VgaType;
  memoryMB: number;
  cpus: number;
  mttcg: boolean;
  tbSize: number;
  bootFromCdrom: boolean;
  isoName: string;     /* 内置 ISO（filesDir/vm 下）；'' = 无内置 */
  kernelBoot: boolean; /* 直启内核：磁盘/ISO 弱化（教学/开发者实验室） */
}

export const OS_TEMPLATES: OsTemplate[] = [
  {
    id: 'alpine',
    icon: '🐧',
    name: 'Alpine Linux',
    arch: 'x86_64',
    desc: '内置 ISO 引导 + 8G 系统盘，开箱即起',
    imageNeeded: false,
    imageLabel: '内置 alpine-virt (x86_64)',
    diskMB: 8192,
    board: 'pc', firmware: 'seabios', vga: 'std',
    memoryMB: 1024, cpus: 2, mttcg: true, tbSize: 1024,
    bootFromCdrom: true, isoName: 'alpine-virt-x86_64.iso', kernelBoot: false,
  },
  {
    id: 'android-x86',
    icon: '🤖',
    name: 'Android-x86',
    arch: 'x86_64',
    desc: 'q35 板卡 + virtio 显存优先，跑安卓',
    imageNeeded: true,
    imageLabel: '需自备 android-x86.iso',
    diskMB: 8192,
    board: 'q35', firmware: 'seabios', vga: 'virtio',
    memoryMB: 2048, cpus: 2, mttcg: true, tbSize: 1024,
    bootFromCdrom: true, isoName: '', kernelBoot: false,
  },
  {
    id: 'free-dos',
    icon: '💾',
    name: 'FreeDOS',
    arch: 'i386',
    desc: '经典 DOS，单核最低配，怀旧/教学',
    imageNeeded: true,
    imageLabel: '需自备 freedos.iso / 软盘',
    diskMB: 512,
    board: 'pc', firmware: 'seabios', vga: 'std',
    memoryMB: 512, cpus: 1, mttcg: false, tbSize: 524,
    bootFromCdrom: true, isoName: '', kernelBoot: false,
  },
  {
    id: 'bare-kernel',
    icon: '⚙️',
    name: '裸内核 (直启)',
    arch: 'aarch64',
    desc: '-kernel/-initrd 直启，最小内核教学',
    imageNeeded: true,
    imageLabel: '需自备 kernel/initrd',
    diskMB: 0,
    board: 'virt', firmware: 'seabios', vga: 'virtio',
    memoryMB: 1024, cpus: 2, mttcg: true, tbSize: 1024,
    bootFromCdrom: false, isoName: '', kernelBoot: true,
  },
];

/* 按模板产出 VmProfile（diskPath 指向待创建路径；ISO 指向内置或留空待自备）。
 * id/filesDir/vmDataDir 决定落盘位置，剩下的由创建者负责（创建盘 0 时不动）。 */
export function buildTemplateProfile(tpl: OsTemplate, id: string, filesDir: string, vmDataDir: string): VmProfile {
  const p = blankProfile(id);
  p.name = `${tpl.name} (${tpl.arch})`;
  p.machine.arch = tpl.arch;
  p.machine.vga = tpl.vga;
  p.machine.machine = tpl.board;
  p.machine.firmware = tpl.firmware;
  p.machine.cpuModel = '';
  p.runtime.memoryMB = tpl.memoryMB;
  p.runtime.cpus = tpl.cpus;
  p.runtime.mttcg = tpl.mttcg;
  p.runtime.tbSize = tpl.tbSize;
  if (tpl.diskMB > 0) {
    p.media.diskPath = `${filesDir}/vms/${id}.qcow2`;
  }
  if (tpl.isoName.length > 0) {
    p.media.cdromPaths = [`${vmDataDir}/${tpl.isoName}`];
  }
  p.media.bootFromCdrom = tpl.bootFromCdrom;
  p.net.enabled = true;
  p.net.portForwards = '';
  p.net.sharedFolder = false;
  p.temporarySession = false;
  p.extraArgs = '';
  return p;
}
