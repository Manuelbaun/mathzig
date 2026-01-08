import { dlopen, ptr as bunPtr, toArrayBuffer as bunToArrayBuffer } from "bun:ffi";
import { Backend, Pointer } from "../backend";
import { all_symbols } from "./loader";

export class FFIBackend implements Backend {
  public symbols: any;

  constructor(libPath: string) {
    this.symbols = dlopen(libPath, all_symbols).symbols;
  }

  call(funcName: string, ...args: any[]): any {
    const fn = this.symbols[funcName];
    if (!fn) throw new Error(`Symbol not found: ${funcName}`);
    return fn(...args);
  }

  alloc(size: number | bigint): Pointer {
    return this.symbols.wasm_malloc(BigInt(size));
  }

  free(ptr: Pointer): void {
    this.symbols.wasm_free(ptr);
  }

  freeTemporary(_ptr: Pointer): void {
    // No-op for FFI as ptr() returns Buffer/TypedArray managed by GC
  }

  ptr(data: any): Pointer {
    if (data === null || data === undefined) return 0 as any;
    if (typeof data === "number" || typeof data === "bigint") return data as any;
    if (typeof data === "string") {
      return Buffer.from(data + "\0") as any;
    }
    if (ArrayBuffer.isView(data) || data instanceof ArrayBuffer) {
      return bunPtr(data) as any;
    }
    if (typeof data === 'object' && 'handle' in data) {
      return (data as any).handle;
    }
    throw new Error(`Unable to convert ${data} to a pointer. Type: ${typeof data}`);
  }

  readString(ptr: Pointer): string {
    if (!ptr) return "";
    // Bun's FFI may return a boxed String object for cstrings.
    // Convert to primitive string to ensure === comparison works.
    return String(ptr);
  }

  toArrayBuffer(ptr: Pointer, size: number): ArrayBuffer {
    return bunToArrayBuffer(ptr, 0, size);
  }
}
