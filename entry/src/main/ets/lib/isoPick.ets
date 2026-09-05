// 本机文件选择：拉起系统文档选择器，解析成 qemu 可 fopen 的真实路径。
// 选择器返回的是 grant-scoped URI（授权临时生效），不是可直接 fopen 的裸路径——必须转真实路径并当场校验。
// ISO 按用户确认的「原地引用外部路径」：不拷贝进应用存储，路径失效由启动失败时的
// qemu-<id>.log 弹窗兜底（VmConsole.failStart）。
// 系统盘镜像 / 内核则按需求「复制进虚拟机目录」（见 VmWizard.finish → prepareMedia），
// 复制动作发生在选择之后，选择本身仍只是拿一个可读真实路径。
import { picker, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { isoReadable } from './fsutil';

/* 拉起文档选择器选 1 个文件，返回真实文件路径；取消 / 解析失败 / 文件不可读返回 ''。
 * suffixes 为空数组 = 不过滤后缀（内核文件无固定扩展名：vmlinuz/bzImage/Image…）。
 * 本 SDK 的 fileUri 无 getPathFromUri，用 EntryAbility 已验证的 new fileUri.FileUri(uri).path 取真实路径。 */
export function pickFilePath(ctx: common.UIAbilityContext, suffixes: string[]): Promise<string> {
  return new Promise<string>((resolve) => {
    const dp = new picker.DocumentViewPicker(ctx);
    const opts: picker.DocumentSelectOptions = { maxSelectNumber: 1 };
    if (suffixes.length > 0) {
      opts.fileSuffixFilters = suffixes;
    }
    dp.select(opts)
      .then((uris: string[]) => {
        if (uris.length === 0) {
          resolve('');
          return;
        }
        let p = '';
        try {
          p = new fileUri.FileUri(uris[0]).path;
        } catch {
          p = '';
        }
        if (p.length === 0 || !isoReadable(p)) {
          p = '';
        }
        resolve(p);
      })
      .catch(() => resolve(''));
  });
}

/* 选 1 个 .iso（原地引用场景），语义同旧版 */
export function pickIsoPath(ctx: common.UIAbilityContext): Promise<string> {
  return pickFilePath(ctx, ['.iso']);
}
