// VMRegistry：运行态权威源的 ArkUI 反应式投影 + 生命周期事件总线。
// native（ncp_client）是运行态的最终权威（按 vmId 各管一个 NCP 子进程）；
// Wrapper 把它聚合成一份可被 AppStorage 反应式追踪的 runningMap，页面用
// @StorageLink('runningMap') 订阅「运行中」徽标，无需各自轮询 napi.vmRunning。
// 生命周期事件：refresh 时做上一帧对比，VM 由跑变停（或反过来）时
// emit 一次 vmExited / vmStarted，方便页面即时反应（如清理缩略图 / 关窗）。
//
// 类型约定：AppStorage 存 Record<string, Object>（每个值是 {running,w,h}），
// 读取时用 typeof 窄化再组装成 VmRun —— ArkTS 禁 any/unknown、禁对接口字段
// 下标访问，动态 key 一律走 Record + typeof（同 VmManage 的 diskInfo 解析）。
import napiModule from 'libentry.so';

interface VmSnapshotNapi {
  vmSnapshot: (vmIds: string[]) => Object;
}

const napi = napiModule as VmSnapshotNapi;

export interface VmRun {
  running: boolean;
  w: number;
  h: number;
}

export interface VmDisplay {
  w: number;
  h: number;
}

export interface VmLifecycleEvent {
  vmId: string;
  running: boolean;
}

type LifecycleListener = (evt: VmLifecycleEvent) => void;

const lifecycle: LifecycleListener[] = [];
let prevMap: Record<string, Object> = {}; /* diff 用；本帧未知运行态的 vmId 视为停 */
let primed = false; /* 首帧只记录不 diff，避免「全部 started」误报 */
let initialized = false;

const EMPTY: Record<string, Object> = {};

/* 把 native 传回的一个 {running,w,h} 对象窄化成 VmRun */
function runFrom(o: Object): VmRun {
  const so = o as Record<string, Object>;
  return {
    running: typeof so['running'] === 'boolean' ? so['running'] as boolean : false,
    w: typeof so['w'] === 'number' ? so['w'] as number : 0,
    h: typeof so['h'] === 'number' ? so['h'] as number : 0,
  };
}

/* 从 dynamic map 里取某 vmId 是否运行：元素可能缺失，一律 typeof 窄化 */
function isRunningEntry(map: Record<string, Object>, id: string): boolean {
  const e = map[id];
  if (typeof e === 'undefined') {
    return false;
  }
  return runFrom(e).running;
}

/** 进程级幂等初始化：保证 AppStorage('runningMap') 存在（值可为空 map）。 */
export function initVmRegistry(): void {
  if (initialized) {
    return;
  }
  initialized = true;
  if (AppStorage.get<Record<string, Object>>('runningMap') === undefined) {
    AppStorage.setOrCreate('runningMap', EMPTY);
  }
}

/** 订阅 VM 生命周期变化（started/exited）。页面销毁时用退订。 */
export function subscribeVmLifecycle(cb: LifecycleListener): void {
  if (lifecycle.indexOf(cb) < 0) {
    lifecycle.push(cb);
  }
}

export function unsubscribeVmLifecycle(cb: LifecycleListener): void {
  const i = lifecycle.indexOf(cb);
  if (i >= 0) {
    lifecycle.splice(i, 1);
  }
}

/** 当前反应式快照里某台 VM 是否运行（无该 vmId 视为未运行）。 */
export function vmIsRunning(vmId: string): boolean {
  const map = AppStorage.get<Record<string, Object>>('runningMap') ?? EMPTY;
  const st = map[vmId];
  if (typeof st === 'undefined') {
    return false;
  }
  return runFrom(st).running;
}

/** 当前反应式快照里某台 VM 的 guest 分辨率；未运行返回 0x0。 */
export function vmDisplay(vmId: string): VmDisplay {
  const map = AppStorage.get<Record<string, Object>>('runningMap') ?? EMPTY;
  const st = map[vmId];
  if (typeof st === 'undefined') {
    const zero: VmDisplay = { w: 0, h: 0 };
    return zero;
  }
  const r = runFrom(st);
  const d: VmDisplay = { w: r.w, h: r.h };
  return d;
}

/** 一次批量查询（一次 IPC 聚合 N 台 VM），更新 AppStorage 反应式地图并 diff 发事件。 */
export function refreshRunningMap(vmIds: string[]): void {
  const snapshot = napi.vmSnapshot(vmIds) as Object;
  const src = snapshot as Record<string, Object>;

  const next: Record<string, Object> = {};
  for (const vmId of vmIds) {
    const st = src[vmId];
    if (typeof st === 'undefined') {
      continue;
    }
    next[vmId] = st;
  }

  /* diff：跑→停 emit exited，停→跑 emit started；首帧只记录不 diff */
  if (primed) {
    for (const vmId of vmIds) {
      const prevRunning = isRunningEntry(prevMap, vmId);
      const curRunning = isRunningEntry(next, vmId);
      if (prevRunning && !curRunning) {
        emit(vmId, false);
      } else if (!prevRunning && curRunning) {
        emit(vmId, true);
      }
    }
  }
  prevMap = next;
  primed = true;

  AppStorage.setOrCreate('runningMap', next);
}

function emit(vmId: string, running: boolean): void {
  for (const cb of lifecycle) {
    try {
      cb({ vmId, running });
    } catch {
      /* 单个订阅者出错不影响其余 */
    }
  }
}
