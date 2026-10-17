/* 跨页公共小组件：同一视觉角色只留一处定义。
 * 收编三类历史分叉：① 选择胶囊 Chip（曾是 cChip/cBg 两种底、rBadge/rBtn 两种圆角、
 * tBody/tSub 两种字号的三套写法）；② 分组标题 SecHead（曾是 tLabel/tSub 两种字号）；
 * ③ 右下角 Snackbar（曾是 VmManage/VmStorage 两份逐行相同的拷贝）。
 * Chip 等“无状态展示”用 @Prop（父级重算即刷新）；Snackbar 持有 2 秒自动消失的
 * 定时器，故用 @Link 自持状态（页面只需 this.snack = '...'）。 */

import { cPrimary, cSub, cWeak, cText, cChip, cBorder, cBg, rBadge, rElem, rBtn, sp1, sp3, sp4, sp5, sp2, tBody, tCard, tItem, tSub, tLabel, tMono, btnSh, btnRow, inpH, inpBg, inpRadius, inpPadX } from './uiTokens';

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
       * 与按钮/输入框同圆角档(rBtn)。不可点的信息徽标（tSub + 8/4 padding）再小一档。
       * 高度用 btnRow（38px 行内控件档，与开关图形等高；垂直居中由 Text 处理，
       * 垂直 padding 去掉——padding 与 height 叠加语义会造成高度歧义） */
      .padding({ left: sp3, right: sp3 })
      .height(btnRow)
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

/* ---- 设置项七范式（2026-10-17 标准，规格见 docs/superpowers/specs/2026-10-17-setting-row-standard.md）----
 * 大原则：**标签和注释都在左侧（堆叠），具体操作项在右侧，垂直居中**——右侧控件
 * 以「标签+注释」整块为锚居中，不许只对标签首行居中（chips/开关旧置底形实测偏上
 * ~27px 被打回）。全局规则：值型行（Field/Value/Info）72 固定标签列；开关/选项行
 * 左列弹性堆叠；desc 一律 tSub + cWeak；根 Row/Column 一律 .width('100%')（Row 不
 * 撑满会被外层 Column 水平居中）。
 * desc 是否配 = 判据制：术语望文不生义 / 选择有隐性代价 / 行为反直觉 / 默认值需背书，
 * 满足其一才配；自解释项不配（如「声音」）。ChipGroup 不设组件——向导三种组
 * （wrap 流式 / 磁贴 / FoldHead 折叠）各有结构，规范只收录不收编。 */

/* 字段输入行：72 列标签 + 标准输入框，单行控件随标签行居中。不设 desc——
 * 注释一律左堆叠（大原则），带注释的输入项由调用方组 B 形（现役：GDB 调试
 * 开关行配注释、监听端口纯输入行）。⚠ TextInput 默认上下 padding 8vp，32 高
 * 必须显式压到 sp1（历史实测：不压文字上下被裁）。 */
@Component
export struct FieldRow {
  @Prop label: string = '';
  @Prop text: string = '';
  @Prop placeholder: string = '';
  @Prop maxLength: number = -1;
  onChange: (v: string) => void = (_v: string) => {};

  build() {
    Row() {
      Text(this.label).fontSize(tLabel).width(72)
      TextInput({ text: this.text, placeholder: this.placeholder })
        .layoutWeight(1)
        .maxLength(this.maxLength)
        .fontSize(tItem)
        .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg)
        .padding({ left: inpPadX, right: inpPadX, top: sp1, bottom: sp1 })
        .onChange((v: string) => this.onChange(v))
    }
    .width('100%')
  }
}

/* 只读值行：纯文本值。「不可编辑」不可长得像输入框（旧实现借 inpBg 底盒，误导）。 */
@Component
export struct ValueRow {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label).fontSize(tLabel).width(72)
      Text(this.value).fontSize(tItem).fontColor(cSub)
    }
    .width('100%')
  }
}

/* 开关行（B 形）：标签 + desc 左侧堆叠，Toggle 右侧随整块垂直居中（Row 默认
 * Center 对齐）——系统设置列表同款。desc 超一行时在左列换行（开关仍居中），
 * 不再提供置底形态——大原则「标签和注释都在左侧」无例外（2026-10-17，旧
 * descBelow 置底形开关只对首行居中，与 chips 同病，已废）。
 * ⚠ 成员不能叫 enabled（CustomComponent 基类占用，同名通用属性方法冲突），
 * 置灰位叫 enable。⚠ Toggle 不可 .height() 压（图形随盒缩放）；组件盒自带
 * ~14px 下沿留白，可见开关相对文字块视觉偏上 ~7px（≈2.4vp），translate 下移
 * 补偿（真机 dumpLayout 量测，2026-10-17）。 */
@Component
export struct ToggleRow {
  @Prop label: string = '';
  @Prop isOn: boolean = false;
  @Prop desc: string = '';
  @Prop enable: boolean = true;
  onChange: (v: boolean) => void = (_v: boolean) => {};

  build() {
    Row({ space: sp3 }) {
      Column({ space: sp1 }) {
        Text(this.label).fontSize(tLabel)
        if (this.desc.length > 0) {
          Text(this.desc).fontSize(tSub).fontColor(cWeak)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .enabled(this.enable)
        .translate({ y: 2.4 })
        .onChange((v: boolean) => this.onChange(v))
    }
    .width('100%')
  }
}

/* 选项行（≤4 项）：B 形——标签 + desc 左侧堆叠，chips 右侧随整块垂直居中
 *（与 ToggleRow 同构；真机量测：desc 置底旧形下 chips 只对标签行居中，相对
 * 标签+注释整块偏上 ~27px，用户打回 2026-10-17）。desc 可随选中联动（调用方
 * 传计算表达式）。labels：显示名（与 options 一一对应）——枚举值与展示串大小写
 * 不同时必传（磁盘接口 'ide' vs 'IDE'：原值比较不相等曾致两枚全不亮，且点选会把
 * 展示串当值落盘，2026-10-17）。选项数超宽/需换行 → 向导的 wrap 流式组装。 */
@Component
export struct ChipRow {
  @Prop label: string = '';
  @Prop options: string[] = [];
  @Prop labels: string[] = [];
  @Prop value: string = '';
  @Prop desc: string = '';
  onChange: (v: string) => void = (_v: string) => {};

  private labelOf(o: string, idx: number): string {
    return this.labels.length === this.options.length ? this.labels[idx] : o;
  }

  build() {
    Row({ space: sp3 }) {
      Column({ space: sp1 }) {
        Text(this.label).fontSize(tLabel)
        if (this.desc.length > 0) {
          Text(this.desc).fontSize(tSub).fontColor(cWeak)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      /* ui-layout-ok: chips 按内容宽，靠外层 Row 右置 */
      Row({ space: sp3 }) {
        ForEach(this.options, (o: string, idx: number) => {
          Chip({ label: this.labelOf(o, idx), active: this.value === o, onTap: () => this.onChange(o) })
        }, (o: string) => o)
      }
    }
    .width('100%')
  }
}

/* 滑条行：标签左（弹性）+ 滑条右固定宽 + 实时值最右（固定列宽右对齐，多组滑条
 * 数值竖向成列可扫）。滑条不再全宽置底——「操作项在右侧垂直居中」大原则
 *（2026-10-17，旧全宽形是唯一操作项在行外的范式，用户重申原则后收编）；
 * 160 固定宽拖动手感足够。desc 不配（自解释连续量）。 */
@Component
export struct SliderRow {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop min: number = 0;
  @Prop max: number = 100;
  @Prop step: number = 1;
  format: (v: number) => string = (v: number): string => `${Math.round(v)}`;
  onChange: (v: number) => void = (_v: number) => {};

  build() {
    Row({ space: sp3 }) {
      Text(this.label).fontSize(tLabel).layoutWeight(1)
      Slider({ value: this.value, min: this.min, max: this.max, step: this.step })
        .onChange((v: number) => this.onChange(v))
        .width(160)
        .height(btnRow)
      Text(this.format(this.value)).fontSize(tItem).fontColor(cSub)
        .width(64)
        .textAlign(TextAlign.End)
    }
    .width('100%')
  }
}

/* 信息行：72 列标签 + 主值/等宽副值列 + 可选动作钮，整行垂直居中（标签/按钮/
 * 内容列三者的中心对齐——2026-10-17 真机量测：顶对齐会让三者中心各差 10~20px）。
 * ⚠ sub 是数据（tMono 等宽），不是注释（cWeak 常规）——两种灰色小字靠字体区分，
 * 勿混。mainDim 空态占位（未配置/无）：主值降为说明档 tSub+cWeak——占位与真数据
 * 同档会抢视线（「未配置用了标签同等级字体」打回，2026-10-17）。
 * 多值列表变体（光盘 ISO 若干行）结构各异不收编。 */
@Component
export struct InfoRow {
  @Prop label: string = '';
  @Prop main: string = '';
  @Prop mainDim: boolean = false;
  @Prop sub: string = '';
  @Prop actionLabel: string = '';
  onAction: () => void = () => {};

  build() {
    Row() {
      Text(this.label).fontSize(tLabel).width(72)
      Column({ space: sp1 }) {
        Text(this.main).fontSize(this.mainDim ? tSub : tItem).fontColor(this.mainDim ? cWeak : cText)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.sub.length > 0) {
          Text(this.sub).fontSize(tMono).fontColor(cWeak)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel).focusable(false).fontSize(tItem)
          .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
          .backgroundColor(Color.Transparent).fontColor(cPrimary)
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
