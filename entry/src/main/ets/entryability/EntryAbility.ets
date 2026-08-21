import { AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
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
  ok = tryWriteRaw(resMgr, 'vm/alpine-virt.iso', vmDir + '/alpine-virt.iso') && ok;
  hilog.info(DOMAIN, TAG, 'firmware unpacked to %{public}s, ok=%{public}s', vmDir, String(ok));
  return ok;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    const ok = unpackFirmware(this.context);
    AppStorage.setOrCreate('filesDir', this.context.filesDir);
    AppStorage.setOrCreate('vmDataDir', this.context.filesDir + '/vm');
    AppStorage.setOrCreate('firmwareReady', ok);
    hilog.info(DOMAIN, TAG, 'Ability onCreate, firmwareReady=%{public}s', String(ok));
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
