import { Backend, Pointer } from "../backend";

export class WasmBackend implements Backend {
  public exports: any;
  public memory: WebAssembly.Memory;

  constructor(instance: WebAssembly.Instance) {
    this.exports = instance.exports;
    this.memory = this.exports.memory as WebAssembly.Memory;
  }

  get symbols() {
    return this.exports;
  }

  call(funcName: string, ...args: any[]): any {
    const fn = this.exports[funcName];
    if (!fn) throw new Error(`Symbol not found: ${funcName}`);
    return fn(...args);
  }

  alloc(size: number | bigint): Pointer {
    return this.exports.wasm_malloc(size);
  }

  free(ptr: Pointer): void {
    this.exports.wasm_free(ptr);
  }

  freeTemporary(ptr: Pointer): void {
    this.free(ptr);
  }

  ptr(data: any): Pointer {
    if (data === null || data === undefined) return 0 as any;
    if (typeof data === "number" || typeof data === "bigint") return data as any;
    
    if (typeof data === "string") {
      const bytes = new TextEncoder().encode(data + "\0");
      const p = this.alloc(bytes.length);
      new Uint8Array(this.memory.buffer, p as any, bytes.length).set(bytes);
      return p;
    }

    if (ArrayBuffer.isView(data) || data instanceof ArrayBuffer) {
      const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      const p = this.alloc(bytes.length);
      new Uint8Array(this.memory.buffer, p as any, bytes.length).set(bytes);
      return p;
    }
    
    return data;
  }

  readString(ptr: Pointer): string {
    if (!ptr) return "";
    const view = new Uint8Array(this.memory.buffer, ptr as any);
    let len = 0;
    while (view[len] !== 0) len++;
    return new TextDecoder().decode(view.subarray(0, len));
  }

  toArrayBuffer(ptr: Pointer, size: number): ArrayBuffer {
    // Note: This returns a copy for WASM to be safe, or we could return a view
    // if we are sure the buffer won't grow/move.
    return this.memory.buffer.slice(ptr as any, (ptr as any) + size);
  }
}

export async function loadWasm(wasmUrl: string | URL | ArrayBuffer | Uint8Array): Promise<WasmBackend> {
  let buffer: ArrayBuffer;
  if (wasmUrl instanceof ArrayBuffer) buffer = wasmUrl;
  else if (wasmUrl instanceof Uint8Array) buffer = wasmUrl.buffer;
  else {
    const response = await fetch(wasmUrl.toString());
    buffer = await response.arrayBuffer();
  }

  const { instance } = await WebAssembly.instantiate(buffer, {
    env: {
      memory: new WebAssembly.Memory({ initial: 256 }), // 16MB
    },
    wasi_snapshot_preview1: {
        proc_exit: (code: number) => console.log(`WASI exit: ${code}`),
        fd_write: (fd: number, iovs: number, iovs_len: number, nwritten: number) => {
            const view = new DataView(instance.exports.memory.buffer);
            let written = 0;
            for (let i = 0; i < iovs_len; i++) {
                const ptr = view.getUint32(iovs + i * 8, true);
                const len = view.getUint32(iovs + i * 8 + 4, true);
                const buf = new Uint8Array(instance.exports.memory.buffer, ptr, len);
                const str = new TextDecoder().decode(buf);
                if (fd === 1) process.stdout.write(str);
                else if (fd === 2) process.stderr.write(str);
                written += len;
            }
            view.setUint32(nwritten, written, true);
            return 0;
        },
        // Minimal WASI stubs
        args_get: () => 0,
        args_sizes_get: () => 0,
        clock_time_get: () => 0,
        fd_close: () => 0,
        fd_read: () => 0,
        fd_seek: () => 0,
        random_get: (ptr: number, len: number) => {
            const buf = new Uint8Array(instance.exports.memory.buffer, ptr, len);
            crypto.getRandomValues(buf);
            return 0;
        }
    }
  } as any);

  return new WasmBackend(instance);
}
