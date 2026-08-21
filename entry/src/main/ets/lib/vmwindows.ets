// console 窗口注册表：vmId → 该 VM 独立窗口的主 window（供页面切系统栏）。
// 所有 UIAbility 同进程，模块级单例即可共享。
// 另附 pending vmId FIFO：loadContent 前入队，页面 aboutToAppear 同步出队
// （loadContent 同步建页，UI 线程无并发，参考 wineohos setPendingToplevel）。
import { window } from '@kit.ArkUI';

const consoleWindows: Map<string, window.Window> = new Map();
const pendingVmIds: string[] = [];

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
