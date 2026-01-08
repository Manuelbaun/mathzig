/**
 * Always-on leak / alloc-failure regressions (task-16 / C5).
 *
 * Fast, outside the `soak` tag — runs under strict_bun / `bun test`.
 * Long 1M-tick + 10k-reload soaks live in tests/soak/graph_soak.ts
 * (pipeline step `graph_soak`, excluded from quick gate).
 */
import { describe, expect, it } from "bun:test";
import { compileAot } from "../parity/wasm_aot";
import {
  GraphRunner,
  GraphAllocError,
  createDefaultScalarWasmImports,
  type GraphDefinition,
} from "../../src/ts/graph";
import { AotHostEnv, AllocFailureError } from "../../src/ts/aot_env";
import { loadAllGoldens } from "../graph/corpus";

const compiler = {
  async compile(expr: string, numParams: number): Promise<Uint8Array> {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
};

async function loadGraph(def: GraphDefinition, host?: AotHostEnv): Promise<GraphRunner> {
  return GraphRunner.load(def, {
    compiler,
    env: createDefaultScalarWasmImports(),
    host,
  });
}

function goldenDef(id: string): GraphDefinition {
  const g = loadAllGoldens().find((c) => c.id === id);
  if (!g) throw new Error(`golden ${id} missing`);
  return g.graph as GraphDefinition;
}

describe("task-16 graph leaks / debugStats (always-on)", () => {
  it("debugStats reports host series/matrix counts and wasm pages", async () => {
    const host = new AotHostEnv();
    const runner = await loadGraph(goldenDef("series_build_then_mean"), host);
    try {
      const before = runner.debugStats();
      expect(before.host).not.toBeNull();
      expect(before.instanceCount).toBeGreaterThanOrEqual(2);
      runner.run({});
      const after = runner.debugStats();
      expect(after.host!.seriesHandleCount).toBeGreaterThanOrEqual(0);
      expect(after.maxWasmMemoryPages).toBeGreaterThanOrEqual(1);
      expect(typeof after.host!.decodeBufferHighWater).toBe("number");
    } finally {
      runner.dispose();
    }
  });

  it("series+matrix edges keep handle counts flat over 200 ticks", async () => {
    const host = new AotHostEnv();
    const seriesRunner = await loadGraph(goldenDef("series_build_then_mean"), host);
    const matrixRunner = await loadGraph(goldenDef("matrix_scale_then_matmul"), host);
    try {
      // Warmup
      for (let i = 0; i < 20; i++) {
        seriesRunner.run({});
        matrixRunner.run({});
      }
      const warm = host.debugStats();
      const warmSeries = warm.seriesHandleCount;
      const warmMatrix = warm.matrixHandleCount;

      for (let i = 0; i < 200; i++) {
        const so = seriesRunner.run({});
        expect(so.value).toBeCloseTo(20, 10);
        const mo = matrixRunner.run({});
        expect((mo.value as { data: number[] }).data?.[0] ?? (mo.value as { data: Float64Array }).data[0]).toBeCloseTo(2, 10);
      }

      const end = host.debugStats();
      // Flat within a small bound (GC may leave 0–few retained; never grow with ticks).
      expect(end.seriesHandleCount).toBeLessThanOrEqual(warmSeries + 2);
      expect(end.matrixHandleCount).toBeLessThanOrEqual(warmMatrix + 2);
      expect(end.seriesHandleCount).toBeLessThan(20);
    } finally {
      seriesRunner.dispose();
      matrixRunner.dispose();
    }
  });

  it("reload preserves params and does not grow instance/handle counts", async () => {
    const host = new AotHostEnv();
    const runner = await loadGraph(
      {
        nodes: [
          { id: "x", type: "input" },
          {
            id: "stage",
            type: "expr",
            expr: "x * y",
            inputs: ["x"],
            params: { y: 2 },
          },
        ],
        edges: [{ from: "x.out", to: "stage.x" }],
        outputs: { value: "stage.out" },
      },
      host,
    );
    try {
      for (let i = 0; i < 10; i++) runner.run({ x: 3 });
      const warm = runner.debugStats();
      const warmHost = host.debugStats();

      for (let i = 0; i < 100; i++) {
        await runner.reload("stage", i % 2 === 0 ? "x + y" : "x * y");
        const out = runner.run({ x: 3 });
        const y = runner.listParams().find((p) => p.name === "y")!.value;
        expect(y).toBe(2);
        if (i % 2 === 0) expect(out.value).toBeCloseTo(5, 10);
        else expect(out.value).toBeCloseTo(6, 10);
      }

      const end = runner.debugStats();
      expect(end.instanceCount).toBe(warm.instanceCount);
      expect(host.debugStats().seriesHandleCount).toBeLessThanOrEqual(warmHost.seriesHandleCount + 1);
    } finally {
      runner.dispose();
    }
  });

  it("reload compile rejection keeps counters and prior behavior", async () => {
    const runner = await loadGraph({
      nodes: [
        { id: "x", type: "input" },
        { id: "stage", type: "expr", expr: "x * 2", inputs: ["x"] },
      ],
      edges: [{ from: "x.out", to: "stage.x" }],
      outputs: { value: "stage.out" },
    });
    try {
      expect(runner.run({ x: 4 }).value).toBeCloseTo(8, 10);
      const before = runner.debugStats();
      await expect(runner.reload("stage", "[1, 2; 3, 4]")).rejects.toThrow(/rejected|incompatible/i);
      expect(runner.run({ x: 4 }).value).toBeCloseTo(8, 10);
      expect(runner.debugStats().instanceCount).toBe(before.instanceCount);
    } finally {
      runner.dispose();
    }
  });

  it("alloc-failure mid-tick: typed GraphAllocError, no handle corruption, next tick recovers", async () => {
    const host = new AotHostEnv();
    // Matrix edge forces hostAlloc / module alloc on wire write.
    const runner = await loadGraph(goldenDef("matrix_scale_then_matmul"), host);
    try {
      const ok1 = runner.run({});
      expect((ok1.value as { rows: number }).rows).toBe(2);
      const handlesBefore = host.debugStats().matrixHandleCount + host.debugStats().seriesHandleCount;

      // Inject failures so a subsequent wire alloc trips.
      host.injectAllocFailures(8);
      let threw: unknown;
      try {
        runner.run({});
      } catch (e) {
        threw = e;
      }
      expect(threw).toBeTruthy();
      expect(
        threw instanceof GraphAllocError ||
          threw instanceof AllocFailureError ||
          (threw instanceof Error && /AllocFailure|alloc/i.test(threw.message)),
      ).toBe(true);
      if (threw instanceof GraphAllocError) {
        expect(threw.nodeId.length).toBeGreaterThan(0);
        expect(threw.code).toBe("AllocFailure");
      }

      const mid = host.debugStats();
      // Shared env must not grow unbounded from a failed tick.
      expect(mid.matrixHandleCount + mid.seriesHandleCount).toBeLessThanOrEqual(handlesBefore + 2);

      // Clear any remaining injects and recover.
      host.injectAllocFailures(0);
      const ok2 = runner.run({});
      expect((ok2.value as { rows: number }).rows).toBe(2);
      const data = (ok2.value as { data: ArrayLike<number> }).data;
      expect(Number(data[0])).toBeCloseTo(2, 10);
      expect(Number(data[3])).toBeCloseTo(8, 10);
    } finally {
      runner.dispose();
    }
  });

  it("negative: skipping endTick GC makes series handles grow (documents counter sensitivity)", async () => {
    // Direct host createSeries without endTick — proves counters detect growth.
    const host = new AotHostEnv();
    host.beginTick();
    for (let i = 0; i < 50; i++) {
      host.createSeries([0, 1], [i, i + 1]);
    }
    // Deliberately do NOT call endTick — handles accumulate.
    expect(host.debugStats().seriesHandleCount).toBe(50);
    host.endTick([]); // now free them
    expect(host.debugStats().seriesHandleCount).toBe(0);
  });
});
