export const startVm: (vmId: string, arch: string, args: string[], surfaceId: bigint) => number;
export const vmRunning: (vmId: string) => boolean;
export const createSurface: (vmId: string, surfaceId: bigint) => number;
export const resizeSurface: (vmId: string, w: number, h: number) => number;
export const destroySurface: (vmId: string) => number;
export const sendPointer: (vmId: string, x: number, y: number, buttons: number) => void;
export const sendKey: (vmId: string, qcode: number, down: boolean) => void;
export const qmpConnect: (vmId: string, sockPath: string) => number;
export const qmpCommand: (vmId: string, cmd: string) => string;
export const qmpDisconnect: (vmId: string) => void;
export const qmpConnected: (vmId: string) => boolean;
export const setQmpEventCallback: (vmId: string, cb: ((evt: string) => void) | null) => void;
export const captureScreen: (vmId: string) => ScreenShot | null;
export const createDisk: (path: string, sizeMB: number) => number;

export interface ScreenShot {
  width: number;
  height: number;
  pixels: ArrayBuffer; /* RGBA_8888, matches image.PixelMapFormat.RGBA_8888 */
}
