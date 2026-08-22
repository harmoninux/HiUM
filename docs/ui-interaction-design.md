# HiUM · UI 交互设计（PC/Pad 桌面向 · 极简工具）

> 目标：把现有"手机竖屏 + push 整页 + 硬编码颜色"改造成**响应式宽屏桌面**的虚拟机管理器。
> 视觉语言：极简工具（白底细边框 + 留白分层 + 单主色 + mono 标签）。
> 批准稿：`.temp/ui/minimal-pc-pad-v2.html`（细化 v2，visual mockup）。

---

## 1. 为什么这样改（现状问题）

| 现状 | 问题 |
|---|---|
| `#fff2f3f5` 背景 + 白卡 + `#ff007dff` 蓝 | 默认示例蓝、无品牌；状态色在各文件里**硬编码**，改一处要全改 |
| 浅灰底 vs 白卡靠 border-radius 区分 | 层级弱，选中的卡片直接灌成深蓝底，生硬 |
| padding 8/12/16 混用、标题 18/24 | 无排版 scale，视觉松散 |
| 单列往下滚 + `NavPathStack.push` 整页 | 手机式；Pad/PC 宽屏浪费空间，需来回跳转 |
| 模板选择 = 全屏白盖板，无遮罩无动画 | 突兀；列表页卡片"点正门+长按菜单+启动按钮"三重交互易误触 |
| 无空态、toast 打断式 | 引导弱、反馈突兀 |

## 2. 三个决策（桌面范式）

1. **主窗口 = split-view**（左 `VM 列表` 侧栏 + 右 `详情`），不改 push 整页 → 选中即看，符合"VM 管理器"高频心智。
2. **机器工坊 / 模板选择 = 居中模态**（遮罩 + 大卡片），不离开当前上下文。
3. **VM 屏幕 = 独立窗口**（`VmConsoleAbility`，每台 VM 一个），PC 可多开平铺、Pad 单开全屏。

## 3. Design Token（新文件 `entry/src/main/ets/lib/uiTokens.ets`）

集中常量，替换散落各文件的硬编码颜色/字号/间距。

**颜色 color（`%{public}s` 形如 `#ff0563ff`）**

| 语义 | 值 | 用途 |
|---|---|---|
| `primary` | `#ff0563ff` | 主色：主按钮/选中/强调 |
| `danger` | `#ffd92d20` | 危险/删除/强制断电 |
| `running` | `#ff1f7a44` | 运行中 |
| `warn` | `#ffb25e09` | 需自备镜像/缺 media |
| `text` | `#ff15181c` | 主文本 |
| `sub` | `#ff8a8f98` | 次级文本 |
| `weak` | `#ff9ca3af` | 弱文本/占位 |
| `bg` | `#fffafafa` | 页面背景 |
| `card` | `#ffffffff` | 卡片 |
| `border` | `#ffe8e8e8` | 卡/元素边框 |
| `block` | `#fff1f2f4` | 灰底块（参数预览/图标底） |
| `chip` | `#fff1f2f4` | chips 底 |

**字号 type**

| token | 值 | 用途 |
|---|---|---|
| `tPage` | 16 / 700 | 页面/窗口标题 |
| `tCard` | 13 / 600 | 卡片/行标题 |
| `tLabel` | 13 / 400 | 设置行标签 |
| `tBody` | 12 / 400 | 正文/按钮 |
| `tSub` | 11 / 400 | 次级说明 |
| `tMono` | 9–10 | 状态/指纹（mono） |

**间距 spacing**：`4 · 8 · 12 · 16 · 24`（卡片 padding 12、间距 8、页边 16）。
**圆角 radius**：卡/按钮 8、小元素 6、徽标 3。**边框**：`1px #ffe8e8e8`（分层靠细边框，不用阴影）。
**mono 字体**：`ui-monospace` 承载架构/参数/run 状态标签。

## 4. 各界面改造点

### 4.1 主窗口（`Index.ets` + `VmList.ets` + 新增详情容器）
- `Navigation` 改 `NavigationMode.Split / Auto`：`sideBar` = `VmList`，content = 选中 VM 的 `VmManage`（或一个顶层 wrap-value 的详情页）。
- **侧栏 `VmList`**：
  - 顶部：`虚拟机` 标题 + `＋ 新建` 主按钮。
  - 搜索框：按名称/架构过滤（`@State filter` → `profiles.filter(...)`）。
  - 汇总 pill：`● N 运行` / `M 已停`（复用 `vmregistry`）。
  - 列表行：`[thumb mono 架构] [名称 + 徽标] [规格描述]`，选中高亮（`#fff0f6ff` + 主色描边）；点击选中进详情，`进入/启动` 按钮独立。
  - 空间 300px，响应式：`<760px` 侧栏折到顶部。
- **详情容器（页内 content）**：顶部 `名称 + 运行徽标 + arch mono 标 + [进入][编辑][删除]`；下分词条 chips；再按**分区**滚动：系统盘 / 快照·时光机 / 网络 / 高级。
- 空态：无 VM → 侧栏"从模板新建"插画；未选中 → "从左侧选择一台虚拟机"。

### 4.2 详情分区 + 快照时间线（重组 `VmManage.ets`）
- 分区标题（小灰大写 + 细分割线）：`系统盘`、`快照 · 时光机`、`网络`、`高级`。
- **系统盘**：`qcow2 · 虚拟8.0G · 实占1.2G` + 进度条（实占/虚拟比）+ `信息/扩容/移除`。
- **快照时间线**：竖向时间轴，历史快照描边节点、当前实心蓝点，每点 `恢复/删除`；保留现有 `temporarySession` 临时会话开关。
- **网络**：启用开关 + 端口转发 + 9p 共享（子说明）。
- **高级（折叠）**：MTTCG / tb-size / extraArgs / 直启内核。
- 保留 `expand`/`diskResize`/`snapshotCreate/Apply/Delete` 的原逻辑，只换壳。

### 4.3 机器工坊 `VmWizard.ets`（由 NavDestination 页面改居中模态）
- `bindContentCover`（或 `CustomDialogController`）承载，遮罩 + 居中卡（宽 ~720，响应式）。
- 顶：`取消 | 机器工坊 | 下一步`；底：`上一步 / 取消`。
- 步骤条改**编号圆点 + 分隔线**：当前主色实心、已过主色描边、未到置灰（`step/STEPS` 状态机复用）。
- 各步内容（架构/板卡/CPU/介质/网络/命名）沿用现有 builder，仅配色/间距换 token；`buildArgs` 只读预览块用 mono 灰底。

### 4.4 模板选择（磁贴网格模态）
- 复用工坊模态容器，磁贴网格 `4 磁贴`（🐧 Alpine 内置 / 🤖 Android 需自备 / 💾 FreeDOS 需自备 / ⚙️ 裸内核需自备），每磁贴：图标 + 名 + mono 参数 + 徽标。
- 底部一条 `从零开始（手工向导）`。点磁贴 → `WizardParam{mode:'new', template}` 进工坊。

### 4.5 反馈（snackbar 替代打断式 toast）
- 右下角浅色/深色 snackbar：`✓ 已创建快照「A」`，2s 自动淡出。
- 用于创建/扩容/恢复/删快照等"易回应"操作；错误类仍可 toast。

### 4.6 配色替换（`VmEdit.ets` / `StorageOverview.ets` / `VmConsole.ets`）
- 仅把 `#ff2e7d32`/`#ff9900`/`#ff666666`/`#fff2f3f5` 等换成 token。
- `VmEdit`：保留为高级编辑入口；列表改为分区 + 设置行。
- `StorageOverview`：白卡+细边框；配额卡 + ISO 列表 + 体检。
- `VmConsole`：工具条半透明黑微调；状态右上 mono `running/paused`。

## 5. 响应式断点

| 宽度 | 布局 |
|---|---|
| `< 600`（手机，非重点） | 单列，Details 也可回退 push（保兼容） |
| `600–840` | 侧栏可折叠，双栏 |
| `≥ 840`（Pad/PC） | 完整 split-view（侧栏 300 + 详情 flex） |

基于 `@ohos.window` / `window.getWindowProperties().windowRect.width` 或 `onAreaChange` 判定，驱动 `NavigationMode`。

## 6. 实现拆分（供 writing-plans 展开）

| step | 内容 | 文件 |
|---|---|---|
| 1 | `uiTokens.ets`（颜色/字号/间距/圆角常量）+ 公共基础组件（`uiCard`/`StatusBadge`/`LabelRow`/`Snackbar` @Builder） | 新增 |
| 2 | 主窗口 Split 模式（sideBar=列表 + content=详情）+ 侧栏搜索/汇总/选中态 | Index/VmList/新详情容器 |
| 3 | 详情分区重组 + 快照时间线 + snackbar | VmManage |
| 4 | 工坊改居中模态 + 磁贴模板 + 步骤条 | VmWizard |
| 5 | 配置/存储/console 配色换成 token（无行为变化） | VmEdit/Storage/VmConsole |
| 6 | 空态 + 全局硬编码颜色清零 + 全量回归 | 全 |

## 7. ArkTS 约束注意
- `Navigation` Split 需同时给 `sideBar`/`navDestination`（`navDestination` 处理详情跳转，sideBar 直接嵌 content）。
- 模态：`bindContentCover` 在 ArkTS 需完整 builder；或 `CustomDialogController`（弹窗实例注意生命周期）。
- `NavigationMode.Auto` 会自动按窗口宽度切换 Split/Stack，优先用它。
- 组件 `@Builder` 复用，避免 each 页重复样式；颜色引用走 token 常量不再内联。

## 8. 验证
1. `make hap` 无 ArkTS Error/警告。
2. 部署（项目 HDC `-s 192.168.1.3:8710 -t 127.0.0.1:5555` + `bm install -p`）进程存活、无 FATAL/CRASH/SIGSEGV。
3. 设备人工过：列表选中→详情、搜索过滤、模板磁贴→工坊、快照时间线、snackbar、空态。
4. 每 step 一项一 commit、一项一验证（Build + Deploy + 进程存活）。
