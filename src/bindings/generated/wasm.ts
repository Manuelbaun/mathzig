// Auto-generated WASM bridge implementation for MathZig
import * as Types from "./index";

// Callback registry for WASM callbacks
const callbackRegistry = new Map<number, Function>();

export class WasmBackend implements Types.Backend {
  private exports: any;
  public memory: WebAssembly.Memory;
  private nextCallbackSlot: number = 0;

  constructor(instance: WebAssembly.Instance) {
    this.exports = instance.exports;
    this.memory = this.exports.memory as WebAssembly.Memory;
  }

  call(funcName: string, ...args: any[]): any {
    return this.exports[funcName](...args);
  }

  readStruct(handle: any, offset: number, ffiType: string): any {
    const view = new DataView(this.memory.buffer);
    switch (ffiType) {
      case 'f64': return view.getFloat64(handle + offset, true);
      case 'f32': return view.getFloat32(handle + offset, true);
      case 'i32': return view.getInt32(handle + offset, true);
      case 'u32': return view.getUint32(handle + offset, true);
      case 'i8': return view.getInt8(handle + offset);
      case 'u8': return view.getUint8(handle + offset);
      case 'bool': return view.getUint8(handle + offset) !== 0;
      default: return view.getUint32(handle + offset, true);
    }
  }

  writeStruct(handle: any, offset: number, ffiType: string, value: any): void {
    const view = new DataView(this.memory.buffer);
    switch (ffiType) {
      case 'f64': view.setFloat64(handle + offset, value, true); break;
      case 'f32': view.setFloat32(handle + offset, value, true); break;
      case 'i32': view.setInt32(handle + offset, value, true); break;
      case 'u32': view.setUint32(handle + offset, value, true); break;
      case 'i8': view.setInt8(handle + offset, value); break;
      case 'u8': view.setUint8(handle + offset, value); break;
      case 'bool': view.setUint8(handle + offset, value ? 1 : 0); break;
      default: view.setUint32(handle + offset, value, true);
    }
  }

  alloc(size: number): any {
    return this.exports.wasm_malloc ? this.exports.wasm_malloc(size) : 0;
  }

  free(handle: any): void {
    if (this.exports.wasm_free) this.exports.wasm_free(handle);
  }

  freeTemporary(handle: any): void {
    this.free(handle);
  }

  ptr(data: ArrayBufferView | string | any): any {
    if (typeof data === "string") {
      return this.writeString(data);
    }
    if (ArrayBuffer.isView(data)) {
      if (data.buffer === this.memory.buffer) {
        return data.byteOffset;
      }
      const bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      const p = this.alloc(bytes.length);
      if (p) new Uint8Array(this.memory.buffer, p, bytes.length).set(bytes);
      return p;
    }
    return data;
  }

  readString(handle: any): string {
    if (!handle) return "";
    const view = new Uint8Array(this.memory.buffer, handle);
    let len = 0;
    while (view[len] !== 0) len++;
    return new TextDecoder().decode(view.subarray(0, len));
  }

  writeString(str: string): any {
    const bytes = new TextEncoder().encode(str + "\0");
    const p = this.alloc(bytes.length);
    if (p) new Uint8Array(this.memory.buffer, p, bytes.length).set(bytes);
    return p;
  }

  writePointerArray(ptrs: any[]): any {
    const bytes = ptrs.length * 4;
    const p = this.alloc(bytes);
    if (p) {
      const view = new Uint32Array(this.memory.buffer, p, ptrs.length);
      for (let i = 0; i < ptrs.length; i++) {
        view[i] = ptrs[i];
      }
    }
    return p;
  }

  toArrayBuffer(handle: any, size: number): ArrayBuffer {
    return this.memory.buffer.slice(handle, handle + size);
  }

  createCallback(fn: Function, signature: string): any {
    // Determine callback type from signature
    const isVoidReturn = signature.startsWith("void");
    const hasIntArg = signature.includes("(int)");
    const hasDoubleArgs = signature.includes("double") && signature.includes(",");

    // Get next available slot
    const slot = this.nextCallbackSlot++;
    callbackRegistry.set(slot, fn);

    // Get the function pointer from the appropriate lookup function
    let ptr: number;
    if (isVoidReturn && !hasIntArg && !hasDoubleArgs) {
      ptr = this.exports.get_void_cb_ptr ? this.exports.get_void_cb_ptr(slot) : 0;
    } else if (hasDoubleArgs) {
      ptr = this.exports.get_double_cb_ptr ? this.exports.get_double_cb_ptr(slot) : 0;
    } else {
      ptr = this.exports.get_int_cb_ptr ? this.exports.get_int_cb_ptr(slot) : 0;
    }
    return ptr;
  }
}

export async function load(wasmUrl: string | URL | ArrayBuffer | Uint8Array): Promise<WasmBackend & Types.Module> {
  let buffer: ArrayBuffer;
  if (wasmUrl instanceof ArrayBuffer) buffer = wasmUrl;
  else if (wasmUrl instanceof Uint8Array) buffer = wasmUrl.buffer;
  else {
    const response = await fetch(wasmUrl.toString());
    buffer = await response.arrayBuffer();
  }

  const { instance } = await WebAssembly.instantiate(buffer, {
    env: {
      memory: new WebAssembly.Memory({ initial: 1024 }),
      // Callback dispatchers - called by WASM trampolines
      js_callback_void: (slot: number) => {
        const fn = callbackRegistry.get(slot);
        if (fn) fn();
      },
      js_callback_int: (slot: number, arg: number) => {
        const fn = callbackRegistry.get(slot);
        return fn ? fn(arg) : 0;
      },
      js_callback_double: (slot: number, a: number, b: number) => {
        const fn = callbackRegistry.get(slot);
        return fn ? fn(a, b) : 0.0;
      },
    },
    wasi_snapshot_preview1: { 
      proc_exit: () => {},
      args_get: () => 0,
      args_sizes_get: () => 0,
      environ_get: () => 0,
      environ_sizes_get: () => 0,
      fd_close: () => 0,
      fd_read: () => 0,
      fd_write: (fd: number, iovs: number, iovs_len: number, nwritten: number) => {
        const view = new DataView(instance.exports.memory.buffer);
        let written = 0;
        for (let i = 0; i < iovs_len; i++) {
          const ptr = view.getUint32(iovs + i * 8, true);
          const len = view.getUint32(iovs + i * 8 + 4, true);
          const buf = new Uint8Array(instance.exports.memory.buffer, ptr, len);
          const str = new TextDecoder().decode(buf);
          if (fd === 1) console.log(str); // stdout
          else if (fd === 2) console.error(str); // stderr
          written += len;
        }
        view.setUint32(nwritten, written, true);
        return 0;
      },
      fd_pread: () => 0,
      fd_pwrite: () => 0,
      fd_seek: () => 0,
      fd_fdstat_get: () => 0,
      fd_fdstat_set_flags: () => 0,
      fd_fdstat_set_rights: () => 0,
      fd_datasync: () => 0,
      fd_advise: () => 0,
      fd_allocate: () => 0,
      fd_filestat_get: () => 0,
      fd_filestat_set_size: () => 0,
      fd_filestat_set_times: () => 0,
      fd_prestat_get: () => 0,
      fd_prestat_dir_name: () => 0,
      fd_renumber: () => 0,
      fd_tell: () => 0,
      fd_sync: () => 0,
      path_create_directory: () => 0,
      path_filestat_get: () => 0,
      path_filestat_set_times: () => 0,
      path_link: () => 0,
      path_open: () => 0,
      path_readlink: () => 0,
      path_remove_directory: () => 0,
      path_rename: () => 0,
      path_symlink: () => 0,
      path_unlink_file: () => 0,
      poll_oneoff: () => 0,
      proc_raise: () => 0,
      sched_yield: () => 0,
      sock_recv: () => 0,
      sock_send: () => 0,
      sock_shutdown: () => 0,
      clock_res_get: () => 0,
      clock_time_get: () => 0,
      random_get: () => 0
    }
  });
  const backend = new WasmBackend(instance);
  const mod = Types.createModule(backend);
  return Object.assign(backend, mod);
}

export * from "./index";
