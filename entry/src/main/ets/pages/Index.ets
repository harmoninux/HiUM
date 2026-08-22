// 应用导航壳：列表页为根，edit 为 NavDestination。console 已迁出为每台 VM
// 独立的 VmConsoleAbility 窗口（见 VmList.openConsole）。
import { VmList } from './VmList';
import { VmEdit } from './VmEdit';
import { VmWizard, WizardParam } from './VmWizard';
import { VmManage } from './VmManage';
import { StorageOverview } from './StorageOverview';
import { VmProfile } from '../lib/vmprofile';

@Entry
@Component
struct Index {
  @Provide('navStack') navStack: NavPathStack = new NavPathStack();

  @Builder
  pageMap(name: string, param: Object) {
    NavDestination() {
      if (name === 'edit') {
        VmEdit({ profile: param as VmProfile })
      } else if (name === 'wizard') {
        VmWizard({ param: param as WizardParam })
      } else if (name === 'manage') {
        VmManage({ profile: param as VmProfile })
      } else if (name === 'storage') {
        StorageOverview()
      }
    }
    .hideTitleBar(true)
  }

  build() {
    Navigation(this.navStack) {
      VmList()
    }
    .navDestination(this.pageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
  }
}
