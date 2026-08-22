// 虚拟机 Console 页：独立窗口（VmConsoleAbility）内的 XComponent 渲染 +
// 顶部工具条（电源/QMP 控制/截图/全屏）。vmId 经 LocalStorage 传入，页面按
// vmId 自载 profile。VM 跑在 NCP 子进程，关窗只是摘窗，重开窗口即重新挂窗。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';
import { VmProfile, VmStore, buildArgs, qmpSockPath, sharedDir } from '../lib/vmprofile';
import { prepareStart } from '../lib/tempSession';
import { getConsoleWindow, takePendingVmId } from '../lib/vmwindows';
import { cDanger, rBtn, btnSh } from '../lib/uiTokens';

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
  qmpConnected: (vmId: string) => boolean;
  setQmpEventCallback: (vmId: string, cb: ((evt: string) => void) | null) => void;
  captureScreen: (vmId: string) => ScreenShotBuf | null;
}

const napi: QemuNapi = napiModule as QemuNapi;

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

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
  @State paused: boolean = false;
  @State fullscreen: boolean = true; /* 窗口默认沉浸式 */
  /* 串口尾随面板 */
  @State showSerial: boolean = false;
  @State serialText: string = '';
  /* QMP 工具面板 */
  @State showQmp: boolean = false;
  @State qmpCmd: string = '';
  @State qmpResp: string = '';
  @State qmpEvents: string[] = [];
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
    this.qmpEvents.push(name);
    if (this.qmpEvents.length > 50) {
      this.qmpEvents = this.qmpEvents.slice(-50);
    }
    switch (name) {
      case 'STOP':
        this.paused = true;
        this.status = 'paused';
        break;
      case 'RESUME':
        this.paused = false;
        this.status = 'running';
        break;
      case 'RESET':
        this.status = 'running (reset)';
        break;
      case 'SHUTDOWN':
      case 'QMP_DISCONNECT':
        this.paused = false;
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

  /* ================= 串口尾随 ================= */

  private refreshSerial(): void {
    if (!this.profile) {
      return;
    }
    const path = `${this.vmDataDir}/serial-${this.profile.id}.log`;
    let text = '';
    try {
      if (fs.accessSync(path)) {
        const fd = fs.openSync(path, fs.OpenMode.READ_ONLY);
        const buf = new ArrayBuffer(256 * 1024);
        const n = fs.readSync(fd.fd, buf);
        fs.closeSync(fd);
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n));
      }
    } catch {
      text = '';
    }
    this.serialText = text.length > 0 ? text : '（串口为空）';
  }

  private toggleSerial(): void {
    this.showSerial = !this.showSerial;
    this.showQmp = false;
    if (this.showSerial) {
      this.refreshSerial();
    }
  }

  /* ================= QMP 工具页 ================= */

  private sendQmpCmd(): void {
    const cmd = this.qmpCmd.trim();
    if (cmd.length === 0) {
      promptAction.showToast({ message: '请输入 QMP 命令' });
      return;
    }
    this.qmpResp = napi.qmpCommand(this.vmId, cmd);
    this.qmpEvents = []; /* 发送即清空事件流，聚焦当前往返 */
  }

  private toggleQmp(): void {
    this.showQmp = !this.showQmp;
    this.showSerial = false;
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

  /* 沉浸式（隐藏系统栏） ↔ 显示系统栏；窗口本身始终全出血布局 */
  private toggleFullscreen(): void {
    const win = getConsoleWindow(this.vmId);
    if (!win) {
      return;
    }
    this.fullscreen = !this.fullscreen;
    const visible = !this.fullscreen;
    win.setSpecificSystemBarEnabled('status', visible)
      .catch((err: Object) => hilog.warn(DOMAIN, TAG, 'status bar: %{public}s', JSON.stringify(err)));
    win.setSpecificSystemBarEnabled('navigationIndicator', visible)
      .catch((err: Object) => hilog.warn(DOMAIN, TAG, 'navi bar: %{public}s', JSON.stringify(err)));
  }

  @Builder
  powerBuilder() {
    Column({ space: 4 }) {
      Button('关机 (ACPI)').focusable(false).width('100%')
        .height(btnSh).borderRadius(rBtn)
        .onClick(() => this.qmp('system_powerdown'))
      Button(this.paused ? '恢复运行' : '暂停').focusable(false).width('100%')
        .height(btnSh).borderRadius(rBtn)
        .onClick(() => this.qmp(this.paused ? 'cont' : 'stop'))
      Button('重启').focusable(false).width('100%')
        .height(btnSh).borderRadius(rBtn)
        .onClick(() => this.qmp('system_reset'))
      Button('强制断电').focusable(false).width('100%')
        .height(btnSh).borderRadius(rBtn)
        .fontColor(cDanger)
        .onClick(() => this.qmp('quit'))
    }
    .width(140)
    .padding(8)
    .backgroundColor(Color.White)
    .borderRadius(8)
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
          })
          .onTouch((event: TouchEvent) => this.handleTouch(event))
      }
      .width('100%')
      .height('100%')

      Row({ space: 8 }) {
        Button('电源').focusable(false).fontSize(13)
          .height(btnSh).borderRadius(rBtn)
          .bindMenu(this.powerBuilder())
        Button('Ctrl+Alt+Del').focusable(false).fontSize(13)
          .height(btnSh).borderRadius(rBtn)
          .onClick(() => this.qmp('send-key',
            '{"keys":[{"type":"qcode","data":"ctrl"},' +
            '{"type":"qcode","data":"alt"},' +
            '{"type":"qcode","data":"delete"}]}'))
        Button('截图').focusable(false).fontSize(13)
          .height(btnSh).borderRadius(rBtn)
          .onClick(() => {
            this.saveThumb();
            promptAction.showToast({ message: '已保存为虚拟机封面' });
          })
        Button(this.fullscreen ? '退出全屏' : '全屏').focusable(false).fontSize(13)
          .height(btnSh).borderRadius(rBtn)
          .onClick(() => this.toggleFullscreen())
        Button('串口').focusable(false).fontSize(13)
          .height(btnSh).borderRadius(rBtn)
          .onClick(() => this.toggleSerial())
        Button('QMP').focusable(false).fontSize(13)
          .height(btnSh).borderRadius(rBtn)
          .onClick(() => this.toggleQmp())
        Text(this.status).fontSize(12).fontColor(Color.White).layoutWeight(1)
      }
      .width('100%')
      .padding(6)
      .backgroundColor('#99000000')

      /* 串口尾随抽屉 */
      if (this.showSerial) {
        Column({ space: 6 }) {
          Row() {
            Text('串口输出').fontSize(13).fontColor(Color.White)
            Blank()
            Button('刷新').focusable(false).fontSize(12)
              .onClick(() => this.refreshSerial())
          }.width('100%')
          Scroll() {
            Text(this.serialText).fontSize(11).fontColor('#ffdddddd')
              .width('100%')
          }
          .layoutWeight(1)
          .align(Alignment.TopStart)
        }
        .width('100%')
        .height(220)
        .padding(8)
        .backgroundColor('#cc000000')
        .align(Alignment.Bottom)
      }

      /* QMP 工具抽屉 */
      if (this.showQmp) {
        Column({ space: 6 }) {
          Row() {
            Text('QMP 命令').fontSize(13).fontColor(Color.White)
            Blank()
            Text(`已连: ${napi.qmpConnected(this.vmId)}`).fontSize(11).fontColor('#ff99ccff')
          }.width('100%')
          TextInput({ text: this.qmpCmd, placeholder: '如 {"execute":"query-status"}' })
            .fontColor(Color.White)
            .backgroundColor('#88333333')
            .onChange((v: string) => this.qmpCmd = v)
          Button('发送').focusable(false).fontSize(13)
            .onClick(() => this.sendQmpCmd())
          Scroll() {
            Text(this.qmpResp.length > 0 ? this.qmpResp : '（暂无响应，发送一条命令试试）')
              .fontSize(11)
              .fontColor('#ffdddddd')
              .width('100%')
          }
          .layoutWeight(1)
          .align(Alignment.TopStart)
          Text('事件流: ' + (this.qmpEvents.length > 0 ? this.qmpEvents.join(' · ') : '（无）'))
            .fontSize(10)
            .fontColor('#ffbbbbbb')
            .width('100%')
        }
        .width('100%')
        .height(260)
        .padding(8)
        .backgroundColor('#cc000000')
        .align(Alignment.Bottom)
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
