/**
 * Vite plugin middleware for Graph page:
 * - POST /api/aot_compile?params=N  body=expr → application/wasm
 * - POST /api/compile_graph          body=graph JSON → JSON { wasmBase64, graphJson, meta }
 *
 * Shells out to zig-out/bin/mathzig (or MATHZIG_BIN). Browser never imports
 * node:child_process / fused_compile — server-side only.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import type { Plugin, Connect } from "vite";
import type { IncomingMessage, ServerResponse } from "node:http";

export type CompileGraphMeta = {
  wasmBytes: number;
  outputCount: number;
  inputCount: number;
  paramCount: number;
  /** Number of declared wasm exports in the sidecar (usually the tick entry). */
  exportCount: number;
  outMode: string;
};

export type CompileGraphResult = {
  wasm: Uint8Array;
  graphJson: string;
  meta: CompileGraphMeta;
};

export type CompileGraphError = {
  status: number;
  message: string;
};

export function repoRootFromConfig(configRoot: string): string {
  // apps/console → repo root
  return path.resolve(configRoot, "../..");
}

export function mathzigBin(root: string): string {
  return process.env.MATHZIG_BIN
    ? path.resolve(process.env.MATHZIG_BIN)
    : path.resolve(root, "zig-out/bin/mathzig");
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function compileExpr(
  root: string,
  bin: string,
  cacheDir: string,
  expr: string,
  numParams: number,
): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const key = createHash("sha1").update(`${expr}|${numParams}`).digest("hex");
    const outFile = path.join(cacheDir, `${key}.wasm`);
    if (fs.existsSync(outFile)) {
      resolve(new Uint8Array(fs.readFileSync(outFile)));
      return;
    }
    if (!fs.existsSync(bin)) {
      reject(
        new Error(
          `mathzig binary missing: ${bin}\n` +
            `Build it first:\n` +
            `  export PATH="$PWD/tools/macos-sdk-shim:$PATH" && zig build`,
        ),
      );
      return;
    }
    fs.mkdirSync(cacheDir, { recursive: true });
    const inFile = path.join(cacheDir, `${key}.mz`);
    fs.writeFileSync(inFile, expr);
    const args = [bin, "compile", "-i", inFile, "-o", outFile];
    if (numParams > 0) args.push("-p", String(numParams));

    const child = spawn(args[0]!, args.slice(1), { cwd: root });
    let stderr = "";
    let stdout = "";
    child.stderr?.on("data", (d) => {
      stderr += String(d);
    });
    child.stdout?.on("data", (d) => {
      stdout += String(d);
    });
    child.on("error", (err) => reject(err));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`compile failed (exit ${code}):\n${stderr || stdout}`));
        return;
      }
      if (!fs.existsSync(outFile)) {
        reject(new Error(`compile produced no output: ${outFile}\n${stderr || stdout}`));
        return;
      }
      resolve(new Uint8Array(fs.readFileSync(outFile)));
    });
  });
}

/**
 * Shell `mathzig compile-graph` for a GraphDefinition JSON string.
 * Pure server helper — unit-testable without Vite.
 */
export function compileGraphDefinition(
  root: string,
  bin: string,
  graphJsonText: string,
  options: { outMode?: "table" | "named_exports" } = {},
): CompileGraphResult | CompileGraphError {
  if (!fs.existsSync(bin)) {
    return {
      status: 500,
      message:
        `mathzig binary missing: ${bin}\n` +
        `Build it first:\n` +
        `  export PATH="$PWD/tools/macos-sdk-shim:$PATH" && zig build`,
    };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(graphJsonText);
  } catch {
    return { status: 400, message: "invalid graph JSON: parse error" };
  }
  if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { status: 400, message: "invalid graph JSON: expected object" };
  }

  // Accept either raw GraphDefinition or { graph, outMode }.
  const body = parsed as Record<string, unknown>;
  let def: unknown = body;
  let outMode = options.outMode ?? "table";
  if (body.graph != null && typeof body.graph === "object") {
    def = body.graph;
    if (body.outMode === "table" || body.outMode === "named_exports") {
      outMode = body.outMode;
    }
  }
  if (options.outMode) outMode = options.outMode;

  const defObj = def as Record<string, unknown>;
  if (!Array.isArray(defObj.nodes)) {
    // EditorDocument shape: { definition, ui }
    if (
      defObj.definition != null &&
      typeof defObj.definition === "object" &&
      Array.isArray((defObj.definition as Record<string, unknown>).nodes)
    ) {
      def = defObj.definition;
    } else {
      return {
        status: 400,
        message: "invalid graph JSON: missing nodes array (GraphDefinition required)",
      };
    }
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mathzig-console-fuse-"));
  try {
    const inPath = path.join(tmp, "graph.json");
    const outPath = path.join(tmp, "out.wasm");
    fs.writeFileSync(inPath, JSON.stringify(def));

    const r = spawnSync(
      bin,
      ["compile-graph", "-i", inPath, "-o", outPath, "--out-mode", outMode],
      { encoding: "utf8", timeout: 120_000, cwd: root },
    );

    // Infrastructure: spawn could not run the binary (ENOENT, etc.).
    if (r.error) {
      return {
        status: 500,
        message: `compile-graph spawn failed: ${r.error.message}`,
      };
    }
    // Infrastructure: process killed (timeout / signal), not a graph rejection.
    if (r.signal) {
      return {
        status: 500,
        message: `compile-graph killed by signal ${r.signal}`,
      };
    }
    // Non-zero CLI exit = graph/input/compile problem → always 4xx.
    // Do not parse stderr for status (avoids over-classifying internal lines as 400
    // via bare "error:" and under-classifying "Error compiling node …" as 500).
    if (r.status !== 0) {
      const detail = (r.stderr || r.stdout || "").trim() || `exit ${r.status}`;
      return { status: 400, message: detail };
    }
    if (!fs.existsSync(outPath)) {
      return { status: 500, message: "compile-graph exited 0 but output wasm missing" };
    }

    const wasm = new Uint8Array(fs.readFileSync(outPath));
    const sidecarPath = outPath.replace(/\.wasm$/, ".graph.json");
    if (!fs.existsSync(sidecarPath)) {
      return { status: 500, message: "compile-graph produced no .graph.json sidecar" };
    }
    const graphJson = fs.readFileSync(sidecarPath, "utf8");

    let meta: CompileGraphMeta = {
      wasmBytes: wasm.byteLength,
      outputCount: 0,
      inputCount: 0,
      paramCount: 0,
      exportCount: 0,
      outMode,
    };
    try {
      const side = JSON.parse(graphJson) as {
        outputs?: unknown[];
        inputs?: unknown[];
        params?: unknown[];
        exports?: unknown[];
      };
      meta = {
        wasmBytes: wasm.byteLength,
        outputCount: Array.isArray(side.outputs) ? side.outputs.length : 0,
        inputCount: Array.isArray(side.inputs) ? side.inputs.length : 0,
        paramCount: Array.isArray(side.params) ? side.params.length : 0,
        exportCount: Array.isArray(side.exports) ? side.exports.length : 0,
        outMode,
      };
    } catch {
      // keep defaults
    }

    return { wasm, graphJson, meta };
  } finally {
    try {
      fs.rmSync(tmp, { recursive: true, force: true });
    } catch {
      // best-effort
    }
  }
}

/**
 * Status policy for compile-graph failures:
 * - **400** — non-zero CLI exit (invalid graph, unsupported nodes, bad expr, …)
 * - **500** — infrastructure only (missing binary, spawn error, signal, missing artifacts)
 *
 * Kept for tests / docs; callers should prefer the structured result from
 * {@link compileGraphDefinition} rather than re-classifying stderr strings.
 */
export function isInfrastructureCompileFailure(message: string): boolean {
  const m = message.toLowerCase();
  return (
    m.includes("mathzig binary missing") ||
    m.includes("spawn failed") ||
    m.includes("killed by signal") ||
    m.includes("output wasm missing") ||
    m.includes("no .graph.json sidecar")
  );
}

/** @deprecated Use status policy: non-zero CLI → 400; use {@link isInfrastructureCompileFailure}. */
export function isClientCompileError(message: string): boolean {
  return !isInfrastructureCompileFailure(message);
}

function uint8ToBase64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64");
}

/** Connect handler for /api/aot_compile and /api/compile_graph (exported for tests). */
export function makeCompileApiHandler(root: string): Connect.NextHandleFunction {
  const bin = mathzigBin(root);
  const cacheDir = path.join(root, "tests/artifacts/wasm_aot_console");

  return (req, res, next) => {
    const url = req.url ?? "";

    if (url.startsWith("/api/compile_graph") && req.method === "POST") {
      void (async () => {
        try {
          const body = await readBody(req);
          if (!body.trim()) {
            sendText(res, 400, "empty body: expected GraphDefinition JSON");
            return;
          }
          const result = compileGraphDefinition(root, bin, body);
          if ("status" in result && "message" in result && !("wasm" in result)) {
            sendText(res, result.status, result.message);
            return;
          }
          const ok = result as CompileGraphResult;
          res.statusCode = 200;
          res.setHeader("content-type", "application/json; charset=utf-8");
          res.setHeader("cache-control", "no-store");
          res.end(
            JSON.stringify({
              wasmBase64: uint8ToBase64(ok.wasm),
              graphJson: ok.graphJson,
              meta: ok.meta,
            }),
          );
        } catch (e) {
          sendText(res, 500, String((e as Error)?.message ?? e));
        }
      })();
      return;
    }

    if (!url.startsWith("/api/aot_compile") || req.method !== "POST") {
      next();
      return;
    }

    void (async () => {
      try {
        const u = new URL(url, "http://localhost");
        const params = Number(u.searchParams.get("params") || "0");
        if (!Number.isFinite(params) || params < 0 || params > 16) {
          sendText(res, 400, "invalid params");
          return;
        }
        const expr = await readBody(req);
        if (!expr.trim()) {
          sendText(res, 400, "empty expr");
          return;
        }
        const bytes = await compileExpr(root, bin, cacheDir, expr, params);
        res.statusCode = 200;
        res.setHeader("content-type", "application/wasm");
        res.setHeader("cache-control", "no-store");
        res.end(Buffer.from(bytes));
      } catch (e) {
        sendText(res, 500, String((e as Error)?.message ?? e));
      }
    })();
  };
}

function sendText(res: ServerResponse, status: number, body: string) {
  res.statusCode = status;
  res.setHeader("content-type", "text/plain; charset=utf-8");
  res.end(body);
}

export function aotCompilePlugin(): Plugin {
  let root = process.cwd();
  return {
    name: "mathzig-aot-compile-api",
    configResolved(config) {
      root = repoRootFromConfig(config.root);
    },
    configureServer(server) {
      server.middlewares.use(makeCompileApiHandler(root));
    },
    configurePreviewServer(server) {
      server.middlewares.use(makeCompileApiHandler(root));
    },
  };
}
