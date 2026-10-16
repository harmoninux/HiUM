// 虚拟机 Console 页：独立窗口（VmConsoleAbility）内的 XComponent 渲染 +
// 底部状态栏（电源/暂停/介质/串口/输入/虚拟键盘）。vmId 经 LocalStorage 传入，
// 页面按 vmId 自载 profile。VM 跑在 NCP 子进程，关窗只是摘窗，重开窗口即重新挂窗。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction, window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';
import { VmProfile, VmStore, buildArgs, qmpSockPath, serialSockPath, serialLogPath, thumbPath, sharedDir, builtinIsoFor, mainDiskPath, ensureRiscvVars } from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pathExists, isoReadable, readTail } from '../lib/fsutil';
import { pickIsoPath } from '../lib/isoPick';
import { prepareStart } from '../lib/tempSession';
import { takePendingVmId, isPadOrPhone } from '../lib/vmwindows';
import { VirtualKeyboard } from '../lib/VirtualKeyboard';
import {
  sp1, sp2, sp3, cCard, cText, cPrimary, cDanger,
  cConsoleText, cConsoleAccent, cConsoleLogText, cConsoleWarn,
  cConsolePanel, cConsolePanelStrong, cConsoleInputBg, cConsolePlaceholder,
  cConsoleBanner, cConsoleBtn, cConsoleScrim,
  cConsolePanelSolid, cConsoleLogBg, cConsoleKey, cConsolePrimary, rConsole,
} from '../lib/uiTokens';

/* 多 ISO 启动前的可读性过滤在 doStart 内做：把不可读盘从本次启动的 ISO 列表里剔除，
 * 再经 buildArgs 的 isoOverride 传入（不动 profile 对象，避免污染后续配置/结算）。 */

interface QemuNapi {
  startVm: (vmId: string, arch: string, args: string[], surfaceId: bigint) => number;
  vmRunning: (vmId: string) => boolean;
  vmSnapshot: (vmIds: string[]) => Object;
  createSurface: (vmId: string, surfaceId: bigint) => number;
  resizeSurface: (vmId: string, w: number, h: number) => number;
  destroySurface: (vmId: string) => number;
  sendPointer: (vmId: string, x: number, y: number, buttons: number) => void;
  sendKey: (vmId: string, qcode: number, down: boolean) => void;
  scroll: (vmId: string, dx: number, dy: number) => void;
  qmpConnect: (vmId: string, sockPath: string) => number;
  qmpCommand: (vmId: string, cmd: string) => string;
  qmpReady: (vmId: string) => boolean;
  forceStopVm: (vmId: string) => number;
  setQmpEventCallback: (vmId: string, cb: ((evt: string) => void) | null) => void;
  serialOpen: (vmId: string, sockPath: string) => number;
  serialWrite: (vmId: string, text: string) => number;
  serialClose: (vmId: string) => void;
  setSerialCallback: (vmId: string, cb: ((text: string) => void) | null) => void;
  /* 子进程抓帧缩放到 ≤512 宽后写 path（缩略图文件，数据不走 parcel，见
   * qemu_ipc.h kScreenshot）；返回实际宽高，未出帧/进程已死/写盘失败返回 null */
  captureScreen: (vmId: string, path: string) => CaptureShot | null;
}

interface CaptureShot {
  width: number;
  height: number;
}

/* 介质菜单里的一个光驱槽位（query-block 认定，见 refreshCdSlots） */
interface CdSlot {
  qmpId: string; /* QMP 块后端名（'cdN' 或 pc/q35 第一张的 'ide1-cd0'） */
  file: string;  /* 当前介质路径；'' = 空盘 */
}

const napi: QemuNapi = napiModule as QemuNapi;

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

/* 悬浮钮 + 工具栏（替代底部状态栏）：半透明圆钮浮在画面顶部，可拖拽移动
 * （位置只在本次窗口会话内有效，不做持久化），点击展开/收起工具栏。 */
/* 工具栏字号：11/12 是「细条状态栏」语境的档——改成悬浮浮层后该档显小，
 * 升到条目档 14/28（浮层与窗口形态（Pad/PC）无关，不再分档）。
 * 串口面板/黑底浮层字号（PANEL_FS）不经工具栏，维持原值。 */
const BAR_BTN_H = 28;
const BAR_FS = 14;
/* 钮拖拽判定阈值（vp）：位移超过视为拖动，否则算点击（展开/收起工具栏） */
const BAR_DRAG_THRESHOLD = 5;
/* 串口面板与黑底浮层（熔断横幅/手势速查）：独立专档，不随工具栏档变化 */
const PANEL_H = 32;
const PANEL_BTN_H = 26;
const PANEL_FS = 12;
/* 串口日志区固定高（约 7~8 行 12 号字的等宽行） */
const SERIAL_LOG_H = 144;
const FAB_PREF = 'vmconsole_fab'; /* console 偏好文件名（虚拟键盘显隐 / 输入设置 / 串口字号共用） */
/* 串口输入框的组件 id：发送后要把焦点交还给它（见 sendAndRefocus） */
const SERIAL_INPUT_ID = 'hium-serial-input';
/* 双指 tap 判定阈值（vp）：质心自双指落下起的累计位移小于该值、且期间没发过
 * 滚轮，抬起时合成一次右键点击。取值比单指移动阈值(8)放宽——两指比单指易抖 */
const TWO_TAP_SLOP = 12;
/* 触控板（相对）模式的光标速度档：手指位移 × 倍率 = 光标位移 */
const SPEED_FACTORS: number[] = [0.6, 1.0, 1.7];
const SPEED_LABELS: string[] = ['慢', '中', '快'];
/* QMP 命令名 → 动作的中文说法（qmp() 失败提示用；原始命令名/响应只进 hilog，
 * 不外露给用户） */
const QMP_CMD_CN: Record<string, string> = {
  'system_reset': '重启',
  'system_powerdown': '关机',
  'quit': '关机',
  'stop': '暂停',
  'cont': '继续',
  'eject': '弹出光盘',
  'blockdev-change-medium': '更换光盘',
  'send-key': '发送按键',
};
/* 串口日志字号合法档（偏好校验用；字号循环键帽已随键帽精简移除） */
const SERIAL_FS_LIST: number[] = [12, 14, 17];
/* 惯性滑行的速度衰减与停止阈值（每 16ms 一拍）：0.82 的衰减下约 0.5s 滑停 */
const GLIDE_DECAY = 0.82;
const GLIDE_STOP = 0.4;
const GLIDE_MIN_START = 1.2;

interface QmpEvent {
  event: string;
}

class VmXComponentController extends XComponentController {
  vmId: string = '';
  surfaceId: bigint = 0n;
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

  /* 不透传给渲染器：系统拖拽期会发「铺满窗口内容区」的异形尺寸（比例偏离组件，
   * 见 syncBufferGeometry 注释），照单全收会把 buffer 做成异形 */
  onSurfaceChanged(_surfaceId: string, _rect: SurfaceRect): void {
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
  /* vmListVersion：仅作「写通道」用（截图完成/改名后 bump 通知列表与详情页刷新）；
   * 窗口标题由系统标题栏展示 VM 名，console 内不再持有名称副本 */
  @StorageLink('vmListVersion') vmListVersion: number = 0;
  @State status: string = '';
  /* QMP 可用（就绪往返过一次）：关机/重启/Ctrl+Alt+Del 的启用依据。
   * build 里不问 napi.vmRunning（同步 IPC 往返），经本状态由事件驱动翻转 */
  @State qmpAlive: boolean = false;
  @State paused: boolean = false; /* guest 暂停态（QMP STOP/RESUME 事件驱动；电源菜单显示 暂停/继续） */
  @State cdSlots: CdSlot[] = [];  /* 光驱槽位与当前介质（介质菜单数据源，query-block 拉取） */
  /* 输入设置（触屏/触控板模式、滚轮反向、光标速度档；全局偏好，见 loadInputPrefs） */
  @State inputMode: number = 0;
  @State scrollReverse: boolean = false;
  @State cursorSpeedIdx: number = 1;
  @State serialFs: number = SERIAL_FS_LIST[0]; /* 串口日志字号（全局偏好） */
  @State showKbd: boolean = false;   /* 虚拟键盘显隐（工具栏开关，按 vmId 持久化） */
  @State showGestureHint: boolean = false; /* 首次进入的手势速查（全局看过一次不再弹） */
  @State immersive: boolean = false; /* 沉浸全屏态（最大化进入）：隐藏系统栏；页内浮层不占布局、常驻 */
  @State barOpen: boolean = false;   /* 悬浮工具栏展开态（默认收起，只有一枚小钮浮在画面） */
  /* 悬浮钮位置：以屏幕顶部中点为原点的偏移（默认 0/0 = 顶部居中；拖动只改
   * 偏移，窗口缩放/最大化后自动跟随——居中是动态约束而非一次性落位） */
  @State barOffX: number = 0;
  @State barOffY: number = 0;
  @State toolbarW: number = 0; /* 工具栏实测宽高（以钮为中心定位；0 = 尚未测出） */
  @State toolbarH: number = 0;
  /* v5 交互式串口：serialView=串口浮层面板打开（悬浮画面底部之上，画面满幅）；
   * 文本/输入/Ctrl 修饰态均在页内 */
  @State serialView: boolean = false;
  @State serialText: string = '';
  @State serialInput: string = '';
  /* 上次启动失败留下的熔断标记（非空 = 本次进入不自动启动，需用户点「仍要启动」） */
  @State bootFailReason: string = '';
  private vmId: string = '';
  private profile: VmProfile | null = null;
  /* 就绪轮询：QMP 一次成功往返才算「起来了」（见 native qmpReady 的说明）。
   * 启动中 → qmpReady → 运行中；T 内 !vmRunning → 启动失败；T 内仍活着但没就绪 → 疑似卡死。 */
  private readyTimer: number = -1;
  private readySeen: boolean = false; /* 本窗口内是否见过 qemu 就绪；决定「死了」怎么处理 */
  private stuck: boolean = false; /* 超出等待窗口仍未就绪：跳过 quit，直接走 IPC 强杀 */
  /* 用户主动停止（关机/强制断电）：QMP_DISCONNECT 随之而来，但那不是「启动失败」，
   * 不能写熔断标记，否则每次正常关机都会让下次进入不自动启动。 */
  private userStopped: boolean = false;
  private xcController: VmXComponentController = new VmXComponentController();
  /* 顶部悬浮工具栏尺寸（见 BAR_* 常量注释：浮层升档后不分 Pad/PC） */
  private barBtnH: number = BAR_BTN_H;
  private barFs: number = BAR_FS;
  private immersiveMaximized: boolean = false;  /* 防递归：maximize() 自身也触发窗口状态回调 */
  private areaW: number = 0;
  private areaH: number = 0;
  /* 布局层 letterbox：guest 帧几何（vmSnapshot 轮询校准）+ 画面组件尺寸。
   * letterbox 必须由布局做而不是渲染做：resize 时布局同步变、渲染 buffer 跨进程
   * 滞后百毫秒级，合成器会把 buffer 非等比拉伸铺到组件上——渲染层独担 letterbox
   * 时「拉伸的旧帧（变形）」与「letterbox 新帧」交替上屏，就是 resize 期间画面
   * 在撑满/letterbox 间跳变的根源。组件矩形恒比 guest（同步层决策）后拉伸变等比，
   * 跳变无从发生。渲染层的 letterbox viewport 保留：guest 切显示模式到布局校准
   * 之间的瞬态兜底（宁可短暂黑边不可变形），也是输入反算的公共契约，不动。 */
  @State fbW: number = 0;
  @State fbH: number = 0;
  @State fitW: number = 0;
  @State fitH: number = 0;
  /* 画面容器尺寸。必须 @State：浮层 opacity/position 的更新依赖它——V1 的
   * 属性更新只在「该属性读取过的 @State」变化时重跑，普通字段改了不触发
   * 任何属性重算，浮层会永远停在首帧的「透明」状态（实测踩过） */
  @State containerW: number = 0;
  @State containerH: number = 0;
  private geoTimer: number = -1;
  /* buffer 几何的权威源：系统在自由窗口拖拽期间会向 surface 发「铺满窗口内容区」
   * 的 onSurfaceChanged（比例偏离组件），渲染层若照单全收，buffer 就被做成异形、
   * letterbox 画的黑边被合成器压进画面（实测变形的根源）。因此 buffer 尺寸由本页
   * 按组件实际尺寸下发，onSurfaceChanged 只更新缓存不透传。比例一致时合成器是
   * 等比缩放，尺寸不必紧追组件——偏差超阈值才下发一次补清晰度 */
  private sentW: number = 0;
  private sentH: number = 0;
  private density: number = 0;
  private surfaceReady: boolean = false;
  private startPending: boolean = false;
  private closed: boolean = false; /* VM 已死导致本窗口即将销毁，防重复 terminate */
  /* 物理键盘已注入未抬起的 QKeyCode：失焦/页面销毁时全量补 up。onKeyEvent 是
   * down/up 纯镜像，按住 Alt 时切窗/失焦，Up 不会送达，guest 会一直认为 Alt 按着 */
  private pressedKeys: Set<number> = new Set();
  /* 触摸手势状态机（单指=移动/左键/长按右键；双指=滚轮/抬起即右键点击） */
  private touchButtons: number = 0;
  private singleDown: boolean = false;
  private singleStartX: number = 0;
  private singleStartY: number = 0;
  private longPressTimer: number = -1;
  private longPressed: boolean = false;
  private twoFinger: boolean = false;
  private twoFingerStartX: number = 0; /* 双指落下时的质心：tap 判定的基准点 */
  private twoFingerStartY: number = 0;
  private twoFingerScrolled: boolean = false; /* 双指期间发过滚轮 → 抬起不再是 tap */
  private scrollCenterX: number = 0;
  private scrollCenterY: number = 0;
  private scrollAcc: number = 0;
  private lastX: number = 0;
  private lastY: number = 0;
  /* 触控板（相对）模式：客户端虚拟光标 + 位移跟踪 + 惯性滑行。
   * curX/curY 为 -1 表示未初始化（首次进相对模式时居中，见 ensureCursor） */
  private curX: number = -1;
  private curY: number = -1;
  private trackLastX: number = 0;
  private trackLastY: number = 0;
  private trackMoved: boolean = false; /* 本次单指手势移动超过阈值（决定抬起是点按还是滑行） */
  private trackVX: number = 0;         /* 最近一次移动的位移量（惯性滑行的初速度） */
  private trackVY: number = 0;
  private glideTimer: number = -1;
  private serialScroller: Scroller = new Scroller();
  /* 悬浮钮拖拽状态机（onTouch 驱动）：起点触摸坐标 + 起点钮位置 + 是否已判定拖动 */
  private barStartX: number = 0;
  private barStartY: number = 0;
  private barStartOffX: number = 0; /* 手势起点的偏移（拖动 = 起点偏移 + 位移） */
  private barStartOffY: number = 0;
  private barMoved: boolean = false;

  private toSurfacePx(vp: number, vpSize: number, surfaceSize: number): number {
    if (vpSize <= 0 || surfaceSize <= 0) {
      return Math.round(vp);
    }
    return Math.round(vp * surfaceSize / vpSize);
  }

  /* 容器内按 guest 比例取最大内接矩形。fb 未出帧（VM 没跑/刚启动）时 fit=0，
   * 组件铺满容器——画面全黑无比例可言，铺满还能让首帧立即可见 */
  private recomputeFit(): void {
    if (this.containerW <= 0 || this.containerH <= 0) {
      return;
    }
    if (this.fbW <= 0 || this.fbH <= 0) {
      this.fitW = 0;
      this.fitH = 0;
      return;
    }
    const scale = Math.min(this.containerW / this.fbW, this.containerH / this.fbH);
    this.fitW = Math.max(1, Math.floor(this.fbW * scale));
    this.fitH = Math.max(1, Math.floor(this.fbH * scale));
  }

  /* 按组件实际尺寸（vp×密度）下发 buffer 几何。比例变了必发（保住「buffer 比例=
   * 组件比例」这条合成器等比缩放的前提）；只是尺寸变大/变小时合成器本来就是等比
   * 缩放，偏差不超阈值就懒得追——也顺带把 EGLSurface 重建从「每次窗口变化」降为
   * 稀发。初始 sentW=0 保证首回路必发。 */
  private syncBufferGeometry(): void {
    const w = this.areaW;
    const h = this.areaH;
    if (w <= 0 || h <= 0 || this.density <= 0) {
      return;
    }
    if (this.sentW > 0 && this.sentH > 0) {
      const ratio = w / h;
      const sentRatio = this.sentW / this.sentH;
      const ratioSame = Math.abs(ratio - sentRatio) < sentRatio * 0.02;
      const sizeClose = Math.abs(w - this.sentW) < this.sentW * 0.25 &&
        Math.abs(h - this.sentH) < this.sentH * 0.25;
      if (ratioSame && sizeClose) {
        return;
      }
    }
    this.sentW = w;
    this.sentH = h;
    napi.resizeSurface(this.vmId, Math.round(w * this.density), Math.round(h * this.density));
  }

  /* guest 帧几何轮询：fb 尺寸只在 qemu 出首帧和 guest 切显示模式时变化（低频），
   * 轮询只为校准布局比例——未出帧时快问（启动出画面的瞬间尽快定比例），校准后
   * 放慢。vmSnapshot 一次 IPC 往返，量级可忽略 */
  private beginGeoWatch(): void {
    const tick = (): void => {
      if (this.closed) {
        return;
      }
      let w = 0;
      let h = 0;
      const snap = napi.vmSnapshot([this.vmId]) as Record<string, Object>;
      const st = snap[this.vmId];
      if (typeof st !== 'undefined') {
        const e = st as Record<string, Object>;
        w = e['w'] as number;
        h = e['h'] as number;
      }
      if (w > 0 && h > 0 && (w !== this.fbW || h !== this.fbH)) {
        this.fbW = w;
        this.fbH = h;
        this.recomputeFit();
      }
      this.geoTimer = setTimeout(tick, this.fbW > 0 ? 1000 : 250);
    };
    this.geoTimer = setTimeout(tick, 250);
  }

  private stopGeoWatch(): void {
    if (this.geoTimer >= 0) {
      clearTimeout(this.geoTimer);
      this.geoTimer = -1;
    }
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
    this.density = display.getDefaultDisplaySync().densityPixels;
    this.beginGeoWatch();
    this.loadKbd();
    this.loadGestureHint();
    this.loadConsolePrefs();
    this.enterVm();
    /* 最大化→沉浸仅对自由窗口设备（PC 2in1 等）有意义；Pad/手机窗口本来就
     * 全屏沉浸（Ability 侧 layoutFullScreen），由系统手势/任务栏管，不监听 */
    if (!isPadOrPhone()) {
      this.initImmersive();
    }
    this.initKeyGuard();
  }

  aboutToDisappear(): void {
    this.releaseAllKeys();
    this.stopGlide();
    /* 关窗留最后一帧缩略图（VM 仍在跑时；child 已死则内部空跑）。详情页靠
     * vmListVersion 感知刷新，故 bump */
    this.captureThumb(true);
    this.stopReadyWatch();
    this.stopThumbRetry();
    this.stopGeoWatch();
    napi.setQmpEventCallback(this.vmId, null);
    this.closeSerial();
  }

  private enterVm(): void {
    if (!this.profile) {
      this.status = '配置不存在或已删除';
      return;
    }
    if (napi.vmRunning(this.vmId)) {
      /* 已在后台运行（上次关窗只是摘窗）：重新挂窗，接管 QMP。
       * 仍走一遍就绪轮询——「子进程活着」不等于「qemu 起来了」（可能是上次卡死的
       * 残留），没就绪时它会在 T 后翻成「疑似卡死」。 */
      this.status = ''; /* 运行态不显示文字（画面即证明）；工具栏只承载瞬态/异常消息 */
      napi.qmpConnect(this.vmId, qmpSockPath(this.profile, this.vmDataDir));
      this.beginReadyWatch();
      return;
    }
    /* 熔断：上次启动失败且未修好配置 → 不自动重来。跑飞的 qemu 子进程会满速灌盘
     * 且不退（实测 38MB/s），而 console 一开窗就自动启动，用户会被反复拖进去，
     * 应用等于打不开。改为把原因摆出来，由用户显式点「仍要启动」再冒一次险。 */
    this.bootFailReason = new VmStore(this.filesDir).readBootFail(this.vmId);
    if (this.bootFailReason.length > 0) {
      this.status = '上次启动失败，未自动启动';
      return;
    }
    if (this.surfaceReady) {
      this.startVm();
    } else {
      this.startPending = true; /* 等 surface 起来再启动，避免黑屏竞态 */
    }
  }

  /* 「仍要启动」：清掉熔断标记后走正常启动流程（失败会再落一次标记）。
   * **先重读磁盘上的 profile**：窗口是独立 Ability，this.profile 是开窗那一刻的
   * 快照；用户修参数只能去编辑页（另一个窗口写盘），本窗口不会自己重载。不重读的话
   * 「改好了再重试」必然拿旧参数再失败一次（实测踩过）。 */
  private retryAnyway(): void {
    const fresh = new VmStore(this.filesDir).load(this.vmId);
    if (fresh) {
      this.profile = fresh;
    }
    new VmStore(this.filesDir).clearBootFail(this.vmId);
    this.bootFailReason = '';
    this.status = '';
    this.startVm();
  }

  private startVm(): void {
    if (!this.profile || napi.vmRunning(this.vmId)) {
      return;
    }
    if (this.xcController.surfaceId === 0n) {
      this.startPending = true;
      return;
    }
    const isos = this.profile.media.cdromPaths;
    const builtin = this.vmDataDir + '/' + builtinIsoFor(this.profile.machine.arch);
    /* 若引导光盘（第一张）是内置 Alpine ISO 且未下载：先按需下载，成功后继续启动 */
    if (isos.length > 0 && isos[0] === builtin && !pathExists(isos[0])) {
      this.status = '下载系统镜像…';
      const ctx = getContext(this) as common.UIAbilityContext;
      ensureBuiltinIso(ctx, this.vmDataDir, this.profile.machine.arch, (pct: number) => {
        this.status = `下载系统镜像 ${pct}%`;
      }).then((ok: boolean) => {
        if (!ok) {
          this.status = '系统镜像下载失败';
          return;
        }
        this.doStart();
      });
      return;
    }
    /* 光盘已配置但不可读（重启后选择器授权失效 / 文件被移动 / 可移动存储拔出）。
     * 启动源盘（第一张）且需从光盘启动 → 必须拦截给出路（丢盘必哑火）；非启动源盘
     * 不可读 → 启动时静默剔除（doStart 内过滤）。用 isoReadable（真 open 读）而非
     * pathExists（accessSync 可能对读不了的路径返回 true）。 */
    if (isos.length > 0 && this.profile.media.bootFromCdrom && !isoReadable(isos[0])) {
      this.status = '启动光盘无法读取';
      const nm = isos[0].substring(isos[0].lastIndexOf('/') + 1);
      AlertDialog.show({
        title: '启动光盘无法读取',
        message: `光盘 ${nm} 可能已被移动或删除。可以从系统盘启动，或到「虚拟机配置」里重新选择 ISO。`,
        buttons: [
          { value: '取消', action: () => {
          } },
          { value: '从系统盘启动', action: () => {
            if (!this.profile) { return; }
            this.profile.media.bootFromCdrom = false;
            new VmStore(this.filesDir).save(this.profile);
            this.status = '已改为从系统盘启动';
            this.doStart();
          } },
        ],
      });
      return;
    }
    this.doStart();
  }

  /* 读 qemu 日志末尾若干行：qemu 的报错（unknown CPU / 参数非法 / 内存不足等）经
   * vm.cpp 重定向 stdout/stderr 写到 <vmDataDir>/qemu-<vmId>.log（多实例各写各文件，
   * 对齐 qmp-<id>.sock/serial-<id>.log），是语义错误的唯一权威来源。启动失败时透出
   * 具体原因，替代笼统的「启动失败」——因为自定义 qemu 参数(extraArgs)永远无法静态
   * 校验，唯一的兜底就是让 qemu 自己把话说出来。旧版全局 qemu.log 作回退。
   * 只读尾部 64KB：日志在启动失败时会涨到 GB 级（实测 38MB/s），按整文件大小
   * 分配 ArrayBuffer 会直接 OOM。 */
  private qemuLogTail(): string {
    const candidates: string[] = [
      this.vmDataDir + '/qemu-' + this.vmId + '.log',
      this.vmDataDir + '/qemu.log',
    ];
    for (const log of candidates) {
      const text = readTail(log, 64 * 1024);
      const lines = text.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
      if (lines.length === 0) { continue; }
      return lines.slice(-60).join('\n');
    }
    return '';
  }

  /* 启动失败统一出口：状态栏留一句简短提示，完整 qemu.log 尾部用弹窗展示——
   * 报错（unknown CPU / 参数非法 / backtrace 等）可能远长于一行，弹窗可整段看，
   * 也避免状态栏被 maxLines(1) 截断。detail 为空（如进程级拉起失败，未写入 log）则只留状态栏。 */
  private failStart(shortMsg: string): void {
    this.status = shortMsg;
    const detail = this.qemuLogTail();
    if (detail.length === 0) {
      return;
    }
    AlertDialog.show({
      title: '虚拟机启动失败',
      message: detail,
      buttons: [{ value: '确定', action: () => {
      } }],
    });
  }

  private doStart(): void {
    const cur = this.profile;
    if (!cur) {
      return;
    }
    /* 启动基线从磁盘重读：编辑页/存储页/本页各持内存副本（@Prop 深拷贝），若拿旧
     * 副本启动，存储页刚改过的配置会被本页的旧值顶掉。load 失败才回退页面副本。 */
    const pBack: VmProfile = new VmStore(this.filesDir).load(this.vmId) ?? cur;
    /* 启动防线：磁盘文件缺失直接拦下（光盘已有 isoReadable 过滤；磁盘缺失 qemu
     * 不干净报错而是循环灌日志——实测秒级数 MB，直到宿主盘满）。 */
    for (const d of pBack.media.disks) {
      if (d.path.length === 0) {
        continue;
      }
      try {
        fs.accessSync(d.path);
      } catch {
        this.status = '磁盘文件缺失';
        promptAction.showToast({ message: `${d.path.split('/').pop()} 不存在，请在「存储管理」里重建或导入` });
        return;
      }
    }
    hilog.info(DOMAIN, TAG, 'doStart vmId=%{public}s arch=%{public}s isoCount=%{public}d bootFromCdrom=%{public}s tempSession=%{public}s',
      this.vmId, pBack.machine.arch, pBack.media.cdromPaths.length, String(pBack.media.bootFromCdrom),
      String(pBack.temporarySession));
    let share = '';
    if (pBack.net.sharedFolder) {
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
    /* 启动前的快照结算 + 临时会话打点：仅主盘（disks[0]）参与；qcow2 才支持
     *（raw 无内部快照）。失败则拒启，避免"用户以为会回滚却没回滚"。 */
    const disk = mainDiskPath(pBack);
    if (pBack.temporarySession &&
      (disk.length === 0 || !disk.toLowerCase().endsWith('.qcow2'))) {
      this.status = '临时会话需 qcow2 系统盘';
      return;
    }
    const tr = prepareStart(pBack.id, disk, pBack.temporarySession);
    if (tr !== 0) {
      this.status = '临时会话准备失败 (' + tr + ')';
      return;
    }
    /* 每次启动都是一个新的 NCP 子进程；多实例按 vmId 各起各的。
     * 不可读的辅助盘在下方按 isoReadable 过滤剔出本次启动列表（不动 this.profile），
     * 避免污染后续配置页/下次结算。 */
    /* 多 ISO：把不可读盘从本次启动列表剔除（不动 profile）+ toast 告知，其余原样传给 buildArgs。 */
    const allIsos = pBack.media.cdromPaths;
    const launchIsos = allIsos.filter((p: string): boolean => isoReadable(p));
    if (launchIsos.length !== allIsos.length) {
      const skipped = allIsos.filter((p: string): boolean => launchIsos.indexOf(p) < 0);
      hilog.warn(DOMAIN, TAG, 'doStart skip unreadable ISO vm=%{public}s %{public}d -> %{public}d',
        this.vmId, allIsos.length, launchIsos.length);
      const nm = skipped[0].substring(skipped[0].lastIndexOf('/') + 1);
      promptAction.showToast({
        message: skipped.length > 1 ?
          `${nm} 等${skipped.length}张光盘无法读取，本次启动已跳过` : `光盘 ${nm} 无法读取，本次启动已跳过`,
      });
    }
    /* riscv64 的变量存储 pflash 要每 VM 一份、且在 buildArgs 之前铺好：共用或沿用旧内容
     * 会让 edk2 因陈旧启动项不再自动引导光盘（详见 ensureRiscvVars 注释）。 */
    if (pBack.machine.arch === 'riscv64') {
      ensureRiscvVars(pBack, this.vmDataDir);
    }
    const launchArgs = buildArgs(pBack, this.vmDataDir, share, launchIsos);
    hilog.info(DOMAIN, TAG, 'doStart buildArgs vm=%{public}s argc=%{public}d isoCount=%{public}d',
      this.vmId, launchArgs.length, launchIsos.length);
    const ret = napi.startVm(this.vmId, pBack.machine.arch,
      launchArgs, this.xcController.surfaceId);
    hilog.info(DOMAIN, TAG, 'doStart startVm vm=%{public}s arch=%{public}s ret=%{public}d',
      this.vmId, pBack.machine.arch, ret);
    if (ret !== 0) {
      this.failStart('启动失败');
      return;
    }
    this.status = '启动中…';
    this.stuck = false;
    const qmpRet = napi.qmpConnect(this.vmId, qmpSockPath(pBack, this.vmDataDir));
    hilog.info(DOMAIN, TAG, 'doStart qmpConnect vm=%{public}s ret=%{public}d', this.vmId, qmpRet);
    this.beginReadyWatch();
  }

  /* 启动就绪判定：轮询 qmpReady（= QMP 成功往返过一次，qemu 主循环确认活着）。
   * 绝不能用「socket 连上了」「DCL 注册了」「出首帧了」当锚点 —— 实测跑飞时三者
   * 都已发生，而 qemu 根本不进主循环（-qmp 的 chardev 建在 device init 之前，
   * unix socket 一进内核 backlog，connect 就会成功）。旧代码的 2s「vmRunning 即
   * 运行中」是假成功：vmRunning 的真实语义只是「子进程收到了 START」。
   * 窗口 T=45s：edk2 + 大内存 + 多 ISO 首次启动会超过旧代码的 10s，而误判「卡死」
   * 的代价是让用户以为好 VM 坏了。 */
  private beginReadyWatch(): void {
    this.stopReadyWatch();
    this.stopThumbRetry(); /* 新一轮启动，上一轮没抓到首帧的试抓作废 */
    this.readySeen = false;
    this.qmpAlive = false; /* 重新等待就绪，就绪后翻转（电源按钮随之启用） */
    this.paused = false;   /* 新一轮启动，暂停态归零（STOP 事件会重新置位） */
    this.bootFailReason = ''; /* 新一轮启动，旧失败提示作废（再失败会重新落标记） */
    const started = Date.now();
    const WAIT_MS = 45000;
    this.readyTimer = setInterval(() => {
      if (napi.qmpReady(this.vmId)) {
        this.stopReadyWatch();
        this.readySeen = true;
        this.qmpAlive = true;
        this.status = ''; /* 运行态不显示文字（画面即证明）；工具栏只承载瞬态/异常消息 */
        /* 起来了就把熔断标记销掉（用户已修好配置） */
        new VmStore(this.filesDir).clearBootFail(this.vmId);
        this.bootFailReason = '';
        /* 拉一次光驱状态（介质菜单数据源）；起周期试抓——首帧「落定」不能等：
         * 黑帧不落盘（见 qemu_child kScreenshot），慢引导 guest 的首张有效画面
         * 可能晚就绪数十秒，3s 单次抓大概率扑空，之后详情页只能靠自己的慢轮询 */
        this.refreshCdSlots();
        this.beginThumbRetry();
        return;
      }
      if (!napi.vmRunning(this.vmId)) {
        this.stopReadyWatch();
        this.noteBootFail('启动过程中意外退出');
        this.failStart('启动失败：启动过程中意外退出');
        return;
      }
      if (Date.now() - started > WAIT_MS) {
        this.stopReadyWatch();
        this.stuck = true;
        this.qmpAlive = false; /* 已无响应：点关机/重启只会白等 5s 超时 */
        this.status = '疑似卡死（虚拟机无响应，可强制关机）';
        this.noteBootFail('启动超时（' + Math.round((Date.now() - started) / 1000) + ' 秒无响应）');
      }
    }, 500);
  }

  private stopReadyWatch(): void {
    if (this.readyTimer >= 0) {
      clearInterval(this.readyTimer);
      this.readyTimer = -1;
    }
  }

  /* 落熔断标记。用户主动停止（关机/强制断电）不算失败，不落。 */
  private noteBootFail(reason: string): void {
    if (this.userStopped) {
      return;
    }
    new VmStore(this.filesDir).markBootFail(this.vmId, reason);
    this.bootFailReason = reason;
  }

  /* console 内的破坏性电源操作与 VmManage 对齐：先确认再执行（重启=立即复位） */
  private confirmRestart(): void {
    const nm = this.profile ? this.profile.name : '虚拟机';
    AlertDialog.show({
      title: '重启',
      message: `将立即重启「${nm}」，未保存的数据可能丢失。确认？`,
      buttons: [
        { value: '取消', action: () => {} },
        { value: '重启', fontColor: cDanger, action: () => this.qmp('system_reset') },
      ],
    });
  }

  private confirmForceOff(): void {
    const nm = this.profile ? this.profile.name : '虚拟机';
    AlertDialog.show({
      title: '强制关机',
      message: `将立即切断「${nm}」的电源，未保存的数据可能丢失。确认？`,
      buttons: [
        { value: '取消', action: () => {} },
        { value: '强制关机', fontColor: cDanger, action: () => this.forcePowerOff() },
      ],
    });
  }

  /* 强制断电：先礼后兵 —— QMP quit 让 qemu 自己收尾；卡死时 quit 必然超时
   * （qmpCommand 同步阻塞 5s 后返回空），所以已判卡死就跳过它直接走 IPC 强杀。
   * 强杀走 kShutdown → 子进程 MainProc 置位后 _exit(0)，不依赖 qemu 合作。 */
  private forcePowerOff(): void {
    this.userStopped = true;
    this.stopReadyWatch();
    if (!napi.vmRunning(this.vmId)) {
      this.status = '已关机';
      return;
    }
    this.status = '正在强制关机…';
    if (this.stuck) {
      /* 已判卡死：quit 必然白等 5s，直接强杀，然后只轮询「死没死」 */
      hilog.warn(DOMAIN, TAG, '已判卡死，直接 IPC 强杀 vm=%{public}s', this.vmId);
      napi.forceStopVm(this.vmId);
      this.pollGone(0, true);
      return;
    }
    napi.qmpCommand(this.vmId, '{"execute":"quit"}');
    this.pollGone(0, false);
  }

  /* 轮询子进程退出（500ms × 6 = 3s）。第一阶段超时则升级为 IPC 强杀，再等一轮。
   * 必须等到真死才结束：旧 qemu 仍握 qcow2 写锁时重启会撞
   * "Failed to get write lock"（在 ncp_client_start 里被显示成笼统的「启动失败」）。 */
  private pollGone(tries: number, forced: boolean): void {
    if (!napi.vmRunning(this.vmId)) {
      this.status = '已关机';
      return;
    }
    if (tries >= 6) {
      if (forced) {
        this.status = '强制关机未生效';
        return;
      }
      hilog.warn(DOMAIN, TAG, 'quit 未生效，改走 IPC 强杀 vm=%{public}s', this.vmId);
      napi.forceStopVm(this.vmId);
      this.pollGone(0, true);
      return;
    }
    setTimeout(() => this.pollGone(tries + 1, forced), 500);
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
        this.status = '已暂停';
        break;
      case 'RESUME':
        this.paused = false;
        this.status = ''; /* 运行态不显示文字（画面即证明）；工具栏只承载瞬态/异常消息 */
        break;
      case 'RESET':
        /* 复位是瞬时事件，复位完就是普通的运行中；标「复位」既像"卡在复位"，
         * 又会一直挂到下一个状态事件才被覆盖 */
        this.paused = false;
        this.status = ''; /* 运行态不显示文字（画面即证明）；工具栏只承载瞬态/异常消息 */
        break;
      case 'SHUTDOWN':
      case 'QMP_DISCONNECT':
        /* qemu 大概率还活着（SHUTDOWN 先于进程退出）：留最后一帧缩略图
         *（已退净时 ncp 抓帧失败，空跑无碍） */
        this.captureThumb(true);
        this.paused = false;
        this.stopReadyWatch();
        this.stopThumbRetry();
        this.qmpAlive = false;
        this.vmListVersion++;
        this.closeSerial(); /* 串口随 VM 死亡断线，回画面视图 */
        /* 从没就绪过 → 这是一次「启动失败」，不是「运行中的 VM 死了」，不能按
         * 关机处理：窗口一关，用户只看到一闪而过、什么原因都不知道。留着窗口
         * 显示失败横幅 + 「仍要启动」，标记也在这里落（就绪轮询常常等不到这一轮
         * —— 子进程死掉时 socket 立刻断开，这个事件先到，随后 aboutToDisappear
         * 就把轮询停了。实测踩过：不在这里补，熔断标记永远写不出来）。 */
        if (!this.readySeen && !this.userStopped) {
          this.noteBootFail('启动过程中意外退出');
          this.status = '启动失败：启动过程中意外退出';
          break;
        }
        this.status = '已关机';
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
      hilog.warn(DOMAIN, TAG, 'qmp %{public}s failed: %{public}s', cmd, resp.substring(0, 200));
      const cn = QMP_CMD_CN[cmd] ?? '操作';
      promptAction.showToast({ message: cn + '失败，请重试' });
    }
  }

  /* ================= 详情页缩略图（运行期抓帧） ================= */

  /* 抓一帧写缩略图缓存（详情页「截图=启动按钮」用）。触发点刻意少而准：就绪后
   * 3 秒（首帧已画）、VM 死亡事件、本窗口关闭——每帧裸 RGBA 有几百 KB，不做
   * 周期抓取。child 已死/未出帧时 ncp 抓帧失败返回 null，静默跳过。
   * 文件格式 = 8 字节小端宽高头 + RGBA_8888 裸像素（读取侧见 VmManage.loadThumb）。
   * bump=true 时 vmListVersion++，让已打开的详情页/列表刷出新图。 */
  private captureThumb(bump: boolean): void {
    if (this.vmId.length === 0) {
      return;
    }
    try {
      /* native 侧直接写缩略图文件（kScreenshot 数据走文件不走 parcel，
       * 见 qemu_ipc.h）；本函数只管时机与刷新信号 */
      const shot = napi.captureScreen(this.vmId, thumbPath(this.vmId, this.vmDataDir));
      if (shot === null || shot.width <= 0 || shot.height <= 0) {
        /* 未出帧/黑帧（慢引导 guest 启动初期）为预期，静默等下一个时机 */
        return;
      }
      hilog.info(DOMAIN, TAG, 'captureThumb: %{public}dx%{public}d vm=%{public}s', shot.width, shot.height, this.vmId);
      if (bump) {
        this.vmListVersion++;
      }
      this.stopThumbRetry(); /* 首帧已到手，周期试抓使命完成 */
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'captureThumb: %{public}s', JSON.stringify(e));
    }
  }

  /* ================= 首帧周期试抓 ================= */

  private thumbRetryTimer: number = -1;

  /* 就绪后每 3s 试抓一次直到首张有效画面落盘（黑帧/未出帧不写盘，空转零成本）。
   * 让详情页在 guest 真正出画的 ≤3s 内就能拿到首图，而不是等它自己的慢轮询 */
  private beginThumbRetry(): void {
    this.stopThumbRetry();
    this.thumbRetryTimer = setInterval(() => this.captureThumb(true), 3000);
  }

  private stopThumbRetry(): void {
    if (this.thumbRetryTimer >= 0) {
      clearInterval(this.thumbRetryTimer);
      this.thumbRetryTimer = -1;
    }
  }

  /* ================= 介质（运行中换/弹 ISO） ================= */

  /* 从 QMP query-block 拉当前光驱与介质。认定规则：removable=true 且设备名是
   * 'cdN'（显式 id：附加盘、virt 第一张）或 'ide1-cd0'（pc/q35 第一张盘的 -cdrom
   * 自动后端 id，实测），floppy0 等其它 removable 设备排除。槽位顺序 cd0,cd1…；
   * 空盘 file=''。换/弹操作后需重新拉取（介质变了）。 */
  private refreshCdSlots(): void {
    if (!this.qmpAlive) {
      return;
    }
    const slots: CdSlot[] = [];
    const resp = napi.qmpCommand(this.vmId, '{"execute":"query-block"}');
    try {
      const obj = JSON.parse(resp) as Record<string, Object>;
      const ret = obj['return'];
      if (!Array.isArray(ret)) {
        return;
      }
      for (const item of ret as Object[]) {
        const e = item as Record<string, Object>;
        const dev = typeof e['device'] === 'string' ? e['device'] as string : '';
        const rm = e['removable'];
        if (!(typeof rm === 'boolean' && rm as boolean) || !this.isCdDevice(dev)) {
          continue;
        }
        let file = '';
        const ins = e['inserted'];
        if (typeof ins === 'object' && ins !== null) {
          const io = ins as Record<string, Object>;
          file = typeof io['file'] === 'string' ? io['file'] as string : '';
        }
        slots.push({ qmpId: dev, file: file });
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'query-block parse: %{public}s', JSON.stringify(err));
      return;
    }
    slots.sort((a: CdSlot, b: CdSlot) => this.cdOrder(a.qmpId) - this.cdOrder(b.qmpId));
    this.cdSlots = slots;
  }

  private isCdDevice(dev: string): boolean {
    return dev === 'ide1-cd0' || /^cd\d+$/.test(dev);
  }

  private cdOrder(dev: string): number {
    if (dev === 'ide1-cd0') {
      return 0;
    }
    const n = Number(dev.substring(2));
    return Number.isInteger(n) ? n : 99;
  }

  /* 换成新选的光盘：blockdev-change-medium（force 跳过 guest 的托盘锁）+
   * 配置同步 + 槽位刷新。blockdev-change-medium 对不可换介质的设备会报
   * "not removable"——virt 板已改用 usb-storage 挂第一张（见 buildArgs），
   * 若仍出现该报错说明设备组合不在预期内，toast 会带出原文。 */
  private changeCd(idx: number): void {
    const slot = idx < this.cdSlots.length ? this.cdSlots[idx] : null;
    if (slot === null || !this.qmpAlive) {
      return;
    }
    pickIsoPath(this.vmCtx()).then((p: string) => {
      if (p.length === 0) {
        return;
      }
      this.qmp('blockdev-change-medium', JSON.stringify({
        device: slot.qmpId, filename: p, format: 'raw', 'read-only-mode': 'read-only', force: true,
      }));
      this.persistCdSlots(idx, slot.file, p);
      this.refreshCdSlots();
      promptAction.showToast({ message: '已更换光盘' });
    });
  }

  /* 弹出光盘（eject，force 同义）。profile 同步为「移除该盘」：下次启动即不带这台
   * 光驱（与 UTM 的 Eject/Clear 语义一致）。 */
  private ejectCd(idx: number): void {
    const slot = idx < this.cdSlots.length ? this.cdSlots[idx] : null;
    if (slot === null || slot.file.length === 0 || !this.qmpAlive) {
      return;
    }
    this.qmp('eject', JSON.stringify({ device: slot.qmpId, force: true }));
    this.persistCdSlots(idx, slot.file, '');
    this.refreshCdSlots();
    promptAction.showToast({ message: '已弹出光盘' });
  }

  /* 换/弹盘后同步落档：按「槽位优先、旧路径兜底」定位 profile.cdromPaths 里的条目，
   * newFile='' 表示移除。槽位越界（启动时不可读盘被过滤，运行槽位比配置少）时
   * 追加，保证新盘不丢。与其它页面一致：重读磁盘、改、save、bump 版本号。 */
  private persistCdSlots(idx: number, oldFile: string, newFile: string): void {
    const fresh = new VmStore(this.filesDir).load(this.vmId);
    if (fresh === null) {
      return;
    }
    const list = fresh.media.cdromPaths.slice();
    let pos = idx;
    if (pos >= list.length || (oldFile.length > 0 && list[pos] !== oldFile)) {
      pos = oldFile.length > 0 ? list.indexOf(oldFile) : -1;
    }
    if (newFile.length === 0) {
      if (pos >= 0 && pos < list.length) {
        list.splice(pos, 1);
      }
    } else if (pos >= 0 && pos < list.length) {
      list[pos] = newFile;
    } else {
      list.push(newFile);
    }
    fresh.media.cdromPaths = list;
    new VmStore(this.filesDir).save(fresh);
    this.vmListVersion++;
  }

  private shortName(path: string): string {
    const nm = path.substring(path.lastIndexOf('/') + 1);
    return nm.length > 18 ? nm.substring(0, 17) + '…' : nm;
  }

  /* 是否有光驱（决定「介质」按钮显隐）：profile 有配盘即显示（槽位就绪前后都在），
   * 运行后即便 eject 光了槽位仍在（qemu 里光驱设备还挂着） */
  private hasCds(): boolean {
    return (this.profile !== null && this.profile.media.cdromPaths.length > 0) || this.cdSlots.length > 0;
  }

  /* 「介质」菜单：每槽一行「更换/装入」+ 有盘时一行「弹出」 */
  @Builder
  mediaMenu() {
    Menu() {
      if (this.cdSlots.length === 0) {
        MenuItem({ content: this.qmpAlive ? '无光盘设备' : '未就绪' }).enabled(false)
      }
      ForEach(this.cdSlots, (s: CdSlot, i: number) => {
        MenuItem({ content: s.file.length > 0 ? `更换光盘 ${i + 1}：${this.shortName(s.file)}` : `装入光盘 ${i + 1}` })
          .enabled(this.qmpAlive)
          .onClick(() => this.changeCd(i))
        if (s.file.length > 0) {
          MenuItem({ content: `弹出光盘 ${i + 1}` })
            .enabled(this.qmpAlive)
            .onClick(() => this.ejectCd(i))
        }
      }, (s: CdSlot, i: number) => `${i}:${s.file}`)
    }
  }

  /* ================= 触摸手势（单指移动/点击/长按右键，双指滚轮） ================= */

  /* 「电源」菜单：电源操作 + 暂停/继续收拢。重启/强制关机自带确认对话框，
   * 关机/暂停/CAD 直发（暂停无数据风险，两态互切即撤销）。
   * 原生 Menu/MenuItem（同 VmList.newVmMenu 的既有结论：自拼 Button 样式嘈杂） */
  @Builder
  powerMenu() {
    Menu() {
      MenuItem({ content: this.paused ? '继续' : '暂停' })
        .enabled(this.qmpAlive)
        .onClick(() => { this.qmp(this.paused ? 'cont' : 'stop'); })
      MenuItem({ content: '关机' })
        .enabled(this.qmpAlive)
        .onClick(() => {
          this.userStopped = true;
          this.qmp('system_powerdown');
        })
      MenuItem({ content: '重启' })
        .enabled(this.qmpAlive)
        .onClick(() => { this.confirmRestart() })
      MenuItem({ content: '强制关机' })
        .contentFontColor(cDanger)
        .onClick(() => { this.confirmForceOff() })
      MenuItem({ content: 'Ctrl+Alt+Del' })
        .enabled(this.qmpAlive)
        .onClick(() => { this.actReset() })
    }
  }

  private sendPtrMedia(vx: number, vy: number, buttons: number): void {
    /* 绝对注入：view 坐标按 viewport 比例映射到 guest 表面坐标（virtio-tablet 语义），
     * px 基准= vp×密度，与 syncBufferGeometry 下发的 buffer 尺寸同一换算 */
    const px = this.toSurfacePx(vx, this.areaW, this.areaW * this.density);
    const py = this.toSurfacePx(vy, this.areaH, this.areaH * this.density);
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

  /* ================= 触控板（相对）模式 ================= */

  /* 虚拟光标未初始化（-1）时居中到画面区：首次进相对模式时的落点 */
  private ensureCursor(): void {
    if (this.curX < 0 || this.curY < 0) {
      this.curX = this.areaW > 0 ? this.areaW / 2 : 100;
      this.curY = this.areaH > 0 ? this.areaH / 2 : 100;
    }
  }

  private moveCursorBy(dx: number, dy: number, buttons: number): void {
    this.ensureCursor();
    const maxX = this.areaW > 0 ? this.areaW : this.curX + dx;
    const maxY = this.areaH > 0 ? this.areaH : this.curY + dy;
    this.curX = Math.min(Math.max(this.curX + dx, 0), maxX);
    this.curY = Math.min(Math.max(this.curY + dy, 0), maxY);
    this.sendPtrMedia(this.curX, this.curY, buttons);
  }

  /* 惯性滑行：松手后按最后一段位移的初速度继续滑，16ms 一拍、逐拍衰减，
   * 低于停止阈值即停。任何新的按下/双指手势都会先 stopGlide 打断 */
  private startGlide(): void {
    if (Math.abs(this.trackVX) < GLIDE_MIN_START && Math.abs(this.trackVY) < GLIDE_MIN_START) {
      return;
    }
    this.stopGlide();
    const tick = (): void => {
      this.trackVX *= GLIDE_DECAY;
      this.trackVY *= GLIDE_DECAY;
      this.moveCursorBy(this.trackVX, this.trackVY, 0);
      if (Math.abs(this.trackVX) < GLIDE_STOP && Math.abs(this.trackVY) < GLIDE_STOP) {
        this.glideTimer = -1;
        return;
      }
      this.glideTimer = setTimeout(tick, 16);
    };
    this.glideTimer = setTimeout(tick, 16);
  }

  private stopGlide(): void {
    if (this.glideTimer >= 0) {
      clearTimeout(this.glideTimer);
      this.glideTimer = -1;
    }
  }

  /* 触控板模式长按 = 按住左键（Click & Hold）：随后滑动即拖动，抬起补释放。
   * 右键在相对模式由「双指轻点」承担（触屏模式长按仍是右键，见 fireLongPress） */
  private fireLongPressTouchpad(): void {
    this.longPressTimer = -1;
    this.longPressed = true;
    this.touchButtons = 0x01;
    this.sendPtrMedia(this.curX, this.curY, 0x01);
  }

  /* 触控板模式单指收尾（Up 与 touches=0 两条路径共用，调用方保证只结算一次）：
   * 长按 → 补左键抬起；没动过 → 点按左键；拖动过 → 惯性滑行 */
  private finishTouchpadGesture(): void {
    if (this.longPressed) {
      this.sendPtrMedia(this.curX, this.curY, 0);
      return;
    }
    if (!this.trackMoved) {
      /* down/up 连续入队即完整一次点击（qemu 输入队列保序，同双指 tap 的处理） */
      this.sendPtrMedia(this.curX, this.curY, 0x01);
      this.sendPtrMedia(this.curX, this.curY, 0);
      return;
    }
    this.startGlide();
  }

  /* 触控板模式单指处理：按下不按键也不跳光标；滑动移虚拟光标；长按阈值照旧 */
  private handleTouchpad(t: TouchObject): void {
    if (!this.singleDown) {
      this.singleDown = true;
      this.singleStartX = t.x;
      this.singleStartY = t.y;
      this.trackLastX = t.x;
      this.trackLastY = t.y;
      this.trackMoved = false;
      this.trackVX = 0;
      this.trackVY = 0;
      this.longPressed = false;
      this.touchButtons = 0;
      this.stopGlide();
      this.ensureCursor();
      this.cancelLongPress();
      this.longPressTimer = setTimeout(() => this.fireLongPressTouchpad(), 600);
      return;
    }
    const speed = SPEED_FACTORS[this.cursorSpeedIdx];
    const dx = (t.x - this.trackLastX) * speed;
    const dy = (t.y - this.trackLastY) * speed;
    this.trackLastX = t.x;
    this.trackLastY = t.y;
    this.trackVX = dx;
    this.trackVY = dy;
    if (!this.trackMoved) {
      const mx = t.x - this.singleStartX;
      const my = t.y - this.singleStartY;
      if (mx > 8 || mx < -8 || my > 8 || my < -8) {
        this.trackMoved = true;
        this.cancelLongPress();
      }
    }
    /* 长按已按住左键：滑动即拖动；否则纯移光标 */
    this.moveCursorBy(dx, dy, this.longPressed ? 0x01 : 0);
  }

  /* 双指手势收尾：期间没发过滚轮、且质心位移在 tap 阈值内 → 合成一次右键
   * 点击。down/up 连续入队即可：qemu 输入队列保序，guest 按自身 USB 轮询
   * 节奏看到完整的一次按下/释放，无需人为延时。返回是否判定为 tap */
  private endTwoFinger(): boolean {
    const dX = this.scrollCenterX - this.twoFingerStartX;
    const dY = this.scrollCenterY - this.twoFingerStartY;
    const wasTap = !this.twoFingerScrolled &&
      Math.abs(dX) < TWO_TAP_SLOP && Math.abs(dY) < TWO_TAP_SLOP;
    this.twoFinger = false;
    this.twoFingerScrolled = false;
    this.scrollAcc = 0;
    if (wasTap) {
      /* 触控板模式光标在虚拟位置：右键点在那里而不是双指质心 */
      const cx = this.inputMode === 1 ? this.curX : this.twoFingerStartX;
      const cy = this.inputMode === 1 ? this.curY : this.twoFingerStartY;
      this.sendPtrMedia(cx, cy, 0x02);
      this.sendPtrMedia(cx, cy, 0);
    }
    return wasTap;
  }

  private handleTouch(event: TouchEvent): void {
    const n = event.touches.length;
    /* 双指手势的收尾（n<2 且 twoFinger）：实机抬走一根手指上报的是
     * Move(touches=1) 而非 Up（官方文档的 Up 语义只在单指场景验证过，
     * 参照 wineohos DesktopLayer 的实测），最后一根才报 Up——两处都必须能
     * 结算 tap。Move 收尾时把剩指登记为已消费，防它被单指分支当成新点击
     * 注入左键；提前复位 twoFinger 的话最后一根 Up 走单指路径，右键永远
     * 合成不出来（实测踩过） */
    if (this.twoFinger && n < 2) {
      const t0 = event.touches.length > 0 ? event.touches[0] : null;
      const wasTap = this.endTwoFinger();
      if (event.type !== TouchType.Up && t0) {
        this.singleDown = true;
        this.touchButtons = 0;
        this.singleStartX = t0.x;
        this.singleStartY = t0.y;
        this.trackLastX = t0.x;
        this.trackLastY = t0.y;
        this.trackMoved = false;
      }
      return;
    }
    if (event.type === TouchType.Up) {
      this.cancelLongPress();
      this.singleDown = false;
      this.twoFinger = false;
      this.scrollAcc = 0;
      if (this.inputMode === 1) {
        this.finishTouchpadGesture();
        this.touchButtons = 0;
        this.longPressed = false;
        return;
      }
      const releaseBtns = this.touchButtons;
      this.touchButtons = 0;
      this.longPressed = false;
      if (releaseBtns !== 0) {
        this.sendPtrMedia(this.lastX, this.lastY, 0);
      }
      return;
    }
    if (n >= 2) {
      /* 双指：垂直滑动 → 滚轮（两指质心累积位移折算步数）；几乎没动就抬起
       * → 右键点击（在 n<2 的收尾块结算，见 endTwoFinger）。
       * touches 数组顺序不可依赖（官方约定），质心求平均不受影响 */
      const cX = (event.touches[0].x + event.touches[1].x) / 2;
      const cY = (event.touches[0].y + event.touches[1].y) / 2;
      if (!this.twoFinger) {
        this.stopGlide();
        this.twoFinger = true;
        this.twoFingerStartX = cX;
        this.twoFingerStartY = cY;
        this.twoFingerScrolled = false;
        this.scrollCenterX = cX;
        this.scrollCenterY = cY;
        this.scrollAcc = 0;
        this.cancelLongPress();
        this.singleDown = false;
        /* 单指阶段可能已把左键 down 注入 guest：按钮在 native 侧按位 diff，
         * 这里只清状态不发释放的话，整个双指手势 guest 都看到左键按住 */
        if (this.touchButtons !== 0) {
          this.touchButtons = 0;
          this.sendPtrMedia(this.lastX, this.lastY, 0);
        }
      } else {
        /* 自然滚动（对齐 wineohos 虚拟桌面的手感）：手指上滑 → 内容上移，
         * 即发 WHEEL_DOWN。步长 24vp：wineohos 同档的 12vp 实测 guest 侧
         * 滚动过快（一格滚 3 行文本，轻扫就飞过十来行），放慢一倍。
         * 「滚轮反向」偏好对两种手势模式与轴事件（触控板/物理滚轮）统一生效 */
        const delta = (this.scrollCenterY - cY) * (this.scrollReverse ? -1 : 1);
        this.scrollCenterX = cX;
        this.scrollCenterY = cY;
        this.scrollAcc += delta;
        const step = 24; /* vp → 1 格滚动 */
        while (this.scrollAcc >= step) {
          napi.scroll(this.vmId, 0, 1);
          this.scrollAcc -= step;
          this.twoFingerScrolled = true;
        }
        while (this.scrollAcc <= -step) {
          napi.scroll(this.vmId, 0, -1);
          this.scrollAcc += step;
          this.twoFingerScrolled = true;
        }
      }
      return;
    }

    if (n === 1) {
      const t = event.touches[0];
      if (this.inputMode === 1) {
        this.handleTouchpad(t);
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

    /* n === 0：全部抬起 → 释放按住的键。触控板模式下仅在 Up 未送达（wasDown
     * 仍为 true）时兜底结算，避免与 Up 路径重复合成点击 */
    const wasDown = this.singleDown;
    this.cancelLongPress();
    this.singleDown = false;
    this.twoFinger = false;
    this.scrollAcc = 0;
    if (this.inputMode === 1) {
      if (wasDown) {
        this.finishTouchpadGesture();
        this.touchButtons = 0;
        this.longPressed = false;
      }
      return;
    }
    const releaseBtns = this.longPressed ? 0 : this.touchButtons;
    this.touchButtons = 0;
    this.longPressed = false;
    if (releaseBtns !== 0) {
      this.sendPtrMedia(this.lastX, this.lastY, 0);
    }
  }

  /* console 通用 helpers（preferences 按 vmId 区分键；原 fab 前缀沿用为文件名） */
  private vmCtx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private vmPrefKey(suffix: string): string {
    return `${this.vmId}_${suffix}`;
  }

  /* 虚拟键盘显隐持久化（Preferences 按 vmId 区分，重开窗口记住开/关） */
  private loadKbd(): void {
    if (this.vmId.length === 0) {
      return;
    }
    preferences.getPreferences(this.vmCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      this.showKbd = prefs.getSync(this.vmPrefKey('kbd'), false) as boolean;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'loadKbd: %{public}s', JSON.stringify(e));
    });
  }

  /* 手势速查：触屏单指/双指、触控板双指的映射不直观（触控板手势被系统转成
   * mouse/axis，用户无从发现），首次进入展示一次；全局键不分 vmId */
  private loadGestureHint(): void {
    preferences.getPreferences(this.vmCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      if (!(prefs.getSync('gesture_hint', false) as boolean)) {
        this.showGestureHint = true;
      }
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'loadGestureHint: %{public}s', JSON.stringify(e));
    });
  }

  private dismissGestureHint(): void {
    this.showGestureHint = false;
    preferences.getPreferences(this.vmCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync('gesture_hint', true);
      prefs.flush();
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'saveGestureHint: %{public}s', JSON.stringify(e));
    });
  }

  private toggleKbd(): void {
    if (!this.showKbd && this.serialView) {
      this.closeSerial(); /* 互斥：键盘面板沉底部，会盖住串口输入行 */
    }
    this.showKbd = !this.showKbd;
    preferences.getPreferences(this.vmCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync(this.vmPrefKey('kbd'), this.showKbd);
      prefs.flush();
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'saveKbd: %{public}s', JSON.stringify(e));
    });
  }

  /* 输入设置与串口字号是「设备级」偏好（不分 vmId，换台 VM 手感一致）：一次读齐 */
  private loadConsolePrefs(): void {
    preferences.getPreferences(this.vmCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      this.inputMode = prefs.getSync('input_mode', 0) as number;
      this.scrollReverse = prefs.getSync('scroll_reverse', false) as boolean;
      this.cursorSpeedIdx = prefs.getSync('cursor_speed', 1) as number;
      this.serialFs = prefs.getSync('serial_fs', SERIAL_FS_LIST[0]) as number;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'loadConsolePrefs: %{public}s', JSON.stringify(e));
    });
  }

  private saveConsolePrefs(): void {
    preferences.getPreferences(this.vmCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync('input_mode', this.inputMode);
      prefs.putSync('scroll_reverse', this.scrollReverse);
      prefs.putSync('cursor_speed', this.cursorSpeedIdx);
      prefs.putSync('serial_fs', this.serialFs);
      prefs.flush();
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'saveConsolePrefs: %{public}s', JSON.stringify(e));
    });
  }

  /* 「输入」菜单：模式二选一（✓ 前缀标记）+ 滚轮反向 + 光标速度循环。
   * 触屏=绝对定位（点哪指哪）；触控板=相对移动（点按＝左键、长按＝按住左键拖动、
   * 双指轻点＝右键、双指滑动＝滚轮），落点由客户端虚拟光标维护（见 handleTouchpadMove）。 */
  @Builder
  inputMenu() {
    Menu() {
      MenuItem({ content: (this.inputMode === 0 ? '✓ ' : '') + '触屏模式' })
        .onClick(() => { this.inputMode = 0; this.saveConsolePrefs(); })
      MenuItem({ content: (this.inputMode === 1 ? '✓ ' : '') + '触控板模式' })
        .onClick(() => { this.inputMode = 1; this.stopGlide(); this.saveConsolePrefs(); })
      MenuItem({ content: (this.scrollReverse ? '✓ ' : '') + '滚轮反向' })
        .onClick(() => { this.scrollReverse = !this.scrollReverse; this.saveConsolePrefs(); })
      MenuItem({ content: '光标速度：' + SPEED_LABELS[this.cursorSpeedIdx] })
        .onClick(() => {
          this.cursorSpeedIdx = (this.cursorSpeedIdx + 1) % SPEED_FACTORS.length;
          this.saveConsolePrefs();
        })
    }
  }

  /* ================= 悬浮钮拖拽（onTouch；位置不持久化） ================= */

  /* 钮位置求值：屏幕顶部中点 + 偏移（钮恒为 36 见方，不依赖浮层测量） */
  private barPosX(): number {
    return Math.max(0, (this.containerW - (this.barBtnH + 8)) / 2) + this.barOffX;
  }

  private barPosY(): number {
    return sp2 + this.barOffY;
  }

  /* 偏移的边界钳制（钳偏移而非坐标——钮整体保持容器内） */
  private clampBarOffX(ox: number): number {
    const half = Math.max(0, (this.containerW - (this.barBtnH + 8)) / 2);
    return Math.min(Math.max(-half, ox), half);
  }

  private clampBarOffY(oy: number): number {
    const maxOy = Math.max(-sp2, this.containerH - (this.barBtnH + 8) - sp2);
    return Math.min(Math.max(-sp2, oy), maxOy);
  }

  /* 容器尺寸变化（PC 窗口缩放/最大化/串口面板开合）：钮以「顶部中点 + 偏移」
   * 自动重定位——未拖过 = 保持居中；拖过 = 相对屏幕中心的偏移保持；越界裁回 */
  private syncBarPos(): void {
    if (this.containerW <= 0) {
      return;
    }
    const nx = this.clampBarOffX(this.barOffX);
    const ny = this.clampBarOffY(this.barOffY);
    if (nx !== this.barOffX) {
      this.barOffX = nx;
    }
    if (ny !== this.barOffY) {
      this.barOffY = ny;
    }
  }

  /* 工具栏定位：水平以钮为中心（出界贴边）、垂直贴钮下方（底部放不下翻到
   * 上方）。钮与工具栏是两组独立定位——展开/收起/气泡出入都不会挪动钮 */
  private toolbarX(): number {
    const btn = this.barBtnH + 8;
    const x = this.barPosX() + btn / 2 - this.toolbarW / 2;
    return Math.min(Math.max(0, x), Math.max(0, this.containerW - this.toolbarW));
  }

  private toolbarY(): number {
    const below = this.barPosY() + (this.barBtnH + 8) + sp2;
    if (this.toolbarH > 0 && below + this.toolbarH > this.containerH) {
      return Math.max(0, this.barPosY() - sp2 - this.toolbarH);
    }
    return below;
  }

  /* 拖拽 + 点击判定：位移 > BAR_DRAG_THRESHOLD → 拖动（改偏移）；否则点击 → 展开/收起 */
  private onBarTouch(ev: TouchEvent): void {
    if (ev.type === TouchType.Down) {
      const t = ev.touches[0];
      if (t) {
        this.barStartX = t.windowX;
        this.barStartY = t.windowY;
      }
      this.barStartOffX = this.barOffX;
      this.barStartOffY = this.barOffY;
      this.barMoved = false;
    } else if (ev.type === TouchType.Move) {
      const t = ev.touches[0];
      if (t) {
        if (!this.barMoved &&
          (Math.abs(t.windowX - this.barStartX) > BAR_DRAG_THRESHOLD ||
            Math.abs(t.windowY - this.barStartY) > BAR_DRAG_THRESHOLD)) {
          this.barMoved = true;
        }
        if (this.barMoved) {
          this.barOffX = this.clampBarOffX(this.barStartOffX + (t.windowX - this.barStartX));
          this.barOffY = this.clampBarOffY(this.barStartOffY + (t.windowY - this.barStartY));
        }
      }
    } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
      if (!this.barMoved) {
        this.barOpen = !this.barOpen;
      }
      this.barMoved = false;
    }
  }

  private actReset(): void {
    this.qmp('send-key',
      '{"keys":[{"type":"qcode","data":"ctrl"},' +
      '{"type":"qcode","data":"alt"},' +
      '{"type":"qcode","data":"delete"}]}');
  }

  /* ================= 交互式串口（v4）：画面 ↔ 串口视图 ================= */

  /* 键帽 chip（清屏等动作）：圆角浅底方块 */
  @Builder
  serialKey(label: string, action: () => void) {
    Text(label)
      .fontSize(PANEL_FS)
      .height(PANEL_BTN_H)
      .padding({ left: sp3, right: sp3 })
      .fontColor(cConsoleText)
      .backgroundColor(cConsoleKey)
      .borderRadius(rConsole)
      .onClick(action)
  }

  /* 串口面板（底栏改浮层 v5）：日志区（更深底 + 等宽）+ 清屏/输入行。
   * 悬浮于画面底部之上，画面不再被挤压；面板 90% 半透明深底保日志可读的同时
   * 透出一点画面，盖住的是画面下缘而非布局空间。 */
  @Builder
  serialPanel() {
    Column({ space: sp2 }) {
      Scroll(this.serialScroller) {
        Text(this.serialText)
          .fontSize(this.serialFs)
          .fontFamily('monospace') /* 等宽（系统无此族名时回退默认，不影响功能） */
          .fontColor(cConsoleLogText)
          .width('100%')
          .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
          /* 长按选中复制（触摸场景 SELECTABLE_UNFOCUSABLE 即可；Ctrl+C
           * 才需 SELECTABLE_FOCUSABLE）。数据刷新会重置选择，属预期 */
          .copyOption(CopyOptions.LocalDevice)
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
      }
      .width('100%')
      .height(SERIAL_LOG_H)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
      .backgroundColor(cConsoleLogBg)
      .borderRadius(rConsole)
      .clip(true) /* 圆角裁剪滚动内容 */

      Row({ space: sp2 }) {
        this.serialKey('清屏', (): void => { this.serialText = '' })
        TextInput({ text: this.serialInput, placeholder: '输入后回车发送（打开 Ctrl 可发组合键）' })
          .layoutWeight(1)
          .fontSize(PANEL_FS)
          .fontFamily('monospace')
          .height(PANEL_H)
          .fontColor(cConsoleText)
          /* placeholder/光标必须显式给色：不设就跟随系统主题，深色主题下是深色，
           * 落在深色面板（+ 底下 VM 常是黑屏）上等于隐形（实测踩过） */
          .placeholderColor(cConsolePlaceholder)
          .placeholderFont({ size: PANEL_FS }) /* 不给就用默认字号，比同栏其他文字大一圈 */
          .caretColor(cConsoleAccent)
          .backgroundColor(cConsoleInputBg)
          .borderRadius(rConsole)
          .padding({ left: sp3, right: sp3 })
          .id(SERIAL_INPUT_ID)
          .onChange((v: string) => this.serialInput = v)
          .onSubmit(() => this.sendAndRefocus())
        Text('发送')
          .fontSize(PANEL_FS)
          .height(PANEL_BTN_H)
          .padding({ left: sp3, right: sp3 })
          .fontColor(Color.White)
          .backgroundColor(cConsolePrimary)
          .borderRadius(rConsole)
          .onClick(() => this.sendAndRefocus())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
    .backgroundColor(cConsolePanelSolid)
    .borderRadius({ topLeft: 12, topRight: 12 })
  }

  /* 打开串口视图：先回放本 VM 的落盘日志尾部（chardev logfile，跨启动累积；
   * 与实时流是同一条数据流，直接续上不插标记），再连 socket（qemu
   * -serial chardev:socket,server=on）并注册数据回调；VM 未启用交互串口
   * （serialInteractive=false / raspi）时提示。只读 64KB 尾部：日志无轮转
   * 上限，guest 刷屏时可达 MB 级（同 qemuLogTail 的教训） */
  private openSerial(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    if (!p.machine.serialInteractive) {
      promptAction.showToast({ message: '当前串口是日志模式，不能发送输入' });
      return;
    }
    this.serialView = true;
    this.showKbd = false; /* 互斥：串口面板与虚拟键盘都沉在画面底部，并存会互相压住 */
    this.serialText = readTail(serialLogPath(this.vmId, this.vmDataDir), 64 * 1024);
    this.serialInput = '';
    napi.serialOpen(this.vmId, serialSockPath(p, this.vmDataDir));
    napi.setSerialCallback(this.vmId, (text: string) => this.onSerialData(text));
    setTimeout(() => {
      this.serialScroller.scrollEdge(Edge.Bottom);
    }, 100);
  }

  private closeSerial(): void {
    if (!this.serialView) {
      return;
    }
    this.serialView = false;
    napi.setSerialCallback(this.vmId, null);
    napi.serialClose(this.vmId);
  }

  private toggleSerialView(): void {
    if (this.serialView) {
      this.closeSerial();
    } else {
      this.openSerial();
    }
  }

  /* 入站字节推送到只读文本区；断线合成标记单独显示。限长防内存涨（boot 刷屏会很大） */
  private onSerialData(text: string): void {
    if (text === '<SERIAL_DISCONNECT>') {
      this.serialText += '\n[串口连接已断开]\n';
      return;
    }
    this.serialText += text;
    if (this.serialText.length > 512 * 1024) {
      this.serialText = this.serialText.substring(this.serialText.length - 512 * 1024);
    }
    this.serialScroller.scrollEdge(Edge.Bottom);
  }

  /* 发送（回车 / 点「发送」）后把焦点交还输入框：onSubmit 会让输入框失焦，
   * 用户得再点一下才能继续输入，连续调试串口时很别扭。空回车与发送失败也回焦，
   * 否则同样要重新点一次。发送回车结尾（Linux ttyS0 icrnl 会转 \n） */
  private sendAndRefocus(): void {
    this.serialSendText();
    focusControl.requestFocus(SERIAL_INPUT_ID);
  }

  private serialSendText(): void {
    const t = this.serialInput;
    if (t.length === 0) {
      return;
    }
    const ret = napi.serialWrite(this.vmId, t + '\r');
    if (ret < 0) {
      promptAction.showToast({ message: '串口未连接' });
      return;
    }
    this.serialInput = '';
  }

  /* ================ 窗口最大化 → 沉浸全屏（参照 wineohos VirtualDesktopAbility） ================
   * 用户点系统最大化按钮 → 系统发 MAXIMIZE(2) → 本页以 ENTER_IMMERSIVE 方式
   * 最大化：铺满屏幕、隐藏系统标题栏/状态栏(Dock)。还原走系统自带通道——悬停
   * 屏幕边缘唤出标题栏/Dock 点还原，无需应用自建入口（不用
   * DISABLE_TITLE_AND_DOCK_HOVER，那会禁掉 hover 还原）。immersive = 沉浸稳态
   * （FULL_SCREEN），此时连页内底部状态栏也一起隐藏，画面铺满整窗；还原后
   * 状态栏回来。immersiveMaximized 防递归：maximize() 自身也会触发状态回调。 */
  private initImmersive(): void {
    window.getLastWindow(this.vmCtx()).then((win: window.Window) => {
      win.on('windowStatusChange', (statusType: number) => {
        if (statusType === window.WindowStatusType.MAXIMIZE) {
          if (!this.immersiveMaximized) {
            this.immersiveMaximized = true;
            win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE)
              .catch((e: Error) => {
                hilog.warn(DOMAIN, TAG, 'maximize immersive failed: %{public}s', JSON.stringify(e));
                this.immersiveMaximized = false;
              });
          }
          return;
        }
        if (statusType === window.WindowStatusType.FULL_SCREEN) {
          this.immersive = true; /* 沉浸稳态：隐藏系统栏（系统侧）+ 页内底部状态栏 */
          return;
        }
        /* 还原/最小化/分屏等：恢复底部状态栏 + 复位，下次再点最大化仍能拦截 */
        this.immersive = false;
        this.immersiveMaximized = false;
      });
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'getLastWindow: %{public}s', JSON.stringify(e));
    });
  }

  /* 释放所有已注入未抬起的物理键（失焦兜底）。幂等：无按键时直接返回 */
  private releaseAllKeys(): void {
    if (this.pressedKeys.size === 0 || this.vmId.length === 0) {
      return;
    }
    this.pressedKeys.forEach((q: number) => napi.sendKey(this.vmId, q, false));
    this.pressedKeys.clear();
  }

  /* 按键守卫：窗口失活（切到别的窗口/应用）时释放按下键。页内焦点转移
   * （如点到串口输入框）由根容器 onBlur 覆盖；页面销毁由 aboutToDisappear 覆盖 */
  private initKeyGuard(): void {
    window.getLastWindow(this.vmCtx()).then((win: window.Window) => {
      win.on('windowEvent', (t: number) => {
        if (t === window.WindowEventType.WINDOW_INACTIVE) {
          this.releaseAllKeys();
        }
      });
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'keyGuard getLastWindow: %{public}s', JSON.stringify(e));
    });
  }

  build() {
    /* 根 = 左上角对齐的 Stack：纵向内容（画面区 + 串口面板）+ 绝对定位的
     * 悬浮钮/工具栏浮层（不占布局，沉浸（最大化）时画面依旧铺满） */
    Stack({ alignContent: Alignment.TopStart }) {
      /* 纵向 = 画面区（串口面板已在画面 Stack 内作浮层，不再占布局挤压画面）；
       * 其后的悬浮钮/工具栏是 Stack 浮层，不占布局 */
      Column() {
        /* VM 画面区：XComponent + 虚拟键盘/熔断横幅/手势速查 overlay */
        Stack() {
          XComponent({ type: XComponentType.SURFACE, controller: this.xcController })
            .width(this.fitW > 0 ? this.fitW : '100%')
            .height(this.fitH > 0 ? this.fitH : '100%')
            .backgroundColor(Color.Black)
            .onAreaChange((oldArea: Area, newArea: Area) => {
              this.areaW = newArea.width as number;
              this.areaH = newArea.height as number;
              this.syncBufferGeometry();
            })
            .onTouch((event: TouchEvent) => this.handleTouch(event))
            /* 鼠标**未按下**的移动不产生 TouchEvent（touch 需要接触），只走 onMouse 的
             * MouseAction.Move；不挂它的话 guest 光标只有点击时才瞬移过去、移动完全不
             * 跟随。MouseEvent.x/y 与 TouchObject.x/y 同为「响应组件的组件坐标系」vp，
             * 故直接复用 sendPtrMedia。 */
            .onMouse((event: MouseEvent) => {
              if (event.action === MouseAction.Move) {
                /* 触摸状态机活跃时 touch 通道已在发移动，mouse 再发就是双发 */
                if (this.singleDown || this.twoFinger || this.touchButtons !== 0) {
                  return;
                }
                /* 悬停移动事件比触摸密集得多（每秒可达上百次），坐标没变就不发 */
                if (event.x !== this.lastX || event.y !== this.lastY) {
                  this.sendPtrMedia(event.x, event.y, 0);
                }
                return;
              }
              /* 触控板双指点击 / 物理鼠标的右键、中键：Press/Release 直通注入
               * （触控板双指点击被系统转成鼠标右键，不产生 TouchEvent）。
               * 左键不在这里处理——OHOS 对左键同时派发 mouse 与合成 touch，
               * onTouch 状态机已管左键，此处再发会双发（wineohos 同款结论） */
              if (event.action !== MouseAction.Press && event.action !== MouseAction.Release) {
                return;
              }
              const btnMask = event.button === MouseButton.Right ? 0x02 :
                event.button === MouseButton.Middle ? 0x04 : 0;
              if (btnMask !== 0) {
                this.sendPtrMedia(event.x, event.y,
                  event.action === MouseAction.Press ? btnMask : 0);
              }
            })
            /* 触控板双指滑动 / 物理滚轮：系统转成轴事件，不产生 TouchEvent。
             * 只有 vertical 可用——native 滚轮 ABI 无横向按钮。vert 为离散滚动
             * 增量，限幅防异常大值一次灌几十格 */
            .onAxisEvent((ev?: AxisEvent) => {
              if (!ev) {
                return;
              }
              const vert = ev.getVerticalAxisValue();
              if (vert === 0) {
                return;
              }
              const steps = Math.max(-3, Math.min(3, Math.round(vert)));
              napi.scroll(this.vmId, 0, this.scrollReverse ? -steps : steps);
            })
          /* 虚拟键盘 overlay：盖在 VM 画面上。面板空白处透传给画面，
           * 键帽/把手消费触摸（见 VirtualKeyboard 组件 hitTest 说明） */
          if (isPadOrPhone() && this.showKbd) {
            VirtualKeyboard({ vmId: this.vmId, showKbd: this.$showKbd })
          }
          /* 串口面板 overlay：悬浮于画面底部之上，画面保持满幅——原底栏形态推开
           * 画面（平板横屏吃掉约 1/3 高），而串口调试高频需要的是画面够大。
           * wrapper 只为沉底占位：空白区 Transparent 不拦兄弟命中，触摸照达画面 */
          if (this.serialView) {
            Column() {
              this.serialPanel()
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.End)
            .hitTestBehavior(HitTestMode.Transparent)
          }
          /* 熔断横幅：上次启动失败且本次没有自动启动 —— 把原因和「仍要启动」摆出来。
           * 不自动重试是因为跑飞的 qemu 会满速灌盘且不退（详见 enterVm 注释）。 */
          /* 判定只看 bootFailReason：它在熔断/失败时置位，就绪或「仍要启动」时清空。
           * 不在 build 里问 napi.vmRunning —— 那是同步 IPC 往返，每次重绘都打一次。 */
          if (this.bootFailReason.length > 0) {
            Column({ space: sp3 }) {
              Text('上次启动失败').fontSize(PANEL_FS).fontColor(cConsoleWarn)
              Text(this.bootFailReason).fontSize(PANEL_FS).fontColor(cConsoleText).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              /* ui-layout-ok: 父 Column 已 alignItems(Start)（见横幅 Column 链式尾部） */
              Row({ space: sp3 }) {
                Button('仍要启动').focusable(false).fontSize(PANEL_FS).height(PANEL_BTN_H)
                  .padding({ left: sp3, right: sp3 })
                  .fontColor(cConsoleText).backgroundColor(cConsoleBtn)
                  .onClick(() => { this.retryAnyway() })
                Button('看日志').focusable(false).fontSize(PANEL_FS).height(PANEL_BTN_H)
                  .padding({ left: sp3, right: sp3 })
                  .fontColor(cConsoleText).backgroundColor(Color.Transparent)
                  .onClick(() => { this.failStart('上次启动失败'); })
              }
            }
            .width('100%')
            .backgroundColor(cConsoleBanner)
            .padding(sp3)
            .alignItems(HorizontalAlign.Start)
          }
          /* 手势速查（首次进入）：盖在一切之上，点任意处关闭 */
          if (this.showGestureHint) {
            Column() {
              Column({ space: sp3 }) {
                Text('操作手势').fontSize(16).fontWeight(FontWeight.Medium).fontColor(cConsoleText)
                Text('触摸屏').fontSize(PANEL_FS).fontColor(cConsoleAccent)
                Text('单指点按＝左键，拖动＝移动光标；长按＝右键\n双指轻点＝右键；双指上下滑动＝滚轮')
                  .fontSize(PANEL_FS).fontColor(cConsoleText).textAlign(TextAlign.Center)
                Text('触控板').fontSize(PANEL_FS).fontColor(cConsoleAccent)
                Text('双指点击＝右键；双指滑动＝滚轮')
                  .fontSize(PANEL_FS).fontColor(cConsoleText).textAlign(TextAlign.Center)
                Text('「输入」里可切换为触控板模式：滑动移光标，点按＝左键，\n长按＝按住左键拖动；滚轮方向与光标速度也在那里调')
                  .fontSize(PANEL_FS).fontColor(cConsoleText).textAlign(TextAlign.Center)
                Button('知道了').focusable(false).fontSize(PANEL_FS).height(PANEL_BTN_H + 6)
                  .padding({ left: sp3 * 2, right: sp3 * 2 })
                  .fontColor(cConsoleText).backgroundColor(cConsoleBtn)
                  .onClick(() => this.dismissGestureHint())
              }
              .padding(sp3 * 3)
              .backgroundColor(cConsolePanelStrong)
              .borderRadius(12)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(cConsoleScrim)
            .onClick(() => this.dismissGestureHint())
          }
        }
        .width('100%')
        .layoutWeight(1)
        /* letterbox 黑边由容器出（布局属性，同步）：XComponent 缩到 guest 比例居中，
         * 边框区域露容器黑底。resize 时布局与黑边同步走，画面比例恒定不跳 */
        .backgroundColor(Color.Black)
        .onAreaChange((_o: Area, n: Area) => {
          this.containerW = n.width as number;
          this.containerH = n.height as number;
          this.recomputeFit();
          this.syncBarPos();
        })

      }
      .width('100%')
      .height('100%')

      /* 悬浮钮（可拖拽）+ 工具栏 = 两组独立绝对定位的浮层。钮行左缘 = 钮位
       *（钮恒在行内最左，展开/气泡都不会挪动钮）；钮位以**屏幕顶部中点为
       * 原点**的偏移表达——未拖过保持居中，拖过保持相对屏幕中心的偏移，
       * 窗口缩放/最大化都自动跟随。位置不持久化 */
      /* 窗口尺寸未测到前不渲染（条件由 @State containerW 驱动）——创建时
       * 就按最终位置亮相，不会先闪在 (0,0) 再跳居中 */
      if (this.containerW > 0) {
        Row({ space: sp2 }) {
          Stack() {
            SymbolGlyph(this.barOpen ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(20)
              .fontColor([cConsoleText])
          }
          .width(this.barBtnH + 8)
          .height(this.barBtnH + 8)
          .backgroundColor(cConsolePanel)
          .borderRadius((this.barBtnH + 8) / 2)
          .onTouch((ev: TouchEvent) => this.onBarTouch(ev))
          if (this.status.length > 0) {
            Text(this.status).fontSize(this.barFs).fontColor(cConsoleText)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: isPadOrPhone() ? 220 : 340 })
              .backgroundColor(cConsolePanel)
              .borderRadius(12)
              .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
          }
        }
        .alignItems(VerticalAlign.Center)
        .position({ x: this.barPosX(), y: this.barPosY() })
      }

      if (this.barOpen) {
        /* 按钮高 = 圆钮直径（barBtnH+8）：条高与收起态圆钮一致，展开不显小 */
        Row({ space: sp3 }) {
          Button('电源').focusable(false).fontSize(this.barFs).height(this.barBtnH + 8)
            .padding({ left: sp1, right: sp1 })
            .fontColor(cConsoleText).backgroundColor(Color.Transparent)
            .bindMenu(this.powerMenu)
          if (this.hasCds()) {
            Button('光盘').focusable(false).fontSize(this.barFs).height(this.barBtnH + 8)
              .padding({ left: sp1, right: sp1 })
              .fontColor(cConsoleText).backgroundColor(Color.Transparent)
              .bindMenu(this.mediaMenu)
          }
          Button('串口').focusable(false).fontSize(this.barFs).height(this.barBtnH + 8)
            .padding({ left: sp1, right: sp1 })
            .fontColor(this.serialView ? cConsoleAccent : cConsoleText).backgroundColor(Color.Transparent)
            .onClick(() => { this.toggleSerialView() })
          Button('输入').focusable(false).fontSize(this.barFs).height(this.barBtnH + 8)
            .padding({ left: sp1, right: sp1 })
            .fontColor(this.inputMode === 1 ? cConsoleAccent : cConsoleText).backgroundColor(Color.Transparent)
            .bindMenu(this.inputMenu)
          if (isPadOrPhone()) {
            Button(this.showKbd ? '隐藏键盘' : '虚拟键盘').focusable(false).fontSize(this.barFs).height(this.barBtnH + 8)
              .padding({ left: sp1, right: sp1 })
              .fontColor(this.showKbd ? cConsoleAccent : cConsoleText).backgroundColor(Color.Transparent)
              .onClick(() => { this.toggleKbd() })
          }
        }
        .backgroundColor(cConsolePanel)
        .borderRadius(12)
        .padding({ left: sp3, right: sp3 })
        .constraintSize({ maxWidth: '92%' })
        .position({ x: this.toolbarX(), y: this.toolbarY() })
        /* 宽度实测前透明一帧（首次展开），避免从「左缘贴钮心」跳到居中 */
        .opacity(this.toolbarW <= 0 ? 0 : 1)
        .onAreaChange((_o: Area, n: Area) => {
          this.toolbarW = n.width as number;
          this.toolbarH = n.height as number;
        })
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
        this.pressedKeys.add(qcode);
        napi.sendKey(this.vmId, qcode, true);
      } else if (event.type === KeyType.Up) {
        this.pressedKeys.delete(qcode);
        napi.sendKey(this.vmId, qcode, false);
      }
      event.stopPropagation();
    })
    .onBlur(() => {
      /* 焦点离开本页内容区（如点到串口输入框/失焦）：释放按下键，防卡键 */
      this.releaseAllKeys();
    })
  }
}
