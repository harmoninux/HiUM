// 单台虚拟机的管理页（per-VM）：系统盘信息 / 扩容 / 移除。
// 快照、时光机入口后续（Phase 1）加在这里 —— 快照归属单台 VM，不进跨 VM 的库。
// 从列表卡片正文进入（卡片点击只进管理，不启动；启动仍走「启动」按钮）。
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore } from '../lib/vmprofile';
import { vmIsRunning } from '../lib/vmregistry';

interface DiskNapi {
  diskInfo: (path: string) => string;
  diskResize: (path: string, sizeMB: number) => number;
}

const napi = napiModule as DiskNapi;
const GB = 1024 * 1024 * 1024;

@Component
export struct VmManage {
  profile: VmProfile | null = null; /* 由导航参数传入 */
  @Consume('navStack') navStack: NavPathStack;
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @State name: string = '';
  @State arch: string = '';
  @State diskPath: string = '';
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;
  @State expandMode: boolean = false;
  @State newGBText: string = '';

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.diskPath = p.media.diskPath;
    this.refreshDisk();
  }

  private refreshDisk(): void {
    this.diskVirtualGB = 0;
    this.diskActualGB = 0;
    this.diskFmt = '?';
    if (!this.diskPath) {
      return;
    }
    const s = napi.diskInfo(this.diskPath);
    if (s.length === 0) {
      return;
    }
    try {
      /* ArkTS 禁对接口字段下标访问、禁 unknown：用 Record 字典式解析 + typeof 窄化 */
      const j = JSON.parse(s) as Record<string, number | string>;
      const vsize = typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0;
      const asize = typeof j['actual-size'] === 'number' ? j['actual-size'] as number : 0;
      const fmt = typeof j['format'] === 'string' ? j['format'] as string : '?';
      this.diskVirtualGB = vsize / GB;
      this.diskActualGB = asize / GB;
      this.diskFmt = fmt;
    } catch {
      /* 解析失败保持默认 */
    }
  }

  /* qcow2 只能扩大：目标须大于当前 virtual-size；运行中不能动 backing 盘 */
  private doExpand(): void {
    if (!this.diskPath) {
      return;
    }
    if (this.profile && vmIsRunning(this.profile.id)) {
      promptAction.showToast({ message: '运行中不能扩容系统盘' });
      return;
    }
    const gbNum = Number(this.newGBText);
    if (!Number.isInteger(gbNum) || gbNum <= 0) {
      promptAction.showToast({ message: '请输入有效的大小（GB）' });
      return;
    }
    if (gbNum * GB <= this.diskVirtualGB) {
      promptAction.showToast({ message: '扩容目标须大于当前大小' });
      return;
    }
    const ret = napi.diskResize(this.diskPath, gbNum * 1024);
    if (ret !== 0) {
      promptAction.showToast({ message: '扩容失败' });
      return;
    }
    this.expandMode = false;
    this.newGBText = '';
    this.refreshDisk();
    promptAction.showToast({ message: `已扩容到 ${gbNum} GB` });
  }

  private confirmRemove(): void {
    if (!this.profile) {
      return;
    }
    if (vmIsRunning(this.profile.id)) {
      promptAction.showToast({ message: '运行中不能移除系统盘' });
      return;
    }
    AlertDialog.show({
      title: '移除系统盘',
      message: '移除后该虚拟机的系统盘文件将被删除，且不可恢复。确认？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '移除',
        fontColor: Color.Red,
        action: () => {
          const p = this.profile;
          if (!p) {
            return;
          }
          try {
            if (this.diskPath && fs.accessSync(this.diskPath)) {
              fs.unlinkSync(this.diskPath);
            }
          } catch {
            /* 删除失败不阻塞，仍清引用 */
          }
          p.media.diskPath = '';
          new VmStore(this.filesDir).save(p);
          this.diskPath = '';
          this.vmListVersion++;
          this.refreshDisk();
          promptAction.showToast({ message: '已移除系统盘' });
        },
      },
    });
  }

  build() {
    Column() {
      Row() {
        Button('返回').focusable(false).fontSize(14).backgroundColor(Color.Transparent)
          .fontColor('#ff007dff')
          .onClick(() => this.navStack.pop())
        Blank()
        Text('虚拟机管理').fontSize(18).fontWeight(FontWeight.Medium)
        Blank()
        Text(this.arch).fontSize(13).fontColor('#ff666666')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })

      List({ space: 1 }) {
        ListItem() {
          Row() {
            Text('名称').fontSize(14).width(72)
            Text(this.name).fontSize(15).layoutWeight(1)
          }.padding(12)
        }

        ListItem() {
          Column({ space: 8 }) {
            Row() {
              Text('系统盘').fontSize(16).fontWeight(FontWeight.Medium)
              Blank()
              if (this.diskPath) {
                Text(this.baseName(this.diskPath)).fontSize(13).fontColor('#ff666666')
              }
            }
            if (this.diskPath) {
              Text(`${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`)
                .fontSize(13)
                .fontColor('#ff666666')
              Row({ space: 8 }) {
                Button('信息').focusable(false).fontSize(13)
                  .onClick(() => {
                    promptAction.showToast({
                      message: `${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`,
                    });
                  })
                Button('扩容').focusable(false).fontSize(13)
                  .onClick(() => {
                    this.newGBText = this.diskVirtualGB > 0 ? String(Math.ceil(this.diskVirtualGB)) : '';
                    this.expandMode = !this.expandMode;
                  })
                Button('移除').focusable(false).fontSize(13).fontColor(Color.Red)
                  .onClick(() => this.confirmRemove())
              }
              if (this.expandMode) {
                Row({ space: 8 }) {
                  Text('新大小(GB)').fontSize(13).fontColor('#ff666666')
                  TextInput({ text: this.newGBText })
                    .type(InputType.Number)
                    .layoutWeight(1)
                    .onChange((v: string) => this.newGBText = v)
                  Button('确定').focusable(false).fontSize(13)
                    .onClick(() => this.doExpand())
                  Button('取消').focusable(false).fontSize(13).fontColor('#ff666666')
                    .onClick(() => this.expandMode = false)
                }
              }
            } else {
              Text('未配置系统盘，可到配置页添加').fontSize(13).fontColor('#ff999999')
            }
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Row() {
            Text('快照 / 时光机').fontSize(15).fontColor('#ff007dff')
            Blank()
            Text('后续版本').fontSize(12).fontColor('#ff999999')
          }.padding(12)
        }
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 1, color: '#11000000' })
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#fff2f3f5')
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }
}
