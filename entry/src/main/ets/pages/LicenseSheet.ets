// 开源许可弹窗（设置 → 关于 → 开源许可「详情」）：应用协议 + 随包第三方组件清单。
// 清单与仓库 THIRD-PARTY.md 同源维护——改这里必同步那边（分发事实的唯一依据在
// entry/libs/ 实际打进去的 .so）。

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SecHead } from '../lib/uiWidgets';
import { sp1, sp3, sp4, sp5, tSub, tItem, tLabel, cWeak, cSub, cText } from '../lib/uiTokens';

const DOMAIN = 0x0001;
const TAG = 'QemuUI';

/* 随包分发的动态库（依据 entry/libs/ 实际内容；上游链接点击整行打开） */
interface OpenSourceItem {
  name: string;
  license: string;
  url: string;
}

const OPEN_SOURCES: OpenSourceItem[] = [
  { name: 'QEMU', license: 'GPL-2.0', url: 'https://gitlab.com/qemu-project/qemu' },
  { name: 'libslirp', license: 'BSD-3-Clause', url: 'https://gitlab.com/qemu-project/libslirp' },
  { name: 'zlib', license: 'zlib', url: 'https://zlib.net' },
  { name: 'pcre2', license: 'BSD-3-Clause', url: 'https://github.com/PCRE2Project/pcre2' },
];

@Component
export struct LicenseSheet {
  private open(url: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.openLink(url).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'license openLink: %{public}s', JSON.stringify(e));
    });
  }

  build() {
    Scroll() {
      Column({ space: sp4 }) {
        Text('HiUM 以 GPL-2.0 发布').fontSize(tLabel)
        Text('本应用是自由软件：你可以在 GPL-2.0 协议下重新分发和/或修改它。完整协议文本见仓库根 LICENSE 文件（https://github.com/harmoninux/HiUM）。')
          .fontSize(tSub).fontColor(cSub).width('100%')

        SecHead({ label: '随包第三方组件' })
        Column({ space: sp3 }) {
          ForEach(OPEN_SOURCES, (o: OpenSourceItem) => {
            Column({ space: sp1 }) {
              Row({ space: sp3 }) {
                Text(o.name).fontSize(tItem).fontColor(cText)
                  .layoutWeight(1).maxLines(1)
                Text(o.license).fontSize(tSub).fontColor(cSub)
              }.width('100%')
              Text(o.url).fontSize(tSub).fontColor(cWeak)
                .width('100%').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .onClick(() => this.open(o.url))
          }, (o: OpenSourceItem) => o.name)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Text('glib、pixman 等以静态方式编入 QEMU，不单独分发；完整声明见仓库 THIRD-PARTY.md。内置 Alpine 镜像为运行时按需下载，不随包分发。')
          .fontSize(tSub).fontColor(cWeak).width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: sp5, right: sp5, top: sp4, bottom: sp4 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart) /* Scroll 默认居中：内容不足一屏时吊在半空（2026-10-17 打回） */
  }
}
