// 单台虚拟机的「存储」页（per-VM 虚拟盘管理）：系统盘 信息/扩容/移除 + 光盘 ISO 引用。
// 系统盘是这台 VM 自己的资产，维护操作只发生在 per-VM 页；跨 VM 集中总览已弃用。
// 由 VmManage（详情）顶部「存储」按钮带参进入（pushPath { name:'storage', param }）。
// 快照依赖系统盘存在，但快照本身留在详情页（VmManage.secSnapshot），此处不做。
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import { snapshotCreate } from '../lib/vmsnapshot';
import {
  cPrimary, cDanger, cRunning, cSuccess, cText, cSub, cWeak,
  cCard, cBlock, cChip, cBorder,
  tCard, tLabel, tBody, tSub,
  sp1, sp2, sp3, sp4, sp5, rElem, rBadge, rBtn, btnH, btnSh, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  diskInfo: (path: string) => string;
  diskResize: (path: string, sizeMB: number) => number;
}

const napi = napiModule as DiskNapi;
const GB = 1024 * 1024 * 1024;

@Component
export struct VmStorage {
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
  @State snapNameText: string = '';
  @State snapCreateMode: boolean = false;
  @State cdromPath: string = '';
  @State snack: string = '';
  @State isWide: boolean = false; /* 宽屏(Split)下隐藏返回；getWindowSize 判宽 */

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.diskPath = p.media.diskPath;
    this.cdromPath = p.media.cdromPath;
    this.refreshDisk();
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

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
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

  private showDiskInfo(): void {
    promptAction.showToast({
      message: `${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`,
    });
  }

  /* 快照需 qcow2 且 VM 停机（运行中盘被 qemu 锁死，改了会丢） */
  private canSnapshot(): boolean {
    return this.diskFmt === 'qcow2' && this.profile !== null && !vmIsRunning(this.profile.id);
  }

  /* 创建内部快照（qcow2），仅离线可用 */
  private doSnapshotCreate(): void {
    if (!this.canSnapshot()) {
      promptAction.showToast({ message: this.profile !== null && vmIsRunning(this.profile.id) ? '快照需关机' : '仅 qcow2 支持' });
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
    this.showSnack(`已创建快照「${name}」`);
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
    this.showSnack(`已扩容到 ${gbNum} GB`);
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
        fontColor: cDanger,
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
          this.showSnack('已移除系统盘');
        },
      },
    });
  }

  /* 清光盘引用（只改 profile，不删 ISO 文件；不校验路径，配置页没做过校验） */
  private clearCdrom(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    p.media.cdromPath = '';
    new VmStore(this.filesDir).save(p);
    this.cdromPath = '';
    this.vmListVersion++;
    this.showSnack('已清除光盘引用');
  }

  @Builder
  secHead(t: string) {
    Divider().color(cBorder).margin({ top: sp2 })
    Text(t).fontSize(tSub).fontColor(cWeak).fontWeight(FontWeight.Bold).letterSpacing(0.5)
      .padding({ top: sp1, bottom: sp1 }).width('100%')
  }

  /* 系统盘：信息 / 扩容 / 移除（从 VmManage 平移到 per-VM 存储页） */
  @Builder
  secSystemDisk() {
    this.secHead('系统盘')
    if (!this.diskPath) {
      Text('未配置系统盘，可到配置页添加').fontSize(tSub).fontColor(cWeak).padding({ top: sp1, bottom: sp1 })
    } else {
      Column() {
        Row() {
          Text(`${this.diskFmt} · 虚拟 ${this.diskVirtualGB.toFixed(1)}G`).fontSize(tSub).fontColor(cSub)
          Blank()
          Text(`实占 ${this.diskActualGB.toFixed(1)}G`).fontSize(tSub).fontColor(cSub)
        }.width('100%')
        /* 实占/虚拟 进度条 */
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(6).backgroundColor(cBlock).borderRadius(rElem)
          Row().width((Math.min(100, (this.diskActualGB / Math.max(0.1, this.diskVirtualGB)) * 100)).toString() + '%')
            .height(6).backgroundColor(cPrimary).borderRadius(rElem)
        }.width('100%').margin({ top: sp1, bottom: sp1 })
        Row({ space: sp2 }) {
          Button('信息').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cSub)
            .onClick(() => this.showDiskInfo())
          Button('扩容').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cSub)
            .onClick(() => {
              this.newGBText = this.diskVirtualGB > 0 ? String(Math.ceil(this.diskVirtualGB)) : '';
              this.expandMode = !this.expandMode;
            })
          Button('移除').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.confirmRemove())
          if (this.canSnapshot()) {
            Button('创建快照').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cPrimary)
              .onClick(() => this.snapCreateMode = !this.snapCreateMode)
          }
        }
        if (this.snapCreateMode) {
          Row({ space: sp2 }) {
            TextInput({ text: this.snapNameText, placeholder: '快照名' }).layoutWeight(1).fontSize(tBody)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
              .onChange((v: string) => this.snapNameText = v)
            Button('创建').focusable(false).fontSize(tSub)
              .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
              .backgroundColor(cPrimary).fontColor(Color.White)
              .onClick(() => this.doSnapshotCreate())
            Button('取消').focusable(false).fontSize(tSub)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cSub)
              .onClick(() => this.snapCreateMode = false)
          }.margin({ top: sp2 })
        }
        if (this.expandMode) {
          Row({ space: sp2 }) {
            Text('新大小(GB)').fontSize(tSub).fontColor(cSub)
            TextInput({ text: this.newGBText }).type(InputType.Number).layoutWeight(1).fontSize(tBody)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
              .onChange((v: string) => this.newGBText = v)
            Button('确定').focusable(false).fontSize(tSub)
              .height(btnH).borderRadius(rBtn).padding({ left: btnPadX, right: btnPadX })
              .backgroundColor(cPrimary).fontColor(Color.White)
              .onClick(() => this.doExpand())
            Button('取消').focusable(false).fontSize(tSub)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cSub)
              .onClick(() => this.expandMode = false)
          }.margin({ top: sp2 })
        }
      }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: sp1, bottom: sp2 })
    }
  }

  /* 光盘 ISO：该 VM 的启动镜像引用（只读展示，可清引用） */
  @Builder
  secCdrom() {
    this.secHead('光盘 ISO')
    Column() {
      Row() {
        Text(this.cdromPath ? this.baseName(this.cdromPath) : '未引用光盘')
          .fontSize(tSub).fontColor(this.cdromPath ? cSub : cWeak).layoutWeight(1)
        if (this.cdromPath.length > 0) {
          Button('清除').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.clearCdrom())
        }
      }.width('100%').padding({ top: sp1, bottom: sp2 })
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  build() {
    Stack() {
      Column() {
        /* 顶部行：返回(宽屏隐藏) / 存储 ·VM名 / arch */
        Row({ space: sp2 }) {
          if (!this.isWide) {
            Button('返回').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cPrimary)
              .onClick(() => this.navStack.pop())
          }
          Column({ space: 1 }) {
            Text('存储 · ' + this.name).fontSize(tCard).fontWeight(FontWeight.Medium).fontColor(cText)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.arch).fontSize(tSub).fontColor(cSub)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%')
        .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column() {
            this.secSystemDisk()
            this.secCdrom()
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
