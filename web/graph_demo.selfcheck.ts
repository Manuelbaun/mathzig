#!/usr/bin/env bun
/**
 * Headless selfcheck for task-09 graph demo controller + GraphRunner.reload/setParam.
 * Exercises graph_controller logic in bun (no playwright).
 */
import { compileAot } from "../tests/parity/wasm_aot";
import {
  GraphRunner,
  createDefaultScalarWasmImports,
} from "../src/ts/graph";
import {
  createGraphController,
  paramSliderRange,
  formatGraphValue,
  EXAMPLE_GRAPH,
} from "./graph_controller.js";

const compiler = {
  version: "selfcheck",
  async compile(expr: string, numParams: number) {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
};

let failed = 0;
function check(name: string, cond: boolean, detail = "") {
  if (cond) {
    console.log(`  ok  ${name}`);
  } else {
    failed++;
    console.error(`  FAIL ${name}${detail ? " — " + detail : ""}`);
  }
}

console.log("graph_demo.selfcheck");

// ── slider heuristic ─────────────────────────────────────────────────────
{
  const r01 = paramSliderRange(0.2);
  check("slider [0,1] min0", r01.min === 0 && r01.max === 1);
  const r5 = paramSliderRange(5);
  check("slider (1,10] max=2d", r5.max === 10 && r5.min === 0);
  const r100 = paramSliderRange(100);
  check("slider large span", r100.min < 100 && r100.max > 100);
}

// ── format values ────────────────────────────────────────────────────────
{
  const n = formatGraphValue(3.5);
  check("format number", n.kind === "number" && n.text.includes("3.5"));
  const m = formatGraphValue({ rows: 1, cols: 2, data: [1, 2] });
  check("format matrix table", m.kind === "matrix" && m.html.includes("<table"));
  const s = formatGraphValue({ timestamps: [0, 1], values: [10, 20] });
  check("format series len+last", s.kind === "series" && s.text.includes("len=2") && s.text.includes("20"));
}

// ── controller load + tick + setParam ────────────────────────────────────
{
  const ctl = createGraphController({
    GraphRunner,
    createDefaultScalarWasmImports,
    compiler,
  });

  const loaded = await ctl.load(EXAMPLE_GRAPH as any);
  check("load example", loaded.ok === true, loaded.ok ? "" : (loaded as any).error);
  if (loaded.ok) {
    check("params from manifests", loaded.params.some((p) => p.name === "a" || p.name === "g"));
    check("inputs include source", loaded.inputs.includes("source"));

    ctl.setInput("source", 10);
    const out1 = ctl.tick();
    check("tick yields numbers", typeof out1.value === "number" && typeof out1.filtered === "number");

    const before = out1.value as number;
    ctl.setParam("gain", "g", 3);
    const out2 = ctl.tick();
    check("setParam changes next tick", (out2.value as number) !== before || before === 0);

    try {
      ctl.setParam("gain", "nope", 1);
      check("setParam unknown errors", false);
    } catch (e) {
      check("setParam unknown errors", /no param/i.test(String((e as Error).message)));
    }

    // Compatible reload on gain: x * g → x + g
    await ctl.reload("gain", "x + g");
    ctl.setParam("gain", "g", 1);
    ctl.setInput("source", 4);
    // lowpass with a=0.2, prev=0: filtered = 4*0.2 + 0 = 0.8; gain: 0.8+1 = 1.8
    const out3 = ctl.tick();
    check(
      "reload compatible swaps behavior",
      Math.abs((out3.value as number) - 1.8) < 1e-9,
      `got ${out3.value}`,
    );

    // Incompatible reload: keep running
    let rejected = false;
    try {
      await ctl.reload("gain", "[1, 2; 3, 4]");
    } catch {
      rejected = true;
    }
    check("reload incompatible rejects", rejected);
    const out4 = ctl.tick();
    check(
      "reload reject keeps old node",
      Math.abs((out4.value as number) - 1.8) < 1e-9,
      `got ${out4.value}`,
    );
  }

  ctl.dispose();
}

// ── bad JSON ─────────────────────────────────────────────────────────────
{
  const ctl = createGraphController({
    GraphRunner,
    createDefaultScalarWasmImports,
    compiler,
  });
  const bad = await ctl.loadJson("{not json");
  check("bad JSON inline error", bad.ok === false && /JSON parse/i.test((bad as any).error));
  const cycle = await ctl.loadJson(
    JSON.stringify({
      nodes: [
        { id: "a", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "b", type: "expr", expr: "x * 2", inputs: ["x"] },
      ],
      edges: [
        { from: "a.out", to: "b.x" },
        { from: "b.out", to: "a.x" },
      ],
      outputs: { value: "b.out" },
    }),
  );
  check("cycle load error", cycle.ok === false && /cycle/i.test((cycle as any).error));
  ctl.dispose();
}

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nall selfcheck passed");
