// 虚拟机屏幕虚拟键盘 overlay：VmConsole 悬浮菜单「虚拟键盘」开关控制显隐，
// 面板可拖动（拖顶部把手），位置持久化（preferences 按 vmId 区分）。
// 仿 wineohos main-ui KeyboardOverlay：紧凑 QWERTY + 修饰键锁存语义（Shift/Ctrl/Alt
// 点按点亮，下一个普通键按下时先行注入其 down，抬起后再补 up 并解除锁存——避免
// 忘松修饰键导致后续输入全带修饰）。注入走 qemu QKeyCode（与物理键盘 sendKey
// 同通道）：napi.sendKey(vmId, qcode, down)。键值来源 lib/keymap.ets 的
// HOS_TO_QKEYCODE values（即 qapi 的 QKeyCode 枚举）。
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
}

/* keyView 入参。必须整体作为单个对象字面量传给 @Builder（按引用传递），
 * pressed/latched 变化才会刷新键帽配色——拆成基本类型参数会被快照冻结 */
interface KeySpec {
  k: KbKey;
  pressed: boolean;
  latched: boolean;
}

function key(label: string, code: number, w: number = 1, mod: number = 0): KbKey {
  return { label: label, code: code, w: w, mod: mod };
}

/* 紧凑 QWERTY 布局（qemu QKeyCode）：数字行 + 三行字母 + 空格/方向行；
 * 只保留桌面操作高频键。修饰键 qcode 取自 keymap（Shift=1 / Ctrl=5 / Alt=3）。 */
const KB_ROWS: KbKey[][] = [
  [key('Esc', 8, 1.3), key('1', 9), key('2', 10), key('3', 11), key('4', 12), key('5', 13),
   key('6', 14), key('7', 15), key('8', 16), key('9', 17), key('0', 18), key('⌫', 21, 1.7)],
  [key('Tab', 22, 1.5), key('Q', 23), key('W', 24), key('E', 25), key('R', 26), key('T', 27),
   key('Y', 28), key('U', 29), key('I', 30), key('O', 31), key('P', 32)],
  [key('Ctrl', 5, 1.7, 2), key('A', 36), key('S', 37), key('D', 38), key('F', 39), key('G', 40),
   key('H', 41), key('J', 42), key('K', 43), key('L', 44), key('Enter', 35, 1.8)],
  [key('Shift', 1, 1.9, 1), key('Z', 49), key('X', 50), key('C', 51), key('V', 52), key('B', 53),
   key('N', 54), key('M', 55), key(',', 56), key('.', 57), key('/', 58)],
  [key('Alt', 3, 1.7, 4), key('空格', 60, 5.6), key('←', 99), key('↑', 100), key('↓', 101), key('→', 102)],
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
  @State private scrW: number = 0;     /* 窗口 vp 尺寸（onAreaChange 量得，钳制基准） */
  @State private scrH: number = 0;
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

  /* 面板宽/高估算（position 定位用）。宽随窗口缩放，高固定（5 行键帽 + 把手）。
   * 首帧 scrW=0 时回退 640，等 onAreaChange 量得窗口后重算 */
  private kbdW(): number {
    return this.scrW > 0 ? Math.min(this.scrW * 0.94, 860) : 640;
  }

  private kbdH(): number {
    return 292;
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

  @Builder
  keyView($$: KeySpec) {
    Text($$.k.label)
      .fontSize($$.k.label.length > 1 ? 12 : 15)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(42)
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
                if (this.scrW <= 0 || this.scrH <= 0) {
                  return;
                }
                /* 中心坐标，钳制到让整面板（按估算宽高）落在窗口内 */
                const nx = (this.panRelX * this.scrW + ev.offsetX) / this.scrW;
                const ny = (this.panRelY * this.scrH + ev.offsetY) / this.scrH;
                const loX = Math.min(this.kbdW() / 2 / this.scrW, 0.5);
                const loY = Math.min(this.kbdH() / 2 / this.scrH, 0.5);
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
                  latched: k.mod != 0 && (this.modMask & k.mod) != 0
                })
              }, (k: KbKey) => k.code.toString())
            }
            .width('100%')
          }, (row: KbKey[], idx: number) => idx.toString())
        }
        .width(this.kbdW())
        .padding({ left: sp8, right: sp8, top: 2, bottom: sp8 })
        /* 半透明面板：压低不透明度让 VM 画面透出来（键帽同理） */
        .backgroundColor('#4D000000')
        .borderRadius(12)
        /* 面板区域阻断下层：容器 Transparent（自身不阻塞下层），面板用
         * BLOCK_HIERARCHY（自身+子节点响应、阻止下层兄弟参与触摸测试） */
        .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
        .position({
          /* 中心坐标换算成左上角，再把整面板钳制在窗口内（顶/底/左/右不越界） */
          x: this.scrW > 0 ? Math.min(
            Math.max(this.relX * this.scrW - this.kbdW() / 2, 0),
            Math.max(0, this.scrW - this.kbdW())) : 0,
          y: this.scrH > 0 ? Math.min(
            Math.max(this.relY * this.scrH - this.kbdH() / 2, 0),
            Math.max(0, this.scrH - this.kbdH())) : 0,
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
