#!/usr/bin/env bun
/**
 * Head-to-head: AOT-compiled wasm vs hand-written JavaScript vs the FFI
 * engine, for expressions you call many times with changing inputs.
 *
 *   bun tools/bench/aot_vs_js.ts [--iters 1_000_000] [--batches 7]
 *
 * Lanes per case:
 *   js         — hand-written arrow function (the thing you'd write instead)
 *   wasm_aot   — module compiled once with `mathzig compile -p 1`, then
 *                `eval(x)` per call (compile cost NOT in the loop)
 *   ffi_eval   — engine CompiledExpr.evaluateFast() per call (bytecode VM
 *                through bun:ffi), for context
 *
 * Reports median ns/op over batches and the ratio vs the js lane. This is a
 * quick decision tool, not a tracked benchmark — for regression tracking use
 * `bun tools/bench/run.ts` (bench/manifest.json tiers + dashboard).
 */
import { runMathZigCompiler } from "../../tests/ts/wasm_utils";
import { AotHostEnv, readAbiManifest } from "../../src/ts/aot_env";
import { MathZig } from "../../src/ts/mathzig";

type Case = {
  id: string;
  expr: string;
  js: (x: number) => number;
  note: string;
  /** false for cases that aren't an elementwise sweep of x (e.g. internal loops). */
  batchable?: boolean;
};

const CASES: Case[] = [
  {
    id: "poly",
    expr: "x*x*x + 2*x*x - 5*x + 1",
    js: (x) => x * x * x + 2 * x * x - 5 * x + 1,
    note: "pure arithmetic — compiles to inline wasm ops, no imports",
  },
  {
    id: "scalar_math",
    expr: "sin(x) * exp(x / 10) + cos(x) * cos(x)",
    js: (x) => Math.sin(x) * Math.exp(x / 10) + Math.cos(x) * Math.cos(x),
    note: "sin/cos/exp are env imports -> one JS Math call per use",
  },
  {
    id: "sqrt_hypot",
    expr: "sqrt(x*x + 3) + hypot(x, 2)",
    js: (x) => Math.sqrt(x * x + 3) + Math.hypot(x, 2),
    note: "sqrt lowers to native f64.sqrt; hypot stays an import",
  },
  {
    id: "loop_heavy",
    expr: `acc = 0;
for (k = 1; k < 500; k = k + 1) {
  acc = acc + (x + k) / (x * k + 1)
};
acc`,
    js: (x) => {
      let acc = 0;
      for (let k = 1; k < 500; k++) acc += (x + k) / (x * k + 1);
      return acc;
    },
    note: "500-iteration loop INSIDE the module — boundary cost amortized",
    batchable: false,
  },
  {
    id: "delegated",
    expr: "gamma(x)",
    js: (x) => {
      // Lanczos approximation — what you'd hand-roll in JS
      const g = 7;
      const c = [
        0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
        -176.61502916214059, 12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6,
        1.5056327351493116e-7,
      ];
      let z = x - 1;
      let a = c[0]!;
      const t = z + g + 0.5;
      for (let i = 1; i < g + 2; i++) a += c[i]! / (z + i);
      return Math.sqrt(2 * Math.PI) * Math.pow(t, z + 0.5) * Math.exp(-t) * a;
    },
    note: "delegated builtin — full FFI round-trip into the engine per call",
  },
];

function parseArgs() {
  const args = process.argv.slice(2);
  const get = (flag: string, dflt: number) => {
    const i = args.indexOf(flag);
    return i >= 0 ? Number(args[i + 1]!.replace(/_/g, "")) : dflt;
  };
  return { iters: get("--iters", 1_000_000), batches: get("--batches", 7) };
}

/** Median ns/op over `batches` timed batches of `iters` calls. */
function bench(fn: (x: number) => number, iters: number, batches: number): { nsPerOp: number; sink: number } {
  let sink = 0;
  // warmup (JIT tiers, wasm compilation tiers)
  for (let i = 0; i < Math.min(iters, 100_000); i++) sink += fn(1 + (i % 100) / 100);
  const times: number[] = [];
  for (let b = 0; b < batches; b++) {
    const t0 = Bun.nanoseconds();
    for (let i = 0; i < iters; i++) sink += fn(1 + (i % 100) / 100);
    times.push((Bun.nanoseconds() - t0) / iters);
  }
  times.sort((a, b2) => a - b2);
  return { nsPerOp: times[Math.floor(times.length / 2)]!, sink };
}

async function makeAotLane(expr: string): Promise<(x: number) => number> {
  const wasmBytes = await runMathZigCompiler(expr, 1); // 1 param: x
  const module = await WebAssembly.compile(wasmBytes);
  const manifest = readAbiManifest(module);
  const host = new AotHostEnv();
  const instance = await WebAssembly.instantiate(module, { env: host.buildEnvForManifest(manifest) });
  host.attachMemory((instance.exports as { memory?: WebAssembly.Memory }).memory ?? null);
  host.attachInstance(instance.exports as Record<string, unknown>);
  return instance.exports.eval as (x: number) => number;
}

function makeFfiLane(mz: MathZig, expr: string): (x: number) => number {
  mz.setVariable("x", 0);
  const compiled = mz.compile(expr);
  return (x: number) => {
    mz.setVariable("x", x);
    return compiled.evaluateFast();
  };
}

/** Median ns per element for a whole-array operation, over `reps` runs. */
function benchBatch(run: (inp: Float64Array, out: Float64Array, n: number) => void, inp: Float64Array, out: Float64Array, reps: number): { nsPerEl: number; sink: number } {
  const n = inp.length;
  run(inp, out, n); // warmup
  const times: number[] = [];
  for (let r = 0; r < reps; r++) {
    const t0 = Bun.nanoseconds();
    run(inp, out, n);
    times.push((Bun.nanoseconds() - t0) / n);
  }
  times.sort((a, b) => a - b);
  return { nsPerEl: times[Math.floor(times.length / 2)]!, sink: out[0]! + out[n - 1]! };
}

const { iters, batches } = parseArgs();
const mz = MathZig.create();

// ===========================================================================
// Per-call: one eval per call from JS (the original table). JS's best case —
// the JIT inlines everything; wasm/ffi pay a boundary crossing per call.
// ===========================================================================
console.log(`PER-CALL  iters=${iters} batches=${batches}  (median ns/op; ratio >1 = slower than JS)\n`);
console.log(
  "case".padEnd(14) + "js".padStart(10) + "wasm_aot".padStart(12) + "ffi_eval".padStart(12) +
  "  wasm/js".padStart(10) + "  ffi/js".padStart(10),
);

for (const c of CASES) {
  const aot = await makeAotLane(c.expr);
  const ffi = makeFfiLane(mz, c.expr);

  // sanity: all lanes must agree before timing means anything
  for (const x of [1.3, 2.7, 4.1]) {
    const [j, w, f] = [c.js(x), aot(x), ffi(x)];
    if (Math.abs(j - w) > 1e-6 * Math.max(1, Math.abs(j)) || Math.abs(j - f) > 1e-6 * Math.max(1, Math.abs(j))) {
      throw new Error(`${c.id}: lanes disagree at x=${x}: js=${j} wasm=${w} ffi=${f}`);
    }
  }

  const j = bench(c.js, iters, batches);
  const w = bench(aot, iters, batches);
  const f = bench(ffi, iters, batches);
  console.log(
    c.id.padEnd(14) +
    `${j.nsPerOp.toFixed(1)}`.padStart(10) +
    `${w.nsPerOp.toFixed(1)}`.padStart(12) +
    `${f.nsPerOp.toFixed(1)}`.padStart(12) +
    `${(w.nsPerOp / j.nsPerOp).toFixed(2)}x`.padStart(10) +
    `${(f.nsPerOp / j.nsPerOp).toFixed(2)}x`.padStart(10),
  );
  console.log(`  ${c.note}`);
}

// ===========================================================================
// Batch: apply the expression to a whole Float64Array. This is the workload
// the compiler actually targets (bulk eval of a dynamic expression).
//   js_batch       — hand-written fn over the array (baseline)
//   wasm_loop      — JS loops calling module eval(x) per element; NO in-module
//                    batch export exists yet, so this still pays N crossings
//   ffi_simd       — mathzig_batch_eval_simd: ONE crossing, SIMD loop in Zig
//   ffi_scalarloop — setVariable + evaluateFast per element (2 crossings each)
// ===========================================================================
const N = Math.min(iters, 1_000_000);
const inp = new Float64Array(N);
for (let i = 0; i < N; i++) inp[i] = 1 + (i % 100) / 100;
const out = new Float64Array(N);

console.log(`\nBATCH  N=${N} batches=${batches}  (median ns/element; ratio >1 = slower than js_batch)\n`);
console.log(
  "case".padEnd(14) + "js_batch".padStart(10) + "wasm_loop".padStart(11) + "ffi_simd".padStart(10) +
  "ffi_scalar".padStart(12) + "  wasm/js".padStart(10) + "  simd/js".padStart(10),
);

let globalSink = 0;
for (const c of CASES) {
  if (c.batchable === false) continue;

  const aot = await makeAotLane(c.expr);

  // dedicated ctx per case so the swept variable's index is unambiguous
  const bctx = MathZig.create();
  const varIndex = bctx.addVariableIndexed("x", 0);
  const compiled = bctx.compile(c.expr);

  const jsBatch = benchBatch((i, o, n) => { for (let k = 0; k < n; k++) o[k] = c.js(i[k]!); }, inp, out, batches);
  const wasmLoop = benchBatch((i, o, n) => { for (let k = 0; k < n; k++) o[k] = aot(i[k]!); }, inp, out, batches);
  const ffiSimd = benchBatch((i, o, n) => compiled.evaluateBatchSIMD(varIndex, i, o, n), inp, out, batches);
  const ffiScalar = benchBatch((i, o, n) => {
    for (let k = 0; k < n; k++) { bctx.setVariable("x", i[k]!); o[k] = compiled.evaluateFast(); }
  }, inp, out, batches);
  globalSink += jsBatch.sink + wasmLoop.sink + ffiSimd.sink + ffiScalar.sink;

  console.log(
    c.id.padEnd(14) +
    `${jsBatch.nsPerEl.toFixed(2)}`.padStart(10) +
    `${wasmLoop.nsPerEl.toFixed(2)}`.padStart(11) +
    `${ffiSimd.nsPerEl.toFixed(2)}`.padStart(10) +
    `${ffiScalar.nsPerEl.toFixed(2)}`.padStart(12) +
    `${(wasmLoop.nsPerEl / jsBatch.nsPerEl).toFixed(2)}x`.padStart(10) +
    `${(ffiSimd.nsPerEl / jsBatch.nsPerEl).toFixed(2)}x`.padStart(10),
  );
  compiled.free();
  bctx.destroy();
}
if (globalSink === Infinity) console.log("(sink)"); // keep results live
