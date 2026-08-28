// 机器工坊：分步配置向导（架构→板卡/固件→CPU/内存→介质→网络→命名+预览）。
// 新建 / 编辑统一主路径：新建直接进手工向导，无需模板磁贴；VmEdit 保留为高级入口。
// 第⑥步实时 buildArgs 只读预览。
import { promptAction } from '@kit.ArkUI';
import { pathExists } from '../lib/fsutil';
import napiModule from 'libentry.so';
import { common } from '@kit.AbilityKit';
import {
  VmProfile, VmStore, VmArch, VmBoard, VmFirmware, VgaType,
  newProfileId, fitBoard, buildArgs, sharedDir, SCHEMA_VERSION, builtinIsoFor,
  forwardErrors,
} from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import {
  cPrimary, cSub, cWeak, cText, cBorder, cDanger, cBg, cBlock,
  tPage, tCard, tBody, tSub, tLabel, tMono,
  sp1, sp2, sp3, sp4, bw, rBtn, btnH, btnSh, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
}
const napi = napiModule as DiskNapi;

const STEPS: string[] = ['架构', '板卡/固件', 'CPU/内存', '介质', '网络', '命名'];
const ARCH_OPTIONS: VmArch[] = ['x86_64', 'i386', 'aarch64', 'arm', 'loongarch64', 'riscv64'];
const DISK_SIZES: number[] = [1, 2, 4, 8, 16, 32, 64, 128, 256];

@Component
export struct VmWizard {
  onClose: (() => void) | null = null; /* 模态关闭回调（宿主 Stack 置 false）；非响应式，够用 */
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @State step: number = 0;
  @State arch: VmArch = 'x86_64';
  @State vga: VgaType = 'std';
  @State board: VmBoard = 'pc';
  @State cpuModel: string = '';
  @State memoryMB: number = 1024;
  @State cpus: number = 2;
  @State mttcg: boolean = true;
  @State tbSizeText: string = '1024';
  @State diskGB: number = 8;
  @State diskAlloc: string = 'dynamic';
  @State cdromPath: string = '';
  @State bootFromCdrom: boolean = false;
  @State netEnabled: boolean = true;
  @State portForwards: string = '';
  @State sharedFolder: boolean = false;
  @State name: string = '';
  @State cpuModelCollapsed: boolean = true; /* CPU 机型组默认折叠（步骤②） */
  @State tcgCollapsed: boolean = true;      /* TCG 模拟组默认折叠（步骤③） */
  @State ensureIsoLoading: boolean = false; /* 内置 Alpine ISO 下载中 */
  @State isoPct: number = 0;

  aboutToAppear(): void {
    /* 每次打开都重置到默认，防止组件实例跨 if(showWizard) 开关复用残留上一次状态 */
    this.step = 0;
    this.name = '';
    this.arch = 'x86_64';
    this.board = 'pc';
    this.vga = 'std';
    this.cpuModel = '';
    this.memoryMB = 1024;
    this.cpus = 2;
    this.mttcg = true;
    this.tbSizeText = '1024';
    this.diskGB = 8;
    this.diskAlloc = 'dynamic';
    this.cdromPath = '';
    this.bootFromCdrom = false;
    this.netEnabled = true;
    this.portForwards = '';
    this.sharedFolder = false;
    this.cpuModelCollapsed = true;
    this.tcgCollapsed = true;
  }

  /* 「内置 Alpine」按钮：按当前架构确保内置 iso 就绪（缺失则按需下载），完成后挂到光驱 */
  private pickBuiltinIso(): void {
    const name = builtinIsoFor(this.arch);
    if (name.length === 0) {
      promptAction.showToast({ message: '该架构无内置 ISO' });
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    this.ensureIsoLoading = true;
    this.isoPct = 0;
    ensureBuiltinIso(ctx, this.vmDataDir, this.arch, (pct: number) => {
      this.isoPct = pct;
    }).then((ok: boolean) => {
      this.ensureIsoLoading = false;
      if (ok) {
        this.cdromPath = this.vmDataDir + '/' + name;
        this.bootFromCdrom = true;
      } else {
        promptAction.showToast({ message: '内置 ISO 下载失败' });
      }
    });
  }

  private boards(): string[] {
    if (this.arch === 'aarch64') { return ['virt', 'raspi2', 'raspi3']; }
    if (this.arch === 'arm') { return ['virt', 'raspi2', 'raspi3']; }
    if (this.arch === 'loongarch64' || this.arch === 'riscv64') { return ['virt']; }
    return ['pc', 'q35'];
  }

  /* 架构卡片显示名：存储值(loongarch64)较长，UI 主标题用短称 loongarch */
  private archLabel(a: VmArch): string {
    return a === 'loongarch64' ? 'loongarch' : a;
  }

  /* 引导固件由板卡自动选择（向导不暴露）：x86 用 SeaBIOS（OVMF 固件产出后
   * q35 再自动切 UEFI）；virt 按架构固定 EDK2；树莓派 SoC 自带、无外部固件 */
  private firmwareHint(): string {
    const b = fitBoard(this.arch, this.board);
    if (b === 'pc' || b === 'q35') { return '引导固件：SeaBIOS（自动）'; }
    if (b === 'virt') { return '引导固件：EDK2 UEFI（按架构固定）'; }
    return '引导固件：树莓派 SoC 自带';
  }

  /* 保存进 profile 的固件值：跟随板卡推导。OVMF_CODE/VARS 尚未产出，x86 一律
   * SeaBIOS；arm 系该字段 buildArgs 未消费（virt 强制 -bios edk2，raspi 靠 SoC），
   * 填 seabios 仅为占位。 */
  private autoFirmware(): VmFirmware {
    return 'seabios';
  }

  /* ---- 输入约束：各步即时校验（红字提示 + 禁用下一步/完成），不再等运行时报错 ---- */

  /* 该架构的常用 CPU 机型预设（TCG 下 host 受支持性差，不放入预设） */
  private cpuPresets(): string[] {
    if (this.arch === 'x86_64' || this.arch === 'i386') { return ['max', 'qemu64']; }
    if (this.arch === 'aarch64') { return ['max', 'cortex-a57', 'cortex-a72', 'cortex-a53']; }
    if (this.arch === 'arm') { return ['max', 'cortex-a7', 'cortex-a15']; }
    if (this.arch === 'loongarch64') { return ['max', 'la464']; }
    return ['max'];
  }

  private cpuModelError(): string {
    const m = this.cpuModel.trim();
    if (m.length === 0) { return ''; }
    return /^[A-Za-z0-9._-]+$/.test(m) ? '' : 'CPU 机型只允许字母/数字/点/下划线/连字符（不含空格分隔符）';
  }

  /* 第 step 步的内容校验：返回错误描述（'' = 通过） */
  private calcError(step: number): string {
    if (step === 1) {
      return this.cpuModelError();
    }
    if (step === 2) {
      const tb = Number(this.tbSizeText);
      if (!Number.isInteger(tb) || tb < 512 || tb > 8192) {
        return `tb-size 需为 512-8192 的整数（MB），当前「${this.tbSizeText.trim()}」`;
      }
    }
    if (step === 3) {
      if (this.cdromPath.trim().length > 0 && !pathExists(this.cdromPath.trim())) {
        return 'ISO 路径不存在';
      }
    }
    if (step === 4 && this.netEnabled && this.portForwards.trim().length > 0) {
      const errs = forwardErrors(this.portForwards);
      if (errs.length > 0) { return '端口转发：' + errs.join('；'); }
    }
    if (step === 5) {
      if (this.name.trim().length === 0) { return '需要指定虚拟机名称'; }
    }
    return '';
  }

  private stepError(): string {
    return this.calcError(this.step);
  }

  private fullError(): string {
    for (let i = 0; i < STEPS.length; i++) {
      const e = this.calcError(i);
      if (e.length > 0) { return e; }
    }
    return '';
  }

  /* 当前步红字提示（stepError 非空时渲染） */
  @Builder
  stepErrorMsg() {
    if (this.stepError().length > 0) {
      Text(this.stepError()).fontSize(tSub).fontColor(cDanger).width('100%')
    }
  }

  /* 分组标题 + 分割线（组头）：灰字在左，细线延伸至右；组间留距 */
  @Builder
  groupHeader(label: string) {
    Row({ space: 8 }) {
      Text(label).fontSize(tLabel).fontColor(cSub)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp1 })
  }

  private boardName(b: string): string {
    if (b === 'virt') return 'virt (通用)';
    if (b === 'raspi2') return 'raspi2b (树莓派2B)';
    if (b === 'raspi3') return 'raspi3b (树莓派3B)';
    if (b === 'q35') return 'q35 (现代PCIe)';
    return 'pc (兼容最好)';
  }

  /* 从当前步装配一份 VmProfile（不落盘、不建盘；用于预览/完成） */
  private assemble(id: string): VmProfile {
    /* 系统盘必配：保存时建在标准位置 */
    const diskPath = `${this.filesDir}/vms/${id}.qcow2`;
    const tbSize = Number(this.tbSizeText);
    const p: VmProfile = {
      schemaVersion: SCHEMA_VERSION,
      id: id,
      name: this.name.trim().length > 0 ? this.name.trim() : '未命名',
      machine: {
        arch: this.arch,
        vga: this.vga,
        machine: fitBoard(this.arch, this.board),
        firmware: this.autoFirmware(),
        cpuModel: this.cpuModel.trim(),
      },
      runtime: {
        memoryMB: Math.round(this.memoryMB),
        cpus: Math.round(this.cpus),
        mttcg: this.mttcg,
        tbSize: Number.isInteger(tbSize) && tbSize > 0 ? tbSize : 1024,
      },
      media: {
        diskPath: diskPath,
        cdromPath: this.cdromPath.trim(),
        bootFromCdrom: this.bootFromCdrom,
      },
      net: {
        enabled: this.netEnabled,
        portForwards: this.portForwards.trim(),
        sharedFolder: this.sharedFolder,
      },
      temporarySession: false,
      extraArgs: '',
    };
    return p;
  }

  private finish(): void {
    /* 全量兜底校验（按钮启用已前置，此处防跳步/异常路径） */
    if (this.fullError().length > 0) {
      promptAction.showToast({ message: '存在无效设置，请按红字提示修正' });
      return;
    }
    const id = newProfileId();
    const p = this.assemble(id);
    if (p.media.diskPath.length > 0) {
      if (!pathExists(p.media.diskPath)) {
        const ret = napi.createDisk(p.media.diskPath, Math.round(this.diskGB * 1024), this.diskAlloc);
        if (ret !== 0) {
          promptAction.showToast({ message: '创建磁盘失败' });
          return;
        }
      }
    }
    new VmStore(this.filesDir).save(p);
    promptAction.showToast({ message: `已保存「${p.name}」` });
    if (this.onClose) { this.onClose(); }
  }

  @Builder
  stepHeader() {
    Row() {
      ForEach(STEPS, (s: string, i: number) => {
        Row({ space: 6 }) {
          Text(String(i + 1)).fontSize(tMono)
            .fontColor(this.step === i ? Color.White : cSub)
            .width(20).height(20).textAlign(TextAlign.Center)
            .backgroundColor(this.step === i ? cPrimary : Color.Transparent)
            .border({ width: bw, color: this.step === i ? cPrimary : cBorder })
            .borderRadius(10)
          Text(s).fontSize(tMono).fontColor(this.step === i ? cPrimary : cWeak)
        }
        .layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => this.step = i)
      }, (s: string) => s)
    }
    .width('100%').padding({ left: sp4, right: sp4 })
  }

  @Builder
  stepArch() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        ForEach(ARCH_OPTIONS, (a: VmArch) => {
          Column() {
            Text(this.archLabel(a)).fontSize(tCard).fontWeight(FontWeight.Medium)
              .fontColor(this.arch === a ? Color.White : cText)
            if (a === 'aarch64') { Text('ARM 64 位').fontSize(tSub).fontColor(this.arch === a ? Color.White : cWeak) }
            if (a === 'arm') { Text('ARM 32 位').fontSize(tSub).fontColor(this.arch === a ? Color.White : cWeak) }
            if (a === 'x86_64') { Text('64 位').fontSize(tSub).fontColor(this.arch === a ? Color.White : cWeak) }
            if (a === 'i386') { Text('32 位').fontSize(tSub).fontColor(this.arch === a ? Color.White : cWeak) }
            if (a === 'loongarch64') { Text('64 位').fontSize(tSub).fontColor(this.arch === a ? Color.White : cWeak) }
            if (a === 'riscv64') { Text('RISC-V').fontSize(tSub).fontColor(this.arch === a ? Color.White : cWeak) }
          }
          .layoutWeight(1)
          .padding(12)
          .backgroundColor(this.arch === a ? cPrimary : Color.White)
          .borderRadius(8)
          .onClick(() => {
            this.arch = a;
            this.board = fitBoard(a, this.board);
          })
        }, (a: VmArch) => a)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
  }

  @Builder
  stepBoard() {
    Column({ space: 12 }) {
      this.groupHeader('机器类型')
      Row({ space: 10 }) {
        ForEach(this.boards(), (b: string) => {
          Column() {
            Text(b).fontSize(tCard).fontWeight(FontWeight.Medium)
              .fontColor(this.board === b ? Color.White : cText)
            Text(this.boardName(b)).fontSize(tSub).fontColor(this.board === b ? Color.White : cWeak)
          }
          .layoutWeight(1)
          .padding(12)
          .backgroundColor(this.board === b ? cPrimary : Color.White)
          .borderRadius(8)
          .onClick(() => this.board = b as VmBoard)
        }, (b: string) => b)
      }
      .width('100%')

      Text(this.firmwareHint()).fontSize(tSub).fontColor(cWeak).width('100%')

      /* CPU 机型组：默认折叠，点组头展开/收起 */
      /* CPU 机型组：默认折叠，点组头展开/收起。
       * 标题+提示合成同一 Text 的 Span（单行盒排版），避免两个独立 Text
       * 因符号字符(▸)字体度量不同而垂直错位 */
      Row({ space: 8 }) {
        Text() {
          Span('CPU 机型').fontColor(cSub)
          Span(this.cpuModelCollapsed ? ' ▸ 展开' : ' ▾ 收起').fontColor(cWeak).fontSize(tSub)
        }
        .fontSize(tLabel)
        Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: sp2, bottom: sp1 })
      .onClick(() => this.cpuModelCollapsed = !this.cpuModelCollapsed)

      if (!this.cpuModelCollapsed) {
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          Text('自动')
            .fontSize(tBody)
            .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
            .margin({ right: sp2, bottom: sp2 })
            .fontColor(this.cpuModel.trim().length === 0 ? Color.White : cText)
            .backgroundColor(this.cpuModel.trim().length === 0 ? cPrimary : cBg)
            .borderRadius(rBtn)
            .onClick(() => this.cpuModel = '')
          ForEach(this.cpuPresets(), (m: string) => {
            Text(m)
              .fontSize(tBody)
              .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              .margin({ right: sp2, bottom: sp2 })
              .fontColor(this.cpuModel.trim() === m ? Color.White : cText)
              .backgroundColor(this.cpuModel.trim() === m ? cPrimary : cBg)
              .borderRadius(rBtn)
              .onClick(() => this.cpuModel = m)
          }, (m: string) => m)
        }
        .width('100%')

        TextInput({ text: this.cpuModel, placeholder: '自定义（预设外的机型）' })
          .fontSize(tBody)
          .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
          .onChange((v: string) => this.cpuModel = v)

        Text('留空 = 自动；ARM/ARM64/龙芯/RISC-V 默认 max，x86 用板卡默认').fontSize(tSub).fontColor(cWeak)
      }

      this.stepErrorMsg()

    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
  }

  @Builder
  stepCpuMem() {
    Column({ space: 12 }) {
      this.groupHeader('内存与核数')
      Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(tLabel)
      Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
        .onChange((v: number) => this.memoryMB = v)
      Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(tLabel)
      Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
        .onChange((v: number) => this.cpus = v)
      /* TCG 模拟组：默认折叠，点组头展开/收起 */
      Row({ space: 8 }) {
        Text() {
          Span('TCG 模拟').fontColor(cSub)
          Span(this.tcgCollapsed ? ' ▸ 展开' : ' ▾ 收起').fontColor(cWeak).fontSize(tSub)
        }
        .fontSize(tLabel)
        Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: sp2, bottom: sp1 })
      .onClick(() => this.tcgCollapsed = !this.tcgCollapsed)

      if (!this.tcgCollapsed) {
        Row() {
          Text('TCG 多线程 (MTTCG)').fontSize(tLabel).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.mttcg })
            .onChange((v: boolean) => this.mttcg = v)
        }
        Row() {
          Text('tb-size').fontSize(tLabel).width(90)
          TextInput({ text: this.tbSizeText })
            .layoutWeight(1)
            .fontSize(tBody)
            .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
            .onChange((v: string) => this.tbSizeText = v)
        }
        Text('有效范围 512-8192 MB（默认 1024）').fontSize(tSub).fontColor(cWeak)
      }

      this.stepErrorMsg()
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
  }

  @Builder
  stepMedia() {
    Column({ space: 12 }) {
      /* 系统盘必配（无开关）：每台 VM 都带系统盘，保存时建在标准位置 */
      this.groupHeader('系统盘')
      Text(`磁盘大小: ${Math.round(this.diskGB)}GB`).fontSize(tLabel)
      Slider({ value: Math.max(0, DISK_SIZES.indexOf(this.diskGB)),
        min: 0, max: DISK_SIZES.length - 1, step: 1 })
        .onChange((v: number) => this.diskGB = DISK_SIZES[Math.round(v)])
      Row({ space: sp3 }) {
        Row({ space: 6 }) {
          Radio({ value: 'dynamic', group: 'diskAlloc' })
            .checked(this.diskAlloc === 'dynamic')
            .onChange((isChecked: boolean) => {
              if (isChecked) { this.diskAlloc = 'dynamic'; }
            })
          Text('动态分配').fontSize(tBody).fontColor(cText)
        }
        Row({ space: 6 }) {
          Radio({ value: 'fixed', group: 'diskAlloc' })
            .checked(this.diskAlloc === 'fixed')
            .onChange((isChecked: boolean) => {
              if (isChecked) { this.diskAlloc = 'fixed'; }
            })
          Text('固定大小').fontSize(tBody).fontColor(cText)
        }
      }
      Text('动态分配：用到多少占多少；固定大小：创建时即占满该容量').fontSize(tSub).fontColor(cWeak)

      this.groupHeader('光盘')
      Row() {
        Text(this.cdromPath ? this.baseName(this.cdromPath) : '无')
          .fontSize(tSub).fontColor(cSub).layoutWeight(1)
        if (this.cdromPath.length > 0) {
          Button('移除').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .onClick(() => this.cdromPath = '')
        }
      }
      if (this.cdromPath.length === 0) {
        Row({ space: 8 }) {
          TextInput({ placeholder: 'ISO 完整路径', text: this.cdromPath })
            .layoutWeight(1).fontSize(tBody)
            .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
            .onChange((v: string) => this.cdromPath = v)
          Button(this.ensureIsoLoading ? `下载 ${this.isoPct}%` : `内置 Alpine (${this.archLabel(this.arch)})`)
            .focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .enabled(!this.ensureIsoLoading)
            .onClick(() => this.pickBuiltinIso())
        }
      }
      Row() {
        Text('从光盘启动').fontSize(tLabel).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
          .onChange((v: boolean) => this.bootFromCdrom = v)
      }

      this.stepErrorMsg()
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
  }

  @Builder
  stepNet() {
    Column({ space: 12 }) {
      this.groupHeader('网络')
      Row() {
        Text('启用网络').fontSize(tLabel).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
          .onChange((v: boolean) => this.netEnabled = v)
      }
      if (this.netEnabled) {
        Text('端口转发').fontSize(tLabel)
        TextInput({ placeholder: '如 2222:22,8080:80', text: this.portForwards })
          .fontSize(tBody)
          .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
          .onChange((v: string) => this.portForwards = v)
        Text('宿主端口:客机端口，逗号分隔，如 2222:22,8080:80').fontSize(tSub).fontColor(cWeak)
        Row() {
          Text('9p 共享目录').fontSize(tLabel).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.sharedFolder })
            .onChange((v: boolean) => this.sharedFolder = v)
        }
        if (this.sharedFolder) {
          Text('挂载宿主 Download/ 到客机 /shared（9p）').fontSize(tSub).fontColor(cWeak)
        }
        this.stepErrorMsg()
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
  }

  @Builder
  stepPreview() {
    Column({ space: 12 }) {
      Text('名称').fontSize(tLabel).width(72)
      TextInput({ text: this.name, placeholder: '必填' })
        .fontSize(tBody)
        .maxLength(60)
        .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
        .onChange((v: string) => this.name = v)
      Text('1-60 字符，保存后仍可在列表编辑').fontSize(tSub).fontColor(cWeak)

      this.stepErrorMsg()
      Row() {
        Text('qemu 参数预览').fontSize(tSub).fontColor(cSub)
        Blank()
      }
      Text(buildArgs(this.assemble(newProfileId()), this.vmDataDir, sharedDir(this.filesDir)).join(' '))
        .fontSize(tMono)
        .fontColor(cText)
        .padding(8)
        .width('100%')
        .backgroundColor(cBlock)
        .borderRadius(6)
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  build() {
    Column() {
      Column() {
        Row({ space: sp2 }) {
            Button('上一步').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent)
              .fontColor(this.step > 0 ? cPrimary : cWeak)
              .enabled(this.step > 0)
              .onClick(() => { if (this.step > 0) { this.step--; } })
            Blank()
            Text('创建虚拟机').fontSize(tPage).fontWeight(FontWeight.Medium)
            Blank()
            Button('关闭').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent)
              .fontColor(cSub)
              .onClick(() => { if (this.onClose) this.onClose(); })
          }
          .width('100%')
          .padding({ left: sp4, right: sp4, top: sp2, bottom: sp2 })

          this.stepHeader()

          Scroll() {
            Column() {
              if (this.step === 0) { this.stepArch() }
              else if (this.step === 1) { this.stepBoard() }
              else if (this.step === 2) { this.stepCpuMem() }
              else if (this.step === 3) { this.stepMedia() }
              else if (this.step === 4) { this.stepNet() }
              else if (this.step === 5) { this.stepPreview() }
            }
            .width('100%')
            .padding({ bottom: 24 })
          }
          .layoutWeight(1)
          .align(Alignment.Top)

          /* 内容下方：下一步 / 完成（固定不随滚动） */
          Row() {
            Blank()
            Button(this.step === STEPS.length - 1 ? '完成' : '下一步')
              .focusable(false).fontSize(tBody)
              .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
              .backgroundColor(Color.Transparent)
              .fontColor(cPrimary)
              /* 下一步只卡当前步；完成卡全部步（防跳步改坏其他步后直接提交） */
              .enabled(this.step === STEPS.length - 1
                ? this.fullError().length === 0
                : this.stepError().length === 0)
              .onClick(() => {
                if (this.step < STEPS.length - 1) {
                  this.step++;
                } else {
                  this.finish();
                }
              })
            Blank()
          }
          .width('100%')
          .padding({ left: sp4, right: sp4, top: sp2, bottom: sp2 })
          .backgroundColor(cBg)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cBg)
  }
}
