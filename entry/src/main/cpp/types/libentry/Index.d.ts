export const startVm: (arch: string, args: string[]) => number;
export const vmRunning: () => boolean;
export const vmSpent: () => boolean;
export const createSurface: (surfaceId: bigint) => number;
export const resizeSurface: (surfaceId: bigint, w: number, h: number) => number;
export const destroySurface: (surfaceId: bigint) => number;
export const sendPointer: (x: number, y: number, buttons: number) => void;
export const sendKey: (qcode: number, down: boolean) => void;
export const qmpConnect: (port: number) => number;
export const qmpCommand: (cmd: string) => string;
export const qmpDisconnect: () => void;
export const qmpConnected: () => boolean;
export const setQmpEventCallback: (cb: ((evt: string) => void) | null) => void;
export const captureScreen: () => ScreenShot | null;
export const createDisk: (path: string, sizeMB: number) => number;

export interface ScreenShot {
  width: number;
  height: number;
  pixels: ArrayBuffer; /* RGBA_8888, matches image.PixelMapFormat.RGBA_8888 */
}
