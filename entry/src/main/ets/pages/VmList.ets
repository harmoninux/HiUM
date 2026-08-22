// 虚拟机列表页（首页）：卡片 + 新建/编辑/删除/启动。
// 多实例：每台 VM 独立子进程，可同时运行多台（受内存约束）；
// console 为每台 VM 一个 VmConsoleAbility 独立窗口（specified 模式按 vmId 归并）。
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import napiModule from 'libentry.so';
import {
  VmProfile, VmStore,
  newProfileId, blankProfile, alpineProfile, qmpSockPath,
} from '../lib/vmprofile';
import { OS_TEMPLATES, OsTemplate, buildTemplateProfile } from '../lib/osTemplates';
import {
  initVmRegistry, refreshRunningMap, vmIsRunning,
  subscribeVmLifecycle, unsubscribeVmLifecycle, VmLifecycleEvent,
} from '../lib/vmregistry';

/* 只用于「运行中 VM 安全关机/断电」的一次性 QMP 调用（连接是 per-vm 单例，无抢占） */
interface QmpNapi {
  qmpConnect: (vmId: string, sockPath: string) => number;
  qmpCommand: (vmId: string, cmd: string) => string;
}
/* 模板一键创建要用的 qemu-img create（盘在创建时建好，失败不落配置） */
interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
}
const diskNapi = napiModule as DiskNapi;

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
  @State showPicker: boolean = false; /* 「+ 新建」模板选择面板 */
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
        fontColor: force ? Color.Red : Color.Black,
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

  /* 从模板一键创建：建盘 + 存配置 + 刷新。新盘用动态分配（稀疏，实占≈0）。 */
  private templateCreate(tpl: OsTemplate): void {
    const id = newProfileId();
    const p = buildTemplateProfile(tpl, id, this.filesDir, this.vmDataDir);
    if (tpl.diskMB > 0 && p.media.diskPath.length > 0) {
      const ret = diskNapi.createDisk(p.media.diskPath, tpl.diskMB, 'dynamic');
      if (ret !== 0) {
        promptAction.showToast({ message: '创建磁盘失败' });
        return;
      }
    }
    this.store().save(p);
    this.vmListVersion++;
    this.showPicker = false;
    promptAction.showToast({ message: `已创建「${p.name}」` });
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
        fontColor: Color.Red,
        action: () => {
          this.store().remove(p);
          this.reload();
        },
      },
    });
  }

  @Builder
  thumb(p: VmProfile) {
    if (fs.accessSync(this.store().thumbPath(p.id))) {
      Image('file://' + this.store().thumbPath(p.id))
        .width(96)
        .height(60)
        .objectFit(ImageFit.Cover)
        .borderRadius(4)
    } else {
      Column() {
        Text(p.machine.arch)
          .fontSize(11)
          .fontColor(Color.White)
      }
      .width(96)
      .height(60)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#ff334455')
      .borderRadius(4)
    }
  }

  /* 「+ 新建」模板选择面板：点模板一键创建；点「从零开始」进手工配置 */
  @Builder
  templatePicker() {
    Column() {
      Row() {
        Text('从模板新建').fontSize(18).fontWeight(FontWeight.Bold)
        Blank()
        Button('×').focusable(false).fontSize(20).backgroundColor(Color.Transparent)
          .fontColor('#888888')
          .onClick(() => this.showPicker = false)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })

      Scroll() {
        Column({ space: 10 }) {
          ForEach(OS_TEMPLATES, (t: OsTemplate) => {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(t.name).fontSize(16).fontWeight(FontWeight.Medium)
                Text(t.arch).fontSize(12).fontColor('#ff666666')
                Blank()
                Text(t.imageNeeded ? '需自备镜像' : '内置镜像')
                  .fontSize(11)
                  .fontColor(t.imageNeeded ? '#ff9900' : '#ff2e7d32')
              }
              Text(t.desc).fontSize(12).fontColor('#ff666666')
              Text(t.imageLabel).fontSize(11).fontColor('#ff999999')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(12)
            .backgroundColor(Color.White)
            .borderRadius(8)
            .onClick(() => this.templateCreate(t))
          }, (t: OsTemplate) => t.id)

          Column({ space: 4 }) {
            Text('从零开始').fontSize(16).fontWeight(FontWeight.Medium)
            Text('自定义架构/板卡/固件/介质（手工向导）').fontSize(12).fontColor('#ff999999')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .backgroundColor(Color.White)
          .borderRadius(8)
          .onClick(() => {
            this.showPicker = false;
            this.navStack.pushPath({ name: 'edit', param: blankProfile(newProfileId()) });
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
  }

  @Builder
  cardMenu(p: VmProfile) {
    Column({ space: 4 }) {
      if (this.isRunning(p)) {
        Button('安全关机 (ACPI)').focusable(false).width('100%')
          .onClick(() => this.confirmPowerOff(p, false))
        Button('强制断电').focusable(false).width('100%')
          .fontColor(Color.Red)
          .onClick(() => this.confirmPowerOff(p, true))
      }
      Button('编辑').focusable(false).width('100%')
        .onClick(() => this.navStack.pushPath({ name: 'edit', param: p }))
      Button('删除').focusable(false).width('100%')
        .fontColor(Color.Red)
        .onClick(() => this.confirmDelete(p))
    }
    .width(120)
    .padding(8)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  vmCard(p: VmProfile) {
    Row({ space: 10 }) {
      this.thumb(p)
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(p.name).fontSize(16).fontWeight(FontWeight.Medium)
          if (this.isRunning(p)) {
            Text('运行中').fontSize(11).fontColor('#ff2e7d32')
          }
          if (this.mediaIssue(p).length > 0) {
            Text('⚠ 媒体失效').fontSize(11).fontColor(Color.Red)
          }
        }
        Text(`${p.machine.arch} · ${p.runtime.memoryMB}MB · ${p.runtime.cpus}核` +
          (p.media.cdromPath ? ' · 光盘' : '') + this.diskUsed(p))
          .fontSize(12)
          .fontColor('#ff666666')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.isRunning(p) ? '进入' : '启动')
        .focusable(false)
        .fontSize(13)
        .onClick(() => this.openConsole(p))
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Color.White)
    .borderRadius(8)
    .onClick(() => this.navStack.pushPath({ name: 'manage', param: p }))
    .bindContextMenu(this.cardMenu(p), ResponseType.LongPress)
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('虚拟机').fontSize(24).fontWeight(FontWeight.Bold)
        Blank()
        Button('存储')
          .focusable(false)
          .fontSize(14)
          .fontColor('#ff007dff')
          .margin({ right: 12 })
          .onClick(() => this.navStack.pushPath({ name: 'storage' }))
        Button('+ 新建')
          .focusable(false)
          .fontSize(14)
          .onClick(() => {
            this.showPicker = true;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (!this.firmwareReady) {
        Text('固件未就绪（需先 make deps 并重新打包）')
          .fontSize(13)
          .fontColor(Color.Red)
          .padding(16)
      }

      List({ space: 10 }) {
        ForEach(this.profiles, (p: VmProfile) => {
          ListItem() {
            this.vmCard(p)
          }
        }, (p: VmProfile) => p.id + ':' + this.thumbTick)
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#fff2f3f5')

    if (this.showPicker) {
      this.templatePicker()
    }
    }
    .width('100%')
    .height('100%')
  }
}
