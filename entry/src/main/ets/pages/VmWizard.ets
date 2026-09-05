// 机器工坊：分步配置向导（架构→板卡/固件→CPU/内存→介质→网络→命名+预览）。
// 新建 / 编辑统一主路径：新建直接进手工向导，无需模板磁贴；VmEdit 保留为高级入口。
// 第⑥步实时 buildArgs 只读预览。
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pathExists, isoReadable, copyFileWithProgress, fileSizeOf, readAsciiAt } from '../lib/fsutil';
import napiModule from 'libentry.so';
import { common } from '@kit.AbilityKit';
import {
  VmProfile, VmStore, VmArch, VmBoard, VmFirmware, VgaType,
  newProfileId, fitBoard, buildArgs, sharedDir, SCHEMA_VERSION, builtinIsoFor,
  forwardErrors,
} from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pickIsoPath, pickFilePath } from '../lib/isoPick';
import {
  cPrimary, cSub, cWeak, cText, cBorder, cDanger, cBg, cBlock, cChip,
  tPage, tCard, tBody, tSub, tLabel, tMono,
  sp1, sp2, sp3, sp4, sp8, spCard, bw, rElem, rBtn, rBadge, btnH, btnSh, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
  diskInfo: (path: string) => string;
}
const napi = napiModule as DiskNapi;

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

const STEPS: string[] = ['架构', '板卡/固件', 'CPU/内存', '介质', '网络', '命名'];
const ARCH_OPTIONS: VmArch[] = ['x86_64', 'i386', 'aarch64', 'arm', 'loongarch64', 'riscv64'];
const DISK_SIZES: number[] = [1, 2, 4, 8, 16, 32, 64, 128, 256];
/* 可导入的系统盘镜像后缀（.img/.raw 按 raw 处理，见 buildArgs 扩展名判定） */
const DISK_SUFFIXES: string[] = ['.qcow2', '.img', '.raw'];

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
  /* 系统盘来源：new=新建空白盘（大小+分配方式）；import=导入现有镜像，创建时复制进 vms/ */
  @State diskSource: string = 'new';
  @State importDiskSrc: string = '';    /* 已选镜像的真实路径（创建时复制，profile 不存它） */
  @State importDiskMeta: string = '';   /* diskInfo 探测结果摘要（格式 · 虚拟大小） */
  /* 直接内核引导（可选高级组）：选了就在创建时复制进 vms/ 并生成 -kernel/-initrd/-append */
  @State kernelSrc: string = '';
  @State initrdSrc: string = '';
  @State kernelAppend: string = '';
  @State kernelCollapsed: boolean = true;
  @State copying: boolean = false;      /* finish 的镜像/内核复制进行中（禁用完成按钮） */
  @State copyPct: number = 0;
  @State cdromPaths: string[] = [];
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
    this.diskSource = 'new';
    this.importDiskSrc = '';
    this.importDiskMeta = '';
    this.kernelSrc = '';
    this.initrdSrc = '';
    this.kernelAppend = '';
    this.kernelCollapsed = true;
    this.copying = false;
    this.copyPct = 0;
    this.cdromPaths = [];
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
        this.addIso(this.vmDataDir + '/' + name);
        this.bootFromCdrom = true;
      } else {
        promptAction.showToast({ message: '内置 ISO 下载失败' });
      }
    });
  }

  /* 「选择文件」按钮：拉起系统选择器选 .iso，解析成真实路径后追加到 ISO 列表并默认从光盘启动。
   * 原地引用（不拷贝）；路径不可读/取消则回退为「未选择文件」。 */
  private pickLocalIso(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickIsoPath(ctx).then((p: string) => {
      if (p.length === 0) {
        promptAction.showToast({ message: '未选择文件 / 路径不可读' });
        return;
      }
      this.addIso(p);
      this.bootFromCdrom = true;
    });
  }

  /* 追加一张 ISO（去重；列表顺序 = 启动顺序，第一张为启动盘候选） */
  private addIso(p: string): void {
    if (p.length === 0) { return; }
    if (this.cdromPaths.indexOf(p) < 0) {
      this.cdromPaths.push(p);
    }
  }
  private removeIso(idx: number): void {
    this.cdromPaths.splice(idx, 1);
  }

  /* 「导入镜像」的选择：只暂存真实路径（importDiskSrc），复制动作在 finish
   * （按新 id 复制到 vms/ 标准位置后 profile 才引用它）。顺带用 diskInfo 探测
   * 格式/虚拟大小做展示与格式校验（qemu-img 不认的判无效）。 */
  private pickImportDisk(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickFilePath(ctx, DISK_SUFFIXES).then((p: string) => {
      if (p.length === 0) {
        promptAction.showToast({ message: '未选择文件 / 路径不可读' });
        return;
      }
      this.importDiskSrc = p;
      this.importDiskMeta = '';
      const s = napi.diskInfo(p);
      if (s.length > 0) {
        try {
          /* ArkTS 禁 any/unknown：Record 字典式解析 + typeof 窄化（同 VmEdit.readDiskMeta） */
          const j = JSON.parse(s) as Record<string, number | string>;
          const fmt = typeof j['format'] === 'string' ? j['format'] as string : '?';
          const vs = typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0;
          this.importDiskMeta = `${fmt} · 虚拟 ${(vs / (1024 * 1024 * 1024)).toFixed(1)}G`;
        } catch {
          this.importDiskMeta = '';
        }
      }
    });
  }

  /* 内核/initrd 选择：内核无固定扩展名（vmlinuz/bzImage/Image…），不过滤后缀 */
  private pickKernel(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickFilePath(ctx, []).then((p: string) => {
      if (p.length > 0) { this.kernelSrc = p; }
    });
  }

  private pickInitrd(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickFilePath(ctx, []).then((p: string) => {
      if (p.length > 0) { this.initrdSrc = p; }
    });
  }

  /* 导入镜像的目标扩展名（小写）：.qcow2 保持（qcow2 格式判定靠它），其余原样保留
   *（picker 已限 .qcow2/.img/.raw，非 qcow2 后缀 buildArgs 一律按 raw） */
  private importDiskExt(): string {
    const s = this.importDiskSrc.toLowerCase();
    const i = s.lastIndexOf('.');
    return i >= 0 ? s.substring(i) : '.img';
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
      if (this.diskSource === 'import') {
        if (this.importDiskSrc.length === 0 || !isoReadable(this.importDiskSrc)) {
          return '导入模式需先选择可读的镜像文件';
        }
        if (this.importDiskMeta.length === 0) {
          return '镜像无法识别（需 qcow2/raw 格式）';
        }
      }
      if (this.kernelSrc.length > 0 && !isoReadable(this.kernelSrc)) {
        return '内核文件不可读或不存在';
      }
      if (this.initrdSrc.length > 0 && !isoReadable(this.initrdSrc)) {
        return 'initrd 文件不可读或不存在';
      }
      if (this.bootFromCdrom && this.cdromPaths.length === 0) {
        return '从光盘启动需先指定 ISO';
      }
      for (const p of this.cdromPaths) {
        if (!isoReadable(p)) {
          return 'ISO 不可读或不存在';
        }
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
    Row({ space: sp8 }) {
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

  /* 从当前步装配一份 VmProfile（不落盘、不建盘；用于预览/完成）。
   * 导入/内核文件的路径在这里就定为 vms/ 内的复制目标路径——finish 按它复制，
   * profile 引用的始终是复制后的自有资产。 */
  private assemble(id: string): VmProfile {
    const diskPath = this.diskSource === 'import'
      ? `${this.filesDir}/vms/${id}${this.importDiskExt()}`
      : `${this.filesDir}/vms/${id}.qcow2`;
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
        cdromPaths: this.cdromPaths,
        bootFromCdrom: this.bootFromCdrom,
        kernelPath: this.kernelSrc.length > 0 ? `${this.filesDir}/vms/${id}.kernel` : '',
        initrdPath: this.initrdSrc.length > 0 ? `${this.filesDir}/vms/${id}.initrd` : '',
        kernelAppend: this.kernelAppend.trim(),
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
    if (this.copying) {
      return;
    }
    const id = newProfileId();
    const p = this.assemble(id);
    /* 介质落盘：import=复制所选镜像为系统盘（大文件异步分块+进度）；
     * kernel/initrd=复制进 vms/；new=新建空白 qcow2。全部就绪后才 save。 */
    this.copying = true;
    this.copyPct = 0;
    this.prepareMedia(p)
      .then((ok: boolean) => {
        this.copying = false;
        if (!ok) {
          return; /* 各步骤已 toast 具体原因 */
        }
        new VmStore(this.filesDir).save(p);
        promptAction.showToast({ message: `已保存「${p.name}」` });
        if (this.onClose) { this.onClose(); }
      });
  }

  /* finish 的介质准备：按来源把系统盘/内核/initrd 备齐，全部成功才 resolve(true) */
  private prepareMedia(p: VmProfile): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const doKernel = (): void => {
        if (this.kernelSrc.length === 0) {
          resolve(true);
          return;
        }
        copyFileWithProgress(this.kernelSrc, p.media.kernelPath, (pct: number) => {
          this.copyPct = pct;
        }).then((ok: boolean) => {
          if (!ok) {
            promptAction.showToast({ message: '复制内核失败' });
            resolve(false);
            return;
          }
          /* 诊断：复制后核对大小 + 内核头 magic，防止「复制成功但内容不对」留给
           * qemu loader 才报。magic 按架构核对 ASCII 签名：x86 bzImage=HdrS@0x202、
           * arm64 Image=ARM\x64@0x38（0x64 恰是 ASCII 'd'）；arm32 zImage/loongarch/
           * riscv 无可查的 ASCII magic，只核大小。 */
          const srcSize = fileSizeOf(this.kernelSrc);
          const dstSize = fileSizeOf(p.media.kernelPath);
          let magic = '';
          let magicOk = true;
          if (this.arch === 'x86_64' || this.arch === 'i386') {
            magic = readAsciiAt(p.media.kernelPath, 0x202, 4);
            magicOk = magic === 'HdrS';
          } else if (this.arch === 'aarch64') {
            magic = readAsciiAt(p.media.kernelPath, 0x38, 4);
            magicOk = magic === 'ARMd';
          }
          hilog.info(DOMAIN, TAG, 'kernel copy src=%{public}s (%{public}d) → dst %{public}d bytes, magic=%{public}s',
            this.kernelSrc, srcSize, dstSize, magic);
          if (srcSize !== dstSize || !magicOk) {
            promptAction.showToast({ message: `内核文件校验失败（大小 ${dstSize}/${srcSize}，magic=${magic}）` });
            resolve(false);
            return;
          }
          if (this.initrdSrc.length === 0) {
            resolve(true);
            return;
          }
          copyFileWithProgress(this.initrdSrc, p.media.initrdPath, (pct: number) => {
            this.copyPct = pct;
          }).then((ok2: boolean) => {
            if (!ok2) { promptAction.showToast({ message: '复制 initrd 失败' }); }
            hilog.info(DOMAIN, TAG, 'initrd copy src=%{public}s (%{public}d) → dst %{public}d bytes',
              this.initrdSrc, fileSizeOf(this.initrdSrc), fileSizeOf(p.media.initrdPath));
            resolve(ok2);
          });
        });
      };
      const doDisk = (): void => {
        if (this.diskSource === 'import') {
          copyFileWithProgress(this.importDiskSrc, p.media.diskPath, (pct: number) => {
            this.copyPct = pct;
          }).then((ok: boolean) => {
            if (!ok) {
              promptAction.showToast({ message: '复制系统盘镜像失败' });
              resolve(false);
              return;
            }
            hilog.info(DOMAIN, TAG, 'disk copy src=%{public}s (%{public}d) → dst %{public}d bytes',
              this.importDiskSrc, fileSizeOf(this.importDiskSrc), fileSizeOf(p.media.diskPath));
            doKernel();
          });
          return;
        }
        if (!pathExists(p.media.diskPath)) {
          const ret = napi.createDisk(p.media.diskPath, Math.round(this.diskGB * 1024), this.diskAlloc);
          if (ret !== 0) {
            promptAction.showToast({ message: '创建磁盘失败' });
            resolve(false);
            return;
          }
        }
        doKernel();
      };
      doDisk();
    });
  }

  @Builder
  stepHeader() {
    Row() {
      ForEach(STEPS, (s: string, i: number) => {
        Row({ space: sp1 }) {
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
    Column({ space: spCard }) {
      Row({ space: sp2 }) {
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
          .padding(spCard)
          .backgroundColor(this.arch === a ? cPrimary : Color.White)
          .borderRadius(rElem)
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
    Column({ space: spCard }) {
      this.groupHeader('机器类型')
      Row({ space: sp2 }) {
        ForEach(this.boards(), (b: string) => {
          Column() {
            Text(b).fontSize(tCard).fontWeight(FontWeight.Medium)
              .fontColor(this.board === b ? Color.White : cText)
            Text(this.boardName(b)).fontSize(tSub).fontColor(this.board === b ? Color.White : cWeak)
          }
          .layoutWeight(1)
          .padding(spCard)
          .backgroundColor(this.board === b ? cPrimary : Color.White)
          .borderRadius(rElem)
          .onClick(() => { this.board = b as VmBoard; })
        }, (b: string) => b)
      }
      .width('100%')

      Text(this.firmwareHint()).fontSize(tSub).fontColor(cWeak).width('100%')

      /* CPU 机型组：默认折叠，点组头展开/收起 */
      /* CPU 机型组：默认折叠，点组头展开/收起。
       * 标题+提示合成同一 Text 的 Span（单行盒排版），避免两个独立 Text
       * 因符号字符(▸)字体度量不同而垂直错位 */
      Row({ space: sp8 }) {
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
    Column({ space: spCard }) {
      this.groupHeader('内存与核数')
      Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(tLabel)
      Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
        .onChange((v: number) => this.memoryMB = v)
      Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(tLabel)
      Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
        .onChange((v: number) => this.cpus = v)
      /* TCG 模拟组：默认折叠，点组头展开/收起 */
      Row({ space: sp8 }) {
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
    Column({ space: spCard }) {
      /* 系统盘必配（无开关）：新建空白盘 或 导入现有镜像（创建时复制进 vms/）。
       * 来源/分配方式用分段胶囊（与概览 chips 同款），不用 Radio——圆点+对勾太嘈杂 */
      this.groupHeader('系统盘')
      Row({ space: sp2 }) {
        Text('新建空白盘').fontSize(tBody)
          .fontColor(this.diskSource === 'new' ? Color.White : cSub)
          .backgroundColor(this.diskSource === 'new' ? cPrimary : cChip)
          .borderRadius(rBadge)
          .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
          .onClick(() => { this.diskSource = 'new' })
        Text('导入现有镜像').fontSize(tBody)
          .fontColor(this.diskSource === 'import' ? Color.White : cSub)
          .backgroundColor(this.diskSource === 'import' ? cPrimary : cChip)
          .borderRadius(rBadge)
          .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
          .onClick(() => { this.diskSource = 'import' })
      }
      if (this.diskSource === 'new') {
        Text(`磁盘大小: ${Math.round(this.diskGB)}GB`).fontSize(tLabel)
        Slider({ value: Math.max(0, DISK_SIZES.indexOf(this.diskGB)),
          min: 0, max: DISK_SIZES.length - 1, step: 1 })
          .onChange((v: number) => this.diskGB = DISK_SIZES[Math.round(v)])
        Row({ space: sp2 }) {
          Text('动态分配').fontSize(tBody)
            .fontColor(this.diskAlloc === 'dynamic' ? Color.White : cSub)
            .backgroundColor(this.diskAlloc === 'dynamic' ? cPrimary : cChip)
            .borderRadius(rBadge)
            .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
            .onClick(() => { this.diskAlloc = 'dynamic' })
          Text('固定大小').fontSize(tBody)
            .fontColor(this.diskAlloc === 'fixed' ? Color.White : cSub)
            .backgroundColor(this.diskAlloc === 'fixed' ? cPrimary : cChip)
            .borderRadius(rBadge)
            .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
            .onClick(() => { this.diskAlloc = 'fixed' })
          Text('动态：用到多少占多少；固定：创建即占满')
            .fontSize(tSub).fontColor(cWeak).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      } else {
        Row({ space: sp2 }) {
          Button('选择镜像').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cPrimary)
            .onClick(() => this.pickImportDisk())
          Text(this.importDiskSrc.length > 0
            ? this.baseName(this.importDiskSrc) + (this.importDiskMeta.length > 0 ? `（${this.importDiskMeta}）` : '')
            : '未选择（支持 .qcow2/.img/.raw）')
            .fontSize(tSub).fontColor(this.importDiskSrc.length > 0 ? cSub : cWeak)
            .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text('创建时复制进虚拟机目录作为系统盘；之后与源文件无关').fontSize(tSub).fontColor(cWeak)
      }

      /* 直接内核引导：默认折叠的高级组；选了 kernel 即绕过固件引导（-kernel） */
      Row({ space: sp8 }) {
        Text() {
          Span('内核引导').fontColor(cSub)
          Span(this.kernelCollapsed ? ' ▸ 展开' : ' ▾ 收起').fontColor(cWeak).fontSize(tSub)
        }
        .fontSize(tLabel)
        Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: sp2, bottom: sp1 })
      .onClick(() => this.kernelCollapsed = !this.kernelCollapsed)

      if (!this.kernelCollapsed) {
        Row({ space: sp2 }) {
          Button('选择内核').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cPrimary)
            .onClick(() => this.pickKernel())
          Text(this.kernelSrc.length > 0 ? this.baseName(this.kernelSrc) : '未选择（vmlinuz/bzImage/Image…）')
            .fontSize(tSub).fontColor(this.kernelSrc.length > 0 ? cSub : cWeak)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.kernelSrc.length > 0) {
            Button('清除').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cDanger)
              .onClick(() => { this.kernelSrc = ''; })
          }
        }
        Row({ space: sp2 }) {
          Button('选择 initrd').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cPrimary)
            .onClick(() => this.pickInitrd())
          Text(this.initrdSrc.length > 0 ? this.baseName(this.initrdSrc) : '可选（initramfs/initrd.img…）')
            .fontSize(tSub).fontColor(this.initrdSrc.length > 0 ? cSub : cWeak)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.initrdSrc.length > 0) {
            Button('清除').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cDanger)
              .onClick(() => { this.initrdSrc = ''; })
          }
        }
        TextInput({ text: this.kernelAppend, placeholder: '内核参数（可选），如 console=tty0 console=ttyS0 root=/dev/vda' })
          .fontSize(tBody)
          .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
          .onChange((v: string) => this.kernelAppend = v)
        Text('指定内核后由 qemu 直接装载引导（-kernel），绕过 BIOS/UEFI 流程；内核与 initrd 在创建时复制进虚拟机目录')
          .fontSize(tSub).fontColor(cWeak).width('100%')
      }

      this.groupHeader('光盘')
      /* 多 ISO 有序列表：第一张为启动盘候选（从光盘启动时）；每张一行可独立移除 */
      if (this.cdromPaths.length > 0) {
        ForEach(this.cdromPaths, (p: string, idx: number) => {
          Row({ space: sp2 }) {
            Text(idx === 0 ? `${this.baseName(p)}（启动盘）` : this.baseName(p))
              .fontSize(tSub).fontColor(idx === 0 ? cPrimary : cSub).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('移除').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .onClick(() => this.removeIso(idx))
          }
          .width('100%')
        }, (p: string, idx: number) => `${idx}:${p}`)
      } else {
        Text('无').fontSize(tSub).fontColor(cSub).width('100%')
      }
      Row({ space: sp2 }) {
        Button('添加 ISO').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .backgroundColor(Color.Transparent).fontColor(cPrimary)
          .onClick(() => this.pickLocalIso())
        Button(this.ensureIsoLoading ? `内置下载 ${this.isoPct}%` : `内置 Alpine (${this.archLabel(this.arch)})`)
          .focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .enabled(!this.ensureIsoLoading)
          .onClick(() => this.pickBuiltinIso())
      }
      Text('第一张为启动盘候选（从光盘启动时）')
        .fontSize(tSub).fontColor(cWeak).width('100%')
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
    Column({ space: spCard }) {
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
    Column({ space: spCard }) {
      Text('名称').fontSize(tLabel).width(72)
      TextInput({ text: this.name, placeholder: '必填' })
        .fontSize(tBody)
        .maxLength(60)
        .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
        .onChange((v: string) => this.name = v)
      this.stepErrorMsg()
      Row() {
        Text('qemu 参数预览').fontSize(tSub).fontColor(cSub)
        Blank()
      }
      Text(buildArgs(this.assemble(newProfileId()), this.vmDataDir, sharedDir(this.filesDir)).join(' '))
        .fontSize(tMono)
        .fontColor(cText)
        .padding(sp8)
        .width('100%')
        .backgroundColor(cBlock)
        .borderRadius(rElem)
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

          /* 内容下方：下一步 / 完成（固定不随滚动）；完成可能触发镜像/内核复制，显示进度 */
          Row() {
            Blank()
            Button(this.copying ? `复制介质 ${this.copyPct}%`
              : (this.step === STEPS.length - 1 ? '完成' : '下一步'))
              .focusable(false).fontSize(tBody)
              .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
              .backgroundColor(Color.Transparent)
              .fontColor(cPrimary)
              /* 下一步只卡当前步；完成卡全部步（防跳步改坏其他步后直接提交） */
              .enabled(!this.copying && (this.step === STEPS.length - 1
                ? this.fullError().length === 0
                : this.stepError().length === 0))
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
