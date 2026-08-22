# HiUM UI 交互改造 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有手机式竖屏 UI 改造成 Pad/PC 桌面向的极简工具风格虚拟机管理器（split-view + 居中模态 + 独立窗口），并收敛全部硬编码颜色为统一 token。

**Architecture:** 主窗口 `Navigation` 改 `NavigationMode.Auto`（宽屏自动 Split，窄屏退回 Stack），侧栏呈现 VM 列表、content 区渲染详情；工坊/模板改为 `bindContentCover` 居中模态；`VmConsoleAbility` 维持每台 VM 一窗口。新增 `uiTokens.ets` 集中颜色/字号/间距，逐页替换硬编码。

**Tech Stack:** HarmonyOS / ArkTS (API 6.1.1 / targetSdk 24), ArkUI `Navigation`/`bindContentCover`/`XComponent`, QEMU NCP 子进程, DevEco hvigor。

**验证模式映射（本项目无 ArkTS 单测框架，用构建+部署验证）：**
- `make hap` = 编译通过（ArkTS/CPP 无 Error）→ 相当于"测试通过"。
- `make install` = 部署 + `aa start` + 进程存活 → 相当于"运行验证"。
- `make log` = hilog 过滤，确认无 `CRASH`/`SIGSEGV`/`FATAL`。
- 每 Task 一项一 commit、一项一验证。

**参考设计稿：** `docs/ui-interaction-design.md`（spec）；mockup `.temp/ui/minimal-pc-pad-v2.html`。

---

## Task 1: 新增 `uiTokens.ets`（颜色/字号/间距/圆角常量）

**Files:**
- Create: `entry/src/main/ets/lib/uiTokens.ets`

思想：全部页面不再内联颜色，引用统一常量。用**独立的具名 const 导出**（ArkTS 对 `as const`/Record 字面量的处理不稳，用裸常量最稳）。

- [ ] **Step 1: 写 `uiTokens.ets`**

```ts
/* 统一设计 token：颜色 / 字号 / 间距 / 圆角。所有页面改用这些常量，禁止内联色值。 */

/* ---- 颜色 ---- */
export const cPrimary  = '#ff0563ff'; /* 主色：主按钮/选中/强调 */
export const cDanger   = '#ffd92d20'; /* 危险：删除/强制断电 */
export const cRunning  = '#ff1f7a44'; /* 运行中 */
export const cWarn     = '#ffb25e09'; /* 需自备镜像/缺媒体 */
export const cText     = '#ff15181c'; /* 主文本 */
export const cSub      = '#ff8a8f98'; /* 次级文本 */
export const cWeak     = '#ff9ca3af'; /* 弱文本/占位 */
export const cBg       = '#fffafafa'; /* 页面背景 */
export const cCard     = '#ffffffff'; /* 卡片 */
export const cBorder   = '#ffe8e8e8'; /* 卡/元素边框 */
export const cBlock    = '#fff1f2f4'; /* 灰底块（参数预览/图标底） */
export const cChip     = '#fff1f2f4'; /* chips 底 */
export const cSel      = '#ffdbe9ff'; /* 侧栏选中描边/浅底（#cddffe 同族） */
export const cSelBg    = '#ffeef4ff'; /* 选中浅底 */

/* ---- 字号 (size / weight) ---- */
export const tPage  = 16; /* 页面/窗口标题 700 */
export const tCard  = 13; /* 卡片/行标题 600 */
export const tLabel = 13; /* 设置行标签 400 */
export const tBody  = 12; /* 正文/按钮 400 */
export const tSub   = 11; /* 次级说明 400 */

/* ---- 间距 ---- */
export const sp1 = 4;
export const sp2 = 8;
export const sp3 = 12;
export const sp4 = 16;
export const sp5 = 24;

/* ---- 圆角 / 边框 ---- */
export const rCard = 8;     /* 卡/按钮 */
export const rElem = 6;     /* 小元素 */
export const rBadge = 3;    /* 徽标 */
export const bw = 1;
```

- [ ] **Step 2: 编译通过**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`（`uiTokens.ets` 无 Error）。

- [ ] **Step 3: Commit**

```bash
git add entry/src/main/ets/lib/uiTokens.ets
git commit -m "UI(1/6) design token：颜色/字号/间距/圆角集中到 uiTokens"
```

---

## Task 2: 主窗口改 `NavigationMode.Auto` + 侧栏列表 + 搜索/汇总/选中态

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`
- Modify: `entry/src/main/ets/pages/VmList.ets`
- Modify (若缺): `entry/src/main/ets/module.json5`（无需改，VmManage 是 NavDestination 非 @Entry）

思想：`Navigation().mode(NavigationMode.Auto)` 让宽屏自动 Split（侧栏+内容）、窄屏退化成 Stack。侧栏 builder 是 VM 列表；点某行 `navPathStack.pushPath({name:'manage', param: p})` → 在 content 区渲染详情（Split）或覆盖全屏（Stack）。

- [ ] **Step 1: `Index.ets` 改为 Auto + sideBar + pageMap**

```ts
@Entry
@Component
struct Index {
  @Provide('navStack') navStack: NavPathStack = new NavPathStack();

  @Builder
  sideBar() {
    VmList()
  }

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
      /* wizard 迁移到模态后不再走 navDestination；保留注释，见 Task 4 */
    }
    .hideTitleBar(true)
  }

  build() {
    Navigation(this.navStack) {
      // Navigation 第一个子为默认 content；放空占位，实际由 sideBar 提供侧栏、navDestination 渲染内容
      Text('').hidden(true)
    }
    .mode(NavigationMode.Auto)
    .sideBar(this.sideBar)
    .navDestination(this.pageMap)
    .hideTitleBar(true)
  }
}
```

> 核对点：`NavigationMode.Auto` 在 API 12+ 可用；若编译器只认 `Stack|Split`，改用 `.mode(NavigationMode.Split)` 并在窄屏个案处理。以 DevEco 实际报错为准，二选一，其余不变。

- [ ] **Step 2: `VmList.ets` 改造成侧栏样式**（顶部标题+按钮、搜索框、汇总 pill、行选中态、空态）

在 `build()` 里替换：删掉整页 `Column+Row+List` 头盔，改为侧栏结构，并加 `@State filter` / `@State selectedId`。

```ts
  @State filter: string = '';
  @State selectedId: string = '';

  private filtered(): VmProfile[] {
    if (this.filter.length === 0) return this.profiles;
    const f = this.filter.toLowerCase();
    return this.profiles.filter((p: VmProfile) =>
      p.name.toLowerCase().indexOf(f) >= 0 ||
      p.machine.arch.toLowerCase().indexOf(f) >= 0);
  }

  private select(p: VmProfile): void {
    this.selectedId = p.id;
    this.navStack.pushPath({ name: 'manage', param: p });
  }

  private runningCount(): number { return this.profiles.filter((p: VmProfile) => this.isRunning(p)).length; }
```

侧栏 UI 骨架（用 token 常量替换原色值）：

```ts
  build() {
    Column() {
      Row({ space: sp2 }) {
        Text('虚拟机').fontSize(tPage).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('＋ 新建').fontSize(tBody).height(30).backgroundColor(cPrimary).fontColor(Color.White)
          .onClick(() => this.showPicker = true)
      }
      .width('100%').padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })

      Row() {
        TextInput({ text: this.filter, placeholder: '搜索名称 / 架构' })
          .layoutWeight(1).fontSize(tBody).height(32)
          .onChange((v: string) => this.filter = v)
      }
      .width('100%').padding({ left: sp3, right: sp3, bottom: sp2 })

      Row({ space: sp2 }) {
        Text(`● ${this.runningCount()} 运行`).fontSize(tSub).fontColor(cRunning)
        Text(`${this.profiles.length - this.runningCount()} 已停`).fontSize(tSub).fontColor(cSub)
      }
      .width('100%').padding({ left: sp3, right: sp3, bottom: sp2 })

      if (!this.firmwareReady) {
        Text('固件未就绪（需先 make deps）').fontSize(tSub).fontColor(cDanger).padding(sp3)
      }

      if (this.filtered().length === 0) {
        this.emptySide()
      }

      List({ space: sp1 }) {
        ForEach(this.filtered(), (p: VmProfile) => {
          ListItem() {
            this.sideRow(p)
          }
        }, (p: VmProfile) => p.id + ':' + this.thumbTick)
      }
      .layoutWeight(1)
      .padding({ left: sp2, right: sp2, bottom: sp2 })
    }
    .width('100%').height('100%').backgroundColor(cBg)
  }

  @Builder
  emptySide() {
    Column() {
      Text('🖥️').fontSize(30)
      Text('还没有虚拟机').fontSize(tCard).fontWeight(FontWeight.Medium).margin({ top: sp2 })
      Text('从模板快速创建，或手工配置一台').fontSize(tSub).fontColor(cSub).margin({ top: sp1, bottom: sp2 })
      Row({ space: sp2 }) {
        Button('＋ 从模板新建').fontSize(tBody).backgroundColor(cPrimary).fontColor(Color.White)
          .onClick(() => this.showPicker = true)
        Button('从零开始').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cSub)
          .onClick(() => this.openWizardNew(null))
      }
    }.padding(sp5).alignItems(HorizontalAlign.Center).width('100%')
  }
```

行组件 `sideRow`（缩略图 + 名称/徽标 + 规格；点击选中进详情，启动/进入按钮独立，长按菜单保留）：

```ts
  @Builder
  sideRow(p: VmProfile) {
    Row({ space: sp2 }) {
      // 缩略图
      if (fs.accessSync(this.store().thumbPath(p.id))) {
        Image('file://' + this.store().thumbPath(p.id))
          .width(40).height(26).objectFit(ImageFit.Cover).borderRadius(rElem)
      } else {
        Text(p.machine.arch).fontSize(10).fontColor('#ff555555').fontFamily('monospace')
          .width(40).height(26).textAlign(TextAlign.Center)
          .backgroundColor(cBlock).borderRadius(rElem)
      }
      Column({ space: 2 }) {
        Row({ space: sp2 }) {
          Text(p.name).fontSize(tCard).fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.isRunning(p)) { Text('● 运行').fontSize(9).fontColor(cRunning).backgroundColor('#ffe9f7ef').padding({ left: sp1, right: sp1, top: 1, bottom: 1 }).borderRadius(rBadge) }
          if (this.mediaIssue(p).length > 0) { Text('缺媒体').fontSize(9).fontColor(cWarn).backgroundColor('#fffff4e6').padding({ left: sp1, right: sp1, top: 1, bottom: 1 }).borderRadius(rBadge) }
        }
        Text(`${p.machine.arch} · ${p.runtime.memoryMB}MB · ${p.runtime.cpus}核` + (p.media.cdromPath ? ' · 光盘' : '') + this.diskUsed(p))
          .fontSize(10).fontColor(cSub).maxLines(1)
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      Button(this.isRunning(p) ? '进入' : '启动')
        .fontSize(tBody).height(26)
        .backgroundColor(this.isRunning(p) ? cPrimary : Color.Transparent)
        .fontColor(this.isRunning(p) ? Color.White : cPrimary)
        .onClick(() => this.openConsole(p))
    }
    .width('100%').padding(sp2)
    .backgroundColor(this.selectedId === p.id ? cSelBg : Color.Transparent)
    .borderRadius(rElem)
    .border(this.selectedId === p.id ? { width: bw, color: cSel } : { width: bw, color: Color.Transparent })
    .onClick(() => this.select(p))
    .bindContextMenu(this.cardMenu(p), ResponseType.LongPress)
  }
```

> 说明：`vmCard` 整块改名为 `sideRow`；保留 `cardMenu`（编辑/删除/安全关机/强制断电）作长按菜单；`confirmPowerOff/powerOff/openWizardEdit/confirmDelete/openConsole/store/reload/pollTick/diskUsed/mediaIssue` 原样保留。

- [ ] **Step 3: 编译**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`。若报 `NavigationMode.Auto` 不存在，见 Step 1 核对点，改用 `Split`。

- [ ] **Step 4: 部署 + 进程存活 + 无崩溃**

Run: `make install && make log`
Expected: 应用能启动；`make log` 无 `CRASH`/`SIGSEGV`/`FATAL`。宽屏下应看到侧栏列表 + 右侧可点开详情。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/pages/Index.ets entry/src/main/ets/pages/VmList.ets
git commit -m "UI(2/6) 主窗口 Navigation Auto + 侧栏列表/搜索/汇总/选中态"
```

---

## Task 3: `VmManage` 详情分区重组 + 快照时间线 + snackbar

**Files:**
- Modify: `entry/src/main/ets/pages/VmManage.ets`

思想：详情区从"列表两块卡"改为**分区滚动**（系统盘/快照·时光机/网络/高级），系统盘加实占进度条，快照改竖向时间线（当前实心蓝点），临时会话保留为分区内开关。逻辑（`diskResize/snapshot*/expand/remove`）全部保留，只换壳 + 加 snackbar。

- [ ] **Step 1: 引入 token 与 `selectedId` 相关工具，重写 `build()`**

顶部结构：

```ts
  build() {
    Column() {
      // 顶栏：返回 + 名称/徽标/arch + 操作按钮
      Row({ space: sp2 }) {
        Button('返回').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cPrimary)
          .onClick(() => this.navStack.pop())
        Blank()
        Text(this.name).fontSize(tPage).fontWeight(FontWeight.Bold)
        if (this.profile && vmIsRunning(this.profile.id)) {
          Text('●').fontSize(10).fontColor(cRunning)
        }
        Text(this.arch).fontSize(tSub).fontColor(cSub)
        Blank()
        Text('运行中').fontSize(tSub).fontColor(cRunning).hidden(!(this.profile && vmIsRunning(this.profile.id)))
      }
      .width('100%').padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })

      Scroll() {
        Column() {
          /* —— 概览 chips —— */
          Row({ space: sp1 }) {
            Text(`内存 ${this.mem()}G`).fontSize(tSub).fontColor(cText).backgroundColor(cChip).padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 }).borderRadius(rElem)
            Text(`核 ${this.cpusC()}`).fontSize(tSub).fontColor(cText).backgroundColor(cChip).padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 }).borderRadius(rElem)
            Text(this.boardLabel()).fontSize(tSub).fontColor(cText).fontFamily('monospace').backgroundColor(cChip).padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 }).borderRadius(rElem)
          }
          .width('100%').margin({ bottom: sp2 })

          this.secSystemDisk()
          this.secSnapshot()
          this.secNet()
          this.secAdvanced()
        }
        .width('100%').padding({ left: sp3, right: sp3, bottom: sp4 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor(cCard)
  }
```

> 以下 helper 函数补齐：`mem()` 取 `Math.round(memoryMB/1024)`，`cpusC()` 取 `runtime.cpus`，`boardLabel()` 取 `profile.machine.machine`。`profile.memoryMB` 需从 `profile.runtime` 取——若 VM 内存现以 MB 存（1G=1024），`mem()` 返回 `(Math.round(profile.runtime.memoryMB/1024))` 元字符。用实际字段为准：`p.runtime.memoryMB`。

各分区 builder：

```ts
  @Builder
  secSystemDisk() {
    this.secHead('系统盘')
    if (!this.diskPath) {
      Text('未配置系统盘，可到配置页添加').fontSize(tSub).fontColor(cWeak).padding({ top: sp1, bottom: sp1 })
    } else {
      Column() {
        Row() {
          Text(`qcow2 · 虚拟 ${this.diskVirtualGB.toFixed(1)}G`).fontSize(tSub).fontColor(cSub)
          Blank()
          Text(`实占 ${this.diskActualGB.toFixed(1)}G`).fontSize(tSub).fontColor(cSub)
        }.width('100%')
        // 实占/虚拟 进度条
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(6).backgroundColor(cBlock).borderRadius(rElem)
          Row().width(`${Math.min(100, this.diskActualGB / Math.max(0.1, this.diskVirtualGB) * 100)}%`)
            .height(6).backgroundColor(cPrimary).borderRadius(rElem)
        }.width('100%').margin({ top: sp1, bottom: sp1 })
        Row({ space: sp2 }) {
          Button('信息').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cSub)
            .onClick(() => this.showDiskInfo())
          Button('扩容').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cSub)
            .onClick(() => { this.newGBText = String(Math.ceil(this.diskVirtualGB)); this.expandMode = !this.expandMode })
          Button('移除').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.confirmRemove())
        }
        if (this.expandMode) {
          Row({ space: sp2 }) {
            Text('新大小(GB)').fontSize(tSub).fontColor(cSub)
            TextInput({ text: this.newGBText }).type(InputType.Number).layoutWeight(1).fontSize(tSub)
              .onChange((v: string) => this.newGBText = v)
            Button('确定').fontSize(tSub).backgroundColor(cPrimary).fontColor(Color.White).onClick(() => this.doExpand())
            Button('取消').fontSize(tSub).backgroundColor(Color.Transparent).fontColor(cSub).onClick(() => this.expandMode = false)
          }.margin({ top: sp2 })
        }
      }
      .width('100%').padding({ top: sp1, bottom: sp2 })
    }
  }

  @Builder
  secSnapshot() {
    this.secHead('快照')
    Column() {
      Row() {
        Column({ space: 1 }) {
          Text('临时会话（启动即回滚）').fontSize(tLabel)
          Text('开机打起点快照，关机自动丢弃本次改动').fontSize(tSub).fontColor(cSub)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.tempSession })
          .onChange((v: boolean) => this.doSetTemp(v))
      }.width('100%').padding({ top: sp1, bottom: sp2 })

      // 时间线（当前显示为实心蓝点在最下）
      Column() {
        ForEach(this.snapshots, (s: VmSnapshotEntry) => {
          Row() {
            Column().width(9).height(9).borderRadius(5).backgroundColor(cCard).border({ width: 2, color: cPrimary }).margin({ right: sp2 })
            Column({ space: 1 }) {
              Text(s.name).fontSize(tLabel)
              Text(this.dateStr(s.dateSec)).fontSize(10).fontColor(cWeak)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('恢复').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cPrimary).onClick(() => this.doSnapshotApply(s))
            Button('删除').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cDanger).onClick(() => this.doSnapshotDelete(s))
          }.width('100%').padding({ top: sp1, bottom: sp1 })
        }, (s: VmSnapshotEntry) => s.id + ':' + s.name)
        Row() {
          Column().width(9).height(9).borderRadius(5).backgroundColor(cPrimary).margin({ right: sp2 })
          Column({ space: 1 }) {
            Text('当前').fontSize(tLabel)
            Text('2026-08-22 09:00').fontSize(10).fontColor(cWeak)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding({ top: sp1, bottom: sp1 })
      }
      .width('100%').padding({ left: sp2 })

      if (this.snapshots.length === 0) {
        Text(this.snapStatus()).fontSize(tSub).fontColor(cWeak).padding({ top: sp1, bottom: sp1 })
      }
    }.alignItems(HorizontalAlign.Start)
  }

  @Builder
  secNet() {
    this.secHead('网络')
    Column() {
      Row() {
        Column({ space: 1 }) {
          Text('已启用').fontSize(tLabel)
          Text(`端口转发 ${this.profile?.net.portForwards.length > 0 ? this.profile.net.portForwards : '无'} · 9p 共享${this.profile?.net.sharedFolder ? '开' : '关'}`)
            .fontSize(tSub).fontColor(cSub)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.profile?.net.enabled === true })
          .onChange((v: boolean) => { if (this.profile) { this.profile.net.enabled = v; this.saveTiny(); } })
      }.width('100%').padding({ top: sp1, bottom: sp2 })
    }.alignItems(HorizontalAlign.Start)
  }

  @Builder
  secAdvanced() {
    this.secHead('高级')
    Text('TCG 多线程 · tb-size · 自定义参数（到配置页编辑）').fontSize(tSub).fontColor(cSub).padding({ top: sp1, bottom: sp2 })
  }

  @Builder
  secHead(t: string) {
    Text(t).fontSize(11).fontColor(cWeak).fontWeight(FontWeight.Bold).letterSpacing(0.5)
      .padding({ top: sp3, bottom: sp1 }).width('100%')
  }
```

> `saveTiny()`：`if (this.profile) { new VmStore(this.filesDir).save(this.profile); this.vmListVersion++; }`，用于详情里直接改网络开关等即时保存。`showDiskInfo/doExpand/confirmRemove/doSnapshotApply/doSnapshotDelete/doSetTemp/dateStr/refreshDisk/refreshSnapshot/hasQcow/canSnapshot/snapStatus` 全部原样保留。

- [ ] **Step 2: sub-snackbar**：加一个 `@State snack: string`，`showSnack(msg)` 设值 + 2s 清空；在 `build()` 外层 `Stack` 右下角渲染。

```ts
  @State snack: string = '';

  private showSnack(msg: string): void {
    this.snack = msg;
    setTimeout(() => { if (this.snack === msg) this.snack = ''; }, 2000);
  }
```

在顶部结构外包 `Stack`：

```ts
  build() {
    Stack() {
      Column() { /* …上面整块… */ }
        .width('100%').height('100%').backgroundColor(cCard)
      if (this.snack.length > 0) {
        Row() {
          Text('✓ ').fontSize(tBody).fontColor('#ff34d399')
          Text(this.snack).fontSize(tBody).fontColor(cText)
        }
        .padding({ left: sp3, right: sp3, top: sp2, bottom: sp2 })
        .backgroundColor('#ff15181c').borderRadius(rElem)
        .position({ right: sp4, bottom: sp4 })
      }
    }
    .width('100%').height('100%')
  }
```

在各动作成功处调用 `this.showSnack(...)`（如扩容成功、创建快照、恢复到快照、删除快照、移除盘）。

- [ ] **Step 3: 编译**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`。注意 `this.profile?.net.portForwards` 的可能空值取到（`profile` 可空），用到即判断。

- [ ] **Step 4: 部署验证**

Run: `make install && make log` Expected: 无崩溃；详情侧栏选中后右侧显示分区详情。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/pages/VmManage.ets
git commit -m "UI(3/6) 管理页分区重组 + 快照时间线 + 右下角 snackbar"
```

---

## Task 4: `VmWizard` 改居中模态 + 磁贴模板选择 + 步骤条

**Files:**
- Modify: `entry/src/main/ets/pages/VmWizard.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`（页面映射里 wizard 不再作为 navDestination）

思想：工坊不再 `pushPath` 进 NavDestination，而是主窗口 `Navigation` content 上 `bindContentCover` 弹出（遮罩 + 居中卡片）。模板选择与工坊共用一个模态容器：首次进入若无模板则先弹磁贴网格，点磁贴预填。步骤条从胶囊改成"编号圆点+分隔线"。

- [ ] **Step 1: 磁贴模板 builder（复用 OS_TEMPLATES）**

```ts
  @Builder
  templateTiles() {
    Column() {
      Row() { Text('新建虚拟机').fontSize(tPage).fontWeight(FontWeight.Bold); Blank(); Button('×').backgroundColor(Color.Transparent).fontColor(cWeak).onClick(() => this.showCover = false) }
        .width('100%').padding({ left: sp4, right: sp4, top: sp3, bottom: sp3 })
      // 磁贴网格
      Row() {
        ForEach(OS_TEMPLATES, (t: OsTemplate) => {
          Column() {
            Text(t.icon ?? '💿').fontSize(20)
            Text(t.name).fontSize(tCard).fontWeight(FontWeight.Medium).margin({ top: sp1 })
            Text(`${t.arch}`).fontSize(10).fontColor(cSub).fontFamily('monospace')
            Text(t.imageNeeded ? '需自备' : '内置镜像').fontSize(10)
              .fontColor(t.imageNeeded ? cWarn : cRunning)
          }
          .layoutWeight(1).padding(sp3)
          .backgroundColor(cCard).borderRadius(rCard)
          .border({ width: bw, color: cBorder })
          .margin({ right: sp2 })
          .onClick(() => { this.loadTemplate(t); this.showTiles = false; this.showCover = true; })
        }, (t: OsTemplate) => t.id)
      }
      .width('100%')
      Row() {
        Text('都不合适？').fontSize(tSub).fontColor(cSub)
        Blank()
        Button('从零开始（手工向导）').fontSize(tBody).backgroundColor(Color.Transparent).fontColor(cPrimary)
          .onClick(() => { this.showTiles = false; this.showCover = true; })
      }.width('100%').padding({ left: sp4, right: sp4, top: sp3, bottom: sp4 })
    }
    .width('100%').backgroundColor(cCard).borderRadius(rCard)
  }
```

> `OsTemplate` 需在 `osTemplates.ets` 加 `icon?: string` 字段（🐧/🤖/💾/⚙️），否则用默认 `'💿'`。为降低侵入，可在模板定义里补 `icon`。

- [ ] **Step 2: `VmWizard` 加 `onClose`，`VmList` 用遮罩浮层承载模态（唯一方案）**

不依赖 `bindContentCover`（规避 API 边界差异）。`VmWizard` 保留 `@Component`，新增 `onClose` 回调成员；`VmList` 用自己的 `Stack` + 全屏遮罩浮层承载。

`VmWizard.ets` 头部（其余 state 不变）：

```ts
@Component
export struct VmWizard {
  param: WizardParam = { mode: 'new' };        /* 普通成员，非响应式，够用 */
  onClose: (() => void) | null = null;          /* 完成/取消时回调给宿主 */
  @Consume('navStack') navStack: NavPathStack;
  // …其余 @State 不变
```

`finish()` 把 `this.navStack.pop()` 改为回调宿主关闭：

```ts
  private finish(): void {
    const id = this.isEdit() ? (this.param.profile as VmProfile).id : newProfileId();
    const p = this.assemble(id);
    if (this.diskEnabled && p.media.diskPath.length > 0) {
      if (!fs.accessSync(p.media.diskPath)) {
        const ret = napi.createDisk(p.media.diskPath, Math.round(this.diskGB * 1024), this.diskAlloc);
        if (ret !== 0) { promptAction.showToast({ message: '创建磁盘失败' }); return; }
      }
    }
    new VmStore(this.filesDir).save(p);
    this.vmListVersion++;
    promptAction.showToast({ message: `已保存「${p.name}」` });
    if (this.onClose) { this.onClose(); }
  }
```

`取消/上一步` 也走 `onClose`（取消）与 `step--`（上一步），取消处：`if (this.onClose) { this.onClose(); }` 替代 `this.navStack.pop()`。

`VmList.ets` 挂载（新建入口统一走遮蔽模态；编辑稍后并入）：

```ts
  @State showWizard: boolean = false;
  @State wizardParam: WizardParam = { mode: 'new' };

  private openWizard(tpl: OsTemplate | null): void {
    this.wizardParam = tpl ? { mode: 'new', template: tpl } : { mode: 'new' };
    this.showWizard = true;
  }

  private closeWizard(): void {
    this.showWizard = false;
    this.vmListVersion++;
  }

  @Builder
  wizardCover() {
    VmWizard({ param: this.wizardParam, onClose: () => this.closeWizard() })
  }

  build() {
    Stack() {
      Column() {
        /* …侧栏整块（原 build 内容）… */
      }
      .width('100%').height('100%')

      if (this.showWizard) {
        Row() {
          Column() {
            this.wizardCover()
          }
          .width(720).height('100%').maxHeight(660)
          .backgroundColor(cCard).borderRadius(rCard)
        }
        .width('100%').height('100%')
        .backgroundColor('#52000000')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%')
  }
```

> 侧栏「＋ 新建」按钮 onClick 改为 `this.openWizard(null)`；模板磁贴（Task 4 Step 1）点选后调 `openWizard(t)`。`openWizardNew/openWizardEdit` 原方法删除或内部改写为 `openWizard(...)`。

- [ ] **Step 3: 步骤条改编号圆点 + 分隔线**

```ts
  @Builder
  stepHeader() {
    Row({ space: 4 }) {
      ForEach(STEPS, (s: string, i: number) => {
        Row({ space: 6 }) {
          // 圆点
          Text(String(i + 1)).fontSize(10).fontColor(this.step === i ? Color.White : cSub)
            .width(20).height(20).textAlign(TextAlign.Center)
            .backgroundColor(this.step === i ? cPrimary : Color.Transparent)
            .border({ width: bw, color: this.step === i ? cPrimary : cBorder })
            .borderRadius(10)
          Text(s).fontSize(10).fontColor(this.step === i ? cPrimary : cWeak)
        }
        .layoutWeight(1)
        .onClick(() => this.step = i)
        .justifyContent(FlexAlign.Center)
      }, (s: string) => s)
      /* 每个点之间是 layoutWeight(1) 均匀分布；若要"分隔线"可在 ForEach 里先输出点后输出短线（用弹窗内 Row），
         但此处用点+文字平均分布已足。 */
    }
    .width('100%').padding({ left: sp2, right: sp2 })
  }
```

- [ ] **Step 4: 编译**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`，无 `bindContentCover` 相关误用。

- [ ] **Step 5: 部署验证**

Run: `make install && make log`
Expected: 点「＋ 新建」→ 遮罩弹出磁贴模板或工坊；上一步/下一步可走；无崩溃。

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/pages/VmWizard.ets entry/src/main/ets/pages/VmList.ets entry/src/main/ets/lib/osTemplates.ets entry/src/main/ets/pages/Index.ets
git commit -m "UI(4/6) 机器工坊改居中模态 + 磁贴模板选择 + 编号圆点步骤条"
```

---

## Task 5: `VmEdit` / `StorageOverview` / `VmConsole` 配色换 token（纯替换，无行为变化）

**Files:**
- Modify: `entry/src/main/ets/pages/VmEdit.ets`
- Modify: `entry/src/main/ets/pages/StorageOverview.ets`
- Modify: `entry/src/main/ets/pages/VmConsole.ets`

思想：只把散落的色值换成 token 常量，不改布局/逻辑。

- [ ] **Step 1: 逐页替换**

把这三页里出现的色值替换为 token（在文件头 import）：
- `#ff007dff` → `cPrimary`（主操作/文字色）。
- `#ff2e7d32` → `cRunning`（成功/运行）。
- `#ff9900` / `#ffb25e09` → `cWarn`。
- `#ff666666` → `cSub`（次级文本）。
- `#ff999999` → `cWeak`（弱文本/占位）。
- `#fff2f3f5` → `cBg`（页面背景）。
- `#11000000` → 保留，可改 `cBorder`（分隔线）。
- `Color.Red` → `cDanger`（危险）。
- 保持 `Color.White`（文字反色）不变。

`VmConsole` 其余为黑底面（`#99000000`/`#cc000000`/`Color.Black`），属屏幕区域，保持；仅把顶部工具条文字状态色 `#34d399` → 保留（running 绿），`#ff99ccff` 保留。

- [ ] **Step 2: 编译**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`。

- [ ] **Step 3: 部署验证**

Run: `make install && make log`
Expected: 无崩溃；各页仍可用（外观变化，颜色统一）。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/pages/VmEdit.ets entry/src/main/ets/pages/StorageOverview.ets entry/src/main/ets/pages/VmConsole.ets
git commit -m "UI(5/6) 编辑/存储/控制台配色换 token"
```

---

## Task 6: 空态 + 全局硬编码颜色清零 + 全量回归

**Files:**
- Modify: `entry/src/main/ets/pages/VmList.ets`（空态已含）
- Modify: 依赖文件里仍残留的硬编码色值（grep 清零）

- [ ] **Step 1: 清残留硬编码**

Run: `cd entry/src/main/ets && grep -rIn "#ff[0-9a-fA-F]\{6\}\|Color.Red" pages lib | grep -v "uiTokens\|RawFile\|#000\|#ffffff\|#fff"`
Expected: 输出为空或仅剩合理黑/白（屏幕类）。剩余项逐一替换成 token（`VGA`/`Color.White` 反色除外）。

- [ ] **Step 2: 全量回归验证**

```bash
make hap && make install && make log
```
Run the first two commands and `make log` for crash detection.
Expected: `BUILD SUCCESSFUL`；进程起；`make log` 无 `CRASH`/`SIGSEGV`/`FATAL`。

- [ ] **Step 3: 设备人工回归清单**

- 「＋ 新建」→ 磁贴模板 → 工坊走完六步 → 保存 + 建盘。
- 侧栏选中一台 → 右侧详情分区/快照时间线/网络/高级；扩容/恢复/移除带 snackbar。
- 搜索过滤；无 VM 空态；运行/已停汇总 pill。
- 各页配色统一（无残留示例蓝）。

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "UI(6/6) 空态 + 硬编码颜色清零 + 全量回归"
```

---

## 自检

- **Spec 覆盖**：spec 第 3 节 token → Task 1；第 4.1 主窗口 → Task 2；4.2 详情/时间线 → Task 3；4.3 工坊模态 + 4.4 磁贴模板 → Task 4；4.5 snackbar → Task 3；4.6 配色 → Task 5；空态/清零 → Task 6。✓
- **一致性**：token 命名贯穿（`cPrimary/cSub/cWeak/cBg/cCard/cBorder/cBlock/cSel/cSelBg/cRunning/cWarn/cDanger`，`tPage/tCard/tLabel/tBody/tSub`，`sp1..sp5`，`rCard/rElem/rBadge`，`bw`）。`VmProfile` 字段（`machine.arch/vga/machine/firmware/cpuModel.runtime.memoryMB/cpus.net.portForwards/sharedFolder.media.diskPath/cdromPath`）与现有实现一致。`VmStore.load/save`、`snapshotCreate/Apply/Delete`、`parseSnapshots`、`vmIsRunning`、`openConsole` 沿用现有签名。✓
- **ArkTS 注意**：不依赖 `delete`/`any`/`unknown`；颜色常量裸 const；`${x}%` 用于 width 需注意 ArkTS 允许字符串化，若报错则改用 `(w).toString()+'%'`。

## 执行交接

计划已保存。两种执行方式：

1. **Subagent-Driven（推荐）**——每个 Task 派一个新 subagent，任务间我复核，快速迭代。
2. **Inline Execution**——在本会话用 executing-plans 分批执行 + 检查点复核。

选哪种？（另：以上 Token 的 UI 组件样式基于 ArkUI 常规写法，devicе 编译若对个别 API（如 `NavigationMode.Auto`、`InputType.Number`、`letterSpacing`、`.position()`）报不支持，按 SDK 文档微调即可，不影响整体拆分。）
