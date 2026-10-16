# 运行态 HUD 设计 · 形态 A（定稿 2026-10-16）

Console 内的两级观测浮层：**读数 chip 常显**（一眼看负载）+ **点开监控卡**（线程级明细，排障证据）。
视觉稿：同目录 `2026-10-16-hud-design-mockup.html`（五帧状态 + 行为约定，token 全部取自
`uiTokens.ets` console 专档）。

## 0. 定位与口径

**这台 VM 在宿主机上的资源账单**——不是 guest 仪表盘。

- CPU = 子进程吃掉的核时；内存 = 子进程 RSS；磁盘 = 子进程文件 IO 吞吐。
- 回答「HiUM 跑这台 VM 会不会把手机拖死」（耗电/发热/卡顿的直接来源）。
- guest 内部状态（guest 负载、guest 内存、FPS）不在范围内，见 §5 后置。

分层原则：**宿主资源问内核（/proc），guest 逻辑问 QMP，guest 内部问 guest agent**。
本设计只做第一层。观测者不吊死在被观测者上（QMP 活性 = qemu 主循环活着，恰是
HUD 要诊断的对象——与「就绪判定只用 QMP 往返」是同一条纪律的两面）；线程榜只有
内核账本给得了（QMP query-cpus-fast 无 per-thread CPU%、无 RSS、无线程名）；
/proc/<子进程> 天然是单 VM 粒度（cgroup 是全 app 共享的，拆不开）。

## 1. 评审决定（2026-10-16，均已确认）

| # | 决定 | 理由 |
|---|---|---|
| 1 | 形态 A：chip + 点开卡 | 一眼可见性 + 按需明细；形态 B（无 chip）少一眼可见，形态 C（底栏第三视图）留给曲线时代 |
| 2 | 命名「监控」不叫「性能」 | 避开设置页「性能预设」概念撞车 |
| 3 | 状态消息 chip 整体移除 | 用户不要「启动完成」这类常显指示；落地时删 `this.status` chip，本设计读数 chip 是钮旁唯一常显物 |
| 4 | 悬浮钮常驻，不加隐藏能力 | 它是电源/串口/工具栏唯一入口；自动隐没与 guest 输入手势打架 |
| 5 | 数据源 /proc，不用 QMP | 见 §0；实现首日探针定读取路线（§4） |
| 6 | FPS/guest 内部/网络速率/曲线 后置 | 见 §5 |

## 2. UI 规格

### 2.1 状态阶梯

```
① 完全收起：只剩悬浮钮（HUD 关 = 零开销，无定时器无采样）
② HUD 开·收起：钮旁多一枚读数 chip「116% · 1.2G」
③ HUD 开·展开：+ 监控卡（指标区 + 线程榜），锚定钮行下
④ 工具栏展开：「监控」按钮入列（激活态 accent），卡下移避让
```

- chip 与钮同行（Row：圆钮 + chip，gap sp2）；拖钮整体跟随（同一锚点）。
- 交互：工具栏「监控」开关 HUD（激活高亮 `cConsoleAccent`，同串口/输入范式）；
  HUD 开时**点 chip 展开卡、再点收起**。
- 开关状态入全局偏好（FAB_PREF，同输入设置/串口字号，跨 VM 手感一致）。

### 2.2 读数 chip

- 高 36（与圆钮一致），`cConsolePanel` 底，圆角 12，内边距左右 sp2，字号 14 白。
- 内容 `CPU% · 内存`（如 `116% · 1.2G`），等宽数字（`font-variant-numeric` 或
  monospace）+ **定 minWidth**，刷新不跳。
- 采样失败/VM 未运行显示 `— · —`，不报错。

### 2.3 监控卡

- 宽 300，`cConsolePanelStrong` 底（比工具栏更实），圆角 12，内边距 sp3。
- 卡头：`监控`（14 白）+ 右侧 `● 1s 采样`（12 灰，绿点为状态色、必须带文字标签）。
- 指标区（3 行）：标签 12 灰（`cConsolePlaceholder`）居左；值 14 白等宽右对齐。
  - `CPU` → `116% ≈1.2 核`（核数换算随值，em 12 灰）
  - `内存` → `1.2G`（子进程 VmRSS）
  - `磁盘` → `读 2.1 / 写 0.3 MB/s`
- 分隔线：12% 白（hair）。
- 线程榜：12 等宽，按占用降序 **top 4**，超出合并 `其余 N 线程 x%`（灰）。
  线程名 = qemu 线程 comm（如 `CPU 0/TCG`、`qemu-main`、`io-thread`），开发者向。
- 定位：水平以钮心为中心（出界贴边，同 `toolbarX` 逻辑）；垂直贴钮行下 sp2，
  工具栏展开时贴工具栏下 sp2（下移避让）；放不下翻到上方（同 `toolbarY` 逻辑）。
- 空态：居中一行 13 灰「虚拟机未运行」。

### 2.4 token

全部沿用 console 专档（panel/panelStrong/text/accent/placeholder/hair），**不新增
token**。恒深底浅字不随深浅色切换（叠在不可预知的 guest 画面上，同串口面板理由）。

## 3. 数据规格

### 3.1 数据面（一次采样全量）

| 项 | 来源（子进程视角） | 说明 |
|---|---|---|
| CPU 总 ticks | `/proc/self/task/*/stat` utime+stime 求和 | 父侧差分 ÷ 经过时间，`clk_tck`=100；100% = 1 核（top 口径） |
| 线程榜 | 同上逐线程 + `/proc/self/task/<tid>/comm` | comm 16 字节装得下 qemu 线程名 |
| 内存 | `/proc/self/status` VmRSS | kB → G 显示 |
| 磁盘 | `/proc/self/io` rchar/wchar | 差分出速率；口径=进程文件 IO（含串口日志写）。**刻意不用 read_bytes/write_bytes**——只计穿透存储的物理 IO，页缓存吸收后数字失真 |

### 3.2 采样纪律

- 1s 一拍（htop 手感）；**仅 HUD 开 + console 窗口前台**时跑；HUD 关 = 零开销。
- 轮询在 ArkTS（`setTimeout` 循环调 `napi.vmStats(vmId)`），差分状态持在 native 层，
  ArkTS 只消费算好的每秒值（接口风格对齐 `diskInfo`：返回 JSON 串）。
- 子进程刚死/采样失败：显示「—」，自动停拍（进程不存在不建定时器拍空数据）。

## 4. 读取路线（实现首日探针定）

同一数据面，两条路线：

- **A · 父进程直读** `/proc/<child_pid>/`：IPC 协议零改动、子进程不用动（部署快）。
  风险：HarmonyOS 沙箱对读自有子进程 /proc 无文档背书（Android 同场景一般允许）。
- **B · 子进程自读 + IPC 上报**：`qemu_ipc.h` 加 `kStats = 11`（`[ver] → [ver]累计值+线程榜`），
  子进程自读自己零权限风险；payload KB 级，远低于 OHIPC parcel MB 级红线（kScreenshot
  教训）；版本号不 bump（父子同包同批构建，同 kScreenshot 先例）。

**探针**：native 侧对运行中子进程一次 `open(/proc/<pid>/stat)`，失败与否立刻见分晓。
通 → 走 A；不通 → 落 B。上次卡死观测证明这设备内核 /proc task 级数据真实存在
（当时经 hdc shell 读），未验证的只是 app 沙箱视角。

## 5. 边界与后置

- **FPS**：需渲染侧接线（renderer/fb 帧计数已有雏形 `f.frames`），单独立项。
- **guest 内部负载/进程**：需 guest agent（Phase 3 阶梯，qga 走 virtio-serial）。
- **网络速率**：/proc 无 per-进程 socket 吞吐口径，后置。
- **历史曲线**：待形态 C（底栏第三视图/长观测）。

## 6. 关联改动：状态消息移除

- 删 `VmConsole` 的 `this.status` 常显 chip（悬浮钮旁）及相关 setState。
- 反馈路径去向（实现时逐条确认）：启动失败 → 熔断横幅（独立保留）；VM 退出 →
  串口面板「连接已断开」提示已有 + 窗口标题；其余瞬态消息（启动完成/重启中）直接消失。
- 本项与 HUD 同批落地（同文件同区域，一次走查）。

## 7. 验收清单（真机）

1. chip 数值与 hdc 侧 `top -p <child_pid>` 对照量级一致；数字刷新不跳动。
2. 点 chip 展开卡/再点收起；工具栏展开时卡下移不重叠；拖钮 chip+卡跟随。
3. VM 未运行：chip `— · —`、卡空态；HUD 关：hilog 无采样定时器活动（零开销）。
4. 线程榜在 guest 卡死场景能认出单线程满转（本设计的立项动机，复现时验证）。
5. 状态消息移除后：启动失败横幅、VM 退出反馈路径无回归。
