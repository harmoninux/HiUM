import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { picker, fileUri } from '@kit.CoreFileKit';
import { ensureAppBootstrap } from '../lib/bootstrap';
import { initTempSession } from '../lib/tempSession';

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
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
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
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
