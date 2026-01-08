/**
 * Host-mediated value transfer for node-graph edges.
 *
 * Per-tick protocol for a consumer node:
 *   reset_heap() → write non-scalar inputs (via module alloc) → eval → decode
 *
 * Layouts match `src/wasm/abi.zig`. Readers/writers reuse AotHostEnv helpers
 * (no forked decode path). Series handles pass through one shared HostEnv.
 */

import {
  AotHostEnv,
  type MatrixData,
  type SeriesData,
} from "../aot_env";

/** Port kinds accepted by the graph schema / node manifest (friendly names). */
export type PortKind =
  | "number"
  | "scalar"
  | "boolean"
  | "matrix"
  | "complex"
  | "record"
  | "string"
  | "series"
  | "any";

/** Canonical host-side values carried on graph edges. */
export type GraphValue =
  | number
  | boolean
  | MatrixValue
  | ComplexValue
  | RecordValue
  | SeriesValue
  | string;

export type MatrixValue = {
  rows: number;
  cols: number;
  data: Float64Array | number[];
};

export type ComplexValue = {
  re: number;
  im: number;
  tag?: 1;
};

export type RecordValue = Map<string, number> | Record<string, number>;

export type SeriesValue =
  | SeriesData
  | { id: number; timestamps?: number[]; values?: number[]; len?: () => number }
  | { timestamps: number[]; values: number[] };

export type WasmNodeExports = {
  memory?: WebAssembly.Memory;
  alloc?: (size: number) => number;
  reset_heap?: () => void;
  eval: (...args: number[]) => number;
  heap_ptr?: WebAssembly.Global;
};

/** Normalize friendly / wire kind names to a port kind. */
export function normalizePortKind(kind: string): PortKind {
  switch (kind) {
    case "scalar":
    case "number":
      return "number";
    case "bool":
    case "boolean":
      return "boolean";
    case "matrix":
    case "matrix_ptr":
      return "matrix";
    case "complex":
    case "complex_ptr":
      return "complex";
    case "record":
    case "record_ptr":
      return "record";
    case "string":
    case "string_ptr":
      return "string";
    case "series":
    case "series_handle":
      return "series";
    case "any":
      return "any";
    default:
      throw new Error(`Unknown port kind '${kind}'.`);
  }
}

/** True when kinds are compatible for an edge (producer → consumer). */
export function kindsCompatible(producer: PortKind | string, consumer: PortKind | string): boolean {
  const a = normalizePortKind(producer);
  const b = normalizePortKind(consumer);
  if (a === b) return true;
  if (a === "any" || b === "any") return true;
  // number/scalar already collapsed; boolean may flow into number slots.
  if ((a === "number" && b === "boolean") || (a === "boolean" && b === "number")) return true;
  return false;
}

/**
 * Write a host GraphValue into a consumer module as an f64 wire argument.
 * Scalar/boolean/series-handle: returned as plain f64 (no heap write).
 * Matrix/complex/record/string: allocated via module `alloc` (or hostAlloc).
 */
export function writeWireValue(
  host: AotHostEnv,
  exports: WasmNodeExports,
  kind: PortKind | string,
  value: GraphValue,
): number {
  const k = normalizePortKind(kind);
  host.attachMemory(exports.memory ?? null);

  switch (k) {
    case "number":
    case "scalar":
      if (typeof value !== "number" || !Number.isFinite(value)) {
        throw new Error(`Expected finite number wire value, got ${describeValue(value)}.`);
      }
      return value;
    case "boolean":
      if (typeof value === "boolean") return value ? 1 : 0;
      if (typeof value === "number") return value ? 1 : 0;
      throw new Error(`Expected boolean wire value, got ${describeValue(value)}.`);
    case "series": {
      // Handle pass-through via the shared host env series store.
      if (typeof value === "number" && host.resolveSeries(value)) return value;
      if (value && typeof value === "object" && "id" in value && typeof (value as { id: unknown }).id === "number") {
        const id = (value as { id: number }).id;
        if (host.resolveSeries(id)) return id;
      }
      const ts = seriesTimestamps(value);
      const vals = seriesValues(value);
      if (!ts || !vals) throw new Error(`Expected series value, got ${describeValue(value)}.`);
      return host.createSeries(ts, vals);
    }
    case "matrix": {
      const m = asMatrix(value);
      if (!m) throw new Error(`Expected matrix value, got ${describeValue(value)}.`);
      return writeMatrixIntoModule(host, exports, m.rows, m.cols, m.data);
    }
    case "complex": {
      const c = asComplex(value);
      if (!c) throw new Error(`Expected complex value, got ${describeValue(value)}.`);
      return writeComplexIntoModule(host, exports, c.re, c.im);
    }
    case "record": {
      const entries = asRecordEntries(value);
      if (!entries) throw new Error(`Expected record value, got ${describeValue(value)}.`);
      return writeRecordIntoModule(host, exports, entries);
    }
    case "string": {
      if (typeof value !== "string") throw new Error(`Expected string value, got ${describeValue(value)}.`);
      return writeStringIntoModule(host, exports, value);
    }
    case "any":
      if (typeof value === "number") return value;
      if (typeof value === "boolean") return value ? 1 : 0;
      if (asMatrix(value)) return writeWireValue(host, exports, "matrix", value);
      if (asComplex(value)) return writeWireValue(host, exports, "complex", value);
      if (asRecordEntries(value)) return writeWireValue(host, exports, "record", value);
      if (seriesTimestamps(value)) return writeWireValue(host, exports, "series", value);
      if (typeof value === "string") return writeWireValue(host, exports, "string", value);
      throw new Error(`Cannot encode any-kind value ${describeValue(value)}.`);
    default:
      throw new Error(`Unsupported port kind '${k}'.`);
  }
}

/**
 * Decode an eval return wire into a host GraphValue (deep-copied out of
 * module memory so the next reset_heap cannot invalidate it).
 */
export function readWireValue(
  host: AotHostEnv,
  exports: WasmNodeExports,
  kind: PortKind | string,
  raw: number,
  resultTag?: string | null,
): GraphValue {
  const k = normalizePortKind(kind);
  host.attachMemory(exports.memory ?? null);
  const tag = resultTag ?? kindToResultTag(k);

  switch (k) {
    case "number":
    case "scalar":
      if (tag === "unit" && Number.isFinite(raw)) return raw;
      return raw;
    case "boolean":
      return raw !== 0;
    case "matrix": {
      const p = Math.trunc(raw);
      const m = host.readMatrix(raw) ?? host.matrixStore.get(p);
      if (!m) {
        throw new Error(
          `Failed to decode matrix at wire ${raw}` +
            (p === 0
              ? " (null/zero pointer — producer returned no matrix; check ODE/alloc and that the host env is attached)"
              : p > 0 && p < 1024
                ? " (pointer below heap base 1024)"
                : "") +
            ".",
        );
      }
      // Durable host copy (independent of module heap / reset_heap).
      return copyMatrix(m);
    }
    case "complex": {
      const c = host.readComplex(raw);
      if (!c) {
        // Pure-real complexes may constant-fold to a plain number.
        if (Number.isFinite(raw)) return { re: raw, im: 0, tag: 1 };
        throw new Error(`Failed to decode complex at wire ${raw}.`);
      }
      return { re: c.re, im: c.im, tag: 1 };
    }
    case "record": {
      const stored = host.recordStore.get(Math.trunc(raw));
      if (stored) return new Map(stored);
      const entries = host.readWasmRecord(raw);
      if (!entries) throw new Error(`Failed to decode record at wire ${raw}.`);
      return new Map(entries.map((e) => [e.key, e.wire]));
    }
    case "series": {
      const s = host.resolveSeries(raw);
      if (s) {
        return {
          id: Math.trunc(raw),
          timestamps: s.timestamps.slice(),
          values: s.values.slice(),
          minTs: s.minTs,
          maxTs: s.maxTs,
        };
      }
      const linear = host.readLinearSeries(raw);
      if (linear) {
        const id = host.createSeries(linear.timestamps, linear.values);
        return {
          id,
          timestamps: linear.timestamps.slice(),
          values: linear.values.slice(),
          minTs: linear.minTs,
          maxTs: linear.maxTs,
        };
      }
      throw new Error(`Failed to decode series at wire ${raw}.`);
    }
    case "string": {
      const text = host.readLengthPrefixedString(raw) ?? host.readCString(raw);
      if (text === null) throw new Error(`Failed to decode string at wire ${raw}.`);
      return text;
    }
    case "any": {
      // Prefer explicit result tag when available.
      if (tag === "matrix") return readWireValue(host, exports, "matrix", raw, tag);
      if (tag === "complex") return readWireValue(host, exports, "complex", raw, tag);
      if (tag === "record") return readWireValue(host, exports, "record", raw, tag);
      if (tag === "series") return readWireValue(host, exports, "series", raw, tag);
      if (tag === "string") return readWireValue(host, exports, "string", raw, tag);
      return raw;
    }
    default:
      return raw;
  }
}

export function kindToResultTag(kind: PortKind | string): string {
  const k = normalizePortKind(kind);
  switch (k) {
    case "number":
    case "scalar":
      return "number";
    case "boolean":
      return "boolean";
    case "matrix":
      return "matrix";
    case "complex":
      return "complex";
    case "record":
      return "record";
    case "string":
      return "string";
    case "series":
      return "series";
    default:
      return "number";
  }
}

export function resultTagToPortKind(tag: string | undefined | null): PortKind {
  if (!tag || tag === "number" || tag === "unit") return "number";
  if (tag === "boolean") return "boolean";
  if (tag === "matrix") return "matrix";
  if (tag === "complex") return "complex";
  if (tag === "record") return "record";
  if (tag === "string") return "string";
  if (tag === "series") return "series";
  return "number";
}

/** Deep-compare two graph values for determinism checks. */
export function graphValuesEqual(a: GraphValue, b: GraphValue, eps = 1e-12): boolean {
  if (typeof a === "number" && typeof b === "number") {
    if (Number.isNaN(a) && Number.isNaN(b)) return true;
    return Math.abs(a - b) <= eps;
  }
  if (typeof a === "boolean" && typeof b === "boolean") return a === b;
  if (typeof a === "string" && typeof b === "string") return a === b;

  const ma = asMatrix(a);
  const mb = asMatrix(b);
  if (ma && mb) {
    if (ma.rows !== mb.rows || ma.cols !== mb.cols) return false;
    for (let i = 0; i < ma.data.length; i++) {
      if (Math.abs(Number(ma.data[i]) - Number(mb.data[i])) > eps) return false;
    }
    return true;
  }

  const ca = asComplex(a);
  const cb = asComplex(b);
  if (ca && cb) return Math.abs(ca.re - cb.re) <= eps && Math.abs(ca.im - cb.im) <= eps;

  const ra = asRecordEntries(a);
  const rb = asRecordEntries(b);
  if (ra && rb) {
    if (ra.length !== rb.length) return false;
    const mapB = new Map(rb.map((e) => [e.key, e.wire]));
    for (const e of ra) {
      const v = mapB.get(e.key);
      if (v === undefined || Math.abs(v - e.wire) > eps) return false;
    }
    return true;
  }

  const sa = seriesTimestamps(a);
  const sb = seriesTimestamps(b);
  const va = seriesValues(a);
  const vb = seriesValues(b);
  if (sa && sb && va && vb) {
    if (sa.length !== sb.length || va.length !== vb.length) return false;
    for (let i = 0; i < sa.length; i++) {
      if (Math.abs(sa[i]! - sb[i]!) > eps || Math.abs(va[i]! - vb[i]!) > eps) return false;
    }
    return true;
  }

  return false;
}

// ── internal helpers ──────────────────────────────────────────────────────

function moduleAlloc(exports: WasmNodeExports, host: AotHostEnv, size: number, align = 8): number {
  // Route through hostAlloc when the host has captured module alloc (attachInstance)
  // so injectAllocFailures + decode-buffer high-water apply without wasm codegen changes.
  host.attachMemory(exports.memory ?? null);
  if (host.memory && typeof exports.alloc === "function") {
    // Prefer host path: requires moduleAllocFn from attachInstance (GraphRunner sets this).
    try {
      return host.hostAlloc(size, align);
    } catch (e) {
      // Re-throw AllocFailureError; other errors fall through to raw alloc.
      if (e && typeof e === "object" && (e as { code?: string }).code === "AllocFailure") throw e;
      if (e instanceof Error && e.name === "AllocFailureError") throw e;
    }
  }
  if (typeof exports.alloc === "function") {
    return exports.alloc(size);
  }
  return host.hostAlloc(size, align);
}

function writeMatrixIntoModule(
  host: AotHostEnv,
  exports: WasmNodeExports,
  rows: number,
  cols: number,
  values: ArrayLike<number>,
): number {
  const count = rows * cols;
  const data = Float64Array.from({ length: count }, (_, i) => Number(values[i] ?? NaN));
  const ptr = moduleAlloc(exports, host, 8 + count * 8, 8);
  if (!ptr && count > 0) {
    // Fall back to hostAlloc / store when module has no memory / alloc failed.
    host.attachMemory(exports.memory ?? null);
    return host.writeMatrix(rows, cols, data);
  }
  const mem = exports.memory ?? host.memory;
  if (!mem || (!ptr && count > 0)) {
    return host.createMatrix(rows, cols, Array.from(data));
  }
  // Empty matrix may legitimately land at ptr 0 only if alloc returns 0 and
  // count==0 — prefer a durable host handle so decode never sees "wire 0".
  if (!ptr) {
    return host.createMatrix(rows, cols, Array.from(data));
  }
  const dv = new DataView(mem.buffer);
  dv.setInt32(ptr, rows, true);
  dv.setInt32(ptr + 4, cols, true);
  for (let i = 0; i < count; i++) dv.setFloat64(ptr + 8 + i * 8, data[i]!, true);
  // Module-local pointers must not enter matrixStore: multi-node GraphRunner
  // shares one AotHostEnv and heap addresses collide across instances.
  // Durable edge values are GraphValue copies after each node (copyMatrix).
  return ptr;
}

function writeComplexIntoModule(host: AotHostEnv, exports: WasmNodeExports, re: number, im: number): number {
  const ptr = moduleAlloc(exports, host, 16, 8);
  const mem = exports.memory ?? host.memory;
  if (!mem || !ptr) {
    host.attachMemory(exports.memory ?? null);
    return host.writeComplex(re, im);
  }
  const dv = new DataView(mem.buffer);
  dv.setFloat64(ptr, re, true);
  dv.setFloat64(ptr + 8, im, true);
  return ptr;
}

function writeRecordIntoModule(
  host: AotHostEnv,
  exports: WasmNodeExports,
  entries: Array<{ key: string; wire: number; kind: number }>,
): number {
  host.attachMemory(exports.memory ?? null);
  if (!exports.memory && !host.memory) {
    const map = new Map<string, number>();
    for (const e of entries) map.set(e.key, e.wire);
    return host.createRecord(map);
  }
  // Prefer AotHostEnv writer (handles key string table / CString writes).
  return host.writeWasmRecord(entries);
}

function writeStringIntoModule(host: AotHostEnv, exports: WasmNodeExports, text: string): number {
  host.attachMemory(exports.memory ?? null);
  return host.writeLengthPrefixedString(text);
}

function copyMatrix(m: MatrixData): MatrixValue {
  return { rows: m.rows, cols: m.cols, data: Float64Array.from(m.data) };
}

function asMatrix(value: unknown): MatrixValue | null {
  if (!value || typeof value !== "object") return null;
  const v = value as { rows?: unknown; cols?: unknown; data?: unknown };
  if (typeof v.rows !== "number" || typeof v.cols !== "number" || v.data == null) return null;
  if (typeof (v.data as ArrayLike<number>).length !== "number") return null;
  return { rows: v.rows, cols: v.cols, data: v.data as ArrayLike<number> as number[] };
}

function asComplex(value: unknown): ComplexValue | null {
  if (!value || typeof value !== "object") return null;
  const v = value as { re?: unknown; im?: unknown };
  if (typeof v.re !== "number" || typeof v.im !== "number") return null;
  return { re: v.re, im: v.im, tag: 1 };
}

function asRecordEntries(value: unknown): Array<{ key: string; wire: number; kind: number }> | null {
  if (value instanceof Map) {
    return [...value.entries()].map(([key, wire]) => ({
      key: String(key),
      wire: Number(wire),
      kind: 0,
    }));
  }
  if (value && typeof value === "object" && !Array.isArray(value) && !("rows" in (value as object)) && !("re" in (value as object))) {
    const obj = value as Record<string, unknown>;
    if ("timestamps" in obj || "id" in obj) return null;
    return Object.entries(obj).map(([key, wire]) => ({
      key,
      wire: Number(wire),
      kind: 0,
    }));
  }
  return null;
}

function seriesTimestamps(value: unknown): number[] | null {
  if (!value || typeof value !== "object") return null;
  const v = value as { timestamps?: unknown; getTimestampsPtr?: () => number[] };
  if (Array.isArray(v.timestamps)) return v.timestamps as number[];
  if (typeof v.getTimestampsPtr === "function") return v.getTimestampsPtr();
  return null;
}

function seriesValues(value: unknown): number[] | null {
  if (!value || typeof value !== "object") return null;
  const v = value as { values?: unknown; getValuesPtr?: () => number[] };
  if (Array.isArray(v.values)) return v.values as number[];
  if (typeof v.getValuesPtr === "function") return v.getValuesPtr();
  return null;
}

function describeValue(value: unknown): string {
  if (value === null) return "null";
  if (typeof value !== "object") return typeof value;
  if (asMatrix(value)) return "matrix";
  if (asComplex(value)) return "complex";
  if (seriesTimestamps(value)) return "series";
  if (value instanceof Map) return "record";
  return value.constructor?.name ?? "object";
}
