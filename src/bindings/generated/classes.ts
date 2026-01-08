import type { Backend, Pointer } from "../backend";

export class MathZig {
  public handle: Pointer;
  constructor(public backend: Backend, handle: Pointer) {
    this.handle = handle;
  }

  static create(backend: Backend): MathZig {
    const h = backend.call("mathzig_create");
    if (!h) throw new Error("Failed to create MathZig context");
    return new MathZig(backend, h);
  }

  destroy(): void {
    this.backend.call("mathzig_destroy", this.handle);
  }
  compile(expr: string): CompiledExpr {
    const expr_ptr = this.backend.ptr(expr);
    try {
      const res = this.backend.call("mathzig_compile", this.handle, expr_ptr);
      if (!res) throw new Error(`MathZig error in compile: ${this instanceof MathZig ? (this as any).getError() : 'Failed to create handle'}`);
      return new CompiledExpr(this.backend, res);
    } finally {
    this.backend.freeTemporary(expr_ptr);
    }
  }

  freeExpr(expr: CompiledExpr): void {
    this.backend.call("mathzig_free_expr", this.handle, expr.handle);
  }

  eval(expr: string): Value {
    const expr_ptr = this.backend.ptr(expr);
    try {
      this.backend.call("mathzig_eval", this.handle, expr_ptr);
      const tag = Number(this.backend.call("mathzig_get_last_tag"));
      const num = Number(this.backend.call("mathzig_get_last_number"));
      if (tag === 14) throw new Error(`MathZig error in eval: ${this.getError()}`);
      if (tag === 0) return num; // Number
      if (tag === 7) return num !== 0; // Boolean
      if (tag === 13) return null; // Null
      if (tag === 12) return undefined; // Undefined
      const p = this.backend.call("mathzig_get_last_ptr") || 0;
      const v = new Value(this.backend, p, tag, num, this);
      // Retain ref-counted types because last_value will be released on next call
      if (tag === 3 || tag === 4 || tag === 10 || tag === 9) { // Matrix, Series, Record, Array
          v.retain();
      }
      return v;
    } finally {
    this.backend.freeTemporary(expr_ptr);
    }
  }

  setVariable(name: string, val: number): void {
    const name_ptr = this.backend.ptr(name);
    try {
      this.backend.call("mathzig_set_variable", this.handle, name_ptr, val);
    } finally {
    this.backend.freeTemporary(name_ptr);
    }
  }

  addVariableIndexed(name: string, initial_val: number): number {
    const name_ptr = this.backend.ptr(name);
    try {
      const res = this.backend.call("mathzig_add_variable_indexed", this.handle, name_ptr, initial_val);
      return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
    } finally {
    this.backend.freeTemporary(name_ptr);
    }
  }

  setByIndex(index: number, val: number): void {
    this.backend.call("mathzig_set_by_index", this.handle, index, val);
  }

  setByIndexFast(index: number, val: number): void {
    this.backend.call("mathzig_set_by_index_fast", this.handle, index, val);
  }

  getVariablesPtr(): Float64Array | Pointer {
    return this.backend.call("mathzig_get_variables_ptr", this.handle);
  }

  toLaTeX(expr: string): string {
    const expr_ptr = this.backend.ptr(expr);
    try {
      return this.backend.readString(this.backend.call("mathzig_to_latex", this.handle, expr_ptr));
    } finally {
    this.backend.freeTemporary(expr_ptr);
    }
  }

  getError(): string {
    return this.backend.readString(this.backend.call("mathzig_get_error", this.handle));
  }

  getMemoryUsed(): number {
    const res = this.backend.call("mathzig_get_memory_used", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getMemoryReserved(): number {
    const res = this.backend.call("mathzig_get_memory_reserved", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getMemoryPeak(): number {
    const res = this.backend.call("mathzig_get_memory_peak", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  resetMemory(): void {
    this.backend.call("mathzig_reset_memory", this.handle);
  }

  version(): string {
    return this.backend.readString(this.backend.call("mathzig_version", this.handle));
  }

  getFunctions(): string {
    return this.backend.readString(this.backend.call("mathzig_get_functions", this.handle));
  }

  createSeries(timestamps: Float64Array | Pointer, values: Float64Array | Pointer, count: number, sample_mode: number): Series {
    const res = this.backend.call("mathzig_create_series", this.handle, this.backend.ptr(timestamps), this.backend.ptr(values), count, sample_mode);
    if (!res) throw new Error(`MathZig error in createSeries: ${this instanceof MathZig ? (this as any).getError() : 'Failed to create handle'}`);
    return new Series(this.backend, res);
  }

  compilePolynomial(var_index: number, coefficients: Float64Array | Pointer, count: number): CompiledExpr {
    const res = this.backend.call("mathzig_compile_polynomial", this.handle, var_index, this.backend.ptr(coefficients), count);
    if (!res) throw new Error(`MathZig error in compilePolynomial: ${this instanceof MathZig ? (this as any).getError() : 'Failed to create handle'}`);
    return new CompiledExpr(this.backend, res);
  }

  setSeries(name: string, series: string | Uint8Array | Pointer): boolean {
    const name_ptr = this.backend.ptr(name);
    try {
      return this.backend.call("mathzig_set_series", this.handle, name_ptr, this.backend.ptr(series));
    } finally {
    this.backend.freeTemporary(name_ptr);
    }
  }

  setDebug(debug: boolean): void {
    this.backend.call("mathzig_set_debug", this.handle, debug);
  }

  writeCsv(var_name: string, path: string): boolean {
    const var_name_ptr = this.backend.ptr(var_name);
    const path_ptr = this.backend.ptr(path);
    try {
      return this.backend.call("mathzig_write_csv", this.handle, var_name_ptr, path_ptr);
    } finally {
    this.backend.freeTemporary(var_name_ptr);
    this.backend.freeTemporary(path_ptr);
    }
  }

  getLastErrorOffset(): number {
    const res = this.backend.call("mathzig_get_last_error_offset", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  recordNew(): Pointer {
    return this.backend.call("mathzig_record_new", this.handle);
  }

  recordSetWire(rec: Pointer, key: string, wire: number, kind: number): boolean {
    const key_ptr = this.backend.ptr(key);
    try {
      return this.backend.call("mathzig_record_set_wire", this.handle, rec, key_ptr, wire, kind);
    } finally {
    this.backend.freeTemporary(key_ptr);
    }
  }

  callBuiltinWire(builtin_id: number, argc: number, args_ptr: Float64Array | Pointer, kinds_ptr: string | Uint8Array | Pointer, pred_ptr: string | Uint8Array | Pointer): number {
    return this.backend.call("mathzig_call_builtin", this.handle, builtin_id, argc, this.backend.ptr(args_ptr), kinds_ptr, pred_ptr);
  }

}

export class CompiledExpr {
  public handle: Pointer;
  constructor(public backend: Backend, handle: Pointer) {
    this.handle = handle;
  }

  evaluate(ctx: MathZig): Value {
    this.backend.call("mathzig_evaluate", ctx.handle, this.handle);
    const tag = Number(this.backend.call("mathzig_get_last_tag"));
    const num = Number(this.backend.call("mathzig_get_last_number"));
    if (tag === 14) throw new Error(`MathZig error in evaluate: ${ctx.getError()}`);
    if (tag === 0) return num; // Number
    if (tag === 7) return num !== 0; // Boolean
    if (tag === 13) return null; // Null
    if (tag === 12) return undefined; // Undefined
    const p = this.backend.call("mathzig_get_last_ptr") || 0;
    const v = new Value(this.backend, p, tag, num, ctx);
    // Retain ref-counted types because last_value will be released on next call
    if (tag === 3 || tag === 4 || tag === 10 || tag === 9) { // Matrix, Series, Record, Array
        v.retain();
    }
    return v;
  }

  evaluateFast(ctx: MathZig): number {
    return this.backend.call("mathzig_evaluate_fast", ctx.handle, this.handle);
  }

  getBytecodeSize(): number {
    const res = this.backend.call("mathzig_expr_bytecode_size", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getNumInstructions(): number {
    const res = this.backend.call("mathzig_expr_num_instructions", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getNumVariables(): number {
    const res = this.backend.call("mathzig_expr_num_variables", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getNumConstants(): number {
    const res = this.backend.call("mathzig_expr_num_constants", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getStackSize(): number {
    const res = this.backend.call("mathzig_expr_stack_size", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  evaluateBatch(ctx: MathZig, var_index: number, inputs: Float64Array | Pointer, outputs: Float64Array | Pointer, count: number): number {
    const res = this.backend.call("mathzig_evaluate_batch", ctx.handle, this.handle, var_index, this.backend.ptr(inputs), this.backend.ptr(outputs), count);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  evaluateBatchSIMD(ctx: MathZig, var_index: number, inputs: Float64Array | Pointer, outputs: Float64Array | Pointer, count: number): void {
    this.backend.call("mathzig_batch_eval_simd", ctx.handle, this.handle, var_index, this.backend.ptr(inputs), this.backend.ptr(outputs), count);
  }

  evaluateBatchParallel(ctx: MathZig, var_index: number, inputs: Float64Array | Pointer, outputs: Float64Array | Pointer, count: number): void {
    this.backend.call("mathzig_batch_eval_parallel", ctx.handle, this.handle, var_index, this.backend.ptr(inputs), this.backend.ptr(outputs), count);
  }

  evaluateBatchComplexSIMD(ctx: MathZig, var_index: number, re_in: Float64Array | Pointer, im_in: Float64Array | Pointer, re_out: Float64Array | Pointer, im_out: Float64Array | Pointer, count: number): void {
    this.backend.call("mathzig_batch_eval_complex_simd", ctx.handle, this.handle, var_index, this.backend.ptr(re_in), this.backend.ptr(im_in), this.backend.ptr(re_out), this.backend.ptr(im_out), count);
  }

}

export class Value {
  public handle: Pointer;
  public tag: number;
  public num: number;
  public owner?: any; // To avoid circular dependency
  constructor(public backend: Backend, handle: Pointer, tag?: number, num?: number, owner?: any) {
    this.handle = handle;
    this.tag = tag ?? Number(backend.call("mathzig_get_last_tag"));
    this.num = num ?? Number(backend.call("mathzig_get_last_number"));
    this.owner = owner;
  }

  get value(): any {
    if (this.tag === 0) return this.num;
    if (this.tag === 7) return this.num !== 0;
    if (this.tag === 13) return null;
    if (this.tag === 12) return undefined;
    if (this.tag === 10) return new Record(this.backend, this.handle);
    if (this.tag === 4) return new Series(this.backend, this.handle);
    if (this.tag === 3) return new Matrix(this.backend, 0, 0, undefined); // handle will be used, rows/cols might need separate fetch if not in Value
    return this;
  }

  retain(): void {
    this.backend.call("mathzig_retain", this.handle, this.tag);
  }

  release(): void {
    this.backend.call("mathzig_release", this.handle, this.tag);
  }

  toNumber(): number {
    return Number(this.backend.call("mathzig_value_to_number", this.handle, this.tag));
  }
  real(): number {
    return this.backend.call("mathzig_value_real", this.handle);
  }

  imag(): number {
    return this.backend.call("mathzig_value_imag", this.handle);
  }

}

export class Record {
  public handle: Pointer;
  constructor(public backend: Backend, handle: Pointer) {
    this.handle = handle;
  }

  len(): number {
    const res = this.backend.call("mathzig_record_len", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getField(key: string): Value {
    const key_ptr = this.backend.ptr(key);
    try {
      this.backend.call("mathzig_record_get_field", this.handle, key_ptr);
      const tag = Number(this.backend.call("mathzig_get_last_tag"));
      const num = Number(this.backend.call("mathzig_get_last_number"));
      if (tag === 14) throw new Error(`MathZig error in getField`);
      if (tag === 0) return num; // Number
      if (tag === 7) return num !== 0; // Boolean
      if (tag === 13) return null; // Null
      if (tag === 12) return undefined; // Undefined
      const p = this.backend.call("mathzig_get_last_ptr") || 0;
      const v = new Value(this.backend, p, tag, num, undefined);
      // Retain ref-counted types because last_value will be released on next call
      if (tag === 3 || tag === 4 || tag === 10 || tag === 9) { // Matrix, Series, Record, Array
          v.retain();
      }
      return v;
    } finally {
    this.backend.freeTemporary(key_ptr);
    }
  }

  keyAt(index: number): string {
    return this.backend.readString(this.backend.call("mathzig_record_key_at", this.handle, index));
  }

  valueWireAt(index: number): number {
    return this.backend.call("mathzig_record_value_wire_at", this.handle, index);
  }

  valueKindAt(index: number): number {
    return this.backend.call("mathzig_record_value_kind_at", this.handle, index);
  }

}

export class Series {
  public handle: Pointer;
  constructor(public backend: Backend, handle: Pointer) {
    this.handle = handle;
  }

  len(): number {
    const res = this.backend.call("mathzig_series_len", this.handle);
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  duration(): number {
    return this.backend.call("mathzig_series_duration", this.handle);
  }

  getTimestampsPtr(): Float64Array | Pointer {
    return this.backend.call("mathzig_series_get_timestamps_ptr", this.handle);
  }

  getValuesPtr(): Float64Array | Pointer {
    return this.backend.call("mathzig_series_get_values_ptr", this.handle);
  }

  free(): void {
    this.backend.call("mathzig_free_series", this.handle);
  }

}

export class Matrix {
  public data: Float64Array;
  public rows: number;
  public cols: number;
  public stride: number;

  constructor(public backend: Backend, rows: number, cols: number, data?: Float64Array) {
    this.rows = rows;
    this.cols = cols;
    this.stride = cols;
    if (data) {
      this.data = data;
    } else {
      const p = backend.call("mathzig_alloc_aligned", 32n, BigInt(rows * cols * 8));
      if (!p) throw new Error("Failed to allocate matrix data");
      this.data = new Float64Array(backend.toArrayBuffer(p, rows * cols * 8), 0, rows * cols);
    }
  }
  rows(): number {
    const res = this.backend.call("mathzig_matrix_rows", this.backend.ptr(this.data));
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  cols(): number {
    const res = this.backend.call("mathzig_matrix_cols", this.backend.ptr(this.data));
    return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
  }

  getData(): Float64Array | Pointer {
    return this.backend.call("mathzig_matrix_get_data", this.backend.ptr(this.data));
  }

  multiply(other: Matrix, out: Matrix | undefined): Matrix {
    const data_ptr = this.backend.ptr(this.data);
    try {
      const result = out || new Matrix(this.backend, this.rows, (other as any)?.cols || this.cols);
      this.backend.call("mathzig_gemm", this.rows, this.cols, other.cols, data_ptr, this.stride || this.cols, this.backend.ptr(other.data), other.stride || other.cols, this.backend.ptr(result.data), result.stride || result.cols);
      return result;
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  multiplyParallel(ctx: MathZig, other: Matrix, out: Matrix | undefined): Matrix {
    const data_ptr = this.backend.ptr(this.data);
    try {
      const result = out || new Matrix(this.backend, this.rows, (other as any)?.cols || this.cols);
      this.backend.call("mathzig_gemm_parallel", ctx.handle, this.rows, this.cols, other.cols, data_ptr, this.stride || this.cols, this.backend.ptr(other.data), other.stride || other.cols, this.backend.ptr(result.data), result.stride || result.cols);
      return result;
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  inverse(): boolean {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_matrix_inverse", this.rows, data_ptr, this.stride || this.cols, 0);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  determinant(): number {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_determinant", this.rows, data_ptr, this.stride || this.cols, 0);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  gemv(alpha: number, stride_a: number, x: Float64Array | Pointer, beta: number, y: Float64Array | Pointer): void {
    const data_ptr = this.backend.ptr(this.data);
    try {
      this.backend.call("mathzig_gemv", this.rows, this.cols, alpha, data_ptr, stride_a, this.backend.ptr(x), beta, this.backend.ptr(y));
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  gemvSimple(stride_a: number, x: Float64Array | Pointer, y: Float64Array | Pointer): void {
    const data_ptr = this.backend.ptr(this.data);
    try {
      this.backend.call("mathzig_gemv_simple", this.rows, this.cols, data_ptr, stride_a, this.backend.ptr(x), this.backend.ptr(y));
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  sum(): number {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_matrix_sum", this.rows, this.cols, data_ptr);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  mean(): number {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_matrix_mean", this.rows, this.cols, data_ptr);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

}

export class Vector {
  public data: Float64Array;
  public len: number;
  constructor(public backend: Backend, dataOrLen: Float64Array | number) {
    if (typeof dataOrLen === "number") {
      this.len = dataOrLen;
      const p = backend.call("mathzig_alloc_aligned", 32n, BigInt(dataOrLen * 8));
      if (!p) throw new Error("Failed to allocate vector data");
      this.data = new Float64Array(backend.toArrayBuffer(p, dataOrLen * 8), 0, dataOrLen);
    } else {
      this.data = dataOrLen;
      this.len = dataOrLen.length;
    }
  }
  add(other: Vector, out: Vector | undefined): Vector {
    const data_ptr = this.backend.ptr(this.data);
    try {
      const result = out || new Vector(this.backend, new Float64Array(this.data.length));
      this.backend.call("mathzig_vec_add", data_ptr, this.backend.ptr(other.data), this.backend.ptr(result.data), this.len);
      return result;
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  sub(other: Vector, out: Vector | undefined): Vector {
    const data_ptr = this.backend.ptr(this.data);
    try {
      const result = out || new Vector(this.backend, new Float64Array(this.data.length));
      this.backend.call("mathzig_vec_sub", data_ptr, this.backend.ptr(other.data), this.backend.ptr(result.data), this.len);
      return result;
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  dot(other: Vector): number {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_vec_dot", data_ptr, this.backend.ptr(other.data), this.len);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  norm(): number {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_vec_norm", data_ptr, this.len);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  scale(alpha: number, out: Vector | undefined): Vector {
    const data_ptr = this.backend.ptr(this.data);
    try {
      const result = out || new Vector(this.backend, new Float64Array(this.data.length));
      this.backend.call("mathzig_vec_scale", alpha, data_ptr, this.backend.ptr(result.data), this.len);
      return result;
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  scaleInplace(alpha: number): void {
    const data_ptr = this.backend.ptr(this.data);
    try {
      this.backend.call("mathzig_vec_scale_inplace", alpha, data_ptr, this.len);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  axpy(alpha: number, other: Vector): void {
    const data_ptr = this.backend.ptr(this.data);
    try {
      this.backend.call("mathzig_vec_axpy", alpha, data_ptr, this.backend.ptr(other.data), this.len);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  sum(): number {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_vec_sum", data_ptr, this.len);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

  mean(): number {
    const data_ptr = this.backend.ptr(this.data);
    try {
      return this.backend.call("mathzig_vec_mean", data_ptr, this.len);
    } finally {
    this.backend.freeTemporary(data_ptr);
    }
  }

}

