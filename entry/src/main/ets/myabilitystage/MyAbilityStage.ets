// AbilityStage：为 specified 启动模式的 VmConsoleAbility 归并实例。
// 同一 vmId 复用已存在的窗口实例（onNewWant 置前），不同 vmId 各开各的窗口。
import { AbilityStage, Want } from '@kit.AbilityKit';

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
}
