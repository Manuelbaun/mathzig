#!/usr/bin/env bun
/**
 * Demo server for web/graph_demo.html
 *
 * - Serves web/ (and rebuilds graph_bundle.js if missing)
 * - POST /api/aot_compile?params=N  body=expr  → application/wasm
 *
 * Usage:
 *   export PATH="$PWD/tools/macos-sdk-shim:$PATH"
 *   zig build          # ensure zig-out/bin/mathzig exists
 *   bun tools/build_graph_bundle.ts
 *   bun web/graph_demo_server.ts
 *   open http://localhost:8787/graph_demo.html
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";

const root = path.resolve(import.meta.dir, "..");
const webDir = path.join(root, "web");
const port = Number(process.env.PORT || 8787);
const bin = process.env.MATHZIG_BIN
  ? path.resolve(process.env.MATHZIG_BIN)
  : path.resolve(root, "zig-out/bin/mathzig");
const cacheDir = path.join(root, "tests/artifacts/wasm_aot_demo");
fs.mkdirSync(cacheDir, { recursive: true });

const bundlePath = path.join(webDir, "graph_bundle.js");
if (!fs.existsSync(bundlePath)) {
  console.log("Building graph_bundle.js…");
  const build = Bun.spawnSync({
    cmd: ["bun", path.join(root, "tools/build_graph_bundle.ts")],
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });
  if (build.exitCode !== 0) {
    console.error("Failed to build graph_bundle.js");
    process.exit(1);
  }
}

if (!fs.existsSync(bin)) {
  console.warn(`Warning: mathzig binary not found at ${bin}`);
  console.warn("Run: export PATH=\"$PWD/tools/macos-sdk-shim:$PATH\" && zig build");
}

async function compileExpr(expr: string, numParams: number): Promise<Uint8Array> {
  const key = createHash("sha1").update(`${expr}|${numParams}`).digest("hex");
  const outFile = path.join(cacheDir, `${key}.wasm`);
  if (fs.existsSync(outFile)) {
    return new Uint8Array(fs.readFileSync(outFile));
  }
  if (!fs.existsSync(bin)) {
    throw new Error(`mathzig binary missing: ${bin}`);
  }
  const inFile = path.join(cacheDir, `${key}.mz`);
  fs.writeFileSync(inFile, expr);
  const args = [bin, "compile", "-i", inFile, "-o", outFile];
  if (numParams > 0) args.push("-p", String(numParams));
  const proc = Bun.spawn(args, { stdout: "pipe", stderr: "pipe", cwd: root });
  const code = await proc.exited;
  const stderr = await new Response(proc.stderr).text();
  const stdout = await new Response(proc.stdout).text();
  if (code !== 0) {
    throw new Error(`compile failed (exit ${code}):\n${stderr || stdout}`);
  }
  return new Uint8Array(fs.readFileSync(outFile));
}

function contentType(filePath: string): string {
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  if (filePath.endsWith(".wasm")) return "application/wasm";
  if (filePath.endsWith(".json")) return "application/json";
  if (filePath.endsWith(".svg")) return "image/svg+xml";
  return "application/octet-stream";
}

const server = Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/api/aot_compile" && req.method === "POST") {
      try {
        const params = Number(url.searchParams.get("params") || "0");
        if (!Number.isFinite(params) || params < 0 || params > 16) {
          return new Response("invalid params", { status: 400 });
        }
        const expr = await req.text();
        if (!expr.trim()) return new Response("empty expr", { status: 400 });
        const bytes = await compileExpr(expr, params);
        return new Response(bytes, {
          headers: {
            "content-type": "application/wasm",
            "cache-control": "no-store",
          },
        });
      } catch (e) {
        return new Response(String((e as Error)?.message ?? e), { status: 500 });
      }
    }

    let rel = url.pathname === "/" ? "/graph_demo.html" : url.pathname;
    // Prevent path escape
    rel = path.normalize(rel).replace(/^(\.\.(\/|\\|$))+/, "");
    const filePath = path.join(webDir, rel);
    if (!filePath.startsWith(webDir)) {
      return new Response("forbidden", { status: 403 });
    }
    if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      return new Response("not found", { status: 404 });
    }
    const data = fs.readFileSync(filePath);
    return new Response(data, {
      headers: {
        "content-type": contentType(filePath),
        "cache-control": "no-cache",
      },
    });
  },
});

console.log(`Graph demo: http://localhost:${server.port}/graph_demo.html`);
console.log(`Compile API: POST http://localhost:${server.port}/api/aot_compile?params=N`);
