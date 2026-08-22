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
