// 应用级初始化：固件解包 + AppStorage 公共键。进程可能由 EntryAbility
// 或某个 VmConsoleAbility 冷启动拉起，两边 onCreate 都必须调一次（幂等）。
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0001;
const TAG = 'QemuEntry';

/* firmware blobs produced by deps/ (packed as rawfile/vm/...) */
const FIRMWARE_FILES: string[] = [
  'bios-256k.bin',
  'bios.bin',
  'kvmvapic.bin',
  'linuxboot.bin',
  'linuxboot_dma.bin',
  'vgabios-stdvga.bin',
  'vgabios-virtio.bin',
  'vgabios-ramfb.bin',
  'efi-virtio.rom',
  'edk2-x86_64-code.fd', /* Windows x64 OVMF CODE（pflash） */
  'edk2-i386-vars.fd',   /* x86 OVMF VARS 模板（复制成每 VM VARS） */
  'edk2-arm-vars.fd',    /* aarch64 AAVMF VARS 模板 */
  'edk2-aarch64-code.fd', /* aarch64 客户机 UEFI 固件（virt 机器经 -bios 加载） */
  'edk2-arm-code.fd', /* arm(32位) 客户机 UEFI 固件（virt 机器经 -bios 加载） */
  'edk2-loongarch64-code.fd', /* loongarch64 客户机 UEFI 固件（virt 机器经 -bios 加载） */
  'edk2-riscv-code.fd', /* riscv64 客户机 UEFI 固件（virt 机器经 -bios 加载） */
];

/* swtpm 真 TPM 运行库：rawfile/bin/swtpm/lib/*（软件包由 deps/ 交叉编译，spawn 时经
 * LD_LIBRARY_PATH 指定；必须与 swtpm 可执行同目录下解包，避免依赖系统缺失库）。 */
const SWTPM_LIBS: string[] = [
  'libtpms.so.0',
  'libswtpm_libtpms.so.0',
  'libjson-glib-1.0.so.0',
  'libcrypto.so.3',
  'libpcre2-8.so.0',
  'libz.so.1',
];

function writeRaw(resMgr: resourceManager.ResourceManager, rawPath: string, dst: string): void {
  try {
    if (fs.statSync(dst).size > 0) {
      return; /* already unpacked */
    }
  } catch {
    /* not there yet */
  }
  hilog.info(DOMAIN, TAG, 'unpacking %{public}s', rawPath);
  const data = resMgr.getRawFileContentSync(rawPath);
  const fd = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  fs.writeSync(fd.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
  fs.closeSync(fd);
}

function errStr(err: Object): string {
  const be = err as BusinessError;
  return `code=${be.code} msg=${be.message}`;
}

function tryWriteRaw(resMgr: resourceManager.ResourceManager, rawPath: string, dst: string): boolean {
  try {
    writeRaw(resMgr, rawPath, dst);
    return true;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'unpack %{public}s failed: %{public}s', rawPath, errStr(err));
    return false;
  }
}

function unpackFirmware(ctx: common.UIAbilityContext): boolean {
  const resMgr = ctx.resourceManager;
  const vmDir = ctx.filesDir + '/vm';
  let ok = true;
  try {
    if (!fs.accessSync(vmDir)) {
      fs.mkdirSync(vmDir, true);
    }
    if (!fs.accessSync(vmDir + '/keymaps')) {
      fs.mkdirSync(vmDir + '/keymaps', true);
    }
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'mkdir failed: %{public}s', errStr(err));
    return false;
  }
  for (const name of FIRMWARE_FILES) {
    ok = tryWriteRaw(resMgr, 'vm/firmware/' + name, vmDir + '/' + name) && ok;
  }
  ok = tryWriteRaw(resMgr, 'vm/keymaps/en-us', vmDir + '/keymaps/en-us') && ok;
  hilog.info(DOMAIN, TAG, 'firmware unpacked to %{public}s, ok=%{public}s', vmDir, String(ok));
  return ok;
}

/* 解包真 TPM swtpm：可执行 → vmDir/swtpm/bin/swtpm，运行库 → vmDir/swtpm/lib/*。
 * 镜像 rawfile 不保留可执行位，且 @ohos.file.fs 无 chmod，故可执行位由 native
 * spawn 前 best-effort chmod 补齐（见 swtpm.cpp swtpm_start）。 */
function unpackSwtpm(resMgr: resourceManager.ResourceManager, vmDir: string): boolean {
  const swtpmDir = vmDir + '/swtpm';
  let ok = true;
  try {
    if (!fs.accessSync(swtpmDir + '/bin')) {
      fs.mkdirSync(swtpmDir + '/bin', true);
    }
    if (!fs.accessSync(swtpmDir + '/lib')) {
      fs.mkdirSync(swtpmDir + '/lib', true);
    }
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'swtpm mkdir failed: %{public}s', errStr(err));
    return false;
  }
  ok = tryWriteRaw(resMgr, 'bin/swtpm/bin/swtpm', swtpmDir + '/bin/swtpm') && ok;
  for (const name of SWTPM_LIBS) {
    ok = tryWriteRaw(resMgr, 'bin/swtpm/lib/' + name, swtpmDir + '/lib/' + name) && ok;
  }
  hilog.info(DOMAIN, TAG, 'swtpm unpacked to %{public}s, ok=%{public}s', swtpmDir, String(ok));
  return ok;
}

let bootstrapped = false;

export function ensureAppBootstrap(ctx: common.UIAbilityContext): void {
  if (bootstrapped) {
    return;
  }
  bootstrapped = true;
  try {
    ctx.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
  }
  const ok = unpackFirmware(ctx);
  unpackSwtpm(ctx.resourceManager, ctx.filesDir + '/vm');
  AppStorage.setOrCreate('filesDir', ctx.filesDir);
  AppStorage.setOrCreate('vmDataDir', ctx.filesDir + '/vm');
  AppStorage.setOrCreate('firmwareReady', ok);
  hilog.info(DOMAIN, TAG, 'app bootstrap done, firmwareReady=%{public}s', String(ok));
}
