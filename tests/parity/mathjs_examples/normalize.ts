import { create, all, type MathJsInstance } from "mathjs";
import type { NormalizedValue } from "./schema";

export function createMathJs(): MathJsInstance {
  return create(all, {});
}

export function normalizeMathJs(value: any, math: MathJsInstance): NormalizedValue {
  if (value === undefined) return null;
  if (value === null) return null;
  if (typeof value === "number") {
    if (Number.isNaN(value)) return Number.NaN;
    return value;
  }
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value;

  if (typeof math.isUnit === "function" && math.isUnit(value)) {
    try {
      return { __unit: true, value: value.toNumber(), unit: value.formatUnits?.() };
    } catch {
      return { __unit: true, value: Number(value) };
    }
  }

  if (typeof math.isMatrix === "function" && math.isMatrix(value)) {
    return { __matrix: true, data: shapeMatrix(normalizeNested(value.toArray(), math)) };
  }

  if (Array.isArray(value)) {
    return value.map((v) => normalizeNested(v, math));
  }

  if (value && typeof value === "object") {
    if (value.mathjs === "Unit" && typeof value.value === "number") {
      return { __unit: true, value: value.value, unit: value.unit };
    }
    if ("re" in value && "im" in value && typeof value.re === "number" && typeof value.im === "number") {
      return { __complex: true, re: value.re, im: value.im };
    }
    if ("value" in value && value.isFraction === true) {
      const n = Number(value.valueOf?.() ?? value);
      return Number.isFinite(n) ? n : String(value);
    }
    if ("value" in value && typeof value.toNumber === "function") {
      return value.toNumber();
    }
    if ("value" in value && typeof value.value === "number") {
      return value.value;
    }
  }

  return String(value);
}

function normalizeNested(value: any, math: MathJsInstance): any {
  if (Array.isArray(value)) return value.map((v) => normalizeNested(v, math));
  return normalizeMathJs(value, math);
}

function shapeMatrix(data: any): any {
  if (!Array.isArray(data)) return data;
  if (data.length === 0) return data;
  if (!Array.isArray(data[0])) return data;
  if (data.length === 1) return data[0];
  if (data.every((row) => Array.isArray(row) && row.length === 1)) return data.map((row) => row[0]);
  return data;
}

export function normalizeMathZig(ctx: { eval: (expr: string) => any }, expr: string, raw: any): NormalizedValue {
  if (raw === undefined) return null;
  if (raw === null) return null;
  if (typeof raw === "number") return raw;
  if (typeof raw === "boolean") return raw;
  if (typeof raw === "string") return raw;

  if (raw && typeof raw === "object" && "rows" in raw && "cols" in raw && "data" in raw) {
    const m = raw as { rows: number; cols: number; data: ArrayLike<number> };
    const mat: number[][] = [];
    for (let r = 0; r < m.rows; r++) {
      const row: number[] = [];
      for (let c = 0; c < m.cols; c++) row.push(m.data[r * m.cols + c]);
      mat.push(row);
    }
    return { __matrix: true, data: shapeMatrix(mat) };
  }

  if (raw && typeof raw === "object" && "tag" in raw && typeof raw.toNumber === "function") {
    const tag = raw.tag as number;
    try {
      if (tag === 1) {
        const reRaw = ctx.eval(`re(${expr})`);
        const imRaw = ctx.eval(`im(${expr})`);
        const re = typeof reRaw === "number" ? reRaw : Number(reRaw);
        const im = typeof imRaw === "number" ? imRaw : Number(imRaw);
        return { __complex: true, re, im };
      }
      if (tag === 2) return raw.toNumber();
      if (tag === 3) {
        const inner = raw.value;
        if (inner && typeof inner === "object" && "rows" in inner) {
          return normalizeMathZig(ctx, expr, inner);
        }
        return { __matrix: true, data: "[Matrix]" };
      }
      if (tag === 14) return { __error: true, message: String(raw.num ?? "error") };
      return raw.toNumber();
    } finally {
      raw.release?.();
    }
  }

  return String(raw);
}

function almostEqual(a: number, b: number, eps = 1e-9): boolean {
  if (Number.isNaN(a) && Number.isNaN(b)) return true;
  const diff = Math.abs(a - b);
  if (diff <= eps) return true;
  return diff <= Math.max(Math.abs(a), Math.abs(b), 1) * eps;
}

export function compareNormalized(
  expected: NormalizedValue,
  actual: NormalizedValue,
  tolerance = 1e-9
): { ok: boolean; reason?: string } {
  if (typeof expected === "number" && typeof actual === "number") {
    return almostEqual(expected, actual, tolerance)
      ? { ok: true }
      : { ok: false, reason: `number ${actual} != ${expected}` };
  }

  if (expected && typeof expected === "object" && "__complex" in expected) {
    if (!actual || typeof actual !== "object" || !("__complex" in actual)) {
      return { ok: false, reason: `expected complex, got ${JSON.stringify(actual)}` };
    }
    if (!almostEqual(expected.re, actual.re, tolerance) || !almostEqual(expected.im, actual.im, tolerance)) {
      return { ok: false, reason: `complex (${actual.re}+${actual.im}i) != (${expected.re}+${expected.im}i)` };
    }
    return { ok: true };
  }

  if (expected && typeof expected === "object" && "__unit" in expected) {
    const actualNum = actual && typeof actual === "object" && "__unit" in actual ? actual.value : actual;
    if (typeof actualNum !== "number") return { ok: false, reason: `expected unit number ${expected.value}, got ${JSON.stringify(actual)}` };
    return almostEqual(expected.value, actualNum, Math.max(tolerance, 1e-6))
      ? { ok: true }
      : { ok: false, reason: `unit ${actualNum} != ${expected.value}` };
  }

  if (expected && typeof expected === "object" && "__matrix" in expected) {
    if (!actual || typeof actual !== "object" || !("__matrix" in actual)) {
      return { ok: false, reason: `expected matrix, got ${JSON.stringify(actual)}` };
    }
    return compareNormalized(expected.data as NormalizedValue, actual.data as NormalizedValue, tolerance);
  }

  if (Array.isArray(expected) && Array.isArray(actual)) {
    if (expected.length !== actual.length) {
      return { ok: false, reason: `array length ${actual.length} != ${expected.length}` };
    }
    for (let i = 0; i < expected.length; i++) {
      const r = compareNormalized(expected[i], actual[i], tolerance);
      if (!r.ok) return { ok: false, reason: `index ${i}: ${r.reason}` };
    }
    return { ok: true };
  }

  if (expected && typeof expected === "object" && "__error" in expected) {
    return actual && typeof actual === "object" && "__error" in actual
      ? { ok: true }
      : { ok: false, reason: `expected error, got ${JSON.stringify(actual)}` };
  }

  const eq = JSON.stringify(expected) === JSON.stringify(actual);
  return eq ? { ok: true } : { ok: false, reason: `${JSON.stringify(actual)} != ${JSON.stringify(expected)}` };
}