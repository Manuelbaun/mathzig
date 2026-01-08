/** Browser stub for `bun:ffi` (scalar graph path does not need native FFI). */
export const ptr = (x: unknown) => x;
export const toArrayBuffer = (_p?: unknown, n = 0) => new ArrayBuffer(n || 0);
export const dlopen = () => ({ symbols: {} });
export const suffix = "";
export class CString {}
export class JSCallback {}
export const linkSymbols = () => ({});
export const viewSource = () => "";
