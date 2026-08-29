# VM 配置页/详情页 UI 重构设计

> 状态：已与用户对齐（mockup 已批准），待写实现计划
> 日期：2026-08-29
> 范围：`VmManage`（详情页）/ `VmEdit`（配置页）/ `VmStorage`（存储弹窗）

## 背景与问题

现状四个问题（用户反馈）：

1. **详情页并非全只读**：网络节的 `Toggle` 可直接改 `net.enabled` 并立即保存，与「详情只读」的产品预期不符。
2. **配置页字段未归类**：`VmEdit` 是平铺的一条 `List`，名称/架构/CPU/内存/系统盘/光盘/显卡/网络/高级全部摊在一起，无分组层次。
3. **配置里有创建时没有的选项**：`显卡 (std/virtio)` 在详情/配置页出现，但创建向导从不暴露（固定 `std`），属于冗余选项。
4. **存储弹窗光盘清除后无法加回**：`secCdrom` 只有「清除」，清掉 `cdromPath` 后没有再添加的路径——死路。

## 设计目标

- 详情页字段**全只读**，操作钮（启动/进入/编辑/删除/存储管理/恢复/删除/复制）保留。
- 配置页按 **基础 / 存储 / 网络 / 高级** 四分组，组头灰字+延伸线，与向导 `groupHeader` 同款。
- **删除「显卡」**，统一跟随 `std` 默认（数据模型字段 `machine.vga` 保留，不破坏旧数据）。
- 存储弹窗光盘区加 **「选择 ISO」** 入口，清除后可直接重新添加。

## 改动概览（三个界面）

### ① 详情页 `VmManage`

- **概览**：从「无标题的 chips 行」改为**独立分区**（`secHead('概览')` + 一排胶囊 chips）。
  - 胶囊内容：`内存 1G` / `核 2` / `pc`(machine) / `seabios`(firmware)。
  - **去掉 vga 胶囊**与 `vgaLabel()` helper。
- **网络**：`Toggle` 改为**只读**：`.enabled(false)` 的灰色开关 + 左侧状态文本动态显示 `已启用`/`已关闭`。
  - 删除网络节里 `onChange` 的写库逻辑与 `saveTiny()`（改网络开关统一去配置页）。
- 其余分区（存储 / 快照 / 高级）**不变**，动作按钮全保留。

### ② 配置页 `VmEdit`

把平铺 `List` 重排为四分组（`Scroll + Column`，去掉整页 `.divider()`，改用组头自带分隔线；每行仍 `padding(spCard)`）：

- **基础**：名称 / 架构 / CPU 核数 / 内存
- **存储**：系统盘（+存储管理按钮）/ 光盘 ISO（+移除 / 内置 Alpine / 路径输入）/ 从光盘启动
- **网络**：启用网络 / 端口映射(条件) / 共享目录(条件)
- **高级**（折叠组头）：TCG 多线程 / tb-size / 自定义 QEMU 参数

**删除**：
- `显卡` ListItem、`@State vga`、`VGA_OPTIONS` 常量、对应 `Select`。
- `save()` 里 `vga: this.vga` 改为 `vga: this.profile.machine.vga`（保留原值，避免破坏旧导入盘；创建向导固定 `std`，实际恒为 `std`）。

**高级折叠**：原「▼ 高级选项」ListItem 改为**组头即折叠开关**——`groupHead('高级')` 后接 `▸ 展开`/`▾ 收起`，点击切换 `showAdvanced`，展开显示三项高级字段。

组头 builder 复用向导惯例（灰字 + 延伸线）：

```ts
@Builder
groupHead(label: string) {
  Row({ space: sp8 }) {
    Text(label).fontSize(tLabel).fontColor(cSub)
    Divider().strokeWidth(1).color(cBorder).layoutWeight(1)
  }
  .width('100%')
  .margin({ top: sp2, bottom: sp1 })
}
```

### ③ 存储弹窗 `VmStorage`

`secCdrom` 重排：

- 有 `cdromPath`：行 = 光盘文件名 + 「清除」按钮（现有逻辑保留）。
- 无 `cdromPath`：行 = 「未引用光盘」+ **「＋ 选择 ISO」**幽灵按钮（虚线边框、`cPrimary`、通栏居中），点击展开选择区。
- 展开选择区（复刻配置页光盘逻辑）：完整路径 `TextInput` + 「内置 Alpine (arch)」按钮（复用 `ensureBuiltinIso` + `builtinIsoFor`）。

需新增：
- `@StorageLink('vmDataDir')`（ISO 下载写盘目录；默认已有 `filesDir`）。
- `@State isoPickMode` / `isoPathText` / `ensureIsoLoading` / `isoPct`。
- `pickBuiltinIso()` 方法（从 `VmEdit` 复制），完成把 `cdromPath` 设为 `vmDataDir + '/' + name`、`bootFromCdrom = true`。
- import：`builtinIsoFor`（vmprofile）、`ensureBuiltinIso`（isoDl）、`common`（AbilityKit，`getContext` 用）。

## 数据模型

**不改** `vmprofile.ts` 的 `machine.vga` 字段（qemu 需要，仍是 `std`/`virtio`）。仅移除 UI 暴露，配置保存保留原值。无 schema 变更、无迁移。

## 不做的事

- 不改 `VmWizard`（创建向导路径已无 VGA，`groupHeader` 已是目标样式，无需动）。
- 不改 `vmprofile` / native / QMP 逻辑。
- 不改 `Index.ets` 导航壳（宽屏分栏、模态承载均不变）。
- 不做设置项的编辑器之外的功能增强（如新增选项）。

## 验证

1. `make hap` 编译通过（删 `VGA_OPTIONS`/`vga` 后无残留引用）。
2. 部署到 `192.168.1.4:44959`（先 `hdc tconn`）。
3. **详情页**：概览为独立分区胶囊（无 vga）；网络节为只读灰开关 + 「已启用」文案，点不动、不触发保存。
4. **配置页**：四分组（基础/存储/网络/高级）组头清晰；无「显卡」；高级组头点击展开/收起；保存后详情页信息一致。
5. **存储弹窗**：清光盘后出现「＋ 选择 ISO」，点开可输入路径或点「内置 Alpine」重新挂上，保存后详情页光盘显示更新。
