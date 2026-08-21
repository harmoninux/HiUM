// VmConsoleAbility：每台 VM 一个实例、一个独立窗口（specified 启动模式，
// 按 vmId 归并）。同进程运行，native 的 vmId 路由注册表天然共享。
// 窗口默认沉浸式（内容全出血 + 隐藏系统栏，Pad 上面面铺满），页面工具条
// 可切回显示系统栏（参考 wineohos DesktopAbility/VirtualDesktopAbility）。
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ensureAppBootstrap } from '../lib/bootstrap';
import { setConsoleWindow, removeConsoleWindow, pushPendingVmId } from '../lib/vmwindows';

const DOMAIN = 0x0002;
const TAG = 'QemuUI';

export default class VmConsoleAbility extends UIAbility {
  private vmId: string = '';
  private vmName: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    /* 进程可能由本 Ability 冷启动（如任务列表恢复），公共初始化不能只在
     * EntryAbility 做 */
    ensureAppBootstrap(this.context);
    const params = want.parameters ?? {};
    this.vmId = (params['vmId'] as string) ?? '';
    this.vmName = (params['vmName'] as string) ?? '';
    hilog.info(DOMAIN, TAG, 'VmConsoleAbility onCreate vmId=%{public}s', this.vmId);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const vmId = this.vmId;
    const vmName = this.vmName;
    pushPendingVmId(vmId);
    windowStage.loadContent('pages/VmConsole', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      windowStage.getMainWindow().then((win: window.Window) => {
        setConsoleWindow(vmId, win);
        /* 沉浸式：内容铺满窗口并隐藏状态栏/导航条；2in1 自由窗口下标题栏
         * 仍在，顺带把标题设成 VM 名（平板全屏窗口无标题栏，失败忽略） */
        win.setWindowLayoutFullScreen(true)
          .catch((e: Object) => hilog.warn(DOMAIN, TAG, 'layoutFullScreen: %{public}s', JSON.stringify(e)));
        win.setSpecificSystemBarEnabled('status', false)
          .catch((e: Object) => hilog.warn(DOMAIN, TAG, 'hide status bar: %{public}s', JSON.stringify(e)));
        win.setSpecificSystemBarEnabled('navigationIndicator', false)
          .catch((e: Object) => hilog.warn(DOMAIN, TAG, 'hide navi bar: %{public}s', JSON.stringify(e)));
        win.setWindowTitle(vmName.length > 0 ? vmName : '虚拟机')
          .catch((e: Object) => hilog.warn(DOMAIN, TAG, 'setWindowTitle: %{public}s', JSON.stringify(e)));
      }).catch((e: Object) => hilog.error(DOMAIN, TAG, 'getMainWindow: %{public}s', JSON.stringify(e)));
    });
  }

  onWindowStageDestroy(): void {
    removeConsoleWindow(this.vmId);
    hilog.info(DOMAIN, TAG, 'VmConsoleAbility window destroyed vmId=%{public}s', this.vmId);
  }
}
