// 虚拟机 Console 页：XComponent 渲染 + 顶部工具条（电源/QMP 控制/截图）。
// VM 跑在 NCP 子进程，生命周期跨页面存活：离开本页只是摘窗，重进时重新挂窗。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';
import { VmProfile, VmStore, buildArgs } from '../lib/vmprofile';

interface ScreenShotBuf {
  width: number;
  height: number;
  pixels: ArrayBuffer;
}

interface QemuNapi {
  startVm: (arch: string, args: string[], surfaceId: bigint) => number;
  vmRunning: () => boolean;
  createSurface: (surfaceId: bigint) => number;
  resizeSurface: (w: number, h: number) => number;
  destroySurface: () => number;
  sendPointer: (x: number, y: number, buttons: number) => void;
  sendKey: (qcode: number, down: boolean) => void;
  qmpConnect: (port: number) => number;
  qmpCommand: (cmd: string) => string;
  qmpConnected: () => boolean;
  setQmpEventCallback: (cb: ((evt: string) => void) | null) => void;
  captureScreen: () => ScreenShotBuf | null;
}

const napi: QemuNapi = napiModule as QemuNapi;

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

interface QmpEvent {
  event: string;
}

class VmXComponentController extends XComponentController {
  surfaceId: bigint = 0n;
  surfaceWidth: number = 0;
  surfaceHeight: number = 0;
  onReady: (() => void) | null = null;

  onSurfaceCreated(surfaceId: string): void {
    this.surfaceId = BigInt(surfaceId);
    /* 页面转场期间立刻挂窗会得到坏 queue（swap 必报 EGL_BAD_SURFACE）：
     * 等转场稳定后再挂（实测 500ms 足够；首启的 START 自带窗口不受影响） */
    const id = this.surfaceId;
    setTimeout(() => {
      napi.createSurface(id);
      if (this.onReady) {
        this.onReady();
      }
    }, 500);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    this.surfaceWidth = rect.surfaceWidth;
    this.surfaceHeight = rect.surfaceHeight;
    napi.resizeSurface(rect.surfaceWidth, rect.surfaceHeight);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    napi.destroySurface();
    this.surfaceId = 0n;
  }
}

@Component
export struct Console {
  profile: VmProfile | null = null;
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('runningVmId') runningVmId: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;
  @State status: string = '';
  @State paused: boolean = false;
  private xcController: VmXComponentController = new VmXComponentController();
  private touchButtons: number = 0;
  private areaW: number = 0;
  private areaH: number = 0;
  private surfaceReady: boolean = false;
  private startPending: boolean = false;

  private toSurfacePx(vp: number, vpSize: number, surfaceSize: number): number {
    if (vpSize <= 0 || surfaceSize <= 0) {
      return Math.round(vp);
    }
    return Math.round(vp * surfaceSize / vpSize);
  }

  aboutToAppear(): void {
    this.xcController.onReady = () => {
      this.surfaceReady = true;
      if (this.startPending) {
        this.startPending = false;
        this.startVm();
      }
    };
    napi.setQmpEventCallback((evt: string) => this.onQmpEvent(evt));
    this.enterVm();
  }

  aboutToDisappear(): void {
    napi.setQmpEventCallback(null);
    this.saveThumb(); /* 顺手更新列表页缩略图 */
  }

  private enterVm(): void {
    if (!this.profile) {
      return;
    }
    if (napi.vmRunning() && this.runningVmId === this.profile.id) {
      this.status = 'running';
      napi.qmpConnect(this.profile.qmpPort);
      return;
    }
    if (this.surfaceReady) {
      this.startVm();
    } else {
      this.startPending = true; /* 等 surface 起来再启动，避免黑屏竞态 */
    }
  }

  private startVm(): void {
    if (!this.profile || napi.vmRunning()) {
      return;
    }
    if (this.xcController.surfaceId === 0n) {
      this.startPending = true;
      return;
    }
    /* 每次启动都是一个新的 NCP 子进程，不再有「一进程一轮 VM」的重启流程 */
    const ret = napi.startVm(this.profile.arch, buildArgs(this.profile, this.vmDataDir),
      this.xcController.surfaceId);
    if (ret !== 0) {
      this.status = '启动失败: ' + ret;
      return;
    }
    this.runningVmId = this.profile.id;
    this.status = 'starting...';
    napi.qmpConnect(this.profile.qmpPort);
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
        if (this.runningVmId === this.profile?.id) {
          this.runningVmId = '';
        }
        this.vmListVersion++;
        break;
      default:
        break;
    }
  }

  private qmp(cmd: string, argsJson?: string): void {
    let req = `{"execute":"${cmd}"`;
    if (argsJson) {
      req += `,"arguments":${argsJson}`;
    }
    const resp = napi.qmpCommand(req + '}');
    if (resp.indexOf('"error"') >= 0) {
      promptAction.showToast({ message: cmd + ' 失败: ' + resp.substring(0, 120) });
    }
  }

  private saveThumb(): void {
    if (!this.profile || !napi.vmRunning()) {
      return;
    }
    const shot = napi.captureScreen();
    if (!shot || shot.width <= 0) {
      return;
    }
    const store = new VmStore(this.filesDir);
    const thumb = store.thumbPath(this.profile.id);
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
            napi.sendPointer(px, py, this.touchButtons);
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
        napi.sendKey(qcode, true);
      } else if (event.type === KeyType.Up) {
        napi.sendKey(qcode, false);
      }
      event.stopPropagation();
    })
  }
}
