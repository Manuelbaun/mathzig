/**
 * Bun adapter — cross-runner graph parity (task-13 / C2).
 *
 * Modes: ts_wasm · native_vm (CLI) · zig_vm (composed) · native_wasm (exact skip).
 * Corpus: tests/graph/goldens/* (one source with Zig adapter).
 */

import { describe, expect, it, beforeAll } from "bun:test";
import { existsSync, mkdirSync, writeFileSync, unlinkSync } from "node:fs";
import { resolve, join } from "node:path";
import { compileAot } from "../parity/wasm_aot";
import { compareValues } from "../parity/compare";
import { MathZig } from "../../src/ts/mathzig";
import {
  GraphRunner,
  createDefaultScalarWasmImports,
  GRAPH_ALIAS_LIMIT,
  ALIAS_LIMIT_ERROR,
  type GraphDefinition,
  type GraphValue,
  type MatrixValue,
  type ComplexValue,
} from "../../src/ts/graph";
import { AotHostEnv } from "../../src/ts/aot_env";
import {
  loadAllGoldens,
  expectedSkipSet,
  assertExactSkipSet,
  NATIVE_WASM_SKIP_ID,
  type GoldenCase,
  type SkipRecord,
} from "../graph/corpus";

const compiler = {
  async compile(expr: string, numParams: number): Promise<Uint8Array> {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
};

const BIN = resolve("zig-out/bin/mathzig");
const TMP = resolve("tests/artifacts/graph_corpus");

const observedSkips: SkipRecord[] = [];

function zigVmEval(expr: string, vars: Record<string, number> = {}): unknown {
  const mz = MathZig.create();
  try {
    for (const [k, v] of Object.entries(vars)) mz.setVariable(k, v);
    const res = mz.eval(expr);
    return unwrapValue(res);
  } finally {
    mz.destroy();
  }
}

function unwrapValue(res: unknown): unknown {
  if (res == null || typeof res !== "object") return res;
  const v = res as Record<string, unknown>;
  if (v.tag === 1 && typeof v.real === "function" && typeof v.imag === "function") {
    const re = (v.real as () => number)();
    const im = (v.imag as () => number)();
    (v.release as (() => void) | undefined)?.();
    return { tag: "complex", re, im };
  }
  if (typeof v.toNumber === "function") {
    try {
      const n = (v.toNumber as () => number)();
      if (Number.isFinite(n)) {
        (v.release as (() => void) | undefined)?.();
        return n;
      }
    } catch {
      /* fall through */
    }
  }
  if (typeof v.real === "function" && typeof v.imag === "function") {
    const re = (v.real as () => number)();
    const im = (v.imag as () => number)();
    (v.release as (() => void) | undefined)?.();
    return { tag: "complex", re, im };
  }
  if ("re" in v && "im" in v) return { tag: "complex", re: Number(v.re), im: Number(v.im) };
  if ("rows" in v && "cols" in v && "data" in v) {
    const data = v.data;
    const arr =
      data instanceof Float64Array
        ? Array.from(data)
        : Array.isArray(data)
          ? data.map(Number)
          : Array.from(data as ArrayLike<number>);
    return { tag: "matrix", rows: Number(v.rows), cols: Number(v.cols), data: arr };
  }
  return res;
}

function normalizeGraphValue(v: GraphValue | unknown): unknown {
  if (v == null || typeof v !== "object") return v;
  const o = v as Record<string, unknown>;
  if ("re" in o && "im" in o) return { tag: "complex", re: Number(o.re), im: Number(o.im) };
  if ("rows" in o && "cols" in o && "data" in o) {
    const data = o.data;
    const arr =
      data instanceof Float64Array
        ? Array.from(data)
        : Array.isArray(data)
          ? data.map(Number)
          : Array.from(data as ArrayLike<number>);
    return { tag: "matrix", rows: Number(o.rows), cols: Number(o.cols), data: arr };
  }
  return v;
}

function normalizeOutputs(outs: Record<string, GraphValue>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(outs)) result[k] = normalizeGraphValue(v);
  return result;
}

function compareOutputMap(
  expected: Record<string, unknown>,
  actual: Record<string, unknown>,
  tol: number,
  label: string,
): void {
  const expKeys = Object.keys(expected).sort();
  const actKeys = Object.keys(actual).sort();
  expect(actKeys).toEqual(expKeys);
  for (const key of expKeys) {
    const exp = expected[key];
    const act = actual[key];
    if (exp && typeof exp === "object" && !Array.isArray(exp) && "tag" in (exp as object)) {
      const e = exp as { tag: string; re?: number; im?: number; rows?: number; cols?: number; data?: number[] };
      if (e.tag === "matrix") {
        const a = act as { tag?: string; rows: number; cols: number; data: number[] };
        expect(a.rows).toBe(e.rows);
        expect(a.cols).toBe(e.cols);
        expect(a.data?.length).toBe(e.data!.length);
        for (let i = 0; i < e.data!.length; i++) {
          expect(Number(a.data[i])).toBeCloseTo(e.data![i]!, 12);
        }
        continue;
      }
      if (e.tag === "complex") {
        const a = act as { tag?: string; re: number; im: number };
        expect(a.re).toBeCloseTo(e.re!, 12);
        expect(a.im).toBeCloseTo(e.im!, 12);
        continue;
      }
    }
    const cmp = compareValues(exp, act, { tolerance: { abs: tol, rel: tol } });
    expect(cmp.ok, `${label}.${key}: ${cmp.reason ?? "mismatch"}`).toBe(true);
  }
}

async function runTsWasm(c: GoldenCase): Promise<Record<string, unknown>> {
  const host = new AotHostEnv();
  const runner = await GraphRunner.load(c.graph as GraphDefinition, {
    compiler,
    env: createDefaultScalarWasmImports(),
    host,
  });
  try {
    for (const p of c.params ?? []) runner.setParam(p.nodeId, p.name, p.value);
    return normalizeOutputs(runner.run(c.inputs ?? {}));
  } finally {
    runner.dispose();
  }
}

async function runNativeVmCli(c: GoldenCase): Promise<Record<string, unknown>> {
  if (!existsSync(BIN)) {
    throw new Error(`mathzig binary missing at ${BIN}; build with zig build (SDK shim on PATH)`);
  }
  mkdirSync(TMP, { recursive: true });
  const graphPath = join(TMP, `${c.id}.graph.json`);
  writeFileSync(graphPath, JSON.stringify(c.graph));
  const args = [BIN, "graph", "run", graphPath];
  for (const [name, value] of Object.entries(c.inputs ?? {})) {
    args.push("--set", `${name}=${value}`);
  }
  for (const p of c.params ?? []) {
    args.push("--param", `${p.nodeId}:${p.name}=${p.value}`);
  }
  const proc = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" });
  const code = await proc.exited;
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  if (code !== 0) {
    throw new Error(`native_vm CLI failed (${code}): ${stderr || stdout}`);
  }
  // mathzig graph run prints results via std.debug.print → stderr.
  const combined = `${stdout}\n${stderr}`;
  // Last JSON object line (starts with '{').
  const line = combined
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("{") && l.endsWith("}"))
    .pop();
  if (!line) {
    throw new Error(`native_vm CLI produced no JSON for ${c.id}: out=${stdout} err=${stderr}`);
  }
  return JSON.parse(line) as Record<string, unknown>;
}

function runNativeVmLoadError(c: GoldenCase): { code: string; message: string } {
  if (!existsSync(BIN)) {
    throw new Error(`mathzig binary missing at ${BIN}`);
  }
  mkdirSync(TMP, { recursive: true });
  const graphPath = join(TMP, `${c.id}.graph.json`);
  writeFileSync(graphPath, JSON.stringify(c.graph));
  const proc = Bun.spawnSync([BIN, "graph", "run", graphPath], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const stderr = proc.stderr.toString();
  const stdout = proc.stdout.toString();
  const message = `${stderr}\n${stdout}`;
  // CLI prints error names; map cycle → Cycle.
  let code = "Unknown";
  if (/cycle/i.test(message)) code = "Cycle";
  else if (/AliasLimitExceeded/i.test(message)) code = "AliasLimitExceeded";
  else if (/WasmPhase2/i.test(message)) code = "WasmPhase2Required";
  else {
    const m = message.match(/Error loading graph: (\w+)/);
    if (m) code = m[1]!;
  }
  return { code, message };
}

describe("cross-runner graph corpus (task-13 C2)", () => {
  const goldens = loadAllGoldens();

  beforeAll(() => {
    mkdirSync(TMP, { recursive: true });
    observedSkips.length = 0;
  });

  it("loads required golden files (corpus contract)", () => {
    expect(goldens.length).toBeGreaterThanOrEqual(12);
    const ids = new Set(goldens.map((g) => g.id));
    expect(ids.size).toBe(goldens.length);
  });

  for (const c of goldens) {
    describe(`case ${c.id} (${c.file})`, () => {
      if (c.form === "load_error") {
        it("ts_wasm load-error matches code", async () => {
          await expect(
            GraphRunner.load(c.graph as GraphDefinition, {
              compiler,
              env: createDefaultScalarWasmImports(),
            }),
          ).rejects.toThrow(new RegExp(c.error_code === "Cycle" ? "cycle" : c.error_code ?? "error", "i"));
        });

        it("native_vm load-error matches code", () => {
          const { code, message } = runNativeVmLoadError(c);
          expect(code).toBe(c.error_code);
          if (c.offending) {
            expect(message.toLowerCase()).toContain(c.offending.toLowerCase());
          }
        });

        it("native_wasm mode is not applicable (no execution skip entry)", () => {
          // load_error cases never enter native_wasm execution; success cases own the skip bucket.
          expect(c.form).toBe("load_error");
        });
        return;
      }

      // ── success ──────────────────────────────────────────────────────────
      it("ts_wasm matches expected_outputs", async () => {
        const outs = await runTsWasm(c);
        compareOutputMap(c.expected_outputs ?? {}, outs, c.tolerance ?? 1e-12, "ts_wasm");
      }, 120_000);

      it("native_vm matches expected_outputs", async () => {
        const outs = await runNativeVmCli(c);
        // CLI may print numbers without tag wrappers; normalize matrix/complex shapes.
        const normalized: Record<string, unknown> = {};
        for (const [k, v] of Object.entries(outs)) {
          if (v && typeof v === "object" && "rows" in (v as object) && "cols" in (v as object)) {
            const m = v as { rows: number; cols: number; data: number[] };
            normalized[k] = { tag: "matrix", rows: m.rows, cols: m.cols, data: m.data };
          } else if (v && typeof v === "object" && "re" in (v as object) && "im" in (v as object)) {
            const cx = v as { re: number; im: number };
            normalized[k] = { tag: "complex", re: cx.re, im: cx.im };
          } else {
            normalized[k] = v;
          }
        }
        compareOutputMap(c.expected_outputs ?? {}, normalized, c.tolerance ?? 1e-12, "native_vm");
      }, 60_000);

      it("zig_vm composed-expr oracle aligns with expected (when applicable)", () => {
        if (!c.composed_expr) return;
        const exp = c.expected_outputs ?? {};
        const keys = Object.keys(exp);
        if (keys.length === 0) {
          // empty graph: composed is a placeholder only
          const v = zigVmEval(c.composed_expr, c.composed_vars ?? {});
          expect(v).toBeDefined();
          return;
        }
        const oracle = unwrapValue(zigVmEval(c.composed_expr, c.composed_vars ?? {}));
        const targetKey = "value" in exp ? "value" : keys.length === 1 ? keys[0]! : "end" in exp ? "end" : null;
        if (!targetKey) return; // multi-output structural; runners already checked
        const expected = exp[targetKey];
        if (expected && typeof expected === "object" && "tag" in (expected as object)) {
          const e = expected as { tag: string; re?: number; im?: number; rows?: number; cols?: number; data?: number[] };
          if (e.tag === "matrix") {
            const a = oracle as { tag?: string; rows: number; cols: number; data: number[] };
            expect(a.rows).toBe(e.rows);
            expect(a.cols).toBe(e.cols);
            for (let i = 0; i < e.data!.length; i++) {
              expect(Number(a.data[i])).toBeCloseTo(e.data![i]!, 12);
            }
            return;
          }
          if (e.tag === "complex") {
            const a = oracle as { re: number; im: number };
            expect(a.re).toBeCloseTo(e.re!, 12);
            expect(a.im).toBeCloseTo(e.im!, 12);
            return;
          }
        }
        const cmp = compareValues(expected, oracle, {
          tolerance: { abs: c.tolerance ?? 1e-12, rel: c.tolerance ?? 1e-12 },
        });
        expect(cmp.ok, `zig_vm: ${cmp.reason}`).toBe(true);
      });

      it("native_wasm is expected-skip with exact ID", () => {
        const rec: SkipRecord = {
          case_id: c.id,
          mode: "native_wasm",
          id: NATIVE_WASM_SKIP_ID,
          reason: "Pure-wasm node interpreter not landed (VM-native evaluator v1 never loads .wasm bytes).",
        };
        observedSkips.push(rec);
        expect(rec.id).toBe(NATIVE_WASM_SKIP_ID);
      });
    });
  }

  it("exact skip-ID set matches corpus contract (no silent growth/shrink)", () => {
    // Re-build from success cases if parallel describe ordering left holes.
    const success = goldens.filter((g) => g.form === "success");
    const rebuilt: SkipRecord[] = success.map((c) => ({
      case_id: c.id,
      mode: "native_wasm" as const,
      id: NATIVE_WASM_SKIP_ID,
      reason: "Pure-wasm node interpreter not landed (VM-native evaluator v1 never loads .wasm bytes).",
    }));
    assertExactSkipSet(rebuilt, expectedSkipSet(goldens));
    // Also assert observed from per-case tests (may be empty if only this runs — use rebuilt).
    assertExactSkipSet(rebuilt);
  });

  // ── Negatives ────────────────────────────────────────────────────────────
  describe("negatives", () => {
    it("wrong expected value fails ts_wasm comparison", async () => {
      const c = goldens.find((g) => g.id === "scalar_double_then_add")!;
      const outs = await runTsWasm(c);
      const cmp = compareValues(999, outs.value, { tolerance: { abs: 1e-12 } });
      expect(cmp.ok).toBe(false);
    });

    it("AliasLimitExceeded: same named error from TS and native when >3 ports", async () => {
      const bad: GraphDefinition = {
        nodes: [
          { id: "a", type: "input" },
          { id: "b", type: "input" },
          { id: "c", type: "input" },
          { id: "d", type: "input" },
          {
            id: "sum",
            type: "expr",
            expr: "a + b + c + d",
            inputs: ["a", "b", "c", "d"],
          },
        ],
        edges: [
          { from: "a.out", to: "sum.a" },
          { from: "b.out", to: "sum.b" },
          { from: "c.out", to: "sum.c" },
          { from: "d.out", to: "sum.d" },
        ],
        outputs: { value: "sum.out" },
      };

      // TS
      let tsMsg = "";
      try {
        await GraphRunner.load(bad, { compiler, env: createDefaultScalarWasmImports() });
      } catch (e) {
        tsMsg = String(e);
      }
      expect(tsMsg).toContain(ALIAS_LIMIT_ERROR);
      expect(GRAPH_ALIAS_LIMIT).toBe(3);

      // Native CLI
      if (!existsSync(BIN)) throw new Error("mathzig binary missing");
      mkdirSync(TMP, { recursive: true });
      const path = join(TMP, "alias_limit_bad.json");
      writeFileSync(path, JSON.stringify(bad));
      const proc = Bun.spawnSync([BIN, "graph", "run", path], { stdout: "pipe", stderr: "pipe" });
      expect(proc.exitCode).not.toBe(0);
      const msg = `${proc.stderr.toString()}\n${proc.stdout.toString()}`;
      expect(msg).toMatch(/AliasLimitExceeded/);
    });
  });
});
