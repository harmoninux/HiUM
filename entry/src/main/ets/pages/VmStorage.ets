// 单台虚拟机的「存储」弹窗（per-VM 虚拟盘管理）：系统盘 扩容/重建 + 光盘 ISO 引用。
// 系统盘是这台 VM 自己的资产，维护操作只发生在 per-VM 弹窗；跨 VM 集中总览已弃用。
// 由 Index 的 bindSheet 半模态承载（系统蒙层/圆角/动效/关闭链路），标题走 sheet title。
// 快照依赖系统盘存在，但快照本身留在详情页（VmManage.secSnapshot），此处不做。
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore, VmArch, VmDisk, DiskIface, builtinIsoFor, ideDataDiskCapacity } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import { snapshotCreate } from '../lib/vmsnapshot';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pickIsoPath, pickFilePath } from '../lib/isoPick';
import { copyFileWithProgress } from '../lib/fsutil';
import { mainDiskPath } from '../lib/vmprofile';
import {
  cPrimary, cDanger, cRunning, cWarn, cText, cSub, cWeak,
  cCard, cBlock, cBorder,
  tCard, tLabel, tBody, tItem, tSub,
  sp1, sp3, sp4, sp5, sp6, sp2, rElem, rBtn, btnH, btnSh, btnRow, btnPadX,
  inpH, inpBg, inpRadius, inpPadX,
} from '../lib/uiTokens';
import { Chip, SecHead, Snackbar } from '../lib/uiWidgets';

interface DiskNapi {
  diskInfo: (path: string) => string;
  diskResize: (path: string, sizeMB: number) => number;
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
}

const napi = napiModule as DiskNapi;
const GB = 1024 * 1024 * 1024;

@Component
export struct VmStorage {
  @Prop profile: VmProfile | null = null; /* 由 Index 半模态（bindSheet）传入（@Provide → @Prop） */
  /* 标题/关闭由 sheet 系统提供（Index 侧 SheetOptions.title + showClose），本组件不再自绘卡头 */
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
  /* v5：数据盘（disks[1..]；增/删/扩容/只读；快照不参与） */
  @State extraDisks: VmDisk[] = [];
  @State secondMode: boolean = false;   /* 增盘表单显隐 */
  @State secondSrc: string = '';        /* 导入源（添加时复制进 vms/） */
  @State secondSrcMeta: string = '';
  @State secondNewGBText: string = '';
  @State secondNewReadonly: boolean = false; /* 新增数据盘表单的只读开关（默认可写） */
  @State secondNewAlloc: string = 'dynamic'; /* 新盘分配方式：dynamic 稀疏 / fixed 预分配(falloc) */
  @State secondExpandIdx: number = -1;       /* 扩容模式的目标盘下标；-1=添加模式 */

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.diskPath = mainDiskPath(p);
    this.cdromPaths = p.media.cdromPaths.length > 0 ? p.media.cdromPaths.slice() : [];
    this.extraDisks = p.media.disks.slice(1);
    this.refreshDisk();
  }

  /* 右下角 snackbar：成功类反馈走这里，错误类保留 toast。展示与自动消失已收进
   * Snackbar 组件（@Link 自清）；先清空再赋值让同文案连发也能重新计时 */
  private showSnack(msg: string): void {
    this.snack = '';
    this.snack = msg;
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

  /* ================= 数据盘（v5：disks[1..]，系统盘=disks[0] 走 diskPath） ================= */

  /* 数据盘增/删/扩容需停机（盘被 qemu 锁）；只读开关只改 profile 随时可以 */
  private canSecondOp(): boolean {
    return this.profile !== null && !vmIsRunning(this.profile.id);
  }

  /* 把 extraDisks 写回 profile（第 0 张系统盘保留原只读值），save + bump */
  /* 写前重读最新档：@Prop 是深拷贝副本，拿副本整份落盘会把其他页面刚保存的内容
   * 回滚（实测：存储页改动数据盘后，编辑页旧副本保存把改动覆盖回去）。入参可为
   * null（调用点的 null 检查在返回值上做）。 */
  private freshProfile(p: VmProfile | null): VmProfile | null {
    return p ? (new VmStore(this.filesDir).load(p.id) ?? p) : null;
  }

  private syncExtraDisks(): void {
    const p0 = this.profile;
    if (!p0) {
      return;
    }
    const p = this.freshProfile(p0);
    if (!p) {
      return;
    }
    const first: VmDisk = p.media.disks.length > 0
      ? p.media.disks[0]
      : { path: this.diskPath, readonly: false, iface: 'virtio' };
    p.media.disks = [first].concat(this.extraDisks);
    new VmStore(this.filesDir).save(p);
    this.vmListVersion++;
  }

  private pickSecondSrc(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickFilePath(ctx, ['.qcow2', '.img', '.raw']).then((p: string) => {
      if (p.length === 0) {
        promptAction.showToast({ message: '未选中文件，或文件无法读取' });
        return;
      }
      this.secondSrc = p;
      this.secondSrcMeta = '';
      const s = napi.diskInfo(p);
      if (s.length > 0) {
        try {
          const j = JSON.parse(s) as Record<string, number | string>;
          const fmt = typeof j['format'] === 'string' ? j['format'] as string : '?';
          const vs = typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0;
          this.secondSrcMeta = `${fmt} · 虚拟 ${(vs / GB).toFixed(1)}G`;
        } catch {
          this.secondSrcMeta = '';
        }
      }
    });
  }

  private secondSrcExt(): string {
    const s = this.secondSrc.toLowerCase();
    const i = s.lastIndexOf('.');
    return i >= 0 ? s.substring(i) : '.img';
  }

  /* 新增一张数据盘：新建空白 qcow2 或导入镜像（复制进 vms/），push 进 extraDisks */
  private doSecondAdd(): void {
    const p = this.freshProfile(this.profile);
    if (!p) {
      return;
    }
    if (!this.canSecondOp()) {
      promptAction.showToast({ message: '虚拟机运行中，请先关机再修改数据盘' });
      return;
    }
    /* 数据盘上限按主盘接口收紧：ide 槽位有限（-cdrom 再占一槽），pc 超出会被
     * qemu 静默丢弃（不报错、guest 看不见），必须挡在这里；virtio 无此限制。 */
    const mainIface: DiskIface = p.media.disks.length > 0 ? p.media.disks[0].iface : 'virtio';
    const cap = mainIface === 'ide' ? ideDataDiskCapacity(p.machine.machine) : 8;
    if (this.extraDisks.length >= cap) {
      promptAction.showToast({ message: mainIface === 'ide' ? `IDE 模式下数据盘最多 ${cap} 张` : '数据盘最多 8 张' });
      return;
    }
    const store = new VmStore(this.filesDir);
    const finish = (dst: string, msg: string): void => {
      const next = this.extraDisks.slice();
      /* 接口继承系统盘：Windows（ide 系统盘）下 virtio 数据盘装完系统也看不到 */
      next.push({ path: dst, readonly: this.secondNewReadonly, iface: mainIface });
      this.extraDisks = next;
      this.syncExtraDisks();
      this.secondMode = false;
      this.secondSrc = '';
      this.secondSrcMeta = '';
      this.secondNewGBText = '';
      this.secondNewReadonly = false;
      this.secondNewAlloc = 'dynamic';
      this.showSnack(msg);
    };
    if (this.secondSrc.length > 0) {
      const dst = `${store.dir}/${p.id}-d2-${this.extraDisks.length + 1}${this.secondSrcExt()}`;
      copyFileWithProgress(this.secondSrc, dst, () => {}).then((ok: boolean) => {
        if (!ok) {
          promptAction.showToast({ message: '复制数据盘失败' });
          return;
        }
        finish(dst, '数据盘已添加');
      });
      return;
    }
    const gbNum = Number(this.secondNewGBText);
    if (!Number.isInteger(gbNum) || gbNum <= 0 || gbNum > 512) {
      promptAction.showToast({ message: '请输入有效的大小（1-512 GB）' });
      return;
    }
    const dst = `${store.dir}/${p.id}-d2-${this.extraDisks.length + 1}.qcow2`;
    const ret = napi.createDisk(dst, gbNum * 1024, this.secondNewAlloc);
    if (ret !== 0) {
      promptAction.showToast({ message: '创建数据盘失败' });
      return;
    }
    finish(dst, this.secondNewAlloc === 'fixed'
      ? `数据盘 ${gbNum}GB 已创建（固定大小）` : `数据盘 ${gbNum}GB 已创建`);
  }

  /* 某张数据盘的只读开关（同步 extraDisks + profile） */
  private doSecondReadonly(idx: number, v: boolean): void {
    if (idx < 0 || idx >= this.extraDisks.length) {
      return;
    }
    const next = this.extraDisks.slice();
    next[idx] = { path: next[idx].path, readonly: v, iface: next[idx].iface };
    this.extraDisks = next;
    this.syncExtraDisks();
  }

  /* qcow2 扩容（只能扩大；只读不阻碍扩容，管理操作不受 readonly 限制） */
  private doSecondExpand(idx: number): void {
    if (idx < 0 || idx >= this.extraDisks.length) {
      return;
    }
    const path = this.extraDisks[idx].path;
    if (!path) {
      return;
    }
    if (!this.canSecondOp()) {
      promptAction.showToast({ message: '虚拟机运行中，请先关机再扩容' });
      return;
    }
    const gbNum = Number(this.secondNewGBText);
    if (!Number.isInteger(gbNum) || gbNum <= 0) {
      promptAction.showToast({ message: '请输入新大小（GB）' });
      return;
    }
    /* 目标须大于当前大小：从 diskInfo 现读（行内不缓存每盘 meta） */
    const info = napi.diskInfo(path);
    let cur = 0;
    try {
      const j = JSON.parse(info) as Record<string, number | string>;
      const vsize = typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0;
      cur = vsize;
    } catch {
      cur = 0;
    }
    if (cur > 0 && gbNum * GB <= cur) {
      promptAction.showToast({ message: '扩容目标须大于当前大小' });
      return;
    }
    const ret = napi.diskResize(path, gbNum * 1024);
    if (ret !== 0) {
      promptAction.showToast({ message: '扩容失败' });
      return;
    }
    this.secondMode = false;
    this.secondNewGBText = '';
    this.showSnack(`数据盘已扩容到 ${gbNum} GB`);
  }

  /* 移除某张数据盘：删引用 + vms 内镜像文件一并删（不可恢复，强确认） */
  private doSecondRemove(idx: number): void {
    const p = this.freshProfile(this.profile);
    if (!p) {
      return;
    }
    if (!this.canSecondOp()) {
      promptAction.showToast({ message: '虚拟机运行中，请先关机再删除' });
      return;
    }
    if (idx < 0 || idx >= this.extraDisks.length) {
      return;
    }
    const path = this.extraDisks[idx].path;
    AlertDialog.show({
      title: '删除数据盘',
      message: '将移除这块数据盘；如果镜像文件在本应用内，会一并删除，无法恢复。确认？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: cDanger,
        action: () => {
          try {
            const store = new VmStore(this.filesDir);
            if (path.length > 0 && path.startsWith(store.dir) && fs.accessSync(path)) {
              fs.unlinkSync(path);
            }
          } catch {
            /* best effort */
          }
          const next = this.extraDisks.slice();
          next.splice(idx, 1);
          this.extraDisks = next;
          this.syncExtraDisks();
          this.showSnack('已删除数据盘');
        },
      },
    });
  }

  /* 快照需 qcow2 且 VM 停机（运行中盘被 qemu 锁死，改了会丢） */
  private canSnapshot(): boolean {
    return this.diskFmt === 'qcow2' && this.profile !== null && !vmIsRunning(this.profile.id);
  }

  /* 创建内部快照（qcow2），仅离线可用 */
  private doSnapshotCreate(): void {
    if (!this.canSnapshot()) {
      promptAction.showToast({ message: this.profile !== null && vmIsRunning(this.profile.id) ? '关机后才能创建快照' : '系统盘不是 qcow2 格式，暂不支持快照' });
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
    /* 本弹窗是 Stack 遮罩（不压栈），详情页始终 active：bump 即触发它的
     * @Watch('onVmListChanged') → refreshProfile → refreshSnapshot，
     * 否则新建的快照要等离开详情页再回来才出现 */
    this.vmListVersion++;
    this.showSnack(`已创建快照「${name}」`);
  }

  /* qcow2 只能扩大：目标须大于当前 virtual-size；运行中不能动 backing 盘 */
  private doExpand(): void {
    if (!this.diskPath) {
      return;
    }
    if (this.profile && vmIsRunning(this.profile.id)) {
      promptAction.showToast({ message: '虚拟机运行中，请先关机再扩容' });
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
   * （「移除」被禁用），仅离线可操作；重建后旧数据/快照全部丢失，用 AlertDialog 强确认。
   * 分配方式在确认弹窗里一并选择（dynamic=稀疏省空间 / fixed=预分配 falloc，
   * 写入更快且免中途宿主盘满）。 */
  private confirmRebuild(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    if (vmIsRunning(p.id)) {
      promptAction.showToast({ message: '虚拟机运行中，请先关机再重建' });
      return;
    }
    /* 重建尺寸沿用当前虚拟大小（未知回退 8G）；事后仍需更大可走「扩容」 */
    const mb = Math.round((this.diskVirtualGB > 0 ? this.diskVirtualGB : 8) * 1024);
    AlertDialog.show({
      title: '重建系统盘',
      message: `将把系统盘重建为全新的空盘（约 ${Math.ceil(mb / 1024)} GB），现有数据与快照全部丢失、无法恢复。\n动态分配：用到多少占多少；固定大小：创建即占满，写入更快。`,
      buttons: [
        { value: '取消', action: () => {} },
        { value: '动态分配', fontColor: cDanger, action: () => this.doRebuild('dynamic') },
        { value: '固定大小', fontColor: cDanger, action: () => this.doRebuild('fixed') },
      ],
    });
  }

  /* 确认后的重建执行：删旧盘 → 按所选分配方式建新盘 → 落档 */
  private doRebuild(alloc: string): void {
    const cur = this.freshProfile(this.profile);
    if (!cur) {
      return;
    }
    const mb = Math.round((this.diskVirtualGB > 0 ? this.diskVirtualGB : 8) * 1024);
    const store = new VmStore(this.filesDir);
    /* 重建统一落到应用管理的标准 qcow2 路径，避免在导入的 raw 路径下建出
     * qcow2 而扩展名/格式不符；旧的导入镜像属用户资产，不属于本应用 vms 目录则不删 */
    const path = `${store.dir}/${cur.id}.qcow2`;
    this.diskPath = path; /* 本页读取/渲染统一走 new 后的路径 */
    /* 删旧镜像：仅在应用 vms 目录内（同 VmStore.remove 的守卫）；删失败不阻塞 */
    const oldMain = cur.media.disks.length > 0 ? cur.media.disks[0].path : '';
    try {
      if (oldMain.length > 0 && oldMain.startsWith(store.dir) && fs.accessSync(oldMain)) {
        fs.unlinkSync(oldMain);
      }
    } catch {
      /* 删除失败不阻塞，仍重建 */
    }
    const ret = napi.createDisk(path, mb, alloc);
    if (ret !== 0) {
      promptAction.showToast({ message: '重建系统盘失败' });
      return;
    }
    /* 引用与其他配置一致（数据盘不动）；bump 版本让详情页/列表重读 */
    const first: VmDisk = cur.media.disks.length > 0
      ? cur.media.disks[0]
      : { path: '', readonly: false, iface: 'virtio' };
    if (first.path !== path) {
      const newFirst: VmDisk = { path: path, readonly: first.readonly, iface: first.iface, cache: first.cache };
      cur.media.disks = [newFirst].concat(cur.media.disks.slice(1));
      new VmStore(this.filesDir).save(cur);
    }
    this.vmListVersion++;
    this.diskVirtualGB = mb / GB;
    this.refreshDisk();
    this.showSnack(alloc === 'fixed' ? '已重建系统盘（固定大小）' : '已重建系统盘');
  }

  /* 清空全部光盘引用（只改 profile，不删 ISO 文件；不校验路径，配置页没做过校验） */
  private clearCdrom(): void {
    const p = this.freshProfile(this.profile);
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
    const p = this.freshProfile(this.profile);
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
        this.showSnack('已挂载内置镜像');
      } else {
        promptAction.showToast({ message: '内置镜像下载失败，请检查网络后重试' });
      }
    });
  }

  /* 「选择文件」按钮：拉起系统选择器选 .iso，解析成真实路径后追加到 profile（原地引用，不拷贝）。
   * 路径不可读/取消则回退为「未选择文件」；追加即默认从光盘启动。 */
  private pickLocalIso(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    pickIsoPath(ctx).then((p: string) => {
      if (p.length === 0) {
        promptAction.showToast({ message: '未选中文件，或文件无法读取' });
        return;
      }
      this.addIso(p);
      this.showSnack('已挂载光盘');
    });
  }

  /* 分区标题走公共组件 SecHead（字号统一为 tLabel） */

  /* 系统盘：扩容 / 重建 / 创建快照（从 VmManage 平移到 per-VM 存储页）。盘不可移除，只可重建 */
  @Builder
  secSystemDisk() {
    SecHead({ label: '系统盘' })
    if (!this.diskPath) {
      Row({ space: sp3 }) {
        Text('系统盘缺失').fontSize(tSub).fontColor(cWarn).layoutWeight(1)
        Button('重建系统盘').focusable(false).fontSize(tItem)
          .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
          .backgroundColor(Color.Transparent).fontColor(cDanger)
          .onClick(() => this.confirmRebuild())
      }.width('100%')
    } else {
      Column() {
        Row() {
          Text(`${this.diskFmt} · 容量 ${this.diskVirtualGB.toFixed(1)}G`).fontSize(tSub).fontColor(cSub)
          Blank()
          Text(`已占 ${this.diskActualGB.toFixed(1)}G`).fontSize(tSub).fontColor(cSub)
        }.width('100%')
        /* 实占/虚拟 进度条 */
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(6).backgroundColor(cBlock).borderRadius(rElem)
          Row().width((Math.min(100, (this.diskActualGB / Math.max(0.1, this.diskVirtualGB)) * 100)).toString() + '%')
            .height(6).backgroundColor(cPrimary).borderRadius(rElem)
        }.width('100%').margin({ top: sp1, bottom: sp1 })
        Row({ space: sp3 }) {
          Button('扩容').focusable(false).fontSize(tItem)
            .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
            .backgroundColor(Color.Transparent).fontColor(cSub)
            .onClick(() => {
              this.newGBText = this.diskVirtualGB > 0 ? String(Math.ceil(this.diskVirtualGB)) : '';
              this.expandMode = !this.expandMode;
            })
          Button('重建系统盘').focusable(false).fontSize(tItem)
            .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.confirmRebuild())
          if (this.canSnapshot()) {
            Button('创建快照').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(Color.Transparent).fontColor(cPrimary)
              .onClick(() => this.snapCreateMode = !this.snapCreateMode)
          }
        }.width('100%')
        if (this.snapCreateMode) {
          Row({ space: sp3 }) {
            TextInput({ text: this.snapNameText, placeholder: '快照名' }).layoutWeight(1).fontSize(tItem)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX, top: sp1, bottom: sp1 })
              .onChange((v: string) => this.snapNameText = v)
            Button('创建').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(cPrimary).fontColor(Color.White)
              .onClick(() => this.doSnapshotCreate())
            Button('取消').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(Color.Transparent).fontColor(cSub)
              .onClick(() => this.snapCreateMode = false)
          }.width('100%').margin({ top: sp3 })
        }
        if (this.expandMode) {
          Row({ space: sp3 }) {
            Text('新大小(GB)').fontSize(tSub).fontColor(cSub)
            TextInput({ text: this.newGBText }).type(InputType.Number).layoutWeight(1).fontSize(tItem)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX, top: sp1, bottom: sp1 })
              .onChange((v: string) => this.newGBText = v)
            Button('确定').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(cPrimary).fontColor(Color.White)
              .onClick(() => this.doExpand())
            Button('取消').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(Color.Transparent).fontColor(cSub)
              .onClick(() => this.expandMode = false)
          }.width('100%').margin({ top: sp3 })
        }
      }.alignItems(HorizontalAlign.Start).width('100%')    }
  }

  /* 数据盘（v5）：列表逐行 只读/扩容/移除 + 底部「添加数据盘」表单（新建/导入）。
   * 系统盘（disks[0]）在本弹窗「系统盘」区；快照与临时会话只含系统盘。 */
  @Builder
  secSecondDisk() {
    SecHead({ label: '数据盘' })
    Column({ space: sp2 }) {
      /* 逐行：名字 + 只读 Toggle + 扩容 + 移除 */
      ForEach(this.extraDisks, (d: VmDisk, idx: number) => {
        Row({ space: sp3 }) {
          /* 文件名是应用生成的内部 id 命名，对用户无操作意义，显示序号即可 */
          Text(`数据盘${idx + 1}`)
            .fontSize(tSub).fontColor(cSub).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('只读').fontSize(tSub).fontColor(cSub)
          Toggle({ type: ToggleType.Switch, isOn: d.readonly })
            .onChange((v: boolean) => this.doSecondReadonly(idx, v))
          Button('扩容').focusable(false).fontSize(tItem)
            .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
            .enabled(this.canSecondOp())
            .backgroundColor(Color.Transparent).fontColor(cSub)
            .onClick(() => {
              this.secondNewGBText = '';
              this.secondMode = !this.secondMode;
              this.secondExpandIdx = idx;
            })
          Button('删除').focusable(false).fontSize(tItem)
            .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
            .enabled(this.canSecondOp())
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.doSecondRemove(idx))
        }.width('100%')      }, (d: VmDisk) => d.path)

      if (this.extraDisks.length === 0) {
        Text('还没有数据盘。可在下方新建空白盘或导入现有镜像。')
          .fontSize(tSub).fontColor(cWeak).width('100%')
      }

      /* 增盘/扩容表单（secondMode 切换；newGBText 复用两者） */
      if (!this.secondMode) {
        Row({ space: sp3 }) {
          Button(this.canSecondOp() ? '添加数据盘' : '运行中不可添加').focusable(false).fontSize(tItem)
            .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
            .enabled(this.canSecondOp())
            .backgroundColor(Color.Transparent).fontColor(cPrimary)
            .onClick(() => { this.secondMode = true; this.secondExpandIdx = -1 })
        }.width('100%')
      } else {
        if (this.secondExpandIdx >= 0) {
          /* —— 扩容模式：目标=第 secondExpandIdx 张 —— */
          Row({ space: sp3 }) {
            Text('新大小(GB)').fontSize(tSub).fontColor(cSub)
            TextInput({ text: this.secondNewGBText }).type(InputType.Number).layoutWeight(1).fontSize(tItem)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX, top: sp1, bottom: sp1 })
              .onChange((v: string) => this.secondNewGBText = v)
            Button('确定').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(cPrimary).fontColor(Color.White)
              .onClick(() => this.doSecondExpand(this.secondExpandIdx))
            Button('取消').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(Color.Transparent).fontColor(cSub)
              .onClick(() => { this.secondMode = false; this.secondNewGBText = ''; this.secondExpandIdx = -1; })
          }.width('100%')
        } else {
          /* —— 添加模式：导入镜像 or 新建空白 —— */
          Row({ space: sp3 }) {
            Text('导入镜像').fontSize(tBody)
              .fontColor(this.secondSrc.length > 0 ? cPrimary : cSub)
              .onClick(() => this.pickSecondSrc())
            if (this.secondSrc.length > 0) {
              Text(this.baseName(this.secondSrc) + (this.secondSrcMeta.length > 0 ? `（${this.secondSrcMeta}）` : ''))
                .fontSize(tSub).fontColor(cSub).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Button('清除').focusable(false).fontSize(tItem)
                .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                .backgroundColor(Color.Transparent).fontColor(cDanger)
                .onClick(() => { this.secondSrc = ''; this.secondSrcMeta = ''; })
            }
          }.width('100%')
          Row({ space: sp3 }) {
            Text('新大小(GB)').fontSize(tSub).fontColor(cSub)
            TextInput({ text: this.secondNewGBText, placeholder: '新建时填写（1-512）' })
              .layoutWeight(1).fontSize(tItem)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX, top: sp1, bottom: sp1 })
              .onChange((v: string) => this.secondNewGBText = v)
            Button(this.secondSrc.length > 0 ? '导入' : '创建').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(cPrimary).fontColor(Color.White)
              .onClick(() => this.doSecondAdd())
            Button('取消').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(Color.Transparent).fontColor(cSub)
              .onClick(() => { this.secondMode = false; this.secondSrc = ''; this.secondSrcMeta = ''; })
          }.width('100%')
          Row() {
            Text('新盘只读').fontSize(tSub).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.secondNewReadonly })
              .onChange((v: boolean) => this.secondNewReadonly = v)
          }.width('100%')
          /* 说明放控件下方整宽（全局摆放规范见 uiTokens.ets 头部） */
          Column({ space: sp1 }) {
            Row({ space: sp3 }) {
              Text('磁盘分配').fontSize(tSub).fontColor(cSub)
              Chip({ label: '动态分配', active: this.secondNewAlloc === 'dynamic', onTap: () => { this.secondNewAlloc = 'dynamic'; } })
              Chip({ label: '固定大小', active: this.secondNewAlloc === 'fixed', onTap: () => { this.secondNewAlloc = 'fixed'; } })
            }.width('100%')
            Text(this.secondNewAlloc === 'fixed' ? '创建即占满，写入更快' : '按需占用，用到多少占多少')
              .fontSize(tSub).fontColor(cWeak).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
        }
      }
      Text('快照仅含系统盘，数据盘不参与').fontSize(tSub).fontColor(cWeak).width('100%')
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  /* 光盘 ISO：该 VM 的 ISO 引用列表（可加/移除；第一张为启动盘候选） */
  @Builder
  secCdrom() {
    SecHead({ label: '光盘 ISO' })
    Column() {
      if (this.cdromPaths.length > 0) {
        ForEach(this.cdromPaths, (p: string, idx: number) => {
          Row({ space: sp3 }) {
            Text(idx === 0 ? `${this.baseName(p)}（启动盘）` : this.baseName(p))
              .fontSize(tSub).fontColor(idx === 0 ? cPrimary : cSub).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('移除').focusable(false).fontSize(tItem)
              .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
              .backgroundColor(Color.Transparent).fontColor(cDanger)
              .onClick(() => this.removeIso(idx))
          }.width('100%')        }, (p: string, idx: number) => `${idx}:${p}`)
      } else {
        Column({ space: sp1 }) {
          Text('未引用光盘').fontSize(tSub).fontColor(cWeak)
                      Text('选择本地 ISO 或内置 Alpine')
            .fontSize(tSub).fontColor(cWeak)
        }.alignItems(HorizontalAlign.Start).width('100%')      }
      Row({ space: sp3 }) {
        Button('选择文件').focusable(false).fontSize(tItem)
          .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
          .backgroundColor(Color.Transparent).fontColor(cPrimary)
          .border({ width: 1, color: cBorder, style: BorderStyle.Dashed })
          .onClick(() => this.pickLocalIso())
        Button(this.ensureIsoLoading ? `内置下载 ${this.isoPct}%` : `内置 Alpine (${this.arch})`)
          .focusable(false).fontSize(tItem)
          .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
          .enabled(!this.ensureIsoLoading)
          .backgroundColor(Color.Transparent).fontColor(cPrimary)
          .onClick(() => this.pickBuiltinIso())
      }.width('100%')
      if (this.cdromPaths.length > 0) {
        Text('从光盘启动时，使用第一张 ISO 引导')
          .fontSize(tSub).fontColor(cWeak).width('100%')
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  build() {
    Stack() {
      Column() {
        Scroll() {
          Column({ space: sp2 }) {
            this.secSystemDisk()
            this.secSecondDisk()
            this.secCdrom()
          }
          .width('100%')
          .padding({ left: sp5, right: sp5, top: sp2, bottom: sp4 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')

      Snackbar({ msg: this.$snack })
    }
    .width('100%')
    .height('100%')
  }
}
