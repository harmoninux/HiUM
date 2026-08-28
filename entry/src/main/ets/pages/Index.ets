// 应用导航壳：宽屏 Auto → 左栏 VmList（Navigation 子内容即侧栏）+ 右侧 NavDestination 详情；
// 窄屏 Auto 退化为 Stack，整页 push。工坊为【全窗口】居中模态：本层铺半透明黑遮罩 + 居中卡片
// （showWizard 开关，VmList 经 @Consume 触发；因 bindContentCover 遮罩在本
// SDK 不渲染，改用 Stack 遮罩——与 VmManage 的存储弹窗同款，保证两模态一致）。
// console 已迁出为每台 VM 独立的 VmConsoleAbility 窗口（见 VmList.openConsole）。
// 注：本 SDK(API24) 的 NavigationAttribute 无 .sideBar()，侧栏 = Navigation 的子内容本身。
import { VmList } from './VmList';
import { VmEdit } from './VmEdit';
import { VmManage } from './VmManage';
import { VmStorage } from './VmStorage';
import { VmWizard } from './VmWizard';
import { VmProfile } from '../lib/vmprofile';
import { tBody, tSub, tCard, cSub, cWeak, cPrimary, cCard, cBorder, rCard, bw, sp2, rBtn, btnH, btnPadX } from '../lib/uiTokens';

@Entry
@Component
struct Index {
  @Provide('navStack') navStack: NavPathStack = new NavPathStack();
  /* 工坊/存储模态：都由 VmList/VmManage @Consume 同一对变量，在本层(全窗口)渲染遮罩覆盖侧栏+内容 */
  @Provide('showWizard') showWizard: boolean = false;
  @Provide('showStorage') showStorage: boolean = false;
  @Provide('storageParam') storageParam: VmProfile | null = null;
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @Builder
  pageMap(name: string, param: Object) {
    NavDestination() {
      if (name === 'manage') {
        VmManage({ profile: param as VmProfile })
      } else if (name === 'edit') {
        VmEdit({ profile: param as VmProfile })
      } else if (name === 'idle') {
        /* 未选中任何虚拟机时的内容区占位：居中引导，避免右侧留白 */
        Column({ space: 12 }) {
          Text('🖥').fontSize(56)
          Text('未选择虚拟机')
            .fontSize(tCard).fontWeight(FontWeight.Medium).fontColor(cSub)
          Text('从左侧列表选择一台虚拟机，查看详情 / 启动 / 存储')
            .fontSize(tSub).fontColor(cWeak).textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
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

  private closeStorage(): void {
    this.showStorage = false;
  }

  @Builder
  wizardCover() {
    VmWizard({ onClose: () => this.closeWizard() })
  }

  /* 工坊弹窗：遮罩(压暗主界面) + 居中卡片。bindContentCover 自带遮罩在本 SDK 不渲染，
   * 故用 ArkUI Stack 在底下铺一层半透明黑（与存储弹窗同款，保证两模态一致）。
   * 点遮罩关闭；卡片自身吃掉点击、不穿透。 */
  @Builder
  wizardOverlay() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => this.closeWizard())
      Column() { this.wizardCover() }
        .width('88%').constraintSize({ maxWidth: 640 })
        .height(500)
        .backgroundColor(cCard)
        .border({ width: bw, color: cBorder })
        .borderRadius(rCard)
        .clip(true) /* 裁掉子组件(直角背景)超出圆角的部分 */
        .onClick(() => { /* 吃掉卡片区点击，避免透传遮罩误关 */ })
    }
    .width('100%').height('100%')
    .alignContent(Alignment.Center)
  }

  /* 存储弹窗：与工坊同款的全窗口遮罩 + 居中卡片，铺满主界面（侧栏+内容一起压暗）。 */
  @Builder
  storageOverlay() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => this.closeStorage())
      Column() {
        VmStorage({ profile: this.storageParam, onClose: () => this.closeStorage() })
      }
      .width('88%').constraintSize({ maxWidth: 640 })
      .height(540)
      .backgroundColor(cCard)
      .border({ width: 1, color: cBorder })
      .borderRadius(rCard)
      .clip(true) /* 裁掉子组件(直角背景)超出圆角的部分 */
      .onClick(() => { /* 吃掉卡片区点击，避免透传遮罩误关 */ })
    }
    .width('100%').height('100%')
    .alignContent(Alignment.Center)
  }

  build() {
    Stack() {
      Navigation(this.navStack) {
        VmList()
      }
      .mode(NavigationMode.Auto)
      .navBarWidth(300)
      .navDestination(this.pageMap)
      .hideTitleBar(true)

      if (this.showWizard) {
        this.wizardOverlay()
      }
      if (this.showStorage) {
        this.storageOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
