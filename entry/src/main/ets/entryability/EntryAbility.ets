import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { picker, fileUri } from '@kit.CoreFileKit';
import { ensureAppBootstrap } from '../lib/bootstrap';
import { initTempSession } from '../lib/tempSession';
import { setMainWindow, removeMainWindow, getMainWindow } from '../lib/vmwindows';
import { windowCloseGuardCount, showQuitDialog } from '../lib/quitguard';

const DOMAIN = 0x0001;
const TAG = 'QemuEntry';
/* 9p 唯一可共享目录：启动时经 picker 取 Download 目录写入 AppStorage；VmConsole 启动 VM 时读取 */
const SHARED_HOST_KEY = 'sharedHost';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ensureAppBootstrap(this.context);
    initTempSession(this.context.filesDir); /* 进程级：VM 停止时回滚临时会话 */
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    /* 三键区 X 关闭守卫（office 同款正路）：仍有 VM 在跑且这是最后一个窗口时
     * 拦下（return true）并弹确认框，「强制退出」由守卫 terminateSelf；其余放行。
     * 注册了本监听后系统不再走 onPrepareToTerminate。 */
    try {
      windowStage.on('windowStageClose', () => {
        const n = windowCloseGuardCount(this.context.filesDir);
        if (n <= 0) {
          return false;
        }
        showQuitDialog(getMainWindow(), n).then((stay: boolean) => {
          if (!stay) {
            this.context.terminateSelf();
          }
        });
        return true;
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'windowStageClose register err: %{public}s', JSON.stringify(e));
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
    windowStage.getMainWindow().then((win: window.Window) => {
      setMainWindow(win); /* 退出守卫数窗口用，见 lib/quitguard */
    }).catch((e: Object) => hilog.warn(DOMAIN, TAG, 'getMainWindow: %{public}s', JSON.stringify(e)));
    /* 启动即取 Download 作为唯一可共享目录（fire-and-forget，不阻塞界面） */
    this.prepareSharedFolder();
  }

  /* 启动时获取 Download 文件夹（唯一可共享文件夹）；失败不阻塞，VmConsole 读取不到时回退 app 数据 dir/shared */
  private async prepareSharedFolder(): Promise<void> {
    try {
      const pickerObj = new picker.DocumentViewPicker();
      const res = await pickerObj.save({ pickerMode: picker.DocumentPickerMode.DOWNLOAD });
      if (res && res.length > 0) {
        const host = new fileUri.FileUri(res[0]).path + '/';
        AppStorage.setOrCreate(SHARED_HOST_KEY, host);
      }
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'prepareSharedFolder failed: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    removeMainWindow();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
