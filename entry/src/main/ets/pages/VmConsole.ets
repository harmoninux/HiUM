// 虚拟机 Console 页：独立窗口（VmConsoleAbility）内的 XComponent 渲染 +
// 顶部工具条（电源/QMP 控制/截图/全屏）。vmId 经 LocalStorage 传入，页面按
// vmId 自载 profile。VM 跑在 NCP 子进程，关窗只是摘窗，重开窗口即重新挂窗。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction, window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';
import { VmProfile, VmStore, buildArgs, qmpSockPath, serialSockPath, sharedDir, builtinIsoFor, mainDiskPath } from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pathExists, isoReadable, readTail } from '../lib/fsutil';
import { prepareStart } from '../lib/tempSession';
import { takePendingVmId, isPadOrPhone } from '../lib/vmwindows';
import { VirtualKeyboard } from '../lib/VirtualKeyboard';
import { sp1, sp2 } from '../lib/uiTokens';

/* 多 ISO 启动前的可读性过滤在 doStart 内做：把不可读盘从本次启动的 ISO 列表里剔除，
 * 再经 buildArgs 的 isoOverride 传入（不动 profile 对象，避免污染后续配置/结算）。 */

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
  qmpReady: (vmId: string) => boolean;
  forceStopVm: (vmId: string) => number;
  setQmpEventCallback: (vmId: string, cb: ((evt: string) => void) | null) => void;
  serialOpen: (vmId: string, sockPath: string) => number;
  serialWrite: (vmId: string, text: string) => number;
  serialClose: (vmId: string) => void;
  setSerialCallback: (vmId: string, cb: ((text: string) => void) | null) => void;
}

const napi: QemuNapi = napiModule as QemuNapi;

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

/* 悬浮按钮（替代顶部工具条）：半透明圆钮，可拖拽移动，点击展开竖向操作面板。
 * 位置持久化到 preferences（键按 vmId 区分，跨窗口/重开记住落位）。
 * 尺寸/阈值参照 wineohos VirtualDesktop 的 EXIT_BTN_SIZE/EXIT_DRAG_THRESHOLD。 */
const STATUS_H = 32;          /* 底部状态栏高 (vp) */
const STATUS_BTN_H = 26;      /* 底部按钮高 (vp)，收窄让状态条更细 */
const STATUS_FS = 12;         /* 底部状态栏字号（running 字样基准，按钮同） */
const FAB_PREF = 'vmconsole_fab'; /* console 偏好文件名（现仅虚拟键盘显隐用） */
const MENU_TEXT = '#fff5f7fa'; /* 底部栏浅色文字 */
/* console 整个界面都是深色的（画面区纯黑、状态栏与串口面板 #20242b）。uiTokens 的
 * cPrimary(#0563ff) / cDanger(#d92d20) / cWeak(#6b7280) 是给浅色背景设计的深色值，
 * 搬到这里对比度只有 2.1~2.9:1 —— 实测「画面」「强制断电」这类文字看不清。
 * 下面是对应色系的浅色版本，在该背景上均 ≥4.5:1（WCAG AA）。 */
const DARK_ACCENT = '#ff94beff'; /* 主色：选中态/强调（亮蓝） 4.9:1 */
const DARK_DANGER = '#ffffa8a8'; /* 危险操作（亮红） 4.8:1 */
const DARK_WEAK = '#ffaab4c2';   /* 弱化文本（亮灰） 4.5:1 */
/* 串口输入框的组件 id：发送后要把焦点交还给它（见 sendAndRefocus） */
const SERIAL_INPUT_ID = 'hium-serial-input';

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
  @State showKbd: boolean = false;   /* 虚拟键盘显隐（底部状态栏开关，按 vmId 持久化） */
  @State immersive: boolean = false; /* 沉浸全屏态（最大化进入），沉浸时隐藏底部状态栏 */
  /* v4 交互式串口：serialView=串口视图盖在画面上；文本/输入/Ctrl 修饰态均在页内 */
  @State serialView: boolean = false;
  @State serialText: string = '';
  @State serialInput: string = '';
  @State ctrlOn: boolean = false; /* Ctrl 修饰（发送时对字母做 ^C 类映射） */
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
  private immersiveMaximized: boolean = false;  /* 防递归：maximize() 自身也触发窗口状态回调 */
  private areaW: number = 0;
  private areaH: number = 0;
  private surfaceReady: boolean = false;
  private startPending: boolean = false;
  private closed: boolean = false; /* VM 已死导致本窗口即将销毁，防重复 terminate */
  /* 物理键盘已注入未抬起的 QKeyCode：失焦/页面销毁时全量补 up。onKeyEvent 是
   * down/up 纯镜像，按住 Alt 时切窗/失焦，Up 不会送达，guest 会一直认为 Alt 按着 */
  private pressedKeys: Set<number> = new Set();
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
  private serialScroller: Scroller = new Scroller();

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
    /* 最大化→沉浸仅对自由窗口设备（PC 2in1 等）有意义；Pad/手机窗口本来就
     * 全屏沉浸（Ability 侧 layoutFullScreen），由系统手势/任务栏管，不监听 */
    if (!isPadOrPhone()) {
      this.initImmersive();
    }
    this.initKeyGuard();
  }

  aboutToDisappear(): void {
    this.releaseAllKeys();
    this.stopReadyWatch();
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
      this.status = '运行中';
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
    /* 光盘已配置但不可读（重启后选择器授权失效 / 文件被移动 / 可移动存储拔出）。
     * 启动源盘（第一张）且需从光盘启动 → 必须拦截给出路（丢盘必哑火）；非启动源盘
     * 不可读 → 启动时静默剔除（doStart 内过滤）。用 isoReadable（真 open 读）而非
     * pathExists（accessSync 可能对读不了的路径返回 true）。 */
    if (isos.length > 0 && this.profile.media.bootFromCdrom && !isoReadable(isos[0])) {
      this.status = '启动光盘不可读';
      const nm = isos[0].substring(isos[0].lastIndexOf('/') + 1);
      AlertDialog.show({
        title: '启动光盘不可读',
        message: `光盘 ${nm} 可能已移动或失去访问权限。可改用系统盘启动，或到 VM 配置页重新选择 ISO。`,
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
      title: 'QEMU 启动失败',
      message: detail,
      buttons: [{ value: '确定', action: () => {
      } }],
    });
  }

  private doStart(): void {
    if (!this.profile) {
      return;
    }
    const pBack = this.profile;
    hilog.info(DOMAIN, TAG, 'doStart vmId=%{public}s arch=%{public}s isoCount=%{public}d bootFromCdrom=%{public}s tempSession=%{public}s',
      this.vmId, pBack.machine.arch, pBack.media.cdromPaths.length, String(pBack.media.bootFromCdrom),
      String(pBack.temporarySession));
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
    /* 启动前的快照结算 + 临时会话打点：仅主盘（disks[0]）参与；qcow2 才支持
     *（raw 无内部快照）。失败则拒启，避免"用户以为会回滚却没回滚"。 */
    const disk = mainDiskPath(this.profile);
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
    /* 每次启动都是一个新的 NCP 子进程；多实例按 vmId 各起各的。
     * 不可读的辅助盘在下方按 isoReadable 过滤剔出本次启动列表（不动 this.profile），
     * 避免污染后续配置页/下次结算。 */
    /* 多 ISO：把不可读盘从本次启动列表剔除（不动 profile）+ toast 告知，其余原样传给 buildArgs。 */
    const allIsos = this.profile.media.cdromPaths;
    const launchIsos = allIsos.filter((p: string): boolean => isoReadable(p));
    if (launchIsos.length !== allIsos.length) {
      const skipped = allIsos.filter((p: string): boolean => launchIsos.indexOf(p) < 0);
      hilog.warn(DOMAIN, TAG, 'doStart skip unreadable ISO vm=%{public}s %{public}d -> %{public}d',
        this.vmId, allIsos.length, launchIsos.length);
      const nm = skipped[0].substring(skipped[0].lastIndexOf('/') + 1);
      promptAction.showToast({
        message: skipped.length > 1 ?
          `${nm} 等${skipped.length}张光盘不可读，本次启动已跳过` : `光盘 ${nm} 不可读，本次启动已跳过`,
      });
    }
    const launchArgs = buildArgs(this.profile, this.vmDataDir, share, launchIsos);
    hilog.info(DOMAIN, TAG, 'doStart buildArgs vm=%{public}s argc=%{public}d isoCount=%{public}d',
      this.vmId, launchArgs.length, launchIsos.length);
    const ret = napi.startVm(this.vmId, this.profile.machine.arch,
      launchArgs, this.xcController.surfaceId);
    hilog.info(DOMAIN, TAG, 'doStart startVm vm=%{public}s arch=%{public}s ret=%{public}d',
      this.vmId, this.profile.machine.arch, ret);
    if (ret !== 0) {
      this.failStart('启动失败');
      return;
    }
    this.status = '启动中...';
    this.stuck = false;
    const qmpRet = napi.qmpConnect(this.vmId, qmpSockPath(this.profile, this.vmDataDir));
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
    this.readySeen = false;
    this.bootFailReason = ''; /* 新一轮启动，旧失败提示作废（再失败会重新落标记） */
    const started = Date.now();
    const WAIT_MS = 45000;
    this.readyTimer = setInterval(() => {
      if (napi.qmpReady(this.vmId)) {
        this.stopReadyWatch();
        this.readySeen = true;
        this.status = '运行中';
        /* 起来了就把熔断标记销掉（用户已修好配置） */
        new VmStore(this.filesDir).clearBootFail(this.vmId);
        this.bootFailReason = '';
        return;
      }
      if (!napi.vmRunning(this.vmId)) {
        this.stopReadyWatch();
        this.noteBootFail('子进程在就绪前退出');
        this.failStart('启动失败：子进程退出');
        return;
      }
      if (Date.now() - started > WAIT_MS) {
        this.stopReadyWatch();
        this.stuck = true;
        this.status = '疑似卡死（qemu 无响应，可强制断电）';
        this.noteBootFail('启动后 ' + Math.round((Date.now() - started) / 1000) + 's 未就绪');
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
    this.status = '正在断电...';
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
        this.status = '强制断电未生效';
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
        this.status = '已暂停';
        break;
      case 'RESUME':
        this.status = '运行中';
        break;
      case 'RESET':
        /* 复位是瞬时事件，复位完就是普通的运行中；标「复位」既像"卡在复位"，
         * 又会一直挂到下一个状态事件才被覆盖 */
        this.status = '运行中';
        break;
      case 'SHUTDOWN':
      case 'QMP_DISCONNECT':
        this.stopReadyWatch();
        this.vmListVersion++;
        this.closeSerial(); /* 串口随 VM 死亡断线，回画面视图 */
        /* 从没就绪过 → 这是一次「启动失败」，不是「运行中的 VM 死了」，不能按
         * 关机处理：窗口一关，用户只看到一闪而过、什么原因都不知道。留着窗口
         * 显示失败横幅 + 「仍要启动」，标记也在这里落（就绪轮询常常等不到这一轮
         * —— 子进程死掉时 socket 立刻断开，这个事件先到，随后 aboutToDisappear
         * 就把轮询停了。实测踩过：不在这里补，熔断标记永远写不出来）。 */
        if (!this.readySeen && !this.userStopped) {
          this.noteBootFail('子进程在就绪前退出');
          this.status = '启动失败：子进程退出';
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
      promptAction.showToast({ message: cmd + ' 失败: ' + resp.substring(0, 120) });
    }
  }

  /* ================= 触摸手势（单指移动/点击/长按右键，双指滚轮） ================= */

  private sendPtrMedia(vx: number, vy: number, buttons: number): void {
    /* 绝对注入：view 坐标按 viewport 比例映射到 guest 表面坐标（virtio-tablet 语义） */
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

  private toggleKbd(): void {
    this.showKbd = !this.showKbd;
    preferences.getPreferences(this.vmCtx(), FAB_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync(this.vmPrefKey('kbd'), this.showKbd);
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

  /* ================= 交互式串口（v4）：画面 ↔ 串口视图 ================= */

  /* 打开串口视图：连接本 VM 的 socket（qemu -serial chardev:socket,server=on）
   * 并注册数据回调；VM 未启用交互串口（serialInteractive=false / raspi）时提示 */
  private openSerial(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    if (!p.machine.serialInteractive) {
      promptAction.showToast({ message: '该 VM 串口为日志模式（可在配置页开启交互）' });
      return;
    }
    this.serialView = true;
    this.serialText = '';
    this.serialInput = '';
    this.ctrlOn = false;
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

  /* Ctrl+字母 → 控制字节（^C=0x03）；其余字符原样。发送回车结尾（Linux ttyS0 icrnl 会转 \n） */
  private ctrlMap(ch: string): string {
    if (!this.ctrlOn) {
      return ch;
    }
    const c = ch.charCodeAt(0);
    if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) { /* A-Z a-z */
      return String.fromCharCode(c & 0x1f);
    }
    return ch;
  }

  /* 发送（回车 / 点「发送」）后把焦点交还输入框：onSubmit 会让输入框失焦，
   * 用户得再点一下才能继续输入，连续调试串口时很别扭。空回车与发送失败也回焦，
   * 否则同样要重新点一次。 */
  private sendAndRefocus(): void {
    this.serialSendText();
    focusControl.requestFocus(SERIAL_INPUT_ID);
  }

  private serialSendText(): void {
    const t = this.serialInput;
    if (t.length === 0) {
      return;
    }
    let wire = '';
    for (let i = 0; i < t.length; i++) {
      wire += this.ctrlMap(t.charAt(i));
    }
    wire += '\r';
    const ret = napi.serialWrite(this.vmId, wire);
    if (ret < 0) {
      promptAction.showToast({ message: '串口未连接' });
      return;
    }
    this.serialInput = '';
  }

  /* 发送单个原始字符（Esc=0x1b；Enter=0x0d；Ctrl 单发 0x03 在此收尾） */
  private serialSendByte(code: number): void {
    const ret = napi.serialWrite(this.vmId, String.fromCharCode(code));
    if (ret < 0) {
      promptAction.showToast({ message: '串口未连接' });
    }
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
    Column() {
      /* VM 画面区：XComponent + 虚拟键盘 overlay（键盘盖画面、不压底部状态栏） */
      Stack() {
        XComponent({ type: XComponentType.SURFACE, controller: this.xcController })
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
          .onAreaChange((oldArea: Area, newArea: Area) => {
            this.areaW = newArea.width as number;
            this.areaH = newArea.height as number;
          })
          .onTouch((event: TouchEvent) => this.handleTouch(event))
        /* 虚拟键盘 overlay：盖在 VM 画面上。面板空白处透传给画面，
         * 键帽/把手消费触摸（见 VirtualKeyboard 组件 hitTest 说明） */
        if (isPadOrPhone() && this.showKbd) {
          VirtualKeyboard({ vmId: this.vmId, showKbd: this.$showKbd })
        }
        /* 熔断横幅：上次启动失败且本次没有自动启动 —— 把原因和「仍要启动」摆出来。
         * 不自动重试是因为跑飞的 qemu 会满速灌盘且不退（详见 enterVm 注释）。 */
        /* 判定只看 bootFailReason：它在熔断/失败时置位，就绪或「仍要启动」时清空。
         * 不在 build 里问 napi.vmRunning —— 那是同步 IPC 往返，每次重绘都打一次。 */
        if (this.bootFailReason.length > 0) {
          Column({ space: sp2 }) {
            Text('上次启动失败').fontSize(STATUS_FS).fontColor('#fffecaca')
            Text(this.bootFailReason).fontSize(STATUS_FS).fontColor(MENU_TEXT).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: sp2 }) {
              Button('仍要启动').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
                .padding({ left: sp2, right: sp2 })
                .fontColor(MENU_TEXT).backgroundColor('#40ffffff')
                .onClick(() => { this.retryAnyway() })
              Button('看日志').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
                .padding({ left: sp2, right: sp2 })
                .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
                .onClick(() => { this.failStart('上次启动失败'); })
            }
          }
          .width('100%')
          .backgroundColor('#e6601b1b')
          .padding(sp2)
          .alignItems(HorizontalAlign.Start)
        }
        /* 交互式串口 overlay（v4）：盖住画面，只读滚动区 + 键帽/输入行。
         * 键帽发送原始字节：Ctrl=切换修饰、Esc=0x1b、Enter=0x0d */
        if (this.serialView) {
          Column() {
            Scroll(this.serialScroller) {
              Text(this.serialText)
                .fontSize(STATUS_FS)
                .fontColor('#fff1f2f4')
                .width('100%')
                .padding({ left: sp2, right: sp2, top: sp2, bottom: sp2 })
            }
            .layoutWeight(1)
            .align(Alignment.TopStart)
            .scrollBar(BarState.Auto)
            .width('100%')

            Row({ space: sp2 }) {
              Text('Ctrl').fontSize(STATUS_FS).height(STATUS_BTN_H)
                .padding({ left: sp1, right: sp1 })
                .fontColor(this.ctrlOn ? DARK_ACCENT : MENU_TEXT)
                .backgroundColor(Color.Transparent)
                .onClick(() => { this.ctrlOn = !this.ctrlOn })
              Text('Esc').fontSize(STATUS_FS).height(STATUS_BTN_H)
                .padding({ left: sp1, right: sp1 })
                .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
                .onClick(() => { this.serialSendByte(0x1b) })
              Text('Enter').fontSize(STATUS_FS).height(STATUS_BTN_H)
                .padding({ left: sp1, right: sp1 })
                .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
                .onClick(() => { this.serialSendByte(0x0d) })
              Text(this.ctrlOn ? 'Ctrl 开' : '发送键序').fontSize(STATUS_FS).fontColor(DARK_WEAK)
              Text('清屏').fontSize(STATUS_FS).height(STATUS_BTN_H)
                .padding({ left: sp1, right: sp1 })
                .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
                .onClick(() => { this.serialText = '' })
            }
            .width('100%')
            .height(STATUS_H)
            .backgroundColor('#e620242b')
            .padding({ left: sp2, right: sp2 })
            .alignItems(VerticalAlign.Center)

            Row({ space: sp2 }) {
              TextInput({ text: this.serialInput, placeholder: '输入并回车发送（Ctrl 开时 ^C 生效）' })
                .layoutWeight(1)
                .fontSize(STATUS_FS)
                .height(STATUS_H)
                .fontColor(MENU_TEXT)
                /* placeholder/光标必须显式给色：不设就跟随系统主题，深色主题下是深色，
                 * 落在深色面板（半透明 #20242b + 底下 VM 常是黑屏）上等于隐形（实测踩过）。
                 * 背景也要与所在行分开：原来同为 #e620242b，看不出输入框边界。 */
                .placeholderColor('#ff9aa4b2')
                .placeholderFont({ size: STATUS_FS }) /* 不给就用默认字号，比同栏其他文字大一圈 */
                .caretColor(DARK_ACCENT)
                .backgroundColor('#ff2b313b')
                .padding({ left: sp2, right: sp2 })
                .id(SERIAL_INPUT_ID)
                .onChange((v: string) => this.serialInput = v)
                .onSubmit(() => this.sendAndRefocus())
              Text('发送').fontSize(STATUS_FS).height(STATUS_BTN_H)
                .padding({ left: sp1, right: sp1 })
                .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
                .onClick(() => this.sendAndRefocus())
            }
            .width('100%')
            .height(STATUS_H)
            .backgroundColor('#e620242b')
            .padding({ left: sp2, right: sp2 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#e620242b')
        }
      }
      .width('100%')
      .layoutWeight(1)

      /* 底部状态栏：运行状态 + 电源/远程控制（常驻，所有设备；
       * 沉浸全屏时整体隐藏，画面铺满整窗） */
      if (!this.immersive) {
        Row({ space: sp2 }) {
          Text(this.status).fontSize(STATUS_FS).fontColor(MENU_TEXT)
            .layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('关机').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
            .onClick(() => {
              /* 用户主动停止：别让随后到来的 QMP_DISCONNECT 被当成启动失败写熔断标记 */
              this.userStopped = true;
              this.qmp('system_powerdown');
            })
          Button('重启').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
            .onClick(() => { this.qmp('system_reset') })
          Button('强制断电').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(DARK_DANGER).backgroundColor(Color.Transparent)
            .onClick(() => { this.forcePowerOff() })
          Button('Ctrl+Alt+Del').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
            .onClick(() => { this.actReset() })
          Button(this.serialView ? '画面' : '串口').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(this.serialView ? DARK_ACCENT : MENU_TEXT).backgroundColor(Color.Transparent)
            .onClick(() => { this.toggleSerialView() })
          if (isPadOrPhone()) {
            Button(this.showKbd ? '隐藏键盘' : '虚拟键盘').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
              .padding({ left: sp1, right: sp1 })
              .fontColor(this.showKbd ? DARK_ACCENT : MENU_TEXT).backgroundColor(Color.Transparent)
              .onClick(() => { this.toggleKbd() })
          }
        }
        .width('100%')
        .height(STATUS_H)
        .backgroundColor('#e620242b')
        .padding({ left: sp2, right: sp2 })
        .alignItems(VerticalAlign.Center)
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
