import { describe, expect, it } from "bun:test";
import { createDefaultWasmImports, runMathZigCompiler } from "./wasm_utils";
import { AotHostEnv, readAbiManifest, type AotAbiManifest } from "../../src/ts/aot_env";

/**
 * Usage guide for the delegated AOT host env (task-02), as executable tests.
 *
 * Standard flow:
 *   1. compile expression -> wasm bytes
 *   2. readAbiManifest(module)              (the "mathzig.abi" custom section)
 *   3. host.buildEnvForManifest(manifest)   BEFORE instantiate
 *   4. host.attachMemory / attachInstance   AFTER instantiate
 *   5. eval() -> raw f64, host.decodeResult(raw, manifest) -> typed value
 */
async function compileAndRun(expr: string): Promise<{ host: AotHostEnv; result: unknown; manifest: AotAbiManifest | null }> {
  const wasmBytes = await runMathZigCompiler(expr, 0);
  const module = await WebAssembly.compile(wasmBytes);
  const manifest = readAbiManifest(module);

  const host = new AotHostEnv();
  const env = host.buildEnvForManifest(manifest);
  const instance = await WebAssembly.instantiate(module, { env });

  host.attachMemory((instance.exports as { memory?: WebAssembly.Memory }).memory ?? null);
  host.attachInstance(instance.exports as Record<string, unknown>);

  const raw = (instance.exports.eval as () => number)();
  return { host, result: host.decodeResult(raw, manifest), manifest };
}

describe("AOT env usage: scalar fast path", () => {
  it("pure scalar math needs no manifest and no engine", async () => {
    const wasmBytes = await runMathZigCompiler("sin(1.5) + exp(2)", 0);
    const module = await WebAssembly.compile(wasmBytes);
    // createDefaultWasmImports() is the shortcut when you don't need decode
    const instance = await WebAssembly.instantiate(module, createDefaultWasmImports());
    const result = (instance.exports.eval as () => number)();
    const res2 = Math.sin(1.5) + Math.exp(2)
    expect(result).toBeCloseTo(res2, 12);
  });
});

describe("AOT env usage: delegated builtins", () => {
  it("non-trivial builtins delegate to the real engine", async () => {
    const { result } = await compileAndRun("gamma(5)");
    expect(result).toBeCloseTo(24, 9); // gamma(5) = 4!
  });

  it("string args are recognized via the manifest string table", async () => {
    const { result, manifest } = await compileAndRun('std([1, 2, 3], "biased")');
    expect(manifest?.strings).toBeDefined(); // data-segment offsets
    expect(result).toBeCloseTo(0.816496580927726, 12);
  });

  it("failed engine calls throw instead of returning silent NaN", async () => {
    // count() of a plain matrix is a type error in the engine
    await expect(compileAndRun("count([1, 2, 3, 4, 5])")).rejects.toThrow(/delegated builtin/);
  });
});

describe("AOT env usage: decoding typed results", () => {
  it("matrix results decode from module memory", async () => {
    const { result, manifest } = await compileAndRun("[1, 2; 3, 4] * [2, 0; 1, 2]");
    expect(manifest?.result_tag).toBe("matrix");
    const m = result as { rows: number; cols: number; data: Float64Array };
    expect([m.rows, m.cols]).toEqual([2, 2]);
    expect(Array.from(m.data)).toEqual([4, 4, 10, 8]);
  });

  it("complex results decode as { tag, re, im }", async () => {
    const { result, manifest } = await compileAndRun("conj(3 + 4i)");
    expect(manifest?.result_tag).toBe("complex");
    expect(result).toEqual({ tag: 1, re: 3, im: -4 });
  });

  it("record results decode into a key/value map", async () => {
    const { result, manifest } = await compileAndRun("{a: 1, b: 2}");
    expect(manifest?.result_tag).toBe("record");
    const rec = result as Map<string, number>;
    expect(rec.get("a")).toBe(1);
    expect(rec.get("b")).toBe(2);
  });

  it("delegated record results support in-module field access", async () => {
    // size() runs in the engine; its record is copied back into module
    // memory so the compiled `.rows` lookup (rec_get) can read it
    const { result } = await compileAndRun("size([1, 2; 3, 4; 5, 6]).rows");
    expect(result).toBe(3);
  });
});

describe("AOT env usage: series pipelines", () => {
  it("series flow through the host handle store across delegated calls", async () => {
    const { result } = await compileAndRun(
      'last(head(fillna(series([0, 1, 2], [10, nan, 30]), "forward"), 2))',
    );
    expect(result).toBe(10); // NaN forward-filled with 10, head 2, last
  });
});

describe("AOT env usage: ODE driver", () => {
  it("steps a module-exported derivative host-side (needs attachInstance)", async () => {
    const { result } = await compileAndRun(
      'simple_deriv(t, y) = -0.5 * y; ode_solve_euler("simple_deriv", [1], [0, 2], 0.1)',
    );
    // trajectory matrix: steps x (1 + dim), first column is t
    const m = result as { rows: number; cols: number; data: Float64Array };
    expect(m.cols).toBe(2);
    expect(m.rows).toBe(21); // ceil(2 / 0.1) + 1
    expect(m.data[0]).toBe(0); // t0
    expect(m.data[1]).toBe(1); // y0
    // Euler: y_n = (1 - 0.5*dt)^n
    expect(m.data[m.data.length - 1]).toBeCloseTo(Math.pow(0.95, 20), 9);
  });
});
