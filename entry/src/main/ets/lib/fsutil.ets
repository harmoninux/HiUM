/* 路径存在守卫：fs.accessSync 在文件不存在时抛异常，统一 try 包裹，
 * 避免列表/渲染/点击路径因失效媒体崩溃。所有「读一下盘在不在」都应走这里。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import taskpool from '@ohos.taskpool';

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

/* 读文件尾部至多 maxBytes 字节（UTF-8 解码）。专供 qemu 日志诊断：日志会涨到
 * GB 级（启动失败时实测 38MB/s），按整文件大小 new ArrayBuffer 会直接 OOM，
 * 必须只取尾部。offset>0 时首行可能是被截断的残片（多字节字符也会被切），丢弃。
 * 任何失败返回 ''。 */
export function readTail(path: string, maxBytes: number): string {
  let f: fs.File | null = null;
  try {
    const size = fs.statSync(path).size;
    if (size <= 0 || maxBytes <= 0) {
      return '';
    }
    const len = Math.min(size, maxBytes);
    const offset = size - len;
    f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(len);
    const n = fs.readSync(f.fd, buf, { offset: offset, length: len });
    const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, n));
    if (offset === 0) {
      return text;
    }
    const nl = text.indexOf('\n');
    return nl >= 0 ? text.substring(nl + 1) : text;
  } catch {
    return '';
  } finally {
    if (f) {
      try { fs.closeSync(f); } catch { /* best effort */ }
    }
  }
}

/* ---- 子线程分块复制（taskpool）----
 * 复制逻辑整体搬入 taskpool 子线程：主线程同步搬运 GB 级 qcow2 时会反复钉住 UI
 *（克隆 6~9GB 系统盘实测整体卡死），子线程里连续 read/write 不再需要让出事件循环。
 * @Concurrent 必须是顶层函数；本模块依赖仅 fileIo/util/taskpool（无 UI 装饰器），
 * 子线程解析安全（子线程解析到 @Observed/AppStorage 等 UI 装饰器会抛异常，
 * @Concurrent 所在模块必须避开 UI 依赖——官方 TaskPool 使用规范）。
 * 进度只在整数百分比变化时经 sendData 回传（≤100 条消息），避免高频消息+宿主重绘。 */
@Concurrent
function copyFileTask(src: string, dst: string): boolean {
  let total = 0;
  try {
    total = fs.statSync(src).size;
  } catch {
    return false;
  }
  let inFd: fs.File | null = null;
  let outFd: fs.File | null = null;
  try {
    inFd = fs.openSync(src, fs.OpenMode.READ_ONLY);
    outFd = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  } catch {
    if (inFd !== null) {
      try { fs.closeSync(inFd); } catch { /* best effort */ }
    }
    if (outFd !== null) {
      try { fs.closeSync(outFd); } catch { /* best effort */ }
    }
    return false;
  }
  const buf = new ArrayBuffer(4 * 1024 * 1024);
  let done = 0;
  let lastPct = 0;
  try {
    for (;;) {
      const n = fs.readSync(inFd.fd, buf);
      if (n <= 0) {
        break;
      }
      /* 不传 options.offset（它是绝对文件位置，传 0 会每块都覆盖回首字节，
       * >4MB 文件只剩首块）；缺省从当前 filePointer 写，天然顺序追加 */
      fs.writeSync(outFd.fd, buf.slice(0, n));
      done += n;
      const pct = total > 0 ? Math.min(99, Math.floor(done * 100 / total)) : 0;
      if (pct !== lastPct) {
        lastPct = pct;
        try {
          taskpool.Task.sendData(pct);
        } catch {
          /* 宿主未注册回调：进度丢弃，不影响复制 */
        }
      }
    }
  } catch {
    try { fs.closeSync(inFd); } catch { /* best effort */ }
    try { fs.closeSync(outFd); } catch { /* best effort */ }
    try { fs.unlinkSync(dst); } catch { /* 不留半成品 */ }
    return false;
  }
  try { fs.closeSync(inFd); } catch { /* best effort */ }
  try { fs.closeSync(outFd); } catch { /* best effort */ }
  try {
    taskpool.Task.sendData(100);
  } catch {
    /* 进度丢失不影响结果 */
  }
  return true;
}

/* 带进度的异步复制（导入磁盘镜像/克隆大盘）。执行在 taskpool 子线程（见 copyFileTask）。
 * 失败清理半成品并 resolve(false)。与 copyFile 语义不同：目标已存在照样覆盖
 *（导入/克隆是显式动作，目标路径按新 id 生成不会撞）。 */
export function copyFileWithProgress(src: string, dst: string,
  onProgress: (pct: number) => void): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    try {
      const task = new taskpool.Task(copyFileTask, src, dst);
      task.onReceiveData((pct: number) => {
        onProgress(pct);
      });
      taskpool.execute(task).then((r: Object) => {
        resolve(r as boolean);
      }).catch(() => {
        /* 任务框架级失败（调度/序列化，任务体未跑或半途终止）：兜底清一次半成品 */
        try { fs.unlinkSync(dst); } catch { /* 未创建即无事 */ }
        resolve(false);
      });
    } catch {
      resolve(false);
    }
  });
}
