# VM 配置页/详情页 UI 重构实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让详情页字段全只读、配置页按四分组归类、删除配置里的「显卡」项、存储弹窗光盘清除后可重新添加。

**Architecture:** 纯 ArkTS/ArkUI 组件改动，只改三个页面文件（`VmManage` / `VmEdit` / `VmStorage`）；数据模型 `vmprofile.ts` 不动（`machine.vga` 字段保留，只是 UI 不再暴露）。组头统一复用向导 `groupHeader` 样式（灰字 + 延伸线）。

**Tech Stack:** HarmonyOS ArkTS / ArkUI 组件；`hvigorw assembleHap` 编译；`hdc` 部署到 `192.168.1.4:44959` 人工验证。

**验证门禁说明：** 本项目无 ArkUI 组件单测框架（无 `ohosTest` / `*.test.ets`），无法 TDD。每个任务以 `make hap` 编译通过为硬门禁，最终用 `make deploy` 部署到设备做人工验证（见各任务「设备验证」与文末汇总）。

---

### Task 1: 详情页 `VmManage` — 概览独立分区 + 网络节只读化

**Files:**
- Modify: `entry/src/main/ets/pages/VmManage.ets`

改动目标：
1. 概览（内存/核/pc/seabios）从「无标题 chips 行」改为**独立分区**（`secHead('概览')` + 一排胶囊 chips），去掉 `vga` 胶囊与 `vgaLabel()`。
2. 网络节 `Toggle` 从可编辑改为**只读**（`.enabled(false)` 灰开关 + 状态文案 `已启用/已关闭`），删除 `onChange` 写库逻辑与 `saveTiny()`。

- [ ] **Step 1: 概览独立分区（删 vgaLabel helper + 重排 build 的 chips）**

删除 `vgaLabel()` helper（现文件约 line 363-365）：

```ts
  private vgaLabel(): string {
    return this.profile ? this.profile.machine.vga : '';
  }
```

在 build 中把「概览 chips 一行」块（现文件约 line 575-595）替换为独立分区：

替换前：

```ts
            /* 概览 chips 一行 */
            Row({ space: sp2 }) {
              if (this.memLabel().length > 0) {
                Text(this.memLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.cpuLabel().length > 0) {
                Text(this.cpuLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.firmwareLabel().length > 0) {
                Text(this.firmwareLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.vgaLabel().length > 0) {
                Text(this.vgaLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
            }
            .width('100%')
            .padding({ top: sp2, bottom: sp2 })

            this.secStorage()
```

替换后：

```ts
            this.secHead('概览')
            /* 概览胶囊一排（内存/核/机型/固件；无 vga） */
            Row({ space: sp2 }) {
              if (this.memLabel().length > 0) {
                Text(this.memLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.cpuLabel().length > 0) {
                Text(this.cpuLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.boardLabel().length > 0) {
                Text(this.boardLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
              if (this.firmwareLabel().length > 0) {
                Text(this.firmwareLabel()).fontSize(tSubL).fontColor(cSub).backgroundColor(cChip).borderRadius(rBadge)
                  .padding({ left: sp2, right: sp2, top: sp1, bottom: sp1 })
              }
            }
            .width('100%')
            .padding({ top: sp1, bottom: sp2 })

            this.secStorage()
```

（`boardLabel()` 已存在，`secHead` 已存在，无需新增。）

- [ ] **Step 2: 网络节只读化（替换 secNet + 删 saveTiny）**

替换 `secNet()`（现约 line 448-468）：

替换前：

```ts
  @Builder
  secNet() {
    this.secHead('网络')
    Column() {
      Row() {
        Column({ space: 1 }) {
          Text('已启用').fontSize(tLabel)
          Text(`端口转发 ${(this.profile && this.profile.net.portForwards.length > 0) ? this.profile.net.portForwards : '无'} · 9p 共享${(this.profile && this.profile.net.sharedFolder) ? '开' : '关'}`)
            .fontSize(tSubL).fontColor(cSub)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
          .onChange((v: boolean) => {
            this.netEnabled = v;
            if (this.profile) {
              this.profile.net.enabled = v;
              this.saveTiny();
            }
          })
      }.width('100%').padding({ top: sp1, bottom: sp2 })
    }.alignItems(HorizontalAlign.Start)
  }
```

替换后：

```ts
  @Builder
  secNet() {
    this.secHead('网络')
    Column() {
      Row() {
        Column({ space: 1 }) {
          Text(this.netEnabled ? '已启用' : '已关闭').fontSize(tLabel)
          Text(`端口转发 ${(this.profile && this.profile.net.portForwards.length > 0) ? this.profile.net.portForwards : '无'} · 9p 共享${(this.profile && this.profile.net.sharedFolder) ? '开' : '关'}`)
            .fontSize(tSubL).fontColor(cSub)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.netEnabled }).enabled(false)
      }.width('100%').padding({ top: sp1, bottom: sp2 })
    }.alignItems(HorizontalAlign.Start)
  }
```

删除 `saveTiny()` 方法（现约 line 491-496，已无调用方）：

```ts
  private saveTiny(): void {
    if (this.profile) {
      new VmStore(this.filesDir).save(this.profile);
      this.vmListVersion++;
    }
  }
```

- [ ] **Step 3: 编译验证**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`，无 `vgaLabel` / `saveTiny` 残留引用。

- [ ] **Step 4: 提交**

```bash
git add entry/src/main/ets/pages/VmManage.ets
git commit -m "refactor(详情页): 概览改独立分区胶囊(去vga)、网络节Toggle改只读灰开关"
```

---

### Task 2: 配置页 `VmEdit` — 删除「显卡」

**Files:**
- Modify: `entry/src/main/ets/pages/VmEdit.ets`

改动目标：移除配置里的「显卡 std/virtio」（创建向导从不暴露，统一 `std`）；`machine.vga` 字段保留，保存时写回原值。

- [ ] **Step 1: 删常量与状态（VGA_OPTIONS / @State vga / import VgaType）**

删除常量（现约 line 17）：

```ts
const VGA_OPTIONS: VgaType[] = ['std', 'virtio'];
```

删除状态（现约 line 37）：

```ts
  @State vga: VgaType = 'std';
```

删除 `aboutToAppear()` 里的赋值（现约 line 64）：

```ts
    this.vga = p.machine.vga;
```

删除 import 中的 `VgaType`（现 line 6）。替换前：

```ts
import { VmProfile, VmStore, VmArch, VgaType, SCHEMA_VERSION, fitBoard, builtinIsoFor } from '../lib/vmprofile';
```

替换后：

```ts
import { VmProfile, VmStore, VmArch, SCHEMA_VERSION, fitBoard, builtinIsoFor } from '../lib/vmprofile';
```

- [ ] **Step 2: save() 写回 machine.vga 原值**

替换 `save()` 里的 `vga: this.vga,`（现约 line 136）。替换前：

```ts
        vga: this.vga,
```

替换后：

```ts
        vga: this.profile.machine.vga,
```

- [ ] **Step 3: 删除「显卡」ListItem**

替换前（现约 line 301-315）：

```ts
        ListItem() {
          Row() {
            Text('显卡').fontSize(tLabel).width(72)
            Select(VGA_OPTIONS.map((v: VgaType): SelectOption => {
              return { value: v };
            }))
              .value(this.vga)
              .selected(VGA_OPTIONS.indexOf(this.vga))
              .font({ size: tBody })
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).layoutWeight(1)
              .onSelect((index: number) => {
                this.vga = VGA_OPTIONS[index];
              })
          }.padding(spCard)
        }
```

替换后（整段删除，相邻 ListItem 直接相接——上接「从光盘启动」ListItem、下接「网络」ListItem）：

```ts
```

- [ ] **Step 4: 编译验证**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`，无 `VGA_OPTIONS` / `this.vga` / `VgaType` 残留引用。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/pages/VmEdit.ets
git commit -m "refactor(配置页): 删除「显卡」选项(创建向导从不提供，machine.vga 保存保留原值)"
```

---

### Task 3: 配置页 `VmEdit` — 四分组重排

**Files:**
- Modify: `entry/src/main/ets/pages/VmEdit.ets`

改动目标：把平铺 `List` 重排为 `Scroll + Column` 四分组（基础/存储/网络/高级），组头灰字+延伸线；高级组头即折叠开关。**必须在 Task 2 之后执行**（已删显卡）。

- [ ] **Step 1: import 加 sp3/sp5；新增 groupHead / groupHeadAdvanced builder**

import 现在（line 8）末尾为 `...sp1, sp2, sp8, spCard }`，加 `sp3, sp5`。替换前：

```ts
inpH, inpBg, inpRadius, inpPadX, sp1, sp2, sp8, spCard } from '../lib/uiTokens';
```

替换后：

```ts
inpH, inpBg, inpRadius, inpPadX, sp1, sp2, sp3, sp5, sp8, spCard } from '../lib/uiTokens';
```

新增两个 builder（放在类内、`save()` 之后）：

```ts
  /* 分组标题 + 分割线（与 VmWizard groupHeader / VmManage secHead 同款：灰字在左，细线延伸至右） */
  @Builder
  groupHead(label: string) {
    Row({ space: sp8 }) {
      Text(label).fontSize(tLabel).fontColor(cSub)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp1 })
  }

  /* 高级折叠组头：点击展开/收起（原「▼ 高级选项」ListItem 改为组头即开关） */
  @Builder
  groupHeadAdvanced() {
    Row({ space: sp8 }) {
      Text('高级').fontSize(tLabel).fontColor(cSub)
      Text(this.showAdvanced ? ' ▾ 收起' : ' ▸ 展开').fontSize(tSub).fontColor(cWeak)
      Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: sp2, bottom: sp1 })
    .onClick(() => this.showAdvanced = !this.showAdvanced)
  }
```

- [ ] **Step 2: 用新 build() 替换整个 build() 方法**

把 `build()` 整体（现约 line 167-397）替换为：

```ts
  build() {
    Column() {
      Row() {
        Button('取消').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .backgroundColor(Color.Transparent)
          .fontColor(cPrimary)
          .onClick(() => this.navStack.pop())
        Blank()
        Text('虚拟机配置').fontSize(tPage).fontWeight(FontWeight.Medium)
        Blank()
        Button('保存').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
          .backgroundColor(Color.Transparent)
          .fontColor(cPrimary)
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: sp8, right: sp8, top: sp8, bottom: sp8 })

      Scroll() {
        Column() {
          /* —— 基础 —— */
          this.groupHead('基础')

          Row() {
            Text('名称').fontSize(tLabel).width(72)
            TextInput({ text: this.name })
              .layoutWeight(1)
              .fontSize(tBody)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
              .onChange((v: string) => this.name = v)
          }.padding(spCard)

          Row() {
            Text('架构').fontSize(tLabel).width(72)
            Text(this.arch)
              .fontSize(tBody)
              .fontColor(cSub)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).layoutWeight(1)
              .padding({ left: inpPadX, right: inpPadX })
              .textAlign(TextAlign.Start)
          }.padding(spCard)

          Row({ space: 4 }) {
            Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(tLabel)
              .width(120)
            Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
              .onChange((v: number) => this.cpus = v)
              .layoutWeight(1)
          }.alignItems(VerticalAlign.Center).padding(spCard)

          Row() {
            Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(tLabel)
              .width(120)
            Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
              .onChange((v: number) => this.memoryMB = v)
              .layoutWeight(1)
          }.alignItems(VerticalAlign.Center).padding(spCard)

          /* —— 存储 —— */
          this.groupHead('存储')

          Column({ space: sp1 }) {
            Row() {
              Text('系统盘').fontSize(tLabel).width(72)
              Column({ space: 2 }) {
                Text(this.baseName(this.diskPath))
                  .fontSize(tSub)
                  .fontColor(cSub)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`)
                  .fontSize(tMono)
                  .fontColor(cWeak)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('存储管理').focusable(false).fontSize(tBody)
                .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                .backgroundColor(Color.Transparent).fontColor(cPrimary)
                .onClick(() => {
                  const p = this.profile;
                  if (p) {
                    this.storageParam = p;
                    this.showStorage = true;
                  }
                })
            }
          }.alignItems(HorizontalAlign.Start).padding(spCard)

          Column({ space: sp1 }) {
            Row() {
              Text('光盘 ISO').fontSize(tLabel).width(72)
              Text(this.cdromPath ? this.baseName(this.cdromPath) : '无')
                .fontSize(tSub)
                .fontColor(cSub)
                .layoutWeight(1)
              if (this.cdromPath) {
                Button('移除').focusable(false).fontSize(tBody)
                  .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                  .backgroundColor(Color.Transparent).fontColor(cDanger)
                  .onClick(() => this.cdromPath = '')
              }
            }
            if (!this.cdromPath) {
              Row({ space: sp8 }) {
                TextInput({ placeholder: 'ISO 完整路径', text: this.cdromPath })
                  .layoutWeight(1)
                  .fontSize(tBody)
                  .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                  .onChange((v: string) => this.cdromPath = v)
                Button(this.ensureIsoLoading ? `下载 ${this.isoPct}%` : `内置 Alpine (${this.arch})`)
                  .focusable(false).fontSize(tBody)
                  .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
                  .enabled(!this.ensureIsoLoading)
                  .onClick(() => this.pickBuiltinIso())
              }
            }
          }.alignItems(HorizontalAlign.Start).padding(spCard)

          Row() {
            Text('从光盘启动').fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
              .onChange((v: boolean) => this.bootFromCdrom = v)
          }.padding(spCard)

          /* —— 网络 —— */
          this.groupHead('网络')

          Row() {
            Text('启用网络').fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
              .onChange((v: boolean) => this.netEnabled = v)
          }.padding(spCard)

          if (this.netEnabled) {
            Column({ space: 4 }) {
              Text('端口映射').fontSize(tLabel)
              Text('宿主端口:客机端口，逗号分隔').fontSize(tSub).fontColor(cWeak)
              TextInput({ placeholder: '如 2222:22,8080:80', text: this.portForwards })
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.portForwards = v)
            }.alignItems(HorizontalAlign.Start).padding(spCard)
            Column({ space: 4 }) {
              Row() {
                Text('共享目录').fontSize(tLabel).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.sharedFolder })
                  .onChange((v: boolean) => this.sharedFolder = v)
              }.padding({ left: 0, right: 0 })
              Text('挂载宿主 Download/ 到客机 /shared（9p）').fontSize(tSub).fontColor(cWeak)
            }.alignItems(HorizontalAlign.Start).padding(spCard)
          }

          /* —— 高级（折叠组头） —— */
          this.groupHeadAdvanced()
          if (this.showAdvanced) {
            Row() {
              Text('TCG 多线程 (MTTCG)').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.mttcg })
                .onChange((v: boolean) => this.mttcg = v)
            }.padding(spCard)
            Row() {
              Text('tb-size').fontSize(tLabel).width(96)
              TextInput({ text: this.tbSizeText })
                .layoutWeight(1)
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.tbSizeText = v)
            }.padding({ left: spCard, right: spCard, bottom: spCard })
            Column({ space: 4 }) {
              Text('自定义 QEMU 参数').fontSize(tLabel)
              Text('追加到命令行末尾').fontSize(tSub).fontColor(cWeak)
              TextArea({ placeholder: '如 -device usb-kbd', text: this.extraArgs })
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.extraArgs = v)
            }.alignItems(HorizontalAlign.Start).padding(spCard)
          }
        }
        .width('100%')
        .padding({ left: sp3, right: sp3, bottom: sp5 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cBg)
  }
```

（注：原 `List` 的 `.divider()` 与 `.backgroundColor(Color.White)` 一并移除；外层 `Column` 背景 `cBg` 保留。）

- [ ] **Step 3: 编译验证**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`；四分组渲染，无 ListItem 残留（原 List 内内容已全部迁入分组）。

- [ ] **Step 4: 提交**

```bash
git add entry/src/main/ets/pages/VmEdit.ets
git commit -m "refactor(配置页): 平铺List改四分组(基础/存储/网络/高级)，组头灰字+延伸线，高级组头即折叠开关"
```

---

### Task 4: 存储弹窗 `VmStorage` — 光盘可重新添加

**Files:**
- Modify: `entry/src/main/ets/pages/VmStorage.ets`

改动目标：`secCdrom` 无引用光驱时提供「＋ 选择 ISO」入口，展开可输入完整路径或点「内置 Alpine (arch)」重新挂载；修复清除后无法加回的死路。

- [ ] **Step 1: 头文件 import 与状态**

**1a. 加 `common` import**（替换前）：

```ts
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
```

（替换后）：

```ts
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
```

**1b. vmprofile 与 isoDl import**（替换前）：

```ts
import { VmProfile, VmStore } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import { snapshotCreate } from '../lib/vmsnapshot';
```

（替换后）：

```ts
import { VmProfile, VmStore, builtinIsoFor } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';
import { snapshotCreate } from '../lib/vmsnapshot';
import { ensureBuiltinIso } from '../lib/isoDl';
```

**1c. 状态与 StorageLink 增加**（在 `@State cdromPath: string = '';` 附近、`@State snack` 之前插入）：

```ts
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @State isoPickMode: boolean = false;    /* 「选择 ISO」面板展开 */
  @State isoPathText: string = '';        /* 完整路径输入 */
  @State ensureIsoLoading: boolean = false; /* 内置 Alpine 下载中 */
  @State isoPct: number = 0;
```

- [ ] **Step 2: 新增 pickBuiltinIso / applyIsoPath 方法**

在 `clearCdrom()` 之后新增两个方法：

```ts
  /* 「内置 Alpine」按钮：按当前架构确保内置 iso 就绪（缺失则按需下载），完成后挂到光驱 */
  private pickBuiltinIso(): void {
    const name = builtinIsoFor(this.arch);
    if (name.length === 0) {
      promptAction.showToast({ message: '该架构无内置 ISO' });
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    this.ensureIsoLoading = true;
    this.isoPct = 0;
    ensureBuiltinIso(ctx, this.vmDataDir, this.arch, (pct: number) => {
      this.isoPct = pct;
    }).then((ok: boolean) => {
      this.ensureIsoLoading = false;
      if (ok) {
        const p = this.profile;
        if (!p) {
          return;
        }
        this.cdromPath = this.vmDataDir + '/' + name;
        p.media.cdromPath = this.cdromPath;
        p.media.bootFromCdrom = true;
        new VmStore(this.filesDir).save(p);
        this.isoPickMode = false;
        this.isoPathText = '';
        this.vmListVersion++;
        this.showSnack('已挂载内置 ISO');
      } else {
        promptAction.showToast({ message: '内置 ISO 下载失败' });
      }
    });
  }

  /* 用「完整路径」挂载光盘：保存到 profile（不强制改 bootFromCdrom） */
  private applyIsoPath(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    const path = this.isoPathText.trim();
    if (path.length === 0) {
      promptAction.showToast({ message: '请输入 ISO 路径' });
      return;
    }
    p.media.cdromPath = path;
    new VmStore(this.filesDir).save(p);
    this.cdromPath = path;
    this.isoPickMode = false;
    this.isoPathText = '';
    this.vmListVersion++;
    this.showSnack('已挂载光盘');
  }
```

- [ ] **Step 3: 替换 secCdrom**

替换前（现约 line 316-332）：

```ts
  /* 光盘 ISO：该 VM 的启动镜像引用（只读展示，可清引用） */
  @Builder
  secCdrom() {
    this.secHead('光盘 ISO')
    Column() {
      Row() {
        Text(this.cdromPath ? this.baseName(this.cdromPath) : '未引用光盘')
          .fontSize(tSub).fontColor(this.cdromPath ? cSub : cWeak).layoutWeight(1)
        if (this.cdromPath.length > 0) {
          Button('清除').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.clearCdrom())
        }
      }.width('100%').padding({ top: sp1, bottom: sp2 })
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
```

替换后：

```ts
  /* 光盘 ISO：该 VM 的启动镜像引用（可清引用；无引用时提供「选择 ISO」重新添加） */
  @Builder
  secCdrom() {
    this.secHead('光盘 ISO')
    Column() {
      if (this.cdromPath.length > 0) {
        Row() {
          Text(this.baseName(this.cdromPath)).fontSize(tSub).fontColor(cSub).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('清除').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.clearCdrom())
        }.width('100%').padding({ top: sp1, bottom: sp2 })
      } else if (!this.isoPickMode) {
        Row() {
          Text('未引用光盘').fontSize(tSub).fontColor(cWeak).layoutWeight(1).padding({ top: sp1, bottom: sp2 })
          Button('＋ 选择 ISO').focusable(false).fontSize(tBody)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
            .backgroundColor(Color.Transparent).fontColor(cPrimary)
            .border({ width: 1, color: cBorder, style: BorderStyle.Dashed })
            .onClick(() => this.isoPickMode = true)
        }.width('100%').padding({ top: sp1, bottom: sp2 })
      } else {
        Column({ space: sp1 }) {
          Row() {
            TextInput({ placeholder: 'ISO 完整路径', text: this.isoPathText })
              .layoutWeight(1).fontSize(tBody)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
              .onChange((v: string) => this.isoPathText = v)
            Button('取消').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cSub)
              .onClick(() => {
                this.isoPickMode = false;
                this.isoPathText = '';
              })
          }.width('100%')
          Row({ space: sp2 }) {
            Button(this.ensureIsoLoading ? `下载 ${this.isoPct}%` : `内置 Alpine (${this.arch})`)
              .focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .enabled(!this.ensureIsoLoading)
              .backgroundColor(Color.Transparent).fontColor(cPrimary)
              .onClick(() => this.pickBuiltinIso())
            Button('确定路径').focusable(false).fontSize(tBody)
              .height(btnSh).borderRadius(rBtn).padding({ left: sp2, right: sp2 })
              .backgroundColor(Color.Transparent).fontColor(cPrimary)
              .onClick(() => this.applyIsoPath())
          }.width('100%').padding({ top: sp1 })
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: sp1, bottom: sp2 })
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
```

- [ ] **Step 4: 编译验证**

Run: `make hap`
Expected: `BUILD SUCCESSFUL`；`builtinIsoFor` / `ensureBuiltinIso` / `common` / `vmDataDir` / `BorderStyle` 引用无误。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/pages/VmStorage.ets
git commit -m "feat(存储弹窗): 光盘区加「选择ISO」入口，清除后可重新挂载(内置Alpine/完整路径)"
```

---

## 设备验证清单（`make deploy` 后人工确认）

> 需先 `hdc tconn 192.168.1.4:44959`。测试目标 VM 假设为「我的虚拟机」(x86_64)。

1. **详情页（VmManage）**
   - 概览为独立分区 + 胶囊（内存/核/pc/seabios），无 vga 胶囊。
   - 网络节为只读灰开关 + 「已启用/已关闭」，点不动、无 toast、不触发写盘（重启 app 后网络状态不变）。
2. **配置页（VmEdit）**
   - 四分组：基础 / 存储 / 网络 / 高级，组头灰字+延伸线清晰。
   - 无明显「显卡」项。
   - 高级组头点击展开/收起出（TCG多线程/tb-size/自定义QEMU参数）。
   - 改名称→保存，返回详情页名称已更新。
3. **存储弹窗（VmStorage）**
   - 系统盘区（扩容/重建/快照）原样可用。
   - 有光盘引用时显示文件名 + 清除；点清除后出现「未引用光盘 + ＋选择 ISO」。
   - 点「＋选择 ISO」展开：可输入路径→「确定路径」挂载成功；或点「内置 Alpine (x86_64)」下载并挂载。
   - 返回详情页光盘区显示新挂载的 ISO 名，启动徽标（若 bootFromCdrom）正确。

## 后续

- 若实现过程需回看 spec：`docs/superpowers/specs/2026-08-29-vm-config-detail-ui-redesign-design.md`
