// 虚拟机 Console 页：独立窗口（VmConsoleAbility）内的 XComponent 渲染 +
// 顶部工具条（电源/QMP 控制/截图/全屏）。vmId 经 LocalStorage 传入，页面按
// vmId 自载 profile。VM 跑在 NCP 子进程，关窗只是摘窗，重开窗口即重新挂窗。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';
import { VmProfile, VmStore, buildArgs, qmpSockPath, sharedDir, builtinIsoFor } from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pathExists } from '../lib/fsutil';
import { prepareStart } from '../lib/tempSession';
import { takePendingVmId, isPadOrPhone } from '../lib/vmwindows';
import { VirtualKeyboard } from '../lib/VirtualKeyboard';
import {
  cDanger, cPrimary,
  rBtn, rElem, btnH, tBody, tMono, sp1, sp2, sp3,
} from '../lib/uiTokens';

interface ScreenShotBuf {
  width: number;
  height: number;
  pixels: ArrayBuffer;
}

interface QemuNapi {
  startVm: (vmId: string, arch: string, args: string[], surfaceId: bigint) => number;
  vmRunning: (vmId: string) => boolean;
  createSurface: (vmId: string, surfaceId: bigint) => number;
  resizeSurface: (vmId: string, w: number, h: number) => number;
  destroySurface: (vmId: string) => number;
  sendPointer: (vmId: string, x: number, y: number, buttons: number) => void;
  sendKey: (vmId: string, qcode: number, down: boolean) => void;
  scroll: (vmId: string, dx: number, dy: number) => void;
  qmpConnect: (vmId: string, sockPath: string) => number;
  qmpCommand: (vmId: string, cmd: string) => string;
  setQmpEventCallback: (vmId: string, cb: ((evt: string) => void) | null) => void;
  captureScreen: (vmId: string) => ScreenShotBuf | null;
}

const napi: QemuNapi = napiModule as QemuNapi;

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

/* 悬浮按钮（替代顶部工具条）：半透明圆钮，可拖拽移动，点击展开竖向操作面板。
 * 位置持久化到 preferences（键按 vmId 区分，跨窗口/重开记住落位）。
 * 尺寸/阈值参照 wineohos VirtualDesktop 的 EXIT_BTN_SIZE/EXIT_DRAG_THRESHOLD。 */
const FAB_SIZE = 48;          /* 圆钮直径 (vp) */
const FAB_PAD = 16;           /* 默认距边留白 (vp) */
const FAB_DRAG_THRESHOLD = 5; /* 位移 >5vp 判定拖动，否则点击 */
const FAB_PREF = 'vmconsole_fab'; /* preferences 文件名 */
const PANEL_W = 168;          /* 展开面板宽 (vp) */
const MENU_BOX_H = 520;       /* 面板定位盒高：内容底部对齐、向上生长，容纳电源子菜单 */
const MENU_TEXT = '#fff5f7fa'; /* 面板浅底上的文字色 */

interface QmpEvent {
  event: string;
}

class VmXComponentController extends XComponentController {
  vmId: string = '';
  surfaceId: bigint = 0n;
  surfaceWidth: number = 0;
  surfaceHeight: number = 0;
  onReady: (() => void) | null = null;

  onSurfaceCreated(surfaceId: string): void {
    this.surfaceId = BigInt(surfaceId);
    /* 页面转场期间立刻挂窗会得到坏 queue（swap 必报 EGL_BAD_SURFACE）：
     * 等转场稳定后再挂（实测 500ms 足够；首启的 START 自带窗口不受影响） */
    const id = this.surfaceId;
    const vmId = this.vmId;
    setTimeout(() => {
      napi.createSurface(vmId, id);
      if (this.onReady) {
        this.onReady();
      }
    }, 500);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    this.surfaceWidth = rect.surfaceWidth;
    this.surfaceHeight = rect.surfaceHeight;
    napi.resizeSurface(this.vmId, rect.surfaceWidth, rect.surfaceHeight);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    napi.destroySurface(this.vmId);
    this.surfaceId = 0n;
  }
}

@Entry
@Component
struct VmConsole {
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;
  @State status: string = '';
  /* 悬浮按钮（替代顶部工具条）：圆钮位置 + 面板开合 */
  @State fabX: number = -1;    /* <0 = 尚未初始化（等 onAreaChange 定初位） */
  @State fabY: number = -1;
  @State menuOpen: boolean = false;  /* 竖向面板展开 */
  @State showKbd: boolean = false;   /* 虚拟键盘显隐（浮动菜单开关，按 vmId 持久化） */
  private vmId: string = '';
  private profile: VmProfile | null = null;
  private xcController: VmXComponentController = new VmXComponentController();
  private areaW: number = 0;
  private areaH: number = 0;
  private surfaceReady: boolean = false;
  private startPending: boolean = false;
  private closed: boolean = false; /* VM 已死导致本窗口即将销毁，防重复 terminate */
  /* 触摸手势状态机（单指=移动/左键/长按右键；双指=滚轮） */
  private touchButtons: number = 0;
  private singleDown: boolean = false;
  private singleStartX: number = 0;
  private singleStartY: number = 0;
  private longPressTimer: number = -1;
  private longPressed: boolean = false;
  private twoFinger: boolean = false;
  private scrollCenterY: number = 0;
  private scrollAcc: number = 0;
  private lastX: number = 0;
  private lastY: number = 0;
  /* 悬浮按钮拖拽状态机（onTouch 驱动，同 wineohos VirtualDesktop） */
  private fabW: number = 0;      /* 窗口内容 vp 宽（钳制基准） */
  private fabH: number = 0;      /* 窗口内容 vp 高 */
  private fabStartX: number = 0; /* 手势起点触摸窗坐标 */
  private fabStartY: number = 0;
  private fabBtnX: number = 0;   /* 手势起点按钮位置 */
  private fabBtnY: number = 0;
  private fabMoved: boolean = false;

  private toSurfacePx(vp: number, vpSize: number, surfaceSize: number): number {
    if (vpSize <= 0 || surfaceSize <= 0) {
      return Math.round(vp);
    }
    return Math.round(vp * surfaceSize / vpSize);
  }

  aboutToAppear(): void {
    /* vmId 由 Ability 在 loadContent 前入队（同步建页，出队即得） */
    this.vmId = takePendingVmId();
    if (this.vmId.length > 0) {
      this.profile = new VmStore(this.filesDir).load(this.vmId);
    }
    this.xcController.vmId = this.vmId;
    this.xcController.onReady = () => {
      this.surfaceReady = true;
      if (this.startPending) {
        this.startPending = false;
        this.startVm();
      }
    };
    napi.setQmpEventCallback(this.vmId, (evt: string) => this.onQmpEvent(evt));
    this.loadKbd();
    this.enterVm();
  }

  aboutToDisappear(): void {
    napi.setQmpEventCallback(this.vmId, null);
    this.saveThumb(); /* 顺手更新列表页缩略图 */
  }

  private enterVm(): void {
    if (!this.profile) {
      this.status = '配置不存在或已删除';
      return;
    }
    if (napi.vmRunning(this.vmId)) {
      /* 已在后台运行（上次关窗只是摘窗）：重新挂窗，接管 QMP */
      this.status = 'running';
      napi.qmpConnect(this.vmId, qmpSockPath(this.profile, this.vmDataDir));
      return;
    }
    if (this.surfaceReady) {
      this.startVm();
    } else {
      this.startPending = true; /* 等 surface 起来再启动，避免黑屏竞态 */
    }
  }

  private startVm(): void {
    if (!this.profile || napi.vmRunning(this.vmId)) {
      return;
    }
    if (this.xcController.surfaceId === 0n) {
      this.startPending = true;
      return;
    }
    /* 若引导光盘是内置 Alpine ISO 且未下载：先按需下载，成功后继续启动 */
    const cd = this.profile.media.cdromPath;
    const builtin = this.vmDataDir + '/' + builtinIsoFor(this.profile.machine.arch);
    if (cd.length > 0 && cd === builtin && !pathExists(cd)) {
      this.status = '下载系统盘...';
      const ctx = getContext(this) as common.UIAbilityContext;
      ensureBuiltinIso(ctx, this.vmDataDir, this.profile.machine.arch, (pct: number) => {
        this.status = `下载系统盘 ${pct}%`;
      }).then((ok: boolean) => {
        if (!ok) {
          this.status = '系统盘下载失败';
          return;
        }
        this.doStart();
      });
      return;
    }
    this.doStart();
  }

  private doStart(): void {
    if (!this.profile) {
      return;
    }
    let share = '';
    if (this.profile.net.sharedFolder) {
      share = sharedDir(this.filesDir);
      try {
        if (!fs.accessSync(share)) {
          fs.mkdirSync(share, true);
        }
      } catch {
        /* 目录建不出来就不挂 9p，让 qemu 自行忽略 */
        share = '';
      }
    }
    /* 启动前的快照结算 + 临时会话打点：仅 qcow2 支持（raw 无内部快照）。
     * 失败则拒启，避免"用户以为会回滚却没回滚"。 */
    const disk = this.profile.media.diskPath;
    if (this.profile.temporarySession &&
      (disk.length === 0 || !disk.toLowerCase().endsWith('.qcow2'))) {
      this.status = '临时会话需 qcow2 系统盘';
      return;
    }
    const tr = prepareStart(this.profile.id, disk, this.profile.temporarySession);
    if (tr !== 0) {
      this.status = '临时会话打点失败: ' + tr;
      return;
    }
    /* 每次启动都是一个新的 NCP 子进程；多实例按 vmId 各起各的 */
    const ret = napi.startVm(this.vmId, this.profile.machine.arch,
      buildArgs(this.profile, this.vmDataDir, share), this.xcController.surfaceId);
    if (ret !== 0) {
      this.status = '启动失败: ' + ret;
      return;
    }
    this.status = 'starting...';
    napi.qmpConnect(this.vmId, qmpSockPath(this.profile, this.vmDataDir));
    /* 首次启动 qemu 不发 RESUME 事件，按实际运行状态翻牌；长时间没起来
     * 说明子进程早夭（如参数/资源问题），给个可见的失败 */
    setTimeout(() => {
      if (this.status === 'starting...' && napi.vmRunning(this.vmId)) {
        this.status = 'running';
      }
    }, 2000);
    setTimeout(() => {
      if (this.status === 'starting...' && !napi.vmRunning(this.vmId)) {
        this.status = '启动失败（子进程退出）';
      }
    }, 10000);
  }

  private onQmpEvent(evt: string): void {
    let name = '';
    try {
      name = (JSON.parse(evt) as QmpEvent).event;
    } catch {
      return;
    }
    hilog.info(DOMAIN, TAG, 'qmp event: %{public}s', name);
    switch (name) {
      case 'STOP':
        this.status = '已暂停';
        break;
      case 'RESUME':
        this.status = 'running';
        break;
      case 'RESET':
        this.status = 'running (reset)';
        break;
      case 'SHUTDOWN':
      case 'QMP_DISCONNECT':
        this.status = '已关机';
        this.vmListVersion++;
        /* VM 进程已死（意外退出 / ACPI / 强制断电 / quit 一律如此）：
         * 窗口是「存活 VM 的视图」，死机就应该销毁窗口——下次从列表「进入」
         * 会走全新的窗口→enterVm→startVm 自动重启。避免窗口停在「已关机」
         * 冻结帧且再无重启入口 */
        this.closeWindow();
        break;
      default:
        break;
    }
  }

  /* 销毁本 console 窗口（指定多实例 + removeMissionAfterTerminate 会连 mission 一起回收）。
   * VM 死亡时调用一次；terminateSelf 是异步的，用 closed 标志防重复触发 */
  private closeWindow(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.terminateSelf();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'terminateSelf: %{public}s', JSON.stringify(err));
    }
  }

  private qmp(cmd: string, argsJson?: string): void {
    let req = `{"execute":"${cmd}"`;
    if (argsJson) {
      req += `,"arguments":${argsJson}`;
    }
    const resp = napi.qmpCommand(this.vmId, req + '}');
    if (resp.indexOf('"error"') >= 0) {
      promptAction.showToast({ message: cmd + ' 失败: ' + resp.substring(0, 120) });
    }
  }

  /* ================= 触摸手势（单指移动/点击/长按右键，双指滚轮） ================= */

  private sendPtrMedia(vx: number, vy: number, buttons: number): void {
    const px = this.toSurfacePx(vx, this.areaW, this.xcController.surfaceWidth);
    const py = this.toSurfacePx(vy, this.areaH, this.xcController.surfaceHeight);
    this.lastX = vx;
    this.lastY = vy;
    napi.sendPointer(this.vmId, px, py, buttons);
  }

  private cancelLongPress(): void {
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  /* 长按 600ms 且手指几乎没动 → 右键（按下右键，抬起时释放）*/
  private fireLongPress(): void {
    this.longPressTimer = -1;
    this.longPressed = true;
    this.touchButtons = 0x02; /* bit1 = 右键 */
    this.sendPtrMedia(this.lastX, this.lastY, 0x02);
  }

  private handleTouch(event: TouchEvent): void {
    /* 抬起：无论 touches 是否还带着这支手指，一律释放按住的键回空闲 */
    if (event.type === TouchType.Up) {
      this.cancelLongPress();
      const releaseBtns = this.touchButtons;
      this.touchButtons = 0;
      this.singleDown = false;
      this.twoFinger = false;
      this.longPressed = false;
      this.scrollAcc = 0;
      if (releaseBtns !== 0) {
        this.sendPtrMedia(this.lastX, this.lastY, 0);
      }
      return;
    }
    const n = event.touches.length;
    if (n >= 2) {
      /* 双指：垂直滑动 → 滚轮（以两指质心 Y 的累积位移折算步数） */
      const cY = (event.touches[0].y + event.touches[1].y) / 2;
      if (!this.twoFinger) {
        this.twoFinger = true;
        this.scrollCenterY = cY;
        this.scrollAcc = 0;
        this.cancelLongPress();
        this.touchButtons = 0;
        this.singleDown = false;
      } else {
        const delta = cY - this.scrollCenterY;
        this.scrollCenterY = cY;
        this.scrollAcc += delta;
        const step = 28; /* 触摸视图 px → 1 格滚动 */
        while (this.scrollAcc >= step) {
          napi.scroll(this.vmId, 0, 1);
          this.scrollAcc -= step;
        }
        while (this.scrollAcc <= -step) {
          napi.scroll(this.vmId, 0, -1);
          this.scrollAcc += step;
        }
      }
      return;
    }

    if (n === 1) {
      const t = event.touches[0];
      if (this.twoFinger) {
        /* 从双指回到单指：这是滚动结束后残留的手指，不是新点击 */
        this.twoFinger = false;
        this.singleDown = true;
        this.touchButtons = 0;
        this.singleStartX = t.x;
        this.singleStartY = t.y;
        return;
      }
      if (!this.singleDown) {
        this.singleDown = true;
        this.singleStartX = t.x;
        this.singleStartY = t.y;
        this.longPressed = false;
        this.touchButtons = 0x01; /* bit0 = 左键 */
        this.sendPtrMedia(t.x, t.y, 0x01);
        this.cancelLongPress();
        this.longPressTimer = setTimeout(() => this.fireLongPress(), 600);
      } else {
        /* 移动：超过阈值即取消长按（当作拖动） */
        const dx = t.x - this.singleStartX;
        const dy = t.y - this.singleStartY;
        if ((dx > 8 || dx < -8 || dy > 8 || dy < -8) && this.longPressTimer >= 0) {
          this.cancelLongPress();
        }
        this.sendPtrMedia(t.x, t.y, this.touchButtons);
      }
      return;
    }

    /* n === 0：全部抬起 → 释放按住的键 */
    this.cancelLongPress();
    const releaseBtns = this.longPressed ? 0 : this.touchButtons;
    this.touchButtons = 0;
    this.singleDown = false;
    this.twoFinger = false;
    this.longPressed = false;
    if (releaseBtns !== 0) {
      this.sendPtrMedia(this.lastX, this.lastY, 0);
    }
  }

  private saveThumb(): void {
    if (!this.profile || !napi.vmRunning(this.vmId)) {
      return;
    }
    const shot = napi.captureScreen(this.vmId);
    if (!shot || shot.width <= 0) {
      return;
    }
    const store = new VmStore(this.filesDir);
    const thumb = store.thumbPath(this.vmId);
    image.createPixelMap(shot.pixels, {
      size: { width: shot.width, height: shot.height },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false,
    }).then((pixelMap: image.PixelMap) => {
      const fd = fs.openSync(thumb, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      return image.createImagePacker()
        .packToFile(pixelMap, fd.fd, { format: 'image/jpeg', quality: 75 })
        .then(() => {
          fs.closeSync(fd);
          this.vmListVersion++;
        });
    }).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'saveThumb failed: %{public}s', JSON.stringify(err));
    });
  }

  /* ================= 悬浮按钮（拖拽移动 / 点击展开） ================= */

  /* 位置持久化：Preferences 按 vmId 区分不同 VM 的落位 */
  private fabPrefKey(suffix: string): string {
    return `${this.vmId}_${suffix}`;
  }

  private fabCtx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private loadFabPos(): void {
    if (this.vmId.length === 0) {
      return;
    }
    preferences.getPreferences(this.fabCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      const x = prefs.getSync(this.fabPrefKey('x'), -1) as number;
      const y = prefs.getSync(this.fabPrefKey('y'), -1) as number;
      if (x >= 0 && y >= 0) {
        this.fabX = this.clampFabX(x);
        this.fabY = this.clampFabY(y);
      }
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'loadFabPos: %{public}s', JSON.stringify(e));
    });
  }

  private saveFabPos(): void {
    if (this.vmId.length === 0) {
      return;
    }
    preferences.getPreferences(this.fabCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync(this.fabPrefKey('x'), this.fabX);
      prefs.putSync(this.fabPrefKey('y'), this.fabY);
      prefs.flush();
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'saveFabPos: %{public}s', JSON.stringify(e));
    });
  }

  private clampFabX(x: number): number {
    const max = Math.max(0, this.fabW - FAB_SIZE);
    return Math.min(Math.max(0, x), max);
  }

  private clampFabY(y: number): number {
    const max = Math.max(0, this.fabH - FAB_SIZE);
    return Math.min(Math.max(0, y), max);
  }

  /* 初始落位（onAreaChange 第一次拿到窗口大小时）：右下角 */
  private initFab(): void {
    if (this.fabX >= 0) {
      return;
    }
    this.fabX = this.clampFabX(this.fabW - FAB_SIZE - FAB_PAD);
    this.fabY = this.clampFabY(this.fabH - FAB_SIZE - FAB_PAD);
    this.loadFabPos(); /* 有持久化记录就覆盖默认 */
  }

  /* 拖拽 + 点击判定（onTouch 驱动，同 wineohos VirtualDesktop）：
   * 位移 > FAB_DRAG_THRESHOLD → 拖动（移动按钮）；否则视为点击 → 展开/收面板 */
  private onFabTouch(ev: TouchEvent): void {
    if (ev.type === TouchType.Down) {
      const t = ev.touches[0];
      if (t) {
        this.fabStartX = t.windowX;
        this.fabStartY = t.windowY;
      }
      this.fabBtnX = this.fabX;
      this.fabBtnY = this.fabY;
      this.fabMoved = false;
    } else if (ev.type === TouchType.Move) {
      const t = ev.touches[0];
      if (t) {
        if (!this.fabMoved &&
          (Math.abs(t.windowX - this.fabStartX) > FAB_DRAG_THRESHOLD ||
            Math.abs(t.windowY - this.fabStartY) > FAB_DRAG_THRESHOLD)) {
          this.fabMoved = true;
        }
        if (this.fabMoved) {
          this.fabX = this.clampFabX(this.fabBtnX + (t.windowX - this.fabStartX));
          this.fabY = this.clampFabY(this.fabBtnY + (t.windowY - this.fabStartY));
        }
      }
    } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
      if (this.fabMoved) {
        this.saveFabPos(); /* 拖动落位 → 持久化（跨窗口/重开记住） */
      } else {
        this.menuOpen = !this.menuOpen;
      }
      this.fabMoved = false;
    }
  }

  /* 虚拟键盘显隐持久化（Preferences 按 vmId 区分，重开窗口记住开/关） */
  private loadKbd(): void {
    if (this.vmId.length === 0) {
      return;
    }
    preferences.getPreferences(this.fabCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      this.showKbd = prefs.getSync(this.fabPrefKey('kbd'), false) as boolean;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'loadKbd: %{public}s', JSON.stringify(e));
    });
  }

  private toggleKbd(): void {
    this.showKbd = !this.showKbd;
    preferences.getPreferences(this.fabCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync(this.fabPrefKey('kbd'), this.showKbd);
      prefs.flush();
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'saveKbd: %{public}s', JSON.stringify(e));
    });
  }

  private actReset(): void {
    this.qmp('send-key',
      '{"keys":[{"type":"qcode","data":"ctrl"},' +
      '{"type":"qcode","data":"alt"},' +
      '{"type":"qcode","data":"delete"}]}');
  }

  @Builder
  fabMenuHeader() {
    Row() {
      Text(this.status).fontSize(tMono).fontColor('#ffb8c4d0').layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('×').fontSize(tBody).fontColor('#ffb8c4d0')
        .padding({ left: sp2, right: sp2 })
        .onClick(() => {
          this.menuOpen = false;
        })
    }
    .width('100%')
    .padding({ left: sp3, right: sp3, top: sp1, bottom: sp1 })
    .borderRadius(rElem)
    .backgroundColor('#22000000')
  }

  /* 竖向面板：电源四项全部平铺 / Ctrl+Alt+Del / 串口。
   * 去除截图/全屏/QMP（用户反馈不需要）。点击即执行 */
  @Builder
  fabMenu() {
    Column({ space: 2 }) {
      this.fabMenuHeader()
      Button('关机 (ACPI)').focusable(false).fontSize(tBody)
        .fontColor(MENU_TEXT).width('100%').height(btnH).borderRadius(rBtn)
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.qmp('system_powerdown') })
      Button('重启 (Reset)').focusable(false).fontSize(tBody)
        .fontColor(MENU_TEXT).width('100%').height(btnH).borderRadius(rBtn)
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.qmp('system_reset') })
      Button('强制断电').focusable(false).fontSize(tBody)
        .fontColor(cDanger).width('100%').height(btnH).borderRadius(rBtn)
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.qmp('quit') })
      Button('Ctrl+Alt+Del').focusable(false).fontSize(tBody)
        .fontColor(MENU_TEXT).width('100%').height(btnH).borderRadius(rBtn)
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.actReset() })
      Button(this.showKbd ? '隐藏键盘' : '虚拟键盘').focusable(false).fontSize(tBody)
        .fontColor(this.showKbd ? cPrimary : MENU_TEXT).width('100%').height(btnH).borderRadius(rBtn)
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.toggleKbd() })
    }
    .width(PANEL_W)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(rElem)
    .backgroundColor('#e620242b')
    .border({ width: 1, color: '#66FFFFFF' })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        XComponent({ type: XComponentType.SURFACE, controller: this.xcController })
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(Color.Black)
          .onAreaChange((oldArea: Area, newArea: Area) => {
            this.areaW = newArea.width as number;
            this.areaH = newArea.height as number;
            this.fabW = newArea.width as number;
            this.fabH = newArea.height as number;
            this.initFab();
          })
          .onTouch((event: TouchEvent) => this.handleTouch(event))
      }
      .width('100%')
      .height('100%')

      /* 虚拟键盘 overlay：VM 画面之上、悬浮按钮之下。面板空白处透传给画面，
       * 键帽/把手消费触摸（见 VirtualKeyboard 组件 hitTest 说明） */
      if (isPadOrPhone() &&this.showKbd) {
        VirtualKeyboard({ vmId: this.vmId, showKbd: this.$showKbd })
      }

      /* 面板展开时：点面板外的空白区收起面板（透明 catcher，盖在 VM 之上）。
       * 用 Stack 全屏透明层拦截触摸，避免点穿透到客机输入 */
      if (isPadOrPhone() &&this.menuOpen) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#0a000000')
          .onClick(() => {
            this.menuOpen = false;
          })
      }

      /* 悬浮操作面板：停在按钮正上方、右缘与按钮对齐。用固定高度的定位盒 +
       * Blank 撑底，让面板内容自底部向上生长（分组标题/多按钮往上扩，不剪裁）。 */
      if (isPadOrPhone() &&this.menuOpen && this.fabX >= 0) {
        Column() {
          Blank()
          Column() {
            this.fabMenu()
          }
          .width('100%')
          .align(Alignment.BottomEnd)
        }
        .width(PANEL_W)
        .height(MENU_BOX_H)
        .position({
          x: this.fabX + FAB_SIZE - PANEL_W,
          y: this.fabY - 6 - MENU_BOX_H,
        })
      }

      /* 半透明可拖拽悬浮圆钮（替代顶部工具条）：点击展开/收起面板，拖动移动 */
      if (isPadOrPhone() &&this.fabX >= 0) {
        Stack() {
          Text('≡').fontSize(22).fontColor(Color.White).fontWeight(FontWeight.Bold)
        }
        .width(FAB_SIZE)
        .height(FAB_SIZE)
        .borderRadius(FAB_SIZE / 2)
        .backgroundColor('#33000000')
        .border({ width: 1, color: '#66FFFFFF', style: BorderStyle.Solid })
        .position({ x: this.fabX, y: this.fabY })
        .onTouch((ev: TouchEvent) => this.onFabTouch(ev))
      }
    }
    .width('100%')
    .height('100%')
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      const qcode = HOS_TO_QKEYCODE.get(event.keyCode);
      if (qcode === undefined) {
        return;
      }
      if (event.type === KeyType.Down) {
        napi.sendKey(this.vmId, qcode, true);
      } else if (event.type === KeyType.Up) {
        napi.sendKey(this.vmId, qcode, false);
      }
      event.stopPropagation();
    })
  }
}
