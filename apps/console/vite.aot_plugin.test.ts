/**
 * Spec 06 — middleware compile-graph helpers (T1–T3) + HTTP smoke.
 *
 * Tests `compileGraphDefinition` and `makeCompileApiHandler`. Requires
 * zig-out/bin/mathzig (builds if missing, same as fused_cli tests).
 */
import { describe, expect, it, beforeAll } from "bun:test";
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import {
  compileGraphDefinition,
  isInfrastructureCompileFailure,
  makeCompileApiHandler,
  mathzigBin,
  type CompileGraphResult,
} from "./vite.aot_plugin.ts";
import {
  FusedGraphRunner,
  GraphRunner,
  createDefaultScalarWasmImports,
  graphValuesEqual,
  type GraphDefinition,
} from "../../src/ts/graph";
import { compileAot } from "../../tests/parity/wasm_aot";

const ROOT = path.resolve(import.meta.dir, "../..");
const FIXTURES = path.join(ROOT, "tests/fixtures/graph");

function ensureBinary() {
  const bin = mathzigBin(ROOT);
  if (fs.existsSync(bin)) return bin;
  const env = {
    ...process.env,
    PATH: `${path.join(ROOT, "tools/macos-sdk-shim")}${path.delimiter}${process.env.PATH ?? ""}`,
  };
  const r = spawnSync("zig", ["build"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 300_000,
    env,
  });
  if (r.status !== 0) {
    throw new Error(`zig build failed\n${r.stdout}\n${r.stderr}`);
  }
  if (!fs.existsSync(bin)) {
    throw new Error(`zig build succeeded but binary missing: ${bin}`);
  }
  return bin;
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

const paramsDef: GraphDefinition = {
  nodes: [
    { id: "x", type: "input" },
    { id: "gain", type: "expr", expr: "x * k", inputs: ["x"], params: { k: 1 } },
  ],
  edges: [{ from: "x.out", to: "gain.x" }],
  outputs: { y: "gain.out" },
};

function postJson(
  handler: ReturnType<typeof makeCompileApiHandler>,
  url: string,
  body: string,
): Promise<{ status: number; headers: http.IncomingHttpHeaders; body: string }> {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      handler(req, res, () => {
        res.statusCode = 404;
        res.end("not found");
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        server.close();
        reject(new Error("no listen address"));
        return;
      }
      const req = http.request(
        {
          host: "127.0.0.1",
          port: addr.port,
          path: url,
          method: "POST",
          headers: {
            "content-type": "application/json",
            "content-length": Buffer.byteLength(body),
          },
        },
        (res) => {
          const chunks: Buffer[] = [];
          res.on("data", (c) => chunks.push(c));
          res.on("end", () => {
            server.close();
            resolve({
              status: res.statusCode ?? 0,
              headers: res.headers,
              body: Buffer.concat(chunks).toString("utf8"),
            });
          });
        },
      );
      req.on("error", (e) => {
        server.close();
        reject(e);
      });
      req.write(body);
      req.end();
    });
  });
}

describe("POST /api/compile_graph helpers (Spec 06)", () => {
  let bin: string;

  beforeAll(() => {
    bin = ensureBinary();
  });

  // T1 — fixture compile → wasm bytes
  it("T1: compile-graph fixture returns wasm + sidecar meta", () => {
    const text = fs.readFileSync(path.join(FIXTURES, "scalar_chain.json"), "utf8");
    const result = compileGraphDefinition(ROOT, bin, text);
    expect("wasm" in result, JSON.stringify(result)).toBe(true);
    const ok = result as CompileGraphResult;
    expect(ok.wasm.byteLength).toBeGreaterThan(0);
    expect(ok.graphJson.length).toBeGreaterThan(0);
    expect(ok.meta.outputCount).toBe(1);
    expect(ok.meta.wasmBytes).toBe(ok.wasm.byteLength);
    expect(ok.meta.outMode).toBe("table");
    // Sidecar has exports, not nodes — exportCount reflects exports.
    expect(ok.meta.exportCount).toBeGreaterThanOrEqual(1);

    const side = JSON.parse(ok.graphJson);
    expect(Array.isArray(side.outputs)).toBe(true);
    expect(side.outputs[0].name).toBe("y");
  });

  it("T1b: envelope { graph, outMode } works", () => {
    const result = compileGraphDefinition(
      ROOT,
      bin,
      JSON.stringify({ graph: chainDef, outMode: "named_exports" }),
    );
    expect("wasm" in result).toBe(true);
    const ok = result as CompileGraphResult;
    expect(ok.meta.outMode).toBe("named_exports");
    expect(ok.wasm.byteLength).toBeGreaterThan(0);
  });

  // T2 — unsupported graph → 4xx + reason
  it("T2: wasm-only graph → 400 + wasm nodes message", () => {
    const text = fs.readFileSync(path.join(FIXTURES, "wasm_only.json"), "utf8");
    const result = compileGraphDefinition(ROOT, bin, text);
    expect("status" in result && !("wasm" in result)).toBe(true);
    if ("status" in result && !("wasm" in result)) {
      expect(result.status).toBe(400);
      expect(result.message).toMatch(/does not support wasm nodes/i);
    }
  });

  it("T2b: invalid JSON → 400", () => {
    const result = compileGraphDefinition(ROOT, bin, "{ not json");
    expect("status" in result && !("wasm" in result)).toBe(true);
    if ("status" in result && !("wasm" in result)) {
      expect(result.status).toBe(400);
      expect(result.message).toMatch(/invalid graph json/i);
    }
  });

  // T2c — bad expr is a client graph problem, not infrastructure 500
  it("T2c: bad node expr → 400 (not 500)", () => {
    const bad: GraphDefinition = {
      nodes: [
        { id: "x", type: "input" },
        { id: "y", type: "expr", expr: "x + *", inputs: ["x"] },
      ],
      edges: [{ from: "x.out", to: "y.x" }],
      outputs: { out: "y.out" },
    };
    const result = compileGraphDefinition(ROOT, bin, JSON.stringify(bad));
    expect("status" in result && !("wasm" in result)).toBe(true);
    if ("status" in result && !("wasm" in result)) {
      expect(result.status).toBe(400);
      expect(result.message.length).toBeGreaterThan(0);
      // Typical CLI: "Error compiling node 'y': …"
      expect(result.message.toLowerCase()).toMatch(/compil|unexpected|error|syntax|token|parse/);
    }
  });

  it("status policy: infrastructure messages vs client", () => {
    expect(isInfrastructureCompileFailure("mathzig binary missing: /nope")).toBe(true);
    expect(isInfrastructureCompileFailure("compile-graph spawn failed: ENOENT")).toBe(true);
    expect(isInfrastructureCompileFailure("Error compiling node 'y': Unexpected token")).toBe(
      false,
    );
    expect(
      isInfrastructureCompileFailure("Error: Fuse v1 does not support wasm nodes"),
    ).toBe(false);
    // Internal CLI Error: lines are still non-zero CLI → 400 when returned from compile;
    // the helper must not treat them as infrastructure just because they contain "error:".
    expect(
      isInfrastructureCompileFailure(
        "Error: fused module missing mathzig:graph custom section",
      ),
    ).toBe(false);
  });

  // T3 — product default outMode table; values ≡ multi-module
  it("T3: table-mode export artifact matches multi-module GraphRunner values", async () => {
    const result = compileGraphDefinition(
      ROOT,
      bin,
      JSON.stringify({ graph: chainDef }), // default outMode = table
    );
    expect("wasm" in result).toBe(true);
    const ok = result as CompileGraphResult;
    expect(ok.meta.outMode).toBe("table");

    const compiler = {
      async compile(expr: string, numParams: number): Promise<Uint8Array> {
        const { wasmBytes } = await compileAot(expr, numParams);
        return wasmBytes;
      },
    };
    const multi = await GraphRunner.load(chainDef, {
      compiler,
      env: createDefaultScalarWasmImports(),
    });
    const multiOut = await multi.run({ x: 3 });

    const fused = await FusedGraphRunner.load(ok.wasm, {
      env: createDefaultScalarWasmImports(),
    });
    const fusedOut = fused.run({ x: 3 });

    expect(graphValuesEqual(fusedOut.y as number, multiOut.y as number)).toBe(true);
    expect(fusedOut.y).toBe(7);
    fused.dispose();
    multi.dispose();
  });

  // T4 — params are runtime args (no re-export needed for multi path; fused setParam)
  it("T4: fused param change without recompile; multi setParam without re-export", async () => {
    const result = compileGraphDefinition(
      ROOT,
      bin,
      JSON.stringify({ graph: paramsDef }),
    );
    expect("wasm" in result).toBe(true);
    const ok = result as CompileGraphResult;

    const fused = await FusedGraphRunner.load(ok.wasm, {
      env: createDefaultScalarWasmImports(),
    });
    expect(fused.run({ x: 2 }).y).toBe(2); // default k=1
    fused.setParam("gain.k", 3);
    expect(fused.run({ x: 2 }).y).toBe(6);
    fused.dispose();

    // Multi path: param change does not require re-export of fused artifact.
    const compiler = {
      async compile(expr: string, numParams: number): Promise<Uint8Array> {
        const { wasmBytes } = await compileAot(expr, numParams);
        return wasmBytes;
      },
    };
    const multi = await GraphRunner.load(paramsDef, {
      compiler,
      env: createDefaultScalarWasmImports(),
    });
    multi.setParam("gain", "k", 4);
    const multiOut = await multi.run({ x: 2 });
    expect(multiOut.y).toBe(8);
    multi.dispose();
  });

  // HTTP middleware path (T1 API wording)
  it("HTTP: POST /api/compile_graph returns 200 JSON envelope", async () => {
    const handler = makeCompileApiHandler(ROOT);
    const res = await postJson(handler, "/api/compile_graph", JSON.stringify(chainDef));
    expect(res.status).toBe(200);
    expect(String(res.headers["content-type"] ?? "")).toMatch(/application\/json/);
    const json = JSON.parse(res.body) as {
      wasmBase64: string;
      graphJson: string;
      meta: { outputCount: number; outMode: string };
    };
    expect(json.wasmBase64.length).toBeGreaterThan(0);
    expect(json.graphJson.length).toBeGreaterThan(0);
    expect(json.meta.outputCount).toBe(1);
    expect(json.meta.outMode).toBe("table");
    // Round-trip base64 → wasm
    const wasm = Buffer.from(json.wasmBase64, "base64");
    expect(wasm.byteLength).toBeGreaterThan(0);
  });

  it("HTTP: unsupported graph → 400 text body", async () => {
    const handler = makeCompileApiHandler(ROOT);
    const text = fs.readFileSync(path.join(FIXTURES, "wasm_only.json"), "utf8");
    const res = await postJson(handler, "/api/compile_graph", text);
    expect(res.status).toBe(400);
    expect(res.body).toMatch(/does not support wasm nodes/i);
  });
});
