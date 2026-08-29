// 虚拟机配置页：普通字段 + 高级折叠区（TCG/自定义参数）。
// 只编辑 VmProfile JSON，保存后由列表页/console 窗口消费。
import { promptAction } from '@kit.ArkUI';
import napiModule from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { VmProfile, VmStore, VmArch, SCHEMA_VERSION, fitBoard, builtinIsoFor, forwardErrors } from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pathExists } from '../lib/fsutil';
import { pickIsoPath } from '../lib/isoPick';
import { cPrimary, cDanger, cRunning, cSub, cWeak, cBg, cBorder, tPage, tLabel, tBody, tSub, tMono, rBtn, btnSh, inpH, inpBg, inpRadius, inpPadX, sp1, sp2, sp3, sp5, sp8, spCard } from '../lib/uiTokens';

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
  @State cdromPath: string = '';
  @State bootFromCdrom: boolean = false;
  @State netEnabled: boolean = true;
  @State portForwards: string = '';
  @State sharedFolder: boolean = false;
  @State mttcg: boolean = true;
  @State tbSizeText: string = '1024';
  @State extraArgs: string = '';
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
    this.diskPath = p.media.diskPath;
    this.cdromPath = p.media.cdromPath;
    this.bootFromCdrom = p.media.bootFromCdrom;
    this.netEnabled = p.net.enabled;
    this.portForwards = p.net.portForwards;
    this.sharedFolder = p.net.sharedFolder;
    this.mttcg = p.runtime.mttcg;
    this.tbSizeText = String(p.runtime.tbSize);
    this.extraArgs = p.extraArgs;
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
        this.cdromPath = this.vmDataDir + '/' + name;
        this.bootFromCdrom = true;
      } else {
        promptAction.showToast({ message: '内置 ISO 下载失败' });
      }
    });
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
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
      this.cdromPath = p;
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

  /* 保存前静态校验：返回第一条错误描述（'' = 通过）。覆盖「从光盘启动但未指定 ISO」、
   * 端口转发格式、ISO 路径存在性。cpuModel 编辑页无入口、tb-size 有整数兜底，交由向导
   * 与构建时拦；自定义 qemu 参数(extraArgs)与资源型错误无法静态判定，由启动失败时的
   * qemu.log 透出（VmConsole）。 */
  private saveError(): string {
    if (this.bootFromCdrom && this.cdromPath.trim().length === 0) {
      return '从光盘启动需先指定 ISO';
    }
    if (this.cdromPath.trim().length > 0 && !pathExists(this.cdromPath.trim())) {
      return 'ISO 路径不存在';
    }
    if (this.netEnabled && this.portForwards.trim().length > 0) {
      const errs = forwardErrors(this.portForwards);
      if (errs.length > 0) { return '端口转发：' + errs.join('；'); }
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
    /* 系统盘必配（由向导/编辑流程保证）：配置直接使用既有盘路径，不在保存侧再建盘 */
    const tbSize = Number(this.tbSizeText);
    const p: VmProfile = {
      schemaVersion: SCHEMA_VERSION,
      id: this.profile.id,
      name: this.name.trim().length > 0 ? this.name.trim() : '未命名',
      machine: {
        arch: this.arch,
        vga: this.profile.machine.vga,
        machine: fitBoard(this.arch, this.profile.machine.machine),
        firmware: this.profile.machine.firmware,
        cpuModel: this.profile.machine.cpuModel,
      },
      runtime: {
        memoryMB: Math.round(this.memoryMB),
        cpus: Math.round(this.cpus),
        mttcg: this.mttcg,
        tbSize: Number.isInteger(tbSize) && tbSize > 0 ? tbSize : 1024,
      },
      media: {
        diskPath: this.diskPath,
        cdromPath: this.cdromPath.trim(),
        bootFromCdrom: this.bootFromCdrom,
      },
      net: {
        enabled: this.netEnabled,
        portForwards: this.portForwards.trim(),
        sharedFolder: this.sharedFolder,
      },
      temporarySession: this.profile.temporarySession,
      extraArgs: this.extraArgs.trim(),
    };
    new VmStore(this.filesDir).save(p);
    this.vmListVersion++;
    promptAction.showToast({ message: '已保存' });
    this.navStack.pop();
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

          Column({ space: sp1 }) {
            Row() {
              Text('光盘 ISO').fontSize(tLabel).width(72)
              Text(this.cdromPath ? this.baseName(this.cdromPath) : '无')
                .fontSize(tSub)
                .fontColor(cSub)
                .layoutWeight(1)
              if (this.cdromPath) {
                Button('移除').focusable(false).fontSize(tBody)
                  .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                  .backgroundColor(Color.Transparent).fontColor(cDanger)
                  .onClick(() => this.cdromPath = '')
              }
            }
            if (!this.cdromPath) {
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
            }
          }.alignItems(HorizontalAlign.Start).padding({ top: spCard, bottom: spCard })

          Row() {
            Text('从光盘启动').fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
              .onChange((v: boolean) => this.bootFromCdrom = v)
          }.padding({ top: sp1, bottom: sp1 })

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
