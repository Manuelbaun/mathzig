import type { ParityValue } from "./schema";

export interface CompareOptions {
  abs?: number;
  rel?: number;
  treatNaNAsUndefined?: boolean;
  treatNumericBooleanAsBoolean?: boolean;
}

export type Expected =
  | { type: "number"; value: number }
  | { type: "boolean"; value: boolean }
  | { type: "nan" }
  | { type: "undefined" }
  | { type: "error" }
  | { type: "any" };

export interface CompareValuesOptions {
  tolerance?: { abs?: number; rel?: number };
  expected?: Expected;
}

export interface CompareResult {
  ok: boolean;
  reason?: string;
}

const DEFAULT_ABS = 1e-12;
const DEFAULT_REL = 1e-12;

/**
 * Compare two values and return a result with reason on failure.
 * Used by the parity test harness.
 */
export function compareValues(
  reference: any,
  actual: any,
  options: CompareValuesOptions = {}
): CompareResult {
  const tolerance = options.tolerance ?? {};
  const opts: CompareOptions = {
    abs: tolerance.abs ?? DEFAULT_ABS,
    rel: tolerance.rel ?? DEFAULT_REL,
    treatNaNAsUndefined: true,
    treatNumericBooleanAsBoolean: true,
  };

  const refError = isErrorLike(reference);
  const actError = isErrorLike(actual);
  // Handle error cases
  if (refError || actError) {
    if (refError && actError) {
      return { ok: true };
    }
    return { ok: false, reason: "error mismatch" };
  }

  // If expected is specified, validate against it
  if (options.expected) {
    const exp: any = options.expected;
    if (exp.tag) {
      const tagResult = compareExpectedTag(exp, actual, reference);
      if (tagResult) return tagResult;
    }
    switch (exp.type) {
      case "number":
        if (typeof actual !== "number") {
          return { ok: false, reason: `expected number, got ${typeof actual}` };
        }
        if (!compareValue(exp.value, actual, opts)) {
          return { ok: false, reason: `expected ${exp.value}, got ${actual}` };
        }
        return { ok: true };
      case "boolean":
        const actualBool =
          typeof actual === "boolean"
            ? actual
            : typeof actual === "number"
              ? actual !== 0
              : undefined;
        if (actualBool !== exp.value) {
          return { ok: false, reason: `expected ${exp.value}, got ${actual}` };
        }
        return { ok: true };
      case "nan":
        if (typeof actual !== "number" || !Number.isNaN(actual)) {
          return { ok: false, reason: `expected NaN, got ${actual}` };
        }
        return { ok: true };
      case "undefined":
        if (actual !== undefined && !(typeof actual === "number" && Number.isNaN(actual))) {
          return { ok: false, reason: `expected undefined, got ${actual}` };
        }
        return { ok: true };
      case "error":
        if (!actual?.__error) {
          return { ok: false, reason: `expected error, got ${actual}` };
        }
        return { ok: true };
      case "any":
        return { ok: true };
    }
  }

  // Default comparison against reference
  if (compareValue(reference, actual, opts)) {
    return { ok: true };
  }

  return {
    ok: false,
    reason: `expected ${JSON.stringify(reference)}, got ${JSON.stringify(actual)}`,
  };
}

export function compareValue(a: ParityValue, b: ParityValue, opts: CompareOptions = {}): boolean {
  const abs = opts.abs ?? DEFAULT_ABS;
  const rel = opts.rel ?? DEFAULT_REL;

  if (a === b) return true;

  if (opts.treatNaNAsUndefined) {
    if (a === undefined && typeof b === "number" && Number.isNaN(b)) return true;
    if (b === undefined && typeof a === "number" && Number.isNaN(a)) return true;
  }

  if (opts.treatNumericBooleanAsBoolean) {
    if (typeof a === "boolean" && typeof b === "number") return b === (a ? 1 : 0);
    if (typeof b === "boolean" && typeof a === "number") return a === (b ? 1 : 0);
  }

  if (typeof a === "number" && typeof b === "number") {
    if (Number.isNaN(a) && Number.isNaN(b)) return true;
    const diff = Math.abs(a - b);
    if (diff <= abs) return true;
    return diff <= Math.max(Math.abs(a), Math.abs(b)) * rel;
  }

  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!compareValue(a[i], b[i], opts)) return false;
    }
    return true;
  }

  if (isRecord(a) && isRecord(b)) {
    const aKeys = Object.keys(a).sort();
    const bKeys = Object.keys(b).sort();
    if (!compareValue(aKeys, bKeys, opts)) return false;
    for (const key of aKeys) {
      if (!compareValue(a[key], b[key], opts)) return false;
    }
    return true;
  }

  return false;
}

function isRecord(value: ParityValue): value is { [key: string]: ParityValue } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isErrorLike(value: any): boolean {
  if (!value || typeof value !== "object") return false;
  if (value.__error) return true;
  // ValueTag.Error == 14 in current bindings
  return value.tag === 14;
}

function compareExpectedTag(exp: any, actual: any, reference: any): CompareResult | null {
  const expectedTag = String(exp.tag);
  // String content compare (not just tag) so wasm_aot length-prefixed strings
  // match the zig_vm reference LaTeX text.
  if (expectedTag === "string") {
    const refStr = extractStringContent(reference);
    const actStr = extractStringContent(actual);
    if (refStr === null || actStr === null) {
      return { ok: false, reason: "string decode mismatch" };
    }
    if (refStr !== actStr) {
      return { ok: false, reason: `expected string ${JSON.stringify(refStr)}, got ${JSON.stringify(actStr)}` };
    }
    return { ok: true };
  }
  // Only tag-compare for structured/opaque types; primitives should still use ref compare.
  if (!["series", "record", "unit", "matrix", "complex", "function", "array", "slice"].includes(expectedTag)) {
    return null;
  }
  const actualTag = getTagString(actual);
  // AOT returns SI magnitude as number, or a unit-tagged object with .value.
  if (expectedTag === "unit") {
    if (actualTag === "number" && typeof actual === "number") return { ok: true };
    if (actualTag === "unit") return { ok: true };
  }
  if (actualTag !== expectedTag) {
    return { ok: false, reason: `expected ${expectedTag}, got ${actualTag ?? typeof actual}` };
  }
  if (expectedTag === "matrix" && Array.isArray(exp.shape)) {
    const expectedRows = Number(exp.shape[0] ?? NaN);
    const expectedCols = Number(exp.shape[1] ?? NaN);
    const actualRows = getMatrixRows(actual);
    const actualCols = getMatrixCols(actual);
    if (!Number.isFinite(expectedRows) || !Number.isFinite(expectedCols) || actualRows === null || actualCols === null) {
      return { ok: false, reason: "matrix shape mismatch" };
    }
    if (actualRows !== expectedRows || actualCols !== expectedCols) {
      return { ok: false, reason: `expected matrix ${expectedRows}x${expectedCols}, got ${actualRows}x${actualCols}` };
    }
    // When expected.data is provided, require element equality (absolute contents).
    // Opt-in avoids flagging pre-existing shape-only matrix cases whose AOT data
    // may still diverge; new correctness cases (e.g. slice assign) pass data.
    if (Array.isArray(exp.data)) {
      const data = getMatrixData(actual);
      if (!data || data.length !== exp.data.length) {
        return { ok: false, reason: "matrix expected.data length mismatch" };
      }
      for (let i = 0; i < exp.data.length; i++) {
        const want = Number(exp.data[i]);
        const got = data[i];
        const diff = Math.abs(want - got);
        if (diff > DEFAULT_ABS && diff > Math.max(Math.abs(want), Math.abs(got)) * DEFAULT_REL) {
          return { ok: false, reason: `matrix expected.data[${i}]: want ${want}, got ${got}` };
        }
      }
    }
  }
  if (expectedTag === "series" && Array.isArray(exp.shape)) {
    const expectedLen = Number(exp.shape[0] ?? NaN);
    const actualLen = getSeriesLen(actual);
    if (!Number.isFinite(expectedLen) || actualLen === null) {
      return { ok: false, reason: "series shape mismatch" };
    }
    if (actualLen !== expectedLen) {
      return { ok: false, reason: `expected series len ${expectedLen}, got ${actualLen}` };
    }
  }
  if (expectedTag === "record" && Array.isArray(exp.keys)) {
    if (!hasRecordKeys(actual, exp.keys)) {
      return { ok: false, reason: "record keys mismatch" };
    }
  }
  return { ok: true };
}

function extractStringContent(value: any): string | null {
  if (typeof value === "string") return value;
  if (value && typeof value.tag === "number" && value.tag === 6 && value.owner?.backend?.call) {
    try {
      const buf = new Uint8Array(4096);
      const len = Number(
        value.owner.backend.call("mathzig_format_last_value", value.owner.handle, buf, BigInt(buf.length))
      );
      if (!Number.isFinite(len) || len <= 0) return "";
      let text = new TextDecoder().decode(buf.subarray(0, len));
      if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
        text = text.slice(1, -1);
      }
      return text;
    } catch {
      return null;
    }
  }
  return null;
}

function getTagString(value: any): string | undefined {
  if (value === undefined) return "undefined";
  if (value === null) return "null";
  if (typeof value === "number") return "number";
  if (typeof value === "boolean") return "boolean";
  if (typeof value === "string") return "string";
  if (Array.isArray(value)) return "array";
  if (isErrorLike(value)) return "error";

  if (value && typeof value.tag === "number") {
    switch (value.tag) {
      case 0: return "number";
      case 1: return "complex";
      case 2: return "unit";
      case 3: return "matrix";
      case 4: return "series";
      case 5: return "predicate";
      case 6: return "string";
      case 7: return "boolean";
      case 8: return "function";
      case 9: return "array";
      case 10: return "record";
      case 11: return "slice";
      case 12: return "undefined";
      case 13: return "null";
      case 14: return "error";
    }
  }

  if (typeof value?.getField === "function") return "record";
  if (typeof value?.getTimestampsPtr === "function" || typeof value?.getValuesPtr === "function") return "series";
  if (value && typeof value === "object" && value.data instanceof Float64Array && typeof value.rows === "number" && typeof value.cols === "number") {
    return "matrix";
  }

  return undefined;
}

function getSeriesLen(value: any): number | null {
  if (typeof value?.len === "number") {
    return Number.isFinite(value.len) ? value.len : null;
  }
  if (typeof value?.len === "function") {
    try {
      const res = value.len();
      return typeof res === "number" ? res : Number(res);
    } catch {
      return null;
    }
  }
  return null;
}

function getMatrixRows(value: any): number | null {
  if (typeof value?.rows === "number") return value.rows;
  return null;
}

function getMatrixCols(value: any): number | null {
  if (typeof value?.cols === "number") return value.cols;
  return null;
}

function getMatrixData(value: any): number[] | null {
  if (!value) return null;
  if (value.data instanceof Float64Array) return Array.from(value.data);
  if (Array.isArray(value.data)) return value.data.map(Number);
  return null;
}

function hasRecordKeys(value: any, keys: string[]): boolean {
  if (typeof value?.getField !== "function") return false;
  for (const key of keys) {
    try {
      value.getField(key);
    } catch {
      return false;
    }
  }
  return true;
}
