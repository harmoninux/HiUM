/* 统一设计 token：颜色 / 字号 / 间距 / 圆角。所有页面改用这些常量，禁止内联色值。
 * 颜色走资源引用（base/dark 两套 element/color.json），系统深浅色切换时 ArkUI
 * 自动重解析刷新——改成字面量就会失去深色适配（本项目曾因此整页浅色僵死）。 */

/* ---- 颜色（浅色值在 base，深色值在 resources/dark，同名一一对应）---- */
export const cPrimary  = $r('app.color.c_primary'); /* 主色：主按钮/选中/强调 */
export const cDanger   = $r('app.color.c_danger'); /* 危险：删除/强制断电 */
export const cRunning  = $r('app.color.c_running'); /* 运行中 */
export const cSuccess  = $r('app.color.c_success'); /* 成功：snackbar 勾 */
export const cWarn     = $r('app.color.c_warn'); /* 需自备镜像/缺媒体 */
export const cText     = $r('app.color.c_text'); /* 主文本 */
export const cSub      = $r('app.color.c_sub'); /* 次级文本：数据值（规格/状态/统计/标签值），如「qcow2 · 虚拟 16.0G」 */
export const cWeak     = $r('app.color.c_weak'); /* 弱文本：解释性引导句与占位提示，如「开启后防系统盘误写…」 */
export const cBg       = $r('app.color.c_bg'); /* 页面背景 */
export const cCard     = $r('app.color.c_card'); /* 卡片 */
export const cBorder   = $r('app.color.c_border'); /* 卡/元素边框 */
export const cBlock    = $r('app.color.c_block'); /* 灰底块（参数预览/图标底） */
export const cChip     = $r('app.color.c_chip'); /* chips 底 */
export const cSel      = $r('app.color.c_sel'); /* 选中描边/浅底 */
export const cSelBg    = $r('app.color.c_sel_bg'); /* 选中浅底 */

/* ---- 字号 (size / weight)：四档 20/16/14/12，主次分明的关键是「条目与说明分档」----
 * 层级混用审计结论（2026-10）：信息行曾在 tLabel(16)/tSub(14) 间随机取用、
 * 行内按钮曾在 tBody/tSub 间两档并存，落地后按下面角色对号入座，禁止借用。 */
export const tPage  = 20; /* 页面/窗口标题，500（不加大字重，层级靠档位差） */
export const tCard  = 16; /* 卡片/分组标题（SecHead 等），500~600；层级高于字段名 */
export const tLabel = 14; /* 表单字段名/标签（VmEdit 左列等）400——与 tItem 同值：字段名
                           * 跨页同档（详情页信息行与编辑弹窗表单标签一致），否则从详情页
                           * 打开编辑弹窗会有「字体突然变大」的跳变；对齐系统 Subtitle_S/Body_M */
export const tBody  = 16; /* 正文/一切按钮/输入框文字 400（系统 textfield 基准 16fp） */
export const tItem  = 14; /* 条目档：区块内信息行主文本（快照名/当前状态/已启用/盘信息行） */
export const tSub   = 12; /* 元数据档：说明/规格/日期/chips/徽标 400（对齐系统 caption） */
export const tMono  = 12; /* mono 小字：状态/指纹/步骤圆点 */

/* ---- 间距：4 的倍数纯档，按档取用不许自造数值 ---- */
export const sp1 = 4;
export const sp2 = 8;
export const sp3 = 12;
export const sp4 = 16;
export const sp5 = 24;
export const sp6 = 32;

/* ---- 圆角 / 边框 ---- */
export const rCard = 10;  /* 卡/按钮 */
export const rElem = 8;   /* 小元素 */
export const rBadge = 4;  /* 徽标 */
export const bw = 1;

/* ---- 按钮尺寸（对齐设计稿：小圆角矩形，而非系统默认胶囊） ---- */
export const rBtn = 8;    /* 按钮外圆角 */
export const btnH = 40;   /* 主/标准按钮高（图标按钮容器同高） */
export const btnSh = 32;  /* 小/文字式动作按钮高 */
export const btnPadX = 16;/* 按钮水平内边距 */
export const iconFs = 22; /* 图标按钮内 SymbolGlyph 字号（容器 btnH；截图卡等语境特例除外） */

/* ---- 文本输入框（统一外观，不再依赖系统默认高度/圆角/底色） ---- */
export const inpH = 40;      /* 标准输入框高（与 btnH 对齐，同排不错位） */
export const inpBg = cBlock; /* 输入框底，浅灰块 */
export const inpRadius = 8;  /* 输入框圆角 */
export const inpPadX = 16;   /* 输入框左右内边距 */

/* ---- 弹窗遮罩（主窗口全窗口模态共用；console 内另有更深的 cConsoleScrim） ---- */
export const scrim = 'rgba(0,0,0,0.45)';

/* ---- console 深色浮层专档：console 界面恒深色（画面纯黑底、串口面板 #20242b），
 * 不随系统深浅切换，故不走资源双色板而是固定值。注意不能直接套上面那组资源色：
 * cPrimary/cDanger/cWeak 是给浅色背景设计的深色值，搬到这里对比度只有 2.1~2.9:1
 *（实测「画面」「强制断电」这类文字看不清）；下面这组是深色浮层上的浅色版本，
 * 均 ≥4.5:1（WCAG AA）。同一语义值只留此处一份，改色只改这里。 ---- */
export const cConsoleText = '#fff5f7fa';      /* 浮层主文本 4.9:1 */
export const cConsoleAccent = '#ff94beff';    /* 浮层主色：选中态/强调 4.9:1 */
export const cConsoleDanger = '#ffffa8a8';    /* 浮层危险操作（亮红） 4.8:1 */
export const cConsoleLogText = '#fff1f2f4';   /* 串口日志正文 */
export const cConsoleWarn = '#fffecaca';      /* 熔断横幅标题（亮黄红） */
export const cConsolePanel = '#e620242b';     /* 串口面板/键帽行底（半透明深灰） */
export const cConsolePanelStrong = '#ee20242b'; /* 速查卡片底（更实一点） */
export const cConsoleInputBg = '#ff2b313b';   /* 串口输入框底（与面板拉开边界） */
export const cConsolePlaceholder = '#ff9aa4b2'; /* 串口输入框占位/光标提示 */
export const cConsoleBanner = '#e6601b1b';    /* 启动失败横幅底 */
export const cConsoleBtn = '#40ffffff';       /* 深色浮层上的浅色按钮底 */
export const cConsoleScrim = 'rgba(0,0,0,0.55)'; /* 全屏遮罩（手势速查/截图卡按钮） */

/* ---- 虚拟键盘浮动面板（恒深色底，同 console 专档理由；主色为固定亮蓝而非主题色） ---- */
export const cKbPanel = '#4D000000';   /* 面板底（半透明黑，透出画面） */
export const cKbKey = '#1A000000';     /* 键帽底 */
export const cKbBorder = '#66FFFFFF';  /* 键帽描边 */
export const cKbHandle = '#88FFFFFF';  /* 拖动把手 */
export const cKbPressed = '#ff0563ff'; /* 按下/锁存键帽底（固定在深底上白字可读的蓝） */
