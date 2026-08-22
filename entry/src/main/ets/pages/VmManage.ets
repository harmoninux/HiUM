// 单台虚拟机的管理页（per-VM）：系统盘信息 / 扩容 / 移除。
// 快照、时光机入口后续（Phase 1）加在这里 —— 快照归属单台 VM，不进跨 VM 的库。
// 从列表卡片正文进入（卡片点击只进管理，不启动；启动仍走「启动」按钮）。
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import {
  VmSnapshotEntry, snapshotCreate, snapshotApply, snapshotDelete, parseSnapshots,
} from '../lib/vmsnapshot';
import { isTempSnapshot } from '../lib/tempSession';

interface DiskNapi {
  diskInfo: (path: string) => string;
  diskResize: (path: string, sizeMB: number) => number;
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
  @State diskPath: string = '';
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;
  @State expandMode: boolean = false;
  @State newGBText: string = '';
  @State snapshots: VmSnapshotEntry[] = [];
  @State snapNameText: string = '';
  @State snapCreateMode: boolean = false;
  @State tempSession: boolean = false;

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.diskPath = p.media.diskPath;
    this.tempSession = p.temporarySession;
    this.refreshDisk();
    this.refreshSnapshot();
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

  private doSnapshotCreate(): void {
    if (!this.canSnapshot()) {
      promptAction.showToast({ message: this.snapStatus() });
      return;
    }
    const name = this.snapNameText.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '请输入快照名' });
      return;
    }
    const ret = snapshotCreate(this.diskPath, name);
    if (ret !== 0) {
      promptAction.showToast({ message: '创建快照失败' });
      return;
    }
    this.snapCreateMode = false;
    this.snapNameText = '';
    this.refreshSnapshot();
    promptAction.showToast({ message: `已创建快照「${name}」` });
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
          promptAction.showToast({ message: `已恢复到「${s.name}」` });
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
        fontColor: Color.Red,
        action: () => {
          const ret = snapshotDelete(this.diskPath, s.name);
          if (ret !== 0) {
            promptAction.showToast({ message: '删除快照失败' });
            return;
          }
          this.refreshSnapshot();
          promptAction.showToast({ message: '已删除快照' });
        },
      },
    });
  }

  /* 切换「临时会话启动模式」：开机前打会话起点内部快照，停机自动回滚丢弃本次改动 */
  private doSetTemp(v: boolean): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    p.temporarySession = v;
    new VmStore(this.filesDir).save(p);
    this.tempSession = v;
    this.vmListVersion++;
    promptAction.showToast({ message: v ? '已开启临时会话（启动后改动将被丢弃）' : '已关闭临时会话' });
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

  /* qcow2 只能扩大：目标须大于当前 virtual-size；运行中不能动 backing 盘 */
  private doExpand(): void {
    if (!this.diskPath) {
      return;
    }
    if (this.profile && vmIsRunning(this.profile.id)) {
      promptAction.showToast({ message: '运行中不能扩容系统盘' });
      return;
    }
    const gbNum = Number(this.newGBText);
    if (!Number.isInteger(gbNum) || gbNum <= 0) {
      promptAction.showToast({ message: '请输入有效的大小（GB）' });
      return;
    }
    if (gbNum * GB <= this.diskVirtualGB) {
      promptAction.showToast({ message: '扩容目标须大于当前大小' });
      return;
    }
    const ret = napi.diskResize(this.diskPath, gbNum * 1024);
    if (ret !== 0) {
      promptAction.showToast({ message: '扩容失败' });
      return;
    }
    this.expandMode = false;
    this.newGBText = '';
    this.refreshDisk();
    promptAction.showToast({ message: `已扩容到 ${gbNum} GB` });
  }

  private confirmRemove(): void {
    if (!this.profile) {
      return;
    }
    if (vmIsRunning(this.profile.id)) {
      promptAction.showToast({ message: '运行中不能移除系统盘' });
      return;
    }
    AlertDialog.show({
      title: '移除系统盘',
      message: '移除后该虚拟机的系统盘文件将被删除，且不可恢复。确认？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '移除',
        fontColor: Color.Red,
        action: () => {
          const p = this.profile;
          if (!p) {
            return;
          }
          try {
            if (this.diskPath && fs.accessSync(this.diskPath)) {
              fs.unlinkSync(this.diskPath);
            }
          } catch {
            /* 删除失败不阻塞，仍清引用 */
          }
          p.media.diskPath = '';
          new VmStore(this.filesDir).save(p);
          this.diskPath = '';
          this.vmListVersion++;
          this.refreshDisk();
          promptAction.showToast({ message: '已移除系统盘' });
        },
      },
    });
  }

  build() {
    Column() {
      Row() {
        Button('返回').focusable(false).fontSize(14).backgroundColor(Color.Transparent)
          .fontColor('#ff007dff')
          .onClick(() => this.navStack.pop())
        Blank()
        Text('虚拟机管理').fontSize(18).fontWeight(FontWeight.Medium)
        Blank()
        Text(this.arch).fontSize(13).fontColor('#ff666666')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })

      List({ space: 1 }) {
        ListItem() {
          Row() {
            Text('名称').fontSize(14).width(72)
            Text(this.name).fontSize(15).layoutWeight(1)
          }.padding(12)
        }

        ListItem() {
          Column({ space: 8 }) {
            Row() {
              Text('系统盘').fontSize(16).fontWeight(FontWeight.Medium)
              Blank()
              if (this.diskPath) {
                Text(this.baseName(this.diskPath)).fontSize(13).fontColor('#ff666666')
              }
            }
            if (this.diskPath) {
              Text(`${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`)
                .fontSize(13)
                .fontColor('#ff666666')
              Row({ space: 8 }) {
                Button('信息').focusable(false).fontSize(13)
                  .onClick(() => {
                    promptAction.showToast({
                      message: `${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`,
                    });
                  })
                Button('扩容').focusable(false).fontSize(13)
                  .onClick(() => {
                    this.newGBText = this.diskVirtualGB > 0 ? String(Math.ceil(this.diskVirtualGB)) : '';
                    this.expandMode = !this.expandMode;
                  })
                Button('移除').focusable(false).fontSize(13).fontColor(Color.Red)
                  .onClick(() => this.confirmRemove())
              }
              if (this.expandMode) {
                Row({ space: 8 }) {
                  Text('新大小(GB)').fontSize(13).fontColor('#ff666666')
                  TextInput({ text: this.newGBText })
                    .type(InputType.Number)
                    .layoutWeight(1)
                    .onChange((v: string) => this.newGBText = v)
                  Button('确定').focusable(false).fontSize(13)
                    .onClick(() => this.doExpand())
                  Button('取消').focusable(false).fontSize(13).fontColor('#ff666666')
                    .onClick(() => this.expandMode = false)
                }
              }
            } else {
              Text('未配置系统盘，可到配置页添加').fontSize(13).fontColor('#ff999999')
            }
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Column({ space: 8 }) {
            Row() {
              Text('快照 / 时光机').fontSize(16).fontWeight(FontWeight.Medium)
              Blank()
              Text(this.snapStatus()).fontSize(12).fontColor(
                this.canSnapshot() ? '#ff2e7d32' : '#ff999999')
            }
            Row() {
              Text('临时会话（启动即回滚）').fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.tempSession })
                .onChange((v: boolean) => this.doSetTemp(v))
            }
            Text('以临时会话启动：开机前打一个起点快照，关机自动回滚并丢弃本次改动（需 qcow2 系统盘）')
              .fontSize(11).fontColor('#ff999999')
            if (this.hasQcow()) {
              if (this.canSnapshot()) {
                Row({ space: 8 }) {
                  Button('新建快照').focusable(false).fontSize(13)
                    .onClick(() => this.snapCreateMode = !this.snapCreateMode)
                  Button('刷新').focusable(false).fontSize(13).fontColor('#ff666666')
                    .onClick(() => this.refreshSnapshot())
                }
                if (this.snapCreateMode) {
                  Row({ space: 8 }) {
                    TextInput({ text: this.snapNameText, placeholder: '快照名' })
                      .layoutWeight(1)
                      .fontSize(13)
                      .onChange((v: string) => this.snapNameText = v)
                    Button('创建').focusable(false).fontSize(13)
                      .onClick(() => this.doSnapshotCreate())
                    Button('取消').focusable(false).fontSize(13).fontColor('#ff666666')
                      .onClick(() => this.snapCreateMode = false)
                  }
                }
                if (this.snapshots.length === 0) {
                  Text('暂无快照').fontSize(12).fontColor('#ff999999')
                } else {
                  ForEach(this.snapshots, (s: VmSnapshotEntry) => {
                    Row({ space: 8 }) {
                      Column({ space: 2 }) {
                        Text(s.name).fontSize(14)
                        Text(this.dateStr(s.dateSec)).fontSize(11).fontColor('#ff999999')
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      Button('恢复').focusable(false).fontSize(12)
                        .onClick(() => this.doSnapshotApply(s))
                      Button('删除').focusable(false).fontSize(12).fontColor(Color.Red)
                        .onClick(() => this.doSnapshotDelete(s))
                    }.padding({ top: 4, bottom: 4 })
                  }, (s: VmSnapshotEntry) => s.id + ':' + s.name)
                }
              } else {
                Text('停机后可创建快照').fontSize(12).fontColor('#ff999999')
              }
            }
          }.alignItems(HorizontalAlign.Start).padding(12)
        }
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 1, color: '#11000000' })
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#fff2f3f5')
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }
}
