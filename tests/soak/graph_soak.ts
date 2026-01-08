#!/usr/bin/env bun
/**
 * task-16 / C5 — long soak for GraphRunner (ts_wasm multi-module).
 *
 * Tag class: **soak** (like browser smoke):
 *   - excluded from quick gate (`bun run mz -- --quick`)
 *   - included in full protocol (`bun run mz`) as pipeline step `graph_soak`
 *   - NOT under bunfig `tests/ts` root — never pulled into default `bun test`
 *
 * Default (CI-friendly, still stressy):
 *   MATHZIG_SOAK_TICKS=50000 MATHZIG_SOAK_RELOADS=2000  (~tens of seconds)
 *
 * Deep soak (spec full numbers):
 *   MATHZIG_SOAK_FULL=1
 *   → 1_000_000 ticks + 10_000 reloads
 *
 * Exact commands:
 *   export PATH="$PWD/tools/macos-sdk-shim:$PATH"
 *   zig build   # mathzig for AOT compile
 *   bun tests/soak/graph_soak.ts
 *   MATHZIG_SOAK_FULL=1 bun tests/soak/graph_soak.ts
 *
 * Assertions after warmup (1k ticks):
 *   - series + matrix host handle counts flat (Δ ≤ 2)
 *   - wasm memory pages flat (Δ ≤ 1 per instance)
 *   - reload soak: instance count constant, params preserved
 */
import { compileAot } from "../parity/wasm_aot";
import {
  GraphRunner,
  createDefaultScalarWasmImports,
  type GraphDefinition,
} from "../../src/ts/graph";
import { AotHostEnv } from "../../src/ts/aot_env";
import { loadAllGoldens } from "../graph/corpus";

const FULL = process.env.MATHZIG_SOAK_FULL === "1";
const TICKS = FULL
  ? 1_000_000
  : Number(process.env.MATHZIG_SOAK_TICKS ?? "50000");
const RELOADS = FULL
  ? 10_000
  : Number(process.env.MATHZIG_SOAK_RELOADS ?? "2000");
const WARMUP = Math.min(1000, Math.floor(TICKS / 10));

const compiler = {
  async compile(expr: string, numParams: number): Promise<Uint8Array> {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
};

function golden(id: string): GraphDefinition {
  const g = loadAllGoldens().find((c) => c.id === id);
  if (!g) throw new Error(`golden ${id} missing`);
  return g.graph as GraphDefinition;
}

function rssMb(): number | null {
  try {
    // Bun / Node: heapUsed as soft RSS proxy when process.memoryUsage available
    const mu = (process as { memoryUsage?: () => { rss: number; heapUsed: number } }).memoryUsage?.();
    if (!mu) return null;
    return mu.rss / (1024 * 1024);
  } catch {
    return null;
  }
}

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(msg);
}

type CounterRow = {
  label: string;
  series: number;
  matrix: number;
  record: number;
  pages: number;
  rssMb: number | null;
};

function row(label: string, host: AotHostEnv, runner: GraphRunner): CounterRow {
  const h = host.debugStats();
  const r = runner.debugStats();
  return {
    label,
    series: h.seriesHandleCount,
    matrix: h.matrixHandleCount,
    record: h.recordHandleCount,
    pages: r.maxWasmMemoryPages,
    rssMb: rssMb(),
  };
}

function printTable(rows: CounterRow[]): void {
  console.log("\nCounter table (start / after-warmup / end):");
  console.log(
    "  label".padEnd(16) +
      "series".padStart(8) +
      "matrix".padStart(8) +
      "record".padStart(8) +
      "pages".padStart(8) +
      "rssMb".padStart(10),
  );
  for (const r of rows) {
    console.log(
      `  ${r.label.padEnd(14)}` +
        `${String(r.series).padStart(8)}` +
        `${String(r.matrix).padStart(8)}` +
        `${String(r.record).padStart(8)}` +
        `${String(r.pages).padStart(8)}` +
        `${r.rssMb != null ? r.rssMb.toFixed(1).padStart(10) : "n/a".padStart(10)}`,
    );
  }
}

async function tickSoak(): Promise<void> {
  console.log(`\n══ tick soak: ${TICKS} ticks (warmup ${WARMUP}) FULL=${FULL} ══`);
  const host = new AotHostEnv();
  const seriesRunner = await GraphRunner.load(golden("series_build_then_mean"), {
    compiler,
    env: createDefaultScalarWasmImports(),
    host,
  });
  const matrixRunner = await GraphRunner.load(golden("matrix_scale_then_matmul"), {
    compiler,
    env: createDefaultScalarWasmImports(),
    host,
  });

  const table: CounterRow[] = [];
  // Use series runner for page reporting (both share host).
  table.push(row("start", host, seriesRunner));

  const t0 = performance.now();
  for (let i = 0; i < TICKS; i++) {
    const so = seriesRunner.run({});
    assert(Math.abs(Number(so.value) - 20) < 1e-9, `series tick ${i} bad value ${so.value}`);
    const mo = matrixRunner.run({});
    const data = (mo.value as { data: ArrayLike<number> }).data;
    assert(Math.abs(Number(data[0]) - 2) < 1e-9, `matrix tick ${i} bad`);
    if (i + 1 === WARMUP) table.push(row("after-warmup", host, seriesRunner));
  }
  table.push(row("end", host, seriesRunner));
  const ms = performance.now() - t0;

  printTable(table);
  const warm = table[1] ?? table[0]!;
  const end = table[table.length - 1]!;
  assert(end.series <= warm.series + 2, `series handles grew: warm=${warm.series} end=${end.series}`);
  assert(end.matrix <= warm.matrix + 2, `matrix handles grew: warm=${warm.matrix} end=${end.matrix}`);
  assert(end.pages <= warm.pages + 1, `wasm pages grew: warm=${warm.pages} end=${end.pages}`);

  // RSS soft bound: allow growth but flag pathological multi-GB leaks.
  // Bound: +512 MiB over warmup (CI noise + wasm caches); deep soak may be higher.
  if (warm.rssMb != null && end.rssMb != null) {
    const delta = end.rssMb - warm.rssMb;
    const bound = FULL ? 1024 : 512;
    assert(delta < bound, `RSS grew ${delta.toFixed(1)} MiB (bound ${bound})`);
    console.log(`  RSS Δ after warmup: ${delta.toFixed(1)} MiB (bound ${bound})`);
  }

  console.log(`  tick soak OK in ${(ms / 1000).toFixed(2)}s (${(TICKS / (ms / 1000)).toFixed(0)} ticks/s)`);
  seriesRunner.dispose();
  matrixRunner.dispose();
}

async function reloadSoak(): Promise<void> {
  console.log(`\n══ reload soak: ${RELOADS} reloads FULL=${FULL} ══`);
  const host = new AotHostEnv();
  const runner = await GraphRunner.load(
    {
      nodes: [
        { id: "x", type: "input" },
        {
          id: "stage",
          type: "expr",
          expr: "x * y",
          inputs: ["x"],
          params: { y: 3 },
        },
      ],
      edges: [{ from: "x.out", to: "stage.x" }],
      outputs: { value: "stage.out" },
    },
    { compiler, env: createDefaultScalarWasmImports(), host },
  );

  // Warm
  for (let i = 0; i < 50; i++) runner.run({ x: 2 });
  const warm = runner.debugStats();
  const warmHost = host.debugStats();
  const t0 = performance.now();

  for (let i = 0; i < RELOADS; i++) {
    const expr = i % 2 === 0 ? "x + y" : "x * y";
    await runner.reload("stage", expr);
    const out = runner.run({ x: 2 });
    const y = runner.listParams().find((p) => p.name === "y")!.value;
    assert(y === 3, `param y not preserved at reload ${i}`);
    const expected = i % 2 === 0 ? 5 : 6;
    assert(Math.abs(Number(out.value) - expected) < 1e-9, `reload ${i} value ${out.value} != ${expected}`);
  }

  const end = runner.debugStats();
  const endHost = host.debugStats();
  assert(end.instanceCount === warm.instanceCount, "instance count changed across reloads");
  assert(
    endHost.seriesHandleCount <= warmHost.seriesHandleCount + 2,
    "series handles grew across reload soak",
  );
  console.log(
    `  reload soak OK in ${((performance.now() - t0) / 1000).toFixed(2)}s; instances=${end.instanceCount}`,
  );
  runner.dispose();
}

async function main(): Promise<void> {
  console.log("task-16 graph soak");
  console.log(`  TICKS=${TICKS} RELOADS=${RELOADS} WARMUP=${WARMUP} FULL=${FULL}`);
  await tickSoak();
  await reloadSoak();
  console.log("\nAll soak checks passed.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
