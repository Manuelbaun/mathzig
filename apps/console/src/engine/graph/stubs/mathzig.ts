/**
 * Browser stub for `src/ts/mathzig` (bun:ffi MathZig).
 * Scalar GraphRunner never calls into a real native host; full-Value nodes
 * that need delegated builtins will fail at runtime with a clear path note.
 */
export class MathZig {
  static create() {
    return new MathZig();
  }
  static allocAligned(_align: number, _size: number, _backend?: unknown) {
    return 0;
  }
  handle = 0;
  backend = {
    call() {
      return 0;
    },
    ptr(x: unknown) {
      return x;
    },
    toArrayBuffer(_p: unknown, n = 0) {
      return new ArrayBuffer(n || 0);
    },
    readString() {
      return "";
    },
  };
  resetMemory() {}
  createSeries() {
    return 0;
  }
}

export const SampleMode = { Step: 0, Linear: 1, Cumulative: 2 } as const;
export const ValueTag = { Number: 0 } as const;
export const ptr = (x: unknown) => x;
export const toArrayBuffer = (_p?: unknown, n = 0) => new ArrayBuffer(n || 0);
