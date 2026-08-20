export const startVm: (arch: string, args: string[]) => number;
export const vmRunning: () => boolean;
export const createSurface: (surfaceId: bigint) => number;
export const resizeSurface: (surfaceId: bigint, w: number, h: number) => number;
export const destroySurface: (surfaceId: bigint) => number;
export const sendPointer: (x: number, y: number, buttons: number) => void;
export const sendKey: (qcode: number, down: boolean) => void;
