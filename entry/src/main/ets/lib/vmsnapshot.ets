// 快照引擎：对单台 VM 系统盘做 qemu-img 内部快照（qcow2 专属，离线操作）。
// 快照是磁盘自身状态，必须停下 VM 才能改盘（运行中盘被 qemu 锁定会失败）。
// 本模块是 napi 的类型化封装 + 快照列表的解析层。
//
// 注意：qemu-img 10.x 的 `snapshot -l` 不支持 --output=json，但 `info --output=json`
// （即 diskInfo 用的那条）里带一个 `snapshots` 数组 —— 列表就从它解析。
// 页面用已有的 napi.diskInfo(path) 拿原始 JSON，交给 parseSnapshots。
import napiModule from 'libentry.so';

interface SnapshotNapi {
  snapshotCreate: (path: string, name: string) => number;
  snapshotApply: (path: string, name: string) => number;
  snapshotDelete: (path: string, name: string) => number;
}

const napi = napiModule as SnapshotNapi;

export interface VmSnapshotEntry {
  id: string;      /* qemu 内部序号（显示用） */
  name: string;    /* 快照名（回滚/删除按此定位） */
  vmStateSize: number; /* 快照占的字节数 */
  dateSec: number; /* UTC 秒（显示用） */
}

/* 从 qemu-img info --output=json 的原始文本里解析快照数组。
 * 有快照时 JSON 顶层有 `snapshots: [...]`；快照为空时该键缺席 → 返回空数组。
 * ArkTS 禁 any/unknown、禁对接口字段下标 → 一律 Record<string, Object> + typeof 窄化。 */
export function parseSnapshots(json: string): VmSnapshotEntry[] {
  const out: VmSnapshotEntry[] = [];
  if (json.length === 0) {
    return out;
  }
  let obj: Object;
  try {
    obj = JSON.parse(json) as Object;
  } catch {
    return out;
  }
  const ro = obj as Record<string, Object>;
  const s = ro['snapshots'];
  if (!Array.isArray(s)) {
    return out;
  }
  for (const item of s as Object[]) {
    const rec = item as Record<string, Object>;
    const id = rec['id'];
    const name = rec['name'];
    const e: VmSnapshotEntry = {
      id: typeof id === 'string' ? id as string : (typeof id === 'number' ? String(id) : ''),
      name: typeof name === 'string' ? name as string : '',
      vmStateSize: typeof rec['vm-state-size'] === 'number' ? rec['vm-state-size'] as number : 0,
      dateSec: typeof rec['date-sec'] === 'number' ? rec['date-sec'] as number : 0,
    };
    if (e.name.length > 0 || e.id.length > 0) {
      out.push(e);
    }
  }
  return out;
}

export function snapshotCreate(path: string, name: string): number {
  return napi.snapshotCreate(path, name);
}

export function snapshotApply(path: string, name: string): number {
  return napi.snapshotApply(path, name);
}

export function snapshotDelete(path: string, name: string): number {
  return napi.snapshotDelete(path, name);
}
