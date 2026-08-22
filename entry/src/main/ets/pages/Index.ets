// 应用导航壳：宽屏 Auto → 左栏 VmList（Navigation 子内容即侧栏）+ 右侧 NavDestination 详情；
// 窄屏 Auto 退化为 Stack，整页 push。工坊为【全窗口】居中模态（showWizard 开关 + wizardParam 参数，
// 由 VmList 经 @Consume 触发、在本层渲染遮罩，覆盖整个窗口而非仅侧栏）。
// console 已迁出为每台 VM 独立的 VmConsoleAbility 窗口（见 VmList.openConsole）。
// 注：本 SDK(API24) 的 NavigationAttribute 无 .sideBar()，侧栏 = Navigation 的子内容本身。
import { VmList } from './VmList';
import { VmEdit } from './VmEdit';
import { VmManage } from './VmManage';
import { VmStorage } from './VmStorage';
import { VmWizard, WizardParam } from './VmWizard';
import { VmProfile } from '../lib/vmprofile';
import { tBody, cSub, cCard, cBorder, rCard, bw } from '../lib/uiTokens';

@Entry
@Component
struct Index {
  @Provide('navStack') navStack: NavPathStack = new NavPathStack();
  /* 工坊模态：由 VmList @Consume 同一对变量；在本层(全窗口)渲染遮罩覆盖侧栏+内容 */
  @Provide('showWizard') showWizard: boolean = false;
  @Provide('wizardParam') wizardParam: WizardParam = { mode: 'new' };
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @Builder
  pageMap(name: string, param: Object) {
    NavDestination() {
      if (name === 'manage') {
        VmManage({ profile: param as VmProfile })
      } else if (name === 'edit') {
        VmEdit({ profile: param as VmProfile })
      } else if (name === 'storage') {
        VmStorage({ profile: param as VmProfile })
      } else if (name === 'idle') {
        Text('从左侧选择一台虚拟机').fontSize(tBody).fontColor(cSub)
      }
    }
    .hideTitleBar(true)
  }

  aboutToAppear(): void {
    /* 初始 content 区先渲染空态占位（宽屏 Split 下左栏列表 + 右侧「从左侧选择一台虚拟机」；
     * 点列表行进 VmList.select 用 replacePath 换成 manage） */
    this.navStack.pushPath({ name: 'idle' });
  }

  private closeWizard(): void {
    this.showWizard = false;
    this.vmListVersion++;
  }

  @Builder
  wizardCover() {
    VmWizard({ param: this.wizardParam, onClose: () => this.closeWizard() })
  }

  @Builder
  coverBuilder() {
    /* bindContentCover 自带半透明遮罩 / 点外部关闭 / 返回键 / 转场；这里只放居中卡片 */
    Column() {
      Column() { this.wizardCover() }
        .width('88%').constraintSize({ maxWidth: 640 })
        .height(500)
        .backgroundColor(cCard)
        .border({ width: bw, color: cBorder })
        .borderRadius(rCard)
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Navigation(this.navStack) {
      VmList()
    }
    .mode(NavigationMode.Auto)
    .navBarWidth(300)
    .navDestination(this.pageMap)
    .hideTitleBar(true)
    .bindContentCover($$this.showWizard, this.coverBuilder, { enableSafeArea: true })
  }
}
