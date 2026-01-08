///! MathZig TypeScript Bindings for Unified FFI/WASM
///! 
///! Usage:
///!   import { MathZig } from './mathzig';

import { ptr, toArrayBuffer } from 'bun:ffi';
import { getLibPath } from "../bindings/generated/loader";
import { FFIBackend } from "../bindings/generated/ffi_backend";
import type { Backend } from "../bindings/backend";
import * as generated from "../bindings/generated/classes";

export { toArrayBuffer, ptr };
export type { Backend };

export enum SampleMode {
  Step = 0,
  Linear = 1,
  Cumulative = 2,
}

export enum ValueTag {
  Number = 0,
  Complex = 1,
  Unit = 2,
  Matrix = 3,
  Series = 4,
  Predicate = 5,
  String = 6,
  Boolean = 7,
  Function = 8,
  Array = 9,
  Record = 10,
  Slice = 11,
  Undefined = 12,
  Null = 13,
  Error = 14,
}

let defaultBackend: Backend | null = null;

export function getDefaultBackend(): Backend {
  if (!defaultBackend) {
    defaultBackend = new FFIBackend(getLibPath());
  }
  return defaultBackend;
}

export function setDefaultBackend(backend: Backend) {
  defaultBackend = backend;
}

type ManagedView = { ptr: any; view: Float64Array };

const freedPtrs = new Set<any>();
const managedViewsByPtr = new Map<any, Set<Float64Array>>();

const matrixRegistry = new FinalizationRegistry((held: ManagedView) => {
  if (freedPtrs.has(held.ptr)) return;
  const views = managedViewsByPtr.get(held.ptr);
  if (!views) return;
  views.delete(held.view);
  if (views.size > 0) return;
  managedViewsByPtr.delete(held.ptr);
  try {
    getDefaultBackend().call("mathzig_free", held.ptr);
  } catch (e) {
    console.error("Failed to free matrix memory:", e);
  }
});

function registerManagedView(view: Float64Array, ptr: any): void {
  let views = managedViewsByPtr.get(ptr);
  if (!views) {
    views = new Set();
    managedViewsByPtr.set(ptr, views);
  }
  views.add(view);
  matrixRegistry.register(view, { ptr, view });
}

function releaseManagedPtr(ptr: any): void {
  if (freedPtrs.has(ptr)) return;
  freedPtrs.add(ptr);
  const views = managedViewsByPtr.get(ptr);
  if (!views) return;
  for (const view of views) {
    matrixRegistry.unregister(view);
  }
  managedViewsByPtr.delete(ptr);
}

export class MathZig extends generated.MathZig {
  static create(backend?: Backend): MathZig {
    const be = backend || getDefaultBackend();
    const h = be.call("mathzig_create");
    if (!h) throw new Error('Failed to create MathZig context');
    return new MathZig(be, h);
  }

  static allocAligned(alignment: number, size: number, backend?: Backend): any {
    const be = backend || getDefaultBackend();
    return be.call("mathzig_alloc_aligned", BigInt(alignment), BigInt(size));
  }

  static free(p: any, backend?: Backend): void {
    const be = backend || getDefaultBackend();
    releaseManagedPtr(p);
    be.call("mathzig_free", p);
  }

  static toFloat64Array(
    p: any,
    count: number,
    backend?: Backend,
    options?: { managed?: boolean },
  ): Float64Array {
    const be = backend || getDefaultBackend();
    const buf = be.toArrayBuffer(p, count * 8);
    const arr = new Float64Array(buf, 0, count);
    if (options?.managed) {
      registerManagedView(arr, p);
    }
    return arr;
  }

  static createMatrix(rows: number, cols: number, backend?: Backend): Float64Array {
    const be = backend || getDefaultBackend();
    const p = MathZig.allocAligned(32, rows * cols * 8, be);
    return MathZig.toFloat64Array(p, rows * cols, be, { managed: true });
  }

  compile(expr: string): CompiledExpr {
    const res = super.compile(expr);
    return new CompiledExpr(this.backend, res.handle, this);
  }

  eval(expr: string): any {
    const res = super.eval(expr);
    return Value.unwrap(this, res);
  }

  compilePolynomial(var_index: number, coefficients: Float64Array, count?: number): CompiledExpr {
    const res = super.compilePolynomial(var_index, coefficients, count ?? coefficients.length);
    return new CompiledExpr(this.backend, res.handle, this);
  }

  getVariablesPtr(): any { return super.getVariablesPtr(); }
  getError(): string { return super.getError(); }

  getFunctions(): string[] {
    const json = super.getFunctions();
    try {
      return JSON.parse(json);
    } catch (e) {
      return [];
    }
  }
  getMemoryUsed(): number { return super.getMemoryUsed(); }
  getMemoryReserved(): number { return super.getMemoryReserved(); }
  getMemoryPeak(): number { return super.getMemoryPeak(); }

  createSeries(timestamps: Float64Array, values: Float64Array, mode: SampleMode = SampleMode.Linear): any {
    return super.createSeries(timestamps, values, timestamps.length, mode);
  }

  setSeries(name: string, series: any): boolean {
    return super.setSeries(name, series);
  }

  matmulSIMD(a: Float64Array, b: Float64Array): Float64Array {
    const n = Math.sqrt(a.length);
    const result = MathZig.createMatrix(n, n, this.backend);
    const matA = new generated.Matrix(this.backend, n, n, a);
    const matB = new generated.Matrix(this.backend, n, n, b);
    const matC = new generated.Matrix(this.backend, n, n, result);
    matA.multiplyParallel(this, matB, matC);
    return result;
  }
}

export class Value extends generated.Value {
  constructor(backend: Backend, handle: any, tag?: number, num?: number, public owner?: MathZig) {
    super(backend, handle, tag, num, owner);
  }
  get type(): number { return this.tag; }

  override toNumber(): number {
    if (this.tag === ValueTag.Unit || this.tag === ValueTag.Number || this.tag === ValueTag.Boolean) {
        return this.num;
    }
    return super.toNumber();
  }

  get value(): any {
    if (this.tag === ValueTag.Number) return this.num;
    if (this.tag === ValueTag.Boolean) return this.num !== 0;
    if (this.tag === ValueTag.Null) return null;
    if (this.tag === ValueTag.Undefined) return undefined;
    if (this.tag === ValueTag.Record) return new Record(this.backend, this.handle, this.owner);
    if (this.tag === ValueTag.Series) return new Series(this.backend, this.handle, this.owner);
    if (this.tag === ValueTag.Matrix) return Matrix.fromPointer(this.handle, this.backend);
    if (this.tag === ValueTag.Unit) return this.toNumber();
    if (this.tag === ValueTag.Complex) {
        return { re: (this as any).real(), im: (this as any).imag() };
    }
    return this;
  }

  static unwrap(owner: MathZig, res: any): any {
    if (res instanceof generated.Value) {
      const v = new Value(owner.backend, res.handle, res.tag, res.num, owner);
      if (v.tag === ValueTag.Number) { return v.num; }
      if (v.tag === ValueTag.Boolean) { return v.num !== 0; }
      if (v.tag === ValueTag.Null) { return null; }
      if (v.tag === ValueTag.Undefined) { return undefined; }
      
      if (v.tag === ValueTag.Record) return new Record(owner.backend, v.handle, owner);
      if (v.tag === ValueTag.Series) return new Series(owner.backend, v.handle, owner);
      if (v.tag === ValueTag.Matrix) return Matrix.fromPointer(v.handle, owner.backend);
      return v;
    }
    return res;
  }
}

export class Record extends generated.Record {
  constructor(backend: Backend, handle: any, public owner?: MathZig) {
    super(backend, handle);
  }
  retain() { this.backend.call("mathzig_retain", this.handle, ValueTag.Record); }
  release() { this.backend.call("mathzig_release", this.handle, ValueTag.Record); }
  getField(key: string): any {
    const res = super.getField(key);
    if (this.owner) return Value.unwrap(this.owner, res);
    return res;
  }
}

export class Series extends generated.Series {
  constructor(backend: Backend, handle: any, public owner?: MathZig) {
    super(backend, handle);
  }
  retain() { this.backend.call("mathzig_retain", this.handle, ValueTag.Series); }
  release() { this.backend.call("mathzig_release", this.handle, ValueTag.Series); }
}

export class CompiledExpr extends generated.CompiledExpr {
  constructor(backend: Backend, handle: any, public owner: MathZig) {
    super(backend, handle);
  }

  evaluate(): any {
    const res = super.evaluate(this.owner as any);
    return Value.unwrap(this.owner, res);
  }

  evaluateFast(): number {
    return super.evaluateFast(this.owner as any);
  }

  evaluateBatch(var_index: number, inputs: number[] | Float64Array, outputs?: Float64Array, count?: number): any {
    if (Array.isArray(inputs)) {
      const n = count ?? inputs.length;
      if (n < 0 || n > inputs.length) {
        throw new RangeError(`evaluateBatch: count ${n} out of range for inputs length ${inputs.length}`);
      }
      const inputsArray = new Float64Array(inputs);
      if (outputs) {
        if (outputs.length < n) {
          throw new RangeError(`evaluateBatch: outputs length ${outputs.length} < count ${n}`);
        }
        super.evaluateBatch(this.owner as any, var_index, inputsArray, outputs, n);
        return outputs;
      }
      const outputsArray = new Float64Array(n);
      super.evaluateBatch(this.owner as any, var_index, inputsArray, outputsArray, n);
      return Array.from(outputsArray);
    }
    return super.evaluateBatch(this.owner as any, var_index, inputs, outputs!, count!);
  }

  evaluateBatchSIMD(var_index: number, inputs: Float64Array, outputs: Float64Array, count: number): void {
    super.evaluateBatchSIMD(this.owner as any, var_index, inputs, outputs, count);
  }

  evaluateBatchParallel(var_index: number, inputs: Float64Array, outputs: Float64Array, count: number): void {
    super.evaluateBatchParallel(this.owner as any, var_index, inputs, outputs, count);
  }

  evaluateBatchComplexSIMD(var_index: number, re_in: Float64Array, im_in: Float64Array, re_out: Float64Array, im_out: Float64Array, count: number): void {
    super.evaluateBatchComplexSIMD(this.owner as any, var_index, re_in, im_in, re_out, im_out, count);
  }

  free(): void {
    this.owner.freeExpr(this as any);
  }
}

/**
 * Matrix wrapper that uses default backend when none is provided.
 */
export class Matrix extends generated.Matrix {
  static fromPointer(p: any, backend?: Backend): Matrix {
    const be = backend || getDefaultBackend();
    const rows = be.call("mathzig_matrix_rows", p);
    const cols = be.call("mathzig_matrix_cols", p);
    const dataPtr = be.call("mathzig_matrix_get_data", p);
    const count = rows * cols;
    const buf = be.toArrayBuffer(dataPtr, count * 8);
    const arr = new Float64Array(buf, 0, count);
    const mat = new Matrix(be, rows, cols, arr);
    return mat;
  }

  constructor(rowsOrBackend: number | Backend, colsOrRows?: number, dataOrCols?: Float64Array | number, data?: Float64Array) {
    // Support both (rows, cols, data?) and (backend, rows, cols, data?)
    if (typeof rowsOrBackend === 'number') {
      // Called as Matrix(rows, cols, data?)
      const be = getDefaultBackend();
      const rows = rowsOrBackend;
      const cols = colsOrRows as number;
      super(be, rows, cols, dataOrCols as Float64Array | undefined);
      if (!dataOrCols) {
        registerManagedView(this.data, ptr(this.data));
      }
    } else {
      // Called as Matrix(backend, rows, cols, data?)
      const be = rowsOrBackend;
      const rows = colsOrRows as number;
      const cols = dataOrCols as number;
      super(be, rows, cols, data);
      if (!data) {
        registerManagedView(this.data, ptr(this.data));
      }
    }
  }
}

/**
 * Vector wrapper that uses default backend when none is provided.
 */
export class Vector extends generated.Vector {
  constructor(dataOrLenOrBackend: Float64Array | number | Backend, dataOrLen?: Float64Array | number) {
    // Support both (dataOrLen) and (backend, dataOrLen)
    if (typeof dataOrLenOrBackend === 'object' && !('call' in dataOrLenOrBackend)) {
      // Called as Vector(Float64Array)
      super(getDefaultBackend(), dataOrLenOrBackend as Float64Array);
    } else if (typeof dataOrLenOrBackend === 'number') {
      // Called as Vector(length)
      super(getDefaultBackend(), dataOrLenOrBackend);
    } else {
      // Called as Vector(backend, dataOrLen)
      super(dataOrLenOrBackend as Backend, dataOrLen as Float64Array | number);
    }
  }
}

/**
 * High-level helper for vector addition.
 */
export function vecAdd(a: Float64Array, b: Float64Array, out?: Float64Array): Float64Array {
  const vA = new generated.Vector(getDefaultBackend(), a);
  const vB = new generated.Vector(getDefaultBackend(), b);
  const vOut = out ? new generated.Vector(getDefaultBackend(), out) : undefined;
  return vA.add(vB, vOut).data;
}

/**
 * High-level helper for vector subtraction.
 */
export function vecSub(a: Float64Array, b: Float64Array, out?: Float64Array): Float64Array {
  const vA = new generated.Vector(getDefaultBackend(), a);
  const vB = new generated.Vector(getDefaultBackend(), b);
  const vOut = out ? new generated.Vector(getDefaultBackend(), out) : undefined;
  return vA.sub(vB, vOut).data;
}

/**
 * High-level helper for vector dot product.
 */
export function vecDot(a: Float64Array, b: Float64Array): number {
  const vA = new generated.Vector(getDefaultBackend(), a);
  const vB = new generated.Vector(getDefaultBackend(), b);
  return vA.dot(vB);
}

/**
 * High-level helper for vector norm.
 */
export function vecNorm(a: Float64Array): number {
  const v = new generated.Vector(getDefaultBackend(), a);
  return v.norm();
}

/**
 * High-level helper for vector scaling.
 */
export function vecScale(alpha: number, a: Float64Array, out?: Float64Array): Float64Array {
  const v = new generated.Vector(getDefaultBackend(), a);
  const vOut = out ? new generated.Vector(getDefaultBackend(), out) : undefined;
  return v.scale(alpha, vOut).data;
}

/**
 * High-level helper for in-place vector scaling.
 */
export function vecScaleInplace(alpha: number, a: Float64Array): void {
  const v = new generated.Vector(getDefaultBackend(), a);
  v.scaleInplace(alpha);
}

/**
 * High-level helper for vector AXPY (y = alpha*x + y).
 */
export function vecAxpy(alpha: number, x: Float64Array, y: Float64Array): void {
  const vX = new generated.Vector(getDefaultBackend(), x);
  const vY = new generated.Vector(getDefaultBackend(), y);
  vX.axpy(alpha, vY);
}

/**
 * High-level helper for Matrix-Vector multiplication.
 */
export function gemv(rows: number, cols: number, alpha: number, A: Float64Array, stride_a: number, x: Float64Array, beta: number, y: Float64Array): void {
  const matA = new generated.Matrix(getDefaultBackend(), rows, cols, A);
  matA.stride = stride_a;
  matA.gemv(alpha, stride_a, x, beta, y);
}

/**
 * High-level helper for simple Matrix-Vector multiplication.
 */
export function gemvSimple(rows: number, cols: number, A: Float64Array, stride_a: number, x: Float64Array, y: Float64Array): void {
  const matA = new generated.Matrix(getDefaultBackend(), rows, cols, A);
  matA.stride = stride_a;
  matA.gemvSimple(stride_a, x, y);
}

/**
 * High-level helper for Matrix-Matrix multiplication.
 */
export function gemm(rowsA: number, colsA: number, colsB: number, A: Float64Array, strideA: number, B: Float64Array, strideB: number, C: Float64Array, strideC: number): void {
  const matA = new generated.Matrix(getDefaultBackend(), rowsA, colsA, A);
  matA.stride = strideA;
  const matB = new generated.Matrix(getDefaultBackend(), colsA, colsB, B);
  matB.stride = strideB;
  const matC = new generated.Matrix(getDefaultBackend(), rowsA, colsB, C);
  matC.stride = strideC;
  matA.multiply(matB, matC);
}

/**
 * High-level helper to evaluate an expression once.
 */
export function evalExpression(expr: string): number {
  const ctx = MathZig.create();
  try {
    const res = ctx.eval(expr);
    if (typeof res === 'number') return res;
    if (res instanceof Value) {
      const num = res.toNumber();
      res.release();
      return num;
    }
    return Number(res);
  } finally {
    ctx.destroy();
  }
}

/**
 * High-level helper for batch evaluation.
 */
export function evaluateBatch(expr: string, varName: string, inputs: number[]): number[] {
  const ctx = MathZig.create();
  try {
    const varIndex = ctx.addVariableIndexed(varName, 0);
    const compiled = ctx.compile(expr);
    try {
      const inputsArray = new Float64Array(inputs);
      const outputsArray = new Float64Array(inputs.length);
      compiled.evaluateBatch(varIndex, inputsArray, outputsArray, inputs.length);
      return Array.from(outputsArray);
    } finally {
      compiled.free();
    }
  } finally {
    ctx.destroy();
  }
}
