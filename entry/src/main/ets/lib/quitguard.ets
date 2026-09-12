// 退出守卫：应用进程退出会连带杀掉 NCP 子进程里的 qemu（≈ 强制断电，guest 内
// 未落盘数据丢失、磁盘镜像有损坏风险）。两条退出路径分别拦截：
//  - 窗口三键区 X：WindowStage.on('windowStageClose')（@since 14，同步回调
//    return true = 拦下关窗；office 同款，已真机验证）。仅当被关窗口是最后一个
//    时才拦；否则窗口关了进程还在，VM 继续后台运行，无数据风险。拦下后弹确认框，
//    「强制退出」由守卫自己 terminateSelf——关窗时机握在我们手里，对话框没有
//    系统异步回调 ~10s 超时强杀的问题。
//  - Dock/托盘右键退出：MyAbilityStage.onPrepareTerminationAsync（应用级，有 VM
//    在跑就拦，不论几个窗口）。这条路是系统异步回调，超时强制关闭是系统行为。
// 运行态查询复用现成的 vmSnapshot（native ncp_client 才是权威源，含死进程自愈），
// 数据口径与 VM 列表页徽标一致（见 lib/vmregistry）。
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import napiModule from 'libentry.so';
import { VmStore } from './vmprofile';
import { livingWindowCount, anyWindow } from './vmwindows';

const DOMAIN = 0x0001;
const TAG = 'QemuEntry';

interface QuitGuardNapi {
  vmSnapshot: (vmIds: string[]) => Object;
}

const napi = napiModule as QuitGuardNapi;

/* 确认框在途标记：在途时再点 X 只挡不叠（office requestBackExit 同款防重入） */
let dialogInFlight = false;

/* 当前运行中的 VM 台数：取全部 profile 的 id 聚合查询（同 VmList 刷新口径） */
function runningVmCount(filesDir: string): number {
  const ids = new VmStore(filesDir).list().map((p) => p.id);
  if (ids.length === 0) {
    return 0;
  }
  const snap = napi.vmSnapshot(ids) as Record<string, Object>;
  let n = 0;
  for (const id of ids) {
    const st = snap[id];
    if (typeof st === 'undefined') {
      continue;
    }
    const e = st as Record<string, Object>;
    if (typeof e['running'] === 'boolean' && (e['running'] as boolean)) {
      n++;
    }
  }
  return n;
}

/* 窗口 X 路径的拦截判定：>0 = 需拦截（返回值即运行中台数，供弹窗文案用）。
 * 不拦：无 VM 在跑，或还有其他窗口（本窗关了进程不死）。 */
export function windowCloseGuardCount(filesDir: string): number {
  if (livingWindowCount() > 1) {
    return 0;
  }
  return runningVmCount(filesDir);
}

/* Dock/托盘退出路径的拦截判定：有 VM 在跑即拦（应用级退出，不论窗口数） */
export function appQuitGuardCount(filesDir: string): number {
  return runningVmCount(filesDir);
}

/* 确认弹窗。决议 true = 用户「取消」（留在应用）；false = 用户「强制退出」
 * 或弹窗失败（fail-open：守卫是 best-effort，不把用户困在应用里）。 */
export function showQuitDialog(win: window.Window | undefined, count: number): Promise<boolean> {
  if (win === undefined || dialogInFlight) {
    return Promise.resolve(win === undefined ? false : true);
  }
  dialogInFlight = true;
  hilog.info(DOMAIN, TAG, 'quit guard dialog, %{public}d vm(s) running', count);
  return new Promise<boolean>((resolve) => {
    try {
      win.getUIContext().getPromptAction().showDialog({
        title: '仍有虚拟机正在运行',
        message: `退出应用将强制停止 ${count} 台正在运行的虚拟机（相当于直接断电），虚拟机内未保存的数据可能丢失。`,
        buttons: [
          { text: '取消', color: '#FF0A59F7' },
          { text: '强制退出', color: '#FFE84026' },
        ],
      }).then((r) => {
        resolve(r.index !== 1);
      }).catch((e: Object) => {
        hilog.warn(DOMAIN, TAG, 'quit dialog failed: %{public}s', JSON.stringify(e));
        resolve(false);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'quit dialog throw: %{public}s', JSON.stringify(e));
      resolve(false);
    }
  }).then((stay: boolean) => {
    dialogInFlight = false;
    return stay;
  });
}

/* Dock/托盘退出时借来弹窗的存活窗口（主窗口优先，见 vmwindows.anyWindow） */
export function quitDialogHost(): window.Window | undefined {
  return anyWindow();
}
