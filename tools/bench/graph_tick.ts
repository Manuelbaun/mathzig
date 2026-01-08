#!/usr/bin/env bun
/**
 * Node-graph tick microbench (task-10 / B4 + Spec 08 multi vs fused).
 *
 * Reuses GraphRunner (multi-module) and FusedGraphRunner (Stage B table tick);
 * reports median ns/tick. Compile/load cost is measured separately from
 * steady-state ticks (warmup excluded from the median window).
 *
 * Multi single-tick uses hot `GraphRunner.run()` (no `runProfiled` tax).
 * Fused uses Stage B table `tick` via `FusedGraphRunner.run()`.
 *
 *   bun tools/bench/graph_tick.ts \
 *     [--ticks 100000] [--batches 7] \
 *     [--mode run|batch|both] \
 *     [--runtime multi|fused|both] \
 *     [--mono]            # optional: single-expr AOT upper bound on scalar chains
 *
 * Flags:
 *   --mode     How to tick: single `run`, host `runBatch`, or both (default both).
 *   --runtime  multi = GraphRunner (one module per expr node);
 *              fused = FusedGraphRunner Stage B (`tick` + output table);
 *              both  = report multi and fused side-by-side (default both).
 *              Task-10 multi-only re-baselines: pass `--runtime multi`
 *              (default `both` also needs `zig-out/bin/mathzig` for fuse).
 *
 * Cases:
 *   scalar_3 / scalar_10 / scalar_50  — pure-scalar chains
 *   multi_out                         — chain with 2 graph outs (mid + end)
 *   matrix_edge                       — matrix host-mediated / fused edge
 *   mono_scalar_N (optional --mono)   — same math as one AOT expr (upper bound)
 *
 * Not a tracked dashboard feature — results go into
 * docs/reference/graph_tick_baseline.md (tripwire baseline) and
 * docs/archive/plans/compile-fuse/08_results.md (historical fuse measurements).
 */
import * as os from "node:os";
import { compileAot } from "../../tests/parity/wasm_aot";
import {
  GraphRunner,
  FusedGraphRunner,
  createDefaultScalarWasmImports,
  type GraphDefinition,
} from "../../src/ts/graph";
import { compileFused } from "../../src/ts/graph/node";
import { AotHostEnv } from "../../src/ts/aot_env";

const compiler = {
  async compile(expr: string, numParams: number): Promise<Uint8Array> {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
  version: "graph_tick_bench",
};

type TickMode = "run" | "batch" | "both";
type Runtime = "multi" | "fused" | "both";

function parseArgs() {
  const args = process.argv.slice(2);
  const get = (flag: string, dflt: number) => {
    const i = args.indexOf(flag);
    if (i < 0) return dflt;
    const raw = args[i + 1];
    if (raw == null || raw.startsWith("--")) {
      throw new Error(`${flag} requires a numeric value`);
    }
    return Number(raw.replace(/_/g, ""));
  };
  const enumFlag = <T extends string>(flag: string, allowed: readonly T[], dflt: T): T => {
    const i = args.indexOf(flag);
    if (i < 0) return dflt;
    const raw = args[i + 1];
    if (raw == null || raw.startsWith("--")) {
      throw new Error(`${flag} requires one of: ${allowed.join("|")}`);
    }
    if (!(allowed as readonly string[]).includes(raw)) {
      throw new Error(`${flag} must be ${allowed.join("|")} (got ${raw})`);
    }
    return raw as T;
  };
  // Default both so Spec 08 / daily multi-vs-fused is one command; task-10
  // multi-only still works with `--runtime multi`.
  const mode = enumFlag("--mode", ["run", "batch", "both"] as const, "both");
  const runtime = enumFlag("--runtime", ["multi", "fused", "both"] as const, "both");
  const mono = args.includes("--mono");
  return {
    ticks: get("--ticks", 100_000),
    batches: get("--batches", 7),
    mode,
    runtime,
    mono,
  };
}

/** True when any node port is non-number (needs AotHostEnv on multi load). */
function graphNeedsHost(def: GraphDefinition): boolean {
  for (const n of def.nodes) {
    if (n.type === "expr" || n.type === "wasm") {
      if (n.outputKind && n.outputKind !== "number") return true;
      const kinds = (n as { inputKinds?: string[] }).inputKinds;
      if (kinds?.some((k) => k !== "number")) return true;
    }
  }
  return false;
}

/** Build a pure-scalar chain of `depth` expr nodes: x → (*2) → (+1) → (*2) → … */
function scalarChain(depth: number): GraphDefinition {
  if (depth < 1) throw new Error("depth >= 1");
  const nodes: GraphDefinition["nodes"] = [{ id: "x", type: "input" }];
  const edges: Array<{ from: `${string}.${string}`; to: `${string}.${string}` }> = [];
  for (let i = 0; i < depth; i++) {
    const id = `n${i}`;
    // Alternate *2 and +1 so the chain is not a pure multiply that the compiler
    // could constant-fold across independent modules (each module is separate).
    const expr = i % 2 === 0 ? "x * 2" : "x + 1";
    (nodes as any[]).push({ id, type: "expr", expr, inputs: ["x"] });
    const from = i === 0 ? "x.out" : `n${i - 1}.out`;
    edges.push({ from: from as any, to: `${id}.x` as any });
  }
  return {
    nodes,
    edges,
    outputs: { value: `n${depth - 1}.out` },
  };
}

/**
 * Chain with two graph outputs (mid after first expr, end after second).
 * Matches the multi_out case in Spec 08.
 */
function multiOutGraph(): GraphDefinition {
  return {
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
}

function matrixEdgeGraph(): GraphDefinition {
  return {
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
  };
}

/**
 * Matrix-heavy graph with **number** I/O so runBatch applies (task-19 P5).
 * Intermediate edge is matrix; used to measure whether lanes leave >2× on the
 * table vs optimized run() for the shared-memory decision.
 */
function matrixHeavyNumberOutGraph(): GraphDefinition {
  return {
    nodes: [
      { id: "k", type: "input" },
      {
        id: "g",
        type: "expr",
        expr: "[x, 0; 0, x] * [1, 2; 3, 4]",
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
  };
}

/**
 * Same math as scalarChain(depth) folded into one expression
 * (upper bound: one eval, no graph host).
 */
function monoExpr(depth: number): string {
  let e = "x";
  for (let i = 0; i < depth; i++) {
    e = i % 2 === 0 ? `(${e}) * 2` : `(${e}) + 1`;
  }
  return e;
}

function median(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)]!;
}

function nsNow(): number {
  return Bun.nanoseconds();
}

type LoadTiming = {
  /** Wall ns for graph→wasm (multi: per-node AOT inside load; fused: compileFused). */
  compileNs: number;
  /** Wall ns for instantiate / GraphRunner.load remainder. */
  loadNs: number;
  /** compileNs + loadNs */
  totalNs: number;
};

type TickResult = {
  nsPerTick: number;
  sink: number;
};

type CaseRow = {
  case: string;
  nodes: number;
  runtime: "multi" | "fused" | "mono";
  compileMs: number | null;
  loadMs: number | null;
  runNs: number | null;
  batchNs: number | null;
  note?: string;
};

async function loadMulti(def: GraphDefinition): Promise<{
  runner: GraphRunner;
  timing: LoadTiming;
}> {
  // Multi path: compile + instantiate are inside GraphRunner.load — report as
  // one load cost; compileNs left as total (cannot cleanly split without
  // instrumenting the runner). Labelled honestly in results.
  // Pure-scalar: lightweight env only (task-10 style). Host only for non-scalar.
  const t0 = nsNow();
  const runner = await GraphRunner.load(def, {
    compiler,
    env: createDefaultScalarWasmImports(),
    ...(graphNeedsHost(def) ? { host: new AotHostEnv() } : {}),
  });
  const total = nsNow() - t0;
  return {
    runner,
    timing: { compileNs: total, loadNs: 0, totalNs: total },
  };
}

async function loadFused(def: GraphDefinition): Promise<{
  runner: FusedGraphRunner;
  timing: LoadTiming;
}> {
  // Stage B: table + single `tick` entry (preferred hot path for Spec 08).
  // Pure scalar: env only; host only when graph has non-scalar ports (matrix_edge).
  const t0 = nsNow();
  const bytes = await compileFused(def, compiler, { outMode: "table" });
  const compileNs = nsNow() - t0;
  const t1 = nsNow();
  const runner = await FusedGraphRunner.load(bytes, {
    env: createDefaultScalarWasmImports(),
    ...(graphNeedsHost(def) ? { host: new AotHostEnv() } : {}),
  });
  const loadNs = nsNow() - t1;
  return {
    runner,
    timing: { compileNs, loadNs, totalNs: compileNs + loadNs },
  };
}

/** Median ns/tick for runner.run over `batches` timed batches of `ticks`. */
function benchRun(
  runOnce: (inputs: Record<string, number>) => Record<string, unknown>,
  inputs: Record<string, number>,
  ticks: number,
  batches: number,
  sinkKey = "value",
): TickResult {
  let sink = 0;
  // warmup — excluded from median
  const warm = Math.min(ticks, 2_000);
  for (let i = 0; i < warm; i++) {
    const out = runOnce(inputs);
    const v = out[sinkKey];
    sink += typeof v === "number" ? v : Number(v ?? 0);
  }
  const times: number[] = [];
  for (let b = 0; b < batches; b++) {
    const t0 = nsNow();
    for (let i = 0; i < ticks; i++) {
      const out = runOnce(inputs);
      const v = out[sinkKey];
      sink += typeof v === "number" ? v : Number(v ?? 0);
    }
    times.push((nsNow() - t0) / ticks);
  }
  return { nsPerTick: median(times), sink };
}

function benchRunMultiOut(
  runOnce: (inputs: Record<string, number>) => Record<string, unknown>,
  inputs: Record<string, number>,
  ticks: number,
  batches: number,
): TickResult {
  let sink = 0;
  const warm = Math.min(ticks, 2_000);
  for (let i = 0; i < warm; i++) {
    const out = runOnce(inputs);
    sink += Number(out.mid) + Number(out.end);
  }
  const times: number[] = [];
  for (let b = 0; b < batches; b++) {
    const t0 = nsNow();
    for (let i = 0; i < ticks; i++) {
      const out = runOnce(inputs);
      sink += Number(out.mid) + Number(out.end);
    }
    times.push((nsNow() - t0) / ticks);
  }
  return { nsPerTick: median(times), sink };
}

function benchRunMatrix(
  runOnce: () => { value: { data: ArrayLike<number> } },
  ticks: number,
  batches: number,
): TickResult {
  let sink = 0;
  const warm = Math.min(ticks, 500);
  for (let i = 0; i < warm; i++) {
    const out = runOnce();
    sink += Number(out.value.data[0]);
  }
  const times: number[] = [];
  for (let b = 0; b < batches; b++) {
    const t0 = nsNow();
    for (let i = 0; i < ticks; i++) {
      const out = runOnce();
      sink += Number(out.value.data[0]);
    }
    times.push((nsNow() - t0) / ticks);
  }
  return { nsPerTick: median(times), sink };
}

/** Median ns/tick for runBatch when available. */
function benchBatch(
  runBatch: (
    inputLanes: Record<string, Float64Array>,
    n: number,
  ) => Record<string, Float64Array>,
  inputLanes: Record<string, Float64Array>,
  ticks: number,
  batches: number,
  outKeys: string[],
): TickResult {
  // warmup
  runBatch(inputLanes, Math.min(ticks, 2_000));
  const times: number[] = [];
  let sink = 0;
  for (let b = 0; b < batches; b++) {
    const t0 = nsNow();
    const out = runBatch(inputLanes, ticks);
    times.push((nsNow() - t0) / ticks);
    for (const k of outKeys) {
      const lane = out[k];
      if (lane) sink += lane[0]! + lane[ticks - 1]!;
    }
  }
  return { nsPerTick: median(times), sink };
}

async function loadMono(
  depth: number,
): Promise<{
  evalFn: (x: number) => number;
  timing: LoadTiming;
  dispose: () => void;
}> {
  const expr = monoExpr(depth);
  const t0 = nsNow();
  const { wasmBytes } = await compileAot(expr, 1);
  const compileNs = nsNow() - t0;
  const t1 = nsNow();
  const mod = await WebAssembly.compile(wasmBytes);
  const env = createDefaultScalarWasmImports();
  const instance = await WebAssembly.instantiate(mod, env as WebAssembly.Imports);
  const loadNs = nsNow() - t1;
  const evalRaw = instance.exports.eval;
  if (typeof evalRaw !== "function") {
    throw new Error("mono: missing eval export");
  }
  const evalFn = evalRaw as (x: number) => number;
  return {
    evalFn,
    timing: { compileNs, loadNs, totalNs: compileNs + loadNs },
    dispose: () => {},
  };
}

function formatMs(ns: number | null | undefined): string {
  if (ns == null) return "n/a";
  return `${(ns / 1e6).toFixed(1)} ms`;
}

function formatNs(ns: number | null | undefined): string {
  if (ns == null) return "n/a";
  return `${ns.toFixed(1)} ns/tick`;
}

const { ticks, batches, mode, runtime, mono } = parseArgs();

const machine = {
  platform: process.platform,
  arch: process.arch,
  os: `${os.type()} ${os.release()}`,
  cpu: os.cpus()[0]?.model ?? "unknown",
  cores: os.cpus().length,
  bun: Bun.version,
  node: process.version,
  date: new Date().toISOString(),
};

console.log("MathZig graph tick bench (task-10 B4 + Spec 08 multi vs fused)");
console.log(
  `machine: ${machine.cpu} | ${machine.os} | ${machine.arch} | bun ${machine.bun}`,
);
console.log(
  `ticks=${ticks} batches=${batches} mode=${mode} runtime=${runtime}` +
    (mono ? " mono=on" : "") +
    "\n",
);
console.log(
  "Note: multi compile/load is GraphRunner.load wall time (per-node AOT + instantiate).",
);
console.log(
  "      fused compile = compileFused (table/Stage B); load = FusedGraphRunner.load.",
);
console.log("      Steady-state medians exclude warmup.\n");

const rows: CaseRow[] = [];
const wantMulti = runtime === "multi" || runtime === "both";
const wantFused = runtime === "fused" || runtime === "both";

function pushRow(row: CaseRow) {
  rows.push(row);
  const tag = `${row.case}/${row.runtime}`.padEnd(22);
  const nodes = `nodes=${String(row.nodes).padStart(2)}`;
  const compile =
    row.compileMs != null ? `compile ${row.compileMs.toFixed(1)}ms` : "compile n/a";
  const load = row.loadMs != null ? `load ${row.loadMs.toFixed(1)}ms` : "load n/a";
  const run = row.runNs != null ? `run ${row.runNs.toFixed(1)} ns/tick` : "";
  const batch = row.batchNs != null ? `batch ${row.batchNs.toFixed(1)} ns/tick` : "";
  const note = row.note ? `  (${row.note})` : "";
  console.log(
    `${tag} ${nodes}  ${compile.padEnd(16)} ${load.padEnd(14)} ${run}  ${batch}${note}`.trimEnd(),
  );
}

// ── scalar chains ────────────────────────────────────────────────────────
for (const depth of [3, 10, 50]) {
  const def = scalarChain(depth);
  const caseName = `scalar_${depth}`;

  if (wantMulti) {
    const { runner, timing } = await loadMulti(def);
    try {
      const sample = runner.run({ x: 1 });
      if (!Number.isFinite(Number(sample.value))) {
        throw new Error(`${caseName}/multi: non-finite sample ${sample.value}`);
      }
      let runNs: number | null = null;
      let batchNs: number | null = null;
      if (mode === "run" || mode === "both") {
        runNs = benchRun((inp) => runner.run(inp), { x: 1.5 }, ticks, batches).nsPerTick;
      }
      if (mode === "batch" || mode === "both") {
        const lane = new Float64Array(ticks);
        lane.fill(1.5);
        batchNs = benchBatch(
          (lanes, n) => runner.runBatch(lanes, n),
          { x: lane },
          ticks,
          batches,
          ["value"],
        ).nsPerTick;
      }
      pushRow({
        case: caseName,
        nodes: depth,
        runtime: "multi",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs,
        note: "compile+load combined in compileMs",
      });
    } finally {
      runner.dispose();
    }
  }

  if (wantFused) {
    const { runner, timing } = await loadFused(def);
    try {
      const sample = runner.run({ x: 1 });
      if (!Number.isFinite(Number(sample.value))) {
        throw new Error(`${caseName}/fused: non-finite sample ${sample.value}`);
      }
      let runNs: number | null = null;
      let batchNs: number | null = null;
      if (mode === "run" || mode === "both") {
        runNs = benchRun((inp) => runner.run(inp), { x: 1.5 }, ticks, batches).nsPerTick;
      }
      if (mode === "batch" || mode === "both") {
        const lane = new Float64Array(ticks);
        lane.fill(1.5);
        // Fused runBatch is a host loop over run() (Spec 07) — still useful.
        batchNs = benchBatch(
          (lanes, n) => runner.runBatch(lanes, n),
          { x: lane },
          ticks,
          batches,
          ["value"],
        ).nsPerTick;
      }
      pushRow({
        case: caseName,
        nodes: depth,
        runtime: "fused",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs,
        note: "Stage B table tick",
      });
    } finally {
      runner.dispose();
    }
  }

  if (mono) {
    const { evalFn, timing, dispose } = await loadMono(depth);
    try {
      const sample = evalFn(1);
      if (!Number.isFinite(sample)) {
        throw new Error(`${caseName}/mono: non-finite ${sample}`);
      }
      let runNs: number | null = null;
      if (mode === "run" || mode === "both") {
        let sink = 0;
        for (let i = 0; i < Math.min(ticks, 2_000); i++) sink += evalFn(1.5);
        const times: number[] = [];
        for (let b = 0; b < batches; b++) {
          const t0 = nsNow();
          for (let i = 0; i < ticks; i++) sink += evalFn(1.5);
          times.push((nsNow() - t0) / ticks);
        }
        runNs = median(times);
        void sink;
      }
      pushRow({
        case: caseName,
        nodes: 1,
        runtime: "mono",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs: null,
        note: "single-expr AOT upper bound",
      });
    } finally {
      dispose();
    }
  }
}

// ── multi_out (2 outs) ───────────────────────────────────────────────────
{
  const def = multiOutGraph();
  const caseName = "multi_out";
  const nodes = 2;

  if (wantMulti) {
    const { runner, timing } = await loadMulti(def);
    try {
      const sample = runner.run({ x: 3 });
      if (!Number.isFinite(Number(sample.mid)) || !Number.isFinite(Number(sample.end))) {
        throw new Error(`${caseName}/multi: bad sample ${JSON.stringify(sample)}`);
      }
      let runNs: number | null = null;
      let batchNs: number | null = null;
      if (mode === "run" || mode === "both") {
        runNs = benchRunMultiOut((inp) => runner.run(inp), { x: 1.5 }, ticks, batches)
          .nsPerTick;
      }
      if (mode === "batch" || mode === "both") {
        const lane = new Float64Array(ticks);
        lane.fill(1.5);
        batchNs = benchBatch(
          (lanes, n) => runner.runBatch(lanes, n),
          { x: lane },
          ticks,
          batches,
          ["mid", "end"],
        ).nsPerTick;
      }
      pushRow({
        case: caseName,
        nodes,
        runtime: "multi",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs,
        note: "compile+load combined in compileMs",
      });
    } finally {
      runner.dispose();
    }
  }

  if (wantFused) {
    const { runner, timing } = await loadFused(def);
    try {
      const sample = runner.run({ x: 3 });
      if (!Number.isFinite(Number(sample.mid)) || !Number.isFinite(Number(sample.end))) {
        throw new Error(`${caseName}/fused: bad sample ${JSON.stringify(sample)}`);
      }
      let runNs: number | null = null;
      let batchNs: number | null = null;
      if (mode === "run" || mode === "both") {
        runNs = benchRunMultiOut((inp) => runner.run(inp), { x: 1.5 }, ticks, batches)
          .nsPerTick;
      }
      if (mode === "batch" || mode === "both") {
        const lane = new Float64Array(ticks);
        lane.fill(1.5);
        batchNs = benchBatch(
          (lanes, n) => runner.runBatch(lanes, n),
          { x: lane },
          ticks,
          batches,
          ["mid", "end"],
        ).nsPerTick;
      }
      pushRow({
        case: caseName,
        nodes,
        runtime: "fused",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs,
        note: "Stage B table tick (single pass multi-out)",
      });
    } finally {
      runner.dispose();
    }
  }
}

// ── matrix edge (matrix output — batch N/A) ─────────────────────────────
{
  const def = matrixEdgeGraph();
  const caseName = "matrix_edge";

  if (wantMulti) {
    const { runner, timing } = await loadMulti(def);
    try {
      const sample = runner.run({}) as { value: { data: ArrayLike<number> } };
      if (sample.value == null) throw new Error("matrix_edge/multi: empty sample");

      let runNs: number | null = null;
      if (mode === "run" || mode === "both") {
        runNs = benchRunMatrix(
          () => runner.run({}) as { value: { data: ArrayLike<number> } },
          ticks,
          batches,
        ).nsPerTick;
      }
      // Non-scalar outputs: batch N/A (number-lane API)
      pushRow({
        case: caseName,
        nodes: 2,
        runtime: "multi",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs: null,
        note: "non-scalar out; batch N/A; compile+load combined",
      });
    } finally {
      runner.dispose();
    }
  }

  if (wantFused) {
    const { runner, timing } = await loadFused(def);
    try {
      const sample = runner.run({}) as { value: { data: ArrayLike<number> } };
      if (sample.value == null) throw new Error("matrix_edge/fused: empty sample");

      let runNs: number | null = null;
      if (mode === "run" || mode === "both") {
        runNs = benchRunMatrix(
          () => runner.run({}) as { value: { data: ArrayLike<number> } },
          ticks,
          batches,
        ).nsPerTick;
      }
      pushRow({
        case: caseName,
        nodes: 2,
        runtime: "fused",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs: null,
        note: "non-scalar Stage B; batch N/A",
      });
    } finally {
      runner.dispose();
    }
  }
}

// ── matrix-heavy number-out (task-19 P5 shared-memory experiment) ───────
{
  const def = matrixHeavyNumberOutGraph();
  const caseName = "matrix_heavy_num";

  if (wantMulti) {
    const { runner, timing } = await loadMulti(def);
    try {
      const sample = runner.run({ k: 1.5 });
      if (!Number.isFinite(Number(sample.value))) {
        throw new Error(`matrix_heavy_num/multi: bad sample ${sample.value}`);
      }
      let runNs: number | null = null;
      let batchNs: number | null = null;
      if (mode === "run" || mode === "both") {
        runNs = benchRun((inp) => runner.run(inp), { k: 1.5 }, ticks, batches).nsPerTick;
      }
      if (mode === "batch" || mode === "both") {
        const lane = new Float64Array(ticks);
        lane.fill(1.5);
        batchNs = benchBatch(
          (lanes, n) => runner.runBatch(lanes, n),
          { k: lane },
          ticks,
          batches,
          ["value"],
        ).nsPerTick;
      }
      pushRow({
        case: caseName,
        nodes: 3,
        runtime: "multi",
        compileMs: timing.compileNs / 1e6,
        loadMs: timing.loadNs / 1e6,
        runNs,
        batchNs,
        note: "matrix intermediate, number out; batch vs run for shared-memory decision",
      });
    } finally {
      runner.dispose();
    }
  }
}

// Comparison helper for footer
function pairedSpeedup(): Array<{
  case: string;
  multiRun: number | null;
  fusedRun: number | null;
  ratio: number | null;
  winner: string | null;
}> {
  const cases = [...new Set(rows.map((r) => r.case))];
  return cases.map((c) => {
    const multi = rows.find((r) => r.case === c && r.runtime === "multi");
    const fused = rows.find((r) => r.case === c && r.runtime === "fused");
    const multiRun = multi?.runNs ?? null;
    const fusedRun = fused?.runNs ?? null;
    let ratio: number | null = null;
    let winner: string | null = null;
    if (multiRun != null && fusedRun != null && fusedRun > 0) {
      ratio = multiRun / fusedRun;
      if (fusedRun < multiRun * 0.95) winner = "fused";
      else if (multiRun < fusedRun * 0.95) winner = "multi";
      else winner = "tie";
    }
    return { case: c, multiRun, fusedRun, ratio, winner };
  });
}

const compare = pairedSpeedup();

console.log("\n--- multi vs fused (run ns/tick; ratio = multi/fused, >1 means fused faster) ---");
for (const c of compare) {
  if (c.multiRun == null && c.fusedRun == null) continue;
  console.log(
    `${c.case.padEnd(14)} multi ${formatNs(c.multiRun).padEnd(16)} fused ${formatNs(c.fusedRun).padEnd(16)}` +
      (c.ratio != null
        ? ` ratio ${c.ratio.toFixed(2)}×  winner=${c.winner}`
        : ""),
  );
}

// Machine-readable footer for capture into results docs
console.log("\n--- json ---");
console.log(
  JSON.stringify(
    {
      machine,
      ticks,
      batches,
      mode,
      runtime,
      mono,
      rows,
      compare,
      notes: {
        multi_compile:
          "GraphRunner.load wall time (per-node AOT + instantiate); reported in compileMs, loadMs=0",
        fused_compile: "compileFused (mathzig compile-graph, out_mode=table Stage B)",
        fused_load: "FusedGraphRunner.load instantiate",
        warmup: "excluded from median (min(ticks,2000) scalar; 500 matrix)",
        fused_batch: "host loop over run() (Spec 07), not wasm tick_batch",
      },
    },
    null,
    2,
  ),
);

// Silence unused helper warnings if tree-shaken oddly
void formatMs;
