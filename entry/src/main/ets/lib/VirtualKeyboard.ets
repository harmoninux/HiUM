// 虚拟机屏幕虚拟键盘 overlay：VmConsole 悬浮菜单「虚拟键盘」开关控制显隐，
// 面板可拖动（拖顶部把手），位置持久化（preferences 按 vmId 区分）。
// 布局参考 wineohos KeyboardOverlay（a7c18f3）：标准 104 键紧凑布局——F1-F12 行、
// 全标点（` - = [ ] \ ; ' 及 Shift 组合符号）、Home/End/PgUp/PgDn + T 形方向键、
// 左右双 Shift；键值翻译成 qemu QKeyCode（evdev→qapi 枚举序号，与 lib/keymap.ets
// 同源）。修饰键锁存语义（Shift/Ctrl/Alt 点按点亮，下一个普通键按下时先行注入其
// down，抬起后再补 up 并解除锁存——避免忘松修饰键导致后续输入全带修饰）；
// Shift 锁存中带副符号的键帽切换显示副符号（与真实键盘同语义，打出 !@#: 等）。
// 注入走 qemu QKeyCode（与物理键盘 sendKey 同通道）：napi.sendKey(vmId, qcode, down)。
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import napiModule from 'libentry.so';
import { rElem, sp1, sp8 } from './uiTokens';

const DOMAIN = 0x0002;
const TAG = 'KbdOverlay';
const KBD_PREF = 'vmconsole_fab';   /* 复用 fab 的 preferences 文件，键名前缀分开 */
const KBD_PREF_POS = 'kbdpos';

interface KbdNapi {
  sendKey: (vmId: string, qcode: number, down: boolean) => void;
}

const kbdNapi: KbdNapi = napiModule as KbdNapi;

interface KbKey {
  label: string;
  code: number;  /* qemu QKeyCode */
  w: number;     /* 行内 layoutWeight */
  mod: number;   /* 0 普通键；1 Shift / 2 Ctrl / 4 Alt 修饰锁存位 */
  shiftLabel: string; /* Shift 锁存时键帽切换显示的副符号（'' = 无副符号键） */
}

/* keyView 入参。必须整体作为单个对象字面量传给 @Builder（按引用传递），
 * pressed/latched/shiftActive 变化才会刷新键帽——拆成基本类型参数会被快照冻结 */
interface KeySpec {
  k: KbKey;
  pressed: boolean;
  latched: boolean;
  shiftActive: boolean;
}

function key(label: string, code: number, w: number = 1, mod: number = 0, shiftLabel: string = ''): KbKey {
  return { label: label, code: code, w: w, mod: mod, shiftLabel: shiftLabel };
}

/* 连续 qcode 的字母键段（QWERTY 在 QKeyCode 枚举里各占一段连续序号） */
function letters(start: number, labels: string): KbKey[] {
  const out: KbKey[] = [];
  for (let i = 0; i < labels.length; i++) {
    out.push(key(labels[i], start + i));
  }
  return out;
}

/* 标准 104 键紧凑布局（qemu QKeyCode）：F 行（Esc 同行）+ 符号数字行 + 三行字母 +
 * 编辑/方向行。带 Shift 组合符号的键（数字行/标点）键帽平时只显示主字符，Shift
 * 锁存时切换显示副符号（1→!，;→:），按下即打出副符号（qemu 侧按修饰键组合解释，
 * 与真实键盘同语义）。右 Shift 仅作锁存触发（code 只用于键帽去重，修饰键不发
 * 独立事件）。 */
const KB_ROWS: KbKey[][] = [
  [key('Esc', 8, 1.3),
   key('F1', 62), key('F2', 63), key('F3', 64), key('F4', 65),
   key('F5', 66), key('F6', 67), key('F7', 68), key('F8', 69),
   key('F9', 70), key('F10', 71), key('F11', 92), key('F12', 93),
   key('Del', 104, 1.1)],
  /* 数字行：主字符 + Shift 组合符号 */
  [key('`', 47, 0.9, 0, '~'),
   key('1', 9, 1, 0, '!'), key('2', 10, 1, 0, '@'), key('3', 11, 1, 0, '#'),
   key('4', 12, 1, 0, '$'), key('5', 13, 1, 0, '%'), key('6', 14, 1, 0, '^'),
   key('7', 15, 1, 0, '&'), key('8', 16, 1, 0, '*'), key('9', 17, 1, 0, '('),
   key('0', 18, 1, 0, ')'),
   key('-', 19, 1, 0, '_'), key('=', 20, 1, 0, '+'), key('⌫', 21, 1.4)],
  [key('Tab', 22, 1.5)].concat(letters(23, 'QWERTYUIOP'))
    .concat([key('[', 33, 1, 0, '{'), key(']', 34, 1, 0, '}'), key('\\', 48, 1.05, 0, '|')]),
  [key('Ctrl', 5, 1.7, 2)].concat(letters(36, 'ASDFGHJKL'))
    .concat([key(';', 45, 1.05, 0, ':'), key('\'', 46, 1.05, 0, '"'), key('Enter', 35, 1.8)]),
  [key('Shift', 1, 1.9, 1)].concat(letters(49, 'ZXCVBNM'))
    .concat([key(',', 56, 1, 0, '<'), key('.', 57, 1, 0, '>'), key('/', 58, 1, 0, '?'),
      key('↑', 100, 1.1), key('Shift', 2, 1.5, 1)]),
  [key('Alt', 3, 1.5, 4), key('空格', 60, 3.2),
   key('Home', 95, 1.1), key('End', 98, 1.1),
   key('PgUp', 96, 1.1), key('PgDn', 97, 1.1),
   key('←', 99, 1.1), key('↓', 101, 1.1), key('→', 102, 1.1)],
];

/* 模拟键盘覆盖层：点按/长按键帽即注入 key down/up。容器 Transparent 穿透：
 * 空白处触摸直达 VM 画面，只有键帽/把手消费触摸。 */
@Component
export struct VirtualKeyboard {
  @Prop vmId: string = '';
  @Link showKbd: boolean;
  @State private relX: number = 0.5;   /* 面板中心相对窗口宽 */
  @State private relY: number = 0.9;   /* 面板中心相对窗口高 */
  @State private pressedCodes: number[] = [];
  @State private modMask: number = 0;  /* 锁存中的修饰键位掩码 (1/2/4) */
  /* scrW/scrH 必须 @State：onAreaChange 量得后要驱动 position 重算（普通字段改值
   * 不触发布局），否则键盘首帧停在顶/左上角 */
  @State private scrW: number = 0;     /* 窗口 vp 尺寸（父容器 onAreaChange 量得） */
  @State private scrH: number = 0;
  /* 面板实测尺寸（@State 同理）：6 行布局键数随窗口换行不多，但高度随字体/行距
   * 变化，估算值会失准导致钳制出界——用量得的实际宽高做钳制基准 */
  @State private panelW: number = 0;
  @State private panelH: number = 0;
  private modsAtDown: Map<number, number> = new Map(); /* 普通键抬起时补 up 的锁存掩码 */
  private panRelX: number = 0.5;       /* 拖动起手时的面板中心 */
  private panRelY: number = 0.9;

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /* 位置持久化（Preferences 按 vmId 区分不同 VM 的落位）。显隐由父 VmConsole 管 */
  private loadPos(): void {
    if (this.vmId.length === 0) {
      return;
    }
    preferences.getPreferences(this.ctx(), KBD_PREF).then((prefs: preferences.Preferences) => {
      const s = prefs.getSync(`${this.vmId}_${KBD_PREF_POS}`, '') as string;
      if (s) {
        const pos = JSON.parse(s) as Record<string, number>;
        if (typeof pos['relX'] === 'number' && typeof pos['relY'] === 'number') {
          this.relX = pos['relX'];
          this.relY = pos['relY'];
        }
      }
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'loadPos: %{public}s', JSON.stringify(e));
    });
  }

  private savePos(): void {
    if (this.vmId.length === 0) {
      return;
    }
    preferences.getPreferences(this.ctx(), KBD_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync(`${this.vmId}_${KBD_PREF_POS}`, JSON.stringify({ relX: this.relX, relY: this.relY }));
      prefs.flush();
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'savePos: %{public}s', JSON.stringify(e));
    });
  }

  aboutToAppear(): void {
    this.loadPos();
  }

  /* 注入与物理键盘同通道（qemu QKeyCode）：sendKey(vmId, qcode, down) */
  private sendKbKey(code: number, down: boolean): void {
    if (this.vmId.length === 0 || code <= 0) {
      return;
    }
    kbdNapi.sendKey(this.vmId, code, down);
  }

  private sendMods(mask: number, down: boolean): void {
    if ((mask & 1) != 0) {
      this.sendKbKey(1, down);   /* Shift */
    }
    if ((mask & 2) != 0) {
      this.sendKbKey(5, down);   /* Ctrl */
    }
    if ((mask & 4) != 0) {
      this.sendKbKey(3, down);   /* Alt */
    }
  }

  private onKeyTouch(k: KbKey, ev: TouchEvent): void {
    if (k.mod != 0) {
      /* 修饰键：仅翻转锁存态，不发事件（单独按 Shift 对 guest 无意义，
       * 且锁存语义保证不会出现"按下没抬起"的卡键） */
      if (ev.type === TouchType.Down) {
        this.modMask = this.modMask ^ k.mod;
      }
      return;
    }
    if (ev.type === TouchType.Down) {
      const m = this.modMask;
      this.modsAtDown.set(k.code, m);
      this.sendMods(m, true);
      this.sendKbKey(k.code, true);
      this.modMask = 0;
      this.pressedCodes = this.pressedCodes.concat([k.code]);
    } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
      if (this.pressedCodes.indexOf(k.code) < 0) {
        return;
      }
      this.sendKbKey(k.code, false);
      this.sendMods(this.modsAtDown.get(k.code) ?? 0, false);
      this.modsAtDown.delete(k.code);
      this.pressedCodes = this.pressedCodes.filter((c: number) => c != k.code);
    }
  }

  private keyLabel(k: KbKey, shiftActive: boolean): string {
    return shiftActive && k.shiftLabel ? k.shiftLabel : k.label;
  }

  @Builder
  keyView($$: KeySpec) {
    Text(this.keyLabel($$.k, $$.shiftActive))
      .fontSize(this.keyLabel($$.k, $$.shiftActive).length > 1 ? 12 : 15)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(38)
      .backgroundColor($$.pressed || $$.latched ? '#ff0563ff' : '#1A000000')
      .borderRadius(rElem)
      .border({ width: 1, color: '#66FFFFFF' })
      .layoutWeight($$.k.w)
      .onTouch((ev: TouchEvent) => {
        this.onKeyTouch($$.k, ev);
      })
  }

  build() {
    Stack() {
      if (this.showKbd) {
        Column({ space: sp1 }) {
          /* 顶部把手：拖动挪位。手势只挂把手——挂整个面板会和键帽 onTouch 抢事件
           * （按键微动即拖走面板）。拖动中直接改 relX/relY（position 的数据源），
           * 面板逐帧跟手；落盘在 onEnd。 */
          Row() {
            Row()
              .width(36)
              .height(4)
              .borderRadius(2)
              .backgroundColor('#88FFFFFF')
          }
          .width('100%')
          .height(18)
          .justifyContent(FlexAlign.Center)
          .gesture(
            PanGesture()
              .onActionStart(() => {
                this.panRelX = this.relX;
                this.panRelY = this.relY;
              })
              .onActionUpdate((ev: GestureEvent) => {
                if (this.scrW <= 0 || this.scrH <= 0 || this.panelW <= 0) {
                  return;
                }
                /* 中心坐标，钳制到让整面板（按实测宽高）落在窗口内 */
                const nx = (this.panRelX * this.scrW + ev.offsetX) / this.scrW;
                const ny = (this.panRelY * this.scrH + ev.offsetY) / this.scrH;
                const loX = Math.min(this.panelW / 2 / this.scrW, 0.5);
                const loY = Math.min(this.panelH / 2 / this.scrH, 0.5);
                this.relX = Math.min(Math.max(nx, loX), 1 - loX);
                this.relY = Math.min(Math.max(ny, loY), 1 - loY);
              })
              .onActionEnd(() => {
                this.savePos();
              })
          )
          ForEach(KB_ROWS, (row: KbKey[]) => {
            Row({ space: 4 }) {
              ForEach(row, (k: KbKey) => {
                this.keyView({
                  k: k,
                  pressed: this.pressedCodes.indexOf(k.code) >= 0,
                  latched: k.mod != 0 && (this.modMask & k.mod) != 0,
                  shiftActive: (this.modMask & 1) != 0
                })
              }, (k: KbKey) => k.code.toString())
            }
            .width('100%')
          }, (row: KbKey[], idx: number) => idx.toString())
        }
        .width(this.scrW > 0 ? Math.min(this.scrW * 0.94, 860) : 640)
        .padding({ left: sp8, right: sp8, top: 2, bottom: sp8 })
        /* 半透明面板：压低不透明度让 VM 画面透出来（键帽同理） */
        .backgroundColor('#4D000000')
        .borderRadius(12)
        /* 面板区域阻断下层：容器 Transparent（自身不阻塞下层），面板用
         * BLOCK_HIERARCHY（自身+子节点响应、阻止下层兄弟参与触摸测试） */
        .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
        .position({
          /* 中心坐标钳制在窗口内：持久化位置 + 换机/转屏后仍保证整面板可见。
           * 首帧 panelW=0 时钳制退化为不钳制，量得尺寸后自动归位 */
          x: this.scrW > 0
            ? Math.min(Math.max(this.relX, this.panelW / 2 / this.scrW),
                1 - this.panelW / 2 / this.scrW) * this.scrW - this.panelW / 2
            : 0,
          y: this.scrH > 0
            ? Math.min(Math.max(this.relY, this.panelH / 2 / this.scrH),
                1 - this.panelH / 2 / this.scrH) * this.scrH - this.panelH / 2
            : 0,
        })
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          this.panelW = newValue.width as number;
          this.panelH = newValue.height as number;
        })
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.scrW = newValue.width as number;
      this.scrH = newValue.height as number;
    })
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
