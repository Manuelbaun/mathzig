import { MathZigWasm } from "../../../src/ts/mathzig_wasm";
import type { ParityBackend } from "../cli";

export class TsWasmVmBackend implements ParityBackend {
  name = "ts_wasm_vm";
  private ctx: MathZigWasm | null = null;

  async init(): Promise<void> {
    this.ctx = await MathZigWasm.create();
  }

  // Fresh context per case, like zig_vm's reset — otherwise state from earlier
  // cases (variables shadowing units, accumulated function defs) leaks into
  // later ones and parity compares different effective programs.
  async reset(): Promise<void> {
    if (this.ctx) this.ctx.destroy();
    this.ctx = await MathZigWasm.create();
  }

  evaluate(expr: string, vars: Record<string, number>): any {
    if (!this.ctx) throw new Error("backend not initialized");
    for (const [key, val] of Object.entries(vars)) {
      this.ctx.setVariable(key, val);
    }
    const exports = (this.ctx as any)._getExports();
    const ctxPtr = (this.ctx as any)._getCtx();
    const ptr = allocString(expr, exports);
    try {
      exports.mathzig_eval(ctxPtr, ptr);
      const tag = Number(exports.mathzig_get_last_tag());
      const num = Number(exports.mathzig_get_last_number());
      const valuePtr = Number(exports.mathzig_get_last_ptr?.() ?? 0);
      if (tag === 14) {
        const msg = readLastError(exports, ctxPtr);
        throw new Error(`MathZig error in eval: ${msg}`);
      }
      if (tag === 7) return num !== 0;
      if (tag === 12) return undefined;
      if (tag === 13) return null;
      // ValueTag.string == 6 — return plain string for parity compare / expected.tag=string
      if (tag === 6) {
        return formatLastValueAsString(exports, ctxPtr);
      }
      if (tag === 3) {
        const matrix = readMatrix(exports, valuePtr);
        if (matrix) return { tag, ...matrix };
        // Fall through only if ptr is null/invalid; empty matrices still return matrix.
      }
      // ValueTag.series == 4 — expose len for parity shape checks
      if (tag === 4) {
        const series = readSeries(exports, valuePtr);
        if (series) return { tag, ...series };
        return { tag, ptr: valuePtr, num };
      }
      if (tag === 10 || tag === 2 || tag === 1) {
        return { tag, ptr: valuePtr, num };
      }
      return num;
    } finally {
      exports.wasm_free(ptr);
    }
  }

  dispose(): void {
    if (this.ctx) {
      this.ctx.destroy();
      this.ctx = null;
    }
  }
}

function readLastError(exports: any, ctxPtr: number): string {
  const errPtr = Number(exports.mathzig_get_error?.(ctxPtr) ?? 0);
  if (!Number.isFinite(errPtr) || errPtr === 0) return "Unknown error";
  const bytes = new Uint8Array(exports.memory.buffer);
  let end = errPtr;
  while (end < bytes.length && bytes[end] !== 0) end++;
  return new TextDecoder().decode(bytes.subarray(errPtr, end));
}

function readMatrix(
  exports: any,
  matrixPtr: number
): { rows: number; cols: number; data: Float64Array } | null {
  if (!Number.isFinite(matrixPtr) || matrixPtr === 0) return null;
  const rows = Number(exports.mathzig_matrix_rows(matrixPtr));
  const cols = Number(exports.mathzig_matrix_cols(matrixPtr));
  // Allow 0×N / N×0 / 0×0 empty matrices (parity: zeros(0,0), identity(0), …).
  if (!Number.isFinite(rows) || !Number.isFinite(cols) || rows < 0 || cols < 0) return null;
  const count = rows * cols;
  if (count === 0) {
    return { rows, cols, data: new Float64Array(0) };
  }
  const dataPtr = Number(exports.mathzig_matrix_get_data(matrixPtr));
  if (!Number.isFinite(dataPtr) || dataPtr === 0) return null;
  const raw = new Float64Array(exports.memory.buffer, dataPtr, count);
  return { rows, cols, data: Float64Array.from(raw) };
}

function readSeries(
  exports: any,
  seriesPtr: number
): { len: number; ptr: number } | null {
  if (!Number.isFinite(seriesPtr) || seriesPtr === 0) return null;
  if (typeof exports.mathzig_series_len !== "function") return null;
  const len = Number(exports.mathzig_series_len(seriesPtr));
  if (!Number.isFinite(len) || len < 0) return null;
  return { len, ptr: seriesPtr };
}

/** Decode last value as UTF-8 via mathzig_format_last_value (strips quotes if present). */
function formatLastValueAsString(exports: any, ctxPtr: number): string {
  if (typeof exports.mathzig_format_last_value !== "function") {
    throw new Error("mathzig_format_last_value not exported from wasm");
  }
  const cap = 8192;
  const bufPtr = exports.wasm_malloc(cap);
  if (!bufPtr) throw new Error("WASM alloc failed for format buffer");
  try {
    // WASM bindings expect numeric usize, not BigInt.
    const len = Number(exports.mathzig_format_last_value(ctxPtr, bufPtr, cap));
    if (!Number.isFinite(len) || len <= 0) return "";
    const n = Math.min(len, cap);
    const bytes = new Uint8Array(exports.memory.buffer, Number(bufPtr), n);
    let text = new TextDecoder().decode(bytes);
    // formatValue often wraps strings in quotes for display
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.slice(1, -1);
    }
    return text;
  } finally {
    exports.wasm_free(bufPtr);
  }
}

function allocString(str: string, exports: any): number {
  const encoder = new TextEncoder();
  const bytes = encoder.encode(str + "\0");
  const ptr = exports.wasm_malloc(bytes.length);
  if (!ptr) throw new Error("WASM alloc failed");
  const view = new Uint8Array(exports.memory.buffer, ptr, bytes.length);
  view.set(bytes);
  return ptr;
}
