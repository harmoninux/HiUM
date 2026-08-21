// 虚拟机列表页（首页）：卡片 + 新建/编辑/删除/启动。
// VM 单实例运行：同一时间只允许一台 VM 处于 running。
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import napiModule from 'libentry.so';
import {
  VmProfile, VmStore,
  newProfileId, blankProfile, alpineProfile,
} from '../lib/vmprofile';

interface VmRunningNapi {
  vmRunning: () => boolean;
}

const napi = napiModule as VmRunningNapi;

@Component
export struct VmList {
  @Consume('navStack') navStack: NavPathStack;
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('firmwareReady') firmwareReady: boolean = false;
  @StorageLink('runningVmId') runningVmId: string = '';
  @StorageLink('vmListVersion') @Watch('reload') vmListVersion: number = 0;
  @State profiles: VmProfile[] = [];
  @State thumbTick: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private store(): VmStore {
    return new VmStore(this.filesDir);
  }

  private reload(): void {
    const store = this.store();
    let list = store.list();
    if (list.length === 0 && this.firmwareReady) {
      /* 首次使用：内置 Alpine 预设，开箱即用 */
      const seed = alpineProfile(newProfileId(), this.vmDataDir);
      store.save(seed);
      list = [seed];
    }
    this.profiles = list;
    this.thumbTick++;
  }

  private isRunning(p: VmProfile): boolean {
    return this.runningVmId === p.id && napi.vmRunning();
  }

  private openConsole(p: VmProfile): void {
    const runningElsewhere = napi.vmRunning() && this.runningVmId !== p.id;
    if (runningElsewhere) {
      promptAction.showToast({ message: '已有虚拟机在运行，请先关闭它' });
      return;
    }
    this.navStack.pushPath({ name: 'console', param: p });
  }

  private confirmDelete(p: VmProfile): void {
    if (this.isRunning(p)) {
      promptAction.showToast({ message: '运行中的虚拟机不能删除' });
      return;
    }
    AlertDialog.show({
      title: '删除虚拟机',
      message: `将删除「${p.name}」的配置、封面及本应用内创建的磁盘镜像，确认？`,
      primaryButton: {
        value: '取消',
        action: () => {},
      },
      secondaryButton: {
        value: '删除',
        fontColor: Color.Red,
        action: () => {
          this.store().remove(p);
          this.reload();
        },
      },
    });
  }

  @Builder
  thumb(p: VmProfile) {
    if (fs.accessSync(this.store().thumbPath(p.id))) {
      Image('file://' + this.store().thumbPath(p.id))
        .width(96)
        .height(60)
        .objectFit(ImageFit.Cover)
        .borderRadius(4)
    } else {
      Column() {
        Text(p.arch)
          .fontSize(11)
          .fontColor(Color.White)
      }
      .width(96)
      .height(60)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#ff334455')
      .borderRadius(4)
    }
  }

  @Builder
  cardMenu(p: VmProfile) {
    Column({ space: 4 }) {
      Button('编辑').focusable(false).width('100%')
        .onClick(() => this.navStack.pushPath({ name: 'edit', param: p }))
      Button('删除').focusable(false).width('100%')
        .fontColor(Color.Red)
        .onClick(() => this.confirmDelete(p))
    }
    .width(120)
    .padding(8)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  vmCard(p: VmProfile) {
    Row({ space: 10 }) {
      this.thumb(p)
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(p.name).fontSize(16).fontWeight(FontWeight.Medium)
          if (this.isRunning(p)) {
            Text('运行中').fontSize(11).fontColor('#ff2e7d32')
          }
        }
        Text(`${p.arch} · ${p.memoryMB}MB · ${p.cpus}核` +
          (p.cdromPath ? ' · 光盘' : '') + (p.diskPath ? ' · 磁盘' : ''))
          .fontSize(12)
          .fontColor('#ff666666')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.isRunning(p) ? '进入' : '启动')
        .focusable(false)
        .fontSize(13)
        .onClick(() => this.openConsole(p))
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Color.White)
    .borderRadius(8)
    .onClick(() => this.openConsole(p))
    .bindContextMenu(this.cardMenu(p), ResponseType.LongPress)
  }

  build() {
    Column() {
      Row() {
        Text('虚拟机').fontSize(24).fontWeight(FontWeight.Bold)
        Blank()
        Button('+ 新建')
          .focusable(false)
          .fontSize(14)
          .onClick(() => {
            this.navStack.pushPath({ name: 'edit', param: blankProfile(newProfileId()) });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (!this.firmwareReady) {
        Text('固件未就绪（需先 make deps 并重新打包）')
          .fontSize(13)
          .fontColor(Color.Red)
          .padding(16)
      }

      List({ space: 10 }) {
        ForEach(this.profiles, (p: VmProfile) => {
          ListItem() {
            this.vmCard(p)
          }
        }, (p: VmProfile) => p.id + ':' + this.thumbTick)
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#fff2f3f5')
  }
}
