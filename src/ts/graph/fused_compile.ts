/**
 * GraphDefinition → fused .wasm bytes (Spec 04 / 05).
 *
 * Preferred path: shell to `mathzig compile-graph` when the native binary is
 * available (Spec 05). Fallback: exact semantic match against emit-fuse-goldens
 * fixtures (bit-for-bit plan match, never shape/id-only).
 *
 * **Node/bun only.** Imports `node:child_process` / `node:fs` at top level.
 * Do not import this from `index.ts` or browser code — use `./node` from tests
 * and CLI helpers, or `FusedGraphRunner.load(prebuiltBytes)` in the browser.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import type { WasmCompiler } from "./compile_cache";
import { lowerGraphToFusePlan, type FusePlan } from "./fuse";
import type { GraphOutMode } from "./graph_manifest";
import type { GraphDefinition } from "./schema";
import { normalizePortKind } from "./value_transfer";

const FUSE_GOLDEN_DIR = path.resolve(import.meta.dir, "../../../tests/artifacts/fuse");
const REPO_ROOT = path.resolve(import.meta.dir, "../../..");

const FUSE_GOLDENS = [
  "chain_table.wasm",
  "chain_named.wasm",
  "chain_two_named.wasm",
  "diamond_named.wasm",
  "params_named.wasm",
] as const;

/**
 * Graph definitions whose lowered FusePlan is an **exact** semantic match for
 * the corresponding emit-fuse-goldens fixture (exprs included).
 * Anything else must throw — never return a wrong module.
 */
const GOLDEN_SOURCES: Array<{
  fixture: (typeof FUSE_GOLDENS)[number];
  outMode: GraphOutMode;
  def: GraphDefinition;
}> = [
  {
    fixture: "chain_named.wasm",
    outMode: "named_exports",
    def: {
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
    },
  },
  {
    fixture: "chain_table.wasm",
    outMode: "table",
    def: {
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
    },
  },
  {
    fixture: "chain_two_named.wasm",
    outMode: "named_exports",
    def: {
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
    },
  },
  {
    fixture: "diamond_named.wasm",
    outMode: "named_exports",
    def: {
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
    },
  },
  {
    fixture: "params_named.wasm",
    outMode: "named_exports",
    def: {
      nodes: [
        { id: "x", type: "input" },
        { id: "gain", type: "expr", expr: "x * k", inputs: ["x"], params: { k: 1 } },
      ],
      edges: [{ from: "x.out", to: "gain.x" }],
      outputs: { y: "gain.out" },
    },
  },
];

/**
 * Compile a graph definition to fused wasm bytes.
 *
 * 1. Prefer `mathzig compile-graph` (Spec 05) when the binary is available.
 * 2. Else fall back to exact golden fixtures (interim Spec 04 path).
 *
 * **Default `outMode`:**
 * - `"table"` when the graph has any non-scalar port kind (Spec 07 full-value;
 *   single-pass tick + output table — preferred over named_exports recompute).
 * - `"named_exports"` for pure scalar graphs (historical / golden fixtures).
 *
 * CLI `mathzig compile-graph` always defaults to `"table"`. Pass
 * `{ outMode: "table" | "named_exports" }` to force either mode.
 *
 * `@param _compiler` reserved for future in-process multi-root compile.
 */
export async function compileFused(
  def: GraphDefinition,
  _compiler?: WasmCompiler,
  options: { outMode?: GraphOutMode; mathzigBin?: string } = {},
): Promise<Uint8Array> {
  const outMode =
    options.outMode ??
    (graphDefinitionNeedsFullValue(def) ? "table" : "named_exports");

  const fromCli = compileFusedViaCli(def, outMode, options.mathzigBin);
  if (fromCli) return fromCli;

  // Golden-only fallback when CLI binary is missing.
  const plan = lowerGraphToFusePlan(def);
  ensureFuseGoldens();
  const fixture = matchFuseGoldenExact(plan, outMode);
  if (fixture) {
    return loadFuseGolden(fixture);
  }
  throw new Error(
    `compileFused: mathzig compile-graph binary not found and no matching golden. ` +
      `Build with \`zig build\` then retry, or load a prebuilt fixture with FusedGraphRunner.load. ` +
      `Plan has ${plan.nodes.length} compute node(s), ${plan.outputs.length} output(s), ` +
      `${plan.params.length} param(s).`,
  );
}

/** Resolve `zig-out/bin/mathzig` (or override); return null if missing. */
export function resolveMathzigBin(override?: string): string | null {
  if (override && fs.existsSync(override)) return override;
  const candidates = [
    path.join(REPO_ROOT, "zig-out/bin/mathzig"),
    path.join(process.cwd(), "zig-out/bin/mathzig"),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

function compileFusedViaCli(
  def: GraphDefinition,
  outMode: GraphOutMode,
  binOverride?: string,
): Uint8Array | null {
  const bin = resolveMathzigBin(binOverride);
  if (!bin) return null;

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mathzig-fuse-"));
  try {
    const inPath = path.join(tmp, "graph.json");
    const outPath = path.join(tmp, "out.wasm");
    fs.writeFileSync(inPath, JSON.stringify(def));
    const r = spawnSync(
      bin,
      ["compile-graph", "-i", inPath, "-o", outPath, "--out-mode", outMode],
      { encoding: "utf8", timeout: 120_000, cwd: REPO_ROOT },
    );
    if (r.status !== 0) {
      const detail = (r.stderr || r.stdout || "").trim();
      throw new Error(
        `compileFused: mathzig compile-graph failed (status ${r.status})` +
          (detail ? `: ${detail}` : ""),
      );
    }
    if (!fs.existsSync(outPath)) {
      throw new Error("compileFused: compile-graph exited 0 but output wasm missing");
    }
    return new Uint8Array(fs.readFileSync(outPath));
  } finally {
    try {
      fs.rmSync(tmp, { recursive: true, force: true });
    } catch {
      // best-effort cleanup
    }
  }
}

// ── semantic fingerprint (expr-aware) ──────────────────────────────────────

/**
 * Canonical semantic key for a FusePlan under a chosen out_mode.
 * Includes exprs, node ids, ports, param defaults, and output names —
 * never topology labels alone.
 */
export function fusePlanSemanticKey(plan: FusePlan, outMode: GraphOutMode): string {
  return JSON.stringify({
    outMode,
    inputs: plan.inputs.map((i) => ({
      name: i.name,
      kind: i.kind,
      sourceNodeId: i.sourceNodeId,
    })),
    params: plan.params.map((p) => ({
      name: p.name,
      kind: p.kind,
      nodeId: p.nodeId,
      param: p.param,
      default: p.default,
    })),
    consts: plan.consts.map((c) => ({
      id: c.id,
      value: c.value,
      kind: c.kind,
    })),
    nodes: plan.nodes.map((n) => ({
      id: n.id,
      expr: n.expr,
      inputs: n.inputs,
      inputPorts: n.inputPorts,
      inputKinds: n.inputKinds,
      paramNames: n.paramNames,
      outputKind: n.outputKind,
    })),
    outputs: plan.outputs.map((o) => ({
      name: o.name,
      fromNodeId: o.fromNodeId,
      kind: o.kind,
    })),
  });
}

function matchFuseGoldenExact(plan: FusePlan, outMode: GraphOutMode): string | null {
  const key = fusePlanSemanticKey(plan, outMode);
  for (const g of GOLDEN_SOURCES) {
    if (g.outMode !== outMode) continue;
    const goldenPlan = lowerGraphToFusePlan(g.def);
    if (fusePlanSemanticKey(goldenPlan, g.outMode) === key) {
      return g.fixture;
    }
  }
  return null;
}

function ensureFuseGoldens(): void {
  const missing = FUSE_GOLDENS.some((f) => !fs.existsSync(path.join(FUSE_GOLDEN_DIR, f)));
  if (!missing) return;
  const r = spawnSync("zig", ["build", "emit-fuse-goldens"], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    timeout: 120_000,
  });
  if (r.status !== 0) {
    throw new Error(
      `emit-fuse-goldens failed (status ${r.status})\nstdout: ${r.stdout}\nstderr: ${r.stderr}`,
    );
  }
}

function loadFuseGolden(name: string): Uint8Array {
  return new Uint8Array(fs.readFileSync(path.join(FUSE_GOLDEN_DIR, name)));
}

/** True when any port kind is non-number/boolean (full-value fuse → prefer table). */
function graphDefinitionNeedsFullValue(def: GraphDefinition): boolean {
  try {
    const plan = lowerGraphToFusePlan(def);
    const nonScalar = (k: string) => {
      const n = normalizePortKind(k);
      return n !== "number" && n !== "boolean";
    };
    if (plan.inputs.some((i) => nonScalar(i.kind))) return true;
    if (plan.outputs.some((o) => nonScalar(o.kind))) return true;
    if (plan.nodes.some((n) => nonScalar(n.outputKind) || n.inputKinds.some(nonScalar))) {
      return true;
    }
    if (plan.consts.some((c) => nonScalar(c.kind))) return true;
    return false;
  } catch {
    // Lowerer may reject; fall back to historical scalar default.
    return false;
  }
}
