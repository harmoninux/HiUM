/* 统一设计 token：颜色 / 字号 / 间距 / 圆角。所有页面改用这些常量，禁止内联色值。 */

/* ---- 颜色 ---- */
export const cPrimary  = '#ff0563ff'; /* 主色：主按钮/选中/强调 */
export const cDanger   = '#ffd92d20'; /* 危险：删除/强制断电 */
export const cRunning  = '#ff1f7a44'; /* 运行中 */
export const cSuccess  = '#ff34d399'; /* 成功：snackbar 勾 */
export const cWarn     = '#ffb25e09'; /* 需自备镜像/缺媒体 */
export const cText     = '#ff15181c'; /* 主文本 */
export const cSub      = '#ff6e7480'; /* 次级文本（加深一档提升可读性） */
export const cWeak     = '#ff8a8f98'; /* 弱文本/占位 */
export const cBg       = '#fffafafa'; /* 页面背景 */
export const cCard     = '#ffffffff'; /* 卡片 */
export const cBorder   = '#ffe8e8e8'; /* 卡/元素边框 */
export const cBlock    = '#fff1f2f4'; /* 灰底块（参数预览/图标底） */
export const cChip     = '#fff1f2f4'; /* chips 底 */
export const cSel      = '#ffdbe9ff'; /* 选中描边/浅底 */
export const cSelBg    = '#ffeef4ff'; /* 选中浅底 */

/* ---- 字号 (size / weight) ---- */
export const tPage  = 18; /* 页面/窗口标题 700 */
export const tCard  = 14; /* 卡片/行标题 600 */
export const tLabel = 14; /* 设置行标签 400 */
export const tBody  = 14; /* 正文/按钮 400 */
export const tSub   = 12; /* 次级说明 400 */
export const tMono  = 11; /* mono 小字：状态/指纹/日期/步骤圆点 */

/* ---- 间距 ---- */
export const sp1 = 6;
export const sp2 = 10;
export const sp3 = 16;
export const sp4 = 22;
export const sp5 = 32;

/* ---- 圆角 / 边框 ---- */
export const rCard = 10;  /* 卡/按钮 */
export const rElem = 8;   /* 小元素 */
export const rBadge = 4;  /* 徽标 */
export const bw = 1;

/* ---- 按钮尺寸（对齐设计稿：小圆角矩形，而非系统默认胶囊） ---- */
export const rBtn = 8;    /* 按钮外圆角 */
export const btnH = 40;   /* 主/标准按钮高 */
export const btnSh = 32;  /* 小/文字式动作按钮高 */
export const btnPadX = 16;/* 按钮水平内边距 */

/* ---- 文本输入框（统一外观，不再依赖系统默认高度/圆角/底色） ---- */
export const inpH = 44;      /* 标准输入框高 */
export const inpBg = cBlock; /* 输入框底，浅灰块 */
export const inpRadius = 8;  /* 输入框圆角 */
export const inpPadX = 16;   /* 输入框左右内边距 */
