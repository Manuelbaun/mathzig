/** Browser stub for FFIBackend. */
export class FFIBackend {
  constructor(_path?: string) {}
  call() {
    return 0;
  }
  ptr(x: unknown) {
    return x;
  }
  toArrayBuffer(_p: unknown, n = 0) {
    return new ArrayBuffer(n || 0);
  }
  readString() {
    return "";
  }
}
