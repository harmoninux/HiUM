# 光盘 ISO 选择器：文件选择器 + 内置 Alpine

> 日期：2026-08-29
> 类型：设计备忘（非 UI 重构 spec）
> 触发：用户反馈光盘让手填完整路径「不太合适、太麻烦了」。原则：**要么拉起文件选择器让用户选 ISO，要么用内置 Alpine**——不要让用户敲路径。已在 AskUserQuestion 确认**原地引用外部路径**：选中的 ISO 不拷贝进应用存储，直接引用选择器解析出的真实路径（省空间、秒挂），接受「选择器授权会话性、重启后可能读不到」的代价。

## 结论一句话

**去掉三处「ISO 完整路径」手填输入框，改用两种来源：① 内置 Alpine 一键下载；② 本机文件经 `DocumentViewPicker` 选择、`fileUri.getPathFromUri` 解析为真实路径后直接引用。选中即默认勾选「从光盘启动」。**

## 现状：三处入口全是「手填路径 + 内置 Alpine」两段式

| 入口 | 文件 | 现有 UI |
|---|---|---|
| 创建向导（介质步） | `VmWizard.ets` | 光盘名 + 移除；空态 TextInput('ISO 完整路径') + 内置 Alpine 按钮 |
| 编辑配置页（存储节） | `VmEdit.ets` | 同上 |
| 存储弹窗（光盘 ISO 节） | `VmStorage.ets` | 光盘名 + 清除；空态「＋ 选择 ISO」展开 pickMode 面板：TextInput + 内置 Alpine |

三者共用同一模式：`cdromPath` 存路径，`-cdrom <path>` 直接交给 qemu `fopen`（`vmprofile.ets:337`）。`VmConsole.startVm` 有一处**内置 ISO 特判**（`cdromPath === vmDataDir/alpine-*.iso 且缺失 → 先下载再启动`）。

## 方案

### 1. 复用层（新文件 `lib/isoPick.ets`）

封装「拉起系统文件选择器选一个 `.iso`，解析成 qemu 能 fopen 的真实路径」：

```ts
import { picker, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { pathExists } from './fsutil';

/* 拉起文档选择器选 1 个 .iso，返回真实文件路径；取消/失败返回 ''。
 * 参考 EntryAbility:39-42 的 save() 先例：new fileUri.FileUri(uri).path 取真实路径。 */
export function pickIsoPath(ctx: common.UIAbilityContext): Promise<string> {
  return new Promise<string>((resolve) => {
    const dp = new picker.DocumentViewPicker(ctx);
    dp.select({ maxSelectNumber: 1, fileSuffixFilters: ['.iso'] })
      .then((uris: string[]) => {
        if (uris.length === 0) { resolve(''); return; }
        let p = '';
        try { p = fileUri.getPathFromUri(uris[0]); } catch { p = ''; }
        if (p.length === 0 || !pathExists(p)) { p = ''; }
        resolve(p);
      })
      .catch(() => resolve(''));
  });
}
```

- `fileSuffixFilters: ['.iso']` 限定扩展名，避免用户误选非镜像文件。
- 解析失败/取消 → `''`，调用方 toast「未选择文件」即可。
- 不做拷贝（用户已选原地引用）。**依赖 `getPathFromUri` 返回 qemu 可 fopen 的真实路径**——若目标环境只返回虚拟/documents 路径导致 qemu 读不到，由第 2 层的启动失败兜底（`qemu-<id>.log` 弹窗，`VmConsole.failStart`）优雅收场，不崩。

### 2. 三处 UI 改造（去手填，换成两种来源）

**空态**（无 ISO）：一行两个按钮——
- `内置 Alpine (arch)`：现有 `pickBuiltinIso()`，下载到 `vmDataDir/<builtinIsoFor(arch)>` 后 `cdromPath = vmDataDir/...`，并 `bootFromCdrom = true`。
- `选择文件`：`pickIsoPath(ctx)` → 非空则 `cdromPath = <解析路径>`，并 `bootFromCdrom = true`。

**已选态**：`baseName(cdromPath)`（超长 ellipsis）+ `更换`（重新走两种来源）+ `移除`（`cdromPath = ''`，不清 ISO 文件）。`从光盘启动` Toggle 保留给手动覆盖。

具体三处：

- `VmWizard.ets`（约 490-502）——删除 `Row{ TextInput(placeholder:'ISO 完整路径') + 内置按钮 }`，改为两种来源按钮行。
- `VmEdit.ets`（约 322-335）——同上。
- `VmStorage.ets`（约 390-…）——空态不再展开 isoPickMode 面板，直接展示两种来源按钮；删除 `isoPickMode` / `isoPathText` 状态（清引用仍在 `clearCdrom`）。

**选择器进度态**：`内置 Alpine` 下载中显示 `下载 NN%` 并禁用（沿用现有 `ensureIsoLoading`/`isoPct`），`选择文件` 不受影响。

### 3. 不改的

- `vmprofile.ets` `buildArgs`：`-cdrom <path>` 保持不变（原地引用即可）。
- `VmConsole.startVm` 内置 ISO 特判：仅对「确实是内置路径且缺失」触发按需下载；用户选的有路径的文件不触发（本地文件不该被网络下载覆盖）。
- `VmList` 失效媒体清扫（`cdromPath` 存在性校验）、`VmEdit.saveError`/`VmWizard.calcError` 的「ISO 路径不存在」校验：保留，作为选完后的常规存在性检查。
- 自定义 qemu 参数（`extraArgs`）仍作高级逃生通道（用户想跑非iso源/更自由时用），不做静态校验——属于既有第 3 层兜底范畴。

## 落位与已知限制（用户已接受）

- `cdromPath` 直接存储外部真实路径，**不拷贝**。好处：大 ISO（>1GB）秒挂、不占应用存储、不重复。
- 代价：① 文档选择器授权具**会话性**，App 重启后该外部路径可能失去读权限 → qemu `fopen` 失败 → 由 `qemu-<id>.log` 启动失败弹窗兜底提示；② 文件在可移动存储上被拔出 → 同 ①；③ 外部文件被移动/删除 → `pathExists` 校验在编辑/向导拦，启动时 qemu 报错兜底。
- 若用户希望长期稳定，用「内置 Alpine」（应用自有文件）即可。

## 实现位置清单

| 文件 | 职责 |
|---|---|
| `lib/isoPick.ets`（新） | `pickIsoPath`：选 `.iso` → 解析真实路径 |
| `pages/VmWizard.ets` | 介质步光盘节：去掉手填，改两种来源按钮；选中自动勾盘 |
| `pages/VmEdit.ets` | 存储节光盘 ISO：同上 |
| `pages/VmStorage.ets` | 光盘 ISO 节：空态直接两来源按钮；删 `isoPickMode`/`isoPathText` |

## 经验规则（写给未来的维护者）

1. **ISO 来源三处同步**：创建向导 / 编辑配置页 / 存储弹窗任何一处改、另两处必须跟上——同类入口行为不一致是最容易踩的坑（本次正是三处手填齐改）。
2. **别再引入手填路径**：`cdromPath` 只能由内置 Alpine 或文件选择器产出。用户明确反馈手填「太麻烦」；确实想手填/加料的用 `extraArgs`。
3. **选中即默认勾「从光盘启动」**：选 ISO 的意图即引导，Toggle 保留手动覆盖。
4. **`-cdrom` 依赖真实路径**：引用型 ISO 能否长期读取决于选择器授权；不能读时靠第 3 层（qemu-<id>.log 弹窗）兜底，别试图在保存侧静默吞掉。

## 相关文档

- VM 参数校验生命周期：`2026-08-29-vm-param-validation-design.md`（第 3 层 qemu 兜底支撑本次引用型 ISO 的启动失败透出）
