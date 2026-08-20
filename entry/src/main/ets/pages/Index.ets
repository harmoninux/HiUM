import { hilog } from '@kit.PerformanceAnalysisKit';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';

interface QemuNapi {
  startVm: (arch: string, args: string[]) => number;
  vmRunning: () => boolean;
  createSurface: (surfaceId: bigint) => number;
  resizeSurface: (surfaceId: bigint, w: number, h: number) => number;
  destroySurface: (surfaceId: bigint) => number;
  sendPointer: (x: number, y: number, buttons: number) => void;
  sendKey: (qcode: number, down: boolean) => void;
}

const testNapi: QemuNapi = napiModule as QemuNapi;

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

type Arch = 'x86_64' | 'i386' | 'aarch64';

class VmXComponentController extends XComponentController {
  surfaceWidth: number = 0;
  surfaceHeight: number = 0;
  onReady: (() => void) | null = null;

  onSurfaceCreated(surfaceId: string): void {
    hilog.info(DOMAIN, TAG, 'XComponent surface created: %{public}s', surfaceId);
    testNapi.createSurface(BigInt(surfaceId));
    if (this.onReady) {
      this.onReady();
    }
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    this.surfaceWidth = rect.surfaceWidth;
    this.surfaceHeight = rect.surfaceHeight;
    testNapi.resizeSurface(BigInt(surfaceId), rect.surfaceWidth, rect.surfaceHeight);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    testNapi.destroySurface(BigInt(surfaceId));
  }
}

@Entry
@Component
struct Index {
  @State arch: Arch = 'x86_64';
  @State status: string = 'idle';
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('firmwareReady') firmwareReady: boolean = false;
  private xcController: VmXComponentController = new VmXComponentController();
  private touchButtons: number = 0;
  private timerId: number = -1;
  private areaW: number = 0; /* XComponent size in vp */
  private areaH: number = 0;

  /* touch coords are vp relative to the XComponent; native side expects
   * physical pixels of the underlying surface */
  private toSurfacePx(vp: number, vpSize: number, surfaceSize: number): number {
    if (vpSize <= 0 || surfaceSize <= 0) {
      return Math.round(vp);
    }
    return Math.round(vp * surfaceSize / vpSize);
  }

  aboutToAppear(): void {
    this.timerId = setInterval(() => {
      this.status = testNapi.vmRunning() ? 'running' : this.status;
    }, 1000);
    /* PoC: auto-start the VM once the surface is up */
    this.xcController.onReady = () => {
      if (!testNapi.vmRunning()) {
        this.startVm();
      }
    };
  }

  aboutToDisappear(): void {
    clearInterval(this.timerId);
  }

  private buildArgs(arch: Arch): string[] {
    let args: string[] = [
      '-L', this.vmDataDir,
      '-m', '1024',
      '-smp', '2',
      '-accel', 'tcg,thread=multi,tb-size=1024',
      '-display', 'none',
      '-device', 'virtio-tablet-pci',
      '-netdev', 'user,id=n0',
      '-device', 'virtio-net-pci,netdev=n0',
    ];
    if (arch === 'aarch64') {
      args = args.concat([
        '-machine', 'virt',
        '-cpu', 'max',
        '-device', 'virtio-gpu-pci',
      ]);
    } else {
      args = args.concat([
        '-vga', 'std',
        '-cdrom', this.vmDataDir + '/alpine-virt.iso',
        '-boot', 'd',
        '-serial', 'file:' + this.vmDataDir + '/serial.log',
      ]);
    }
    return args;
  }

  private startVm(): void {
    if (!this.firmwareReady) {
      this.status = 'firmware missing (run deps build first)';
      return;
    }
    const ret = testNapi.startVm(this.arch, this.buildArgs(this.arch));
    this.status = ret === 0 ? 'starting...' : ('start failed: ' + ret);
  }

  build() {
    Column() {
      Row() {
        Select([{ value: 'x86_64' }, { value: 'i386' }, { value: 'aarch64' }])
          .selected(0)
          .value(this.arch)
          .focusable(false)
          .onSelect((index: number, value?: string) => {
            this.arch = (value ?? 'x86_64') as Arch;
          })
        Button('Start VM')
          .focusable(false)
          .onClick(() => this.startVm())
        Text(this.status)
          .fontSize(14)
          .margin({ left: 12 })
      }
      .width('100%')
      .padding(8)
      .alignItems(VerticalAlign.Center)

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
          testNapi.sendPointer(px, py, this.touchButtons);
        })
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
        testNapi.sendKey(qcode, true);
      } else if (event.type === KeyType.Up) {
        testNapi.sendKey(qcode, false);
      }
      event.stopPropagation();
    })
  }
}
