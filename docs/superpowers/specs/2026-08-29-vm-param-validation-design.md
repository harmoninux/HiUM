# VM 参数校验生命周期：静态拦截 + QEMU 语义兜底

> 日期：2026-08-29
> 类型：设计备忘（非 UI 重构 spec）
> 触发：用户在新建/编辑 VmWizard/VmEdit 时发现「勾选从光盘启动但未指定 ISO」创建成功、启动才哑火；并强调自定义 qemu 参数导致永远无法完美校验，必须把报错透给用户。

## 结论一句话

**参数校验分三层，分工不同：结构层归一化保证可解析，静态校验层拦"明显无效"，QEMU 语义层兜底拦"静态拦不住"的错——启动失败时把 qemu 日志的真实原因透给用户。** 三者互补，缺一不可。

## 哪些参数组合可能无效

分两类：

**A. 可静态判定**（无需 qemu 知识，纯格式/组合/存在性）——应在保存/创建前拦：

| 组合 | 后果 | 拦截点 |
|---|---|---|
| `bootFromCdrom=true` 但 `cdromPath=''` | `-boot d` 无光驱 → qemu 不报错但起不来 | VmWizard `calcError` 介质步 / VmEdit `saveError` |
| `cdromPath` 非空但路径不存在 | qemu 找不到文件 | 同上（`pathExists`） |
| 端口转发非法（飞 `abc` / 超出 1-65535 / 宿主端口重复） | `parseForwards` 静默丢弃 → 用户以为设了实际没生效 | `forwardErrors` |
| cpuModel 含非法字符（空格等） | `-cpu foo` 报 unknown CPU | 向导 `calcError`（编辑页无输入口，仅适用向导） |
| tb-size 非 512-8192 整数 | 资源型异常 | 向导 `calcError`（编辑页有整数兜底为 1024） |

**B. 无法静态判定**（需 qemu 语义/资源知识）——只能运行时兜底：

- `-cpu foo` 不存在的机型（cpuModel 是自由文本，qemu 知识外）
- **extraArgs**（escape hatch，`buildArgs` 原样 `split(/\s+/).concat` 追加）——根本无校验
- 内存超物理容量，`-m` 分配失败
- 自定义参数与已生成参数冲突（重复 `-m`、未知 `-device`）

**核心**：extraArgs 决定了"无论如何都做不成完美校验"，所以 B 类错误必须有用户可见的出口 —— 让 qemu 自己把话说出来。

## 三层校验体系

### 第 1 层：结构归一化（`vmprofile.ets`）
`migrateProfile` / `fitBoard` / `buildArgs` 保证**结构合法**：板卡按架构收紧、vga/firmware 白名单、端口转发非法条目静默跳过。**只保证"可解析"，不保证"qemu 语义合法"。** 这是底线，任何字段进来都不会让命令行语法崩。

### 第 2 层：静态校验（向导/编辑页）
把"明显无效"拦在落盘前，避免用户保存后才暴露：

- `VmWizard.calcError` — 逐布红字 + 禁用下一步/完成（cpuModel 正则 / tb-size 范围 / ISO 存在 / `forwardErrors` / **从光盘启动无 ISO** / 名称非空）。覆盖最全。
- `VmEdit.saveError` — `save()` 前拦：从光盘启动无 ISO / ISO 路径不存在 / `forwardErrors`。与向导对齐；cpuModel 编辑页无入口、tb-size 有兜底故不重复。

> 历史坑：编辑页补了「从光盘启动无 ISO」后，向导漏同步 —— 同样的字段两种入口行为不一致。**规则：同一校验必须同时落在向导和编辑页，保持可预期。**

### 第 3 层：QEMU 语义兜底（`VmConsole`）
针对 B 类错误，启动失败时读取 `<vmDataDir>/qemu-<vmId>.log` 末尾 60 行，弹窗（`AlertDialog`）展示完整原因：

- `failStart(shortMsg)`：状态栏留简洁「启动失败」，`AlertDialog` 标题「QEMU 启动失败」，内容为 qemu-<vmId>.log 尾部（`\n` 保留结构，可整段看长报错/backtrace）。
- 触发点：`doStart` 里 `startVm` 返回非 0、以及 10s 后子进程退出仍未运行。
- 为何用弹窗而非状态栏：状态栏 `maxLines(1)` 会截断长文本，报错往往远长于一行。

qemu-<vmId>.log 由 `vm.cpp` 把 stdout/stderr `O_TRUNC` 重定向生成：文件名带 vmId（从 `-qmp unix:.../qmp-<id>.sock` 反解——vmId 本身不传给子进程），多实例各写各文件，与 `qmp-<id>.sock`/`serial-<id>.log` 对齐，互不覆盖。是语义错误的**唯一权威来源**。

## 实现位置清单

| 文件 | 职责 |
|---|---|
| `lib/vmprofile.ets` | 结构归一化（`migrateProfile`/`fitBoard`/`buildArgs`） |
| `lib/vmprofile.ets` `forwardErrors` | 端口转发逐条校验（向导调用）|
| `pages/VmWizard.ets` `calcError` | 创建逐步校验（含从光盘启动无 ISO）|
| `pages/VmEdit.ets` `saveError` | 编辑保存前校验（对齐向导）|
| `pages/VmConsole.ets` `failStart`/`qemuLogTail` | 启动失败读 qemu-<vmId>.log 弹窗兜底 |

## 经验规则（写给未来的维护者）

1. **新增可校验字段**：优先在第 2 层加静态校验，且**向导+编辑页两处同步**，不能只加一处。
2. **静态拦不住的**（新增 escape hatch、自由文本、资源型）：交给第 3 层，别指望静默兜底能救 —— 让 qemu 日志报给用户。
3. **`-boot` 依赖**：`buildArgs` 里 `-boot d/c` 只判 `bootFromCdrom`，不判有无光盘 —— 这类"组合级"依赖最容易漏，加字段时要连组合一起考虑。
4. 校验报错要**能直接指导用户**（如「从光盘启动需先指定 ISO」），别只报"参数无效"。
5. **按实例产出的文件要带 id**：`qmp-<id>.sock` / `serial-<id>.log` / `qemu-<id>.log` 都是按 vmId 区分。别用不带 id 的全局文件 —— 多实例并跑时会互相 `O_TRUNC` 覆盖、写交错（qemu.log 曾踩过，已改为按 id）。

## 相关文档

- UI 重构 spec：`2026-08-29-vm-config-detail-ui-redesign-design.md`
- 本次实现提交：`cbdb0dd`（静态校验）、`2bd5c8a`（qemu.log 透出）、`e1c456f`（向导无盘路径清理，前序）
