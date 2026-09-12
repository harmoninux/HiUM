// 模板创建：单页模态（与 VmWizard 自定义向导并列的独立流程，见 docs/vm-template-creation.md）。
// 当前仅 Alpine Linux 一个模板；只暴露 架构/核数/内存/系统盘大小 4 个自由度，
// 其余 = blankProfile 全默认（网络开启 · 声卡开 · TCG 多线程），产物与手工创建完全同构。
// 创建时先建空白 qcow2 再落档（与向导 finish 同序），随后自动下载对应架构的内置
// Alpine ISO（已存在则秒过）；下载失败不毁单——VmConsole.startVm 首启有重下兜底。
// 名称不询问：自动「Alpine <rel> <arch>」，与现有 VM 重名追加「 2」「 3」… 后缀。
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import napiModule from 'libentry.so';
import {
  VmProfile, VmStore, VmArch, blankProfile, defaultBoard, fitVga,
  newProfileId, builtinIsoFor,
} from '../lib/vmprofile';
import { ensureBuiltinIso, alpineRelFor, alpineSizeFor } from '../lib/isoDl';
import { pathExists } from '../lib/fsutil';
import {
  cPrimary, cSub, cWeak, cText, cBorder, cBg, cChip, cSel, cSelBg,
  tPage, tCard, tBody, tSub, tLabel,
  sp1, sp2, sp3, sp4, sp8, spCard, bw, rElem, rBtn, rBadge, btnH, btnPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
}
const napi = napiModule as DiskNapi;

const ARCH_OPTIONS: VmArch[] = ['x86_64', 'i386', 'aarch64', 'arm', 'loongarch64', 'riscv64'];
const DISK_SIZES: number[] = [4, 8, 16, 32, 64];

@Component
export struct VmTemplate {
  onClose: (() => void) | null = null; /* 模态关闭回调（宿主 Index 置 showTemplate=false） */
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmDataDir') vmDataDir: string = '';

  @State arch: VmArch = 'x86_64';
  @State cpus: number = 2;
  @State memoryMB: number = 1024;
  @State diskGB: number = 8;
  /* 名称预览与 ISO 就绪态在 aboutToAppear/切架构时算好缓存——build 里不做磁盘 IO
   *（Slider 拖动会高频重渲染） */
  @State namePreview: string = '';
  @State isoOk: boolean = false;
  @State creating: boolean = false;
  @State dlPct: number = 0;

  aboutToAppear(): void {
    /* 每次打开都重置到默认，防止组件实例跨 if(showTemplate) 开关复用残留状态 */
    this.arch = 'x86_64';
    this.cpus = 2;
    this.memoryMB = 1024;
    this.diskGB = 8;
    this.creating = false;
    this.dlPct = 0;
    this.refreshDerived('x86_64');
  }

  /* 切架构后的派生缓存：自动名（查 VmStore）+ 内置 ISO 是否已就位（查文件系统） */
  private refreshDerived(a: VmArch): void {
    this.namePreview = this.autoName(a);
    this.isoOk = pathExists(this.vmDataDir + '/' + builtinIsoFor(a));
  }

  private archLabel(a: VmArch): string {
    return a === 'loongarch64' ? 'loongarch' : a;
  }

  /* 自动命名：Alpine <rel> <arch>；与现有 VM 重名追加「 2」「 3」… 去重 */
  private autoName(arch: VmArch): string {
    const base = `Alpine ${alpineRelFor(arch)} ${arch}`;
    const names: string[] = new VmStore(this.filesDir).list().map((p: VmProfile) => p.name);
    if (names.indexOf(base) < 0) {
      return base;
    }
    for (let i = 2; ; i++) {
      const cand = `${base} ${i}`;
      if (names.indexOf(cand) < 0) {
        return cand;
      }
    }
  }

  /* 模板产物 = blankProfile 全默认（与手工向导全默认一致）+ 4 个表单项 + 内置 ISO 挂光驱 */
  private assemble(id: string, name: string): VmProfile {
    const p = blankProfile(id);
    p.name = name;
    p.machine.arch = this.arch;
    p.machine.machine = defaultBoard(this.arch);
    p.machine.vga = fitVga(p.machine.machine, 'std');
    p.runtime.memoryMB = Math.round(this.memoryMB);
    p.runtime.cpus = Math.round(this.cpus);
    p.media.disks = [{ path: `${this.filesDir}/vms/${id}.qcow2`, readonly: false }];
    p.media.cdromPaths = [this.vmDataDir + '/' + builtinIsoFor(this.arch)];
    p.media.bootFromCdrom = true;
    return p;
  }

  private create(): void {
    if (this.creating) {
      return;
    }
    this.creating = true;
    this.dlPct = 0;
    const id = newProfileId();
    const p = this.assemble(id, this.autoName(this.arch));
    /* 与手工向导 finish 同序：先建盘，成功后才落档（取消/失败不留孤儿档） */
    const diskPath = p.media.disks[0].path;
    if (!pathExists(diskPath)) {
      const ret = napi.createDisk(diskPath, Math.round(this.diskGB * 1024), 'dynamic');
      if (ret !== 0) {
        promptAction.showToast({ message: '创建磁盘失败' });
        this.creating = false;
        return;
      }
    }
    new VmStore(this.filesDir).save(p);
    /* 下载内置 ISO（同架构多 VM 共享一份，已存在则秒过）；失败不毁单：档案保留，
     * 首次启动时 VmConsole.startVm 对内置 ISO 有重下兜底 */
    const ctx = getContext(this) as common.UIAbilityContext;
    ensureBuiltinIso(ctx, this.vmDataDir, this.arch, (pct: number) => {
      this.dlPct = pct;
    }).then((ok: boolean) => {
      this.creating = false;
      promptAction.showToast({
        message: ok ? `已创建「${p.name}」` : `已创建「${p.name}」；镜像下载失败，首次启动时自动重试`,
      });
      if (this.onClose) { this.onClose(); }
    });
  }

  /* 分组标题 + 分割线（与 VmWizard 同款组头） */
  @Builder
  groupHeader(label: string) {
    Row({ space: sp8 }) {
      Text(label).fontSize(tLabel).fontColor(cSub)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp1 })
  }

  build() {
    Column() {
      Row() {
        Blank()
        Text('模板创建').fontSize(tPage).fontWeight(FontWeight.Medium)
        Blank()
      }
      .width('100%')
      .padding({ left: sp4, right: sp4, top: sp2, bottom: sp2 })

      Scroll() {
        Column({ space: spCard }) {
          /* 模板卡片：当前仅 Alpine 一张，恒选中（纯信息展示，无多模板选择） */
          Row({ space: sp2 }) {
            Column({ space: sp1 }) {
              Text('Alpine Linux').fontSize(tCard).fontWeight(FontWeight.Medium).fontColor(cText)
              Text('迷你安全发行版 · 文本模式 · 内置镜像').fontSize(tSub).fontColor(cWeak)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('内置 ISO').fontSize(tSub).fontColor(cPrimary)
              .backgroundColor(cChip).borderRadius(rBadge)
              .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
          }
          .width('100%')
          .padding(spCard)
          .backgroundColor(cSelBg)
          .border({ width: bw, color: cSel })
          .borderRadius(rElem)

          this.groupHeader('CPU 架构')
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(ARCH_OPTIONS, (a: VmArch) => {
              Text(this.archLabel(a)).fontSize(tBody)
                .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
                .margin({ right: sp2, bottom: sp2 })
                .fontColor(this.arch === a ? Color.White : cSub)
                .backgroundColor(this.arch === a ? cPrimary : cChip)
                .borderRadius(rBadge)
                .onClick(() => {
                  this.arch = a;
                  this.refreshDerived(a);
                })
            }, (a: VmArch) => a)
          }
          .width('100%')

          this.groupHeader('CPU 核数')
          Text(`${Math.round(this.cpus)} 核`).fontSize(tLabel).width('100%')
          Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
            .onChange((v: number) => this.cpus = v)

          this.groupHeader('内存')
          Text(`${Math.round(this.memoryMB)} MB`).fontSize(tLabel).width('100%')
          Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
            .onChange((v: number) => this.memoryMB = v)

          this.groupHeader('系统盘')
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(DISK_SIZES, (g: number) => {
              Text(`${g}G`).fontSize(tBody)
                .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
                .margin({ right: sp2, bottom: sp2 })
                .fontColor(this.diskGB === g ? Color.White : cSub)
                .backgroundColor(this.diskGB === g ? cPrimary : cChip)
                .borderRadius(rBadge)
                .onClick(() => this.diskGB = g)
            }, (g: number) => String(g))
          }
          .width('100%')
          Text('动态分配 qcow2，用到多少占多少').fontSize(tSub).fontColor(cWeak).width('100%')

          Divider().strokeWidth(1).color(cBorder)
          Text(`名称：${this.namePreview}（创建后可改）`).fontSize(tSub).fontColor(cWeak).width('100%')
          Text('其余按推荐默认：网络开启 · 声卡开 · TCG 多线程 · 从光盘引导')
            .fontSize(tSub).fontColor(cWeak).width('100%')
          Text(this.isoOk
            ? '内置 Alpine 镜像已就绪，无需下载'
            : `创建后自动下载 Alpine 镜像（约 ${alpineSizeFor(this.arch)}MB，国内镜像站）`)
            .fontSize(tSub).fontColor(cWeak).width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)

      Row({ space: sp3 }) {
        Blank()
        /* 取消随时可点：未落盘直接关模态；下载中取消则档案保留（同下载失败语义） */
        Button('取消').focusable(false).fontSize(tBody)
          .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
          .backgroundColor(Color.Transparent)
          .fontColor(cSub)
          .onClick(() => { if (this.onClose) { this.onClose(); } })
        Button(this.creating ? `下载中 ${this.dlPct}%` : '创建虚拟机').focusable(false).fontSize(tBody)
          .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
          .backgroundColor(Color.Transparent)
          .fontColor(this.creating ? cWeak : cPrimary)
          .enabled(!this.creating)
          .onClick(() => this.create())
        Blank()
      }
      .width('100%')
      .padding({ left: sp4, right: sp4, top: sp2, bottom: sp2 })
      .backgroundColor(cBg)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cBg)
  }
}
