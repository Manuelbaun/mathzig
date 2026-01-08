import { describe, expect, it, beforeAll } from "bun:test";
import { mkdirSync, readFileSync, existsSync, writeFileSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { compileAot } from "../parity/wasm_aot";
import { MathZig } from "../../src/ts/mathzig";
import {
  GraphRunner,
  createDefaultScalarWasmImports,
  graphValuesEqual,
  readNodeManifest,
  type GraphDefinition,
  type GraphValue,
  type MatrixValue,
  type ComplexValue,
} from "../../src/ts/graph";
import { AotHostEnv } from "../../src/ts/aot_env";

const compiler = {
  async compile(expr: string, numParams: number): Promise<Uint8Array> {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
};

async function loadGraph(
  definition: GraphDefinition,
  opts: { host?: AotHostEnv } = {},
): Promise<GraphRunner> {
  return GraphRunner.load(definition, {
    compiler,
    env: createDefaultScalarWasmImports(),
    host: opts.host,
  });
}

/** Evaluate an expression on the Zig VM (parity baseline). */
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
  // Complex Value (tag === 1) exposes real()/imag()
  if (v.tag === 1 && typeof v.real === "function" && typeof v.imag === "function") {
    const re = (v.real as () => number)();
    const im = (v.imag as () => number)();
    (v.release as (() => void) | undefined)?.();
    return { re, im, tag: 1 as const };
  }
  // Generated Value wrapper — number path
  if (typeof v.toNumber === "function") {
    try {
      const n = (v.toNumber as () => number)();
      if (Number.isFinite(n)) {
        (v.release as (() => void) | undefined)?.();
        return n;
      }
    } catch {
      // fall through
    }
  }
  if (typeof v.real === "function" && typeof v.imag === "function") {
    const re = (v.real as () => number)();
    const im = (v.imag as () => number)();
    (v.release as (() => void) | undefined)?.();
    return { re, im, tag: 1 as const };
  }
  // Already plain {re, im} / {rows, cols, data}
  if ("re" in v && "im" in v) return { re: Number(v.re), im: Number(v.im), tag: 1 as const };
  if ("rows" in v && "cols" in v && "data" in v) return v;
  return res;
}

describe("GraphRunner scalar WASM AOT graphs", () => {
  it("evaluates a multi-node scalar chain like the equivalent single expression", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "x", type: "input" },
        { id: "y", type: "input" },
        { id: "bias", type: "const", value: 1.25 },
        { id: "doubleX", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "sum", type: "expr", expr: "x + y", inputs: ["x", "y"] },
        { id: "result", type: "expr", expr: "(x - y) / z", inputs: ["x", "y", "z"] },
      ],
      edges: [
        { from: "x.out", to: "doubleX.x" },
        { from: "doubleX.out", to: "sum.x" },
        { from: "y.out", to: "sum.y" },
        { from: "sum.out", to: "result.x" },
        { from: "bias.out", to: "result.y" },
        { from: "x.out", to: "result.z" },
      ],
      outputs: { value: "result.out" },
    });

    try {
      const inputs = { x: 3, y: 4 };
      const out = runner.run(inputs);

      expect(out.value).toBeCloseTo(((inputs.x * 2 + inputs.y) - 1.25) / inputs.x, 12);
    } finally {
      runner.dispose();
    }
  });

  it("uses edge topology, not node array order, to evaluate scalar graphs", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "timesThree", type: "expr", expr: "x * 3", inputs: ["x"] },
        { id: "plusOne", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "source", type: "input" },
      ],
      edges: [
        { from: "source.out", to: "plusOne.x" },
        { from: "plusOne.out", to: "timesThree.x" },
      ],
      outputs: { value: "timesThree.out" },
    });

    try {
      expect(runner.run({ source: 5 }).value).toBeCloseTo((5 + 1) * 3, 12);
    } finally {
      runner.dispose();
    }
  });

  it("setParam updates only the requested node parameter", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "signal", type: "input" },
        { id: "leftGain", type: "expr", expr: "x * y", inputs: ["x"], params: { y: 2 } },
        { id: "rightGain", type: "expr", expr: "x * y", inputs: ["x"], params: { y: 5 } },
      ],
      edges: [
        { from: "signal.out", to: "leftGain.x" },
        { from: "signal.out", to: "rightGain.x" },
      ],
      outputs: {
        left: "leftGain.out",
        right: "rightGain.out",
      },
    });

    try {
      expect(runner.run({ signal: 3 })).toEqual({ left: 6, right: 15 });

      runner.setParam("leftGain", "y", 4);

      expect(runner.run({ signal: 3 })).toEqual({ left: 12, right: 15 });
    } finally {
      runner.dispose();
    }
  });

  it("rejects cyclic scalar graphs at load time", async () => {
    const cyclic: GraphDefinition = {
      nodes: [
        { id: "a", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "b", type: "expr", expr: "x * 2", inputs: ["x"] },
      ],
      edges: [
        { from: "a.out", to: "b.x" },
        { from: "b.out", to: "a.x" },
      ],
      outputs: { value: "b.out" },
    };

    await expect(loadGraph(cyclic)).rejects.toThrow(/cycle/i);
  });

  it("reports the missing runtime graph input name", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "temperature", type: "input" },
        { id: "adjusted", type: "expr", expr: "x + 273.15", inputs: ["x"] },
      ],
      edges: [{ from: "temperature.out", to: "adjusted.x" }],
      outputs: { kelvin: "adjusted.out" },
    });

    try {
      expect(() => runner.run({})).toThrow(/input.*temperature|temperature.*input/i);
    } finally {
      runner.dispose();
    }
  });

  it("rejects undeclared input ports", async () => {
    const bad: GraphDefinition = {
      nodes: [
        { id: "src", type: "input" },
        { id: "gain", type: "expr", expr: "x * 2", inputs: ["x"] },
      ],
      edges: [{ from: "src.out", to: "gain.missing" }],
      outputs: { value: "gain.out" },
    };
    await expect(loadGraph(bad)).rejects.toThrow(/undeclared input port 'missing'/i);
  });

  it("setParam rejects unknown node and unknown param names", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "signal", type: "input" },
        { id: "gain", type: "expr", expr: "x * y", inputs: ["x"], params: { y: 2 } },
      ],
      edges: [{ from: "signal.out", to: "gain.x" }],
      outputs: { value: "gain.out" },
    });
    try {
      expect(() => runner.setParam("nope", "y", 1)).toThrow(/unknown graph node 'nope'/i);
      expect(() => runner.setParam("gain", "missing", 1)).toThrow(/no param 'missing'/i);
      expect(() => runner.setParam("signal", "y", 1)).toThrow(/does not have params/i);
      // Valid update still works.
      runner.setParam("gain", "y", 3);
      expect(runner.run({ signal: 4 }).value).toBeCloseTo(12, 12);
    } finally {
      runner.dispose();
    }
  });

  it("reload swaps expr behavior when ports stay compatible", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "signal", type: "input" },
        { id: "stage", type: "expr", expr: "x * y", inputs: ["x"], params: { y: 2 } },
      ],
      edges: [{ from: "signal.out", to: "stage.x" }],
      outputs: { value: "stage.out" },
    });
    try {
      expect(runner.run({ signal: 5 }).value).toBeCloseTo(10, 12);
      // Preserve params across reload: y stays 2, expr becomes x + y → 7.
      await runner.reload("stage", "x + y");
      expect(runner.run({ signal: 5 }).value).toBeCloseTo(7, 12);
      // Param store still works after reload.
      runner.setParam("stage", "y", 10);
      expect(runner.run({ signal: 5 }).value).toBeCloseTo(15, 12);
    } finally {
      runner.dispose();
    }
  });

  it("reload rejects incompatible ports and keeps the old node running", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "signal", type: "input" },
        { id: "stage", type: "expr", expr: "x * 2", inputs: ["x"] },
      ],
      edges: [{ from: "signal.out", to: "stage.x" }],
      outputs: { value: "stage.out" },
    });
    try {
      expect(runner.run({ signal: 3 }).value).toBeCloseTo(6, 12);

      // New expr returns a matrix — output kind mismatch vs number edge/output.
      await expect(runner.reload("stage", "[1, 2; 3, 4]")).rejects.toThrow(
        /incompatible ports|rejected/i,
      );

      // Graph still runs with the previous module.
      expect(runner.run({ signal: 3 }).value).toBeCloseTo(6, 12);
      expect(runner.run({ signal: 4 }).value).toBeCloseTo(8, 12);
    } finally {
      runner.dispose();
    }
  });
});

describe("GraphRunner full-Value golden property (split g→f == zig_vm composed)", () => {
  it("scalar: double then add-one", async () => {
    const composed = "(x * 2) + 1";
    const baseline = zigVmEval(composed, { x: 7 }) as number;

    const runner = await loadGraph({
      nodes: [
        { id: "x", type: "input" },
        { id: "g", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "f", type: "expr", expr: "x + 1", inputs: ["x"] },
      ],
      edges: [
        { from: "x.out", to: "g.x" },
        { from: "g.out", to: "f.x" },
      ],
      outputs: { value: "f.out" },
    });
    try {
      const out = runner.run({ x: 7 });
      expect(out.value).toBeCloseTo(baseline, 12);
      expect(out.value).toBeCloseTo(15, 12);
      // Determinism: two consecutive runs identical.
      const out2 = runner.run({ x: 7 });
      expect(graphValuesEqual(out.value as GraphValue, out2.value as GraphValue)).toBe(true);
    } finally {
      runner.dispose();
    }
  });

  it("matrix: elementwise scale then matmul", async () => {
    // composed: ([1,2;3,4] * 2) * [1,0;0,1]  ==  [2,4;6,8]
    const composed = "([1, 2; 3, 4] * 2) * [1, 0; 0, 1]";
    const baseline = zigVmEval(composed) as { rows: number; cols: number; data: Float64Array | number[] };

    const runner = await loadGraph({
      nodes: [
        {
          id: "g",
          type: "expr",
          expr: "[1, 2; 3, 4] * 2",
          outputKind: "matrix",
        },
        {
          id: "f",
          type: "expr",
          expr: "x * [1, 0; 0, 1]",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
      ],
      edges: [{ from: "g.out", to: "f.x" }],
      outputs: { value: "f.out" },
    });
    try {
      const out = runner.run({});
      const m = out.value as MatrixValue;
      expect(m.rows).toBe(2);
      expect(m.cols).toBe(2);
      expect(Array.from(m.data as ArrayLike<number>)).toEqual([2, 4, 6, 8]);
      // Match zig_vm
      expect(m.rows).toBe(baseline.rows);
      expect(m.cols).toBe(baseline.cols);
      for (let i = 0; i < 4; i++) {
        expect(Number(m.data[i])).toBeCloseTo(Number(baseline.data[i]), 12);
      }
      const out2 = runner.run({});
      expect(graphValuesEqual(out.value as GraphValue, out2.value as GraphValue)).toBe(true);
    } finally {
      runner.dispose();
    }
  });

  it("complex: scale then conjugate", async () => {
    // composed: conj((3+4i) * 2) == 6-8i
    const composed = "conj((3 + 4i) * 2)";
    const baseline = zigVmEval(composed) as { re: number; im: number };

    const runner = await loadGraph({
      nodes: [
        {
          id: "g",
          type: "expr",
          expr: "(3 + 4i) * 2",
          outputKind: "complex",
        },
        {
          id: "f",
          type: "expr",
          expr: "conj(x)",
          inputs: ["x"],
          inputKinds: ["complex"],
          outputKind: "complex",
        },
      ],
      edges: [{ from: "g.out", to: "f.x" }],
      outputs: { value: "f.out" },
    });
    try {
      const out = runner.run({});
      const c = out.value as ComplexValue;
      expect(c.re).toBeCloseTo(6, 12);
      expect(c.im).toBeCloseTo(-8, 12);
      expect(c.re).toBeCloseTo(baseline.re, 12);
      expect(c.im).toBeCloseTo(baseline.im, 12);
      const out2 = runner.run({});
      expect(graphValuesEqual(out.value as GraphValue, out2.value as GraphValue)).toBe(true);
    } finally {
      runner.dispose();
    }
  });

  it("record: build then field extract", async () => {
    // composed: {a: 10, b: 20}.a  == 10
    // Split: g produces record, f extracts .a via rec_get.
    // Expr `x.a` with x as record param.
    const composed = "{a: 10, b: 20}.a";
    const baseline = zigVmEval(composed) as number;

    const runner = await loadGraph({
      nodes: [
        {
          id: "g",
          type: "expr",
          expr: "{a: 10, b: 20}",
          outputKind: "record",
        },
        {
          id: "f",
          type: "expr",
          expr: "x.a",
          inputs: ["x"],
          inputKinds: ["record"],
          outputKind: "number",
        },
      ],
      edges: [{ from: "g.out", to: "f.x" }],
      outputs: { value: "f.out" },
    });
    try {
      const out = runner.run({});
      expect(out.value).toBeCloseTo(baseline, 12);
      expect(out.value).toBe(10);
      const out2 = runner.run({});
      expect(out2.value).toBe(10);
    } finally {
      runner.dispose();
    }
  });

  it("series: build then mean", async () => {
    // composed: mean(series([0,1,2], [10,20,30])) == 20
    const composed = "mean(series([0, 1, 2], [10, 20, 30]))";
    const baseline = zigVmEval(composed) as number;

    const host = new AotHostEnv();
    const runner = await loadGraph(
      {
        nodes: [
          {
            id: "g",
            type: "expr",
            expr: "series([0, 1, 2], [10, 20, 30])",
            outputKind: "series",
          },
          {
            id: "f",
            type: "expr",
            expr: "mean(x)",
            inputs: ["x"],
            inputKinds: ["series"],
            outputKind: "number",
          },
        ],
        edges: [{ from: "g.out", to: "f.x" }],
        outputs: { value: "f.out" },
      },
      { host },
    );
    try {
      const out = runner.run({});
      expect(out.value).toBeCloseTo(baseline, 12);
      expect(out.value).toBeCloseTo(20, 12);
      const out2 = runner.run({});
      expect(graphValuesEqual(out.value as GraphValue, out2.value as GraphValue)).toBe(true);
    } finally {
      runner.dispose();
    }
  });

  it("rejects kind-mismatched edges by name", async () => {
    const bad: GraphDefinition = {
      nodes: [
        { id: "g", type: "expr", expr: "[1, 2; 3, 4]", outputKind: "matrix" },
        {
          id: "f",
          type: "expr",
          expr: "x + 1",
          inputs: ["x"],
          inputKinds: ["number"],
          outputKind: "number",
        },
      ],
      edges: [{ from: "g.out", to: "f.x" }],
      outputs: { value: "f.out" },
    };
    await expect(loadGraph(bad)).rejects.toThrow(/kind mismatch/i);
  });
});

describe("GraphRunner runBatch lanes == run() (task-10 B4)", () => {
  it("scalar multi-node: each lane i equals run() with those inputs", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "x", type: "input" },
        { id: "y", type: "input" },
        { id: "bias", type: "const", value: 1.25 },
        { id: "doubleX", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "sum", type: "expr", expr: "x + y", inputs: ["x", "y"] },
        { id: "result", type: "expr", expr: "(x - y) / z", inputs: ["x", "y", "z"] },
      ],
      edges: [
        { from: "x.out", to: "doubleX.x" },
        { from: "doubleX.out", to: "sum.x" },
        { from: "y.out", to: "sum.y" },
        { from: "sum.out", to: "result.x" },
        { from: "bias.out", to: "result.y" },
        { from: "x.out", to: "result.z" },
      ],
      outputs: { value: "result.out" },
    });

    try {
      const n = 64;
      const xLane = new Float64Array(n);
      const yLane = new Float64Array(n);
      for (let i = 0; i < n; i++) {
        xLane[i] = 1 + i * 0.125;
        yLane[i] = 2 + i * 0.05;
      }

      const batch = runner.runBatch({ x: xLane, y: yLane }, n);
      expect(batch.value).toBeInstanceOf(Float64Array);
      expect(batch.value!.length).toBe(n);

      for (let i = 0; i < n; i++) {
        const single = runner.run({ x: xLane[i]!, y: yLane[i]! });
        expect(batch.value![i]).toBeCloseTo(single.value as number, 12);
      }

      // Zero-length batch allocates empty lanes and does not throw.
      const empty = runner.runBatch({ x: xLane, y: yLane }, 0);
      expect(empty.value!.length).toBe(0);
    } finally {
      runner.dispose();
    }
  });

  it("runBatch picks up setParam between batches", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "signal", type: "input" },
        { id: "gain", type: "expr", expr: "x * y", inputs: ["x"], params: { y: 2 } },
      ],
      edges: [{ from: "signal.out", to: "gain.x" }],
      outputs: { value: "gain.out" },
    });
    try {
      const lane = new Float64Array([1, 2, 3, 4]);
      const a = runner.runBatch({ signal: lane }, 4);
      expect(Array.from(a.value!)).toEqual([2, 4, 6, 8]);
      runner.setParam("gain", "y", 10);
      const b = runner.runBatch({ signal: lane }, 4);
      expect(Array.from(b.value!)).toEqual([10, 20, 30, 40]);
      for (let i = 0; i < 4; i++) {
        expect(b.value![i]).toBeCloseTo(runner.run({ signal: lane[i]! }).value as number, 12);
      }
    } finally {
      runner.dispose();
    }
  });

  it("mixed non-scalar intermediate, number output: batch == run", async () => {
    // g builds a matrix, f extracts a scalar (trace-like via element access path).
    // Use record → field extract so output is number but intermediate is non-scalar.
    const runner = await loadGraph({
      nodes: [
        { id: "k", type: "input" },
        {
          id: "g",
          type: "expr",
          expr: "{a: x, b: x * 2}",
          inputs: ["x"],
          inputKinds: ["number"],
          outputKind: "record",
        },
        {
          id: "f",
          type: "expr",
          expr: "x.a + x.b",
          inputs: ["x"],
          inputKinds: ["record"],
          outputKind: "number",
        },
      ],
      edges: [
        { from: "k.out", to: "g.x" },
        { from: "g.out", to: "f.x" },
      ],
      outputs: { value: "f.out" },
    });
    try {
      const n = 16;
      const kLane = new Float64Array(n);
      for (let i = 0; i < n; i++) kLane[i] = i + 0.5;
      const batch = runner.runBatch({ k: kLane }, n);
      for (let i = 0; i < n; i++) {
        const single = runner.run({ k: kLane[i]! });
        // g: {a:k, b:2k}, f: a+b = 3k
        expect(batch.value![i]).toBeCloseTo(single.value as number, 12);
        expect(batch.value![i]).toBeCloseTo(3 * kLane[i]!, 12);
      }
    } finally {
      runner.dispose();
    }
  });

  it("runBatch rejects non-number graph outputs", async () => {
    const runner = await loadGraph({
      nodes: [
        {
          id: "g",
          type: "expr",
          expr: "[1, 2; 3, 4]",
          outputKind: "matrix",
        },
      ],
      edges: [],
      outputs: { value: "g.out" },
    });
    try {
      expect(() => runner.runBatch({}, 4)).toThrow(/number-kind|non-scalar/i);
    } finally {
      runner.dispose();
    }
  });

  // ── task-19 P5: matrix / complex / series intermediate edges ──────────

  it("matrix intermediate edge: lane i of runBatch == run()", async () => {
    // k → [k,0;0,k] → sum → 2k  (number in/out, matrix mid)
    const runner = await loadGraph({
      nodes: [
        { id: "k", type: "input" },
        {
          id: "g",
          type: "expr",
          expr: "[x, 0; 0, x]",
          inputs: ["x"],
          inputKinds: ["number"],
          outputKind: "matrix",
        },
        {
          id: "f",
          type: "expr",
          expr: "sum(x)",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "number",
        },
      ],
      edges: [
        { from: "k.out", to: "g.x" },
        { from: "g.out", to: "f.x" },
      ],
      outputs: { value: "f.out" },
    });
    try {
      const n = 24;
      const kLane = new Float64Array(n);
      for (let i = 0; i < n; i++) kLane[i] = 0.25 + i * 0.5;
      const batch = runner.runBatch({ k: kLane }, n);
      for (let i = 0; i < n; i++) {
        const single = runner.run({ k: kLane[i]! });
        expect(batch.value![i]).toBeCloseTo(single.value as number, 12);
        expect(batch.value![i]).toBeCloseTo(2 * kLane[i]!, 12);
      }
    } finally {
      runner.dispose();
    }
  });

  it("complex intermediate edge: lane i of runBatch == run()", async () => {
    // Const complex producer → re extract (number out). No free number ports so
    // every lane is identical; still exercises complex edge through runBatchMixed.
    // Residual: AOT `x + 2i` / `(3+4i)*x` with params emits invalid wasm (local idx);
    // dual-input re(complex)+k hits host memory attach gap — tracked as residual.
    const runner = await loadGraph({
      nodes: [
        {
          id: "g",
          type: "expr",
          expr: "(3 + 4i) * 2",
          outputKind: "complex",
        },
        {
          id: "f",
          type: "expr",
          expr: "re(x)",
          inputs: ["x"],
          inputKinds: ["complex"],
          outputKind: "number",
        },
      ],
      edges: [{ from: "g.out", to: "f.x" }],
      outputs: { value: "f.out" },
    });
    try {
      const n = 16;
      const batch = runner.runBatch({}, n);
      for (let i = 0; i < n; i++) {
        const single = runner.run({});
        expect(batch.value![i]).toBeCloseTo(single.value as number, 12);
        expect(batch.value![i]).toBeCloseTo(6, 12);
      }
    } finally {
      runner.dispose();
    }
  });

  it("series intermediate edge: lane i of runBatch == run()", async () => {
    // k → series([0,1],[k, 2k]) → last → 2k
    const runner = await loadGraph({
      nodes: [
        { id: "k", type: "input" },
        {
          id: "g",
          type: "expr",
          expr: "series([0, 1], [x, 2 * x])",
          inputs: ["x"],
          inputKinds: ["number"],
          outputKind: "series",
        },
        {
          id: "f",
          type: "expr",
          expr: "last(x)",
          inputs: ["x"],
          inputKinds: ["series"],
          outputKind: "number",
        },
      ],
      edges: [
        { from: "k.out", to: "g.x" },
        { from: "g.out", to: "f.x" },
      ],
      outputs: { value: "f.out" },
    });
    try {
      const n = 12;
      const kLane = new Float64Array(n);
      for (let i = 0; i < n; i++) kLane[i] = 1 + i;
      const batch = runner.runBatch({ k: kLane }, n);
      for (let i = 0; i < n; i++) {
        const single = runner.run({ k: kLane[i]! });
        expect(batch.value![i]).toBeCloseTo(single.value as number, 12);
        expect(batch.value![i]).toBeCloseTo(2 * kLane[i]!, 12);
      }
    } finally {
      runner.dispose();
    }
  });
});

describe("mathzig compile --node (CLI + manifest)", () => {
  const bin = resolve("zig-out/bin/mathzig");
  const outDir = resolve("tests/artifacts/node_cli");

  beforeAll(() => {
    mkdirSync(outDir, { recursive: true });
  });

  it("emits mathzig:node custom section matching JSON sidecar", async () => {
    if (!existsSync(bin)) {
      console.warn("skip: mathzig binary not built");
      return;
    }
    const wasmPath = resolve(outDir, "gain.wasm");
    const sidecarPath = resolve(outDir, "gain.node.json");
    for (const p of [wasmPath, sidecarPath]) {
      if (existsSync(p)) unlinkSync(p);
    }

    // Expression uses a diagonal scale built from the trailing param so the
    // AOT path takes real matrix*matrix mul (fused `x * alpha` is scalar-only).
    const proc = Bun.spawn(
      [
        bin,
        "compile",
        "--node",
        "--in",
        "x:matrix",
        "--param",
        "alpha:number=0.5",
        "--out",
        "matrix",
        "-o",
        wasmPath,
        "x * [alpha, 0; 0, alpha]",
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const code = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(code).toBe(0);
    expect(existsSync(wasmPath)).toBe(true);
    expect(existsSync(sidecarPath)).toBe(true);

    const sidecar = JSON.parse(readFileSync(sidecarPath, "utf8"));
    expect(sidecar.abi).toBe(1);
    expect(sidecar.inputs).toEqual([{ name: "x", kind: "matrix" }]);
    expect(sidecar.params[0].name).toBe("alpha");
    expect(sidecar.params[0].kind).toBe("number");
    expect(sidecar.params[0].default).toBeCloseTo(0.5, 12);
    expect(sidecar.output.kind).toBe("matrix");

    const bytes = readFileSync(wasmPath);
    const module = await WebAssembly.compile(bytes);
    const section = readNodeManifest(module);
    expect(section).not.toBeNull();
    expect(section!.inputs).toEqual(sidecar.inputs);
    expect(section!.params[0].name).toBe(sidecar.params[0].name);
    expect(section!.output.kind).toBe(sidecar.output.kind);

    // force_heap: memory + alloc + reset_heap present
    const exports = WebAssembly.Module.exports(module).map((e) => e.name);
    expect(exports).toContain("memory");
    expect(exports).toContain("alloc");
    expect(exports).toContain("reset_heap");
    expect(exports).toContain("eval");

    // wasm node runs in GraphRunner
    const host = new AotHostEnv();
    const runner = await GraphRunner.load(
      {
        nodes: [
          {
            id: "src",
            type: "expr",
            expr: "[1, 2; 3, 4]",
            outputKind: "matrix",
          },
          {
            id: "gain",
            type: "wasm",
            wasm: new Uint8Array(bytes),
            manifest: section!,
            params: { alpha: 2 },
          },
        ],
        edges: [{ from: "src.out", to: "gain.x" }],
        outputs: { value: "gain.out" },
      },
      { compiler, host },
    );
    try {
      const out = runner.run({});
      const m = out.value as MatrixValue;
      expect(Array.from(m.data as ArrayLike<number>)).toEqual([2, 4, 6, 8]);
    } finally {
      runner.dispose();
    }

    // silence unused
    void stdout;
    void stderr;
  });

  it("rejects undeclared expression variables under --node", async () => {
    if (!existsSync(bin)) return;
    const wasmPath = resolve(outDir, "bad.wasm");
    const proc = Bun.spawn(
      [bin, "compile", "--node", "--in", "x:number", "--out", "number", "-o", wasmPath, "x + y"],
      { stdout: "pipe", stderr: "pipe" },
    );
    const code = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    // y is free but not declared — either compile error (y unknown after
    // variable rebuild) or validation error.
    expect(code).not.toBe(0);
    expect(stderr.length + (await new Response(proc.stdout).text()).length).toBeGreaterThan(0);
  });
});
