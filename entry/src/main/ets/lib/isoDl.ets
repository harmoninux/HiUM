// 内置系统盘（Alpine ISO）按需下载：国内镜像优先。
// builtinIsoFor(vmprofile) 负责「文件名 ↔ 架构」；本模块负责「文件不存在则从镜像站拉取」。
// 用 @ohos.net.http 流式 GET 分段写入（@ohos.request.downloadFile 在目标环境报 undefined(8) 弃用）。
// 进度由已知镜像大小估算；dataEnd 即完成。失败按镜像顺序回退（tuna → ustc）。
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VmArch, builtinIsoFor } from './vmprofile';

const DOMAIN = 0x0100;
const TAG = 'IsoDl';

/* 国内优先镜像（按序尝试）；国际 dl-cdn 在国内连不上，不列 */
const MIRRORS: string[] = [
  'https://mirrors.tuna.tsinghua.edu.cn',
  'https://mirrors.ustc.edu.cn',
];

/* 每架构：Alpine 镜像目录 / 镜像种 / 版本 / 版本主次 / 约大小(MB)。
 * 镜像站目录名与 VmArch 不完全一致（x86→i386、armv7→arm）；riscv64 官方 v3.23 才有标准镜像。 */
interface IsoSpec { dir: string; kind: string; ver: string; rel: string; sizeMB: number; }

function specFor(arch: VmArch): IsoSpec | null {
  switch (arch) {
    case 'x86_64': return { dir: 'x86_64', kind: 'alpine-virt', ver: '3.21.3', rel: '3.21', sizeMB: 63 };
    case 'i386': return { dir: 'x86', kind: 'alpine-virt', ver: '3.21.3', rel: '3.21', sizeMB: 48 };
    case 'aarch64': return { dir: 'aarch64', kind: 'alpine-virt', ver: '3.21.3', rel: '3.21', sizeMB: 75 };
    case 'arm': return { dir: 'armv7', kind: 'alpine-virt', ver: '3.21.3', rel: '3.21', sizeMB: 46 };
    case 'loongarch64': return { dir: 'loongarch64', kind: 'alpine-standard', ver: '3.21.3', rel: '3.21', sizeMB: 98 };
    case 'riscv64': return { dir: 'riscv64', kind: 'alpine-standard', ver: '3.23.5', rel: '3.23', sizeMB: 52 };
    default: return null;
  }
}

/* 单个镜像站下该架构的完整下载 URL */
function urlFor(arch: VmArch, mirror: string): string {
  const s = specFor(arch);
  return `${mirror}/alpine/v${s!.rel}/releases/${s!.dir}/${s!.kind}-${s!.ver}-${s!.dir}.iso`;
}

/* 从指定镜像流式下载到 dst；onProgress 回调 0..100。成功返回 true。
 * @ohos.http 无需 context；进度用已知镜像大小估算，dataEnd 即完成。 */
function downloadFrom(dst: string, url: string, sizeMB: number, onProgress?: (pct: number) => void): Promise<boolean> {
  hilog.info(DOMAIN, TAG, 'http download start: %{public}s -> %{public}s', url, dst);
  const sizeBytes = sizeMB * 1024 * 1024;
  return new Promise<boolean>((resolve) => {
    let fd = -1;
    try {
      fd = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'open dst fail: %{public}s', JSON.stringify(err));
      resolve(false);
      return;
    }
    const httpReq = http.createHttp();
    let received = 0;
    httpReq.on('dataReceive', (data: ArrayBuffer) => {
      received += data.byteLength;
      try {
        fs.writeSync(fd, data);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'write fail: %{public}s', JSON.stringify(err));
      }
      const pct = sizeBytes > 0 ? Math.min(100, Math.floor(received / sizeBytes * 100)) : 0;
      hilog.debug(DOMAIN, TAG, 'progress %{public}d/%{public}d (%{public}d%%)', received, sizeBytes, pct);
      onProgress?.(pct);
    });
    httpReq.on('dataEnd', () => {
      try {
        fs.closeSync(fd);
      } catch {
        /* best effort */
      }
      httpReq.destroy();
      hilog.info(DOMAIN, TAG, 'http download complete: %{public}s (%{public}d bytes)', dst, received);
      resolve(true);
    });
    httpReq.requestInStream(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 15000,
      readTimeout: 120000,
    }, (err: BusinessError, code: number) => {
      if (err) {
        hilog.warn(DOMAIN, TAG, 'requestInStream err: %{public}s', err.code + ' ' + err.message);
        try {
          fs.closeSync(fd);
        } catch {
          /* best effort */
        }
        httpReq.destroy();
        resolve(false);
        return;
      }
      /* 正常结束：dataEnd 已触发 resolve(true)，此处不再重复 */
    });
  });
}

/* 确保 vmdir 下该架构内置 iso 存在；缺失则按镜像顺序下载到 vmdir/<builtinIsoFor(arch)>。
 * 进度经 onProgress(0..100) 上报。返回 true 表示文件已就绪。
 * @param ctx 兼容旧签名（@ohos.http 实际不使用），保留避免多处调用点改动。 */
export function ensureBuiltinIso(
  _ctx: common.UIAbilityContext,
  vmDataDir: string,
  arch: VmArch,
  onProgress?: (pct: number) => void,
): Promise<boolean> {
  const name = builtinIsoFor(arch);
  const s = specFor(arch);
  if (name.length === 0 || !s) {
    return Promise.resolve(false);
  }
  const dst = vmDataDir + '/' + name;
  try {
    if (fs.accessSync(dst) && fs.statSync(dst).size > 0) {
      return Promise.resolve(true); /* 已有，无需下载 */
    }
  } catch {
    /* 尚未下载 */
  }
  hilog.info(DOMAIN, TAG, 'downloading %{public}s for %{public}s', name, arch);
  return (async () => {
    for (const m of MIRRORS) {
      const ok = await downloadFrom(dst, urlFor(arch, m), s.sizeMB, onProgress);
      if (ok) {
        return true;
      }
    }
    return false;
  })();
}
