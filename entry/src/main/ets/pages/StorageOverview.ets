// 存储概览（Phase 0 收尾，MediaStore 只读侧）：跨所有 VM 的只读统计与告警。
// 宗旨：不建「集中镜像库」——磁盘、光盘仍是各自 VM 的资产（或共享的只读 ISO），
// 本页不改写任何 VM 媒体，只做：① 配额（各盘实占/虚拟合计）、② 每台 VM 的媒体体检、
// ③ 基础镜像（vm 目录里的共享 ISO，可被多台 VM 引用）。媒体引用但文件失效的，打 ⚠。
import { fileIo as fs } from '@kit.CoreFileKit';
import napiModule from 'libentry.so';
import { VmProfile, VmStore } from '../lib/vmprofile';

interface DiskNapi {
  diskInfo: (path: string) => string;
}

const napi = napiModule as DiskNapi;
const GB = 1024 * 1024 * 1024;
const MB = 1024 * 1024;

interface MediaStat {
  name: string;
  id: string;
  diskPath: string;
  diskActualGB: number;
  diskVirtualGB: number;
  diskOk: boolean;
  cdrom: string;
  cdromOk: boolean;
  missing: string; /* 空的 = 媒体完好 */
}

interface IsoEntry {
  name: string;
  sizeMB: number;
  refs: number; /* 多少台 VM 引用基名匹配的 ISO */
}

@Component
export struct StorageOverview {
  @Consume('navStack') navStack: NavPathStack;
  @StorageLink('vmDataDir') vmDataDir: string = '';
  @StorageLink('filesDir') filesDir: string = '';
  @StorageLink('vmListVersion') @Watch('reload') vmListVersion: number = 0;

  @State vms: MediaStat[] = [];
  @State isos: IsoEntry[] = [];
  @State totalActualGB: number = 0;
  @State totalVirtualGB: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private baseName(path: string): string {
    const i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  private mediaStat(p: VmProfile): MediaStat {
    const missing: string[] = [];
    let diskOk = true, diskVirtualGB = 0, diskActualGB = 0;
    if (p.media.diskPath.length > 0) {
      diskOk = fs.accessSync(p.media.diskPath);
      if (diskOk) {
        const s = napi.diskInfo(p.media.diskPath);
        if (s.length > 0) {
          try {
            const j = JSON.parse(s) as Record<string, number | string>;
            diskVirtualGB = ((typeof j['virtual-size'] === 'number' ? j['virtual-size'] as number : 0)) / GB;
            diskActualGB = ((typeof j['actual-size'] === 'number' ? j['actual-size'] as number : 0)) / GB;
          } catch {
            diskOk = false;
          }
        } else {
          diskOk = false;
        }
      }
      if (!diskOk) {
        missing.push('系统盘缺失');
      }
    }
    let cdromOk = true;
    if (p.media.cdromPath.length > 0) {
      cdromOk = fs.accessSync(p.media.cdromPath);
      if (!cdromOk) {
        missing.push('光盘缺失');
      }
    }
    const st: MediaStat = {
      name: p.name, id: p.id, diskPath: p.media.diskPath,
      diskActualGB, diskVirtualGB, diskOk,
      cdrom: p.media.cdromPath, cdromOk,
      missing: missing.join('、'),
    };
    return st;
  }

  private scanIsos(list: VmProfile[]): IsoEntry[] {
    const out: IsoEntry[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.vmDataDir);
    } catch {
      return out;
    }
    for (const n of names) {
      if (!n.toLowerCase().endsWith('.iso')) {
        continue;
      }
      let sizeMB = 0;
      try {
        const st = fs.statSync(this.vmDataDir + '/' + n);
        sizeMB = st.size / MB;
      } catch {
        sizeMB = 0;
      }
      let refs = 0;
      for (const p of list) {
        if (p.media.cdromPath.length > 0 && this.baseName(p.media.cdromPath) === n) {
          refs++;
        }
      }
      const e: IsoEntry = { name: n, sizeMB, refs };
      out.push(e);
    }
    out.sort((a, b) => b.sizeMB - a.sizeMB);
    return out;
  }

  private reload(): void {
    const store = new VmStore(this.filesDir);
    const list = store.list();
    const stats: MediaStat[] = [];
    let tAct = 0, tVir = 0;
    for (const p of list) {
      const st = this.mediaStat(p);
      stats.push(st);
      tAct += st.diskActualGB;
      tVir += st.diskVirtualGB;
    }
    this.vms = stats;
    this.totalActualGB = tAct;
    this.totalVirtualGB = tVir;
    this.isos = this.scanIsos(list);
  }

  /* 每台 VM 的媒体一行文本 */
  private mediaDesc(v: MediaStat): string {
    if (v.diskPath.length === 0 && v.cdrom.length === 0) {
      return '无媒体';
    }
    const parts: string[] = [];
    if (v.diskPath.length > 0) {
      parts.push(v.diskOk
        ? `系统盘 ${v.diskVirtualGB.toFixed(1)}G / 实占${v.diskActualGB.toFixed(1)}G`
        : '系统盘缺失');
    }
    if (v.cdrom.length > 0) {
      parts.push(v.cdromOk ? '光盘 ✓' : '光盘缺失');
    }
    return parts.join(' · ');
  }

  build() {
    Column() {
      Row() {
        Button('返回').focusable(false).fontSize(14).backgroundColor(Color.Transparent)
          .fontColor('#ff007dff')
          .onClick(() => this.navStack.pop())
        Blank()
        Text('存储概览').fontSize(18).fontWeight(FontWeight.Medium)
        Blank()
        Text(`${this.vms.length} 台 VM`).fontSize(13).fontColor('#ff666666')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          /* 配额总览 */
          Column({ space: 4 }) {
            Text('配额').fontSize(16).fontWeight(FontWeight.Medium)
            Text(`实占 ${this.totalActualGB.toFixed(2)} GB · 虚拟 ${this.totalVirtualGB.toFixed(2)} GB`)
              .fontSize(13)
              .fontColor('#ff666666')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .width('100%')
          .backgroundColor(Color.White)
          .borderRadius(8)

          /* 基础镜像（共享 ISO） */
          Column({ space: 4 }) {
            Text('基础镜像（共享 ISO）').fontSize(16).fontWeight(FontWeight.Medium)
            if (this.isos.length === 0) {
              Text('vm 目录下暂无 ISO').fontSize(12).fontColor('#ff999999')
            } else {
              ForEach(this.isos, (i: IsoEntry) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(i.name).fontSize(13)
                    Text(`${i.sizeMB.toFixed(1)} MB · ${i.refs} 台引用`).fontSize(11).fontColor('#ff999999')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.padding({ top: 4, bottom: 4 })
              }, (i: IsoEntry) => i.name)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .width('100%')
          .backgroundColor(Color.White)
          .borderRadius(8)

          /* 各 VM 媒体体检 */
          Column({ space: 4 }) {
            Text('媒体体检').fontSize(16).fontWeight(FontWeight.Medium)
            if (this.vms.length === 0) {
              Text('暂无虚拟机').fontSize(12).fontColor('#ff999999')
            } else {
              ForEach(this.vms, (v: MediaStat) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Row({ space: 6 }) {
                      Text(v.name).fontSize(14)
                      if (v.missing.length > 0) {
                        Text('⚠ ' + v.missing).fontSize(11).fontColor(Color.Red)
                      }
                    }
                    Text(this.mediaDesc(v)).fontSize(11).fontColor('#ff999999')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.padding({ top: 5, bottom: 5 })
              }, (v: MediaStat) => v.id)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .width('100%')
          .backgroundColor(Color.White)
          .borderRadius(8)
        }
        .width('100%')
        .padding(12)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#fff2f3f5')
  }
}
