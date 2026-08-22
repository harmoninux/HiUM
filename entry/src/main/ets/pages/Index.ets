// 应用导航壳：宽屏 Auto → 左栏 VmList（Navigation 子内容即侧栏）+ 右侧 NavDestination 详情；
// 窄屏 Auto 退化为 Stack，整页 push。工坊已迁为 VmList 内嵌的居中模态（Stack 遮罩浮层）。
// console 已迁出为每台 VM 独立的 VmConsoleAbility 窗口（见 VmList.openConsole）。
// 注：本 SDK(API24) 的 NavigationAttribute 无 .sideBar()，侧栏 = Navigation 的子内容本身。
import { VmList } from './VmList';
import { VmEdit } from './VmEdit';
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
      if (name === 'manage') {
        VmManage({ profile: param as VmProfile })
      } else if (name === 'edit') {
        VmEdit({ profile: param as VmProfile })
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
    .mode(NavigationMode.Auto)
    .navBarWidth(300)
    .navDestination(this.pageMap)
    .hideTitleBar(true)
  }
}
