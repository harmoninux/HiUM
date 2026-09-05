// 单台虚拟机的管理页（per-VM）：分区滚动 —— 概览 chips + 系统盘 / 快照·时光机 / 网络 / 高级。
// 快照归属单台 VM，不进跨 VM 的库；临时会话打点/回滚见 lib/tempSession。
// 从列表侧栏点行进（Navigation replace 渲染到 content/detail 区）；成功反馈走右下角 snackbar。
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore, buildArgs, sharedDir, qmpSockPath } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import {
  VmSnapshotEntry, snapshotApply, snapshotDelete, parseSnapshots,
} from '../lib/vmsnapshot';
import { isTempSnapshot } from '../lib/tempSession';
import {
  cPrimary, cDanger, cRunning, cSuccess, cText, cSub, cWeak,
  cCard, cBlock, cChip, cBorder,
  tCard, tLabel, tBody, tSub, tSubL, tMono,
  sp1, sp2, sp3, sp4, sp5, sp8, rElem, rBadge, rBtn, btnH, btnSh, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  diskInfo: (path: string) => string;
  qmpConnect: (vmId: string, sockPath: string) => number;
  qmpCommand: (vmId: string, cmd: string) => string;
}

const napi = napiModule as DiskNapi;
const GB = 1024 * 1024 * 1024;

@Component
export struct VmManage {
  profile: VmProfile | null = null; /* 由导航参数传入 */
  @Consume('navStack') navStack: NavPathStack;
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('vmListVersion') @Watch('onVmListChanged') vmListVersion: number = 0;
  /* 运行态权威源（侧栏每 2s 刷新）。build 里经 isRunningNow() 直接读本字段：
   * runningMap 变化 → 组件（框架强保证）重绘 → 按钮/徽标拿到最新 running。
   * 不走 @State 中转——@State 在异步事件回调里赋值不驱动本次重绘，会停留旧值。 */
  @StorageLink('runningMap') runningMap: Record<string, Object> = {};

  @State name: string = '';
  @State arch: string = '';
  @State diskPath: string = '';
  @State cdromPaths: string[] = [];
  @State bootFromCdrom: boolean = false;
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;
  @State snapshots: VmSnapshotEntry[] = [];
  @State netEnabled: boolean = false;
  @State snack: string = '';
  @State nowSec: number = 0; /* 进入页面时的时间基准，供「当前」快照节点稳定展示 */
  @State isWide: boolean = false; /* 宽屏(Split)下隐藏返回；getWindowSize 判宽 */
  @Consume('showStorage') showStorage: boolean; /* 存储弹窗开关（Index 全窗口遮罩层） */
  @Consume('storageParam') storageParam: VmProfile | null; /* 当前打开的存储弹窗所属 VM */

  aboutToAppear(): void {
    this.refreshProfile();
  }

  /* 本页 VM 是否运行：build 直接依赖 @StorageLink('runningMap')（响应式），
   * runningMap 每 2s 由 VmList poll 刷新，变化即触发重绘，此处拿到最新值。 */
  private isRunningNow(): boolean {
    const p = this.profile;
    if (!p) {
      return false;
    }
    const st = this.runningMap[p.id];
    if (typeof st === 'undefined') {
      return false;
    }
    const so = st as Record<string, Object>;
    const r = so['running'];
    return typeof r === 'boolean' && r as boolean;
  }

  /* 重读 profile 刷新本页状态。编辑页保存会 bump vmListVersion，@Watch 触发这里：
   * 必须从磁盘 load 最新版（详情页 this.profile 是导航传入的旧引用，编辑页写的是
   * 它自己构建的对象，读引用拿不到新值），让启动盘徽标、磁盘/光盘/网络等跟着更新。 */
  private refreshProfile(): void {
    const nav = this.profile;
    if (!nav) {
      return;
    }
    const fresh = new VmStore(this.filesDir).load(nav.id);
    const p = fresh ?? nav;
    this.profile = p; /* 让后续 isTempSnapshot/canSnapshot 也用最新对象 */
    this.name = p.name;
    this.arch = p.machine.arch;
    this.diskPath = p.media.diskPath;
    this.cdromPaths = p.media.cdromPaths;
    this.bootFromCdrom = p.media.bootFromCdrom;
    this.netEnabled = p.net.enabled;
    this.refreshDisk();
    this.refreshSnapshot();
    this.nowSec = Math.floor(Date.now() / 1000);
  }

  /* 编辑页/存储页保存后 vmListVersion +1：重新读取 profile */
  private onVmListChanged(): void {
    this.refreshProfile();
  }

  /* 右下角 snackbar：成功类反馈走这里，错误类保留 toast */
  private showSnack(msg: string): void {
    this.snack = msg;
    setTimeout(() => {
      if (this.snack === msg) {
        this.snack = '';
      }
    }, 2000);
  }

  private refreshDisk(): void {
    this.diskVirtualGB = 0;
    this.diskActualGB = 0;
    this.diskFmt = '?';
    if (!this.diskPath) {
      return;
    }
    const s = napi.diskInfo(this.diskPath);
    if (s.length === 0) {
      return;
    }
    try {
      /* ArkTS 禁对接口字段下标访问、禁 unknown：用 Record 字典式解析 + typeof 窄化 */
      const j = JSON.parse(s) as Record<string, number | string>;
      const vsize = typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0;
      const asize = typeof j['actual-size'] === 'number' ? j['actual-size'] as number : 0;
      const fmt = typeof j['format'] === 'string' ? j['format'] as string : '?';
      this.diskVirtualGB = vsize / GB;
      this.diskActualGB = asize / GB;
      this.diskFmt = fmt;
    } catch {
      /* 解析失败保持默认 */
    }
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  /* 系统盘概览一句话（无盘 → 未配置） */
  private diskSummary(): string {
    return this.diskPath
      ? `${this.diskFmt} · 虚拟 ${this.diskVirtualGB.toFixed(1)}G · 实占 ${this.diskActualGB.toFixed(1)}G`
      : '未配置';
  }

  /* 光盘概览（未引用 → 未引用）；多张时标注第一张 + 计数 */
  private cdromName(): string {
    if (this.cdromPaths.length === 0) {
      return '未引用';
    }
    const first = this.baseName(this.cdromPaths[0]);
    return this.cdromPaths.length > 1 ? `${first} 等${this.cdromPaths.length}张` : first;
  }

  /* 当前优先引导设备：-boot d(光驱)/c(硬盘)。仅标「启动」于实际引导的那个介质。
   * 边界：无系统盘时只能光盘；bootFromCdrom 但无光盘时 qemu 回退硬盘。 */
  private bootDevice(): 'cdrom' | 'disk' | 'none' {
    if (this.cdromPaths.length > 0 && this.bootFromCdrom) {
      return 'cdrom';
    }
    if (this.diskPath.length > 0) {
      return 'disk';
    }
    if (this.cdromPaths.length > 0) {
      return 'cdrom';
    }
    return 'none';
  }

  /* 「启动」徽标：与「运行」徽标同款柔和样式（cChip 底 + 无描边），仅挂在当前启动盘行 */
  @Builder
  bootBadge() {
    Text('启动')
      .fontSize(tSub).fontColor(cPrimary)
      .padding({ left: sp1, right: sp1 })
      .borderRadius(rBadge)
      .backgroundColor(cChip)
  }

  /* ================= 快照 / 时光机（Phase 1，离线 qcow2 内部快照） ================= */

  /* 磁盘是不是 qcow2（raw 不支持内部快照） */
  private hasQcow(): boolean {
    return this.diskPath.length > 0 && this.diskFmt === 'qcow2';
  }

  /* 是否可以操作快照：须 qcow2 且 VM 已下岗（运行中盘被 qemu 锁死，改了会丢） */
  private canSnapshot(): boolean {
    return this.hasQcow() && !(this.profile !== null && vmIsRunning(this.profile.id));
  }

  private snapStatus(): string {
    if (this.diskPath.length === 0) {
      return '未配置系统盘';
    }
    if (this.diskFmt !== 'qcow2') {
      return '仅 qcow2 支持';
    }
    if (this.profile !== null && vmIsRunning(this.profile.id)) {
      return '需关机';
    }
    return '离线可用';
  }

  private refreshSnapshot(): void {
    if (!this.canSnapshot()) {
      this.snapshots = [];
      return;
    }
    /* 列表来自 qemu-img info --output=json 的 snapshots 数组（同 diskInfo 的原始 JSON）；
     * 临时会话的 `__temp__` 点是机制层产物，滤掉不打扰用户 */
    this.snapshots = parseSnapshots(napi.diskInfo(this.diskPath))
      .filter((s: VmSnapshotEntry) => !isTempSnapshot(s.name));
    if (this.snapshots.length > 0) {
      this.snapshots.sort((a, b) => b.dateSec - a.dateSec);
    }
  }

  private doSnapshotApply(s: VmSnapshotEntry): void {
    if (!this.canSnapshot()) {
      promptAction.showToast({ message: this.snapStatus() });
      return;
    }
    AlertDialog.show({
      title: '恢复到快照',
      message: `将系统盘回滚到「${s.name}」时的状态，之后写入的数据会丢失。确认？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '恢复',
        action: () => {
          const ret = snapshotApply(this.diskPath, s.name);
          if (ret !== 0) {
            promptAction.showToast({ message: '恢复失败' });
            return;
          }
          this.refreshDisk();
          this.refreshSnapshot();
          this.showSnack(`已恢复到「${s.name}」`);
        },
      },
    });
  }

  private doSnapshotDelete(s: VmSnapshotEntry): void {
    if (!this.canSnapshot()) {
      promptAction.showToast({ message: this.snapStatus() });
      return;
    }
    AlertDialog.show({
      title: '删除快照',
      message: `删除快照「${s.name}」？当前数据不受影响，不可撤销。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: cDanger,
        action: () => {
          const ret = snapshotDelete(this.diskPath, s.name);
          if (ret !== 0) {
            promptAction.showToast({ message: '删除快照失败' });
            return;
          }
          this.refreshSnapshot();
          this.showSnack('已删除快照');
        },
      },
    });
  }

  private dateStr(sec: number): string {
    if (sec <= 0) {
      return '';
    }
    const d = new Date(sec * 1000);
    const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
      `${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  /* ================= 顶部操作：进入 console 窗口 / 编辑 / 存储 / 删除虚拟机 ================= */

  private openConsole(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    /* 拉起（或复用并置前）该 VM 的独立 console 窗口；VM 未运行则由窗口页自启 */
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.startAbility({
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: 'VmConsoleAbility',
      parameters: { vmId: p.id, vmName: p.name },
    }).catch((err: BusinessError) => {
      promptAction.showToast({ message: '打开窗口失败: ' + err.code });
    });
  }

  private openEdit(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    /* 工坊已迁模态（VmList 侧栏长按「编辑」承载）；详情页编辑走扁平高级入口 VmEdit */
    this.navStack.pushPath({ name: 'edit', param: p });
  }

  /* 打开这台 VM 的「存储」弹窗：由 Index 层以全窗口遮罩承载（铺满主界面，含侧栏），
   * 与机器工坊同款；这里只置参数并开开关。 */
  private openStorage(): void {
    const p = this.profile;
    if (p) {
      this.storageParam = p;
      this.showStorage = true;
    }
  }

  /* 运行中 VM 关机入口：QMP system_powerdown（ACPI，客机自行保存退出）/ quit
   *（立即断电）。与 VmList 长按菜单同一套语义；连接是 per-vm 单例，发完不
   * disconnect，可能被打开中的 console 窗口复用。 */
  private confirmPowerOff(force: boolean): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    const label = force ? '强制关机' : '关机';
    const message = force
      ? `将立即结束「${p.name}」的虚拟机进程，未保存的数据可能丢失。确认？`
      : `向「${p.name}」发送 ACPI 关机信号（客机保存后自行退出）。确认？`;
    AlertDialog.show({
      title: label,
      message: message,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: label,
        fontColor: force ? cDanger : cPrimary,
        action: () => this.powerOff(p, force),
      },
    });
  }

  private powerOff(p: VmProfile, force: boolean): void {
    try {
      napi.qmpConnect(p.id, qmpSockPath(p, this.vmDataDir));
      const cmd = force ? '{"execute":"quit"}' : '{"execute":"system_powerdown"}';
      /* 连接线程异步就绪，等一小下再发，避免 socket 未连上白发（同 VmList） */
      setTimeout(() => {
        napi.qmpCommand(p.id, cmd);
      }, 150);
    } catch {
      promptAction.showToast({ message: '操作失败' });
    }
  }

  private confirmDeleteVm(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    if (vmIsRunning(p.id)) {
      promptAction.showToast({ message: '运行中的虚拟机不能删除' });
      return;
    }
    AlertDialog.show({
      title: '删除虚拟机',
      message: `将删除「${p.name}」的配置、系统盘镜像及内核文件副本（仅本应用目录内），确认？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: cDanger,
        action: () => {
          const cur = this.profile;
          if (cur) {
            new VmStore(this.filesDir).remove(cur);
            this.vmListVersion++;
            this.navStack.pop();
          }
        },
      },
    });
  }

  /* ================= chips 概览 helper ================= */

  private memLabel(): string {
    return this.profile ? '内存 ' + Math.round(this.profile.runtime.memoryMB / 1024) + 'G' : '';
  }

  private cpuLabel(): string {
    return this.profile ? '核 ' + this.profile.runtime.cpus : '';
  }

  private boardLabel(): string {
    return this.profile ? this.profile.machine.machine : '';
  }

  private firmwareLabel(): string {
    return this.profile ? this.profile.machine.firmware : '';
  }

  /* ================= 分区 ================= */

  /* 分区标题（与 VmWizard groupHeader 同款：灰字在左，细线延伸至右） */
  @Builder
  secHead(t: string) {
    Row({ space: sp8 }) {
      Text(t).fontSize(tLabel).fontColor(cSub)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp1 })
  }

  @Builder
  secStorage() {
    this.secHead('存储')
    Row() {
      Column({ space: sp1 }) {
        Row({ space: sp2 }) {
          Text(`系统盘 ${this.diskSummary()}`)
            .fontSize(tSubL).fontColor(cSub).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.bootDevice() === 'disk') {
            this.bootBadge()
          }
        }.width('100%')
        Row({ space: sp2 }) {
          Text(`光盘 ${this.cdromName()}`)
            .fontSize(tSubL).fontColor(cSub).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.bootDevice() === 'cdrom') {
            this.bootBadge()
          }
        }.width('100%')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button('存储管理').focusable(false).fontSize(tBody)
        .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
        .backgroundColor(Color.Transparent).fontColor(cPrimary)
        .onClick(() => this.openStorage())
    }.width('100%').padding({ top: sp1, bottom: sp2 }).alignItems(VerticalAlign.Center)
  }

  @Builder
  secSnapshot() {
    this.secHead('快照')
    Column() {
      if (!this.canSnapshot()) {
        Text(this.snapStatus()).fontSize(tSubL).fontColor(cWeak).padding({ top: sp1, bottom: sp2 })
      }

      /* 时间线（历史快照 + 当前） */
      Column() {
        ForEach(this.snapshots, (s: VmSnapshotEntry) => {
          Row() {
            Column().width(9).height(9).borderRadius(5).backgroundColor(cCard)
              .border({ width: 2, color: cPrimary }).margin({ right: sp2 })
            Column({ space: 1 }) {
              Text(s.name).fontSize(tLabel)
              Text(this.dateStr(s.dateSec)).fontSize(tMono).fontColor(cWeak)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('恢复').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cPrimary)
              .onClick(() => this.doSnapshotApply(s))
            Button('删除').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cDanger)
              .onClick(() => this.doSnapshotDelete(s))
          }.width('100%').padding({ top: sp1, bottom: sp1 })
        }, (s: VmSnapshotEntry) => s.id + ':' + s.name)
        Row() {
          Column().width(9).height(9).borderRadius(5).backgroundColor(cPrimary).margin({ right: sp2 })
          Column({ space: 1 }) {
            Text('当前').fontSize(tLabel)
            Text(this.dateStr(this.nowSec)).fontSize(tMono).fontColor(cWeak)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding({ top: sp1, bottom: sp1 })
      }.width('100%').padding({ left: sp2 })
    }.alignItems(HorizontalAlign.Start)
  }

  @Builder
  secNet() {
    this.secHead('网络')
    Column() {
      Column({ space: 1 }) {
        Text(this.netEnabled ? '已启用' : '已关闭').fontSize(tLabel)
        Text(`端口转发 ${(this.profile && this.profile.net.portForwards.length > 0) ? this.profile.net.portForwards : '无'} · 9p 共享${(this.profile && this.profile.net.sharedFolder) ? '开' : '关'}`)
          .fontSize(tSubL).fontColor(cSub)
      }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: sp1, bottom: sp2 })
    }.alignItems(HorizontalAlign.Start)
  }

  @Builder
  secAdvanced() {
    this.secHead('高级')
    Row() {
      Text('qemu 启动参数预览').fontSize(tSubL).fontColor(cSub)
      Blank()
      Button('复制').focusable(false).fontSize(tBody)
        .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
        .backgroundColor(Color.Transparent).fontColor(cPrimary)
        .onClick(() => this.copyArgs())
    }.width('100%').padding({ top: sp1, bottom: sp1 }).alignItems(VerticalAlign.Center)
    Text(this.qemuArgsText())
      .fontSize(tMono)
      .fontColor(cText)
      .padding(sp8)
      .width('100%')
      .backgroundColor(cBlock)
      .borderRadius(rElem)
      .textAlign(TextAlign.Start)
  }

  /* qemu 命令行预览：buildArgs 是纯函数，直接用当前 profile 派生（同 VmWizard 第⑥步）。
   * 9p 共享目录取 sharedDir（Download 或回退）；VM 空盘等边界照常渲染 */
  private qemuArgsText(): string {
    const p = this.profile;
    if (!p) {
      return '';
    }
    return buildArgs(p, this.vmDataDir, sharedDir(this.filesDir)).join(' ');
  }

  /* 复制 qemu 参数全文到系统剪贴板（长命令手抄容易错） */
  private copyArgs(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.qemuArgsText());
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '已复制' });
    }).catch((e: BusinessError) => {
      promptAction.showToast({ message: '复制失败: ' + e.code });
    });
  }

  build() {
    Stack() {
      Column() {
        /* 顶部行：返回 / 名称+运行徽标+arch / 进入·编辑·删除 */
        Row({ space: sp2 }) {
          if (!this.isWide) {
            Button('返回').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cPrimary)
              .onClick(() => this.navStack.pop())
          }
          Column({ space: 1 }) {
            Row({ space: sp1 }) {
              Text(this.name).fontSize(tCard).fontWeight(FontWeight.Medium).fontColor(cText)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.isRunningNow()) {
                Text('运行中').fontSize(tSub).fontColor(cRunning).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp1, right: sp1 })
              }
            }.alignItems(VerticalAlign.Center)
            Text(this.arch).fontSize(tSubL).fontColor(cSub)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          /* 操作图标钮：启动(play_fill) / 进入(rectangle) / 关机(power, 仅运行中) / 编辑(slider_vertical_3) / 删除(trash) */
          Button() {
            SymbolGlyph(this.isRunningNow() ? $r('sys.symbol.rectangle') : $r('sys.symbol.play_fill'))
              .fontSize(20)
              .fontColor([cPrimary])
          }
          .focusable(false)
          .width(btnH).height(btnH)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.openConsole())
          if (this.isRunningNow()) {
            /* 关机入口（仅运行中显示）：power 图标，点按弹出 关机/强制关机 两选项 */
            Button() {
              SymbolGlyph($r('sys.symbol.power'))
                .fontSize(20)
                .fontColor([cText])
            }
            .focusable(false)
            .width(btnH).height(btnH)
            .backgroundColor(Color.Transparent)
            .bindMenu([
              { value: '关机', action: () => this.confirmPowerOff(false) },
              { value: '强制关机', action: () => this.confirmPowerOff(true) },
            ])
          }
          Button() {
            SymbolGlyph($r('sys.symbol.slider_vertical_3'))
              .fontSize(20)
              .fontColor([cText])
          }
          .focusable(false)
          .width(btnH).height(btnH)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.openEdit())
          Button() {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(20)
              .fontColor([cDanger])
          }
          .focusable(false)
          .width(btnH).height(btnH)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.confirmDeleteVm())
        }
        .width('100%')
        .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column() {
            this.secHead('概览')
            /* 概览胶囊一排（内存/核/机型/固件；无 vga） */
            Row({ space: sp2 }) {
              if (this.memLabel().length > 0) {
                Text(this.memLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.cpuLabel().length > 0) {
                Text(this.cpuLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.boardLabel().length > 0) {
                Text(this.boardLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.firmwareLabel().length > 0) {
                Text(this.firmwareLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
            }
            .width('100%')
            .padding({ top: sp1, bottom: sp2 })

            this.secStorage()
            this.secNet()
            this.secSnapshot()
            this.secAdvanced()
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
      .backgroundColor(cCard)

      if (this.snack.length > 0) {
        Row() {
          Text('✓ ').fontSize(tBody).fontColor(cSuccess)
          Text(this.snack).fontSize(tBody).fontColor(Color.White)
        }
        .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
        .backgroundColor(cText).borderRadius(rElem)
        .position({ right: sp4, bottom: sp4 })
      }

    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.isWide = newValue.width >= 600;
    })
  }
}
