/**
 * Auto-generated unified bindings for MathZig WASM
 */

export type Pointer = number & { __pointer__: null };

export interface Backend {
  call(funcName: string, ...args: any[]): any;
  alloc(size: number): Pointer;
  free(handle: Pointer): void;
  freeTemporary(handle: Pointer): void;
  ptr(data: Uint8Array | Float64Array | Int32Array | any): Pointer;
  readString(handle: Pointer): string;
  writeString(str: string): Pointer;
  writePointerArray(ptrs: Pointer[]): Pointer;
  toArrayBuffer(handle: Pointer, size: number): ArrayBuffer;
  createCallback(fn: Function, signature: string): Pointer;
}

export function createModule(backend: Backend) {
  class MathZig {

    public handle!: Pointer;

    static _wrap(handle: Pointer): MathZig {
      const obj = Object.create(MathZig.prototype);
      obj.handle = handle;
      return obj;
    }

    constructor();
    constructor(handle: Pointer);
    constructor(...args: any[]) {
      if (args.length === 0) {
        this.handle = backend.call("mathzig_create");
      }
      else {
        this.handle = args[0];
      }
    }

    free(): void {
      if (this.handle) {
        backend.call("mathzig_destroy", this.handle);
        this.handle = null as any;
      }
    }


    compile(expression: string): Pointer {

      const expression_ptr = backend.writeString(expression);

      const res = backend.call("mathzig_compile", this.handle, expression_ptr);

      backend.free(expression_ptr);
      return res;
    }


    freeExpr(expr: Pointer): void {

      backend.call("mathzig_free_expr", this.handle, expr);

      return;
    }


    evaluate(expr: Pointer): number {

      const res = backend.call("mathzig_evaluate", this.handle, expr);

      return Number(res);
    }


    eval(expression: string): number {

      const expression_ptr = backend.writeString(expression);

      const res = backend.call("mathzig_eval", this.handle, expression_ptr);

      backend.free(expression_ptr);
      return Number(res);
    }


    setVariable(name: string, value: number): boolean {

      const name_ptr = backend.writeString(name);

      const res = backend.call("mathzig_set_variable", this.handle, name_ptr, value);

      backend.free(name_ptr);
      return res;
    }


    addVariableIndexed(name: string, initialValue: number): number {

      const name_ptr = backend.writeString(name);

      const res = backend.call("mathzig_add_variable_indexed", this.handle, name_ptr, initialValue);

      backend.free(name_ptr);
      return Number(res);
    }


    setByIndex(index: number, value: number): void {

      backend.call("mathzig_set_by_index", this.handle, index, value);

      return;
    }


    evaluateBatch(expr: Pointer, varIndex: number, inputs: number, outputs: number, count: number): number {

      const res = backend.call("mathzig_evaluate_batch", this.handle, expr, varIndex, inputs, outputs, count);

      return Number(res);
    }


    getError(): string {

      const res = backend.call("mathzig_get_error", this.handle);

      return backend.readString(res);
    }


    version(): string {

      const res = backend.call("mathzig_version", this.handle);

      return backend.readString(res);
    }


    versionNumber(): number {

      const res = backend.call("mathzig_version_number", this.handle);

      return Number(res);
    }

  }


  return {
    
    MathZig,
    
  };
}

export type Module = ReturnType<typeof createModule>;
export type MathZigClass = InstanceType<Module['MathZig']>;
