import { TagNames, ValueTag, type EvalResult } from "./value_tags";

type WasmExports = Record<string, any> & {
  memory: WebAssembly.Memory;
};

export type MathZigRuntime = ReturnType<typeof createMathZigRuntime>;

export function createMathZigRuntime() {
  let wasm: WasmExports | null = null;
  let wasmMemory: WebAssembly.Memory | null = null;
  let ctx: number | null = null;

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function allocString(str: string): number {
    if (!wasm || !wasmMemory) throw new Error("Runtime not ready");
    const bytes = encoder.encode(str + "\0");
    const ptr = wasm.wasm_malloc(bytes.length);
    if (ptr === 0) throw new Error("Failed to allocate memory");
    new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  }

  function freeString(ptr: number, str: string): void {
    if (!wasm) return;
    const bytes = encoder.encode(str + "\0");
    wasm.wasm_free(ptr, bytes.length);
  }

  function readString(ptr: number): string {
    if (!wasmMemory || ptr === 0) return "";
    const view = new Uint8Array(wasmMemory.buffer, ptr);
    let end = 0;
    while (view[end] !== 0 && end < 10000) end++;
    return decoder.decode(view.slice(0, end));
  }

  function readF64(ptr: number): number {
    if (!wasmMemory) return NaN;
    return new Float64Array(wasmMemory.buffer, ptr, 1)[0]!;
  }

  function readU32(ptr: number): number {
    if (!wasmMemory) return 0;
    return new Uint32Array(wasmMemory.buffer, ptr, 1)[0]!;
  }

  function getMatrixView(matrixPtr: number) {
    if (!wasm || !wasmMemory || !matrixPtr) return null;
    try {
      let rows: number;
      let cols: number;
      let stride: number;
      let dataPtr: number;
      if (wasm.mathzig_matrix_rows && wasm.mathzig_matrix_cols && wasm.mathzig_matrix_get_data) {
        rows = wasm.mathzig_matrix_rows(matrixPtr);
        cols = wasm.mathzig_matrix_cols(matrixPtr);
        stride = wasm.mathzig_matrix_stride ? wasm.mathzig_matrix_stride(matrixPtr) : cols;
        dataPtr = wasm.mathzig_matrix_get_data(matrixPtr);
      } else {
        dataPtr = readU32(matrixPtr + 8);
        rows = readU32(matrixPtr + 16);
        cols = readU32(matrixPtr + 20);
        stride = readU32(matrixPtr + 24);
      }
      if (rows === 0 || cols === 0 || rows > 1_000_000 || cols > 1000) return null;
      const data = new Float64Array(wasmMemory.buffer, dataPtr, rows * stride);
      return { rows, cols, stride, data };
    } catch (e) {
      console.error("Error reading matrix view:", e);
      return null;
    }
  }

  function readMatrixData(matrixPtr: number) {
    if (!wasm || !wasmMemory || !matrixPtr) return null;
    try {
      let rows: number;
      let cols: number;
      let stride: number;
      let dataPtr: number;
      if (wasm.mathzig_matrix_rows && wasm.mathzig_matrix_cols && wasm.mathzig_matrix_get_data) {
        rows = wasm.mathzig_matrix_rows(matrixPtr);
        cols = wasm.mathzig_matrix_cols(matrixPtr);
        stride = wasm.mathzig_matrix_stride ? wasm.mathzig_matrix_stride(matrixPtr) : cols;
        dataPtr = wasm.mathzig_matrix_get_data(matrixPtr);
      } else {
        dataPtr = readU32(matrixPtr + 8);
        rows = readU32(matrixPtr + 16);
        cols = readU32(matrixPtr + 20);
        stride = readU32(matrixPtr + 24);
      }
      if (rows === 0 || cols === 0 || rows > 10000 || cols > 1000) return null;
      const data: number[][] = [];
      const maxRows = 5000;
      const view = new Float64Array(wasmMemory.buffer, dataPtr, rows * stride);
      for (let r = 0; r < rows && r < maxRows; r++) {
        const rowStart = r * stride;
        const row: number[] = [];
        for (let c = 0; c < cols; c++) row.push(view[rowStart + c]!);
        data.push(row);
      }
      return { rows, cols, data };
    } catch (e) {
      console.error("Error reading matrix:", e);
      return null;
    }
  }

  function readSeriesData(seriesPtr: number) {
    if (!wasm || !wasmMemory || !seriesPtr || !wasm.mathzig_series_len) return null;
    try {
      const len = wasm.mathzig_series_len(seriesPtr) as number;
      const duration = wasm.mathzig_series_duration ? (wasm.mathzig_series_duration(seriesPtr) as number) : 0;
      const tsPtr = wasm.mathzig_series_get_timestamps_ptr(seriesPtr) as number;
      const valPtr = wasm.mathzig_series_get_values_ptr(seriesPtr) as number;
      const maxSamples = Math.min(len, 10000);
      const tsView = new Float64Array(wasmMemory.buffer, tsPtr, maxSamples);
      const valView = new Float64Array(wasmMemory.buffer, valPtr, maxSamples);
      const timestamps = new Array<number>(maxSamples);
      const values = new Array<number>(maxSamples);
      for (let i = 0; i < maxSamples; i++) {
        timestamps[i] = tsView[i]!;
        values[i] = valView[i]!;
      }
      return { len, duration, timestamps, values };
    } catch (e) {
      console.error("Error reading series:", e);
      return null;
    }
  }

  function formatNumber(n: number): string {
    if (Number.isNaN(n)) return "NaN";
    if (!Number.isFinite(n)) return n > 0 ? "Infinity" : "-Infinity";
    if (Number.isInteger(n) && Math.abs(n) < 1e15) return n.toString();
    if (Math.abs(n) > 1e10 || (Math.abs(n) < 1e-6 && n !== 0)) return n.toExponential(4);
    return parseFloat(n.toPrecision(8)).toString();
  }

  function formatComplex(re: number, im: number): string {
    const r = formatNumber(re);
    if (im === 0) return r;
    const i = Math.abs(im) === 1 ? "" : formatNumber(Math.abs(im));
    return `${r} ${im >= 0 ? "+" : "-"} ${i}i`;
  }

  function createSeries(timestamps: number[], values: number[], sampleMode = 1): number | null {
    if (!wasm || !wasmMemory || !ctx) return null;
    const count = Math.min(timestamps.length, values.length);
    if (count === 0) return null;
    const allocFn = wasm.mathzig_alloc_aligned
      ? (s: number) => wasm!.mathzig_alloc_aligned(8, s)
      : (s: number) => wasm!.wasm_malloc(s);
    const tsPtr = allocFn(count * 8);
    const valPtr = allocFn(count * 8);
    if (!tsPtr || !valPtr) return null;
    const tsView = new Float64Array(wasmMemory.buffer, tsPtr, count);
    const valView = new Float64Array(wasmMemory.buffer, valPtr, count);
    for (let i = 0; i < count; i++) {
      tsView[i] = timestamps[i]!;
      valView[i] = values[i]!;
    }
    const series = wasm.mathzig_create_series(ctx, tsPtr, valPtr, count, sampleMode) as number;
    wasm.wasm_free(tsPtr, count * 8);
    wasm.wasm_free(valPtr, count * 8);
    return series;
  }

  function setSeries(name: string, seriesPtr: number): boolean {
    if (!wasm || !ctx) return false;
    const namePtr = allocString(name);
    const ok = wasm.mathzig_set_series(ctx, namePtr, seriesPtr);
    freeString(namePtr, name);
    return Boolean(ok);
  }

  function loadCSVAsSeries(csvText: string, name: string, sampleMode = 1) {
    const lines = csvText.trim().split("\n");
    const ts: number[] = [];
    const vals: number[] = [];
    for (const line of lines) {
      if (!line || line.startsWith("#")) continue;
      const p = line.split(",");
      if (p.length >= 2) {
        const t = parseFloat(p[0]!);
        const v = parseFloat(p[1]!);
        if (!Number.isNaN(t) && !Number.isNaN(v)) {
          ts.push(t);
          vals.push(v);
        }
      }
    }
    if (ts.length === 0) return { error: "No data found" as const };
    const series = createSeries(ts, vals, sampleMode);
    if (!series) return { error: "Alloc failed" as const };
    if (!setSeries(name, series)) return { error: "Binding failed" as const };
    return {
      success: true as const,
      length: ts.length,
      varData: {
        value: `[Series: ${ts.length}]`,
        type: "series",
        tag: ValueTag.series,
        ptr: series,
        seriesData: { len: ts.length, timestamps: ts.slice(0, 10), values: vals.slice(0, 10) },
      },
    };
  }

  function readLastResult(): EvalResult {
    if (!wasm || !ctx) return { error: "System not ready" };
    const tag = wasm.mathzig_get_last_tag() as number;
    const num = wasm.mathzig_get_last_number() as number;
    const ptr = wasm.mathzig_get_last_ptr() as number;

    if (tag === ValueTag.err) {
      return { error: readString(wasm.mathzig_get_error(ctx)) || "Unknown Error", tag };
    }
    if (Number.isNaN(num) && tag === ValueTag.number) {
      const e = readString(wasm.mathzig_get_error(ctx));
      if (e) return { error: e };
    }

    let val = "";
    let type = "";
    let re = 0;
    let im = 0;

    const getFmt = (fb: string) => {
      if (!wasm!.mathzig_format_last_value) return fb;
      const bp = wasm!.wasm_malloc(1024) as number;
      if (!bp) return fb;
      try {
        const w = wasm!.mathzig_format_last_value(ctx, bp, 1024) as number;
        const s = w > 0 ? readString(bp) : fb;
        wasm!.wasm_free(bp, 1024);
        return s;
      } catch {
        wasm!.wasm_free(bp, 1024);
        return fb;
      }
    };

    switch (tag) {
      case ValueTag.number:
        val = formatNumber(num);
        type = "number";
        break;
      case ValueTag.complex:
        if (ptr) {
          re = readF64(ptr);
          im = readF64(ptr + 8);
        } else {
          re = num;
        }
        val = formatComplex(re, im);
        type = "complex";
        break;
      case ValueTag.unit:
        val = getFmt("") || `${formatNumber(num)} (unit)`;
        type = "unit";
        break;
      case ValueTag.matrix:
        val = `[Matrix ${readU32(ptr + 16)}x${readU32(ptr + 20)}]`;
        type = "matrix";
        break;
      case ValueTag.series: {
        const len = wasm.mathzig_series_len ? wasm.mathzig_series_len(ptr) : "?";
        val = `[Series: ${len} items]`;
        type = "series";
        break;
      }
      case ValueTag.boolean:
        val = num !== 0 ? "true" : "false";
        type = "boolean";
        break;
      case ValueTag.string:
        val = `"${readString(ptr)}"`;
        type = "string";
        break;
      case ValueTag.null_val:
        val = "null";
        type = "null";
        break;
      default:
        val = `[${TagNames[tag] ?? "unknown"}]`;
        type = TagNames[tag] ?? "unknown";
    }

    if (ptr && [ValueTag.matrix, ValueTag.series, ValueTag.record].includes(tag as 3 | 4 | 10)) {
      wasm.mathzig_retain?.(ptr, tag);
    }

    return { value: val, type, tag, ptr, number: num, re, im };
  }

  function compile(expr: string): number {
    if (!wasm || !ctx) return 0;
    const exprPtr = allocString(expr);
    const compiledPtr = wasm.mathzig_compile(ctx, exprPtr) as number;
    freeString(exprPtr, expr);
    return compiledPtr;
  }

  function execute(exprPtr: number): EvalResult {
    if (!wasm || !ctx || !exprPtr) return { error: "Invalid execution state" };
    wasm.mathzig_evaluate(ctx, exprPtr);
    return readLastResult();
  }

  function freeExpr(exprPtr: number): void {
    if (!wasm || !ctx || !exprPtr) return;
    wasm.mathzig_free_expr(ctx, exprPtr);
  }

  function evaluate(expr: string): EvalResult {
    if (!wasm || !ctx) return { error: "System not ready" };
    const exprPtr = allocString(expr);
    try {
      wasm.mathzig_eval(ctx, exprPtr);
      const res = readLastResult();
      const assign = expr.match(/^\s*([a-zA-Z_]\w*)\s*=\s*/);
      if (assign && res.tag !== ValueTag.err) {
        res.assignName = assign[1];
      }
      return res;
    } finally {
      freeString(exprPtr, expr);
    }
  }

  function version(): string {
    if (!wasm || !ctx || !wasm.mathzig_version) return "";
    return readString(wasm.mathzig_version(ctx));
  }

  async function init(paths: string[]): Promise<void> {
    let inst: WebAssembly.WebAssemblyInstantiatedSource | null = null;
    for (const p of paths) {
      try {
        const r = await fetch(`${p}?v=${Date.now()}`, { cache: "no-store" });
        if (r.ok) {
          const b = await r.arrayBuffer();
          inst = await WebAssembly.instantiate(b, {});
          break;
        }
      } catch {
        /* try next path */
      }
    }
    if (!inst) throw new Error("WASM binary not found");
    wasm = inst.instance.exports as WasmExports;
    wasmMemory = wasm.memory;
    ctx = wasm.mathzig_create() as number;
    if (!ctx) throw new Error("Context creation failed");
  }

  function reset(): void {
    if (!wasm) throw new Error("Runtime not initialized");
    if (ctx && wasm.mathzig_destroy) wasm.mathzig_destroy(ctx);
    ctx = wasm.mathzig_create() as number;
    if (!ctx) throw new Error("Context creation failed");
  }

  function setVariable(name: string, val: number): void {
    if (!wasm || !ctx) return;
    const namePtr = allocString(name);
    wasm.mathzig_set_variable(ctx, namePtr, val);
    freeString(namePtr, name);
  }

  function toLaTeX(expr: string): string | null {
    if (!wasm || !ctx) return null;
    const exprPtr = allocString(expr);
    try {
      const latexPtr = wasm.mathzig_to_latex(ctx, exprPtr) as number;
      if (latexPtr === 0) return null;
      return readString(latexPtr);
    } finally {
      freeString(exprPtr, expr);
    }
  }

  return {
    init,
    reset,
    evaluate,
    compile,
    execute,
    freeExpr,
    setVariable,
    createSeries,
    setSeries,
    loadCSVAsSeries,
    readMatrixData,
    getMatrixView,
    readSeriesData,
    formatNumber,
    formatComplex,
    readF64,
    readU32,
    toLaTeX,
    version,
    getWasm: () => wasm,
    getMemory: () => wasmMemory,
  };
}
