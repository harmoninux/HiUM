// 应用导航壳：列表页为根，edit/console 为 NavDestination。
import { VmList } from './VmList';
import { VmEdit } from './VmEdit';
import { Console } from './Console';
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
      } else if (name === 'console') {
        Console({ profile: param as VmProfile })
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
