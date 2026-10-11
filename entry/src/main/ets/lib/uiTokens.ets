/* 统一设计 token：颜色 / 字号 / 间距 / 圆角。所有页面改用这些常量，禁止内联色值。
 * 颜色走资源引用（base/dark 两套 element/color.json），系统深浅色切换时 ArkUI
 * 自动重解析刷新——改成字面量就会失去深色适配（本项目曾因此整页浅色僵死）。 */

/* ---- 说明文案摆放规范（2026-10-11 定）----
 * 控件/选项组的解释与提示一律放其**正下方**的独立整宽行（tSub + cWeak），禁止放
 * 控件行内右侧——行内说明随标签/选项宽度浮动，同屏两块（磁盘接口在行内、磁盘分配
 * 在下方）节奏不一被打回。细则：
 * 1. 选项组（chips）的说明解释「当前选中项」，随选择联动；
 * 2. 开关/滑条等撑满整行的项同规：说明在该行下方；
 * 3. 区块级固定提示（如「快照仅含系统盘…」）放区块末尾整宽行。 */

/* ---- 布局对齐规范（2026-10-11 定）----
 * 块内每一「行」（Row）显式 .width('100%') 撑满——Row 不写宽度时按内容宽渲染，
 * 会被外层 Column 默认水平居中（按钮行/chips 行/开关行在磁盘分配、磁盘来源、
 * 光盘区、存储页四处连爆，用户逐处撞见）。行内要右贴的元素（开关/行尾按钮）
 * 靠撑满 + layoutWeight 到位。行本身有意居中的（空态按钮、卡片文字），行前注释
 * 标 `// ui-layout-ok: 理由`；scripts/check-ui-layout.py（make ui-check）扫描
 * 未标记者，改 UI 后与交付前必跑。 */

/* ---- 块内间距规范（2026-10-11 定）----
 * 「行 + 说明」块内必须紧贴：**内紧外松**——内距（行↔说明）明显小于块间 sp3。
 * 行尾普通控件的块 Column 不带 space；行尾是实底宿主（chips/按钮/输入框胶囊）
 * 补 sp1。用户对「行↔说明 8→15px」的加宽明确打回（2026-10-11「选项内的间距还
 * 变更宽了」）——不许再「统一」放大内距。行尾 Toggle 的块 space 0 即可——Toggle
 * 盒自带上下留白，视觉内距已 ≈14px。
 *
 * ⚠️ 开关行高度**不可**用 .height() 约束（2026-10-11 实测证伪）：ArkUI 的
 * Toggle 图形随组件盒联动缩放（盒 66px→图形 38px；强压行盒到 38px 后图形只剩
 * 10px 细条，不是「溢出显示」）——压平=开关不可辨识，勿试。 */

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
export const rConsole = 6; /* console 串口面板内元素圆角（日志区/键帽/输入框，设计稿 6） */
export const bw = 1;

/* ---- 按钮尺寸（对齐设计稿：小圆角矩形，而非系统默认胶囊） ---- */
export const rBtn = 8;    /* 按钮外圆角 */
export const btnH = 40;   /* 主/标准按钮高（图标按钮容器同高） */
export const btnSh = 32;  /* 小/文字式动作按钮高（窗口底部操作条/页面返回钮，16fp 档） */
export const btnRow = 24; /* 行内控件高：24vp=46px——2026-10-11 用户定「其它控件参考系统盘
                           * 只读行调小」；先试 20vp(38px) 被打回「太小」（38 盒里 31px 文字
                           * 顶格无呼吸，图形控件≠文字控件），落 24vp——≥44px 触控底线，
                           * 文字上下各 ~7px。表单内 chips/文字动作钮（存储管理/选择文件/
                           * 移除/取消/确定…）与 Slider（滑动条行，默认 40vp 太高）用本档；
                           * 底部操作条不算行内。*/
export const btnPadX = 16;/* 按钮水平内边距 */
export const iconFs = 22; /* 图标按钮内 SymbolGlyph 字号（容器 btnH；截图卡等语境特例除外） */

/* ---- 文本输入框（统一外观，不再依赖系统默认高度/圆角/底色） ----
 * 字体随内容档 tItem。高度 32vp（61px）：曾试「与胶囊同高 46px」实测文字上下被裁
 * ——TextInput 上下默认 padding 各 8vp（官方文档），46px 扣掉后放不下 31px 文字。
 * 修法：上下 padding 显式压到 sp1（4vp）留足内容区；输入框比行内胶囊略大是系统
 * 组件留白所致（用户 2026-10-11「文本框暂时没必要压缩那么狠」）。
 * 底部操作条按钮才用 btnH 40。console 串口输入框不在此列（专档）。 */
export const inpH = 32;      /* 标准输入框高（61px；上下 padding 必须配 sp1，见上） */
export const inpBg = cBlock; /* 输入框底，浅灰块 */
export const inpRadius = 8;  /* 输入框圆角 */
export const inpPadX = 16;   /* 输入框左右内边距 */

/* ---- 弹窗遮罩（主窗口全窗口模态共用；console 内另有更深的 cConsoleScrim） ---- */
export const scrim = 'rgba(0,0,0,0.45)';

/* ---- 缩略图角标（列表缩略图左下角 arch 标签等）：叠在不可预知的画面像素上，
 * 恒定半透明黑底 + 白字，不随深浅色切换（同 console 专档理由）。---- */
export const cOverlayBg = 'rgba(0,0,0,0.55)';
export const cOverlayText = '#ffffffff';

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

/* ---- 串口底栏面板（2026-10-11 按设计稿重做：面板推开画面、底部常驻，非半透明浮层）---- */
export const cConsolePanelSolid = '#ff20242b'; /* 面板底（不透：底栏之下无画面可透） */
export const cConsoleLogBg = '#ff171a20';      /* 日志区底（比面板再深一档） */
export const cConsoleKey = '#1fffffff';        /* 键帽 chip 底（12% 白） */
export const cConsolePrimary = '#ff0563ff';    /* 主色实心（发送钮底，白字 ≥4.5:1，固定深底蓝） */

/* ---- 虚拟键盘浮动面板（恒深色底，同 console 专档理由；主色为固定亮蓝而非主题色） ---- */
export const cKbPanel = '#4D000000';   /* 面板底（半透明黑，透出画面） */
export const cKbKey = '#1A000000';     /* 键帽底 */
export const cKbBorder = '#66FFFFFF';  /* 键帽描边 */
export const cKbHandle = '#88FFFFFF';  /* 拖动把手 */
export const cKbPressed = '#ff0563ff'; /* 按下/锁存键帽底（固定在深底上白字可读的蓝） */
