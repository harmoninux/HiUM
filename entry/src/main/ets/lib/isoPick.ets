// 光盘 ISO 的「本机文件」来源：拉起系统文档选择器选一个 .iso，解析成 qemu 可 fopen 的真实路径。
// 选择器返回的是 grant-scoped URI（授权临时生效），不是可直接 fopen 的裸路径——必须转真实路径并当场校验。
// 用户已两次确认「原地引用外部路径」：不拷贝进应用存储，直接引用解析出的路径。路径失效（重启后无授权/
// 文件被挪/拔出）由启动失败时的 qemu-<id>.log 弹窗兜底（VmConsole.failStart），此处不做拷贝。
import { picker, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { isoReadable } from './fsutil';

/* 拉起文档选择器选 1 个 .iso，返回真实文件路径；取消 / 解析失败 / 文件不可读返回 ''。
 * 本 SDK 的 fileUri 无 getPathFromUri，用 EntryAbility:39-42 已验证的 new fileUri.FileUri(uri).path 取真实路径。 */
export function pickIsoPath(ctx: common.UIAbilityContext): Promise<string> {
  return new Promise<string>((resolve) => {
    const dp = new picker.DocumentViewPicker(ctx);
    dp.select({ maxSelectNumber: 1, fileSuffixFilters: ['.iso'] })
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
