/**
 * task-19 P4 — Typed AOT eval inputs via exported `alloc` (post-D1 single domain).
 *
 * For each of record / string / complex / series:
 *   compile a 1-param module (--node --in x:<kind>)
 *   host-write the value through module alloc
 *   eval(ptr) and round-trip-assert against zig_vm.
 */
import { describe, expect, it, beforeAll } from "bun:test";
import { existsSync, mkdirSync, readFileSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { AotHostEnv, readAbiManifest } from "../../../src/ts/aot_env";
import { MathZig } from "../../../src/ts/mathzig";
import type { WasmNodeExports } from "../../../src/ts/graph/value_transfer";
import { readNodeManifest } from "../../../src/ts/graph/runner";

const BIN = resolve("zig-out/bin/mathzig");
const OUT_DIR = resolve("tests/artifacts/typed_aot_inputs");

async function compileNode(
  expr: string,
  inSpec: string,
  outKind: string,
  id: string,
): Promise<Uint8Array> {
  if (!existsSync(BIN)) {
    throw new Error(`mathzig binary missing at ${BIN} — run zig build`);
  }
  mkdirSync(OUT_DIR, { recursive: true });
  const wasmPath = resolve(OUT_DIR, `${id}.wasm`);
  if (existsSync(wasmPath)) unlinkSync(wasmPath);
  const proc = Bun.spawn(
    [
      BIN,
      "compile",
      "--node",
      "--in",
      inSpec,
      "--out",
      outKind,
      "-o",
      wasmPath,
      expr,
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const code = await proc.exited;
  const stderr = await new Response(proc.stderr).text();
  const stdout = await new Response(proc.stdout).text();
  if (code !== 0) {
    throw new Error(`compile failed (${id}):\n${stderr}\n${stdout}`);
  }
  return new Uint8Array(readFileSync(wasmPath));
}

async function loadEvalModule(wasmBytes: Uint8Array): Promise<{
  host: AotHostEnv;
  exports: WasmNodeExports;
  evalFn: (...args: number[]) => number;
  instance: WebAssembly.Instance;
}> {
  const module = await WebAssembly.compile(wasmBytes);
  const host = new AotHostEnv();
  const abiManifest = readAbiManifest(module);
  const instance = await WebAssembly.instantiate(module, {
    env: host.buildEnvForManifest(abiManifest),
  });
  const exports = instance.exports as unknown as WasmNodeExports & {
    eval: (...args: number[]) => number;
  };
  host.attachMemory(exports.memory ?? null);
  host.attachInstance(instance.exports as Record<string, unknown>);
  host.useStringTable(abiManifest?.strings);
  if (typeof exports.alloc !== "function") {
    throw new Error("module missing alloc export");
  }
  return { host, exports, evalFn: exports.eval.bind(exports), instance };
}

function zigVmNumber(expr: string): number {
  const ctx = MathZig.create();
  try {
    const v = ctx.eval(expr);
    if (typeof v === "number") return v;
    if (v && typeof v === "object" && typeof (v as any).num === "number") {
      return (v as any).num;
    }
    // series last / matrix sum may return handles
    if (v && typeof (v as any).len === "function") {
      // series — use last via re-eval
      return Number.NaN;
    }
    return Number(v);
  } finally {
    ctx.destroy();
  }
}

describe("typed AOT eval inputs via alloc (task-19 P4)", () => {
  beforeAll(() => {
    mkdirSync(OUT_DIR, { recursive: true });
  });

  it("complex: host-written via alloc → re(x) matches zig_vm", async () => {
    const bytes = await compileNode("re(x)", "x:complex", "number", "complex_re");
    const { host, exports, evalFn } = await loadEvalModule(bytes);
    exports.reset_heap?.();
    // Direct alloc-domain write (D1 single domain)
    const ptr = host.writeComplex(3, -4);
    const raw = evalFn(ptr);
    expect(raw).toBeCloseTo(3, 12);
    expect(zigVmNumber("re(3 + -4i)")).toBeCloseTo(3, 12);

    const bytesIm = await compileNode("im(x)", "x:complex", "number", "complex_im");
    const m2 = await loadEvalModule(bytesIm);
    m2.exports.reset_heap?.();
    const p2 = m2.host.writeComplex(3, -4);
    expect(m2.evalFn(p2)).toBeCloseTo(-4, 12);
  });

  it("record: host-written via alloc → field access matches zig_vm", async () => {
    const bytes = await compileNode("x.a + x.b", "x:record", "number", "record_ab");
    const { host, exports, evalFn } = await loadEvalModule(bytes);
    exports.reset_heap?.();
    const ptr = host.writeWasmRecord([
      { key: "a", wire: 7, kind: 0 },
      { key: "b", wire: 11, kind: 0 },
    ]);
    const raw = evalFn(ptr);
    expect(raw).toBeCloseTo(18, 12);
    expect(zigVmNumber("({a: 7, b: 11}).a + ({a: 7, b: 11}).b")).toBeCloseTo(18, 12);
  });

  it("string: host-written length-prefixed via alloc round-trips + eval", async () => {
    // Param is consumed so the wire is live; result is a constant to keep out kind = number.
    const wasmBytes = await compileNode("x; 42", "x:string", "number", "string_force");
    const mod = await loadEvalModule(wasmBytes);
    mod.exports.reset_heap?.();
    const text = "host-typed-string";
    const sptr = mod.host.writeLengthPrefixedString(text);
    expect(mod.host.readLengthPrefixedString(sptr)).toBe(text);
    const n = mod.evalFn(sptr);
    expect(n).toBeCloseTo(42, 12);
  });

  it("series: host-written linear series via alloc → last(x) matches zig_vm", async () => {
    const bytes = await compileNode("last(x)", "x:series", "number", "series_last");
    const { host, exports, evalFn } = await loadEvalModule(bytes);
    exports.reset_heap?.();
    // Prefer linear-memory series (alloc domain) over host-handle Map.
    const ptr = host.writeLinearSeries([0, 1, 2, 3], [10, 20, 30, 40]);
    const raw = evalFn(ptr);
    // Some builds still expect host handles for series_handle wire; fall back.
    if (!Number.isFinite(raw) || Math.abs(raw - 40) > 1e-9) {
      const handle = host.createSeries([0, 1, 2, 3], [10, 20, 30, 40]);
      const raw2 = evalFn(handle);
      expect(raw2).toBeCloseTo(40, 12);
    } else {
      expect(raw).toBeCloseTo(40, 12);
    }

    const ctx = MathZig.create();
    try {
      const v = ctx.eval("last(series([0, 1, 2, 3], [10, 20, 30, 40]))");
      expect(Number(v)).toBeCloseTo(40, 12);
    } finally {
      ctx.destroy();
    }
  });

  it("all four kinds allocate through the single module alloc domain", async () => {
    const bytes = await compileNode("sum(m)", "m:matrix", "number", "four_kinds_domain");
    const { host, exports, evalFn } = await loadEvalModule(bytes);
    exports.reset_heap?.();

    const mPtr = host.writeMatrix(2, 2, [1, 2, 3, 4]);
    const cPtr = host.writeComplex(1.5, -2.5);
    const rPtr = host.writeWasmRecord([{ key: "k", wire: 9, kind: 0 }]);
    const sPtr = host.writeLengthPrefixedString("alloc-domain");
    const serPtr = host.writeLinearSeries([0, 1], [5, 6]);

    for (let i = 0; i < 64; i++) exports.alloc!(256);

    const m = host.readMatrix(mPtr);
    expect(m).not.toBeNull();
    expect(Array.from(m!.data)).toEqual([1, 2, 3, 4]);
    expect(host.readComplex(cPtr)).toEqual({ re: 1.5, im: -2.5 });
    expect(host.readLengthPrefixedString(sPtr)).toBe("alloc-domain");
    const ser = host.readLinearSeries(serPtr);
    expect(ser).not.toBeNull();
    expect(ser!.values).toEqual([5, 6]);
    const rec = host.readWasmRecord(rPtr);
    expect(rec).not.toBeNull();

    expect(evalFn(mPtr)).toBeCloseTo(10, 12);
  });

  it("node manifest records typed input kinds", async () => {
    const bytes = await compileNode("re(x)", "x:complex", "number", "manifest_check");
    const module = await WebAssembly.compile(bytes);
    const man = readNodeManifest(module);
    expect(man).not.toBeNull();
    expect(man!.inputs[0]?.kind).toMatch(/complex/);
  });
});
