/**
 * Graph DSL sugar: lowering + structural equivalence vs JSON GraphDefinitions,
 * plus runtime equivalence through GraphRunner (same execution path).
 */
import { describe, expect, it } from "bun:test";
import { compileAot } from "../parity/wasm_aot";
import {
  GraphRunner,
  canonicalizeGraphDefinition,
  createDefaultScalarWasmImports,
  dslToGraphDefinition,
  parseGraphDsl,
  DslError,
  type GraphDefinition,
  type GraphValue,
  type MatrixValue,
  type ComplexValue,
} from "../../src/ts/graph";
import { MathZig } from "../../src/ts/mathzig";
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
    return { re, im, tag: 1 as const };
  }
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
  if ("re" in v && "im" in v) return { re: Number(v.re), im: Number(v.im), tag: 1 as const };
  if ("rows" in v && "cols" in v && "data" in v) return v;
  return res;
}

function expectDefsEquivalent(dsl: GraphDefinition, json: GraphDefinition) {
  expect(canonicalizeGraphDefinition(dsl)).toEqual(canonicalizeGraphDefinition(json));
}

// ---------------------------------------------------------------------------
// Table-driven: DSL string ⇔ hand-written GraphDefinition (structure)
// ---------------------------------------------------------------------------

type EquivCase = {
  name: string;
  dsl: string;
  json: GraphDefinition;
};

const EQUIV_CASES: EquivCase[] = [
  {
    name: "single expr with free inputs",
    dsl: `graph {
      result = x * 2 + y;
    }`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "y", type: "input", name: "y" },
        { id: "result", type: "expr", expr: "x * 2 + y", inputs: ["x", "y"], inputKinds: ["number", "number"] },
      ],
      edges: [
        { from: "x.out", to: "result.x" },
        { from: "y.out", to: "result.y" },
      ],
      outputs: { result: "result.out" },
    },
  },
  {
    name: "multi-node chain with const literal",
    dsl: `graph {
      bias = 1.25;
      doubleX = x * 2;
      sum = doubleX + y;
      result = (sum - bias) / x;
    }`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "y", type: "input", name: "y" },
        { id: "bias", type: "const", value: 1.25 },
        {
          id: "doubleX",
          type: "expr",
          expr: "x * 2",
          inputs: ["x"],
          inputKinds: ["number"],
        },
        {
          id: "sum",
          type: "expr",
          expr: "doubleX + y",
          inputs: ["doubleX", "y"],
          inputKinds: ["number", "number"],
        },
        {
          id: "result",
          type: "expr",
          expr: "(sum - bias) / x",
          inputs: ["sum", "bias", "x"],
          inputKinds: ["number", "number", "number"],
        },
      ],
      edges: [
        { from: "x.out", to: "doubleX.x" },
        { from: "doubleX.out", to: "sum.doubleX" },
        { from: "y.out", to: "sum.y" },
        { from: "sum.out", to: "result.sum" },
        { from: "bias.out", to: "result.bias" },
        { from: "x.out", to: "result.x" },
      ],
      outputs: { result: "result.out" },
    },
  },
  {
    name: "param declaration attaches to consumer",
    dsl: `graph {
      param gain = 2;
      y = gain * x;
    }`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        {
          id: "y",
          type: "expr",
          expr: "gain * x",
          inputs: ["x"],
          inputKinds: ["number"],
          params: { gain: 2 },
        },
      ],
      edges: [{ from: "x.out", to: "y.x" }],
      outputs: { y: "y.out" },
    },
  },
  {
    name: "explicit out overrides last assignment",
    dsl: `graph {
      a = x + 1;
      b = a * 2;
      out a;
    }`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "a", type: "expr", expr: "x + 1", inputs: ["x"], inputKinds: ["number"] },
        { id: "b", type: "expr", expr: "a * 2", inputs: ["a"], inputKinds: ["number"] },
      ],
      edges: [
        { from: "x.out", to: "a.x" },
        { from: "a.out", to: "b.a" },
      ],
      outputs: { a: "a.out" },
    },
  },
  {
    name: "function call becomes expr node",
    dsl: `graph {
      a = sin(x);
      y = a * 2;
    }`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "a", type: "expr", expr: "sin(x)", inputs: ["x"], inputKinds: ["number"] },
        { id: "y", type: "expr", expr: "a * 2", inputs: ["a"], inputKinds: ["number"] },
      ],
      edges: [
        { from: "x.out", to: "a.x" },
        { from: "a.out", to: "y.a" },
      ],
      outputs: { y: "y.out" },
    },
  },
  {
    name: "typed assignment for matrix",
    dsl: `graph {
      g: matrix = [1, 2; 3, 4] * 2;
      f: matrix = g * [1, 0; 0, 1];
    }`,
    json: {
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
          expr: "g * [1, 0; 0, 1]",
          inputs: ["g"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
      ],
      edges: [{ from: "g.out", to: "f.g" }],
      outputs: { f: "f.out" },
    },
  },
  {
    name: "explicit input with kind",
    dsl: `graph {
      input signal: number;
      param scale = 3;
      outv = signal * scale;
    }`,
    json: {
      nodes: [
        { id: "signal", type: "input", name: "signal", kind: "number" },
        {
          id: "outv",
          type: "expr",
          expr: "signal * scale",
          inputs: ["signal"],
          inputKinds: ["number"],
          params: { scale: 3 },
        },
      ],
      edges: [{ from: "signal.out", to: "outv.signal" }],
      outputs: { outv: "outv.out" },
    },
  },
  {
    name: "const keyword",
    dsl: `graph {
      const bias = 10;
      y = x + bias;
    }`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "bias", type: "const", value: 10 },
        {
          id: "y",
          type: "expr",
          expr: "x + bias",
          inputs: ["x", "bias"],
          inputKinds: ["number", "number"],
        },
      ],
      edges: [
        { from: "x.out", to: "y.x" },
        { from: "bias.out", to: "y.bias" },
      ],
      outputs: { y: "y.out" },
    },
  },
  {
    name: "bare statements without graph wrapper",
    dsl: `y = x + 1;`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "y", type: "expr", expr: "x + 1", inputs: ["x"], inputKinds: ["number"] },
      ],
      edges: [{ from: "x.out", to: "y.x" }],
      outputs: { y: "y.out" },
    },
  },
  {
    name: "multiple outs",
    dsl: `graph {
      left = x * 2;
      right = x + 1;
      out left, right;
    }`,
    json: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "left", type: "expr", expr: "x * 2", inputs: ["x"], inputKinds: ["number"] },
        { id: "right", type: "expr", expr: "x + 1", inputs: ["x"], inputKinds: ["number"] },
      ],
      edges: [
        { from: "x.out", to: "left.x" },
        { from: "x.out", to: "right.x" },
      ],
      outputs: { left: "left.out", right: "right.out" },
    },
  },
];

describe("Graph DSL → GraphDefinition structural equivalence", () => {
  for (const c of EQUIV_CASES) {
    it(c.name, () => {
      const lowered = dslToGraphDefinition(c.dsl);
      expectDefsEquivalent(lowered, c.json);
    });
  }
});

// ---------------------------------------------------------------------------
// Runtime: DSL-loaded graphs match JSON-loaded graphs and zig_vm baselines
// ---------------------------------------------------------------------------

describe("Graph DSL runtime equivalence via GraphRunner", () => {
  it("multi-node scalar chain matches JSON and composed expr", async () => {
    const dsl = `
      graph {
        bias = 1.25;
        doubleX = x * 2;
        sum = doubleX + y;
        result = (sum - bias) / x;
      }
    `;
    const json: GraphDefinition = {
      nodes: [
        { id: "x", type: "input" },
        { id: "y", type: "input" },
        { id: "bias", type: "const", value: 1.25 },
        { id: "doubleX", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "sum", type: "expr", expr: "doubleX + y", inputs: ["doubleX", "y"] },
        { id: "result", type: "expr", expr: "(sum - bias) / x", inputs: ["sum", "bias", "x"] },
      ],
      edges: [
        { from: "x.out", to: "doubleX.x" },
        { from: "doubleX.out", to: "sum.doubleX" },
        { from: "y.out", to: "sum.y" },
        { from: "sum.out", to: "result.sum" },
        { from: "bias.out", to: "result.bias" },
        { from: "x.out", to: "result.x" },
      ],
      outputs: { result: "result.out" },
    };

    const fromDsl = await loadGraph(dslToGraphDefinition(dsl));
    const fromJson = await loadGraph(json);
    try {
      const inputs = { x: 3, y: 4 };
      const expected = ((inputs.x * 2 + inputs.y) - 1.25) / inputs.x;
      expect(fromDsl.run(inputs).result).toBeCloseTo(expected, 12);
      expect(fromJson.run(inputs).result).toBeCloseTo(expected, 12);
      expect(fromDsl.run(inputs).result).toBeCloseTo(fromJson.run(inputs).result as number, 12);
    } finally {
      fromDsl.dispose();
      fromJson.dispose();
    }
  });

  it("param setParam works on DSL-lowered graph", async () => {
    const def = dslToGraphDefinition(`
      graph {
        param gain = 2;
        y = x * gain;
      }
    `);
    const runner = await loadGraph(def);
    try {
      expect(runner.run({ x: 5 }).y).toBeCloseTo(10, 12);
      runner.setParam("y", "gain", 3);
      expect(runner.run({ x: 5 }).y).toBeCloseTo(15, 12);
    } finally {
      runner.dispose();
    }
  });

  it("edge topology from DSL (forward refs + explicit out)", async () => {
    // Assignments may reference later nodes; evaluation follows edges (topo),
    // not statement order. Explicit `out` selects the graph output.
    const def = dslToGraphDefinition(`
      graph {
        timesThree = plusOne * 3;
        plusOne = source + 1;
        out timesThree;
      }
    `);
    const runner = await loadGraph(def);
    try {
      expect(runner.run({ source: 5 }).timesThree).toBeCloseTo((5 + 1) * 3, 12);
    } finally {
      runner.dispose();
    }
  });

  it("scalar golden: DSL split g→f == zig_vm composed", async () => {
    const composed = "(x * 2) + 1";
    const baseline = zigVmEval(composed, { x: 7 }) as number;
    const def = dslToGraphDefinition(`
      graph {
        g = x * 2;
        f = g + 1;
      }
    `);
    const runner = await loadGraph(def);
    try {
      const out = runner.run({ x: 7 });
      expect(out.f).toBeCloseTo(baseline, 12);
      expect(out.f).toBeCloseTo(15, 12);
    } finally {
      runner.dispose();
    }
  });

  it("matrix golden via DSL kind annotations", async () => {
    const composed = "([1, 2; 3, 4] * 2) * [1, 0; 0, 1]";
    const baseline = zigVmEval(composed) as {
      rows: number;
      cols: number;
      data: Float64Array | number[];
    };
    const def = dslToGraphDefinition(`
      graph {
        g: matrix = [1, 2; 3, 4] * 2;
        f: matrix = g * [1, 0; 0, 1];
      }
    `);

    const runner = await loadGraph(def);
    try {
      const out = runner.run({});
      const m = out.f as MatrixValue;
      expect(m.rows).toBe(2);
      expect(m.cols).toBe(2);
      expect(Array.from(m.data as ArrayLike<number>)).toEqual([2, 4, 6, 8]);
      for (let i = 0; i < 4; i++) {
        expect(Number(m.data[i])).toBeCloseTo(Number(baseline.data[i]), 12);
      }
    } finally {
      runner.dispose();
    }
  });

  it("complex golden via DSL", async () => {
    const composed = "conj((3 + 4i) * 2)";
    const baseline = zigVmEval(composed) as { re: number; im: number };
    const def = dslToGraphDefinition(`
      graph {
        g: complex = (3 + 4i) * 2;
        f: complex = conj(g);
      }
    `);
    const runner = await loadGraph(def);
    try {
      const c = runner.run({}).f as ComplexValue;
      expect(c.re).toBeCloseTo(6, 12);
      expect(c.im).toBeCloseTo(-8, 12);
      expect(c.re).toBeCloseTo(baseline.re, 12);
      expect(c.im).toBeCloseTo(baseline.im, 12);
    } finally {
      runner.dispose();
    }
  });
});

// ---------------------------------------------------------------------------
// Errors with line/col
// ---------------------------------------------------------------------------

describe("Graph DSL error positions", () => {
  it("reports line/col for unexpected character", () => {
    try {
      parseGraphDsl("graph {\n  a = x $ 1;\n}");
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      const err = e as DslError;
      expect(err.line).toBe(2);
      expect(err.col).toBeGreaterThan(0);
      expect(err.message).toMatch(/line 2/);
    }
  });

  it("reports missing semicolon", () => {
    try {
      parseGraphDsl("graph { a = x + 1 }");
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      const err = e as DslError;
      expect(err.message).toMatch(/;/);
      expect(err.line).toBeGreaterThanOrEqual(1);
    }
  });

  it("reports duplicate name", () => {
    try {
      parseGraphDsl(`graph {
        a = x + 1;
        a = x * 2;
      }`);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      expect((e as DslError).message).toMatch(/Duplicate name 'a'/);
    }
  });

  it("reports undefined output", () => {
    try {
      parseGraphDsl(`graph {
        a = x + 1;
        out missing;
      }`);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      expect((e as DslError).message).toMatch(/Output 'missing'/);
    }
  });

  it("reports self-reference", () => {
    try {
      parseGraphDsl(`graph { a = a + 1; }`);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      expect((e as DslError).message).toMatch(/cannot reference itself/);
    }
  });

  it("reports unknown port kind", () => {
    try {
      parseGraphDsl(`graph { a: widget = x; }`);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      expect((e as DslError).message).toMatch(/Unknown port kind 'widget'/);
    }
  });

  it("reports unterminated string", () => {
    try {
      parseGraphDsl(`graph {\n  const s = "oops;\n}`);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      expect((e as DslError).message).toMatch(/Unterminated string/);
    }
  });
});

// ---------------------------------------------------------------------------
// parseGraphDsl metadata
// ---------------------------------------------------------------------------

describe("parseGraphDsl metadata", () => {
  it("returns inputNames, outputNames, params", () => {
    const r = parseGraphDsl(`
      graph {
        param gain = 0.5;
        param bias = 1;
        a = lowpass(x);
        y = gain * a + bias;
        out y;
      }
    `);
    expect(r.params).toEqual({ gain: 0.5, bias: 1 });
    expect(r.inputNames).toEqual(["x"]);
    expect(r.outputNames).toEqual(["y"]);
    expect(r.definition.outputs).toEqual({ y: "y.out" });
  });
});
