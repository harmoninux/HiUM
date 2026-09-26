// 模板创建：单页模态（与 VmWizard 自定义向导并列的独立流程，见 docs/vm-template-creation.md）。
// 模板注册表内联于本文件（唯一消费方，不外提 lib——避免再造孤岛数据文件）：
// Alpine 走「内置 ISO 自动下载」一键开箱；Windows 模板走「自备镜像」（版权镜像不能
// 内置），参数按 Windows 兼容性选型：x86_64 + -cpu max（Win8.1+ x64 强制检查
// PREFETCHW/POPCNT，qemu32/i386 与 qemu64 都过不了检查，见模板内注释；32 位镜像
// 靠 x64 CPU 向下兼容）、IDE 磁盘（安装程序无 virtio 块驱动）、rtl8139 网卡
// （Win10 无 in-box 驱动，装完系统需自行补）、RTC 本地时区（Windows 把 RTC 当
// 本地时间）、声卡默认关（AC97 从 Win8 起无 in-box 驱动）。
// 产物与手工创建完全同构（无模板标记），创建后可改任何参数。
// 创建时先建空白 qcow2 再落档（与向导 finish 同序）；Alpine 创建后自动下载内置 ISO，
// Windows 未选镜像不阻塞创建（toast 提示到编辑页补挂）。
// 名称可空文本框：留空自动「<模板名> <架构>」（重名追加「 2」「 3」… 后缀）——
// 自动名只是兜底，模板 ≠ 装同名系统（Win10 模板常用来装 Win7/8），填了就原样用
// （同向导语义：不查重，VM 以 id 区分）。
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import napiModule from 'libentry.so';
import {
  VmProfile, VmStore, VmArch, VgaType, DiskIface, NetModel,
  blankProfile, defaultBoard, fitVga,
  newProfileId, builtinIsoFor,
} from '../lib/vmprofile';
import { ensureBuiltinIso, alpineRelFor, alpineSizeFor } from '../lib/isoDl';
import { pickIsoPath } from '../lib/isoPick';
import { pathExists } from '../lib/fsutil';
import {
  cPrimary, cSub, cWeak, cText, cBorder, cBg, cChip, cSel, cSelBg,
  tPage, tCard, tBody, tSub, tLabel,
  sp1, sp2, sp3, sp4, sp8, spCard, bw, rElem, rBtn, rBadge, btnH, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
}
const napi = napiModule as DiskNapi;

const DISK_SIZES: number[] = [4, 8, 16, 32, 64];

/* 模板注册表：只定义「参数意图」，板卡/固件交给 defaultBoard（Windows 架构只有
 * x86 → 恒 pc，天然排除 q35——ICH9 呈现 AHCI，XP 无 in-box 驱动会 0x7B 蓝屏）。 */
interface TplDef {
  id: string;
  icon: string;
  name: string;
  desc: string;
  archs: VmArch[];
  vga: VgaType;
  memoryMB: number;
  cpus: number;
  diskGB: number;
  diskIface: DiskIface;
  netModel: NetModel;
  rtcLocal: boolean;
  audio: boolean;
  cpuModel: string; /* ''=qemu 默认（XP/7 兼容默认）；Win10 必须 max（见模板内注释） */
  iso: 'builtin' | 'user'; /* builtin=按架构下载内置 Alpine；user=自备（可跳过） */
}

const TEMPLATES: TplDef[] = [
  {
    id: 'alpine', icon: '🐧', name: 'Alpine Linux',
    desc: '迷你安全发行版 · 文本模式 · 内置镜像',
    archs: ['x86_64', 'i386', 'aarch64', 'arm', 'loongarch64', 'riscv64'],
    vga: 'std', memoryMB: 1024, cpus: 2, diskGB: 8,
    diskIface: 'virtio', netModel: 'virtio', rtcLocal: false, audio: true,
    cpuModel: '',
    iso: 'builtin',
  },
  {
    /* 模板名就叫 Windows，不带版本：一条模板通吃 Win7/8/10（也装得下未来的
     * Win11），具体装什么由用户在名称框里自己起名（见下方注释的兼容矩阵） */
    id: 'windows', icon: '🪟', name: 'Windows',
    desc: '兼容 Win7/8/10 · 32/64 位镜像通用 · 需自备镜像',
    /* 只开 x86_64 + cpu max（qemu32 无 long mode 引导 x64 镜像即 0xC000035A 蓝屏；
     * qemu64 缺 PREFETCHW/POPCNT，Win8.1+ x64 内核检查不过即 0x5D 蓝屏——max 是
     * TCG 可模拟指令的全集（见 qemu target/i386/cpu.c TCG_*_FEATURES），Win7/8/10
     * 的 x64 与 32 位镜像通吃。x86 镜像靠 x64 CPU 向下兼容，不需要 i386 虚拟机。 */
    archs: ['x86_64'],
    vga: 'std', memoryMB: 4096, cpus: 2, diskGB: 64,
    diskIface: 'ide', netModel: 'rtl8139', rtcLocal: true, audio: false,
    cpuModel: 'max',
    iso: 'user',
  },
];

@Component
export struct VmTemplate {
  onClose: (() => void) | null = null; /* 模态关闭回调（宿主 Index 置 showTemplate=false） */
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmDataDir') vmDataDir: string = '';

  @State tplId: string = 'alpine';
  @State arch: VmArch = 'x86_64';
  @State cpus: number = 2;
  @State memoryMB: number = 1024;
  @State diskGB: number = 8;
  @State userIso: string = ''; /* Windows 自备安装镜像路径（原地引用，同向导选 ISO） */
  @State nameInput: string = ''; /* 自定义名称，可空——空=按模板自动命名 */
  /* 名称预览与镜像就绪态在 aboutToAppear/切模板/切架构时算好缓存——build 里不做磁盘 IO
   *（Slider 拖动会高频重渲染） */
  @State namePreview: string = '';
  @State isoOk: boolean = false;
  @State creating: boolean = false;
  @State dlPct: number = 0;

  aboutToAppear(): void {
    /* 每次打开都重置到默认，防止组件实例跨 if(showTemplate) 开关复用残留状态 */
    this.tplId = 'alpine';
    this.creating = false;
    this.dlPct = 0;
    this.applyTplDefaults(TEMPLATES[0]);
  }

  private tpl(): TplDef {
    for (const t of TEMPLATES) {
      if (t.id === this.tplId) {
        return t;
      }
    }
    return TEMPLATES[0];
  }

  /* 切模板：表单项重置到该模板默认（arch 回到首个可选项） */
  private applyTplDefaults(t: TplDef): void {
    this.arch = t.archs[0];
    this.cpus = t.cpus;
    this.memoryMB = t.memoryMB;
    this.diskGB = t.diskGB;
    this.userIso = '';
    this.nameInput = '';
    this.refreshDerived();
  }

  /* 派生缓存：自动名 + 镜像是否就绪（builtin=内置 ISO 已下载；user=已选自备镜像） */
  private refreshDerived(): void {
    this.namePreview = this.autoName(this.nameBase());
    this.isoOk = this.tpl().iso === 'user'
      ? this.userIso.length > 0
      : pathExists(this.vmDataDir + '/' + builtinIsoFor(this.arch));
  }

  private archLabel(a: VmArch): string {
    return a === 'loongarch64' ? 'loongarch' : a;
  }

  private nameBase(): string {
    const t = this.tpl();
    return t.iso === 'builtin' ? `Alpine ${alpineRelFor(this.arch)} ${this.arch}`
      : `${t.name} ${this.arch}`;
  }

  /* 自动命名：与现有 VM 重名追加「 2」「 3」… 去重 */
  private autoName(base: string): string {
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

  /* 最终名称：填了用输入（trim、原样，同向导不查重）；留空走自动命名 */
  private finalName(): string {
    const input = this.nameInput.trim();
    return input.length > 0 ? input : this.autoName(this.nameBase());
  }

  /* 模板产物 = blankProfile 全默认（与手工向导全默认一致）+ 模板覆盖 + 表单值。
   * cpuModel 按模板：Win10 必须 max（Win8.1+ x64 要 PREFETCHW/POPCNT，qemu64 缺 →
   * 引导 0x5D 蓝屏）；Alpine 留空用 qemu 默认。 */
  private assemble(id: string, name: string): VmProfile {
    const t = this.tpl();
    const p = blankProfile(id);
    p.name = name;
    p.machine.arch = this.arch;
    p.machine.machine = defaultBoard(this.arch);
    p.machine.cpuModel = t.cpuModel;
    p.machine.vga = fitVga(p.machine.machine, t.vga);
    p.runtime.memoryMB = Math.round(this.memoryMB);
    p.runtime.cpus = Math.round(this.cpus);
    p.media.disks = [{ path: `${this.filesDir}/vms/${id}.qcow2`, readonly: false, iface: t.diskIface }];
    if (t.iso === 'builtin') {
      p.media.cdromPaths = [this.vmDataDir + '/' + builtinIsoFor(this.arch)];
    } else if (this.userIso.length > 0) {
      p.media.cdromPaths = [this.userIso];
    }
    /* 有光盘才从光盘引导：-boot d 且无 CD 是 SeaBIOS No bootable device；用户之后
     * 经编辑页/存储页补挂 ISO 的入口都会自动置 true */
    p.media.bootFromCdrom = p.media.cdromPaths.length > 0;
    p.net.model = t.netModel;
    p.machine.rtcLocal = t.rtcLocal;
    p.runtime.audio = t.audio;
    return p;
  }

  private create(): void {
    if (this.creating) {
      return;
    }
    this.creating = true;
    this.dlPct = 0;
    const t = this.tpl();
    const id = newProfileId();
    const p = this.assemble(id, this.finalName());
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
    if (t.iso === 'user') {
      /* Windows：无下载链路。未选镜像也不阻塞创建（档案保留，编辑页补挂） */
      this.creating = false;
      promptAction.showToast({
        message: this.userIso.length > 0
          ? `已创建「${p.name}」`
          : `已创建「${p.name}」；未挂安装镜像，请到编辑页选择 ISO`,
      });
      if (this.onClose) { this.onClose(); }
      return;
    }
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

  /* 自备安装镜像（Windows）：系统选择器选 .iso，原地引用不拷贝（同向导/存储页语义） */
  private pickUserIso(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickIsoPath(ctx).then((p: string) => {
      if (p.length === 0) {
        promptAction.showToast({ message: '未选择文件 / 路径不可读' });
        return;
      }
      this.userIso = p;
      this.refreshDerived();
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
          /* 模板卡片列表单选 */
          ForEach(TEMPLATES, (t: TplDef) => {
            Row({ space: sp2 }) {
              Column({ space: sp1 }) {
                Text(`${t.icon} ${t.name}`).fontSize(tCard).fontWeight(FontWeight.Medium).fontColor(cText)
                Text(t.desc).fontSize(tSub).fontColor(cWeak)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              if (t.iso === 'builtin') {
                Text('内置 ISO').fontSize(tSub).fontColor(cPrimary)
                  .backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              } else {
                Text('自备镜像').fontSize(tSub).fontColor(cSub)
                  .backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
            }
            .width('100%')
            .padding(spCard)
            .backgroundColor(this.tplId === t.id ? cSelBg : cBg)
            .border({ width: bw, color: this.tplId === t.id ? cSel : cBorder })
            .borderRadius(rElem)
            .onClick(() => {
              if (this.tplId === t.id) {
                return;
              }
              this.tplId = t.id;
              this.applyTplDefaults(t);
            })
          }, (t: TplDef) => t.id)

          this.groupHeader('CPU 架构')
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.tpl().archs, (a: VmArch) => {
              Text(this.archLabel(a)).fontSize(tBody)
                .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
                .margin({ right: sp2, bottom: sp2 })
                .fontColor(this.arch === a ? Color.White : cSub)
                .backgroundColor(this.arch === a ? cPrimary : cChip)
                .borderRadius(rBadge)
                .onClick(() => {
                  this.arch = a;
                  this.refreshDerived();
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

          this.groupHeader('安装镜像')
          if (this.tpl().iso === 'builtin') {
            Text(this.isoOk
              ? '内置 Alpine 镜像已就绪，无需下载'
              : `创建后自动下载 Alpine 镜像（约 ${alpineSizeFor(this.arch)}MB，国内镜像站）`)
              .fontSize(tSub).fontColor(cWeak).width('100%')
          } else {
            Row({ space: sp2 }) {
              Button('选择 ISO').focusable(false).fontSize(tBody)
                .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
                .backgroundColor(Color.Transparent).fontColor(cPrimary)
                .onClick(() => this.pickUserIso())
              Text(this.userIso.length > 0 ? this.userIso.substring(this.userIso.lastIndexOf('/') + 1) : '未选择')
                .fontSize(tSub).fontColor(this.userIso.length > 0 ? cSub : cWeak)
                .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            Text('Windows 镜像需自备（不随应用分发）；也可暂不选择，创建后到编辑页补挂')
              .fontSize(tSub).fontColor(cWeak).width('100%')
          }

          Divider().strokeWidth(1).color(cBorder)
          /* 名称可空：placeholder 动态展示自动名兜底（随模板/架构联动）——模板名 ≠
           * 装的系统（Win10 模板常用来装 Win7/8），想装别的就在这里起名 */
          this.groupHeader('名称')
          TextInput({ text: this.nameInput, placeholder: `留空自动命名（${this.namePreview}）` })
            .fontSize(tBody)
            .maxLength(60)
            .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg)
            .padding({ left: inpPadX, right: inpPadX })
            .onChange((v: string) => this.nameInput = v)
          Text(this.tpl().iso === 'builtin'
            ? '其余按推荐默认：网络开启 · 声卡开 · TCG 多线程 · 从光盘引导'
            : '已按 Windows 兼容性自动配置：IDE 磁盘 · 兼容网卡 · 本地时钟 · 声卡默认关')
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
