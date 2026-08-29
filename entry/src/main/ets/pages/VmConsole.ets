// 虚拟机 Console 页：独立窗口（VmConsoleAbility）内的 XComponent 渲染 +
// 顶部工具条（电源/QMP 控制/截图/全屏）。vmId 经 LocalStorage 传入，页面按
// vmId 自载 profile。VM 跑在 NCP 子进程，关窗只是摘窗，重开窗口即重新挂窗。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction, window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import napiModule from 'libentry.so';
import { HOS_TO_QKEYCODE } from '../lib/keymap';
import { VmProfile, VmStore, buildArgs, qmpSockPath, sharedDir, builtinIsoFor, seedWinVars, swtpmPidPath, swtpmSockPath, swtpmDir } from '../lib/vmprofile';
import { ensureBuiltinIso } from '../lib/isoDl';
import { pathExists, isoReadable } from '../lib/fsutil';
import { prepareStart } from '../lib/tempSession';
import { takePendingVmId, isPadOrPhone } from '../lib/vmwindows';
import { VirtualKeyboard } from '../lib/VirtualKeyboard';
import {
  cDanger, cPrimary, sp1, sp2,
} from '../lib/uiTokens';

interface ScreenShotBuf {
  width: number;
  height: number;
  pixels: ArrayBuffer;
}

/* 从 buildArgs 产出的命令行里剥掉 -cdrom 及其值（光盘不可读时启动前丢盘用）。
 * 不动 profile 对象自身的 cdromPath，避免污染后续配置/结算。 */
function stripCdrom(args: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '-cdrom') {
      i++; /* 跳过紧随其后的路径值 */
      continue;
    }
    out.push(args[i]);
  }
  return out;
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
  startSwtpm: (binPath: string, libDir: string, tpmDir: string, ctrlSock: string, logPath: string, pidPath: string) => number;
  stopSwtpm: (pidPath: string) => void;
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
  private vmId: string = '';
  private profile: VmProfile | null = null;
  private xcController: VmXComponentController = new VmXComponentController();
  private immersiveMaximized: boolean = false;  /* 防递归：maximize() 自身也触发窗口状态回调 */
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
    this.loadKbd();
    this.enterVm();
    /* 最大化→沉浸仅对自由窗口设备（PC 2in1 等）有意义；Pad/手机窗口本来就
     * 全屏沉浸（Ability 侧 layoutFullScreen），由系统手势/任务栏管，不监听 */
    if (!isPadOrPhone()) {
      this.initImmersive();
    }
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
      this.status = '运行中';
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
    /* 光盘已配置但不可读（重启后选择器授权失效 / 文件被移动 / 可移动存储拔出）：
     * 分两种——辅助光盘直接丢 -cdrom 从硬盘继续；启动源光盘必须拦截给出路（丢盘必哑火）。
     * 用 isoReadable（真 open 读）而非 pathExists（accessSync 可能对读不了的路径返回 true）。 */
    if (cd.length > 0 && !isoReadable(cd)) {
      if (this.profile.media.bootFromCdrom) {
        this.status = '启动光盘不可读';
        const nm = cd.substring(cd.lastIndexOf('/') + 1);
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
              this.doStart(true);
            } },
          ],
        });
        return;
      }
      this.status = '光盘不可读，已跳过';
      promptAction.showToast({ message: '光盘不可读，已跳过；可到配置页重新选择 ISO' });
      this.doStart(true);
      return;
    }
    this.doStart();
  }

  /* 读 qemu 日志末尾若干行：qemu 的报错（unknown CPU / 参数非法 / 内存不足等）经
   * vm.cpp 重定向 stdout/stderr 写到 <vmDataDir>/qemu-<vmId>.log（多实例各写各文件，
   * 对齐 qmp-<id>.sock/serial-<id>.log），是语义错误的唯一权威来源。启动失败时透出
   * 具体原因，替代笼统的「启动失败」——因为自定义 qemu 参数(extraArgs)永远无法静态
   * 校验，唯一的兜底就是让 qemu 自己把话说出来。旧版全局 qemu.log 作回退。 */
  private qemuLogTail(): string {
    const candidates: string[] = [
      this.vmDataDir + '/qemu-' + this.vmId + '.log',
      this.vmDataDir + '/qemu.log',
    ];
    for (const log of candidates) {
      try {
        if (!pathExists(log)) { continue; }
        const st = fs.statSync(log);
        if (st.size <= 0) { continue; }
        const fd = fs.openSync(log, fs.OpenMode.READ_ONLY);
        const buf = new ArrayBuffer(st.size);
        const n = fs.readSync(fd.fd, buf);
        fs.closeSync(fd);
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n));
        const lines = text.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
        if (lines.length === 0) { continue; }
        return lines.slice(-60).join('\n');
      } catch {
        continue;
      }
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

  /* Windows 11 首次启动提示（按架构给不同说明）。用户可能会卡在「不看提示装不上」。 */
  private showWinInstallHint(blocking: boolean): void {
    if (!this.profile) { return; }
    const isArm = this.profile.machine.arch === 'aarch64';
    const isoMsg = isArm
      ? '1. 挂载官方 Win11ARM64 ISO + virtio-win 驱动 ISO（装盘时选「加载驱动程序」选 virtio-scsi）。'
      : '1. 挂载官方 Win11 x64 ISO（x64 全用内置驱动，无需 virtio-win）。';
    const bypassMsg = '2. 到安装界面按 Shift+F10 → regedit → HKEY_LOCAL_MACHINE\\SYSTEM\\Setup → 新建 LabConfig → BypassTPMCheck=1 / BypassSecureBootCheck=1，返回后下一步。';
    AlertDialog.show({
      title: 'Windows 11 安装提示',
      message: isoMsg + '\n' + bypassMsg,
      buttons: [{ value: '知道了', action: () => {
        if (blocking) {
          this.status = '';
        }
      } }],
    });
  }

  private doStart(skipCdrom: boolean = false): void {
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
    /* 每次启动都是一个新的 NCP 子进程；多实例按 vmId 各起各的。
     * skipCdrom（光盘不可读的辅助盘）：启动前从 buildArgs 剥掉 -cdrom（-boot 仍按 bootFromCdrom），
     * 不动 this.profile 对象，避免污染后续配置页/下次结算。 */
    const isWin = this.profile.guestOS === 'windows11';
    if (isWin && !seedWinVars(this.vmDataDir, this.profile.id, this.profile.machine.arch)) {
      this.status = 'UEFI 变量文件缺失';
      this.showWinInstallHint(true);
      return;
    }
    if (isWin && this.profile.security && this.profile.security.tpm) {
      const binPath = this.vmDataDir + '/swtpm/bin/swtpm';
      const libDir = this.vmDataDir + '/swtpm/lib';
      const tpmDir = swtpmDir(this.vmDataDir, this.profile.id);
      const sock = swtpmSockPath(this.vmDataDir, this.profile.id);
      const log = this.vmDataDir + '/swtpm-' + this.profile.id + '.log';
      const pid = swtpmPidPath(this.vmDataDir, this.profile.id);
      const rc = napi.startSwtpm(binPath, libDir, tpmDir, sock, log, pid);
      if (rc !== 0) {
        this.status = 'TPM 启动失败';
        this.profile.security.tpm = false; /* 降级：buildWinArgs 不再挂 tpm-tis */
        promptAction.showToast({ message: 'TPM 启动失败，已改为注册表绕过安装' });
      }
    }
    const args = buildArgs(this.profile, this.vmDataDir, share);
    const launchArgs = skipCdrom ? stripCdrom(args) : args;
    const ret = napi.startVm(this.vmId, this.profile.machine.arch,
      launchArgs, this.xcController.surfaceId);
    if (ret !== 0) {
      if (isWin && this.profile.security && this.profile.security.tpm) {
        napi.stopSwtpm(swtpmPidPath(this.vmDataDir, this.profile.id));
      }
      this.failStart('启动失败');
      return;
    }
    this.status = '启动中...';
    napi.qmpConnect(this.vmId, qmpSockPath(this.profile, this.vmDataDir));
    /* 首次启动 qemu 不发 RESUME 事件，按实际运行状态翻牌；长时间没起来
     * 说明子进程早夭（如参数/资源问题），给个可见的失败 */
    setTimeout(() => {
      if (this.status === '启动中...' && napi.vmRunning(this.vmId)) {
        this.status = '运行中';
      }
    }, 2000);
    setTimeout(() => {
      if (this.status === '启动中...' && !napi.vmRunning(this.vmId)) {
        this.failStart('启动失败：子进程退出');
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
        this.status = '运行中';
        break;
      case 'RESET':
        this.status = '运行中 (复位)';
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
    if (this.profile && this.profile.guestOS === 'windows11') {
      napi.stopSwtpm(swtpmPidPath(this.vmDataDir, this.profile.id));
    }
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
            .onClick(() => { this.qmp('system_powerdown') })
          Button('重启').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
            .onClick(() => { this.qmp('system_reset') })
          Button('强制断电').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
            .onClick(() => { this.qmp('quit') })
          Button('Ctrl+Alt+Del').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
            .padding({ left: sp1, right: sp1 })
            .fontColor(MENU_TEXT).backgroundColor(Color.Transparent)
            .onClick(() => { this.actReset() })
          if (isPadOrPhone()) {
            Button(this.showKbd ? '隐藏键盘' : '虚拟键盘').focusable(false).fontSize(STATUS_FS).height(STATUS_BTN_H)
              .padding({ left: sp1, right: sp1 })
              .fontColor(this.showKbd ? cPrimary : MENU_TEXT).backgroundColor(Color.Transparent)
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
        napi.sendKey(this.vmId, qcode, true);
      } else if (event.type === KeyType.Up) {
        napi.sendKey(this.vmId, qcode, false);
      }
      event.stopPropagation();
    })
  }
}
