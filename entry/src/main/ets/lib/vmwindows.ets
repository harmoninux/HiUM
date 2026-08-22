// console 窗口注册表：vmId → 该 VM 独立窗口的主 window（供页面切系统栏）。
// 所有 UIAbility 同进程，模块级单例即可共享。
// 另附 pending vmId FIFO：loadContent 前入队，页面 aboutToAppear 同步出队
// （loadContent 同步建页，UI 线程无并发，参考 wineohos setPendingToplevel）。
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

const consoleWindows: Map<string, window.Window> = new Map();
const pendingVmIds: string[] = [];

/* 触屏设备（平板/手机）：用沉浸窗口 + 悬浮虚拟键盘；PC(2in1)/其他走桌面窗口 + 真实键鼠。
 * 与 wineohos 的 isPadOrPhone 语义一致。 */
export function isPadOrPhone(): boolean {
  return deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === 'phone';
}

export function setConsoleWindow(vmId: string, win: window.Window): void {
  consoleWindows.set(vmId, win);
}

export function getConsoleWindow(vmId: string): window.Window | undefined {
  return consoleWindows.get(vmId);
}

export function removeConsoleWindow(vmId: string): void {
  consoleWindows.delete(vmId);
}

export function pushPendingVmId(vmId: string): void {
  pendingVmIds.push(vmId);
}

export function takePendingVmId(): string {
  return pendingVmIds.shift() ?? '';
}
