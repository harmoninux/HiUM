// 机器工坊：分步配置向导（架构→板卡/固件→CPU/内存→介质→网络→命名+预览）。
// 取代扁平 VmEdit 作为「从模板/从零新建 + 编辑」的主路径；VmEdit 保留为高级入口。
// 模板预填 = 把 OsTemplate 灌进各步 state；第⑥步实时 buildArgs 只读预览。
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import {
  VmProfile, VmStore, VmArch, VmBoard, VmFirmware, VgaType,
  blankProfile, newProfileId, fitBoard, buildArgs, sharedDir, SCHEMA_VERSION,
} from '../lib/vmprofile';
import { OsTemplate, OS_TEMPLATES } from '../lib/osTemplates';
import {
  cPrimary, cSub, cWeak, cText, cCard, cBorder, cRunning, cWarn, cBg, cBlock,
  tPage, tCard, tBody, tSub,
  sp1, sp2, sp3, sp4, rCard, bw,
} from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
}
const napi = napiModule as DiskNapi;

export interface WizardParam {
  mode: string;            /* 'new' | 'edit' */
  template?: OsTemplate;   /* 从模板新建 */
  profile?: VmProfile;     /* 编辑已有 */
}

const STEPS: string[] = ['架构', '板卡/固件', 'CPU/内存', '介质', '网络', '命名'];
const ARCH_OPTIONS: VmArch[] = ['x86_64', 'i386', 'aarch64'];
const DISK_SIZES: number[] = [1, 2, 4, 8, 16, 32, 64, 128, 256];

@Component
export struct VmWizard {
  @Prop param: WizardParam = { mode: 'new' };
  onClose: (() => void) | null = null; /* 模态关闭回调（宿主 Stack 置 false）；非响应式，够用 */
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @State showTiles: boolean = true; /* 新建先展示磁贴；编辑直接进表单 */

  @State step: number = 0;
  @State arch: VmArch = 'x86_64';
  @State vga: VgaType = 'std';
  @State board: VmBoard = 'pc';
  @State firmware: VmFirmware = 'seabios';
  @State cpuModel: string = '';
  @State memoryMB: number = 1024;
  @State cpus: number = 2;
  @State mttcg: boolean = true;
  @State tbSizeText: string = '1024';
  @State diskEnabled: boolean = false;
  @State diskGB: number = 8;
  @State diskAlloc: string = 'dynamic';
  @State diskPath: string = '';
  @State cdromPath: string = '';
  @State bootFromCdrom: boolean = false;
  @State kernelBoot: boolean = false;
  @State kernelPath: string = '';
  @State initrdPath: string = '';
  @State kernelArgs: string = '';
  @State netEnabled: boolean = true;
  @State portForwards: string = '';
  @State sharedFolder: boolean = false;
  @State name: string = '';

  aboutToAppear(): void {
    const pm = this.param;
    /* 每次打开都重置到默认，防止组件实例跨 if(showWizard) 开关复用残留上一次状态 */
    this.step = 0;
    this.showTiles = (pm.mode === 'new' && !pm.template);
    this.name = '';
    this.arch = 'x86_64';
    this.board = 'pc';
    this.firmware = 'seabios';
    this.vga = 'std';
    this.cpuModel = '';
    this.memoryMB = 1024;
    this.cpus = 2;
    this.mttcg = true;
    this.tbSizeText = '1024';
    this.diskEnabled = false;
    this.diskGB = 8;
    this.diskAlloc = 'dynamic';
    this.diskPath = '';
    this.cdromPath = '';
    this.bootFromCdrom = false;
    this.kernelBoot = false;
    this.kernelPath = '';
    this.initrdPath = '';
    this.kernelArgs = '';
    this.netEnabled = true;
    this.portForwards = '';
    this.sharedFolder = false;
    if (pm.mode === 'edit' && pm.profile) {
      const p = pm.profile;
      this.name = p.name;
      this.arch = p.machine.arch;
      this.vga = p.machine.vga;
      this.board = p.machine.machine;
      this.firmware = p.machine.firmware;
      this.cpuModel = p.machine.cpuModel;
      this.memoryMB = p.runtime.memoryMB;
      this.cpus = p.runtime.cpus;
      this.mttcg = p.runtime.mttcg;
      this.tbSizeText = String(p.runtime.tbSize);
      this.diskEnabled = p.media.diskPath.length > 0;
      this.diskPath = p.media.diskPath;
      this.cdromPath = p.media.cdromPath;
      this.bootFromCdrom = p.media.bootFromCdrom;
      this.netEnabled = p.net.enabled;
      this.portForwards = p.net.portForwards;
      this.sharedFolder = p.net.sharedFolder;
    } else if (pm.template) {
      /* 已带模板（从模板选择面板点入）直接进表单，不再展示磁贴 */
      this.loadTemplate(pm.template);
      this.showTiles = false;
    }
  }

  /* 磁贴选中：把模板参数灌进各步 state（与 aboutToAppear 模板预填同一逻辑） */
  private loadTemplate(t: OsTemplate): void {
    this.name = t.name + ' (新建)';
    this.arch = t.arch;
    this.vga = t.vga;
    this.board = t.board;
    this.firmware = t.firmware;
    this.memoryMB = t.memoryMB;
    this.cpus = t.cpus;
    this.mttcg = t.mttcg;
    this.tbSizeText = String(t.tbSize);
    this.diskEnabled = t.diskMB > 0;
    this.diskGB = Math.max(1, Math.ceil(t.diskMB / 1024));
    this.cdromPath = t.isoName.length > 0 ? `${this.vmDataDir}/${t.isoName}` : '';
    this.bootFromCdrom = t.bootFromCdrom;
    this.kernelBoot = t.kernelBoot;
  }

  private isEdit(): boolean {
    return this.param.mode === 'edit' && this.param.profile !== null;
  }

  private boards(): string[] {
    return this.arch === 'aarch64' ? ['virt', 'raspi2'] : ['pc', 'q35'];
  }

  private boardName(b: string): string {
    if (b === 'virt') return 'virt (通用)';
    if (b === 'raspi2') return 'raspi2 (树莓派)';
    if (b === 'q35') return 'q35 (现代PCIe)';
    return 'pc (兼容最好)';
  }

  /* 从当前步装配一份 VmProfile（不落盘、不建盘；用于预览/完成） */
  private assemble(id: string): VmProfile {
    let diskPath = this.diskPath;
    if (this.diskEnabled && diskPath.length === 0) {
      diskPath = `${this.filesDir}/vms/${id}.qcow2`;
    }
    const tbSize = Number(this.tbSizeText);
    let extra = '';
    if (this.kernelBoot) {
      const parts: string[] = [];
      if (this.kernelPath.length > 0) { parts.push('-kernel ' + this.kernelPath); }
      if (this.initrdPath.length > 0) { parts.push('-initrd ' + this.initrdPath); }
      if (this.kernelArgs.length > 0) { parts.push('-append "' + this.kernelArgs + '"'); }
      extra = parts.join(' ');
    }
    const p: VmProfile = {
      schemaVersion: SCHEMA_VERSION,
      id: id,
      name: this.name.trim().length > 0 ? this.name.trim() : '未命名',
      machine: {
        arch: this.arch,
        vga: this.vga,
        machine: fitBoard(this.arch, this.board),
        firmware: this.firmware,
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
      temporarySession: this.isEdit() ? (this.param.profile as VmProfile).temporarySession : false,
      extraArgs: extra,
    };
    return p;
  }

  private finish(): void {
    const id = this.isEdit() ? (this.param.profile as VmProfile).id : newProfileId();
    const p = this.assemble(id);
    if (this.diskEnabled && p.media.diskPath.length > 0) {
      if (!fs.accessSync(p.media.diskPath)) {
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
          Text(String(i + 1)).fontSize(10)
            .fontColor(this.step === i ? Color.White : cSub)
            .width(20).height(20).textAlign(TextAlign.Center)
            .backgroundColor(this.step === i ? cPrimary : Color.Transparent)
            .border({ width: bw, color: this.step === i ? cPrimary : cBorder })
            .borderRadius(10)
          Text(s).fontSize(10).fontColor(this.step === i ? cPrimary : cWeak)
        }
        .layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => this.step = i)
      }, (s: string) => s)
    }
    .width('100%').padding({ left: sp2, right: sp2 })
  }

  /* 新建时的磁贴模板选择：点磁贴预填进工坊；「从零开始」进手工向导 */
  @Builder
  templateTiles() {
    Column() {
      Row() {
        Text('新建虚拟机').fontSize(tPage).fontWeight(FontWeight.Bold)
        Blank()
        Button('×').backgroundColor(Color.Transparent).fontColor(cWeak)
          .onClick(() => { if (this.onClose) this.onClose(); })
      }.width('100%').padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(OS_TEMPLATES, (t: OsTemplate) => {
          Column() {
            Text(t.icon ?? '💿').fontSize(26)
            Text(t.name).fontSize(tCard).fontWeight(FontWeight.Medium).margin({ top: sp1 })
            Text(t.arch).fontSize(10).fontColor(cSub).fontFamily('monospace')
            Text(t.imageNeeded ? '需自备' : '内置镜像').fontSize(10)
              .fontColor(t.imageNeeded ? cWarn : cRunning)
          }
          .width('48%').margin({ bottom: sp2 }).padding(sp3)
          .backgroundColor(cCard).borderRadius(rCard)
          .border({ width: bw, color: cBorder })
          .onClick(() => { this.loadTemplate(t); this.step = 0; this.showTiles = false; })
        }, (t: OsTemplate) => t.id)
      }.width('100%')
      Row() {
        Text('都不合适？').fontSize(tSub).fontColor(cSub)
        Blank()
        Button('从零开始（手工向导）').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cPrimary)
          .onClick(() => { this.step = 0; this.showTiles = false; })
      }.width('100%').padding({ left: sp4, right: sp4, top: sp3, bottom: sp4 })
    }.width('100%').backgroundColor(cCard).borderRadius(rCard)
  }

  @Builder
  stepArch() {
    Column({ space: 12 }) {
      Text('选择 CPU 架构（决定可用板卡与固件）').fontSize(13).fontColor(cSub)
      Row({ space: 10 }) {
        ForEach(ARCH_OPTIONS, (a: VmArch) => {
          Column() {
            Text(a).fontSize(15).fontWeight(FontWeight.Medium)
            if (a === 'aarch64') { Text('arm64').fontSize(11).fontColor(cWeak) }
            if (a === 'x86_64') { Text('现代 x86').fontSize(11).fontColor(cWeak) }
            if (a === 'i386') { Text('复古 x86').fontSize(11).fontColor(cWeak) }
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
    .padding(12)
  }

  @Builder
  stepBoard() {
    Column({ space: 10 }) {
      Text('板卡 + 固件（按架构过滤）').fontSize(13).fontColor(cSub)
      Row({ space: 10 }) {
        ForEach(this.boards(), (b: string) => {
          Column() {
            Text(b).fontSize(15).fontWeight(FontWeight.Medium)
            Text(this.boardName(b)).fontSize(10).fontColor(cWeak)
          }
          .layoutWeight(1)
          .padding(12)
          .backgroundColor(this.board === b ? cPrimary : Color.White)
          .borderRadius(8)
          .onClick(() => this.board = b as VmBoard)
        }, (b: string) => b)
      }
      .width('100%')

      Row({ space: 10 }) {
        Column() {
          Text('固件').fontSize(13).fontColor(cSub)
          Text('SeaBIOS').fontSize(14)
            .fontColor(this.firmware === 'seabios' ? cPrimary : Color.Black)
            .onClick(() => this.firmware = 'seabios')
        }.layoutWeight(1)
        Column() {
          Text('OVMF (UEFI)').fontSize(13).fontColor(cSub)
          Text('OVMF').fontSize(14)
            .fontColor(this.firmware === 'ovmf' ? cPrimary : Color.Black)
            .onClick(() => this.firmware = 'ovmf')
        }.layoutWeight(1)
      }
      .width('100%')

      Text('CPU 机型（留空 = 自动；aarch64 默认 max，x86 用板卡默认）').fontSize(12).fontColor(cWeak)
      TextInput({ text: this.cpuModel, placeholder: '如 cortex-a57 / max / host' })
        .fontSize(13)
        .onChange((v: string) => this.cpuModel = v)

      if (this.firmware === 'ovmf') {
        Text('OVMF 需板卡支持 + OVMF_CODE/VARS 固件（make deps 尚未产出，暂回落 SeaBIOS）')
          .fontSize(11).fontColor(cWarn)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
  }

  @Builder
  stepCpuMem() {
    Column({ space: 8 }) {
      Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(14)
      Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
        .onChange((v: number) => this.memoryMB = v)
      Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(14)
      Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
        .onChange((v: number) => this.cpus = v)
      Row() {
        Text('TCG 多线程 (MTTCG)').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.mttcg })
          .onChange((v: boolean) => this.mttcg = v)
      }
      Row() {
        Text('tb-size').fontSize(14).width(90)
        TextInput({ text: this.tbSizeText })
          .layoutWeight(1)
          .fontSize(13)
          .onChange((v: string) => this.tbSizeText = v)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
  }

  @Builder
  stepMedia() {
    Column({ space: 8 }) {
      Row() {
        Text('系统盘').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.diskEnabled })
          .onChange((v: boolean) => this.diskEnabled = v)
      }
      if (this.diskEnabled) {
        Text(this.diskPath ? fs.accessSync(this.diskPath) ? '已有盘: ' + this.baseName(this.diskPath) : '新建: ' + this.baseName(this.diskPath) : '保存时创建')
          .fontSize(12).fontColor(cSub)
        Row({ space: 8 }) {
          Slider({ value: Math.max(0, DISK_SIZES.indexOf(this.diskGB)),
            min: 0, max: DISK_SIZES.length - 1, step: 1 })
            .layoutWeight(1)
            .onChange((v: number) => this.diskGB = DISK_SIZES[Math.round(v)])
          Text(`${Math.round(this.diskGB)}GB`).fontSize(13)
        }
        Row({ space: 8 }) {
          Text('动态分配').fontSize(13)
            .fontColor(this.diskAlloc === 'dynamic' ? cPrimary : Color.Black)
            .onClick(() => this.diskAlloc = 'dynamic')
          Text('固定大小').fontSize(13)
            .fontColor(this.diskAlloc === 'fixed' ? cPrimary : Color.Black)
            .onClick(() => this.diskAlloc = 'fixed')
        }
      }

      Row() {
        Text('光盘 ISO').fontSize(14).width(72)
        Text(this.cdromPath ? this.baseName(this.cdromPath) : '无')
          .fontSize(13).fontColor(cSub).layoutWeight(1)
        if (this.cdromPath.length > 0) {
          Button('移除').focusable(false).fontSize(12)
            .onClick(() => this.cdromPath = '')
        }
      }
      if (this.cdromPath.length === 0 && !this.kernelBoot) {
        Row({ space: 8 }) {
          TextInput({ placeholder: 'ISO 完整路径', text: this.cdromPath })
            .layoutWeight(1).fontSize(13)
            .onChange((v: string) => this.cdromPath = v)
          Button('内置 Alpine').focusable(false).fontSize(12)
            .onClick(() => {
              const iso = this.vmDataDir + '/alpine-virt.iso';
              if (fs.accessSync(iso)) { this.cdromPath = iso; } else {
                promptAction.showToast({ message: '内置 ISO 不存在（需 make deps）' });
              }
            })
        }
      }
      Row() {
        Text('从光盘启动').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
          .onChange((v: boolean) => this.bootFromCdrom = v)
      }

      Text('直启内核（-kernel/-initrd/-append，教学/实验室）').fontSize(13).fontColor(cSub)
        .margin({ top: 4 })
      Row() {
        Text('直启内核').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.kernelBoot })
          .onChange((v: boolean) => this.kernelBoot = v)
      }
      if (this.kernelBoot) {
        TextInput({ placeholder: 'kernel 路径，如 /data/.../kernel_aarch64', text: this.kernelPath })
          .fontSize(13).onChange((v: string) => this.kernelPath = v)
        TextInput({ placeholder: 'initrd 路径（可空）', text: this.initrdPath })
          .fontSize(13).onChange((v: string) => this.initrdPath = v)
        TextInput({ placeholder: '内核参数（可为空），如 console=ttyS0', text: this.kernelArgs })
          .fontSize(13).onChange((v: string) => this.kernelArgs = v)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
  }

  @Builder
  stepNet() {
    Column({ space: 8 }) {
      Row() {
        Text('网络').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
          .onChange((v: boolean) => this.netEnabled = v)
      }
      if (this.netEnabled) {
        Text('端口转发（宿主端口:客机端口，逗号分隔）').fontSize(12).fontColor(cSub)
        TextInput({ placeholder: '如 2222:22,8080:80', text: this.portForwards })
          .fontSize(13).onChange((v: string) => this.portForwards = v)
        Row() {
          Text('9p 共享目录').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.sharedFolder })
            .onChange((v: boolean) => this.sharedFolder = v)
        }
        if (this.sharedFolder) {
          Text('挂载宿主 filesDir/shared 到客机 /shared（9p）').fontSize(11).fontColor(cWeak)
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
  }

  @Builder
  stepPreview() {
    Column({ space: 8 }) {
      Text('名称').fontSize(14).width(72)
      TextInput({ text: this.name })
        .layoutWeight(1)
        .onChange((v: string) => this.name = v)
      Row() {
        Text('qemu 参数预览').fontSize(13).fontColor(cSub)
        Blank()
        Text('只读').fontSize(11).fontColor(cWeak)
      }
      Text(buildArgs(this.assemble(newProfileId()), this.vmDataDir, sharedDir(this.filesDir)).join(' '))
        .fontSize(10)
        .fontColor(cText)
        .padding(8)
        .width('100%')
        .backgroundColor(cBlock)
        .borderRadius(6)
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  build() {
    Column() {
      if (this.showTiles && !this.isEdit()) {
        /* 新建：先展示磁贴模板；点磁贴/「从零开始」才进表单 */
        this.templateTiles()
      } else {
        Row() {
          Button('取消').focusable(false).fontSize(14).backgroundColor(Color.Transparent)
            .fontColor(cPrimary)
            .onClick(() => { if (this.onClose) this.onClose(); })
          Blank()
          Text('机器工坊').fontSize(18).fontWeight(FontWeight.Medium)
          Blank()
          Button(this.step === STEPS.length - 1 ? '完成' : '下一步')
            .focusable(false).fontSize(14).backgroundColor(Color.Transparent)
            .fontColor(cPrimary)
            .onClick(() => {
              if (this.step < STEPS.length - 1) {
                this.step++;
              } else {
                this.finish();
              }
            })
        }
        .width('100%')
        .padding({ left: sp2, right: sp2, top: sp2, bottom: sp2 })

        this.stepHeader()

        Scroll() {
          Column() {
            if (this.step === 0) { this.stepArch() }
            else if (this.step === 1) { this.stepBoard() }
            else if (this.step === 2) { this.stepCpuMem() }
            else if (this.step === 3) { this.stepMedia() }
            else if (this.step === 4) { this.stepNet() }
            else if (this.step === 5) { this.stepPreview() }
            if (this.step < STEPS.length - 1) {
              Button('上一步').focusable(false).fontSize(14)
                .backgroundColor(Color.Black)
                .fontColor(cSub)
                .margin({ top: 16 })
                .onClick(() => { if (this.step > 0) this.step--; })
            }
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cBg)
  }
}
