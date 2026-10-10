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
import { VmTemplate } from './VmTemplate';
import { VmProfile } from '../lib/vmprofile';
import { tBody, tSub, tCard, cSub, cWeak, cPrimary, cCard, cBorder, scrim, rCard, bw, sp3, rBtn, btnH, btnPadX } from '../lib/uiTokens';

@Entry
@Component
struct Index {
  @Provide('navStack') navStack: NavPathStack = new NavPathStack();
  /* 工坊/存储/模板模态：都由 VmList/VmManage @Consume 对应变量，在本层(全窗口)渲染遮罩覆盖侧栏+内容 */
  @Provide('showWizard') showWizard: boolean = false;
  @Provide('showTemplate') showTemplate: boolean = false; /* 模板创建模态（与工坊并列的独立流程） */
  @Provide('showStorage') showStorage: boolean = false;
  @Provide('storageParam') storageParam: VmProfile | null = null;
  @Provide('showEdit') showEdit: boolean = false;
  @Provide('editParam') editParam: VmProfile | null = null;
  @State wizardCloseReq: number = 0; /* sheet 拦截桥（见下方 sheet 宿主注释） */
  @State editCloseReq: number = 0;
  @StorageLink('vmListVersion') vmListVersion: number = 0;
  /* 详情页重新显示的信号。编辑页压栈期间 VmManage 处于 inactive —— 官方文档明确
   * 「非栈顶 NavDestination 不响应状态变量变化、不触发 @Watch 回调」，而 pop 回来
   * 组件又不重建、aboutToAppear 不重跑，于是编辑页保存的 vmListVersion++ 打不到它，
   * 概览 chips 会停在旧值。NavDestination.onShown 是唯一能捕获「重新显示」的时机。 */
  @StorageLink('manageShownTick') manageShownTick: number = 0;

  @Builder
  pageMap(name: string, param: Object) {
    NavDestination() {
      if (name === 'manage') {
        VmManage({ profile: param as VmProfile })
      } else if (name === 'idle') {
        /* 未选中任何虚拟机时的内容区占位：居中引导，避免右侧留白 */
        Column({ space: sp3 }) {
          Text('🖥').fontSize(56)
          Text('未选择虚拟机')
            .fontSize(tCard).fontWeight(FontWeight.Medium).fontColor(cSub)
          Text('从列表中选择一台虚拟机，查看详情 / 启动 / 存储')
            .fontSize(tSub).fontColor(cWeak).textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .hideTitleBar(true)
    .onShown(() => {
      /* 只对详情页发信号；edit 页自身不需要（它每次都是新建的）。
       * 顺带 bump vmListVersion：pop 回来时侧栏若已 active，@Watch 立即生效，
       * 名称等改动不用等列表侧的 2s 轮询兜底。 */
      if (name === 'manage') {
        this.manageShownTick++;
        this.vmListVersion++;
      }
    })
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

  private closeTemplate(): void {
    this.showTemplate = false;
    this.vmListVersion++;
  }

  /* —— 四个模态统一 bindSheet 半模态承载（原生化：系统蒙层/圆角/动效/关闭链路）——
   * 宿主为 build Stack 内的常驻占位节点（sheet 要求宿主已挂载上树）。
   * 向导/编辑有未保存内容确认：shouldDismiss 不直接放行，递增 closeReq 由组件内
   * requestClose/requestCancel 走「放弃？」确认后经 onClose 真关；存储/模板无确认直接关。 */

  @Builder
  wizardSheetBuilder() {
    VmWizard({ onClose: () => this.closeWizard(), closeReq: this.wizardCloseReq })
  }

  @Builder
  templateSheetBuilder() {
    VmTemplate({ onClose: () => this.closeTemplate() })
  }

  @Builder
  editSheetBuilder() {
    VmEdit({ profile: this.editParam, closeReq: this.editCloseReq, onClose: () => this.closeEdit() })
  }

  private closeEdit(): void {
    this.showEdit = false;
    this.editParam = null;
  }

  /* 存储弹窗：bindSheet 半模态承载（首个原生化试点，替代自绘遮罩卡）——系统蒙层/
   * 圆角/动效/关闭钮，点遮罩/下拉/back 均可关，onWillDisappear 复位开关。
   * 绑在 Navigation（常驻上树）满足 sheet 宿主节点挂载要求。 */
  @Builder
  storageSheetBuilder() {
    VmStorage({ profile: this.storageParam })
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
      .bindSheet(this.showStorage, this.storageSheetBuilder(), {
        title: { title: '存储', subtitle: this.storageParam ? this.storageParam.name : '' },
        preferType: SheetType.CENTER,
        height: 540,
        width: 640,
        onWillDisappear: () => {
          this.showStorage = false;
        },
      })

      /* sheet 宿主：常驻上树的 1×1 占位节点（sheet 要求宿主已挂载；hitTest 穿透不影响布局）。
       * 向导/编辑 shouldDismiss 拦截（不 dismiss）转 closeReq 桥，由组件内确认后真关；
       * 模板无确认直接关。 */
      Column().width(1).height(1).hitTestBehavior(HitTestMode.None)
        .bindSheet(this.showWizard, this.wizardSheetBuilder(), {
          title: { title: '创建虚拟机' },
          preferType: SheetType.CENTER,
          height: 500,
          width: 640,
          shouldDismiss: (_d: SheetDismiss) => {
            this.wizardCloseReq++;
          },
          onWillDisappear: () => {
            this.showWizard = false;
          },
        })
      Column().width(1).height(1).hitTestBehavior(HitTestMode.None)
        .bindSheet(this.showTemplate, this.templateSheetBuilder(), {
          title: { title: '模板创建' },
          preferType: SheetType.CENTER,
          height: 500,
          width: 640,
          onWillDisappear: () => {
            this.showTemplate = false;
          },
        })
      Column().width(1).height(1).hitTestBehavior(HitTestMode.None)
        .bindSheet(this.showEdit, this.editSheetBuilder(), {
          title: { title: '虚拟机配置', subtitle: this.editParam ? this.editParam.name : '' },
          preferType: SheetType.CENTER,
          height: 540,
          width: 680,
          shouldDismiss: (_d: SheetDismiss) => {
            this.editCloseReq++;
          },
          onWillDisappear: () => {
            this.showEdit = false;
          },
        })
    }
    .width('100%')
    .height('100%')
  }
}
