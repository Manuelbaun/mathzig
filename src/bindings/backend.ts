/**
 * Common interface for MathZig backends (Native FFI and WebAssembly)
 */

export type Pointer = (number | bigint) & { __pointer__: null };

export interface Backend {
  /**
   * Calls a low-level function by name with the given arguments.
   */
  call(funcName: string, ...args: any[]): any;

  /**
   * Allocates memory on the backend's heap.
   */
  alloc(size: number | bigint): Pointer;

  /**
   * Frees memory on the backend's heap.
   */
  free(ptr: Pointer): void;

  /**
   * Frees a temporary pointer returned by ptr(). 
   * On Native FFI, this is usually a no-op (GC handles it).
   * On WebAssembly, this frees the manual allocation.
   */
  freeTemporary(ptr: Pointer): void;

  /**
   * Converts a JS value (String, TypedArray) to a backend pointer.
   * If input is already a pointer, returns it.
   */
  ptr(data: any): Pointer;

  /**
   * Reads a null-terminated UTF-8 string from the backend's memory.
   */
  readString(ptr: Pointer): string;

  /**
   * Copies data from the backend's memory into a new ArrayBuffer.
   */
  toArrayBuffer(ptr: Pointer, size: number): ArrayBuffer;

  /**
   * Returns the underlying symbols (for direct access if needed).
   */
  readonly symbols: any;
}
