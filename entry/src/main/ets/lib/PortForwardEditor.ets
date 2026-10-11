/* 端口转发结构化编辑器：把「宿主端口:客机端口,逗号分隔」的裸文本升级为可增删的行
 * 列表（VmEdit 网络区与 VmWizard 网络步共用）。存储格式不变——序列化仍是同一条
 * 逗号分隔字符串（profile schema / buildArgs / forwardErrors 全部不动），本组件只是
 * 文本的编辑视图。
 * 语义约定：只有「两端都填完」的行才序列化生效（未填完的行留在界面上并灰字提示），
 * 这样逐字输入中途不会触发「端口需为整数」之类的假报错。
 * 历史档里手工改坏、解析不出 host:guest 的条目原样保留展示（红字 + 仅允许移除），
 * 不能让编辑器把用户的存量内容悄悄吃掉。 */

import { cDanger, cSub, cWeak, sp3, tBody, tItem, tSub, rBtn, btnSh, inpH, inpBg, inpRadius, inpPadX } from './uiTokens';
import { forwardErrors } from './vmprofile';

interface FwdRow {
  id: number;   /* 稳定 key：ForEach 复用节点，逐字输入不重建 TextInput（不丢焦点） */
  host: string;
  guest: string;
}

@Component
export struct PortForwardEditor {
  @Link text: string;
  @State rows: FwdRow[] = [];
  @State invalids: string[] = []; /* 存量非法条目（只展示 + 可移除） */
  private nextId: number = 0;

  aboutToAppear(): void {
    const rows: FwdRow[] = [];
    const invalids: string[] = [];
    for (const item of this.text.split(',')) {
      const s = item.trim();
      if (s.length === 0) {
        continue;
      }
      const kv = s.split(':');
      if (kv.length === 2 && /^\d+$/.test(kv[0].trim()) && /^\d+$/.test(kv[1].trim())) {
        rows.push({ id: this.nextId++, host: kv[0].trim(), guest: kv[1].trim() });
      } else {
        invalids.push(s);
      }
    }
    this.rows = rows;
    this.invalids = invalids;
  }

  /* 把当前行状态序列化回 @Link text（只收完整行；非法存量条目原样带上） */
  private commit(): void {
    const parts: string[] = [];
    for (const r of this.rows) {
      const h = r.host.trim();
      const g = r.guest.trim();
      if (h.length > 0 && g.length > 0) {
        parts.push(h + ':' + g);
      }
    }
    for (const s of this.invalids) {
      parts.push(s);
    }
    this.text = parts.join(',');
  }

  private setRow(idx: number, host: string, guest: string): void {
    const next: FwdRow[] = this.rows.slice();
    const r = next[idx];
    if (!r) {
      return;
    }
    next[idx] = { id: r.id, host: host, guest: guest };
    this.rows = next;
    this.commit();
  }

  private addRow(): void {
    this.rows = this.rows.concat([{ id: this.nextId++, host: '', guest: '' }]);
  }

  private removeRow(idx: number): void {
    const next: FwdRow[] = this.rows.slice();
    next.splice(idx, 1);
    this.rows = next;
    this.commit();
  }

  private removeInvalid(idx: number): void {
    const next: string[] = this.invalids.slice();
    next.splice(idx, 1);
    this.invalids = next;
    this.commit();
  }

  /* 既有校验器（宿主端口不重复等）直接复用：序列化后的 text 就是它的入参口径 */
  private errText(): string {
    if (this.text.trim().length === 0) {
      return '';
    }
    const errs = forwardErrors(this.text);
    return errs.length > 0 ? '端口转发：' + errs.join('；') : '';
  }

  build() {
    Column({ space: sp3 }) {
      if (this.rows.length === 0 && this.invalids.length === 0) {
        Text('暂无端口转发').fontSize(tSub).fontColor(cWeak).width('100%')
      }
      ForEach(this.rows, (r: FwdRow, idx: number) => {
        Row({ space: sp3 }) {
          TextInput({ text: r.host, placeholder: '宿主' })
            .type(InputType.Number)
            .width(84)
            .fontSize(tItem)
            .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
            .onChange((v: string) => this.setRow(idx, v, r.guest))
          Text(':').fontSize(tBody).fontColor(cSub)
          TextInput({ text: r.guest, placeholder: '客机' })
            .type(InputType.Number)
            .width(84)
            .fontSize(tItem)
            .height(inpH).borderRadius(inpRadius).backgroundColor(inpBg).padding({ left: inpPadX, right: inpPadX })
            .onChange((v: string) => this.setRow(idx, r.host, v))
          Text('→ 虚拟机').fontSize(tSub).fontColor(cWeak)
          Blank()
          Button('移除').focusable(false).fontSize(tItem)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.removeRow(idx))
        }.width('100%')
      }, (r: FwdRow) => r.id.toString())
      ForEach(this.invalids, (s: string, idx: number) => {
        Row({ space: sp3 }) {
          Text(`「${s}」格式无效`).fontSize(tSub).fontColor(cDanger).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('移除').focusable(false).fontSize(tItem)
            .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
            .backgroundColor(Color.Transparent).fontColor(cDanger)
            .onClick(() => this.removeInvalid(idx))
        }.width('100%')
      }, (s: string, idx: number) => `inv${idx}:${s}`)
      Row() {
        Button('添加一行').focusable(false).fontSize(tItem)
          .height(btnSh).borderRadius(rBtn).padding({ left: sp3, right: sp3 })
          .backgroundColor(Color.Transparent).fontColor(cSub)
          .onClick(() => this.addRow())
        Blank()
      }.width('100%')
      if (this.errText().length > 0) {
        Text(this.errText()).fontSize(tSub).fontColor(cDanger).width('100%')
      }
      Text('设备（宿主）端口 → 虚拟机内端口；两端都填完才生效，在电脑上用 localhost:宿主端口 访问')
        .fontSize(tSub).fontColor(cWeak).width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
