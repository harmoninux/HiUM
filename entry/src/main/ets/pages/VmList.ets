// 虚拟机列表页（首页，Navigation 侧栏）：运行汇总 + 紧凑行 + 选中态 + 空态。
// 宽屏下作为 Index 的 sideBar 常驻左侧，点行 push 'manage' 在右侧渲染详情；
// 多实例：每台 VM 独立子进程，可同时运行多台（受内存约束）；
// console 为每台 VM 一个 VmConsoleAbility 独立窗口（specified 模式按 vmId 归并）。
// 工坊为内嵌居中模态：Stack 遮罩浮层承载 VmWizard（showWizard 开关 + wizardParam 参数）。
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import napiModule from 'libentry.so';
import {
  VmProfile, VmStore,
  newProfileId, alpineProfile, qmpSockPath,
} from '../lib/vmprofile';
import { OsTemplate } from '../lib/osTemplates';
import { WizardParam } from './VmWizard';
import {
  initVmRegistry, refreshRunningMap, vmIsRunning,
  subscribeVmLifecycle, unsubscribeVmLifecycle, VmLifecycleEvent,
} from '../lib/vmregistry';
import {
  cPrimary, cDanger, cRunning, cWarn, cText, cSub, cWeak,
  cBg, cCard, cBorder, cBlock, cChip, cSel, cSelBg,
  tPage, tCard, tLabel, tBody, tSub,
  sp1, sp2, sp3, sp4, sp5, rCard, rElem, rBadge, bw,
} from '../lib/uiTokens';

/* 只用于「运行中 VM 安全关机/断电」的一次性 QMP 调用（连接是 per-vm 单例，无抢占） */
interface QmpNapi {
  qmpConnect: (vmId: string, sockPath: string) => number;
  qmpCommand: (vmId: string, cmd: string) => string;
}
const qmpNapi = napiModule as QmpNapi;

@Component
export struct VmList {
  @Consume('navStack') navStack: NavPathStack;
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('firmwareReady') firmwareReady: boolean = false;
  @StorageLink('vmListVersion') @Watch('reload') vmListVersion: number = 0;
  @State profiles: VmProfile[] = [];
  @State thumbTick: number = 0;
  @State runningIds: Record<string, boolean> = {};
  @State diskUsage: Record<string, number> = {}; /* vmId → 磁盘实占字节数 */
  @Consume('showWizard') showWizard: boolean; /* 全窗口工坊模态开关（Index @Provide） */
  @Consume('wizardParam') wizardParam: WizardParam; /* 工坊参数（新建/编辑） */
  @State selectedId: string = ''; /* 当前选中行（详情区正在展示的 VM） */
  private pollTimer: number = -1;
  private lifecycleCb: ((e: VmLifecycleEvent) => void) | null = null;

  aboutToAppear(): void {
    initVmRegistry();
    this.reload();
    /* 运行徽标经 VMRegistry 反应式快照（一次 IPC 聚合 N 台），页面可见期间
     * 轮询刷新；生命周事件（VM 跑/停）一到达就即时补刷，不再有 ≤2s 延迟 */
    this.pollTick();
    this.pollTimer = setInterval(() => this.pollTick(), 2000);
    this.lifecycleCb = (e: VmLifecycleEvent) => {
      for (const p of this.profiles) {
        if (p.id === e.vmId) {
          this.pollTick();
          break;
        }
      }
    };
    subscribeVmLifecycle(this.lifecycleCb);
  }

  aboutToDisappear(): void {
    clearInterval(this.pollTimer);
    this.pollTimer = -1;
    if (this.lifecycleCb) {
      unsubscribeVmLifecycle(this.lifecycleCb);
      this.lifecycleCb = null;
    }
  }

  private pollTick(): void {
    const ids: string[] = [];
    for (const p of this.profiles) {
      ids.push(p.id);
    }
    refreshRunningMap(ids);
    const next: Record<string, boolean> = {};
    for (const p of this.profiles) {
      next[p.id] = vmIsRunning(p.id);
    }
    this.runningIds = next;
  }

  private store(): VmStore {
    return new VmStore(this.filesDir);
  }

  private reload(): void {
    const store = this.store();
    let list = store.list();
    if (list.length === 0 && this.firmwareReady) {
      /* 首次使用：内置 Alpine 预设，开箱即用 */
      const seed = alpineProfile(newProfileId(), this.vmDataDir);
      store.save(seed);
      list = [seed];
    }
    this.profiles = list;
    this.thumbTick++;
    /* 磁盘实占用量（stat 元数据，快；不 fork qemu-img） */
    const usage: Record<string, number> = {};
    for (const p of list) {
      let bytes = 0;
      if (p.media.diskPath.length > 0) {
        try {
          if (fs.accessSync(p.media.diskPath)) {
            bytes = fs.statSync(p.media.diskPath).size;
          }
        } catch {
          bytes = 0;
        }
      }
      usage[p.id] = bytes;
    }
    this.diskUsage = usage;
    this.pollTick();
  }

  private isRunning(p: VmProfile): boolean {
    return this.runningIds[p.id] === true;
  }

  /* 该 VM 引用的媒体（系统盘/光盘）文件是否失效；空串 = 正常 */
  private mediaIssue(p: VmProfile): string {
    const bad: string[] = [];
    if (p.media.diskPath.length > 0 && !fs.accessSync(p.media.diskPath)) {
      bad.push('系统盘');
    }
    if (p.media.cdromPath.length > 0 && !fs.accessSync(p.media.cdromPath)) {
      bad.push('光盘');
    }
    return bad.join('、');
  }

  /* 卡片上的磁盘用量表述（无盘/读不到 → 空串） */
  private diskUsed(p: VmProfile): string {
    if (p.media.diskPath.length === 0) {
      return '';
    }
    const bytes = this.diskUsage[p.id] ?? 0;
    if (this.mediaIssue(p).indexOf('系统盘') >= 0) {
      return ' · 磁盘缺失';
    }
    return ` · 磁盘${(bytes / 1024 / 1024 / 1024).toFixed(1)}G`;
  }

  /* 运行中 VM 安全关机(ACPI)/断电：走 QMP（连接是 per-vm 单例，无抢占）。 */
  private confirmPowerOff(p: VmProfile, force: boolean): void {
    const label = force ? '强制断电' : '安全关机(ACPI)';
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
      qmpNapi.qmpConnect(p.id, qmpSockPath(p, this.vmDataDir));
      const cmd = force ? '{"execute":"quit"}' : '{"execute":"system_powerdown"}';
      /* 连接线程异步就绪，等一小下再发，避免 socket 未连上白发。
       * 不 disconnect：连接是 per-vm 单例，可能被打开中的 console 复用；
       * 停掉后 socket 自然消亡，reader 线程随之退出。 */
      setTimeout(() => {
        qmpNapi.qmpCommand(p.id, cmd);
        this.pollTick(); /* 立刻刷一次运行态 */
      }, 150);
    } catch {
      promptAction.showToast({ message: '操作失败' });
    }
  }

  /* 模板 → 机器工坊（模态浮层，预填可逐步改）；从零 → 规格化默认 */
  private openWizardNew(tpl: OsTemplate | null): void {
    this.wizardParam = tpl ? { mode: 'new', template: tpl } : { mode: 'new' };
    this.showWizard = true;
  }

  private openWizardEdit(p: VmProfile): void {
    this.wizardParam = { mode: 'edit', profile: p };
    this.showWizard = true;
  }

  private openConsole(p: VmProfile): void {
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

  private confirmDelete(p: VmProfile): void {
    if (this.isRunning(p)) {
      promptAction.showToast({ message: '运行中的虚拟机不能删除' });
      return;
    }
    AlertDialog.show({
      title: '删除虚拟机',
      message: `将删除「${p.name}」的配置、封面及本应用内创建的磁盘镜像，确认？`,
      primaryButton: {
        value: '取消',
        action: () => {},
      },
      secondaryButton: {
        value: '删除',
        fontColor: cDanger,
        action: () => {
          this.store().remove(p);
          this.reload();
        },
      },
    });
  }

  /* 点行：记选中态 + 在 content 区替换该 VM 详情（不叠历史栈，返回键直接退出详情） */
  private select(p: VmProfile): void {
    this.selectedId = p.id;
    this.navStack.replacePath({ name: 'manage', param: p });
  }

  private runningCount(): number {
    return this.profiles.filter((p: VmProfile) => this.isRunning(p)).length;
  }

  @Builder
  cardMenu(p: VmProfile) {
    Column({ space: sp1 }) {
      if (this.isRunning(p)) {
        Button('安全关机 (ACPI)').focusable(false).width('100%')
          .onClick(() => this.confirmPowerOff(p, false))
        Button('强制断电').focusable(false).width('100%')
          .fontColor(cDanger)
          .onClick(() => this.confirmPowerOff(p, true))
      }
      Button('编辑').focusable(false).width('100%')
        .onClick(() => this.openWizardEdit(p))
      Button('删除').focusable(false).width('100%')
        .fontColor(cDanger)
        .onClick(() => this.confirmDelete(p))
    }
    .width(120)
    .padding(sp2)
    .backgroundColor(cCard)
    .borderRadius(rCard)
  }

  /* 空态：无 VM 时居中提示 + 两个创建入口 */
  @Builder
  emptySide() {
    Column({ space: sp3 }) {
      Text('🖥').fontSize(44)
      Text('还没有虚拟机')
        .fontSize(tLabel)
        .fontColor(cSub)
      Text('点下方按钮创建你的第一台虚拟机')
        .fontSize(tSub)
        .fontColor(cWeak)
      Row({ space: sp2 }) {
        Button('＋ 新建')
          .focusable(false)
          .fontSize(tBody)
          .backgroundColor(cPrimary)
          .onClick(() => {
            this.openWizardNew(null);
          })
        Button('从零开始')
          .focusable(false)
          .fontSize(tBody)
          .backgroundColor(cBlock)
          .fontColor(cPrimary)
          .onClick(() => this.openWizardNew(null))
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /* 侧栏紧凑行：封面/架构 tag + 名称(运行/缺媒体徽标) + 规格行 + 进入/启动 */
  @Builder
  sideRow(p: VmProfile) {
    Row({ space: sp3 }) {
      if (fs.accessSync(this.store().thumbPath(p.id))) {
        Image('file://' + this.store().thumbPath(p.id))
          .width(40)
          .height(26)
          .objectFit(ImageFit.Cover)
          .borderRadius(rElem)
      } else {
        Column() {
          Text(p.machine.arch)
            .fontSize(tSub)
            .fontColor(cText)
        }
        .height(26)
        .constraintSize({ minWidth: 40 })
        .padding({ left: sp2, right: sp2 })
        .justifyContent(FlexAlign.Center)
        .backgroundColor(cBlock)
        .borderRadius(rElem)
      }

      Column({ space: sp1 }) {
        Row({ space: sp1 }) {
          Text(p.name)
            .fontSize(tCard)
            .fontWeight(FontWeight.Medium)
            .fontColor(cText)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.isRunning(p)) {
            Text('运行')
              .fontSize(tSub)
              .fontColor(cRunning)
              .backgroundColor(cChip)
              .borderRadius(rBadge)
              .padding({ left: sp1, right: sp1 })
          }
          if (this.mediaIssue(p).length > 0) {
            Text('⚠ 缺媒体')
              .fontSize(tSub)
              .fontColor(cWarn)
              .backgroundColor(cChip)
              .borderRadius(rBadge)
              .padding({ left: sp1, right: sp1 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(`${p.machine.arch} · ${p.runtime.memoryMB}MB · ${p.runtime.cpus}核` +
          (p.media.cdromPath ? ' · 光盘' : '') + this.diskUsed(p))
          .fontSize(tSub)
          .fontColor(cSub)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.isRunning(p) ? '进入' : '启动')
        .focusable(false)
        .fontSize(tBody)
        .backgroundColor(this.isRunning(p) ? cPrimary : Color.Transparent)
        .fontColor(this.isRunning(p) ? Color.White : cPrimary)
        .onClick(() => this.openConsole(p))
    }
    .width('100%')
    .padding(sp3)
    .backgroundColor(this.selectedId === p.id ? cSelBg : cCard)
    .border({ width: bw, color: this.selectedId === p.id ? cSel : cBorder })
    .borderRadius(rCard)
    .onClick(() => this.select(p))
    .bindContextMenu(this.cardMenu(p), ResponseType.LongPress)
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('虚拟机').fontSize(tPage).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('＋ 新建')
          .focusable(false)
          .fontSize(tBody)
          .backgroundColor(cPrimary)
          .onClick(() => {
            this.openWizardNew(null);
          })
      }
      .width('100%')
      .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })

      Row({ space: sp2 }) {
        Text(`● ${this.runningCount()} 运行`).fontSize(tSub).fontColor(cRunning)
        Text(`${this.profiles.length - this.runningCount()} 已停`).fontSize(tSub).fontColor(cSub)
      }
      .width('100%')
      .padding({ left: sp4, right: sp4, top: sp1, bottom: sp2 })

      if (!this.firmwareReady) {
        Text('固件未就绪（需先 make deps 并重新打包）')
          .fontSize(tSub)
          .fontColor(cDanger)
          .padding(sp4)
      }

      if (this.profiles.length === 0) {
        this.emptySide()
      } else {
        List({ space: sp2 }) {
          ForEach(this.profiles, (p: VmProfile) => {
            ListItem() {
              this.sideRow(p)
            }
          }, (p: VmProfile) => p.id + ':' + this.thumbTick)
        }
        .layoutWeight(1)
        .padding({ left: sp3, right: sp3, bottom: sp2 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cBg)

    }
    .width('100%')
    .height('100%')
  }
}
