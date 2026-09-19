// 虚拟机配置页：普通字段 + 高级折叠区（TCG/自定义参数）。
// 只编辑 VmProfile JSON，保存后由列表页/console 窗口消费。
import { promptAction } from '@kit.ArkUI';
import napiModule from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { VmProfile, VmStore, VmArch, VgaType, VmDisk, DiskIface, NetModel, SCHEMA_VERSION, fitBoard, fitVga, builtinIsoFor, forwardErrors, mainDiskPath } from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { isoReadable } from '../lib/fsutil';
import { pickIsoPath } from '../lib/isoPick';
import { cPrimary, cDanger, cRunning, cSub, cWeak, cBg, cBorder, cText, cChip, tPage, tLabel, tBody, tSub, tMono, rBtn, rBadge, btnSh, inpH, inpBg, inpRadius, inpPadX, sp1, sp2, sp3, sp5, sp8, spCard } from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
  diskInfo: (path: string) => string;
}

const napi = napiModule as DiskNapi;

const GB = 1024 * 1024 * 1024;

@Component
export struct VmEdit {
  profile: VmProfile | null = null; /* 由导航参数传入；就地编辑副本 */
  @Consume('navStack') navStack: NavPathStack;
  @Consume('showStorage') showStorage: boolean; /* 存储弹窗全窗口开关（Index @Provide） */
  @Consume('storageParam') storageParam: VmProfile | null;
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

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
  @State mttcg: boolean = true;
  @State tbSizeText: string = '1024';
  @State extraArgs: string = '';
  @State kernelAppend: string = ''; /* 内核参数（-append）；仅当 VM 已配 kernel 时展示可编辑 */
  /* v4：显卡/系统增强/只读与第二盘 */
  @State vga: VgaType = 'std';
  @State rng: boolean = false;
  @State balloon: boolean = false;
  @State diskReadonly: boolean = false;
  @State diskIface: DiskIface = 'virtio'; /* 系统盘接口；数据盘继承它（存储弹窗创建时已定） */
  @State diskUnsafeCache: boolean = false; /* 系统盘 cache=unsafe（安装期提速，见 VmDisk 注释） */
  @State netModel: NetModel = 'virtio';
  @State serialInteractive: boolean = true;
  @State extraDisks: VmDisk[] = []; /* 数据盘（disks[1..]，第 0 张为系统盘走 diskPath） */
  /* v6：声音 / GDB 调试后端 / CPU 关联增强（flags+RTC 本地时区） */
  @State audio: boolean = true;
  @State gdbOn: boolean = false;
  @State gdbPortText: string = '1234';
  @State cpuFlags: string = '';
  @State rtcLocal: boolean = false;
  @State showAdvanced: boolean = false;
  @State ensureIsoLoading: boolean = false; /* 内置 Alpine ISO 下载中 */
  @State isoPct: number = 0;
  /* 已建系统盘的元信息（qemu-img info），直接在「系统盘」行内展示 */
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;

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
    this.mttcg = p.runtime.mttcg;
    this.tbSizeText = String(p.runtime.tbSize);
    this.extraArgs = p.extraArgs;
    this.kernelAppend = p.media.kernelAppend;
    this.vga = p.machine.vga;
    this.rng = p.runtime.rng;
    this.balloon = p.runtime.balloon;
    this.diskReadonly = p.media.disks.length > 0 ? p.media.disks[0].readonly : false;
    this.diskIface = p.media.disks.length > 0 ? p.media.disks[0].iface : 'virtio';
    this.diskUnsafeCache = p.media.disks.length > 0 && p.media.disks[0].cache === 'unsafe';
    this.netModel = p.net.model;
    this.serialInteractive = p.machine.serialInteractive;
    this.extraDisks = p.media.disks.slice(1);
    /* v6 */
    this.audio = p.runtime.audio;
    this.gdbOn = p.runtime.gdbPort > 0;
    this.gdbPortText = String(p.runtime.gdbPort > 0 ? p.runtime.gdbPort : 1234);
    this.cpuFlags = p.machine.cpuFlags;
    this.rtcLocal = p.machine.rtcLocal;
    this.readDiskMeta();
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

  /* v4 板卡判定（编辑页只读展示，按 fitBoard 对齐构建行为） */
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
    /* 保存前静态校验：拦下明显无效的组合，避免落盘后启动才暴露（与向导 calcError 对齐） */
    const verr = this.saveError();
    if (verr.length > 0) {
      promptAction.showToast({ message: verr });
      return;
    }
    /* 保存基线从磁盘重读：本页与存储页各持内存副本（@Prop 深拷贝），谁后保存
     * 谁整份覆盖——若从页面副本整份落盘，存储页刚做的数据盘增删/光盘挂载会被
     * 本页的旧值回滚。磁盘段的盘路径/增删不归本页管，以磁盘最新档为准，
     * 本页只合并系统盘三个属性与数据盘只读开关（见 mergeDisks）。load 失败才回退副本。 */
    const base = new VmStore(this.filesDir).load(this.profile.id) ?? this.profile;
    const tbSize = Number(this.tbSizeText);
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
        cpuFlags: this.cpuFlags.trim(),
        rtcLocal: this.rtcLocal,
      },
      runtime: {
        memoryMB: Math.round(this.memoryMB),
        cpus: Math.round(this.cpus),
        mttcg: this.mttcg,
        tbSize: Number.isInteger(tbSize) && tbSize > 0 ? tbSize : 1024,
        rng: this.rng,
        balloon: this.balloon,
        audio: this.audio,
        gdbPort: this.gdbOn ? Number(this.gdbPortText) : 0,
      },
      media: {
        disks: this.mergeDisks(base),
        cdromPaths: this.cdromPaths,
        bootFromCdrom: this.bootFromCdrom,
        /* kernel/initrd 本页无更换入口，原样透传；kernelAppend 由上方输入框编辑 */
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
    this.navStack.pop();
  }

  /* 磁盘段合并：路径与数据盘增删归存储页（以 base 最新档为准），本页只写
   * 系统盘的 只读/接口/缓存 三属性 + 数据盘的只读开关（按位对齐，存储页增删
   * 过的盘以 base 为准，表单里多出的陈旧项丢弃）。 */
  private mergeDisks(base: VmProfile): VmDisk[] {
    const first: VmDisk = base.media.disks.length > 0
      ? {
        path: base.media.disks[0].path,
        readonly: this.diskReadonly,
        iface: this.diskIface,
        cache: this.diskUnsafeCache ? 'unsafe' : undefined,
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

  /* 分组标题 + 分割线（与 VmWizard groupHeader / VmManage secHead 同款：灰字在左，细线延伸至右） */
  @Builder
  groupHead(label: string) {
    Row({ space: sp8 }) {
      Text(label).fontSize(tLabel).fontColor(cSub)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp2 })
  }

  /* 高级折叠组头：点击展开/收起。标题+展开提示合成同一 Text 的 Span（单行盒排版），
   * 避免 ▸/▾ 符号与文字字体度量不同而垂直错位——同 VmWizard 折叠组头手法 */
  @Builder
  groupHeadAdvanced() {
    Row({ space: sp8 }) {
      Text() {
        Span('高级').fontColor(cSub)
        Span(this.showAdvanced ? ' ▾ 收起' : ' ▸ 展开').fontColor(cWeak).fontSize(tSub)
      }
      .fontSize(tLabel)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp2 })
    .onClick(() => this.showAdvanced = !this.showAdvanced)
  }

  build() {
    Column() {
      Row() {
        Button('取消').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .backgroundColor(Color.Transparent)
          .fontColor(cPrimary)
          .onClick(() => this.navStack.pop())
        Blank()
        Text('虚拟机配置').fontSize(tPage).fontWeight(FontWeight.Medium)
        Blank()
        Button('保存').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .backgroundColor(Color.Transparent)
          .fontColor(cPrimary)
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: sp8, right: sp8, top: sp8, bottom: sp8 })

      Scroll() {
        Column() {
          /* —— 基础 —— */
          this.groupHead('基础')

          Row() {
            Text('名称').fontSize(tLabel).width(72)
            TextInput({ text: this.name })
              .layoutWeight(1)
              .fontSize(tBody)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
              .onChange((v: string) => this.name = v)
          }.padding({ top: sp1, bottom: sp1 })

          Row() {
            Text('架构').fontSize(tLabel).width(72)
            Text(this.arch)
              .fontSize(tBody)
              .fontColor(cSub)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).layoutWeight(1)
              .padding({ left: inpPadX, right: inpPadX })
              .textAlign(TextAlign.Start)
          }.padding({ top: sp1, bottom: sp1 })

          Row({ space: 4 }) {
            Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(tLabel)
              .width(120)
            Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
              .onChange((v: number) => this.cpus = v)
              .layoutWeight(1)
          }.alignItems(VerticalAlign.Center).padding({ top: spCard, bottom: spCard })

          Row() {
            Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(tLabel)
              .width(120)
            Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
              .onChange((v: number) => this.memoryMB = v)
              .layoutWeight(1)
          }.alignItems(VerticalAlign.Center).padding({ top: spCard, bottom: spCard })

          /* v4 显卡：x86 板卡可换；virt/raspi 固定（说明行） */
          Row({ space: sp2 }) {
            Text('显卡').fontSize(tLabel).width(72)
            if (this.isX86Board()) {
              Row({ space: sp2 }) {
                ForEach(['std', 'cirrus', 'vmware', 'virtio'], (g: string) => {
                  Text(g).fontSize(tSub)
                    .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
                    .fontColor(this.vga === g ? Color.White : cText)
                    .backgroundColor(this.vga === g ? cPrimary : cBg)
                    .borderRadius(rBtn)
                    .onClick(() => { this.vga = g as VgaType; })
                }, (g: string) => g)
              }
            } else {
              Text(this.isRaspiBoard() ? '板载（固定）' : 'virtio-gpu（固定）')
                .fontSize(tSub).fontColor(cSub).layoutWeight(1)
            }
          }.width('100%').padding({ top: sp1, bottom: sp1 })

          /* —— 存储 —— */
          this.groupHead('存储')

          Column({ space: sp1 }) {
            Row() {
              Text('系统盘').fontSize(tLabel).width(72)
              Column({ space: 2 }) {
                Text(this.baseName(this.diskPath))
                  .fontSize(tSub)
                  .fontColor(cSub)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`)
                  .fontSize(tMono)
                  .fontColor(cWeak)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('存储管理').focusable(false).fontSize(tBody)
                .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                .backgroundColor(Color.Transparent).fontColor(cPrimary)
                .onClick(() => {
                  const p = this.profile;
                  if (p) {
                    this.storageParam = p;
                    this.showStorage = true;
                  }
                })
            }
          }.alignItems(HorizontalAlign.Start).padding({ top: spCard, bottom: spCard })

          /* v5：系统盘只读 + 数据盘列表（创建/导入/移除/扩容在存储弹窗） */
          Row() {
            Text('系统盘只读').fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.diskReadonly })
              .onChange((v: boolean) => this.diskReadonly = v)
          }.padding({ top: sp1, bottom: sp1 })
          Text('开启后防系统盘误写；扩容、快照等管理操作不受影响').fontSize(tSub).fontColor(cWeak).width('100%')

          /* 磁盘接口（仅 x86 板卡有 IDE 南桥）：切换只影响 -drive if= 的挂载方式，
           * 盘内容不动——Windows VM 若误建为 virtio，切到 ide 即可被安装程序识别。 */
          if (this.isX86Board()) {
            Row({ space: sp2 }) {
              Text('磁盘接口').fontSize(tLabel).layoutWeight(1)
              Text('virtio').fontSize(tBody)
                .fontColor(this.diskIface === 'virtio' ? Color.White : cSub)
                .backgroundColor(this.diskIface === 'virtio' ? cPrimary : cChip)
                .borderRadius(rBadge)
                .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
                .onClick(() => { this.diskIface = 'virtio' })
              Text('ide（Windows）').fontSize(tBody)
                .fontColor(this.diskIface === 'ide' ? Color.White : cSub)
                .backgroundColor(this.diskIface === 'ide' ? cPrimary : cChip)
                .borderRadius(rBadge)
                .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
                .onClick(() => { this.diskIface = 'ide' })
            }.width('100%').padding({ top: sp1, bottom: sp1 })
            Text(this.diskIface === 'ide'
              ? 'XP/Win7 开箱即认；ide 槽位有限（数据盘上限随之收紧）'
              : 'Linux 默认；性能最好但需 guest 驱动（Windows 安装程序不认）')
              .fontSize(tSub).fontColor(cWeak).width('100%')

            /* cache=unsafe：老系统安装期提速开关（机理见 VmDisk.cache 注释） */
            Row() {
              Text('放松写入缓存 (unsafe)').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.diskUnsafeCache })
                .onChange((v: boolean) => this.diskUnsafeCache = v)
            }.width('100%').padding({ top: sp1, bottom: sp1 })
            Text(this.diskUnsafeCache
              ? '忽略客户机刷盘请求，安装系统期间明显提速；宿主/App 崩溃时磁盘可能损坏，装完建议关闭'
              : '默认：客户机刷盘即刻落盘（最安全）')
              .fontSize(tSub).fontColor(cWeak).width('100%')
          }

          Column({ space: sp1 }) {
            Row() {
              Text('数据盘').fontSize(tLabel).width(72)
              Text(this.extraDisks.length === 0 ? '未配置' : `${this.extraDisks.length} 张`)
                .fontSize(tSub).fontColor(cSub).layoutWeight(1)
              Button('存储管理').focusable(false).fontSize(tBody)
                .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
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
              Row({ space: sp2 }) {
                Text(this.baseName(d.path))
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
              }.width('100%').padding({ top: sp1, bottom: sp1 })
            }, (d: VmDisk) => d.path)
            Text('快照仅含系统盘，数据盘不参与').fontSize(tSub).fontColor(cWeak).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: spCard, bottom: spCard })

          Column({ space: sp1 }) {
            Text('光盘 ISO').fontSize(tLabel)
            if (this.cdromPaths.length > 0) {
              ForEach(this.cdromPaths, (p: string, idx: number) => {
                Row({ space: sp2 }) {
                  Text(idx === 0 ? `${this.baseName(p)}（启动盘）` : this.baseName(p))
                    .fontSize(tSub)
                    .fontColor(idx === 0 ? cPrimary : cSub)
                    .layoutWeight(1)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Button('移除').focusable(false).fontSize(tBody)
                    .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                    .backgroundColor(Color.Transparent).fontColor(cDanger)
                    .onClick(() => this.removeIso(idx))
                }
                .width('100%')
              }, (p: string, idx: number) => `${idx}:${p}`)
            } else {
              Text('无').fontSize(tSub).fontColor(cSub)
            }
            Row({ space: sp2 }) {
              Button('选择文件').focusable(false).fontSize(tBody)
                .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                .backgroundColor(Color.Transparent).fontColor(cPrimary)
                .onClick(() => this.pickLocalIso())
              Button(this.ensureIsoLoading ? `内置下载 ${this.isoPct}%` : `内置 Alpine (${this.arch})`)
                .focusable(false).fontSize(tBody)
                .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                .enabled(!this.ensureIsoLoading)
                .onClick(() => this.pickBuiltinIso())
            }
          }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: spCard, bottom: spCard })

          Row() {
            Text(this.hasKernel() ? '从光盘启动（内核引导时无效）' : '从光盘启动')
              .fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
              .enabled(!this.hasKernel())
              .onChange((v: boolean) => this.bootFromCdrom = v)
          }.padding({ top: sp1, bottom: sp1 })

          /* 内核引导：已配 kernel 时展示文件名 + 可编辑的内核参数（-append）。
           * kernel/initrd 文件本身创建后不可更换（重建 VM 走向导） */
          if (this.hasKernel()) {
            Column({ space: 4 }) {
              Text('内核引导').fontSize(tLabel)
              Text(this.kernelLabel()).fontSize(tSub).fontColor(cWeak)
              TextInput({ text: this.kernelAppend, placeholder: '内核参数，如 console=tty0 console=ttyS0 root=/dev/vda' })
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.kernelAppend = v)
            }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: spCard, bottom: spCard })
          }

          /* —— 网络 —— */
          this.groupHead('网络')

          Row() {
            Text('启用网络').fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
              .onChange((v: boolean) => this.netEnabled = v)
          }.padding({ top: sp1, bottom: sp1 })

          if (this.netEnabled) {
            Column({ space: 4 }) {
              Text('端口映射').fontSize(tLabel)
              Text('宿主端口:客机端口，逗号分隔').fontSize(tSub).fontColor(cWeak)
              TextInput({ placeholder: '如 2222:22,8080:80', text: this.portForwards })
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.portForwards = v)
            }.alignItems(HorizontalAlign.Start).padding({ top: spCard, bottom: spCard })
            Column({ space: 4 }) {
              Row() {
                Text('共享目录').fontSize(tLabel).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.sharedFolder })
                  .onChange((v: boolean) => this.sharedFolder = v)
              }.padding({ left: 0, right: 0 })
              Text('挂载宿主 Download/ 到客机 /shared（9p）').fontSize(tSub).fontColor(cWeak)
            }.alignItems(HorizontalAlign.Start).padding({ top: spCard, bottom: spCard })
            /* 网卡型号（仅 x86 板卡可切）：rtl8139 是 XP/Win7 唯一双 in-box 驱动的
             * 网卡，性能弱于 virtio；Linux 用 virtio。 */
            if (this.isX86Board()) {
              Column({ space: 4 }) {
                Row({ space: sp2 }) {
                  Text('网卡型号').fontSize(tLabel).layoutWeight(1)
                  Text('virtio').fontSize(tBody)
                    .fontColor(this.netModel === 'virtio' ? Color.White : cSub)
                    .backgroundColor(this.netModel === 'virtio' ? cPrimary : cChip)
                    .borderRadius(rBadge)
                    .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
                    .onClick(() => { this.netModel = 'virtio' })
                  Text('rtl8139').fontSize(tBody)
                    .fontColor(this.netModel === 'rtl8139' ? Color.White : cSub)
                    .backgroundColor(this.netModel === 'rtl8139' ? cPrimary : cChip)
                    .borderRadius(rBadge)
                    .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
                    .onClick(() => { this.netModel = 'rtl8139' })
                }.width('100%')
                Text(this.netModel === 'rtl8139'
                  ? 'Windows 开箱即认（XP/Win7 内置驱动）'
                  : 'Linux 默认；Windows 需装 virtio-win 驱动')
                  .fontSize(tSub).fontColor(cWeak).width('100%')
              }.alignItems(HorizontalAlign.Start).padding({ top: spCard, bottom: spCard })
            }
          }

          /* —— 高级（折叠组头） —— */
          this.groupHeadAdvanced()
          if (this.showAdvanced) {
            Row() {
              Text('TCG 多线程 (MTTCG)').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.mttcg })
                .onChange((v: boolean) => this.mttcg = v)
            }.padding({ top: sp1, bottom: sp1 })
            Row() {
              Text('tb-size').fontSize(tLabel).width(96)
              TextInput({ text: this.tbSizeText })
                .layoutWeight(1)
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.tbSizeText = v)
            }.padding({ bottom: sp1 })
            /* v4 系统增强：RNG/balloon（raspi 无 PCI 禁用） */
            Row() {
              Text('随机数 (RNG)').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.rng })
                .enabled(!this.isRaspiBoard())
                .onChange((v: boolean) => this.rng = v)
            }.padding({ top: sp1, bottom: sp1 })
            Row() {
              Text('内存回收 (Balloon)').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.balloon })
                .enabled(!this.isRaspiBoard())
                .onChange((v: boolean) => this.balloon = v)
            }.padding({ top: sp1, bottom: sp1 })
            /* v6：声音（raspi 无模拟声卡禁用；向导建 VM 默认开，历史开机开关在此） */
            Row() {
              Text('声音').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.audio })
                .enabled(!this.isRaspiBoard())
                .onChange((v: boolean) => this.audio = v)
            }.padding({ top: sp1, bottom: sp1 })
            /* v6：GDB 调试后端（开机后可连 `gdb target remote :端口`）。仅编辑页提供，
             * 窗口底部引导文案提示用法 */
            Row() {
              Text('GDB 调试').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.gdbOn })
                .onChange((v: boolean) => this.gdbOn = v)
            }.padding({ top: sp1, bottom: sp1 })
            if (this.gdbOn) {
              Row() {
                Text('监听端口').fontSize(tLabel).width(96)
                TextInput({ text: this.gdbPortText })
                  .layoutWeight(1)
                  .fontSize(tBody)
                  .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                  .onChange((v: string) => this.gdbPortText = v)
              }.padding({ bottom: sp1 })
              Text('host 侧执行：gdb 后 target remote :' + this.gdbPortText).fontSize(tSub).fontColor(cWeak)
                .padding({ bottom: sp1 })
            }
            /* v6：CPU 关联增强——flags 字符串与 CPU 模型合并（raspi 固定 CPU 禁用） */
            Row() {
              Text('CPU 关联').fontSize(tLabel).width(96)
              TextInput({ text: this.cpuFlags, placeholder: '如 +sse4a,-avx2' })
                .layoutWeight(1)
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .enabled(!this.isRaspiBoard())
                .onChange((v: string) => this.cpuFlags = v)
            }.padding({ bottom: sp1 })
            Text('追加到 -cpu 模型之后；留空不生成参数').fontSize(tSub).fontColor(cWeak)
              .padding({ bottom: sp1 })
            Row() {
              Text('RTC 本地时区').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.rtcLocal })
                .onChange((v: boolean) => this.rtcLocal = v)
            }.padding({ top: sp1, bottom: sp1 })
            Text('guest 时钟随宿主时区显示（-rtc base=localtime）').fontSize(tSub).fontColor(cWeak)
              .padding({ bottom: sp1 })
            Column({ space: 4 }) {
              Text('自定义 QEMU 参数').fontSize(tLabel)
              Text('追加到命令行末尾').fontSize(tSub).fontColor(cWeak)
              TextArea({ placeholder: '如 -device usb-kbd', text: this.extraArgs })
                .fontSize(tBody)
                .height(108).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.extraArgs = v)
            }.alignItems(HorizontalAlign.Start).padding({ top: spCard, bottom: spCard })
          }
        }
        .width('100%')
        .padding({ left: sp3, right: sp3, bottom: sp5 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cBg)
  }
}
