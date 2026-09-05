// 单台虚拟机的「存储」弹窗（per-VM 虚拟盘管理）：系统盘 扩容/重建 + 光盘 ISO 引用。
// 系统盘是这台 VM 自己的资产，维护操作只发生在 per-VM 弹窗；跨 VM 集中总览已弃用。
// 由 VmManage（详情）顶部「存储」按钮以内容弹窗（bindContentCover）承载，onClose 关闭。
// 快照依赖系统盘存在，但快照本身留在详情页（VmManage.secSnapshot），此处不做。
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore, VmArch, builtinIsoFor } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import { snapshotCreate } from '../lib/vmsnapshot';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pickIsoPath } from '../lib/isoPick';
import {
  cPrimary, cDanger, cRunning, cSuccess, cText, cSub, cWeak,
  cCard, cBlock, cChip, cBorder,
  tCard, tLabel, tBody, tSub,
  sp1, sp2, sp3, sp4, sp5, sp8, rElem, rBadge, rBtn, btnH, btnSh, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';

interface DiskNapi {
  diskInfo: (path: string) => string;
  diskResize: (path: string, sizeMB: number) => number;
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
}

const napi = napiModule as DiskNapi;
const GB = 1024 * 1024 * 1024;

@Component
export struct VmStorage {
  @Prop profile: VmProfile | null = null; /* 由 Index 全窗口弹窗传入（@Provide → @Prop） */
  onClose: (() => void) | null = null; /* 关闭回调；宿主通过它把内容弹窗关掉 */
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @State name: string = '';
  @State arch: VmArch = 'x86_64';
  @State diskPath: string = '';
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;
  @State expandMode: boolean = false;
  @State newGBText: string = '';
  @State snapNameText: string = '';
  @State snapCreateMode: boolean = false;
  @State cdromPaths: string[] = [];
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @State ensureIsoLoading: boolean = false; /* 内置 Alpine 下载中 */
  @State isoPct: number = 0;
  @State snack: string = '';

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.diskPath = p.media.diskPath;
    this.cdromPaths = p.media.cdromPaths.length > 0 ? p.media.cdromPaths.slice() : [];
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

  /* 重建系统盘：删除现有镜像并在同路径创建全新的空盘。这是唯一允许的破坏性磁盘操作
   * （「移除」被禁用），仅离线可操作；重建后旧数据/快照全部丢失，用 AlertDialog 强确认。 */
  private confirmRebuild(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    if (vmIsRunning(p.id)) {
      promptAction.showToast({ message: '运行中不能重建系统盘' });
      return;
    }
    /* 重建尺寸沿用当前虚拟大小（未知回退 8G）；事后仍需更大可走「扩容」 */
    const mb = Math.round((this.diskVirtualGB > 0 ? this.diskVirtualGB : 8) * 1024);
    AlertDialog.show({
      title: '重建系统盘',
      message: `将删除现有系统盘镜像并在同一位置创建全新的空盘（约 ${Math.ceil(mb / 1024)} GB）。\n当前数据与快照将全部丢失，且不可恢复。确认？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '重建',
        fontColor: cDanger,
        action: () => {
          const cur = this.profile;
          if (!cur) {
            return;
          }
          const store = new VmStore(this.filesDir);
          /* 重建统一落到应用管理的标准 qcow2 路径，避免在导入的 raw 路径下建出
           * qcow2 而扩展名/格式不符；旧的导入镜像属用户资产，不属于本应用 vms 目录则不删 */
          const path = `${store.dir}/${cur.id}.qcow2`;
          this.diskPath = path; /* 本页读取/渲染统一走 new 后的路径 */
          /* 删旧镜像：仅在应用 vms 目录内（同 VmStore.remove 的守卫）；删失败不阻塞 */
          try {
            const old = cur.media.diskPath;
            if (old.length > 0 && old.startsWith(store.dir) && fs.accessSync(old)) {
              fs.unlinkSync(old);
            }
          } catch {
            /* 删除失败不阻塞，仍重建 */
          }
          const ret = napi.createDisk(path, mb, 'dynamic');
          if (ret !== 0) {
            promptAction.showToast({ message: '重建系统盘失败' });
            return;
          }
          /* 引用与其他配置一致；bump 版本让详情页/列表重读 */
          if (cur.media.diskPath !== path) {
            cur.media.diskPath = path;
            new VmStore(this.filesDir).save(cur);
          }
          this.vmListVersion++;
          this.diskVirtualGB = mb / GB;
          this.refreshDisk();
          this.showSnack('已重建系统盘');
        },
      },
    });
  }

  /* 清空全部光盘引用（只改 profile，不删 ISO 文件；不校验路径，配置页没做过校验） */
  private clearCdrom(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    p.media.cdromPaths = [];
    new VmStore(this.filesDir).save(p);
    this.cdromPaths = [];
    this.vmListVersion++;
    this.showSnack('已清除光盘引用');
  }

  /* 移除第 idx 张 ISO（持久化） */
  private removeIso(idx: number): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    const next = this.cdromPaths.slice();
    next.splice(idx, 1);
    this.cdromPaths = next;
    p.media.cdromPaths = next;
    new VmStore(this.filesDir).save(p);
    this.vmListVersion++;
  }

  /* 追加一张 ISO（去重 + 持久化），默认从光盘启动 */
  private addIso(pStr: string): void {
    if (pStr.length === 0) { return; }
    if (this.cdromPaths.indexOf(pStr) >= 0) { return; }
    const next = this.cdromPaths.slice();
    next.push(pStr);
    const prof = this.profile;
    if (!prof) { return; }
    this.cdromPaths = next;
    prof.media.cdromPaths = next;
    prof.media.bootFromCdrom = true;
    new VmStore(this.filesDir).save(prof);
    this.vmListVersion++;
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
        this.showSnack('已挂载内置 ISO');
      } else {
        promptAction.showToast({ message: '内置 ISO 下载失败' });
      }
    });
  }

  /* 「选择文件」按钮：拉起系统选择器选 .iso，解析成真实路径后追加到 profile（原地引用，不拷贝）。
   * 路径不可读/取消则回退为「未选择文件」；追加即默认从光盘启动。 */
  private pickLocalIso(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickIsoPath(ctx).then((p: string) => {
      if (p.length === 0) {
        promptAction.showToast({ message: '未选择文件 / 路径不可读' });
        return;
      }
      this.addIso(p);
      this.showSnack('已挂载光盘');
    });
  }

  /* 分区标题（与 VmWizard groupHeader 同款：灰字在左，细线延伸至右） */
  @Builder
  secHead(t: string) {
    Row({ space: sp8 }) {
      Text(t).fontSize(tSub).fontColor(cSub)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp1 })
  }

  /* 系统盘：扩容 / 重建 / 创建快照（从 VmManage 平移到 per-VM 存储页）。盘不可移除，只可重建 */
  @Builder
  secSystemDisk() {
    this.secHead('系统盘')
    if (!this.diskPath) {
      Row({ space: sp2 }) {
        Text('系统盘缺失').fontSize(tSub).fontColor(cWeak).layoutWeight(1).padding({ top: sp1, bottom: sp1 })
        Button('重建系统盘').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .backgroundColor(Color.Transparent).fontColor(cDanger)
          .onClick(() => this.confirmRebuild())
      }.width('100%')
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
          Button('扩容').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cSub)
            .onClick(() => {
              this.newGBText = this.diskVirtualGB > 0 ? String(Math.ceil(this.diskVirtualGB)) : '';
              this.expandMode = !this.expandMode;
            })
          Button('重建系统盘').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.confirmRebuild())
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

  /* 光盘 ISO：该 VM 的 ISO 引用列表（可加/移除；第一张为启动盘候选） */
  @Builder
  secCdrom() {
    this.secHead('光盘 ISO')
    Column() {
      if (this.cdromPaths.length > 0) {
        ForEach(this.cdromPaths, (p: string, idx: number) => {
          Row({ space: sp2 }) {
            Text(idx === 0 ? `${this.baseName(p)}（启动盘）` : this.baseName(p))
              .fontSize(tSub).fontColor(idx === 0 ? cPrimary : cSub).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('移除').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cDanger)
              .onClick(() => this.removeIso(idx))
          }.width('100%').padding({ top: sp1, bottom: sp2 })
        }, (p: string, idx: number) => `${idx}:${p}`)
      } else {
        Column({ space: sp1 }) {
          Text('未引用光盘').fontSize(tSub).fontColor(cWeak)
            .padding({ top: sp1, bottom: sp1 })
          Text('选择本地 ISO 或内置 Alpine')
            .fontSize(tSub).fontColor(cWeak)
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: sp1, bottom: sp1 })
      }
      Row({ space: sp2 }) {
        Button('选择文件').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .backgroundColor(Color.Transparent).fontColor(cPrimary)
          .border({ width: 1, color: cBorder, style: BorderStyle.Dashed })
          .onClick(() => this.pickLocalIso())
        Button(this.ensureIsoLoading ? `内置下载 ${this.isoPct}%` : `内置 Alpine (${this.arch})`)
          .focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .enabled(!this.ensureIsoLoading)
          .backgroundColor(Color.Transparent).fontColor(cPrimary)
          .onClick(() => this.pickBuiltinIso())
      }.width('100%').padding({ top: sp1, bottom: sp2 })
      if (this.cdromPaths.length > 0) {
        Text('第一张为启动盘候选（从光盘启动时）')
          .fontSize(tSub).fontColor(cWeak).width('100%').padding({ bottom: sp2 })
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  build() {
    Stack() {
      Column() {
        /* 顶部行：存储 ·VM名 / arch + 关闭 */
        Row({ space: sp2 }) {
          Column({ space: 1 }) {
            Text('存储 · ' + this.name).fontSize(tCard).fontWeight(FontWeight.Medium).fontColor(cText)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.arch).fontSize(tSub).fontColor(cSub)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('×').backgroundColor(Color.Transparent).fontColor(cWeak)
            .onClick(() => { if (this.onClose) { this.onClose(); } })
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
  }
}
