// 虚拟机配置页：普通字段 + 高级折叠区（TCG/自定义参数）。
// 只编辑 VmProfile JSON，保存后由列表页/console 窗口消费。
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore, VmArch, VgaType } from '../lib/vmprofile';

interface CreateDiskNapi {
  createDisk: (path: string, sizeMB: number) => number;
}

const napi = napiModule as CreateDiskNapi;

const ARCH_OPTIONS: VmArch[] = ['x86_64', 'i386', 'aarch64'];
const VGA_OPTIONS: VgaType[] = ['std', 'virtio'];

@Component
export struct VmEdit {
  profile: VmProfile | null = null; /* 由导航参数传入；就地编辑副本 */
  @Consume('navStack') navStack: NavPathStack;
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') vmListVersion: number = 0;

  @State name: string = '';
  @State arch: VmArch = 'x86_64';
  @State memoryMB: number = 1024;
  @State cpus: number = 2;
  @State diskPath: string = '';
  @State diskGB: number = 8;
  @State cdromPath: string = '';
  @State bootFromCdrom: boolean = false;
  @State vga: VgaType = 'std';
  @State netEnabled: boolean = true;
  @State portForwards: string = '';
  @State mttcg: boolean = true;
  @State tbSizeText: string = '1024';
  @State extraArgs: string = '';
  @State showAdvanced: boolean = false;

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.arch;
    this.memoryMB = p.memoryMB;
    this.cpus = p.cpus;
    this.diskPath = p.diskPath;
    this.cdromPath = p.cdromPath;
    this.bootFromCdrom = p.bootFromCdrom;
    this.vga = p.vga;
    this.netEnabled = p.netEnabled;
    this.portForwards = p.portForwards;
    this.mttcg = p.mttcg;
    this.tbSizeText = String(p.tbSize);
    this.extraArgs = p.extraArgs;
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  private createDisk(): void {
    if (!this.profile) {
      return;
    }
    const store = new VmStore(this.filesDir);
    const path = `${store.dir}/${this.profile.id}.img`;
    const ret = napi.createDisk(path, Math.round(this.diskGB * 1024));
    if (ret !== 0) {
      promptAction.showToast({ message: '创建磁盘失败' });
      return;
    }
    this.diskPath = path;
    promptAction.showToast({ message: `已创建 ${this.diskGB}GB 稀疏磁盘（raw）` });
  }

  private save(): void {
    if (!this.profile) {
      return;
    }
    const tbSize = Number(this.tbSizeText);
    const p: VmProfile = {
      id: this.profile.id,
      name: this.name.trim().length > 0 ? this.name.trim() : '未命名',
      arch: this.arch,
      memoryMB: Math.round(this.memoryMB),
      cpus: Math.round(this.cpus),
      diskPath: this.diskPath,
      cdromPath: this.cdromPath.trim(),
      bootFromCdrom: this.bootFromCdrom,
      vga: this.vga,
      netEnabled: this.netEnabled,
      portForwards: this.portForwards.trim(),
      mttcg: this.mttcg,
      tbSize: Number.isInteger(tbSize) && tbSize > 0 ? tbSize : 1024,
      extraArgs: this.extraArgs.trim(),
    };
    new VmStore(this.filesDir).save(p);
    this.vmListVersion++;
    promptAction.showToast({ message: '已保存' });
    this.navStack.pop();
  }

  build() {
    Column() {
      Row() {
        Button('取消').focusable(false).fontSize(14).backgroundColor(Color.Transparent)
          .fontColor('#ff007dff')
          .onClick(() => this.navStack.pop())
        Blank()
        Text('虚拟机配置').fontSize(18).fontWeight(FontWeight.Medium)
        Blank()
        Button('保存').focusable(false).fontSize(14).backgroundColor(Color.Transparent)
          .fontColor('#ff007dff')
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })

      List({ space: 1 }) {
        ListItem() {
          Row() {
            Text('名称').fontSize(14).width(72)
            TextInput({ text: this.name })
              .layoutWeight(1)
              .onChange((v: string) => this.name = v)
          }.padding(12)
        }

        ListItem() {
          Row() {
            Text('架构').fontSize(14).width(72)
            Select(ARCH_OPTIONS.map((a: VmArch): SelectOption => {
              return { value: a };
            }))
              .value(this.arch)
              .selected(ARCH_OPTIONS.indexOf(this.arch))
              .onSelect((index: number) => {
                this.arch = ARCH_OPTIONS[index];
              })
          }.padding(12)
        }

        ListItem() {
          Column({ space: 4 }) {
            Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(14)
            Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
              .onChange((v: number) => this.memoryMB = v)
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Column({ space: 4 }) {
            Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(14)
            Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
              .onChange((v: number) => this.cpus = v)
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Column({ space: 6 }) {
            Row() {
              Text('系统盘').fontSize(14).width(72)
              Text(this.diskPath ? this.baseName(this.diskPath) : '无')
                .fontSize(13)
                .fontColor('#ff666666')
                .layoutWeight(1)
              if (this.diskPath) {
                Button('移除').focusable(false).fontSize(12)
                  .onClick(() => this.diskPath = '')
              }
            }
            if (!this.diskPath) {
              Row({ space: 8 }) {
                Slider({ value: this.diskGB, min: 1, max: 32, step: 1 })
                  .layoutWeight(1)
                  .onChange((v: number) => this.diskGB = v)
                Text(`${Math.round(this.diskGB)}GB`).fontSize(13)
                Button('创建').focusable(false).fontSize(12)
                  .onClick(() => this.createDisk())
              }
            }
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Column({ space: 6 }) {
            Row() {
              Text('光盘 ISO').fontSize(14).width(72)
              Text(this.cdromPath ? this.baseName(this.cdromPath) : '无')
                .fontSize(13)
                .fontColor('#ff666666')
                .layoutWeight(1)
              if (this.cdromPath) {
                Button('移除').focusable(false).fontSize(12)
                  .onClick(() => this.cdromPath = '')
              }
            }
            if (!this.cdromPath) {
              Row({ space: 8 }) {
                TextInput({ placeholder: 'ISO 完整路径', text: this.cdromPath })
                  .layoutWeight(1)
                  .onChange((v: string) => this.cdromPath = v)
                Button('内置 Alpine').focusable(false).fontSize(12)
                  .onClick(() => {
                    const iso = this.vmDataDir + '/alpine-virt.iso';
                    if (fs.accessSync(iso)) {
                      this.cdromPath = iso;
                    } else {
                      promptAction.showToast({ message: '内置 ISO 不存在（需 make deps）' });
                    }
                  })
              }
            }
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Row() {
            Text('从光盘启动').fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
              .onChange((v: boolean) => this.bootFromCdrom = v)
          }.padding(12)
        }

        ListItem() {
          Row() {
            Text('显卡').fontSize(14).width(72)
            Select(VGA_OPTIONS.map((v: VgaType): SelectOption => {
              return { value: v };
            }))
              .value(this.vga)
              .selected(VGA_OPTIONS.indexOf(this.vga))
              .onSelect((index: number) => {
                this.vga = VGA_OPTIONS[index];
              })
          }.padding(12)
        }

        ListItem() {
          Row() {
            Text('网络').fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
              .onChange((v: boolean) => this.netEnabled = v)
          }.padding(12)
        }

        if (this.netEnabled) {
          ListItem() {
            Column({ space: 4 }) {
              Text('端口转发（宿主端口:客机端口，逗号分隔）').fontSize(13).fontColor('#ff666666')
              TextInput({ placeholder: '如 2222:22,8080:80', text: this.portForwards })
                .onChange((v: string) => this.portForwards = v)
            }.alignItems(HorizontalAlign.Start).padding(12)
          }
        }

        ListItem() {
          Row() {
            Text(this.showAdvanced ? '▲ 高级选项' : '▼ 高级选项')
              .fontSize(14)
              .fontColor('#ff007dff')
              .layoutWeight(1)
          }
          .padding(12)
          .onClick(() => this.showAdvanced = !this.showAdvanced)
        }

        if (this.showAdvanced) {
          ListItem() {
            Row() {
              Text('TCG 多线程 (MTTCG)').fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.mttcg })
                .onChange((v: boolean) => this.mttcg = v)
            }.padding(12)
          }
          ListItem() {
            Row() {
              Text('tb-size').fontSize(14).width(96)
              TextInput({ text: this.tbSizeText })
                .layoutWeight(1)
                .onChange((v: string) => this.tbSizeText = v)
            }.padding(12)
          }
          ListItem() {
            Column({ space: 4 }) {
              Text('自定义 qemu 参数（追加到命令行末尾）').fontSize(13).fontColor('#ff666666')
              TextArea({ placeholder: '如 -device usb-kbd', text: this.extraArgs })
                .onChange((v: string) => this.extraArgs = v)
            }.alignItems(HorizontalAlign.Start).padding(12)
          }
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
}
