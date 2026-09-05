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

/* 复制文件（内部复制固件模板 VARS → 每 VM 可写 VARS）。目标已存在则跳过；
 * 源缺失/复制失败返回 false，不抛。 */
export function copyFile(src: string, dst: string): boolean {
  try {
    if (!fs.accessSync(src)) { return false; }
    if (fs.accessSync(dst)) { return true; } /* 已存在，视为已就绪 */
    const inFd = fs.openSync(src, fs.OpenMode.READ_ONLY);
    const outFd = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    const buf = new ArrayBuffer(4 * 1024 * 1024);
    let n = 0;
    do {
      n = fs.readSync(inFd.fd, buf);
      if (n > 0) {
        /* 不传 options.offset（它是绝对文件位置，传 0 会每块都覆盖回首字节，
         * >4MB 文件只剩首块）；缺省从当前 filePointer 写，天然顺序追加 */
        fs.writeSync(outFd.fd, buf.slice(0, n));
      }
    } while (n > 0);
    fs.closeSync(inFd);
    fs.closeSync(outFd);
    return true;
  } catch {
    return false;
  }
}

/* 文件大小（字节）；不存在/不可读返回 -1 */
export function fileSizeOf(path: string): number {
  try {
    return fs.statSync(path).size;
  } catch {
    return -1;
  }
}

/* 读 path 在 offset 处的 len 个字节并按 ASCII 返回（用于校验文件头 magic）；
 * 任何失败返回 ''。 */
export function readAsciiAt(path: string, offset: number, len: number): string {
  let f: fs.File | null = null;
  try {
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(len);
    const n = fs.readSync(f.fd, buf, { offset: offset, length: len });
    let s = '';
    const u8 = new Uint8Array(buf, 0, n);
    for (const b of u8) {
      s += String.fromCharCode(b);
    }
    return s;
  } catch {
    return '';
  } finally {
    if (f) {
      try { fs.closeSync(f); } catch { /* best effort */ }
    }
  }
}

/* 带进度的异步复制（导入磁盘镜像/内核到虚拟机目录）：4MB 分块，块间让出
 * 事件循环（UI 可刷新进度）；失败清理半成品并 resolve(false)。
 * 与 copyFile 语义不同：目标已存在照样覆盖（导入是显式动作，目标路径按新 id 生成不会撞）。 */
export function copyFileWithProgress(src: string, dst: string,
  onProgress: (pct: number) => void): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    let total = 0;
    try {
      total = fs.statSync(src).size;
    } catch {
      resolve(false);
      return;
    }
    let inFd: fs.File | null = null;
    let outFd: fs.File | null = null;
    try {
      inFd = fs.openSync(src, fs.OpenMode.READ_ONLY);
      outFd = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    } catch {
      resolve(false);
      return;
    }
    const buf = new ArrayBuffer(4 * 1024 * 1024);
    let done = 0;
    const step = (): void => {
      try {
        const n = fs.readSync(inFd!.fd, buf);
        if (n > 0) {
          fs.writeSync(outFd!.fd, buf.slice(0, n)); /* 同上：不传 offset，顺序追加 */
          done += n;
          onProgress(total > 0 ? Math.min(99, Math.round(done * 100 / total)) : 0);
          setTimeout(step, 0); /* 让出事件循环，进度条/按钮态可刷新 */
          return;
        }
        fs.closeSync(inFd!);
        fs.closeSync(outFd!);
        onProgress(100);
        resolve(true);
      } catch {
        try { fs.closeSync(inFd!); } catch { /* best effort */ }
        try { fs.closeSync(outFd!); } catch { /* best effort */ }
        try { fs.unlinkSync(dst); } catch { /* 不留半成品 */ }
        resolve(false);
      }
    };
    step();
  });
}
