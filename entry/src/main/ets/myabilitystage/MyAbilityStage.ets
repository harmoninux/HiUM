// AbilityStage：为 specified 启动模式的 VmConsoleAbility 归并实例。
// 同一 vmId 复用已存在的窗口实例（onNewWant 置前），不同 vmId 各开各的窗口。
import { AbilityConstant, AbilityStage, Want } from '@kit.AbilityKit';
import { appQuitGuardCount, showQuitDialog, quitDialogHost } from '../lib/quitguard';

export default class MyAbilityStage extends AbilityStage {
  onAcceptWant(want: Want): string {
    if (want.abilityName === 'VmConsoleAbility' && want.parameters) {
      const vmId = want.parameters['vmId'];
      if (typeof vmId === 'string' && vmId.length > 0) {
        return 'vmconsole_' + vmId;
      }
    }
    return 'MyAbilityStage';
  }

  /* Dock/托盘右键退出（应用级）：有 VM 在跑就弹确认，见 lib/quitguard。
   * 窗口三键 X 不走这里（由各 WindowStage 的 windowStageClose 拦截）。 */
  onPrepareTerminationAsync(): Promise<AbilityConstant.PrepareTermination> {
    const n = appQuitGuardCount(this.context.filesDir);
    if (n <= 0) {
      return Promise.resolve(AbilityConstant.PrepareTermination.TERMINATE_IMMEDIATELY);
    }
    return showQuitDialog(quitDialogHost(), n).then((stay: boolean) =>
      stay ? AbilityConstant.PrepareTermination.CANCEL : AbilityConstant.PrepareTermination.TERMINATE_IMMEDIATELY);
  }
}
