/**
 * S2 pure wire-decode helpers (task-14 / C3).
 *
 * Hostile u32 lengths/offsets are bound-checked against module memory size
 * and documented caps **before** any large allocation. No MathZig / FFI deps.
 */

import {
  MAX_MATRIX_ELEMENTS,
  MAX_RECORD_ENTRIES,
  MAX_SERIES_SAMPLES,
  MAX_WIRE_STRING_BYTES,
} from "./graph/limits";
import { WireDecodeError } from "./graph/load_error";

export type MatrixData = {
  rows: number;
  cols: number;
  data: Float64Array;
};

export type SoftOpts = { soft?: boolean };

function fail(
  soft: boolean,
  code: string,
  message: string,
  ptrF64: number,
  field: string,
): null {
  if (soft) return null;
  throw new WireDecodeError(code, message, {
    position: { byte: Number.isFinite(ptrF64) ? Math.trunc(ptrF64) : undefined },
    context: { field },
  });
}

/** Length-prefixed string: `[u32 len][utf-8 bytes]`. */
export function decodeLengthPrefixedString(
  mem: WebAssembly.Memory,
  ptrF64: number,
  opts: SoftOpts = {},
): string | null {
  const soft = opts.soft === true;
  if (!Number.isFinite(ptrF64)) return fail(soft, "InvalidPointer", "wire string: non-finite ptr", ptrF64, "string");
  const p = Math.trunc(ptrF64);
  const memSize = mem.buffer.byteLength;
  if (p < 0 || p + 4 > memSize) return fail(soft, "OutOfBounds", "wire string: header OOB", ptrF64, "string");
  const dv = new DataView(mem.buffer);
  const len = dv.getUint32(p, true);
  if (len === 0) return "";
  if (len > MAX_WIRE_STRING_BYTES) {
    return fail(
      soft,
      "LimitExceeded",
      `wire string len ${len} exceeds MAX_WIRE_STRING_BYTES (${MAX_WIRE_STRING_BYTES})`,
      ptrF64,
      "string",
    );
  }
  if (p + 4 + len > memSize) {
    return fail(soft, "OutOfBounds", `wire string: len ${len} exceeds module memory (${memSize})`, ptrF64, "string");
  }
  return new TextDecoder().decode(new Uint8Array(mem.buffer, p + 4, len));
}

/** Matrix: `[i32 rows][i32 cols][f64 data…]`. */
export function decodeMatrix(
  mem: WebAssembly.Memory,
  ptrF64: number,
  opts: SoftOpts = {},
): MatrixData | null {
  const soft = opts.soft === true;
  if (!Number.isFinite(ptrF64)) return fail(soft, "InvalidPointer", "wire matrix: non-finite ptr", ptrF64, "matrix");
  const p = Math.trunc(ptrF64);
  const memSize = mem.buffer.byteLength;
  if (p < 0 || p + 8 > memSize) return fail(soft, "OutOfBounds", "wire matrix: header OOB", ptrF64, "matrix");
  const dv = new DataView(mem.buffer);
  const rows = dv.getInt32(p, true);
  const cols = dv.getInt32(p + 4, true);
  if (rows < 0 || cols < 0) {
    return fail(soft, "InvalidHeader", `wire matrix: negative dims ${rows}x${cols}`, ptrF64, "matrix");
  }
  if (rows > MAX_MATRIX_ELEMENTS || cols > MAX_MATRIX_ELEMENTS) {
    return fail(
      soft,
      "LimitExceeded",
      `wire matrix dims ${rows}x${cols} exceed MAX_MATRIX_ELEMENTS (${MAX_MATRIX_ELEMENTS})`,
      ptrF64,
      "matrix",
    );
  }
  const count = rows * cols;
  if (count > MAX_MATRIX_ELEMENTS) {
    return fail(
      soft,
      "LimitExceeded",
      `wire matrix elements ${count} exceed MAX_MATRIX_ELEMENTS (${MAX_MATRIX_ELEMENTS})`,
      ptrF64,
      "matrix",
    );
  }
  const dataStart = p + 8;
  if (count > 0 && dataStart + count * 8 > memSize) {
    return fail(
      soft,
      "OutOfBounds",
      `wire matrix: payload ${count}*8 exceeds module memory (${memSize})`,
      ptrF64,
      "matrix",
    );
  }
  if (count === 0) return { rows, cols, data: new Float64Array(0) };
  return {
    rows,
    cols,
    data: Float64Array.from(new Float64Array(mem.buffer, dataStart, count)),
  };
}

/** Record table size check + entry walk (keys via NUL C-strings in same memory). */
export function decodeWasmRecord(
  mem: WebAssembly.Memory,
  ptrF64: number,
  opts: SoftOpts = {},
): Array<{ key: string; wire: number; kind: number }> | null {
  const soft = opts.soft === true;
  if (!Number.isFinite(ptrF64)) return fail(soft, "InvalidPointer", "wire record: non-finite ptr", ptrF64, "record");
  const p = Math.trunc(ptrF64);
  const memSize = mem.buffer.byteLength;
  if (p < 0 || p + 8 > memSize) {
    return fail(soft, "OutOfBounds", "wire record: header OOB", ptrF64, "record");
  }
  const dv = new DataView(mem.buffer);
  const count = dv.getUint32(p, true);
  if (count === 0) return fail(soft, "InvalidHeader", "wire record: empty count", ptrF64, "record");
  if (count > MAX_RECORD_ENTRIES) {
    return fail(
      soft,
      "LimitExceeded",
      `wire record count ${count} exceeds MAX_RECORD_ENTRIES (${MAX_RECORD_ENTRIES})`,
      ptrF64,
      "record",
    );
  }
  if (dv.getUint32(p + 4, true) !== 0) {
    return fail(soft, "InvalidHeader", "wire record: pad word must be 0", ptrF64, "record");
  }
  if (p + 8 + count * 16 > memSize) {
    return fail(
      soft,
      "OutOfBounds",
      `wire record: entry table for count=${count} exceeds module memory`,
      ptrF64,
      "record",
    );
  }
  const entries: Array<{ key: string; wire: number; kind: number }> = [];
  const buf = new Uint8Array(mem.buffer);
  for (let i = 0; i < count; i++) {
    const base = p + 8 + i * 16;
    const keyOff = dv.getUint32(base + 8, true);
    const kind = dv.getUint8(base + 12);
    if (kind > 5 || keyOff < 0 || keyOff >= memSize) {
      return fail(soft, "InvalidHeader", `wire record: bad key/kind at entry ${i}`, ptrF64, "record");
    }
    let end = keyOff;
    while (end < memSize && buf[end] !== 0) end++;
    if (end === keyOff) {
      return fail(soft, "InvalidHeader", `wire record: empty key at entry ${i}`, ptrF64, "record");
    }
    const key = new TextDecoder().decode(buf.subarray(keyOff, end));
    entries.push({ key, wire: dv.getFloat64(base, true), kind });
  }
  return entries;
}

/** Series linear-memory layout header validation. */
export function decodeSeriesLayout(
  mem: WebAssembly.Memory,
  ptrF64: number,
  opts: SoftOpts = {},
): { len: number } | null {
  const soft = opts.soft === true;
  if (!Number.isFinite(ptrF64)) return fail(soft, "InvalidPointer", "wire series: non-finite ptr", ptrF64, "series");
  const p = Math.trunc(ptrF64);
  const memSize = mem.buffer.byteLength;
  if (p < 0 || p + 8 > memSize) return fail(soft, "OutOfBounds", "wire series: header OOB", ptrF64, "series");
  const len = new DataView(mem.buffer).getUint32(p, true);
  if (len > MAX_SERIES_SAMPLES) {
    return fail(
      soft,
      "LimitExceeded",
      `wire series len ${len} exceeds MAX_SERIES_SAMPLES (${MAX_SERIES_SAMPLES})`,
      ptrF64,
      "series",
    );
  }
  const total = 8 + len * 16;
  if (p + total > memSize) {
    return fail(soft, "OutOfBounds", `wire series: payload for len=${len} exceeds module memory`, ptrF64, "series");
  }
  return { len };
}
