/**
 * Spec 05 — `mathzig compile-graph` CLI integration (T1–T5).
 *
 * Compiles fixtures via the native binary, checks sidecar, runs through
 * FusedGraphRunner, and asserts error exits for bad JSON / cycle / wasm nodes.
 */
import { describe, expect, it, beforeAll } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { compileAot } from "../../parity/wasm_aot";
import {
  FusedGraphRunner,
  GraphRunner,
  createDefaultScalarWasmImports,
  graphValuesEqual,
  readGraphManifest,
  type GraphDefinition,
} from "../../../src/ts/graph";
import { compileFused } from "../../../src/ts/graph/node";

const ROOT = path.resolve(import.meta.dir, "../../..");
const MATHZIG = path.join(ROOT, "zig-out/bin/mathzig");
const FIXTURES = path.join(ROOT, "tests/fixtures/graph");

function ensureBinary() {
  if (fs.existsSync(MATHZIG)) return;
  const r = spawnSync("zig", ["build"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 300_000,
  });
  if (r.status !== 0) {
    throw new Error(`zig build failed\n${r.stdout}\n${r.stderr}`);
  }
}

function compileGraph(
  input: string,
  output: string,
  extra: string[] = [],
): { status: number | null; stdout: string; stderr: string } {
  const r = spawnSync(
    MATHZIG,
    ["compile-graph", "-i", input, "-o", output, ...extra],
    { cwd: ROOT, encoding: "utf8", timeout: 60_000 },
  );
  return {
    status: r.status,
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
  };
}

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

const compiler = {
  async compile(expr: string, numParams: number): Promise<Uint8Array> {
    const { wasmBytes } = await compileAot(expr, numParams);
    return wasmBytes;
  },
};

describe("mathzig compile-graph (Spec 05)", () => {
  let tmpDir: string;

  beforeAll(() => {
    ensureBinary();
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "fuse-cli-"));
  });

  // T1 — compile fixture, exit 0, non-empty wasm
  it("T1: compile-graph scalar_chain → non-empty wasm", () => {
    const out = path.join(tmpDir, "t1.wasm");
    const r = compileGraph(path.join(FIXTURES, "scalar_chain.json"), out);
    expect(r.status, `stderr: ${r.stderr}\nstdout: ${r.stdout}`).toBe(0);
    expect(fs.existsSync(out)).toBe(true);
    const st = fs.statSync(out);
    expect(st.size).toBeGreaterThan(0);
  });

  // T2 — sidecar exists and matches custom section (bit-identical + field equal)
  it("T2: sidecar exists and matches mathzig:graph section", () => {
    const out = path.join(tmpDir, "t2.wasm");
    const r = compileGraph(path.join(FIXTURES, "scalar_chain.json"), out, [
      "--out-mode",
      "named_exports",
    ]);
    expect(r.status, r.stderr).toBe(0);
    const sidecar = out.replace(/\.wasm$/, ".graph.json");
    expect(fs.existsSync(sidecar)).toBe(true);

    const wasmBytes = new Uint8Array(fs.readFileSync(out));
    const module = new WebAssembly.Module(wasmBytes);
    const sections = WebAssembly.Module.customSections(module, "mathzig:graph");
    expect(sections.length).toBeGreaterThan(0);
    const sectionText = new TextDecoder().decode(sections[0]);
    const sidecarText = fs.readFileSync(sidecar, "utf8");
    // Spec 05: sidecar payload == custom-section bytes
    expect(sidecarText).toBe(sectionText);

    const fromSection = readGraphManifest(module);
    expect(fromSection).not.toBeNull();
    const fromSidecar = JSON.parse(sidecarText);
    // Full field equality (names, kinds, exports, …)
    expect(fromSidecar).toEqual(fromSection);
    expect(fromSection!.outputs.length).toBe(1);
    expect(fromSection!.outputs[0]!.name).toBe("y");
  });

  // T3 — run fused module; outs match multi-module
  it("T3: fused CLI module values match multi-module GraphRunner", async () => {
    const out = path.join(tmpDir, "t3.wasm");
    const r = compileGraph(path.join(FIXTURES, "scalar_chain.json"), out, [
      "--out-mode",
      "named_exports",
    ]);
    expect(r.status, r.stderr).toBe(0);

    const multi = await GraphRunner.load(chainDef, {
      compiler,
      env: createDefaultScalarWasmImports(),
    });
    const multiOut = await multi.run({ x: 3 });

    const fused = await FusedGraphRunner.load(new Uint8Array(fs.readFileSync(out)), {
      env: createDefaultScalarWasmImports(),
    });
    const fusedOut = fused.run({ x: 3 });

    expect(graphValuesEqual(fusedOut.y as number, multiOut.y as number)).toBe(true);
    expect(fusedOut.y).toBe(7);
    fused.dispose();
    multi.dispose();
  });

  // T4 — bad JSON / cycle → non-zero + stderr message
  it("T4: bad JSON and cycle → non-zero exit with message", () => {
    const bad = path.join(tmpDir, "bad.json");
    fs.writeFileSync(bad, "{ not valid");
    const rBad = compileGraph(bad, path.join(tmpDir, "bad.wasm"));
    expect(rBad.status).not.toBe(0);
    expect(rBad.stderr + rBad.stdout).toMatch(/invalid graph JSON|SyntaxError/i);

    const rCycle = compileGraph(
      path.join(FIXTURES, "scalar_cycle.json"),
      path.join(tmpDir, "cycle.wasm"),
    );
    expect(rCycle.status).not.toBe(0);
    expect(rCycle.stderr + rCycle.stdout).toMatch(/cycle/i);
  });

  // T5 — wasm-only node rejected
  it("T5: wasm-only graph → non-zero with clear error", () => {
    const r = compileGraph(
      path.join(FIXTURES, "wasm_only.json"),
      path.join(tmpDir, "wasm.wasm"),
    );
    expect(r.status).not.toBe(0);
    const msg = r.stderr + r.stdout;
    expect(msg).toMatch(/does not support wasm nodes/i);
  });

  // Free-var typo must hard-error (not silently compile as 0)
  it("rejects node expr free vars not in declared inputs/params", () => {
    const graph = path.join(tmpDir, "freevar.json");
    fs.writeFileSync(
      graph,
      JSON.stringify({
        nodes: [
          { id: "x", type: "input" },
          { id: "n", type: "expr", expr: "x + undeclared", inputs: ["x"] },
        ],
        edges: [{ from: "x.out", to: "n.x" }],
        outputs: { y: "n.out" },
      }),
    );
    const r = compileGraph(graph, path.join(tmpDir, "freevar.wasm"));
    expect(r.status).not.toBe(0);
    expect(r.stderr + r.stdout).toMatch(/undeclared port 'undeclared'/i);
  });

  // compileFused prefers CLI when binary is available
  it("compileFused shells to compile-graph for arbitrary graphs", async () => {
    const bytes = await compileFused(
      {
        nodes: [
          { id: "x", type: "input" },
          { id: "dbl", type: "expr", expr: "x + x", inputs: ["x"] },
        ],
        edges: [{ from: "x.out", to: "dbl.x" }],
        outputs: { y: "dbl.out" },
      },
      undefined,
      { outMode: "named_exports" },
    );
    expect(bytes.byteLength).toBeGreaterThan(0);
    const fused = await FusedGraphRunner.load(bytes, {
      env: createDefaultScalarWasmImports(),
    });
    expect(fused.run({ x: 4 }).y).toBe(8);
    fused.dispose();
  });
});
