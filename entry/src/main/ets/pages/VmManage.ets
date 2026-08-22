// 单台虚拟机的管理页（per-VM）：分区滚动 —— 概览 chips + 系统盘 / 快照·时光机 / 网络 / 高级。
// 快照归属单台 VM，不进跨 VM 的库；临时会话打点/回滚见 lib/tempSession。
// 从列表侧栏点行进（Navigation replace 渲染到 content/detail 区）；成功反馈走右下角 snackbar。
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import {
  VmSnapshotEntry, snapshotApply, snapshotDelete, parseSnapshots,
} from '../lib/vmsnapshot';
import { isTempSnapshot } from '../lib/tempSession';
import {
  cPrimary, cDanger, cRunning, cSuccess, cText, cSub, cWeak,
  cCard, cBlock, cChip, cBorder,
  tCard, tLabel, tBody, tSub,
  sp1, sp2, sp3, sp4, sp5, rElem, rBadge, rBtn, btnH, btnSh, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  diskInfo: (path: string) => string;
}

const napi = napiModule as DiskNapi;
const GB = 1024 * 1024 * 1024;

@Component
export struct VmManage {
  profile: VmProfile | null = null; /* 由导航参数传入 */
  @Consume('navStack') navStack: NavPathStack;
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @State name: string = '';
  @State arch: string = '';
  @State running: boolean = false;
  @State diskPath: string = '';
  @State cdromPath: string = '';
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;
  @State snapshots: VmSnapshotEntry[] = [];
  @State netEnabled: boolean = false;
  @State snack: string = '';
  @State nowSec: number = 0; /* 进入页面时的时间基准，供「当前」快照节点稳定展示 */
  @State isWide: boolean = false; /* 宽屏(Split)下隐藏返回；getWindowSize 判宽 */

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.running = vmIsRunning(p.id);
    this.diskPath = p.media.diskPath;
    this.cdromPath = p.media.cdromPath;
    this.netEnabled = p.net.enabled;
    this.refreshDisk();
    this.refreshSnapshot();
    this.nowSec = Math.floor(Date.now() / 1000);
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

  /* 光盘概览（未引用 → 未引用） */
  private cdromName(): string {
    return this.cdromPath.length > 0 ? this.baseName(this.cdromPath) : '未引用';
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

  /* 进入这台 VM 的「存储」页（per-VM 虚拟盘管理） */
  private openStorage(): void {
    const p = this.profile;
    if (p) {
      this.navStack.pushPath({ name: 'storage', param: p });
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
      message: `将删除「${p.name}」的配置、封面及本应用内创建的磁盘镜像，确认？`,
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

  private vgaLabel(): string {
    return this.profile ? this.profile.machine.vga : '';
  }

  /* ================= 分区 ================= */

  @Builder
  secHead(t: string) {
    Divider().color(cBorder).margin({ top: sp2 })
    Text(t).fontSize(tSub).fontColor(cWeak).fontWeight(FontWeight.Bold).letterSpacing(0.5)
      .padding({ top: sp1, bottom: sp1 }).width('100%')
  }

  @Builder
  secStorage() {
    this.secHead('存储')
    Row() {
      Column({ space: sp1 }) {
        Text(`系统盘 ${this.diskSummary()}`)
          .fontSize(tSub).fontColor(cSub).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`光盘 ${this.cdromName()}`)
          .fontSize(tSub).fontColor(cSub).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
        Text(this.snapStatus()).fontSize(tSub).fontColor(cWeak).padding({ top: sp1, bottom: sp2 })
      }

      /* 时间线（历史快照 + 当前） */
      Column() {
        ForEach(this.snapshots, (s: VmSnapshotEntry) => {
          Row() {
            Column().width(9).height(9).borderRadius(5).backgroundColor(cCard)
              .border({ width: 2, color: cPrimary }).margin({ right: sp2 })
            Column({ space: 1 }) {
              Text(s.name).fontSize(tLabel)
              Text(this.dateStr(s.dateSec)).fontSize(10).fontColor(cWeak)
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
            Text(this.dateStr(this.nowSec)).fontSize(10).fontColor(cWeak)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding({ top: sp1, bottom: sp1 })
      }.width('100%').padding({ left: sp2 })
    }.alignItems(HorizontalAlign.Start)
  }

  @Builder
  secNet() {
    this.secHead('网络')
    Column() {
      Row() {
        Column({ space: 1 }) {
          Text('已启用').fontSize(tLabel)
          Text(`端口转发 ${(this.profile && this.profile.net.portForwards.length > 0) ? this.profile.net.portForwards : '无'} · 9p 共享${(this.profile && this.profile.net.sharedFolder) ? '开' : '关'}`)
            .fontSize(tSub).fontColor(cSub)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
          .onChange((v: boolean) => {
            this.netEnabled = v;
            if (this.profile) {
              this.profile.net.enabled = v;
              this.saveTiny();
            }
          })
      }.width('100%').padding({ top: sp1, bottom: sp2 })
    }.alignItems(HorizontalAlign.Start)
  }

  @Builder
  secAdvanced() {
    this.secHead('高级')
    Text('TCG 多线程 · tb-size · 自定义参数（到配置页编辑）').fontSize(tSub).fontColor(cSub)
      .padding({ top: sp1, bottom: sp2 })
  }

  private saveTiny(): void {
    if (this.profile) {
      new VmStore(this.filesDir).save(this.profile);
      this.vmListVersion++;
    }
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
              if (this.running) {
                Text('运行').fontSize(tSub).fontColor(cRunning).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp1, right: sp1 })
              }
            }.alignItems(VerticalAlign.Center)
            Text(this.arch).fontSize(tSub).fontColor(cSub)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(this.running ? '进入' : '启动').focusable(false).fontSize(tBody)
            .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
            .backgroundColor(cPrimary).fontColor(Color.White)
            .onClick(() => this.openConsole())
          Button('编辑').focusable(false).fontSize(tBody)
            .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
            .backgroundColor(cBlock).fontColor(cPrimary)
            .onClick(() => this.openEdit())
          Button('存储').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cPrimary)
            .onClick(() => this.openStorage())
          Button('删除').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.confirmDeleteVm())
        }
        .width('100%')
        .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column() {
            /* 概览 chips 一行 */
            Row({ space: sp2 }) {
              if (this.memLabel().length > 0) {
                Text(this.memLabel()).fontSize(tSub).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.cpuLabel().length > 0) {
                Text(this.cpuLabel()).fontSize(tSub).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.firmwareLabel().length > 0) {
                Text(this.firmwareLabel()).fontSize(tSub).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.vgaLabel().length > 0) {
                Text(this.vgaLabel()).fontSize(tSub).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
            }
            .width('100%')
            .padding({ top: sp2, bottom: sp2 })

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
