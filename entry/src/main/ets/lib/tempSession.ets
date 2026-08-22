// 临时会话引擎：一种「启动模式」——开机前对系统盘打一帧内部快照当「会话起点」，
// VM 停止（关机/断电/崩溃）时自动 `snapshot -a` 回滚到起点再 `-d` 删掉，对话框全部
// 丢弃、系统盘回到本次会话开始时的状态。纯离线 qcow2 内部快照，不涉及在线覆盖层/QMP。
//
// 这帧 `__temp__-` 前缀的快照是机制层产物，不对用户暴露：VmManage 显示快照列表时按前缀滤掉。
// 进程级单例（App 一启动就 initTempSession 订阅生命周期），VM 停止无论列表页开没开都能回滚。
import { VmStore } from './vmprofile';
import { subscribeVmLifecycle, VmLifecycleEvent } from './vmregistry';
import { snapshotCreate, snapshotApply, snapshotDelete } from './vmsnapshot';

const PREFIX = '__temp__';
const pending: Map<string, string> = new Map(); /* vmId → 当前会话起点的快照名 */
let inited = false;

function ts(): string {
  const d = new Date();
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-` +
    `${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/* 快照名是否属临时会话机制层（VmManage 列表据此滤除） */
export function isTempSnapshot(name: string): boolean {
  return name.startsWith(PREFIX);
}

/** 回滚某 vmId 的会话起点快照（若存在）：-a 恢复到起点，-d 删掉，清除 pending。 */
function rollbackOnce(vmId: string, filesDir: string): void {
  const name = pending.get(vmId);
  if (!name) {
    return;
  }
  const p = new VmStore(filesDir).load(vmId);
  const disk = p ? p.media.diskPath : '';
  if (disk.length === 0) {
    /* 磁盘没了/没配：清掉标记即可（无处可回滚） */
    pending.delete(vmId);
    return;
  }
  try {
    if (snapshotApply(disk, name) === 0) {
      snapshotDelete(disk, name);
      pending.delete(vmId);
      return;
    }
  } catch {
    /* 落到下方重试 */
  }
  /* 一次没成（进程刚退、盘锁未释放）：稍后重试一次；仍失败则留 pending 待下次会话启动前清 */
  setTimeout(() => {
    const p2 = new VmStore(filesDir).load(vmId);
    const d2 = p2 ? p2.media.diskPath : '';
    if (d2.length > 0) {
      try {
        if (snapshotApply(d2, name) === 0) {
          snapshotDelete(d2, name);
          pending.delete(vmId);
        }
      } catch {
        /* 放弃，等下次 */
      }
    } else {
      pending.delete(vmId);
    }
  }, 800);
}

/**
 * 每次启动前调用（无论是否临时会话）：先把上一场临时会话的遗留起点「结算」掉
 * （回滚+删），避免残留点把下一次正常会话的写入也误回滚；temporary 为真时再打新起点。
 * 返回 0 成功；非 0 表示临时会话打点失败（调用方应拒启，避免"以为会回滚却没回滚"）。
 */
export function prepareStart(vmId: string, diskPath: string, temporary: boolean): number {
  const old = pending.get(vmId);
  if (old) {
    try {
      if (snapshotApply(diskPath, old) === 0) {
        snapshotDelete(diskPath, old);
      }
    } catch {
      /* 遗留点清不掉不阻塞本次新会话（顶多留一个隐藏的残留快照） */
    }
    pending.delete(vmId);
  }
  if (!temporary) {
    return 0;
  }
  const name = PREFIX + ts();
  const ret = snapshotCreate(diskPath, name);
  if (ret !== 0) {
    return ret;
  }
  pending.set(vmId, name);
  return 0;
}

/** 进程级初始化（App 启动调一次，幂等）：VM 停止且该 vm 在临时会话中 → 回滚丢弃改动。 */
export function initTempSession(filesDir: string): void {
  if (inited) {
    return;
  }
  inited = true;
  subscribeVmLifecycle((e: VmLifecycleEvent) => {
    if (e.running) {
      return;
    }
    rollbackOnce(e.vmId, filesDir);
  });
}
