/* 缩略图缓存读取：8 字节小端宽高头 + 裸 RGBA_8888 → PixelMap。
 * VmConsole 运行期抓帧写入（见其 captureThumb），VmManage / VmList 共读——
 * 格式两端必须一致（同 vmprofile.thumbPath 的注释约定）。 */
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { pathExists } from './fsutil';

export interface Thumb {
  px: image.PixelMap;
  w: number;
  h: number;
}

export function loadThumb(path: string): Thumb | null {
  if (!pathExists(path)) {
    return null;
  }
  try {
    const size = fs.statSync(path).size;
    if (size < 16) {
      return null;
    }
    const buf = new ArrayBuffer(size);
    const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const n = fs.readSync(f.fd, buf);
    fs.closeSync(f);
    const dv = new DataView(buf);
    const w = dv.getUint32(0, true);
    const h = dv.getUint32(4, true);
    const need = 8 + w * h * 4;
    if (w <= 0 || h <= 0 || need > n) {
      return null;
    }
    const opts: image.InitializationOptions = {
      size: { width: w, height: h },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false,
    };
    return { px: image.createPixelMapSync(buf.slice(8, need), opts), w, h };
  } catch {
    return null;
  }
}
