// 真备份/恢复（EntryBackupAbility）：把应用的数据目录接进系统备份/恢复流程。
// 数据 = filesDir/vms（VM 配置 *.json + 缩略图 *.jpg + 系统盘镜像 *.qcow2）。
// 备份方向：文件系统把归档数据 staged 到 context.backupDir；恢复方向：把
// backupDir/vms 写回 filesDir/vms。只备份 vms/，不含可再生的固件/ISO
// （vm/ 目录由 ensureAppBootstrap 从 rawfile 重新解包）。
//
// 说明：系统发起的真实备份/恢复需在整机备份流程里触发（本机无法单独跑），
// 这里保证 onBackupEx/onRestoreEx/onBackup/onRestore 语义正确、能编译，
// 真机备份时由系统调用。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';

const DOMAIN = 0x0009;
const TAG = 'QemuBackup';

interface BackupOpResult {
  type: string;
  errorCode: number;
  errorInfo: string;
}

/* 递归把 srcDir 树复制到 dstDir（大文件走 copyFileSync 流式，不整读进内存）；
 * 单项失败记日志跳过，不中断整棵复制。 */
function copyTree(srcDir: string, dstDir: string): void {
  if (!fs.accessSync(srcDir)) {
    return;
  }
  fs.mkdirSync(dstDir, true);
  const entries = fs.listFileSync(srcDir);
  for (const name of entries) {
    const s = srcDir + '/' + name;
    const d = dstDir + '/' + name;
    try {
      const st = fs.statSync(s);
      if (st.isDirectory()) {
        copyTree(s, d);
      } else if (st.isFile()) {
        fs.copyFileSync(s, d);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'copy %{public}s -> %{public}s failed: %{public}s',
                 s, d, JSON.stringify(err));
    }
  }
}

export default class EntryBackupAbility extends BackupExtensionAbility {
  /* 备份：把 filesDir/vms 复制到 backupDir/vms */
  private stageBackup(): void {
    try {
      const src = this.context.filesDir + '/vms';
      const dst = this.context.backupDir + '/vms';
      copyTree(src, dst);
      hilog.info(DOMAIN, TAG, 'backup staged: %{public}s -> %{public}s', src, dst);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'backup stage failed: %{public}s', JSON.stringify(err));
    }
  }

  /* 恢复：把 backupDir/vms 复制回 filesDir/vms */
  private stageRestore(): void {
    try {
      const src = this.context.backupDir + '/vms';
      const dst = this.context.filesDir + '/vms';
      copyTree(src, dst);
      hilog.info(DOMAIN, TAG, 'restore staged: %{public}s -> %{public}s', src, dst);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'restore stage failed: %{public}s', JSON.stringify(err));
    }
  }

  onBackup(): void {
    this.stageBackup();
  }

  onRestore(bundleVersion: BundleVersion): void {
    this.stageRestore();
  }

  /* 12+ 扩展入口：返回结果 JSON（{type,errorCode,errorInfo}） */
  onBackupEx(backupInfo: string): string {
    this.stageBackup();
    const r: BackupOpResult = { type: 'backup', errorCode: 0, errorInfo: '' };
    return JSON.stringify(r);
  }

  onRestoreEx(bundleVersion: BundleVersion, restoreInfo: string): string {
    this.stageRestore();
    const r: BackupOpResult = { type: 'restore', errorCode: 0, errorInfo: '' };
    return JSON.stringify(r);
  }
}
