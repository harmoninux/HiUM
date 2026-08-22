// 虚拟机配置页：普通字段 + 高级折叠区（TCG/自定义参数）。
// 只编辑 VmProfile JSON，保存后由列表页/console 窗口消费。
import { promptAction } from '@kit.ArkUI';
import { pathExists } from '../lib/fsutil';
import napiModule from 'libentry.so';
import { VmProfile, VmStore, VmArch, VgaType, SCHEMA_VERSION, fitBoard } from '../lib/vmprofile';
import { cPrimary, cDanger, cRunning, cWarn, cSub, cWeak, cBg, cBorder, tPage, tLabel, tBody, tSub, tMono, rBtn, btnSh, inpH, inpBg, inpRadius, inpPadX, sp2 } from '../lib/uiTokens';

interface DiskNapi {
  createDisk: (path: string, sizeMB: number, alloc: string) => number;
  diskInfo: (path: string) => string;
}

const napi = napiModule as DiskNapi;

const ARCH_OPTIONS: VmArch[] = ['x86_64', 'i386', 'aarch64'];
const VGA_OPTIONS: VgaType[] = ['std', 'virtio'];
/* 系统盘容量档位（GB）：指数翻倍进档，1→256 覆盖三个数量级。
 * Slider 滑的是索引（线性），显示的是档位值（指数），见磁盘块。 */
const DISK_SIZES: number[] = [1, 2, 4, 8, 16, 32, 64, 128, 256];
const GB = 1024 * 1024 * 1024;

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
  @State diskAlloc: string = 'dynamic'; /* dynamic|fixed → qemu-img preallocation=off|falloc */
  @State diskCreate: boolean = false; /* 「启用系统盘」开关：开 = 保存时建盘，关 = 仅光盘/不加盘 */
  @State cdromPath: string = '';
  @State bootFromCdrom: boolean = false;
  @State vga: VgaType = 'std';
  @State netEnabled: boolean = true;
  @State portForwards: string = '';
  @State sharedFolder: boolean = false;
  @State mttcg: boolean = true;
  @State tbSizeText: string = '1024';
  @State extraArgs: string = '';
  @State showAdvanced: boolean = false;
  /* 已建系统盘的元信息（qemu-img info），直接在「系统盘」行内展示 */
  @State diskFmt: string = '?';
  @State diskVirtualGB: number = 0;
  @State diskActualGB: number = 0;

  aboutToAppear(): void {
    const p = this.profile;
    if (!p) {
      return;
    }
    this.name = p.name;
    this.arch = p.machine.arch;
    this.memoryMB = p.runtime.memoryMB;
    this.cpus = p.runtime.cpus;
    this.diskPath = p.media.diskPath;
    this.cdromPath = p.media.cdromPath;
    this.bootFromCdrom = p.media.bootFromCdrom;
    this.vga = p.machine.vga;
    this.netEnabled = p.net.enabled;
    this.portForwards = p.net.portForwards;
    this.sharedFolder = p.net.sharedFolder;
    this.mttcg = p.runtime.mttcg;
    this.tbSizeText = String(p.runtime.tbSize);
    this.extraArgs = p.extraArgs;
    this.readDiskMeta();
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  /* 用户打开「启用系统盘」开关；真正创建在点「保存」时发生，取消不留孤儿盘 */
  private createDiskNow(): boolean {
    if (!this.profile) {
      return false;
    }
    const store = new VmStore(this.filesDir);
    const path = `${store.dir}/${this.profile.id}.qcow2`;
    const ret = napi.createDisk(path, Math.round(this.diskGB * 1024), this.diskAlloc);
    if (ret !== 0) {
      promptAction.showToast({ message: '创建磁盘失败' });
      return false;
    }
    this.diskPath = path;
    this.readDiskMeta();
    return true;
  }

  /* 读取已建磁盘的格式/虚拟大小/实占大小（qemu-img info），供「系统盘」行直接展示 */
  private readDiskMeta(): void {
    this.diskFmt = '?';
    this.diskVirtualGB = 0;
    this.diskActualGB = 0;
    if (!this.diskPath) {
      return;
    }
    const s = napi.diskInfo(this.diskPath);
    if (s.length === 0) {
      return;
    }
    try {
      /* ArkTS 禁对接口字段下标访问（arkts-no-props-by-index），用 Record 字典式解析 */
      const j = JSON.parse(s) as Record<string, number | string>;
      const vsize = typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0;
      const actual = typeof j['actual-size'] === 'number' ? j['actual-size'] as number : 0;
      const fmt = typeof j['format'] === 'string' ? j['format'] as string : '?';
      this.diskFmt = fmt;
      this.diskVirtualGB = vsize / GB;
      this.diskActualGB = actual / GB;
    } catch {
      /* 解析失败保持默认 */
    }
  }

  private save(): void {
    if (!this.profile) {
      return;
    }
    /* 用户启用系统盘：保存时才真正建盘（建失败不保存，避免半成品配置） */
    if (this.diskCreate && !this.diskPath) {
      if (!this.createDiskNow()) {
        return;
      }
    }
    const tbSize = Number(this.tbSizeText);
    const p: VmProfile = {
      schemaVersion: SCHEMA_VERSION,
      id: this.profile.id,
      name: this.name.trim().length > 0 ? this.name.trim() : '未命名',
      machine: {
        arch: this.arch,
        vga: this.vga,
        machine: fitBoard(this.arch, this.profile.machine.machine),
        firmware: this.profile.machine.firmware,
        cpuModel: this.profile.machine.cpuModel,
      },
      runtime: {
        memoryMB: Math.round(this.memoryMB),
        cpus: Math.round(this.cpus),
        mttcg: this.mttcg,
        tbSize: Number.isInteger(tbSize) && tbSize > 0 ? tbSize : 1024,
      },
      media: {
        diskPath: this.diskPath,
        cdromPath: this.cdromPath.trim(),
        bootFromCdrom: this.bootFromCdrom,
      },
      net: {
        enabled: this.netEnabled,
        portForwards: this.portForwards.trim(),
        sharedFolder: this.sharedFolder,
      },
      temporarySession: this.profile.temporarySession,
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
        Button('取消').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: 10, right: 10 })
          .backgroundColor(Color.Transparent)
          .fontColor(cPrimary)
          .onClick(() => this.navStack.pop())
        Blank()
        Text('虚拟机配置').fontSize(tPage).fontWeight(FontWeight.Medium)
        Blank()
        Button('保存').focusable(false).fontSize(tBody)
          .height(btnSh).borderRadius(rBtn).padding({ left: 10, right: 10 })
          .backgroundColor(Color.Transparent)
          .fontColor(cPrimary)
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })

      List({ space: 1 }) {
        ListItem() {
          Row() {
            Text('名称').fontSize(tLabel).width(72)
            TextInput({ text: this.name })
              .layoutWeight(1)
              .fontSize(tBody)
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
              .onChange((v: string) => this.name = v)
          }.padding(12)
        }

        ListItem() {
          Row() {
            Text('架构').fontSize(tLabel).width(72)
            Select(ARCH_OPTIONS.map((a: VmArch): SelectOption => {
              return { value: a };
            }))
              .value(this.arch)
              .selected(ARCH_OPTIONS.indexOf(this.arch))
              .font({ size: tBody })
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).layoutWeight(1)
              .onSelect((index: number) => {
                this.arch = ARCH_OPTIONS[index];
              })
          }.padding(12)
        }

        ListItem() {
          Column({ space: 4 }) {
            Text(`内存: ${Math.round(this.memoryMB)} MB`).fontSize(tLabel)
            Slider({ value: this.memoryMB, min: 256, max: 8192, step: 256 })
              .onChange((v: number) => this.memoryMB = v)
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Column({ space: 4 }) {
            Text(`CPU 核数: ${Math.round(this.cpus)}`).fontSize(tLabel)
            Slider({ value: this.cpus, min: 1, max: 8, step: 1 })
              .onChange((v: number) => this.cpus = v)
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Column({ space: 6 }) {
            Row() {
              Text('系统盘').fontSize(tLabel).width(72)
              if (this.diskPath) {
                Column({ space: 2 }) {
                  Text(this.baseName(this.diskPath))
                    .fontSize(tSub)
                    .fontColor(cSub)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${this.diskFmt} · 虚拟${this.diskVirtualGB.toFixed(1)}G · 实占${this.diskActualGB.toFixed(1)}G`)
                    .fontSize(tMono)
                    .fontColor(cWeak)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Button('移除').focusable(false).fontSize(tBody)
                  .height(btnSh).borderRadius(rBtn).padding({ left: 10, right: 10 })
                  .backgroundColor(Color.Transparent).fontColor(cDanger)
                  .onClick(() => {
                    this.diskPath = '';
                    this.diskCreate = false;
                    this.diskFmt = '?';
                    this.diskVirtualGB = 0;
                    this.diskActualGB = 0;
                  })
              } else {
                Text('无').fontSize(tSub).fontColor(cSub).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.diskCreate })
                  .onChange((v: boolean) => this.diskCreate = v)
              }
            }
            if (!this.diskPath && this.diskCreate) {
              Row({ space: 8 }) {
                Text('分配方式').fontSize(tSub).fontColor(cSub)
                Text('动态分配').fontSize(tLabel)
                  .fontColor(this.diskAlloc === 'dynamic' ? cPrimary : Color.Black)
                  .onClick(() => this.diskAlloc = 'dynamic')
                Text('固定大小').fontSize(tLabel)
                  .fontColor(this.diskAlloc === 'fixed' ? cPrimary : Color.Black)
                  .onClick(() => this.diskAlloc = 'fixed')
              }
              Row({ space: 8 }) {
                Slider({ value: Math.max(0, DISK_SIZES.indexOf(this.diskGB)),
                  min: 0, max: DISK_SIZES.length - 1, step: 1 })
                  .layoutWeight(1)
                  .onChange((v: number) => this.diskGB = DISK_SIZES[Math.round(v)])
                Text(`${Math.round(this.diskGB)}GB`).fontSize(tLabel)
              }
              Text('保存时创建 ' + Math.round(this.diskGB) + 'GB ' +
                (this.diskAlloc === 'fixed' ? '固定大小' : '动态分配') + ' 系统盘')
                .fontSize(tBody)
                .fontColor(cRunning)
              if (this.diskAlloc === 'fixed') {
                Text('固定大小：保存时立即预留整块空间，大容量请优先动态分配')
                  .fontSize(tBody)
                  .fontColor(cWarn)
              }
            }
          }.alignItems(HorizontalAlign.Start).padding(12)
        }

        ListItem() {
          Column({ space: 6 }) {
            Row() {
              Text('光盘 ISO').fontSize(tLabel).width(72)
              Text(this.cdromPath ? this.baseName(this.cdromPath) : '无')
                .fontSize(tSub)
                .fontColor(cSub)
                .layoutWeight(1)
              if (this.cdromPath) {
                Button('移除').focusable(false).fontSize(tBody)
                  .height(btnSh).borderRadius(rBtn).padding({ left: 10, right: 10 })
                  .backgroundColor(Color.Transparent).fontColor(cDanger)
                  .onClick(() => this.cdromPath = '')
              }
            }
            if (!this.cdromPath) {
              Row({ space: 8 }) {
                TextInput({ placeholder: 'ISO 完整路径', text: this.cdromPath })
                  .layoutWeight(1)
                  .fontSize(tBody)
                  .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                  .onChange((v: string) => this.cdromPath = v)
                Button('内置 Alpine').focusable(false).fontSize(tBody)
                  .height(btnSh).borderRadius(rBtn).padding({ left: 10, right: 10 })
                  .onClick(() => {
                    const iso = this.vmDataDir + '/alpine-virt.iso';
                    if (pathExists(iso)) {
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
            Text('从光盘启动').fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bootFromCdrom })
              .onChange((v: boolean) => this.bootFromCdrom = v)
          }.padding(12)
        }

        ListItem() {
          Row() {
            Text('显卡').fontSize(tLabel).width(72)
            Select(VGA_OPTIONS.map((v: VgaType): SelectOption => {
              return { value: v };
            }))
              .value(this.vga)
              .selected(VGA_OPTIONS.indexOf(this.vga))
              .font({ size: tBody })
              .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).layoutWeight(1)
              .onSelect((index: number) => {
                this.vga = VGA_OPTIONS[index];
              })
          }.padding(12)
        }

        ListItem() {
          Row() {
            Text('网络').fontSize(tLabel).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.netEnabled })
              .onChange((v: boolean) => this.netEnabled = v)
          }.padding(12)
        }

        if (this.netEnabled) {
          ListItem() {
            Column({ space: 4 }) {
              Text('端口转发（宿主端口:客机端口，逗号分隔）').fontSize(tSub).fontColor(cSub)
              TextInput({ placeholder: '如 2222:22,8080:80', text: this.portForwards })
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.portForwards = v)
            }.alignItems(HorizontalAlign.Start).padding(12)
          }
          ListItem() {
            Column({ space: 4 }) {
              Row() {
                Text('9p 共享目录').fontSize(tLabel).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.sharedFolder })
                  .onChange((v: boolean) => this.sharedFolder = v)
              }.padding({ left: 0, right: 0 })
              Text('挂载宿主应用数据下 shared/ 到客机 /shared（9p）').fontSize(tSub).fontColor(cWeak)
            }.alignItems(HorizontalAlign.Start).padding({ left: 12, right: 12, bottom: 12 })
          }
        }

        ListItem() {
          Row() {
            Text(this.showAdvanced ? '▲ 高级选项' : '▼ 高级选项')
              .fontSize(tLabel)
              .fontColor(cPrimary)
              .layoutWeight(1)
          }
          .padding(12)
          .onClick(() => this.showAdvanced = !this.showAdvanced)
        }

        if (this.showAdvanced) {
          ListItem() {
            Row() {
              Text('TCG 多线程 (MTTCG)').fontSize(tLabel).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.mttcg })
                .onChange((v: boolean) => this.mttcg = v)
            }.padding(12)
          }
          ListItem() {
            Row() {
              Text('tb-size').fontSize(tLabel).width(96)
              TextInput({ text: this.tbSizeText })
                .layoutWeight(1)
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.tbSizeText = v)
            }.padding(12)
          }
          ListItem() {
            Column({ space: 4 }) {
              Text('自定义 qemu 参数（追加到命令行末尾）').fontSize(tSub).fontColor(cSub)
              TextArea({ placeholder: '如 -device usb-kbd', text: this.extraArgs })
                .fontSize(tBody)
                .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
                .onChange((v: string) => this.extraArgs = v)
            }.alignItems(HorizontalAlign.Start).padding(12)
          }
        }
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 1, color: cBorder })
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(cBg)
  }
}
