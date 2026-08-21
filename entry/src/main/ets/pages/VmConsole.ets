// 虚拟机 Console 页：独立窗口（VmConsoleAbility）内的 XComponent 渲染 +
// 顶部工具条（电源/QMP 控制/截图/全屏）。vmId 经 LocalStorage 传入，页面按
// vmId 自载 profile。VM 跑在 NCP 子进程，关窗只是摘窗，重开窗口即重新挂窗。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';
import { VmProfile, VmStore, buildArgs, qmpSockPath } from '../lib/vmprofile';
import { getConsoleWindow, takePendingVmId } from '../lib/vmwindows';

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
  private vmId: string = '';
  private profile: VmProfile | null = null;
  private xcController: VmXComponentController = new VmXComponentController();
  private touchButtons: number = 0;
  private areaW: number = 0;
  private areaH: number = 0;
  private surfaceReady: boolean = false;
  private startPending: boolean = false;
  private closed: boolean = false; /* VM 已死导致本窗口即将销毁，防重复 terminate */

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
    /* 每次启动都是一个新的 NCP 子进程；多实例按 vmId 各起各的 */
    const ret = napi.startVm(this.vmId, this.profile.arch,
      buildArgs(this.profile, this.vmDataDir), this.xcController.surfaceId);
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
        .onClick(() => this.qmp('system_powerdown'))
      Button(this.paused ? '恢复运行' : '暂停').focusable(false).width('100%')
        .onClick(() => this.qmp(this.paused ? 'cont' : 'stop'))
      Button('重启').focusable(false).width('100%')
        .onClick(() => this.qmp('system_reset'))
      Button('强制断电').focusable(false).width('100%')
        .fontColor(Color.Red)
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
          .onTouch((event: TouchEvent) => {
            const touch = event.touches.length > 0 ? event.touches[0] : undefined;
            if (!touch) {
              return;
            }
            switch (event.type) {
              case TouchType.Down:
                this.touchButtons = 0x01;
                break;
              case TouchType.Up:
                this.touchButtons = 0;
                break;
              default:
                break;
            }
            const px = this.toSurfacePx(touch.x, this.areaW, this.xcController.surfaceWidth);
            const py = this.toSurfacePx(touch.y, this.areaH, this.xcController.surfaceHeight);
            napi.sendPointer(this.vmId, px, py, this.touchButtons);
          })
      }
      .width('100%')
      .height('100%')

      Row({ space: 8 }) {
        Button('电源').focusable(false).fontSize(13)
          .bindMenu(this.powerBuilder())
        Button('Ctrl+Alt+Del').focusable(false).fontSize(13)
          .onClick(() => this.qmp('send-key',
            '{"keys":[{"type":"qcode","data":"ctrl"},' +
            '{"type":"qcode","data":"alt"},' +
            '{"type":"qcode","data":"delete"}]}'))
        Button('截图').focusable(false).fontSize(13)
          .onClick(() => {
            this.saveThumb();
            promptAction.showToast({ message: '已保存为虚拟机封面' });
          })
        Button(this.fullscreen ? '退出全屏' : '全屏').focusable(false).fontSize(13)
          .onClick(() => this.toggleFullscreen())
        Text(this.status).fontSize(12).fontColor(Color.White).layoutWeight(1)
      }
      .width('100%')
      .padding(6)
      .backgroundColor('#99000000')
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
