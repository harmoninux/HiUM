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
import { Chip, FieldRow, ValueRow, ToggleRow, ChipRow, SliderRow, InfoRow } from '../lib/uiWidgets';
import { PortForwardEditor } from '../lib/PortForwardEditor';
import { cPrimary, cDanger, cSub, cWeak, cBg, cCard, cBorder, cText, tCard, tLabel, tBody, tItem, tSub, tMono, rBtn, bw, btnSh, btnRow, inpH, inpBg, inpRadius, inpPadX, sp1, sp2, sp3, sp4, sp5, sp6 } from '../lib/uiTokens';

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
  @State pfIncomplete: number = 0; /* 端口转发半行数（PortForwardEditor 上报，保存校验用） */
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
      this.netEnabled, this.portForwards, this.pfIncomplete, this.sharedFolder, this.netModel,
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
      promptAction.showToast({ message: '该架构暂无内置镜像，可自备 ISO' });
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
        promptAction.showToast({ message: '内置镜像下载失败，请检查网络后重试' });
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
        promptAction.showToast({ message: '未选中文件，或文件无法读取' });
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
        return 'ISO 无法读取或不存在';
      }
    }
    if (this.netEnabled && this.pfIncomplete > 0) {
      return '端口转发有 ' + this.pfIncomplete + ' 行只填了一半，请补全或移除';
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

        /* 右侧内容：一次只渲染当前 Tab。配置项（块）间距收归本容器统一（sp3；
         * 2026-10-11 加宽方案 sp4/半档均被用户否决——维持，勿再调），
         * 行内不再自带上下 padding——否则各行 4/12 随机叠加出行距 8~24 乱跳 */
        Scroll() {
          Column({ space: sp3 }) {
            if (this.tabIdx === 0) {
              /* —— 基础 —— */
              FieldRow({ label: '名称', text: this.name, onChange: (v: string) => { this.name = v; } })
              ValueRow({ label: '架构', value: this.arch })
              SliderRow({ label: 'CPU 核数', value: this.cpus, min: 1, max: 8, step: 1,
                onChange: (v: number) => { this.cpus = v; } })
              SliderRow({ label: '内存', value: this.memoryMB, min: 256, max: 8192, step: 256,
                format: (v: number): string => `${Math.round(v)} MB`,
                onChange: (v: number) => { this.memoryMB = v; } })
              /* v4 显卡：x86 板卡可换（ChipRow）；virt/raspi 固定 → 只读值展示。
               * desc 只对选中项做一句话说明（同向导，2026-10-17 用户定） */
              if (this.isX86Board()) {
                ChipRow({ label: '显卡', options: ['std', 'cirrus', 'vmware', 'virtio'], value: this.vga,
                  desc: this.vga === 'std' ? 'QEMU 默认'
                    : this.vga === 'cirrus' ? 'Win9x/旧 DOS 时代老卡'
                    : this.vga === 'vmware' ? 'XP 以后可装 VMware 驱动加速'
                    : '性能最好，新系统首选',
                  onChange: (v: string) => { this.vga = v as VgaType; } })
              } else {
                ValueRow({ label: '显卡', value: this.isRaspiBoard() ? '板载（固定）' : 'virtio-gpu（固定）' })
              }
            } else if (this.tabIdx === 1) {
              /* —— 存储：容量/重建/数据盘增删在「存储管理」弹窗，此处只做开关与光盘 —— */
              InfoRow({ label: '系统盘', main: this.baseName(this.diskPath),
                sub: `${this.diskFmt} · 容量 ${this.diskVirtualGB.toFixed(1)}G · 已占 ${this.diskActualGB.toFixed(1)}G`,
                actionLabel: '存储管理',
                onAction: () => {
                  const p = this.profile;
                  if (p) {
                    this.storageParam = p;
                    this.showStorage = true;
                  }
                } })
              /* v5：系统盘只读 + 数据盘列表（创建/导入/移除/扩容在存储弹窗） */
              ToggleRow({ label: '系统盘只读', isOn: this.diskReadonly,
                desc: '开启后防系统盘误写；扩容、快照等管理操作不受影响',
                onChange: (v: boolean) => { this.diskReadonly = v; } })

              /* 磁盘接口（仅 x86 板卡有 IDE 南桥）：切换只影响 -drive if= 的挂载方式，
               * 盘内容不动——Windows VM 若误建为 virtio，切到 ide 即可被安装程序识别。 */
              if (this.isX86Board()) {
                ChipRow({ label: '磁盘接口', options: ['virtio', 'ide'], labels: ['virtio', 'IDE'],
                  value: this.diskIface,
                  desc: this.diskIface === 'ide' ? 'Windows 免装驱动即可识别' : '性能更好，Linux 首选；Windows 需另装驱动',
                  onChange: (v: string) => { this.diskIface = v as DiskIface; } })
              }

              InfoRow({ label: '数据盘',
                main: this.extraDisks.length === 0 ? '未配置' : `${this.extraDisks.length} 张`,
                mainDim: this.extraDisks.length === 0,
                actionLabel: '存储管理',
                onAction: () => {
                  const p = this.profile;
                  if (p) {
                    this.storageParam = p;
                    this.showStorage = true;
                  }
                } })
              /* 盘列表只在有盘时出现（未配置时挂一条「快照不含数据盘」注释无从谈起）；
               * 缩进 72 对齐 InfoRow 值列。行内 Toggle 同 ToggleRow 做盒留白补偿 */
              if (this.extraDisks.length > 0) {
                Column({ space: sp1 }) {
                  ForEach(this.extraDisks, (d: VmDisk, idx: number) => {
                    Row({ space: sp3 }) {
                      Text(`数据盘${idx + 1}`)
                        .fontSize(tSub).fontColor(cSub).layoutWeight(1).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(d.iface === 'ide' ? 'IDE' : 'virtio').fontSize(tSub).fontColor(cWeak)
                      Text('只读').fontSize(tSub).fontColor(cSub)
                      Toggle({ type: ToggleType.Switch, isOn: d.readonly })
                        .translate({ y: 2.4 }) /* 同 ToggleRow：盒下沿留白，可见开关偏上 */
                        .onChange((v: boolean) => {
                          const next = this.extraDisks.slice();
                          next[idx] = { path: d.path, readonly: v, iface: d.iface };
                          this.extraDisks = next;
                        })
                    }.width('100%')
                  }, (d: VmDisk) => d.path)
                  Text('快照仅含系统盘，数据盘不参与').fontSize(tSub).fontColor(cWeak).width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding({ left: 72 })
              }
              /* 光盘 ISO 行：整块上下堆叠——标签 / 文件名（通栏，移除落行尾最右，
               * 与上方「存储管理」同一右缘）/ 动作钮一行两个。不放左右两列：挂载态
               * 下移除吊在文件名与右列之间三块脱节（2026-10-17 真机打回）；空态
               * 不渲染「无」占位——两枚动作钮已说明状态（用户定）。 */
              Column({ space: sp1 }) {
                Text('光盘 ISO').fontSize(tLabel)
                if (this.cdromPaths.length > 0) {
                  ForEach(this.cdromPaths, (p: string, idx: number) => {
                    Row({ space: sp3 }) {
                      Text(this.baseName(p))
                        .fontSize(tItem)
                        .fontColor(idx === 0 ? cPrimary : cSub)
                        .layoutWeight(1)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Button('移除').focusable(false).fontSize(tItem)
                        .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                        .backgroundColor(Color.Transparent).fontColor(cDanger)
                        .onClick(() => this.removeIso(idx))
                    }
                    .width('100%')
                  }, (p: string, idx: number) => `${idx}:${p}`)
                }
                /* ui-layout-ok: 动作钮一行两个（用户定稿：水平放置即可） */
                Row({ space: sp3 }) {
                  Button('选择文件').focusable(false).fontSize(tItem)
                    .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                    .backgroundColor(Color.Transparent).fontColor(cPrimary)
                    .onClick(() => this.pickLocalIso())
                  Button(this.ensureIsoLoading ? `下载中 ${this.isoPct}%` : '内置 Alpine')
                    .focusable(false).fontSize(tItem)
                    .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                    .backgroundColor(Color.Transparent).fontColor(cPrimary)
                    .enabled(!this.ensureIsoLoading)
                    .onClick(() => this.pickBuiltinIso())
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              ToggleRow({ label: this.hasKernel() ? '从光盘启动（内核引导时无效）' : '从光盘启动',
                isOn: this.bootFromCdrom, enable: !this.hasKernel(),
                onChange: (v: boolean) => { this.bootFromCdrom = v; } })
            } else if (this.tabIdx === 2) {
              /* —— 网络 —— */
              ToggleRow({ label: '启用网络', isOn: this.netEnabled,
                onChange: (v: boolean) => { this.netEnabled = v; } })
              if (this.netEnabled) {
                Column({ space: sp1 }) {
                  PortForwardEditor({ text: this.$portForwards, incomplete: this.$pfIncomplete })
                }.alignItems(HorizontalAlign.Start)
                /* 共享目录：desc 是超一行的挂载指引，B 形左列换行（开关随整块居中） */
                ToggleRow({ label: '共享目录', isOn: this.sharedFolder,
                  desc: '开启后虚拟机可读写设备的下载目录；需在虚拟机内挂载后使用：mkdir -p /shared && mount -t 9p -o trans=virtio shared /shared',
                  onChange: (v: boolean) => { this.sharedFolder = v; } })
                /* 网卡型号（仅 x86 板卡可切）：rtl8139 是 XP/Win7 唯一双 in-box 驱动的
                 * 网卡，性能弱于 virtio；Linux 用 virtio。 */
                if (this.isX86Board()) {
                  ChipRow({ label: '网卡型号', options: ['virtio', 'rtl8139'], value: this.netModel,
                    desc: this.netModel === 'rtl8139' ? 'Windows 默认' : 'Linux 默认；Windows 需装 virtio-win 驱动',
                    onChange: (v: string) => { this.netModel = v as NetModel; } })
                }
              }
            } else {
              /* —— 高级 —— */
              /* 声音（raspi 无模拟声卡禁用）。自解释项，按注释判据不配 desc（旧说明
               * 是 label 复述，已删——判据制示例） */
              ToggleRow({ label: '声音', isOn: this.audio, enable: !this.isRaspiBoard(),
                onChange: (v: boolean) => { this.audio = v; } })

              /* v4 系统增强：RNG/balloon（raspi 无 PCI 禁用）。术语项，判据1 配 desc */
              ToggleRow({ label: '随机数发生器 (RNG)', isOn: this.rng, enable: !this.isRaspiBoard(),
                desc: '为虚拟机提供随机数来源，加密等功能就绪更快；一般无需开启',
                onChange: (v: boolean) => { this.rng = v; } })
              ToggleRow({ label: '内存回收 (Balloon)', isOn: this.balloon, enable: !this.isRaspiBoard(),
                desc: '虚拟机空闲时归还部分内存给设备；一般无需开启',
                onChange: (v: boolean) => { this.balloon = v; } })
              /* v6：GDB 调试后端。连接指引挂在开关行左堆叠（desc 一律在标签侧）；
               * 监听端口是纯输入行（FieldRow 不设 desc） */
              ToggleRow({ label: 'GDB 调试', isOn: this.gdbOn,
                desc: '在电脑上连接需先做端口转发：hdc fport tcp:' + this.gdbPortText + ' tcp:' + this.gdbPortText + '；然后在 GDB 里执行 target remote :' + this.gdbPortText,
                onChange: (v: boolean) => { this.gdbOn = v; } })
              if (this.gdbOn) {
                FieldRow({ label: '监听端口', text: this.gdbPortText,
                  onChange: (v: string) => { this.gdbPortText = v; } })
              }
              ToggleRow({ label: 'RTC 本地时区', isOn: this.rtcLocal,
                desc: '虚拟机内的时钟跟随设备时区显示，Windows 虚拟机建议开启',
                onChange: (v: boolean) => { this.rtcLocal = v; } })

              /* 内核引导：已配 kernel 时展示文件名 + 可编辑的内核参数（-append）。
               * kernel/initrd 文件本身创建后不可更换（重建 VM 走向导） */
              if (this.hasKernel()) {
                Column({ space: sp1 }) {
                  Text('内核引导').fontSize(tLabel)
                  Text(this.kernelLabel()).fontSize(tSub).fontColor(cWeak)
                  TextInput({ text: this.kernelAppend, placeholder: '内核参数，如 console=tty0 console=ttyS0 root=/dev/vda' })
                    .fontSize(tItem)
                    .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX, top: sp1, bottom: sp1 })
                    .onChange((v: string) => this.kernelAppend = v)
                }.alignItems(HorizontalAlign.Start).width('100%')              }

              Column({ space: sp1 }) {
                Text('自定义 QEMU 参数').fontSize(tLabel)
                TextArea({ placeholder: '如 -device usb-kbd', text: this.extraArgs })
                  .fontSize(tItem)
                  .height(108).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX, top: sp1, bottom: sp1 })
                  .onChange((v: string) => this.extraArgs = v)
                Text('追加到命令行末尾').fontSize(tSub).fontColor(cWeak)
              }.alignItems(HorizontalAlign.Start)            }
          }
          .width('100%')
          /* Column 默认水平居中：占满宽度的行看不出来，自适应宽度的说明文字
           * 会悬在中间，表单区一律左对齐 */
          .alignItems(HorizontalAlign.Start)
          .padding({ left: sp5, right: sp5, top: sp2, bottom: sp2 })
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
