/**
 * Spec 04 — FusedGraphRunner host API (T1–T7).
 *
 * Goldens from `zig build emit-fuse-goldens`. Multi-module GraphRunner is the
 * value oracle; fused path is one instantiate.
 */
import { describe, expect, it, beforeAll } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { compileAot } from "../../parity/wasm_aot";
import {
  FusedGraphRunner,
  GraphRunner,
  createDefaultScalarWasmImports,
  graphValuesEqual,
  type GraphDefinition,
} from "../../../src/ts/graph";
import { compileFused } from "../../../src/ts/graph/node";

const ROOT = path.resolve(import.meta.dir, "../../..");
const FUSE_DIR = path.join(ROOT, "tests/artifacts/fuse");

const compiler = {
  async compile(expr: string, numParams: number): Promise<Uint8Array> {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
};

function ensureFixtures() {
  const needed = [
    "chain_table.wasm",
    "chain_named.wasm",
    "chain_two_named.wasm",
    "diamond_named.wasm",
    "params_named.wasm",
  ];
  const missing = needed.some((f) => !fs.existsSync(path.join(FUSE_DIR, f)));
  if (!missing) return;
  const r = spawnSync("zig", ["build", "emit-fuse-goldens"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 120_000,
  });
  if (r.status !== 0) {
    throw new Error(
      `emit-fuse-goldens failed (status ${r.status})\nstdout: ${r.stdout}\nstderr: ${r.stderr}`,
    );
  }
}

function loadBytes(name: string): Uint8Array {
  return new Uint8Array(fs.readFileSync(path.join(FUSE_DIR, name)));
}

async function loadMulti(def: GraphDefinition): Promise<GraphRunner> {
  return GraphRunner.load(def, {
    compiler,
    env: createDefaultScalarWasmImports(),
  });
}

function expectOutputsClose(
  a: Record<string, unknown>,
  b: Record<string, unknown>,
  keys: string[],
) {
  for (const k of keys) {
    expect(a[k]).toBeDefined();
    expect(b[k]).toBeDefined();
    expect(
      graphValuesEqual(a[k] as number, b[k] as number),
      `output '${k}': fused=${a[k]} multi=${b[k]}`,
    ).toBe(true);
  }
}

// Graph definitions matching Spec 03 goldens (multi-module oracle).

const chainDef: GraphDefinition = {
  nodes: [
    { id: "x", type: "input" },
    { id: "mul", type: "expr", expr: "x * 2", inputs: ["x"] },
    { id: "add", type: "expr", expr: "x + 1", inputs: ["x"] },
  ],
  edges: [
    { from: "x.out", to: "mul.x" },
    { from: "mul.out", to: "add.x" },
  ],
  outputs: { y: "add.out" },
};

const chainTwoDef: GraphDefinition = {
  nodes: [
    { id: "x", type: "input" },
    { id: "mul", type: "expr", expr: "x * 2", inputs: ["x"] },
    { id: "add", type: "expr", expr: "x + 1", inputs: ["x"] },
  ],
  edges: [
    { from: "x.out", to: "mul.x" },
    { from: "mul.out", to: "add.x" },
  ],
  outputs: { mid: "mul.out", end: "add.out" },
};

const diamondDef: GraphDefinition = {
  nodes: [
    { id: "x", type: "input" },
    { id: "A", type: "expr", expr: "x * 2", inputs: ["x"] },
    { id: "B", type: "expr", expr: "x + 1", inputs: ["x"] },
    { id: "C", type: "expr", expr: "x * 3", inputs: ["x"] },
  ],
  edges: [
    { from: "x.out", to: "A.x" },
    { from: "A.out", to: "B.x" },
    { from: "A.out", to: "C.x" },
  ],
  outputs: { u: "B.out", v: "C.out" },
};

const paramsDef: GraphDefinition = {
  nodes: [
    { id: "x", type: "input" },
    { id: "gain", type: "expr", expr: "x * k", inputs: ["x"], params: { k: 1 } },
  ],
  edges: [{ from: "x.out", to: "gain.x" }],
  outputs: { y: "gain.out" },
};

describe("FusedGraphRunner (Spec 04)", () => {
  beforeAll(() => {
    ensureFixtures();
  });

  // T1 — 3-node scalar chain (input + mul + add), 1 out
  it("T1: chain named — fused ≡ multi", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("chain_named.wasm"));
    const multi = await loadMulti(chainDef);
    try {
      const inputs = { x: 3 };
      const fo = fused.run(inputs);
      const mo = multi.run(inputs);
      expect(Object.keys(fo).sort()).toEqual(["y"]);
      expectOutputsClose(fo, mo, ["y"]);
      expect(fo.y).toBeCloseTo(7, 12);
    } finally {
      fused.dispose();
      multi.dispose();
    }
  });

  it("T1b: chain table — fused ≡ multi", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("chain_table.wasm"));
    const multi = await loadMulti(chainDef);
    try {
      const fo = fused.run({ x: 3 });
      const mo = multi.run({ x: 3 });
      expectOutputsClose(fo, mo, ["y"]);
    } finally {
      fused.dispose();
      multi.dispose();
    }
  });

  // T2 — 2 outs from chain mid + end
  it("T2: chain mid+end — both keys; fused ≡ multi", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("chain_two_named.wasm"));
    const multi = await loadMulti(chainTwoDef);
    try {
      const fo = fused.run({ x: 3 });
      const mo = multi.run({ x: 3 });
      expect(Object.keys(fo).sort()).toEqual(["end", "mid"]);
      expectOutputsClose(fo, mo, ["mid", "end"]);
      expect(fo.mid).toBeCloseTo(6, 12);
      expect(fo.end).toBeCloseTo(7, 12);
    } finally {
      fused.dispose();
      multi.dispose();
    }
  });

  // T3 — diamond shared node
  it("T3: diamond — fused ≡ multi", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("diamond_named.wasm"));
    const multi = await loadMulti(diamondDef);
    try {
      const fo = fused.run({ x: 3 });
      const mo = multi.run({ x: 3 });
      expectOutputsClose(fo, mo, ["u", "v"]);
      expect(fo.u).toBeCloseTo(7, 12);
      expect(fo.v).toBeCloseTo(18, 12);
    } finally {
      fused.dispose();
      multi.dispose();
    }
  });

  // T4 — params: setParam then run matches multi setParam
  it("T4: setParam then run matches multi", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("params_named.wasm"));
    const multi = await loadMulti(paramsDef);
    try {
      expect(fused.run({ x: 3 }).y).toBeCloseTo(3, 12); // default k=1
      expect(multi.run({ x: 3 }).y).toBeCloseTo(3, 12);

      fused.setParam("gain.k", 2);
      multi.setParam("gain", "k", 2);
      expectOutputsClose(fused.run({ x: 3 }), multi.run({ x: 3 }), ["y"]);
      expect(fused.run({ x: 3 }).y).toBeCloseTo(6, 12);

      fused.setParam("gain.k", 5);
      multi.setParam("gain", "k", 5);
      expectOutputsClose(fused.run({ x: 3 }), multi.run({ x: 3 }), ["y"]);
      expect(fused.run({ x: 3 }).y).toBeCloseTo(15, 12);

      // Per-run override does not stick
      expect(fused.run({ x: 3 }, { "gain.k": 4 }).y).toBeCloseTo(12, 12);
      expect(fused.run({ x: 3 }).y).toBeCloseTo(15, 12);
    } finally {
      fused.dispose();
      multi.dispose();
    }
  });

  // T5 — missing input
  it("T5: missing input throws with input name", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("chain_named.wasm"));
    try {
      expect(() => fused.run({})).toThrow(/input.*'x'|Missing graph input 'x'/i);
    } finally {
      fused.dispose();
    }
  });

  // T6 — module without mathzig:graph
  it("T6: module without mathzig:graph — load throws", async () => {
    // Minimal valid wasm module (empty) has no custom section.
    const emptyModule = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d, // magic
      0x01, 0x00, 0x00, 0x00, // version
    ]);
    await expect(FusedGraphRunner.load(emptyModule)).rejects.toThrow(
      /not a fused graph module|mathzig:graph/i,
    );

    // Single-expr AOT also lacks mathzig:graph
    const { wasmBytes } = await compileAot("x + 1", 1);
    await expect(FusedGraphRunner.load(wasmBytes)).rejects.toThrow(
      /not a fused graph module|mathzig:graph/i,
    );
  });

  // T7 — pure scalar: no Full-Value host required
  it("T7: pure scalar loads without AotHostEnv", async () => {
    // Explicit empty options — no host.
    const fused = await FusedGraphRunner.load(loadBytes("chain_named.wasm"), {});
    try {
      expect(fused.manifest.out_mode).toBe("named_exports");
      expect(fused.run({ x: 10 }).y).toBeCloseTo(21, 12);
    } finally {
      fused.dispose();
    }
  });

  // Determinism: two runs same inputs → bit-identical scalars
  it("determinism: two runs → bit-identical scalars", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("diamond_named.wasm"));
    try {
      const a = fused.run({ x: 3 });
      const b = fused.run({ x: 3 });
      expect(Object.is(a.u, b.u)).toBe(true);
      expect(Object.is(a.v, b.v)).toBe(true);
      // table path too
    } finally {
      fused.dispose();
    }

    const table = await FusedGraphRunner.load(loadBytes("chain_table.wasm"));
    try {
      const a = table.run({ x: 3 });
      const b = table.run({ x: 3 });
      expect(Object.is(a.y, b.y)).toBe(true);
    } finally {
      table.dispose();
    }
  });

  it("compileFused matches known chain golden", async () => {
    const bytes = await compileFused(chainDef, compiler, { outMode: "named_exports" });
    const fused = await FusedGraphRunner.load(bytes);
    try {
      expect(fused.run({ x: 3 }).y).toBeCloseTo(7, 12);
    } finally {
      fused.dispose();
    }
  });

  // Spec 05: compileFused shells to compile-graph — arbitrary scalar graphs work.
  it("compileFused compiles lookalike graph with different exprs via CLI", async () => {
    const lookalike: GraphDefinition = {
      nodes: [
        { id: "x", type: "input" },
        { id: "mul", type: "expr", expr: "x * 99", inputs: ["x"] },
        { id: "add", type: "expr", expr: "x + 99", inputs: ["x"] },
      ],
      edges: [
        { from: "x.out", to: "mul.x" },
        { from: "mul.out", to: "add.x" },
      ],
      outputs: { y: "add.out" },
    };
    const bytes = await compileFused(lookalike, compiler, { outMode: "named_exports" });
    const fused = await FusedGraphRunner.load(bytes, {
      env: createDefaultScalarWasmImports(),
    });
    try {
      // (3 * 99) + 99 = 396
      expect(fused.run({ x: 3 }).y).toBeCloseTo(396, 12);
    } finally {
      fused.dispose();
    }
  });

  it("compileFused compiles diamond lookalike with different exprs via CLI", async () => {
    const lookalike: GraphDefinition = {
      nodes: [
        { id: "x", type: "input" },
        { id: "A", type: "expr", expr: "x * 99", inputs: ["x"] },
        { id: "B", type: "expr", expr: "x + 99", inputs: ["x"] },
        { id: "C", type: "expr", expr: "x * 99", inputs: ["x"] },
      ],
      edges: [
        { from: "x.out", to: "A.x" },
        { from: "A.out", to: "B.x" },
        { from: "A.out", to: "C.x" },
      ],
      outputs: { u: "B.out", v: "C.out" },
    };
    const bytes = await compileFused(lookalike, compiler);
    const fused = await FusedGraphRunner.load(bytes, {
      env: createDefaultScalarWasmImports(),
    });
    try {
      const out = fused.run({ x: 1 });
      // A=99, B=99+99=198, C=99*99=9801
      expect(out.u).toBeCloseTo(198, 12);
      expect(out.v).toBeCloseTo(9801, 12);
    } finally {
      fused.dispose();
    }
  });

  it("compileFused compiles unrelated graph shape via CLI", async () => {
    const unrelated: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "n", type: "expr", expr: "sin(x)", inputs: ["x"] },
      ],
      edges: [{ from: "in.out", to: "n.x" }],
      outputs: { value: "n.out" },
    };
    const bytes = await compileFused(unrelated, compiler);
    const fused = await FusedGraphRunner.load(bytes, {
      env: createDefaultScalarWasmImports(),
    });
    try {
      expect(fused.run({ in: Math.PI / 2 }).value as number).toBeCloseTo(1, 10);
    } finally {
      fused.dispose();
    }
  });

  it("paramOverrides unknown key throws", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("params_named.wasm"));
    try {
      expect(() => fused.run({ x: 3 }, { "gain.nope": 2 })).toThrow(
        /no param 'gain\.nope'|paramOverrides/i,
      );
    } finally {
      fused.dispose();
    }
  });

  it("does not drop silent outputs — all manifest outputs present", async () => {
    const fused = await FusedGraphRunner.load(loadBytes("diamond_named.wasm"));
    try {
      const out = fused.run({ x: 1 });
      expect(Object.keys(out).sort()).toEqual(
        fused.manifest.outputs.map((o) => o.name).sort(),
      );
    } finally {
      fused.dispose();
    }
  });
});
