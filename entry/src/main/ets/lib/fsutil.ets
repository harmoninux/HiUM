/* 路径存在守卫：fs.accessSync 在文件不存在时抛异常，统一 try 包裹，
 * 避免列表/渲染/点击路径因失效媒体崩溃。所有「读一下盘在不在」都应走这里。 */
import { fileIo as fs } from '@kit.CoreFileKit';

export function pathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch {
    return false;
  }
}

/* 真实可读守卫：真 open(READ_ONLY) 并随即关闭，验证「能否真的读」。
 * accessSync 只是可访问性检查，可能对存在但读不了的路径返回 true（如受授权/沙箱限制），
 * 而真实 open 会 EPERM —— 启动前探 ISO 这类「能不能被 qemu 读」的场景必须用这个，
 * 否则会放行一个读不了的盘、把错误留给 qemu。 */
export function isoReadable(path: string): boolean {
  if (path.length === 0) {
    return false;
  }
  let f: fs.File | null = null;
  try {
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
  } catch {
    return false;
  }
  try {
    fs.closeSync(f);
  } catch {
    /* best effort */
  }
  return true;
}
