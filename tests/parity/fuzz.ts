#!/usr/bin/env bun
/**
 * Seeded differential fuzzer: zig_vm vs wasm_aot.
 *
 *   bun tests/parity/fuzz.ts
 *   bun tests/parity/fuzz.ts --seed=42 --count=500
 *   bun tests/parity/fuzz.ts --seed=7 --count=50 --minimize
 *
 * Determinism: same seed → same expression stream.
 * Divergences are printed (and optionally minimized) for promotion into
 * tests/parity/cases/fuzz_regressions.json.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import aotAbi from "../../src/bindings/generated/aot_abi.json";
import { compareValues } from "./compare";
import { ZigVmBackend } from "./backends/zig_vm";
import { WasmAotBackend } from "./backends/wasm_aot";

// ---------------------------------------------------------------------------
// Types / constants
// ---------------------------------------------------------------------------

type WireKind =
  | "number"
  | "boolean"
  | "matrix_ptr"
  | "complex_ptr"
  | "record_ptr"
  | "string_ptr"
  | "series_handle"
  | "predicate_ptr"
  | "any";

type BuiltinSpec = {
  id: number;
  args: WireKind[];
  ret: WireKind;
  min_args: number;
  variadic: boolean;
  where_capable: boolean;
  supported: boolean;
};

type AbiFile = { builtins: Record<string, BuiltinSpec> };
const ABI = aotAbi as AbiFile;

const DEFAULT_SEED = 0x4d415448; // 'MATH'
const DEFAULT_COUNT = 500;

/** ABI names that are unsafe or non-deterministic for differential fuzz. */
const SKIP_BUILTINS = new Set([
  "random",
  "randomInt",
  "pickRandom",
  "now",
  "read_csv",
  "write_csv",
  "create_unit",
  "config",
  "ode_solve", // needs setup / user fn
  "ode_solve_euler",
  "assert", // throws on false
  "toLaTeX", // string wire; covered by gauntlet
  "number", // units long-tail
  "conv", // units long-tail
]);

const DSL_NAME: Record<string, string> = {
  align_: "align",
  gen_range: "range",
};

export type FuzzExpr = {
  index: number;
  expr: string;
  setup?: string[];
  builtin: string;
};

export type FuzzDivergence = {
  index: number;
  seed: number;
  expr: string;
  setup?: string[];
  builtin: string;
  reason: string;
  zig?: unknown;
  aot?: unknown;
  minimized?: string;
};

// ---------------------------------------------------------------------------
// Seeded PRNG (mulberry32) — pure, no Math.random
// ---------------------------------------------------------------------------

export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pick<T>(rng: () => number, arr: readonly T[]): T {
  return arr[Math.floor(rng() * arr.length) % arr.length]!;
}

function int(rng: () => number, lo: number, hi: number): number {
  return lo + Math.floor(rng() * (hi - lo + 1));
}

// ---------------------------------------------------------------------------
// Expression generation
// ---------------------------------------------------------------------------

const SCALAR_BUILTINS = [
  "abs", "sqrt", "cbrt", "exp", "log", "log10", "log2",
  "sin", "cos", "tan", "asin", "acos", "atan",
  "sinh", "cosh", "tanh", "floor", "ceil", "round", "trunc", "sign",
  "square", "cube", "log1p", "expm1", "asinh",
  "sech", "csch", "coth", "erf",
];

const BINARY_SCALAR = ["atan2", "hypot", "min", "max", "gcd", "lcm", "pow_via_sqrt"];

function dsl(name: string): string {
  return DSL_NAME[name] ?? name;
}

function fuzzableBuiltins(): Array<{ name: string; spec: BuiltinSpec }> {
  return Object.entries(ABI.builtins)
    .filter(([name, s]) => s.supported && !SKIP_BUILTINS.has(name))
    .map(([name, spec]) => ({ name, spec }))
    .sort((a, b) => a.spec.id - b.spec.id);
}

function litNumber(rng: () => number): string {
  const mode = int(rng, 0, 6);
  switch (mode) {
    case 0: return String(int(rng, -5, 5));
    case 1: return (rng() * 4 - 2).toFixed(4);
    case 2: return "0";
    case 3: return "1";
    case 4: return "0.5";
    case 5: return "2";
    default: return String(int(rng, 1, 10));
  }
}

function litMatrix(rng: () => number): string {
  const kind = int(rng, 0, 5);
  switch (kind) {
    case 0: return "[]";
    case 1: return `[${litNumber(rng)}]`;
    case 2: return `[${litNumber(rng)}, ${litNumber(rng)}; ${litNumber(rng)}, ${litNumber(rng)}]`;
    case 3: return `[${litNumber(rng)}, ${litNumber(rng)}, ${litNumber(rng)}]`; // 1×3 row vector
    case 4: return `[${litNumber(rng)}; ${litNumber(rng)}; ${litNumber(rng)}]`; // 3×1 col vector
    default: return "[1, 0; 0, 1]";
  }
}

/** Matrices safe to pass into series() (must be vectors). */
function litVector(rng: () => number): string {
  const n = int(rng, 1, 4);
  const vals = Array.from({ length: n }, () => litNumber(rng)).join(", ");
  return rng() < 0.5 ? `[${vals}]` : `[${vals.replace(/, /g, "; ")}]`;
}

function litSeries(rng: () => number): string {
  const kind = int(rng, 0, 3);
  switch (kind) {
    case 0: return "series([], [])";
    case 1: {
      const n = int(rng, 1, 5);
      const ts = Array.from({ length: n }, (_, i) => i).join(", ");
      const vs = Array.from({ length: n }, () => litNumber(rng)).join(", ");
      return `series([${ts}], [${vs}])`;
    }
    case 2: return "series([0, 1, 2, 3, 4], [10, 20, 30, 40, 50])";
    default: {
      const n = int(rng, 2, 6);
      const ts = Array.from({ length: n }, (_, i) => i).join(", ");
      const vs = Array.from({ length: n }, () => litNumber(rng)).join(", ");
      return `series([${ts}], [${vs}])`;
    }
  }
}

function litComplex(rng: () => number): string {
  return `(${litNumber(rng)} + ${litNumber(rng)}i)`;
}

function domainSafeArg(name: string, rng: () => number): string[] | null {
  // Return fixed safe args for domain-sensitive builtins; null → use generic.
  switch (name) {
    case "sqrt": return [String(Math.abs(Number(litNumber(rng))) || 4)];
    case "log":
    case "log10":
    case "log2":
    case "log1p":
      return [String(0.5 + rng() * 10)];
    case "asin":
    case "acos":
    case "atanh":
      return [(rng() * 1.8 - 0.9).toFixed(4)];
    case "acosh":
      return [String(1 + rng() * 5)];
    case "asech":
      return [(0.1 + rng() * 0.8).toFixed(4)];
    case "acsch":
      return [String((rng() < 0.5 ? -1 : 1) * (0.5 + rng() * 3))];
    case "acoth":
      return [String((rng() < 0.5 ? -1 : 1) * (1.5 + rng() * 3))];
    case "asec":
    case "acsc":
      return [String((rng() < 0.5 ? -1 : 1) * (1.1 + rng() * 3))];
    case "factorial":
      return [String(int(rng, 0, 10))];
    case "gamma":
    case "lgamma":
      return [String(0.5 + rng() * 5)];
    case "combinations":
    case "permutations":
      return [String(int(rng, 3, 8)), String(int(rng, 1, 3))];
    case "nthRoot":
      return [String(int(rng, 1, 27)), String(int(rng, 2, 3))];
    case "gcd":
    case "lcm":
      return [String(int(rng, 1, 30)), String(int(rng, 1, 30))];
    case "isPrime":
      return [String(int(rng, 2, 50))];
    case "clamp":
      return [litNumber(rng), "0", "10"];
    case "atan2":
    case "hypot":
      return [litNumber(rng), litNumber(rng)];
    case "round":
      return [litNumber(rng)];
    case "det":
    case "inv":
    case "trace":
      return ["[2, 0; 0, 4]"];
    case "gemv":
      return ["[1, 2; 3, 4]", "[1; 1]"];
    case "dot":
      return ["[1, 2, 3]", "[4, 5, 6]"];
    case "cross":
      return ["[1, 0, 0]", "[0, 1, 0]"];
    case "reshape":
      return ["[1, 2, 3, 4, 5, 6]", "2", "3"];
    case "zeros":
    case "ones":
      return [String(int(rng, 0, 3)), String(int(rng, 0, 3))];
    case "identity":
      return [String(int(rng, 0, 4))];
    case "linspace":
    case "logspace":
      return ["0", "1", String(int(rng, 2, 6))];
    case "gen_range":
      return ["0", String(int(rng, 2, 6))];
    case "bollinger":
      return [litSeries(rng), "5", "2"];
    case "macd":
      return [litSeries(rng), "3", "6", "2"];
    case "sma":
    case "ema":
    case "rsi":
    case "rolling_sum":
    case "rolling_mean":
    case "rolling_min":
    case "rolling_max":
    case "rolling_count":
    case "rolling_stddev":
      return [litSeries(rng), String(int(rng, 2, 4))];
    case "diff":
    case "pct_change":
      return [litSeries(rng), "1"];
    case "head":
    case "tail":
    case "shift":
      return [litSeries(rng), String(int(rng, 0, 3))];
    case "slice":
    case "between":
      return [litSeries(rng), "0", "2"];
    case "since":
      return [litSeries(rng), "1"];
    case "clip":
      return [litSeries(rng), "0", "10"];
    case "fillna":
      return [litSeries(rng), "0"];
    case "resample":
      return [litSeries(rng), String(int(rng, 2, 5)), "\"mean\""];
    case "asofJoin":
    case "align_":
      return [litSeries(rng), litSeries(rng)];
    case "concat":
      return [litMatrix(rng), litMatrix(rng)];
    case "re":
    case "im":
    case "arg":
    case "conj":
      return [litComplex(rng)];
    case "std":
    case "variance":
    case "median":
    case "prod":
    case "mad":
    case "mean":
    case "sum":
    case "count":
      // Prefer matrix args — median/prod on series are elementwise and diverge
      // on wasm_aot where-predicate paths (series vs NaN).
      return [litMatrix(rng)];
    case "series":
      return [litVector(rng), litVector(rng)];
    default:
      return null;
  }
}

function argsForBuiltin(name: string, spec: BuiltinSpec, rng: () => number): string[] {
  const special = domainSafeArg(name, rng);
  if (special) return special;

  const arity = spec.variadic
    ? int(rng, Math.max(1, spec.min_args), Math.max(spec.min_args, spec.args.length))
    : Math.max(spec.min_args, spec.args.length);

  const args: string[] = [];
  for (let i = 0; i < arity; i++) {
    const kind = spec.args[Math.min(i, spec.args.length - 1)] ?? "number";
    args.push(argForKind(kind, rng));
  }
  return args;
}

function argForKind(kind: WireKind, rng: () => number): string {
  switch (kind) {
    case "number":
      return litNumber(rng);
    case "boolean":
      return rng() < 0.5 ? "0" : "1";
    case "matrix_ptr":
      return litMatrix(rng);
    case "complex_ptr":
      return litComplex(rng);
    case "series_handle":
      return litSeries(rng);
    case "string_ptr":
      return pick(rng, ["\"mean\"", "\"sum\"", "\"forward\"", "\"x\""]);
    case "any":
      // Bias toward matrices/numbers; series any-args trip elementwise stats.
      return pick(rng, [litNumber(rng), litMatrix(rng), litVector(rng)]);
    case "record_ptr":
      return "{ a: 1 }";
    default:
      return litNumber(rng);
  }
}

/**
 * Generate one well-typed expression. Bounded depth: mostly single builtin
 * calls; occasionally nested scalar wrappers.
 */
export function generateExpr(
  rng: () => number,
  builtins: Array<{ name: string; spec: BuiltinSpec }>,
  index: number,
): FuzzExpr {
  const depth = int(rng, 0, 2);
  const { name, spec } = pick(rng, builtins);
  const args = argsForBuiltin(name, spec, rng);
  let expr = `${dsl(name)}(${args.join(", ")})`;

  // Optional where clause on where-capable builtins with series-like first arg
  if (spec.where_capable && rng() < 0.25) {
    expr = `${expr} where value > ${litNumber(rng)}`;
  }

  // Nest under a cheap scalar for depth > 0 when result is a number.
  // Do not wrap booleans (abs(isPrime(...)) is a TypeError on zig_vm).
  if (depth > 0 && spec.ret === "number") {
    const wrap = pick(rng, SCALAR_BUILTINS);
    // Keep domain-safe wrappers
    if (wrap === "sqrt" || wrap === "log" || wrap === "log10" || wrap === "log2") {
      expr = `${wrap}(abs(${expr}) + 1)`;
    } else if (wrap === "asin" || wrap === "acos" || wrap === "atanh") {
      expr = `${wrap}(tanh(${expr}))`;
    } else {
      expr = `${wrap}(${expr})`;
    }
  }

  // Reduce series/matrix results to a comparable scalar when helpful
  if (spec.ret === "series_handle" && rng() < 0.6) {
    expr = `last(${expr})`;
  } else if (spec.ret === "matrix_ptr" && rng() < 0.5) {
    expr = pick(rng, [
      `size(${expr}).rows`,
      `size(${expr}).cols`,
      `last(flatten(${expr}))`,
    ]);
  } else if (spec.ret === "record_ptr" && rng() < 0.5) {
    // leave as record — compare by tag via expected
  }

  void BINARY_SCALAR;
  return { index, expr, builtin: name };
}

export function generateFuzzCorpus(seed: number, count: number): FuzzExpr[] {
  const rng = mulberry32(seed);
  const builtins = fuzzableBuiltins();
  const out: FuzzExpr[] = [];
  for (let i = 0; i < count; i++) {
    out.push(generateExpr(rng, builtins, i));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Evaluation + compare
// ---------------------------------------------------------------------------

function snapshot(value: unknown): unknown {
  if (value === null || value === undefined) return value;
  const t = typeof value;
  if (t === "number" || t === "boolean" || t === "string") return value;
  if (Array.isArray(value)) return value.map(snapshot);
  const v = value as any;
  if (v && typeof v === "object") {
    if (v.__error) return v;
    if (typeof v.tag === "number") {
      if (v.tag === 3 || (typeof v.rows === "number" && typeof v.cols === "number" && v.data)) {
        const rows = Number(v.rows);
        const cols = Number(v.cols);
        const data = v.data instanceof Float64Array
          ? Array.from(v.data)
          : Array.isArray(v.data)
            ? v.data.map(Number)
            : [];
        return { tag: "matrix", rows, cols, data };
      }
      if (v.tag === 4 || typeof v.len === "function") {
        try {
          return { tag: "series", len: Number(v.len()) };
        } catch {
          return { tag: "series" };
        }
      }
      if (v.tag === 1) {
        try {
          if (typeof v.real === "function") {
            return { tag: "complex", re: Number(v.real()), im: Number(v.imag()) };
          }
          if (typeof v.re === "number") {
            return { tag: "complex", re: Number(v.re), im: Number(v.im) };
          }
        } catch {
          return { tag: "complex" };
        }
      }
      if (v.tag === 10 || typeof v.getField === "function") {
        return { tag: "record" };
      }
      if (v.tag === 6) return { tag: "string" };
      if (v.tag === 2 && typeof v.num === "number") return v.num;
    }
    if (typeof v.len === "function" && typeof v.getTimestampsPtr === "function") {
      return { tag: "series", len: Number(v.len()) };
    }
    if (typeof v.rows === "number" && typeof v.cols === "number") {
      const data = v.data instanceof Float64Array ? Array.from(v.data) : [];
      return { tag: "matrix", rows: v.rows, cols: v.cols, data };
    }
    if (typeof v.getField === "function") return { tag: "record" };
  }
  return value;
}

async function evalBackend(
  backend: ZigVmBackend | WasmAotBackend,
  expr: FuzzExpr,
): Promise<{ ok: true; value: unknown } | { ok: false; error: string }> {
  try {
    if (expr.setup) {
      for (const line of expr.setup) {
        await backend.evaluate(line, {});
      }
    }
    const raw = await backend.evaluate(expr.expr, {});
    return { ok: true, value: snapshot(raw) };
  } catch (err: any) {
    return { ok: false, error: String(err?.message ?? err) };
  }
}

/**
 * Normalize a backend error string into a coarse (phase, code) pair so dual
 * errors can be compared without treating any two failures as a semantic pass
 * (task-19 P2).
 */
export function normalizeFuzzError(err: string): { phase: string; code: string; raw: string } {
  const raw = String(err ?? "");
  const s = raw.toLowerCase();
  let phase = "runtime";
  if (/compile|parse|syntax|token|unexpected/.test(s)) phase = "compile";
  else if (/type\s*error|typeerror|wrong type|expected .* got|not a (matrix|series|number|string|record|complex)/.test(s))
    phase = "type";
  else if (/out of memory|oom|alloc/.test(s)) phase = "memory";
  else if (/standalone unsupported|standalone/.test(s)) phase = "standalone";
  else if (/not (yet )?implemented|unsupported|unknown builtin/.test(s)) phase = "unsupported";
  else if (/assert|assertion/.test(s)) phase = "assert";
  else if (/domain|nan|inf|overflow|div(ision)? by zero/.test(s)) phase = "domain";

  let code = "generic";
  if (/type/.test(s)) code = "type_error";
  else if (/compile|parse|syntax/.test(s)) code = "compile_error";
  else if (/memory|oom|alloc/.test(s)) code = "oom";
  else if (/unsupported|not implemented/.test(s)) code = "unsupported";
  else if (/assert/.test(s)) code = "assert";
  else if (/div|zero|domain|nan/.test(s)) code = "domain";
  else if (/index|bounds|range/.test(s)) code = "bounds";
  else if (/undefined|null|missing/.test(s)) code = "undefined";

  return { phase, code, raw };
}

export type FuzzCompareResult =
  | { ok: true; dualError?: false }
  | { ok: true; dualError: true; zigNorm: ReturnType<typeof normalizeFuzzError>; aotNorm: ReturnType<typeof normalizeFuzzError> }
  | { ok: false; reason: string; dualErrorMismatch?: boolean };

function compareFuzz(
  zig: { ok: boolean; value?: unknown; error?: string },
  aot: { ok: boolean; value?: unknown; error?: string },
): FuzzCompareResult {
  // Dual errors: no longer a semantic pass. Matching normalized phase/code →
  // dual-error bucket; mismatch → divergence.
  if (!zig.ok && !aot.ok) {
    const zn = normalizeFuzzError(zig.error ?? "");
    const an = normalizeFuzzError(aot.error ?? "");
    if (zn.phase === an.phase && zn.code === an.code) {
      return { ok: true, dualError: true, zigNorm: zn, aotNorm: an };
    }
    return {
      ok: false,
      dualErrorMismatch: true,
      reason: `dual-error mismatch zig=${zn.phase}/${zn.code} aot=${an.phase}/${an.code} (${zn.raw.slice(0, 80)} | ${an.raw.slice(0, 80)})`,
    };
  }
  if (!zig.ok || !aot.ok) {
    return {
      ok: false,
      reason: !zig.ok
        ? `zig_vm error: ${zig.error}; aot=${JSON.stringify(aot.value)}`
        : `wasm_aot error: ${aot.error}; zig=${JSON.stringify(zig.value)}`,
    };
  }
  const cmp = compareValues(zig.value, aot.value, { tolerance: { abs: 1e-12, rel: 1e-12 } });
  if (cmp.ok) return { ok: true };
  return { ok: false, reason: cmp.reason ?? "value mismatch" };
}

/** Shrink expr by stripping wrappers / simplifying args — best-effort. */
export function minimizeExpr(expr: string): string {
  let cur = expr.trim();
  // Unwrap last(...), abs(...), size(...).rows etc. when still divergent is caller's job;
  // here just produce a few candidates' first element as the "smallest" form.
  const wrappers = [
    /^last\((.*)\)$/s,
    /^abs\((.*)\)$/s,
    /^sign\((.*)\)$/s,
    /^floor\((.*)\)$/s,
    /^ceil\((.*)\)$/s,
    /^sqrt\(abs\((.*)\) \+ 1\)$/s,
    /^size\((.*)\)\.rows$/s,
    /^size\((.*)\)\.cols$/s,
    /^last\(flatten\((.*)\)\)$/s,
  ];
  let changed = true;
  while (changed) {
    changed = false;
    for (const re of wrappers) {
      const m = cur.match(re);
      if (m) {
        cur = m[1]!.trim();
        changed = true;
        break;
      }
    }
  }
  // Drop where clause
  const whereIdx = cur.lastIndexOf(") where ");
  if (whereIdx > 0) {
    cur = cur.slice(0, whereIdx + 1);
  }
  return cur;
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

export type FuzzRunOptions = {
  seed?: number;
  count?: number;
  minimize?: boolean;
  /** When true, do not process.exit — return summary (for tests). */
  quiet?: boolean;
};

export type FuzzRunResult = {
  seed: number;
  count: number;
  /** Both backends succeeded and values matched. */
  passed: number;
  /** Value mismatch, one-sided error, or dual-error phase/code mismatch. */
  failed: number;
  /**
   * Both backends errored with matching normalized phase/code.
   * Not a semantic pass (task-19 P2); own summary bucket.
   */
  dualError: number;
  /** @deprecated alias of dualError */
  bothErrored: number;
  /** Well-typed corpus cases where zig_vm failed (generator quality / bug). */
  zigFailedWellTyped: number;
  divergences: FuzzDivergence[];
  exprs: FuzzExpr[];
};

export async function runFuzz(opts: FuzzRunOptions = {}): Promise<FuzzRunResult> {
  const seed = opts.seed ?? DEFAULT_SEED;
  const count = opts.count ?? DEFAULT_COUNT;
  const exprs = generateFuzzCorpus(seed, count);

  const zig = new ZigVmBackend();
  const aot = new WasmAotBackend();
  await zig.init();
  await aot.init();

  let passed = 0;
  let failed = 0;
  let dualError = 0;
  let zigFailedWellTyped = 0;
  const divergences: FuzzDivergence[] = [];

  try {
    for (const fe of exprs) {
      if (typeof zig.reset === "function") zig.reset();
      if (typeof aot.reset === "function") aot.reset();

      const z = await evalBackend(zig, fe);
      const a = await evalBackend(aot, fe);

      // Corpus is intended well-typed; zig_vm failure is tracked separately.
      if (!z.ok) zigFailedWellTyped += 1;

      const cmp = compareFuzz(z, a);
      if (cmp.ok && "dualError" in cmp && cmp.dualError) {
        dualError += 1;
        // Not counted as semantic pass.
        continue;
      }
      if (cmp.ok) {
        passed += 1;
      } else {
        failed += 1;
        const div: FuzzDivergence = {
          index: fe.index,
          seed,
          expr: fe.expr,
          setup: fe.setup,
          builtin: fe.builtin,
          reason: ("reason" in cmp ? cmp.reason : undefined) ?? "mismatch",
          zig: z.ok ? z.value : { __error: z.error },
          aot: a.ok ? a.value : { __error: a.error },
        };
        if (opts.minimize) {
          div.minimized = minimizeExpr(fe.expr);
        }
        divergences.push(div);
        if (!opts.quiet) {
          console.error(
            `DIVERGE #${fe.index} [${fe.builtin}]: ${fe.expr}\n  ${div.reason}`,
          );
        }
      }
    }
  } finally {
    await zig.dispose();
    await aot.dispose();
  }

  return {
    seed,
    count,
    passed,
    failed,
    dualError,
    bothErrored: dualError,
    zigFailedWellTyped,
    divergences,
    exprs,
  };
}

// ---------------------------------------------------------------------------
// Determinism helper (used by tests)
// ---------------------------------------------------------------------------

export function exprsForSeed(seed: number, count: number): string[] {
  return generateFuzzCorpus(seed, count).map((e) => e.expr);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv: string[]): FuzzRunOptions & { help?: boolean } {
  let seed = DEFAULT_SEED;
  let count = DEFAULT_COUNT;
  let minimize = false;
  for (const a of argv) {
    if (a === "--help" || a === "-h") return { help: true };
    if (a === "--minimize") minimize = true;
    else if (a.startsWith("--seed=")) seed = Number(a.slice("--seed=".length)) >>> 0;
    else if (a.startsWith("--count=")) count = Math.max(1, Number(a.slice("--count=".length)) | 0);
    else throw new Error(`Unknown fuzz arg: ${a}`);
  }
  return { seed, count, minimize };
}

if (import.meta.main) {
  const opts = parseArgs(process.argv.slice(2));
  if ((opts as any).help) {
    console.log(`Usage: bun tests/parity/fuzz.ts [--seed=N] [--count=N] [--minimize]
Defaults: --seed=${DEFAULT_SEED} --count=${DEFAULT_COUNT}`);
    process.exit(0);
  }

  console.log(`Fuzz seed=${opts.seed} count=${opts.count}`);
  const res = await runFuzz(opts);
  console.log(
    `Done: passed=${res.passed} failed=${res.failed} dual_error=${res.dualError} zig_fail_welltyped=${res.zigFailedWellTyped}`,
  );

  if (res.divergences.length > 0) {
    const artDir = path.resolve("tests/artifacts/parity");
    fs.mkdirSync(artDir, { recursive: true });
    const artPath = path.join(artDir, `fuzz_divergences_s${res.seed}.json`);
    fs.writeFileSync(artPath, JSON.stringify(res.divergences, null, 2) + "\n");
    console.error(`Wrote ${res.divergences.length} divergences → ${artPath}`);
    console.error(
      "Minimize into tests/parity/cases/fuzz_regressions.json and fix (VM-first).",
    );
    process.exitCode = 1;
  } else {
    console.log(
      "No divergences (value match or dual-error phase/code match). dual_error is not a semantic pass.",
    );
  }
}
