// 全局设置（bindSheet 居中卡承载，入口在列表侧栏标题行）。
// 三个区块：控制（console 输入偏好）/ 存储（vms/ 资产占用 + 内置 ISO 清理）/ 关于。
// 控制区读写与 VmConsole 同一份偏好文件（vmconsole_fab）同键——控制台每次进入
// loadConsolePrefs，设置页改完下次进入生效；控制台内「输入」菜单仍是就地编辑入口。

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SecHead, ChipRow, ToggleRow, InfoRow } from '../lib/uiWidgets';
import { sp1, sp3, sp4, sp5, tSub, tItem, tLabel, cWeak, cSub, cDanger, rBtn, btnRow } from '../lib/uiTokens';
import { fileSizeOf } from '../lib/fsutil';
import { VmArch, builtinIsoFor } from '../lib/vmprofile';

const DOMAIN = 0x0001;
const TAG = 'QemuUI';

/* 与 VmConsole.FAB_PREF 相同文件、相同键（跨组件复制的键名，勿单侧改名） */
const CONSOLE_PREF = 'vmconsole_fab';
const SERIAL_FS: number[] = [12, 14, 17];

/* 内置 ISO 覆盖的架构（builtinIsoFor 返回空名的架构不在设置页出现） */
const ISO_ARCHES: VmArch[] = ['x86_64', 'i386', 'aarch64', 'arm', 'loongarch64', 'riscv64'];
const SERIAL_FS_OPTIONS: string[] = ['12', '14', '17'];

@Component
export struct SettingsSheet {
  onOpenLicense: () => void = () => {}; /* 打开开源许可详情（VmList 侧的独立 sheet） */
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @State inputMode: number = 0;
  @State scrollReverse: boolean = false;
  @State cursorSpeedIdx: number = 1;
  @State serialFs: number = SERIAL_FS[0];
  @State assetBytes: number = 0;
  /* arch -> 实际字节数（0 = 未下载；列表按有文件在前稳定排序在 build 内做） */
  @State isoBytes: Map<string, number> = new Map();
  @State version: string = '';

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    preferences.getPreferences(ctx, CONSOLE_PREF).then((prefs: preferences.Preferences) => {
      this.inputMode = prefs.getSync('input_mode', 0) as number;
      this.scrollReverse = prefs.getSync('scroll_reverse', false) as boolean;
      this.cursorSpeedIdx = prefs.getSync('cursor_speed', 1) as number;
      this.serialFs = prefs.getSync('serial_fs', SERIAL_FS[0]) as number;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'settings loadPrefs: %{public}s', JSON.stringify(e));
    });
    this.refreshAssets();
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'settings version: %{public}s', JSON.stringify(e));
    }
  }

  private savePref(key: string, value: preferences.ValueType): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    preferences.getPreferences(ctx, CONSOLE_PREF).then((prefs: preferences.Preferences) => {
      prefs.putSync(key, value);
      prefs.flush();
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'settings savePref: %{public}s', JSON.stringify(e));
    });
  }

  /* vms/ 目录递归合计（磁盘/ISO/内核都在这层；条目量级小，同步遍历无感） */
  private refreshAssets(): void {
    let total = 0;
    const isos = new Map<string, number>();
    const walk = (dir: string): void => {
      let names: string[] = [];
      try {
        names = fs.listFileSync(dir);
      } catch {
        return;
      }
      for (const n of names) {
        const p = dir + '/' + n;
        let isDir = false;
        let size = 0;
        try {
          const st = fs.statSync(p);
          isDir = st.isDirectory();
          size = st.size;
        } catch {
          continue;
        }
        if (isDir) {
          walk(p);
        } else {
          total += size;
          if (n.endsWith('.iso')) {
            isos.set(n, size);
          }
        }
      }
    };
    walk(this.vmDataDir);
    /* 磁盘镜像与 VM 配置在 files/vms（VmStore 目录），与 vmDataDir（固件+内置 ISO）
     * 是平级目录——只走一边会把 GB 级磁盘漏成百 MB（2026-10-17 真机抓到） */
    walk(this.filesDir + '/vms');
    this.assetBytes = total;
    this.isoBytes = isos;
  }

  private human(bytes: number): string {
    if (bytes <= 0) {
      return '0';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(0) + ' KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }
    return (bytes / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
  }

  private isoList(): string[] {
    const out: string[] = [];
    for (const a of ISO_ARCHES) {
      const n = builtinIsoFor(a);
      if (n.length > 0 && (this.isoBytes.get(n) ?? 0) > 0) {
        out.push(n);
      }
    }
    return out;
  }

  private sizeOf(name: string): number {
    return this.isoBytes.get(name) ?? 0;
  }

  private openRepo(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.openLink('https://github.com/harmoninux/HiUM').catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'settings openRepo: %{public}s', JSON.stringify(e));
    });
  }

  private deleteIso(name: string): void {
    AlertDialog.show({
      title: '删除内置镜像',
      message: `删除 ${name}？下次使用内置镜像时会自动重新下载。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: cDanger,
        action: () => {
          try {
            fs.unlinkSync(this.vmDataDir + '/' + name);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'settings deleteIso: %{public}s', JSON.stringify(e));
          }
          this.refreshAssets();
        },
      },
    });
  }

  build() {
    Scroll() {
      Column({ space: sp4 }) {
        SecHead({ label: '控制' })
        /* 说明置空：触屏/触控板的行为差异在控制台「输入」菜单里有完整描述，
         * 设置页只做默认值切换，不重复长文案 */
        ChipRow({ label: '输入模式', options: ['0', '1'], labels: ['触屏模式', '触控板模式'],
          value: String(this.inputMode),
          onChange: (v: string) => {
            this.inputMode = parseInt(v);
            this.savePref('input_mode', this.inputMode);
          } })
        ToggleRow({ label: '滚轮反向', isOn: this.scrollReverse,
          desc: '滚轮/双指滑动的方向取反',
          onChange: (v: boolean) => {
            this.scrollReverse = v;
            this.savePref('scroll_reverse', v);
          } })
        ChipRow({ label: '光标速度', options: ['0', '1', '2'], labels: ['慢', '中', '快'],
          value: String(this.cursorSpeedIdx),
          onChange: (v: string) => {
            this.cursorSpeedIdx = parseInt(v);
            this.savePref('cursor_speed', this.cursorSpeedIdx);
          } })
        ChipRow({ label: '串口字号', options: SERIAL_FS_OPTIONS,
          value: String(this.serialFs),
          onChange: (v: string) => {
            this.serialFs = parseInt(v);
            this.savePref('serial_fs', this.serialFs);
          } })
        Text('下次打开控制台时生效').fontSize(tSub).fontColor(cWeak).width('100%')

        SecHead({ label: '存储' })
        InfoRow({ label: '虚拟机资产', main: this.human(this.assetBytes),
          sub: '虚拟机磁盘、镜像与内核文件合计' })
        /* 内置镜像 = 单标签 + 下载列表（用户定：逐行 InfoRow 重复「内置镜像」标签难看）；
         * 行内 名称 + 大小 + 删除；空态「未下载」弱提示 */
        Column({ space: sp1 }) {
          Text('内置镜像').fontSize(tLabel)
          if (this.isoList().length > 0) {
            ForEach(this.isoList(), (n: string) => {
              Row({ space: sp3 }) {
                Text(n).fontSize(tSub).fontColor(cSub)
                  .layoutWeight(1).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.human(this.sizeOf(n))).fontSize(tSub).fontColor(cWeak)
                Button('删除').focusable(false).fontSize(tItem)
                  .height(btnRow).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
                  .backgroundColor(Color.Transparent).fontColor(cDanger)
                  .onClick(() => this.deleteIso(n))
              }.width('100%')
            }, (n: string) => n)
          } else {
            Text('未下载').fontSize(tSub).fontColor(cWeak)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        SecHead({ label: '关于' })
        InfoRow({ label: '应用', main: 'HiUM', sub: 'HarmonyOS 上的 QEMU 虚拟机' })
        InfoRow({ label: '版本', main: this.version.length > 0 ? this.version : '—' })
        InfoRow({ label: '开源地址', main: 'github.com/harmoninux/HiUM',
          actionLabel: '打开',
          onAction: (): void => this.openRepo() })
        InfoRow({ label: '开源许可', main: 'GPL-2.0',
          actionLabel: '详情',
          onAction: (): void => this.onOpenLicense() })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: sp5, right: sp5, top: sp4, bottom: sp4 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart) /* 同 LicenseSheet：内容不足一屏时不要垂直居中 */
  }
}
