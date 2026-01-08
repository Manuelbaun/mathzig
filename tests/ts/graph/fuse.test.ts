/**
 * Spec 02 — Graph lowerer (FusePlan) unit tests T1–T8 + review hardening cases.
 */
import { describe, expect, it } from "bun:test";
import {
  FUSE_ERR,
  FuseError,
  lowerGraphToFusePlan,
  type GraphDefinition,
} from "../../../src/ts/graph";

describe("lowerGraphToFusePlan", () => {
  // T1 — Linear chain 3 expr, one output
  it("T1: linear chain of 3 expr nodes → 3 nodes topo order, 1 output", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "a", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "b", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "c", type: "expr", expr: "x / 2", inputs: ["x"] },
      ],
      edges: [
        { from: "in.out", to: "a.x" },
        { from: "a.out", to: "b.x" },
        { from: "b.out", to: "c.x" },
      ],
      outputs: { value: "c.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.nodes.map((n) => n.id)).toEqual(["a", "b", "c"]);
    expect(plan.outputs).toHaveLength(1);
    expect(plan.outputs[0]).toEqual({ name: "value", fromNodeId: "c", kind: "number" });
    expect(plan.inputs).toHaveLength(1);
    expect(plan.inputs[0]!.sourceNodeId).toBe("in");
    expect(plan.nodes[0]!.inputPorts).toEqual(["in"]);
    expect(plan.nodes[1]!.inputPorts).toEqual(["a"]);
    expect(plan.nodes[2]!.inputPorts).toEqual(["b"]);
    // Default inputKinds are number
    expect(plan.nodes[0]!.inputKinds).toEqual(["number"]);
  });

  // T2 — Diamond: A→B, A→C, outputs B and C; A once
  it("T2: diamond shares intermediate A once in nodes", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "A", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "B", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "C", type: "expr", expr: "x - 1", inputs: ["x"] },
      ],
      edges: [
        { from: "in.out", to: "A.x" },
        { from: "A.out", to: "B.x" },
        { from: "A.out", to: "C.x" },
      ],
      outputs: { left: "B.out", right: "C.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.nodes.filter((n) => n.id === "A")).toHaveLength(1);
    expect(plan.nodes.map((n) => n.id).sort()).toEqual(["A", "B", "C"]);
    // A before B and C in topo
    const ids = plan.nodes.map((n) => n.id);
    expect(ids.indexOf("A")).toBeLessThan(ids.indexOf("B"));
    expect(ids.indexOf("A")).toBeLessThan(ids.indexOf("C"));
    expect(plan.outputs).toHaveLength(2);
  });

  // T3 — Unused expr node dropped
  it("T3: unused expr node is absent from plan.nodes", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "used", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "dead", type: "expr", expr: "x * 99", inputs: ["x"] },
      ],
      edges: [
        { from: "in.out", to: "used.x" },
        { from: "in.out", to: "dead.x" },
      ],
      outputs: { value: "used.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.nodes.map((n) => n.id)).toEqual(["used"]);
    expect(plan.nodes.find((n) => n.id === "dead")).toBeUndefined();
  });

  // T4 — Multi outputs preserve names
  it("T4: multi outputs preserve names and length", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "a", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "b", type: "expr", expr: "x + 3", inputs: ["x"] },
      ],
      edges: [
        { from: "in.out", to: "a.x" },
        { from: "in.out", to: "b.x" },
      ],
      outputs: { u: "a.out", v: "b.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.outputs).toHaveLength(2);
    expect(plan.outputs.map((o) => o.name).sort()).toEqual(["u", "v"]);
    expect(plan.outputs.find((o) => o.name === "u")!.fromNodeId).toBe("a");
    expect(plan.outputs.find((o) => o.name === "v")!.fromNodeId).toBe("b");
  });

  // T5 — Flattened unique param names + order
  it("T5: two nodes with param k → flattened unique nodeId.param names in topo order", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        // Declare right before left in array; edges still force left-then-right? Both depend only on in.
        // Topo among them follows node array order when indegree equal (queue seed order).
        { id: "left", type: "expr", expr: "x * k", inputs: ["x"], params: { k: 2 } },
        { id: "right", type: "expr", expr: "x * k", inputs: ["x"], params: { k: 5 } },
      ],
      edges: [
        { from: "in.out", to: "left.x" },
        { from: "in.out", to: "right.x" },
      ],
      outputs: { l: "left.out", r: "right.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    const names = plan.params.map((p) => p.name);
    expect(names).toEqual(["left.k", "right.k"]);
    expect(new Set(names).size).toBe(names.length);
    expect(plan.params.find((p) => p.name === "left.k")!.default).toBe(2);
    expect(plan.params.find((p) => p.name === "right.k")!.default).toBe(5);
    // Expr keeps real param name `k` (boundary policy: real_names)
    expect(plan.nodes.find((n) => n.id === "left")!.expr).toBe("x * k");
    expect(plan.boundaryPolicy).toBe("real_names");
  });

  // T6 — wasm node only → FuseError
  it("T6: wasm node throws FuseError", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        {
          id: "opaque",
          type: "wasm",
          wasm: new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
          manifest: {
            inputs: [{ name: "x", kind: "number" }],
            params: [],
            output: { kind: "number", result_tag: "number" },
          },
        },
      ],
      edges: [{ from: "in.out", to: "opaque.x" }],
      outputs: { value: "opaque.out" },
    };

    expect(() => lowerGraphToFusePlan(def)).toThrow(FuseError);
    try {
      lowerGraphToFusePlan(def);
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.wasmUnsupported);
      expect((e as Error).message).toContain("Replace with an expr node");
    }
  });

  // T7 — Missing edge for required input
  it("T7: missing edge for required input throws", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "sum", type: "expr", expr: "x + y", inputs: ["x", "y"] },
      ],
      edges: [
        // only x connected; y missing
        { from: "in.out", to: "sum.x" },
      ],
      outputs: { value: "sum.out" },
    };

    expect(() => lowerGraphToFusePlan(def)).toThrow(FuseError);
    try {
      lowerGraphToFusePlan(def);
    } catch (e) {
      expect((e as Error).message).toContain(FUSE_ERR.missingInputEdge);
      expect((e as Error).message).toContain("y");
    }
  });

  // T8 — Cycle
  it("T8: cycle throws (topo)", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "a", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "b", type: "expr", expr: "x + 1", inputs: ["x"] },
      ],
      edges: [
        { from: "a.out", to: "b.x" },
        { from: "b.out", to: "a.x" },
      ],
      outputs: { value: "a.out" },
    };

    expect(() => lowerGraphToFusePlan(def)).toThrow(FuseError);
    try {
      lowerGraphToFusePlan(def);
    } catch (e) {
      expect((e as Error).message).toContain(FUSE_ERR.cycle);
    }
  });

  // Boundary policy: real names preserved (not rewritten to x,y,z)
  it("boundary policy: keeps real port names in expr (no x,y,z rewrite)", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "signal", type: "input" },
        {
          id: "gain",
          type: "expr",
          expr: "signal * k",
          inputs: ["signal"],
          params: { k: 1.5 },
        },
      ],
      edges: [{ from: "signal.out", to: "gain.signal" }],
      outputs: { out: "gain.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.boundaryPolicy).toBe("real_names");
    expect(plan.nodes[0]!.expr).toBe("signal * k");
    // Must not have been rewritten to positional x/y
    expect(plan.nodes[0]!.expr).not.toBe("x * y");
    expect(plan.nodes[0]!.inputs).toEqual(["signal"]);
    expect(plan.nodes[0]!.paramNames).toEqual(["k"]);
    expect(plan.params[0]!.name).toBe("gain.k");
  });

  it("drops unreachable const and input; keeps reachable const", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "unusedIn", type: "input" },
        { id: "bias", type: "const", value: 1.25 },
        { id: "deadConst", type: "const", value: 99 },
        { id: "sum", type: "expr", expr: "x + y", inputs: ["x", "y"] },
      ],
      edges: [
        { from: "in.out", to: "sum.x" },
        { from: "bias.out", to: "sum.y" },
      ],
      outputs: { value: "sum.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.inputs.map((i) => i.sourceNodeId)).toEqual(["in"]);
    expect(plan.consts.map((c) => c.id)).toEqual(["bias"]);
    expect(plan.consts[0]!.value).toBe(1.25);
    expect(plan.nodes[0]!.inputPorts).toEqual(["in", "bias"]);
  });

  it("errors when output ref points at missing node", () => {
    const def: GraphDefinition = {
      nodes: [{ id: "a", type: "expr", expr: "1", inputs: [] }],
      edges: [],
      outputs: { value: "ghost.out" },
    };
    expect(() => lowerGraphToFusePlan(def)).toThrow(FuseError);
    try {
      lowerGraphToFusePlan(def);
    } catch (e) {
      expect((e as Error).message).toContain(FUSE_ERR.missingOutputNode);
    }
  });

  // ── Review follow-ups ────────────────────────────────────────────────────

  it("silently drops unreachable wasm (no error)", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "used", type: "expr", expr: "x + 1", inputs: ["x"] },
        {
          id: "deadWasm",
          type: "wasm",
          wasm: new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
          manifest: {
            inputs: [{ name: "x", kind: "number" }],
            params: [],
            output: { kind: "number" },
          },
        },
      ],
      edges: [
        { from: "in.out", to: "used.x" },
        { from: "in.out", to: "deadWasm.x" },
      ],
      outputs: { value: "used.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.nodes.map((n) => n.id)).toEqual(["used"]);
  });

  it("multi-param single node preserves Object.keys order in flat params", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        {
          id: "f",
          type: "expr",
          expr: "x * a + b",
          inputs: ["x"],
          params: { a: 2, b: 3 },
        },
      ],
      edges: [{ from: "in.out", to: "f.x" }],
      outputs: { value: "f.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.params.map((p) => p.name)).toEqual(["f.a", "f.b"]);
    expect(plan.nodes[0]!.paramNames).toEqual(["a", "b"]);
  });

  it("same node referenced by two outputs", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "double", type: "expr", expr: "x * 2", inputs: ["x"] },
      ],
      edges: [{ from: "in.out", to: "double.x" }],
      outputs: { u: "double.out", v: "double.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.nodes).toHaveLength(1);
    expect(plan.outputs).toHaveLength(2);
    expect(plan.outputs.every((o) => o.fromNodeId === "double")).toBe(true);
    expect(plan.outputs.map((o) => o.name).sort()).toEqual(["u", "v"]);
  });

  it("preserves explicit inputKinds on plan nodes", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "m", type: "input", kind: "matrix" },
        {
          id: "scale",
          type: "expr",
          expr: "x",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
      ],
      edges: [{ from: "m.out", to: "scale.x" }],
      outputs: { out: "scale.out" },
    };

    const plan = lowerGraphToFusePlan(def);
    expect(plan.nodes[0]!.inputKinds).toEqual(["matrix"]);
    expect(plan.nodes[0]!.outputKind).toBe("matrix");
    expect(plan.inputs[0]!.kind).toBe("matrix");
  });

  it("rejects undeclared input port with stable FUSE_ERR", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        { id: "n", type: "expr", expr: "x", inputs: ["x"] },
      ],
      edges: [
        { from: "in.out", to: "n.x" },
        { from: "in.out", to: "n.extra" },
      ],
      outputs: { value: "n.out" },
    };

    try {
      lowerGraphToFusePlan(def);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.undeclaredPort);
      expect((e as Error).message).toContain("extra");
    }
  });

  it("rejects input+param name collision with stable FUSE_ERR", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        {
          id: "n",
          type: "expr",
          expr: "x * 2",
          inputs: ["x"],
          params: { x: 1 },
        },
      ],
      edges: [{ from: "in.out", to: "n.x" }],
      outputs: { value: "n.out" },
    };

    try {
      lowerGraphToFusePlan(def);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.inputParamCollision);
    }
  });

  it("rejects non-finite param with stable FUSE_ERR", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "in", type: "input" },
        {
          id: "n",
          type: "expr",
          expr: "x * k",
          inputs: ["x"],
          params: { k: Number.NaN },
        },
      ],
      edges: [{ from: "in.out", to: "n.x" }],
      outputs: { value: "n.out" },
    };

    try {
      lowerGraphToFusePlan(def);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.nonFiniteParam);
    }
  });

  it("rejects duplicate host-facing input names", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "a", type: "input", name: "signal" },
        { id: "b", type: "input", name: "signal" },
        { id: "sum", type: "expr", expr: "x + y", inputs: ["x", "y"] },
      ],
      edges: [
        { from: "a.out", to: "sum.x" },
        { from: "b.out", to: "sum.y" },
      ],
      outputs: { value: "sum.out" },
    };

    try {
      lowerGraphToFusePlan(def);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.duplicateInputName);
      expect((e as Error).message).toContain("signal");
    }
  });

  it("rejects kind mismatch on edges", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "m", type: "input", kind: "matrix" },
        {
          id: "n",
          type: "expr",
          expr: "x",
          inputs: ["x"],
          inputKinds: ["number"],
        },
      ],
      edges: [{ from: "m.out", to: "n.x" }],
      outputs: { value: "n.out" },
    };

    try {
      lowerGraphToFusePlan(def);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.kindMismatch);
    }
  });

  it("rejects invalid output ref as FuseError", () => {
    const def: GraphDefinition = {
      nodes: [{ id: "a", type: "expr", expr: "1", inputs: [] }],
      edges: [],
      outputs: { value: "not-a-ref" as `${string}.${string}` },
    };

    try {
      lowerGraphToFusePlan(def);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.invalidRef);
    }
  });

  it("rejects output port that is not .out", () => {
    const def: GraphDefinition = {
      nodes: [{ id: "a", type: "expr", expr: "1", inputs: [] }],
      edges: [],
      outputs: { value: "a.side" },
    };

    try {
      lowerGraphToFusePlan(def);
      expect.unreachable("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(FuseError);
      expect((e as Error).message).toContain(FUSE_ERR.outputNotOut);
    }
  });
});
