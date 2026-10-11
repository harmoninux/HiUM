// 虚拟机配置弹窗：全窗口遮罩 + 居中卡，内部左侧 Tab（基础/存储/网络/高级）分块聚焦。
// 由 Index.editOverlay 承载（editParam 传 VM、onClose 关闭），不再 Navigation 压栈——
// 单页长表单四类字段混排、保存钮在页尾，弹窗 + Tab 每屏只看一类。
// 只编辑 VmProfile JSON，保存后由列表页/console 窗口消费。
// 表单行布局：能贴右的贴右（设置行范式）——布尔 Switch 行与选项少的 Chip 行
// （磁盘接口/网卡型号）标签撑满 + 控件贴右；选项多一行放不下的 Chip 行（架构/
// 显卡）才用标签 72 列 + 控件从列位流动排列。Slider 一行标签、一行滑条。
// 字号按区域定档（不逐按钮判断）：内容区（标签/值/说明/Chip/按钮/输入框）一律
// tItem 14、说明 tSub 12、输入框 inpH 36 与胶囊协调；仅底部操作条用 tBody 16
// /btnH 40。危险动作（移除/删除/清除）一律透明底 + cDanger。
import { promptAction } from '@kit.ArkUI';
import napiModule from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { VmProfile, VmStore, VmArch, VgaType, VmDisk, DiskIface, NetModel, SCHEMA_VERSION, fitBoard, fitVga, builtinIsoFor, forwardErrors, mainDiskPath } from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { isoReadable } from '../lib/fsutil';
import { pickIsoPath } from '../lib/isoPick';
import { Chip } from '../lib/uiWidgets';
import { PortForwardEditor } from '../lib/PortForwardEditor';
import { cPrimary, cDanger, cSub, cWeak, cBg, cCard, cBorder, cText, tCard, tLabel, tBody, tItem, tSub, tMono, rBtn, bw, btnSh, inpH, inpBg, inpRadius, inpPadX, sp1, sp2, sp3, sp4, sp5, sp6 } from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
  diskInfo: (path: string) => string;
}

const napi = napiModule as DiskNapi;

const GB = 1024 * 1024 * 1024;

@Component
export struct VmEdit {
  @Prop profile: VmProfile | null = null; /* 由 Index 模态传入（@Prop 深拷贝，就地编辑） */
  onClose: (() => void) | null = null; /* 关闭回调；宿主（Index.closeEdit）通过它关掉弹窗 */
  /* sheet 系统关闭（✕/遮罩/back）的拦截桥：Index.shouldDismiss 不直接放行，改为递增本值，
   * 由 requestCancel 决定是否真关（有未保存改动先弹「放弃修改？」） */
  @Prop @Watch('onCloseReqChanged') closeReq: number = 0;
  @Consume('showStorage') showStorage: boolean; /* 存储弹窗全窗口开关（存储 Tab 内打开，盖在本弹窗上） */
  @Consume('storageParam') storageParam: VmProfile | null;
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @State tabIdx: number = 0; /* 左侧 Tab：0 基础 / 1 存储 / 2 网络 / 3 高级 */
  @State name: string = '';
  @State arch: VmArch = 'x86_64';
  @State memoryMB: number = 1024;
  @State cpus: number = 2;
  @State diskPath: string = '';
  @State cdromPaths: string[] = [];
  @State bootFromCdrom: boolean = false;
  @State netEnabled: boolean = true;
  @State portForwards: string = '';
  @State sharedFolder: boolean = false;
  @State extraArgs: string = '';
  @State kernelAppend: string = ''; /* 内核参数（-append）；仅当 VM 已配 kernel 时展示可编辑 */
  /* v4：显卡/系统增强/只读与第二盘 */
  @State vga: VgaType = 'std';
  @State rng: boolean = false;
  @State balloon: boolean = false;
  @State diskReadonly: boolean = false;
  @State diskIface: DiskIface = 'virtio'; /* 系统盘接口；数据盘继承它（存储弹窗创建时已定） */
  @State netModel: NetModel = 'virtio';
  @State serialInteractive: boolean = true;
  @State extraDisks: VmDisk[] = []; /* 数据盘（disks[1..]，第 0 张为系统盘走 diskPath） */
  /* v6：声音 / GDB 调试后端 / RTC 本地时区 */
  @State audio: boolean = true;
  @State gdbOn: boolean = false;
  @State gdbPortText: string = '1234';
  @State rtcLocal: boolean = false;
  @State ensureIsoLoading: boolean = false; /* 内置 Alpine ISO 下载中 */
  @State isoPct: number = 0;
  /* 保存被校验拦下时的内联红字（替代 toast：点过保存就常驻卡头下方；
   * 在哪个 Tab 都看得见；成功保存不会走到这里） */
  @State saveErrorMsg: string = '';
  /* 已建系统盘的元信息（qemu-img info），直接在「系统盘」行内展示 */
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;
  /* 打开弹窗时的表单指纹：取消时比对，有实质改动才弹放弃确认（改了又改回不弹） */
  private baseline: string = '';

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.memoryMB = p.runtime.memoryMB;
    this.cpus = p.runtime.cpus;
    this.diskPath = mainDiskPath(p);
    this.cdromPaths = p.media.cdromPaths.length > 0 ? p.media.cdromPaths.slice() : [];
    this.bootFromCdrom = p.media.bootFromCdrom;
    this.netEnabled = p.net.enabled;
    this.portForwards = p.net.portForwards;
    this.sharedFolder = p.net.sharedFolder;
    this.extraArgs = p.extraArgs;
    this.kernelAppend = p.media.kernelAppend;
    this.vga = p.machine.vga;
    this.rng = p.runtime.rng;
    this.balloon = p.runtime.balloon;
    this.diskReadonly = p.media.disks.length > 0 ? p.media.disks[0].readonly : false;
    this.diskIface = p.media.disks.length > 0 ? p.media.disks[0].iface : 'virtio';
    this.netModel = p.net.model;
    this.serialInteractive = p.machine.serialInteractive;
    this.extraDisks = p.media.disks.slice(1);
    /* v6 */
    this.audio = p.runtime.audio;
    this.gdbOn = p.runtime.gdbPort > 0;
    this.gdbPortText = String(p.runtime.gdbPort > 0 ? p.runtime.gdbPort : 1234);
    this.rtcLocal = p.machine.rtcLocal;
    this.readDiskMeta();
    this.baseline = this.formSig();
  }

  /* 表单指纹：覆盖全部可编辑字段（派生展示字段除外） */
  private formSig(): string {
    return JSON.stringify([
      this.name, this.memoryMB, this.cpus, this.vga,
      this.cdromPaths, this.bootFromCdrom, this.kernelAppend,
      this.netEnabled, this.portForwards, this.sharedFolder, this.netModel,
      this.rng, this.balloon, this.audio,
      this.diskReadonly, this.diskIface,
      this.serialInteractive, this.gdbOn, this.gdbPortText,
      this.rtcLocal, this.extraArgs, this.extraDisks,
    ]);
  }

  /* 取消：有未保存改动时先确认，防误触丢配置 */
  private onCloseReqChanged(): void {
    if (this.closeReq > 0) {
      this.requestCancel();
    }
  }

  private requestCancel(): void {
    if (this.formSig() !== this.baseline) {
      AlertDialog.show({
        title: '放弃修改？',
        message: '当前修改的内容不会保存。',
        buttons: [
          { value: '继续编辑', action: () => {} },
          { value: '放弃', fontColor: cDanger, action: () => this.close() },
        ],
      });
      return;
    }
    this.close();
  }

  private close(): void {
    if (this.onClose) {
      this.onClose();
    }
  }

  private titleName(): string {
    const p = this.profile;
    return p ? p.name : '';
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

  /* 追加一张 ISO（去重）；列表顺序 = 启动顺序，第一张为启动盘候选 */
  private addIso(pStr: string): void {
    if (pStr.length === 0) { return; }
    if (this.cdromPaths.indexOf(pStr) < 0) {
      this.cdromPaths = this.cdromPaths.concat([pStr]);
    }
  }
  private removeIso(idx: number): void {
    const next = this.cdromPaths.slice();
    next.splice(idx, 1);
    this.cdromPaths = next;
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  /* 是否已配直接内核引导（build 里判空走这里，避免 this.profile 链式取值触发 nullable 报错） */
  private hasKernel(): boolean {
    const p = this.profile;
    return p !== null && p.media.kernelPath.length > 0;
  }

  /* 「内核 xxx + yyy」摘要行（仅 hasKernel 时调用） */
  private kernelLabel(): string {
    const p = this.profile;
    if (!p) {
      return '';
    }
    let s = '内核 ' + this.baseName(p.media.kernelPath);
    if (p.media.initrdPath.length > 0) {
      s += ' + ' + this.baseName(p.media.initrdPath);
    }
    return s;
  }

  /* 「选择文件」按钮：拉起系统选择器选 .iso，解析成真实路径后挂到光驱并默认从光盘启动。
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

  /* 读取已建磁盘的格式/虚拟大小/实占大小（qemu-img info），供「系统盘」行直接展示 */
  private readDiskMeta(): void {
    this.diskFmt = '?';
    this.diskVirtualGB = 0;
    this.diskActualGB = 0;
    const s = napi.diskInfo(this.diskPath);
    if (s.length === 0) {
      return;
    }
    try {
      /* ArkTS 禁对接口字段下标访问（arkts-no-props-by-index），用 Record 字典式解析 */
      const j = JSON.parse(s) as Record<string, number | string>;
      const vsize = typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0;
      const actual = typeof j['actual-size'] === 'number' ? j['actual-size'] as number : 0;
      const fmt = typeof j['format'] === 'string' ? j['format'] as string : '?';
      this.diskFmt = fmt;
      this.diskVirtualGB = vsize / GB;
      this.diskActualGB = actual / GB;
    } catch {
      /* 解析失败保持默认 */
    }
  }

  /* v4 板卡判定（只读展示，按 fitBoard 对齐构建行为） */
  private isX86Board(): boolean {
    const p = this.profile;
    if (!p) { return true; }
    const b = fitBoard(this.arch, p.machine.machine);
    return b === 'pc' || b === 'q35';
  }

  private isRaspiBoard(): boolean {
    const p = this.profile;
    if (!p) { return false; }
    const b = fitBoard(this.arch, p.machine.machine);
    return b === 'raspi2' || b === 'raspi3';
  }

  /* 保存前静态校验：返回第一条错误描述（'' = 通过）。覆盖「从光盘启动但未指定 ISO」、
   * 端口转发格式、ISO 路径存在性。cpuModel 编辑页无入口、tb-size 有整数兜底，交由向导
   * 与构建时拦；自定义 qemu 参数(extraArgs)与资源型错误无法静态判定，由启动失败时的
   * qemu.log 透出（VmConsole）。 */
  private saveError(): string {
    if (this.bootFromCdrom && this.cdromPaths.length === 0) {
      return '从光盘启动需先指定 ISO';
    }
    for (const p of this.cdromPaths) {
      if (!isoReadable(p)) {
        return 'ISO 不可读或不存在';
      }
    }
    if (this.netEnabled && this.portForwards.trim().length > 0) {
      const errs = forwardErrors(this.portForwards);
      if (errs.length > 0) { return '端口转发：' + errs.join('；'); }
    }
    /* v6：GDB 端口（开启时）须为 1-65535 整数 */
    if (this.gdbOn) {
      const gp = Number(this.gdbPortText);
      if (!Number.isInteger(gp) || gp < 1 || gp > 65535) {
        return 'GDB 端口需为 1-65535 的整数';
      }
    }
    return '';
  }

  private save(): void {
    if (!this.profile) {
      return;
    }
    /* 保存前静态校验：拦下明显无效的组合，避免落盘后启动才暴露（与向导 calcError 对齐）。
     * 失败走内联红字（卡头下方常驻）而不是 toast——四条校验都可能命中表单深处，
     * toast 一闪而过用户不知改哪 */
    this.saveErrorMsg = '';
    const verr = this.saveError();
    if (verr.length > 0) {
      this.saveErrorMsg = verr;
      return;
    }
    /* 保存基线从磁盘重读：本弹窗与存储弹窗各持内存副本（@Prop 深拷贝），谁后保存
     * 谁整份覆盖——若从本副本整份落盘，存储弹窗刚做的数据盘增删/光盘挂载会被
     * 本窗的旧值回滚。磁盘段的盘路径/增删不归本窗管，以磁盘最新档为准，
     * 本窗只合并系统盘三个属性与数据盘只读开关（见 mergeDisks）。load 失败才回退副本。 */
    const base = new VmStore(this.filesDir).load(this.profile.id) ?? this.profile;
    const p: VmProfile = {
      schemaVersion: SCHEMA_VERSION,
      id: base.id,
      name: this.name.trim().length > 0 ? this.name.trim() : '未命名',
      machine: {
        arch: this.arch,
        vga: fitVga(fitBoard(this.arch, base.machine.machine), this.vga),
        machine: fitBoard(this.arch, base.machine.machine),
        firmware: base.machine.firmware,
        cpuModel: base.machine.cpuModel,
        serialInteractive: this.serialInteractive,
        cpuFlags: base.machine.cpuFlags,
        rtcLocal: this.rtcLocal,
      },
      runtime: {
        memoryMB: Math.round(this.memoryMB),
        cpus: Math.round(this.cpus),
        mttcg: base.runtime.mttcg,
        tbSize: base.runtime.tbSize,
        rng: this.rng,
        balloon: this.balloon,
        audio: this.audio,
        gdbPort: this.gdbOn ? Number(this.gdbPortText) : 0,
      },
      media: {
        disks: this.mergeDisks(base),
        cdromPaths: this.cdromPaths,
        bootFromCdrom: this.bootFromCdrom,
        /* kernel/initrd 本窗无更换入口，原样透传；kernelAppend 由高级 Tab 输入框编辑 */
        kernelPath: base.media.kernelPath,
        initrdPath: base.media.initrdPath,
        kernelAppend: this.kernelAppend.trim(),
      },
      net: {
        enabled: this.netEnabled,
        portForwards: this.portForwards.trim(),
        sharedFolder: this.sharedFolder,
        model: this.netModel,
      },
      temporarySession: base.temporarySession,
      extraArgs: this.extraArgs.trim(),
    };
    new VmStore(this.filesDir).save(p);
    this.vmListVersion++;
    promptAction.showToast({ message: '已保存' });
    this.close();
  }

  /* 磁盘段合并：路径与数据盘增删归存储窗（以 base 最新档为准），本窗只写
   * 系统盘的 只读/接口/缓存 三属性 + 数据盘的只读开关（按位对齐，存储窗增删
   * 过的盘以 base 为准，表单里多出的陈旧项丢弃）。 */
  private mergeDisks(base: VmProfile): VmDisk[] {
    const first: VmDisk = base.media.disks.length > 0
      ? {
        path: base.media.disks[0].path,
        readonly: this.diskReadonly,
        iface: this.diskIface,
        cache: base.media.disks[0].cache,
      }
      : { path: '', readonly: this.diskReadonly, iface: this.diskIface };
    const rest = base.media.disks.slice(1).map((d: VmDisk, i: number): VmDisk => {
      return {
        path: d.path,
        readonly: i < this.extraDisks.length ? this.extraDisks[i].readonly : d.readonly,
        iface: d.iface,
        cache: d.cache,
      };
    });
    return [first].concat(rest);
  }

  @Builder
  tabBtn(label: string, idx: number) {
    Row() {
      Text(label)
        .fontSize(tBody)
        .fontWeight(this.tabIdx === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tabIdx === idx ? cPrimary : cSub)
    }
    .width('100%')
    .height(44)
    .padding({ left: sp4 })
    .backgroundColor(this.tabIdx === idx ? cCard : Color.Transparent)
    .border({ width: { left: 2 }, color: { left: this.tabIdx === idx ? cPrimary : Color.Transparent } })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.tabIdx = idx; })
  }

  build() {
    Column() {
      /* 标题/关闭由 sheet 系统提供；校验拦截提示（内联红字）常驻内容顶部，任何 Tab 都看得见 */
      if (this.saveErrorMsg.length > 0) {
        Text(this.saveErrorMsg).fontSize(tSub).fontColor(cDanger).width('100%')
          .padding({ left: sp5, right: sp5, top: sp2, bottom: sp2 })
      }

      Row() {
        /* 左侧 Tab 栏 */
        Column() {
          this.tabBtn('基础', 0)
          this.tabBtn('存储', 1)
          this.tabBtn('网络', 2)
          this.tabBtn('高级', 3)
        }
        .width(136)
        .height('100%')
        .backgroundColor(cBg)
        .alignItems(HorizontalAlign.Start)
        .padding({ top: sp2 })

        /* 右侧内容：一次只渲染当前 Tab。行距节奏收归本容器统一（space sp2），
         * 行内不再自带上下 padding——否则各行 4/12 随机叠加出行距 8~24 乱跳 */
        Scroll() {
          Column({ space: sp2 }) {
            if (this.tabIdx === 0) {
              /* —— 基础 —— */
              Row() {
                Text('名称').fontSize(tLabel).width(72)
                TextInput({ text: this.name })
                  .layoutWeight(1)
                  .fontSize(tItem)
                  .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                  .onChange((v: string) => this.name = v)
              }
              Row() {
                Text('架构').fontSize(tLabel).width(72)
                Text(this.arch)
                  .fontSize(tBody)
                  .fontColor(cSub)
                  .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).layoutWeight(1)
                  .padding({ left: inpPadX, right: inpPadX })
                  .textAlign(TextAlign.Start)
              }
              Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(tLabel)
              Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
                .onChange((v: number) => this.cpus = v)
                .width('100%')
                .height(40)                
              Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(tLabel)
              Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
                .onChange((v: number) => this.memoryMB = v)
                .width('100%')
                .height(40)                
              /* v4 显卡：x86 板卡可换；virt/raspi 固定（说明行） */
              Row({ space: sp3 }) {
                Text('显卡').fontSize(tLabel).width(72)
                if (this.isX86Board()) {
                  Row({ space: sp3 }) {
                    ForEach(['std', 'cirrus', 'vmware', 'virtio'], (g: string) => {
                      Chip({ label: g, active: this.vga === g, onTap: () => { this.vga = g as VgaType; } })
                    }, (g: string) => g)
                  }
                } else {
                  Text(this.isRaspiBoard() ? '板载（固定）' : 'virtio-gpu（固定）')
                    .fontSize(tSub).fontColor(cSub).layoutWeight(1)
                }
              }.width('100%')            } else if (this.tabIdx === 1) {
              /* —— 存储：容量/重建/数据盘增删在「存储管理」弹窗，此处只做开关与光盘 —— */
              Column({ space: sp1 }) {
                Row() {
                  Text('系统盘').fontSize(tLabel).width(72)
                  Column({ space: 2 }) {
                    Text(this.baseName(this.diskPath))
                      .fontSize(tItem)
                      .fontColor(cText)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`)
                      .fontSize(tMono)
                      .fontColor(cWeak)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Button('存储管理').focusable(false).fontSize(tItem)
                    .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                    .backgroundColor(Color.Transparent).fontColor(cPrimary)
                    .onClick(() => {
                      const p = this.profile;
                      if (p) {
                        this.storageParam = p;
                        this.showStorage = true;
                      }
                    })
                }
              }.alignItems(HorizontalAlign.Start)
              /* v5：系统盘只读 + 数据盘列表（创建/导入/移除/扩容在存储弹窗） */
              Column({ space: sp1 }) {
                Row() {
                  Text('系统盘只读').fontSize(tLabel).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.diskReadonly })
                    .onChange((v: boolean) => this.diskReadonly = v)
                }.width('100%')
                Text('开启后防系统盘误写；扩容、快照等管理操作不受影响').fontSize(tSub).fontColor(cWeak).width('100%')
              }

              /* 磁盘接口（仅 x86 板卡有 IDE 南桥）：切换只影响 -drive if= 的挂载方式，
               * 盘内容不动——Windows VM 若误建为 virtio，切到 ide 即可被安装程序识别。 */
              if (this.isX86Board()) {
                Column({ space: sp1 }) {
                  Row({ space: sp3 }) {
                    Text('磁盘接口').fontSize(tLabel).layoutWeight(1)
                    Chip({ label: 'virtio', active: this.diskIface === 'virtio', onTap: () => { this.diskIface = 'virtio'; } })
                    Chip({ label: 'ide（Windows）', active: this.diskIface === 'ide', onTap: () => { this.diskIface = 'ide'; } })
                  }.width('100%')
                  Text(this.diskIface === 'ide'
                    ? 'Windows 免装驱动即可识别'
                    : '性能更好，Linux 首选；Windows 需另装驱动')
                    .fontSize(tSub).fontColor(cWeak).width('100%')
                }
              }

              Column({ space: sp1 }) {
                Row() {
                  Text('数据盘').fontSize(tLabel).width(72)
                  Text(this.extraDisks.length === 0 ? '未配置' : `${this.extraDisks.length} 张`)
                    .fontSize(tSub).fontColor(cSub).layoutWeight(1)
                  Button('存储管理').focusable(false).fontSize(tItem)
                    .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                    .backgroundColor(Color.Transparent).fontColor(cPrimary)
                    .onClick(() => {
                      const p = this.profile;
                      if (p) {
                        this.storageParam = p;
                        this.showStorage = true;
                      }
                    })
                }
                ForEach(this.extraDisks, (d: VmDisk, idx: number) => {
                  Row({ space: sp3 }) {
                    Text(`数据盘${idx + 1}`)
                      .fontSize(tSub).fontColor(cSub).layoutWeight(1).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(d.iface === 'ide' ? 'IDE' : 'virtio').fontSize(tSub).fontColor(cWeak)
                    Text('只读').fontSize(tSub).fontColor(cSub)
                    Toggle({ type: ToggleType.Switch, isOn: d.readonly })
                      .onChange((v: boolean) => {
                        const next = this.extraDisks.slice();
                        next[idx] = { path: d.path, readonly: v, iface: d.iface };
                        this.extraDisks = next;
                      })
                  }.width('100%')                }, (d: VmDisk) => d.path)
                Text('快照仅含系统盘，数据盘不参与').fontSize(tSub).fontColor(cWeak).width('100%')
              }.alignItems(HorizontalAlign.Start).width('100%')
              Column({ space: sp1 }) {
                Text('光盘 ISO').fontSize(tLabel)
                if (this.cdromPaths.length > 0) {
                  ForEach(this.cdromPaths, (p: string, idx: number) => {
                    Row({ space: sp3 }) {
                      Text(idx === 0 ? `${this.baseName(p)}（启动盘）` : this.baseName(p))
                        .fontSize(tItem)
                        .fontColor(idx === 0 ? cPrimary : cSub)
                        .layoutWeight(1)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Button('移除').focusable(false).fontSize(tItem)
                        .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                        .backgroundColor(Color.Transparent).fontColor(cDanger)
                        .onClick(() => this.removeIso(idx))
                    }
                    .width('100%')
                  }, (p: string, idx: number) => `${idx}:${p}`)
                } else {
                  Text('无').fontSize(tSub).fontColor(cSub)
                }
                Row({ space: sp3 }) {
                  Button('选择文件').focusable(false).fontSize(tItem)
                    .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                    .backgroundColor(Color.Transparent).fontColor(cPrimary)
                    .onClick(() => this.pickLocalIso())
                  Button(this.ensureIsoLoading ? `内置下载 ${this.isoPct}%` : `内置 Alpine (${this.arch})`)
                    .focusable(false).fontSize(tItem)
                    .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                    .backgroundColor(Color.Transparent).fontColor(cPrimary)
                    .enabled(!this.ensureIsoLoading)
                    .onClick(() => this.pickBuiltinIso())
                }
              }.alignItems(HorizontalAlign.Start).width('100%')
              Row() {
                Text(this.hasKernel() ? '从光盘启动（内核引导时无效）' : '从光盘启动')
                  .fontSize(tLabel).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
                  .enabled(!this.hasKernel())
                  .onChange((v: boolean) => this.bootFromCdrom = v)
              }            } else if (this.tabIdx === 2) {
              /* —— 网络 —— */
              Row() {
                Text('启用网络').fontSize(tLabel).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
                  .onChange((v: boolean) => this.netEnabled = v)
              }
              if (this.netEnabled) {
                Column({ space: sp1 }) {
                  Text('端口映射').fontSize(tLabel)
                  PortForwardEditor({ text: this.$portForwards })
                }.alignItems(HorizontalAlign.Start)
                Column({ space: sp1 }) {
                  Row() {
                    Text('共享目录').fontSize(tLabel).layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.sharedFolder })
                      .onChange((v: boolean) => this.sharedFolder = v)
                  }.padding({ left: 0, right: 0 })
                  Text('开启后虚拟机可读写设备的 Download 目录（在虚拟机内是 /shared）').fontSize(tSub).fontColor(cWeak)
                }.alignItems(HorizontalAlign.Start)                /* 网卡型号（仅 x86 板卡可切）：rtl8139 是 XP/Win7 唯一双 in-box 驱动的
                 * 网卡，性能弱于 virtio；Linux 用 virtio。 */
                if (this.isX86Board()) {
                  Column({ space: sp1 }) {
                    Row({ space: sp3 }) {
                      Text('网卡型号').fontSize(tLabel).layoutWeight(1)
                      Chip({ label: 'virtio', active: this.netModel === 'virtio', onTap: () => { this.netModel = 'virtio'; } })
                      Chip({ label: 'rtl8139', active: this.netModel === 'rtl8139', onTap: () => { this.netModel = 'rtl8139'; } })
                    }.width('100%')
                    Text(this.netModel === 'rtl8139'
                      ? 'Windows 默认'
                      : 'Linux 默认；Windows 需装 virtio-win 驱动')
                      .fontSize(tSub).fontColor(cWeak).width('100%')
                  }.alignItems(HorizontalAlign.Start)                }
              }
            } else {
              /* —— 高级 —— */
              /* 声音（raspi 无模拟声卡禁用） */
              Column({ space: sp1 }) {
                Row() {
                  Text('声音').fontSize(tLabel).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.audio })
                    .enabled(!this.isRaspiBoard())
                    .onChange((v: boolean) => this.audio = v)
                }.width('100%')
                Text('开启后虚拟机里的声音通过设备的扬声器/耳机播放').fontSize(tSub).fontColor(cWeak)
                  .width('100%')
              }

              /* v4 系统增强：RNG/balloon（raspi 无 PCI 禁用） */
              Column({ space: sp1 }) {
                Row() {
                  Text('随机数 (RNG)').fontSize(tLabel).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.rng })
                    .enabled(!this.isRaspiBoard())
                    .onChange((v: boolean) => this.rng = v)
                }.width('100%')
                Text('给虚拟机提供随机数来源，可加快部分系统的启动；默认关闭即可').fontSize(tSub).fontColor(cWeak)
                  .width('100%')
              }
              Column({ space: sp1 }) {
                Row() {
                  Text('内存回收 (Balloon)').fontSize(tLabel).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.balloon })
                    .enabled(!this.isRaspiBoard())
                    .onChange((v: boolean) => this.balloon = v)
                }.width('100%')
                Text('虚拟机空闲时归还部分内存给设备；一般无需开启').fontSize(tSub).fontColor(cWeak)
                  .width('100%')
              }
              /* v6：GDB 调试后端（开机后可连 `gdb target remote :端口`） */
              Column({ space: sp1 }) {
                Row() {
                  Text('GDB 调试').fontSize(tLabel).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.gdbOn })
                    .onChange((v: boolean) => this.gdbOn = v)
                }.width('100%')
                if (this.gdbOn) {
                  Row() {
                    Text('监听端口').fontSize(tLabel).width(96)
                    TextInput({ text: this.gdbPortText })
                      .layoutWeight(1)
                      .fontSize(tItem)
                      .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                      .onChange((v: string) => this.gdbPortText = v)
                  }.width('100%')
                  Text('在电脑上执行 gdb，连接 target remote :' + this.gdbPortText).fontSize(tSub).fontColor(cWeak)
                    .width('100%')
                }
              }
              Column({ space: sp1 }) {
                Row() {
                  Text('RTC 本地时区').fontSize(tLabel).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.rtcLocal })
                    .onChange((v: boolean) => this.rtcLocal = v)
                }.width('100%')
                Text('虚拟机内的时钟跟随设备时区显示，Windows 虚拟机建议开启').fontSize(tSub).fontColor(cWeak)
                  .width('100%')
              }

              /* 内核引导：已配 kernel 时展示文件名 + 可编辑的内核参数（-append）。
               * kernel/initrd 文件本身创建后不可更换（重建 VM 走向导） */
              if (this.hasKernel()) {
                Column({ space: sp1 }) {
                  Text('内核引导').fontSize(tLabel)
                  Text(this.kernelLabel()).fontSize(tSub).fontColor(cWeak)
                  TextInput({ text: this.kernelAppend, placeholder: '内核参数，如 console=tty0 console=ttyS0 root=/dev/vda' })
                    .fontSize(tItem)
                    .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                    .onChange((v: string) => this.kernelAppend = v)
                }.alignItems(HorizontalAlign.Start).width('100%')              }

              Column({ space: sp1 }) {
                Text('自定义 QEMU 参数').fontSize(tLabel)
                Text('追加到命令行末尾').fontSize(tSub).fontColor(cWeak)
                TextArea({ placeholder: '如 -device usb-kbd', text: this.extraArgs })
                  .fontSize(tItem)
                  .height(108).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                  .onChange((v: string) => this.extraArgs = v)
              }.alignItems(HorizontalAlign.Start)            }
          }
          .width('100%')
          /* Column 默认水平居中：占满宽度的行看不出来，自适应宽度的说明文字
           * 会悬在中间，表单区一律左对齐 */
          .alignItems(HorizontalAlign.Start)
          .padding({ left: sp5, right: sp5, top: sp4, bottom: sp4 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)

      /* 底部操作条：常驻卡底（不再随内容滚动消失） */
      Row({ space: sp3 }) {
        Blank()
        Button('取消').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
          .backgroundColor(Color.Transparent)
          .fontColor(cPrimary)
          .onClick(() => this.requestCancel())
        Button('保存').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp4, right: sp4 })
          .backgroundColor(cPrimary)
          .fontColor(Color.White)
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: sp5, right: sp5, top: sp2, bottom: sp3 })
      .border({ width: { top: bw }, color: { top: cBorder } })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cCard)
  }
}
