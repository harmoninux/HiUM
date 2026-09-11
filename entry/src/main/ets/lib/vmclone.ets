// VM 克隆：新 id + profile 深拷贝 + vms/ 资产逐文件复制（进度回调）。
// 语义对齐既有资产规则：vms/ 内的磁盘与 kernel/initrd 复制为自有副本并改写
// profile 引用；ISO 光盘保持「原地引用外部路径」（与向导/编辑一致，不复制）。
// 运行中（vmIsRunning）拒绝克隆：磁盘文件正在被 qemu 占用，复制会拿到不一致的
// 快照。失败时清理本轮已复制的文件 + 不 save，不留孤儿资产。
import { fileIo as fs } from '@kit.CoreFileKit';
import { VmProfile, VmStore, newProfileId } from './vmprofile';
import { copyFileWithProgress } from './fsutil';
import { vmIsRunning } from './vmregistry';

/* 目标文件名：
 * - vms 内资产按「源 id 前缀」换新 id：<id>.qcow2 → <newId>.qcow2、
 *   <id>-d2.qcow2 → <newId>-d2.qcow2（含非 .qcow2 扩展名）
 * - 外部引用盘/文件：复制进 vms/，命名为 <newId>-<原文件名>（源文件不受影响） */
function cloneDstPath(src: string, oldId: string, newId: string, vmsDir: string): string {
  const base = src.substring(src.lastIndexOf('/') + 1);
  if (base.startsWith(oldId + '.') || base.startsWith(oldId + '-')) {
    return vmsDir + '/' + newId + base.substring(oldId.length);
  }
  return vmsDir + '/' + newId + '-' + base;
}

function baseName(path: string): string {
  const i = path.lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}

/* 深拷贝（纯数据 JSON 往返；ArkTS 无 structuredClone 且禁 Object spread 深层拷贝） */
function deepCopy(p: VmProfile): VmProfile {
  return JSON.parse(JSON.stringify(p)) as VmProfile;
}

/* 克隆主流程。progress(stage, pct) 回调 UI；返回 ''=成功，否则错误描述。 */
export async function cloneVm(store: VmStore, p: VmProfile,
  progress: (stage: string, pct: number) => void): Promise<string> {
  if (vmIsRunning(p.id)) {
    return 'VM 运行中，无法克隆';
  }
  const vmsDir = store.dir;
  const newId = newProfileId();

  /* 复制清单：系统盘+数据盘（存在的）与 kernel/initrd；cdrom 不复制（原地引用） */
  const srcs: string[] = [];
  for (const d of p.media.disks) {
    if (d.path.length > 0) {
      srcs.push(d.path);
    }
  }
  if (p.media.kernelPath.length > 0) {
    srcs.push(p.media.kernelPath);
  }
  if (p.media.initrdPath.length > 0) {
    srcs.push(p.media.initrdPath);
  }
  /* 逐一校验源存在（vms 内资产被用户移动/删除过则先报错，不留半成品） */
  for (const src of srcs) {
    let ok = false;
    try {
      ok = fs.accessSync(src);
    } catch {
      ok = false;
    }
    if (!ok) {
      return '源文件不存在：' + baseName(src);
    }
  }

  const donePaths: string[] = [];
  let idx = 0;
  for (const src of srcs) {
    idx++;
    const dst = cloneDstPath(src, p.id, newId, vmsDir);
    const ok = await copyFileWithProgress(src, dst,
      (pct: number) => progress(`复制 ${baseName(src)}`, pct));
    if (!ok) {
      /* 清掉本轮已成功的副本，不留孤儿 */
      for (const d of donePaths) {
        try {
          fs.unlinkSync(d);
        } catch {
          /* best effort */
        }
      }
      return '复制失败：' + baseName(src);
    }
    donePaths.push(dst);
  }

  /* profile 深拷贝 + 改 id/name/资产引用 */
  const np = deepCopy(p);
  np.id = newId;
  np.name = p.name.length > 0 ? p.name + '·副本' : '新虚拟机·副本';
  for (const d of np.media.disks) {
    if (d.path.length > 0) {
      d.path = cloneDstPath(d.path, p.id, newId, vmsDir);
    }
  }
  if (np.media.kernelPath.length > 0) {
    np.media.kernelPath = cloneDstPath(np.media.kernelPath, p.id, newId, vmsDir);
  }
  if (np.media.initrdPath.length > 0) {
    np.media.initrdPath = cloneDstPath(np.media.initrdPath, p.id, newId, vmsDir);
  }
  progress('保存配置', 100);
  store.save(np);
  return '';
}
