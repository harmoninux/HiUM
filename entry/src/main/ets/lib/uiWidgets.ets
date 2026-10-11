/* 跨页公共小组件：同一视觉角色只留一处定义。
 * 收编三类历史分叉：① 选择胶囊 Chip（曾是 cChip/cBg 两种底、rBadge/rBtn 两种圆角、
 * tBody/tSub 两种字号的三套写法）；② 分组标题 SecHead（曾是 tLabel/tSub 两种字号）；
 * ③ 右下角 Snackbar（曾是 VmManage/VmStorage 两份逐行相同的拷贝）。
 * Chip 等“无状态展示”用 @Prop（父级重算即刷新）；Snackbar 持有 2 秒自动消失的
 * 定时器，故用 @Link 自持状态（页面只需 this.snack = '...'）。 */

import { cPrimary, cSub, cWeak, cText, cChip, cBorder, cBg, rBadge, rElem, rBtn, sp1, sp3, sp4, sp5, sp2, tBody, tCard, tItem, tSub } from './uiTokens';

/* 选择胶囊：单选一组的选项（未选 cChip 底 + cSub 字；选中 cPrimary 底 + 白字）。
 * 用法：Chip({ label: 'virtio', active: this.iface === 'virtio', onTap: () => this.iface = 'virtio' })
 * ⚠ 不用 .margin() 直接修饰本组件（自定义组件不支持通用属性），需要间距的
 * Flex 换行场景用 Row 包一层再给 Row 加 margin。
 * ⚠ 没有置灰位、成员也绝不能叫 enabled：CustomComponent 基类已占用该名（通用属性
 * 方法 enabled(value): CommonAttribute），同名字段会被编译器拒绝；将来要置灰态请换名。 */
@Component
export struct Chip {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(tItem)
      .fontColor(this.active ? Color.White : cSub)
      /* 可交互胶囊：行内控件跟随所在行的条目档（tItem），保证与旁边标签/值文字同大；
       * 与按钮/输入框同圆角档(rBtn)。不可点的信息徽标（tSub + 8/4 padding）再小一档 */
      .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
      .backgroundColor(this.active ? cPrimary : cChip)
      .borderRadius(rBtn)
      .onClick(() => this.onTap())
  }
}

/* 分组标题：灰字在左、细线延伸至右 */
@Component
export struct SecHead {
  @Prop label: string = '';

  build() {
    Row({ space: sp2 }) {
      Text(this.label).fontSize(tCard).fontColor(cSub)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp3, bottom: sp1 })
  }
}

/* 折叠组头：点击展开/收起。标题与 ▸/▾ 提示合成同一 Text 的 Span（单行盒排版），
 * 避免符号与文字字体度量不同而垂直错位（三处旧实现的既有结论，收编于此） */
@Component
export struct FoldHead {
  @Prop label: string = '';
  @Prop collapsed: boolean = true;
  onToggle: () => void = () => {};

  build() {
    Row({ space: sp2 }) {
      Text() {
        Span(this.label).fontColor(cSub)
        Span(this.collapsed ? ' ▸ 展开' : ' ▾ 收起').fontColor(cWeak).fontSize(tSub)
      }
      .fontSize(tCard)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp3, bottom: sp1 })
    .onClick(() => this.onToggle())
  }
}

/* 右下角成功提示：@Link 双向——页面置消息，组件在 2 秒后自行清空（新消息会重置
 * 计时）。同消息连发时靠 SetTimeout 前清旧定时器保证重新计时。
 * 配色用「主文本色当底 + 页面底色当字」的反色对：浅色主题 = 深底浅字、
 * 深色主题 = 浅底深字，两个主题下对比度都成立（旧实现固定白字，深色主题下
 * 白字落在浅底上不可读）。 */
@Component
export struct Snackbar {
  @Link @Watch('onChanged') msg: string;
  private timer: number = -1;

  onChanged(): void {
    if (this.msg.length === 0) {
      return;
    }
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    const cur = this.msg;
    this.timer = setTimeout(() => {
      this.timer = -1;
      if (this.msg === cur) {
        this.msg = '';
      }
    }, 2000);
  }

  build() {
    if (this.msg.length > 0) {
      Row() {
        Text(this.msg).fontSize(tBody).fontColor(cBg)
      }
      .padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
      .backgroundColor(cText).borderRadius(rElem)
      .position({ right: sp5, bottom: sp5 })
    }
  }
}
