///! MathZig TypeScript Bindings for WebAssembly
///! 
///! Usage:
///!   import { MathZigWasm } from './mathzig_wasm';

import { existsSync, readFileSync } from 'fs';

export enum SampleMode {
  Step = 0,
  Linear = 1,
  Cumulative = 2,
}

export class MathZigWasm {
  private instance: WebAssembly.Instance;
  private memory: WebAssembly.Memory;
  private ctx: number;
  private ownedExprs: Set<number> = new Set();

  private constructor(instance: WebAssembly.Instance, memory: WebAssembly.Memory, ctx: number) {
    this.instance = instance;
    this.memory = memory;
    this.ctx = ctx;
  }

  static async create(wasmPath: string = './web/mathzig_wasm.wasm'): Promise<MathZigWasm> {
    const resolvedPath = existsSync(wasmPath)
      ? wasmPath
      : existsSync('./zig-out/bin/mathzig_wasm.wasm')
        ? './zig-out/bin/mathzig_wasm.wasm'
        : wasmPath;
    const wasmBuffer = readFileSync(resolvedPath);
    const { instance } = await WebAssembly.instantiate(wasmBuffer, {
      env: {
        // Provide any required imports if necessary
      }
    });

    const exports = instance.exports as any;
    const ctx = exports.mathzig_create();
    if (!ctx) {
      throw new Error('Failed to create MathZig context in WASM');
    }

    return new MathZigWasm(instance, exports.memory, ctx);
  }

  private get exports(): any {
    return this.instance.exports;
  }

  private allocString(str: string): number {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(str + '\0');
    const ptr = this.exports.wasm_malloc(bytes.length);
    if (!ptr) throw new Error('WASM memory allocation failed');
    
    const view = new Uint8Array(this.memory.buffer, ptr, bytes.length);
    view.set(bytes);
    return ptr;
  }

  private freeString(ptr: number): void {
    this.exports.wasm_free(ptr);
  }

  eval(expr: string): number {
    const ptr = this.allocString(expr);
    try {
      return this.exports.mathzig_eval(this.ctx, ptr);
    } finally {
      this.freeString(ptr);
    }
  }

  compile(expr: string): CompiledExprWasm {
    const ptr = this.allocString(expr);
    try {
      const compiledPtr = this.exports.mathzig_compile(this.ctx, ptr);
      if (!compiledPtr) {
        throw new Error(`Failed to compile expression: ${expr}`);
      }
      this.ownedExprs.add(compiledPtr);
      return new CompiledExprWasm(this, compiledPtr);
    } finally {
      this.freeString(ptr);
    }
  }

  setVariable(name: string, value: number): void {
    const ptr = this.allocString(name);
    try {
      this.exports.mathzig_set_variable(this.ctx, ptr, value);
    } finally {
      this.freeString(ptr);
    }
  }

  addVariableIndexed(name: string, value: number = 0): number {
    const ptr = this.allocString(name);
    try {
      return this.exports.mathzig_add_variable_indexed(this.ctx, ptr, value);
    } finally {
      this.freeString(ptr);
    }
  }

  setByIndex(index: number, value: number): void {
    this.exports.mathzig_set_by_index(this.ctx, index, value);
  }

  /**
   * Create a Time-Series in WASM memory
   */
  createSeries(timestamps: Float64Array, values: Float64Array, mode: SampleMode = SampleMode.Linear): number {
    if (timestamps.length !== values.length) {
      throw new Error('Timestamps and values must have the same length');
    }
    
    const count = timestamps.length;
    const tsPtr = this.malloc(count * 8);
    const valPtr = this.malloc(count * 8);
    const mem = new DataView(this.memory.buffer);
    for (let i = 0; i < count; i++) {
      mem.setFloat64(tsPtr + i * 8, timestamps[i], true);
      mem.setFloat64(valPtr + i * 8, values[i], true);
    }
    
    const series = this.exports.mathzig_create_series(this.ctx, tsPtr, valPtr, count, mode);
    
    // We can free the temporary arrays because Zig's create_series copies them into SoA layout
    this.free(tsPtr);
    this.free(valPtr);
    
    if (!series) {
      throw new Error('Failed to create series in WASM');
    }
    return series;
  }

  /**
   * Free a series object in WASM memory
   */
  freeSeries(series: number): void {
    this.exports.mathzig_free_series(series);
  }

  /**
   * Bind a series object to a variable name
   */
  setSeries(name: string, series: number): void {
    const ptr = this.allocString(name);
    try {
      const success = this.exports.mathzig_set_series(this.ctx, ptr, series);
      if (!success) {
        throw new Error(`Failed to set series variable: ${name}`);
      }
    } finally {
      this.freeString(ptr);
    }
  }

  /**
   * Get direct pointer to f64 variable storage in WASM memory
   */
  getVariablesPtr(): number {
    return this.exports.mathzig_get_variables_ptr(this.ctx);
  }

  /**
   * Allocate memory in WASM heap
   */
  malloc(size: number): number {
    return this.exports.wasm_malloc(size);
  }

  /**
   * Free memory in WASM heap
   */
  free(ptr: number): void {
    this.exports.wasm_free(ptr);
  }

  /**
   * Compile a polynomial expression using specialized Horner opcode
   */
  compilePolynomial(varIndex: number, coefficients: Float64Array): CompiledExprWasm {
    // Allocate space for coefficients in WASM memory
    const coeffPtr = this.malloc(coefficients.length * 8);
    try {
      const mem = new DataView(this.memory.buffer);
      for (let i = 0; i < coefficients.length; i++) {
        mem.setFloat64(coeffPtr + i * 8, coefficients[i], true);
      }

      const compiledPtr = this.exports.mathzig_compile_polynomial(this.ctx, varIndex, coeffPtr, coefficients.length);
      if (!compiledPtr) {
        throw new Error(`Failed to compile polynomial`);
      }
      this.ownedExprs.add(compiledPtr);
      return new CompiledExprWasm(this, compiledPtr);
    } finally {
      this.free(coeffPtr);
    }
  }

  version(): string {
    const ptr = this.exports.mathzig_version(this.ctx);
    return this.readCString(ptr);
  }

  private readCString(ptr: number): string {
    if (!ptr) return '';
    const view = new Uint8Array(this.memory.buffer, ptr);
    let len = 0;
    while (view[len] !== 0) len++;
    const bytes = new Uint8Array(this.memory.buffer, ptr, len);
    return new TextDecoder().decode(bytes);
  }

  destroy(): void {
    // Free all owned expressions
    for (const exprPtr of this.ownedExprs) {
      this.exports.mathzig_free_expr(this.ctx, exprPtr);
    }
    this.ownedExprs.clear();
    this.exports.mathzig_destroy(this.ctx);
  }

  // Internal access for CompiledExprWasm
  _getExports(): any { return this.exports; }
  _getCtx(): number { return this.ctx; }
  _getMemory(): WebAssembly.Memory { return this.memory; }
  _forgetExpr(ptr: number): void { this.ownedExprs.delete(ptr); }
}

export class CompiledExprWasm {
  constructor(private owner: MathZigWasm, private ptr: number) {}

  evaluate(): number {
    return this.owner._getExports().mathzig_evaluate(this.owner._getCtx(), this.ptr);
  }

  /**
   * Evaluate with batch inputs using SIMD (WASM SIMD128)
   */
  evaluateBatchSIMD(varIndex: number, inputsPtr: number, outputsPtr: number, count: number): void {
    this.owner._getExports().mathzig_batch_eval_simd(
      this.owner._getCtx(),
      this.ptr,
      varIndex,
      inputsPtr,
      outputsPtr,
      count
    );
  }

  /**
   * Evaluate with batch inputs
   */
  evaluateBatch(varIndex: number, inputsPtr: number, outputsPtr: number, count: number): number {
    return this.owner._getExports().mathzig_evaluate_batch(
      this.owner._getCtx(),
      this.ptr,
      varIndex,
      inputsPtr,
      outputsPtr,
      count
    );
  }

  /**
   * High-level batch eval helper for JS arrays/Float64Array.
   * Allocates temporary WASM buffers and returns a new output array.
   */
  evaluateBatchArray(varIndex: number, inputs: number[] | Float64Array): Float64Array {
    const inArray = Array.isArray(inputs) ? new Float64Array(inputs) : inputs;
    const count = inArray.length;
    if (count === 0) return new Float64Array(0);

    const bytes = count * 8;
    const inPtr = this.owner.malloc(bytes);
    const outPtr = this.owner.malloc(bytes);
    try {
      const mem = new DataView(this.owner._getMemory().buffer);
      for (let i = 0; i < count; i++) {
        mem.setFloat64(inPtr + i * 8, inArray[i], true);
      }
      this.evaluateBatch(varIndex, inPtr, outPtr, count);
      const out = new Float64Array(count);
      for (let i = 0; i < count; i++) {
        out[i] = mem.getFloat64(outPtr + i * 8, true);
      }
      return out;
    } finally {
      this.owner.free(inPtr);
      this.owner.free(outPtr);
    }
  }

  /**
   * High-level SIMD batch eval helper for JS arrays/Float64Array.
   * Allocates temporary WASM buffers and returns a new output array.
   */
  evaluateBatchSIMDArray(varIndex: number, inputs: number[] | Float64Array): Float64Array {
    const inArray = Array.isArray(inputs) ? new Float64Array(inputs) : inputs;
    const count = inArray.length;
    if (count === 0) return new Float64Array(0);

    const bytes = count * 8;
    const inPtr = this.owner.malloc(bytes);
    const outPtr = this.owner.malloc(bytes);
    try {
      const mem = new DataView(this.owner._getMemory().buffer);
      for (let i = 0; i < count; i++) {
        mem.setFloat64(inPtr + i * 8, inArray[i], true);
      }
      this.evaluateBatchSIMD(varIndex, inPtr, outPtr, count);
      const out = new Float64Array(count);
      for (let i = 0; i < count; i++) {
        out[i] = mem.getFloat64(outPtr + i * 8, true);
      }
      return out;
    } finally {
      this.owner.free(inPtr);
      this.owner.free(outPtr);
    }
  }

  free(): void {
    this.owner._getExports().mathzig_free_expr(this.owner._getCtx(), this.ptr);
    this.owner._forgetExpr(this.ptr);
  }
}
