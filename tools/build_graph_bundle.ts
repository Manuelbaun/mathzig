#!/usr/bin/env bun
/**
 * Bundle `src/ts/graph` for the browser demo (shared with bun — no code fork).
 *
 * Usage: bun tools/build_graph_bundle.ts
 * Output: web/graph_bundle.js
 *
 * Stubs bun:ffi / MathZig FFI so the scalar demo path loads in browsers.
 * Full-Value delegated builtins need a native host (bun tests / parity).
 */
import * as path from "node:path";
import * as fs from "node:fs";

const root = path.resolve(import.meta.dir, "..");
const entry = path.join(root, "web/graph_entry.ts");
const outfile = path.join(root, "web/graph_bundle.js");

const MATHZIG_STUB = `
export class MathZig {
  static create() {
    return new MathZig();
  }
  static allocAligned(_align, size, _backend) {
    return 0;
  }
  handle = 0;
  backend = {
    call() { return 0; },
    ptr(x) { return x; },
    toArrayBuffer(_p, n) { return new ArrayBuffer(n || 0); },
    readString() { return ""; },
  };
  resetMemory() {}
  createSeries() { return 0; }
}
export const SampleMode = { Step: 0, Linear: 1, Cumulative: 2 };
export const ValueTag = { Number: 0 };
export const ptr = (x) => x;
export const toArrayBuffer = () => new ArrayBuffer(0);
`;

const FFI_STUB = `
export const ptr = (x) => x;
export const toArrayBuffer = () => new ArrayBuffer(0);
export const dlopen = () => ({ symbols: {} });
export const suffix = "";
export const CString = class {};
export const JSCallback = class {};
export const linkSymbols = () => ({});
export const viewSource = () => "";
`;

const LOADER_STUB = `
export function getLibPath() { return ""; }
export function loadNative() { return {}; }
`;

const FFI_BACKEND_STUB = `
export class FFIBackend {
  constructor() {}
  call() { return 0; }
  ptr(x) { return x; }
  toArrayBuffer(_p, n) { return new ArrayBuffer(n || 0); }
  readString() { return ""; }
}
`;

const result = await Bun.build({
  entrypoints: [entry],
  outfile,
  target: "browser",
  format: "esm",
  sourcemap: "none",
  minify: false,
  plugins: [
    {
      name: "browser-native-stubs",
      setup(build) {
        build.onResolve({ filter: /.*/ }, (args) => {
          const p = args.path;
          if (p === "bun:ffi") {
            return { path: "stub:bun-ffi", namespace: "mz-stub" };
          }
          // aot_env imports "./mathzig"
          if (p === "./mathzig" || p === "../mathzig" || p.endsWith("/mathzig") || p.endsWith("/mathzig.ts")) {
            return { path: "stub:mathzig", namespace: "mz-stub" };
          }
          if (p === "../bindings/generated/loader" || p.endsWith("/generated/loader") || p === "./loader") {
            // Only stub the real loader that pulls bun:ffi; keep aot_env generated stubs.
            if (args.importer.includes("mathzig") || args.importer.includes("ffi_backend")) {
              return { path: "stub:loader", namespace: "mz-stub" };
            }
          }
          if (
            p === "../bindings/generated/ffi_backend" ||
            p.endsWith("/generated/ffi_backend") ||
            p === "./ffi_backend"
          ) {
            return { path: "stub:ffi-backend", namespace: "mz-stub" };
          }
          return null;
        });

        build.onLoad({ filter: /.*/, namespace: "mz-stub" }, (args) => {
          if (args.path === "stub:bun-ffi") {
            return { contents: FFI_STUB, loader: "js" };
          }
          if (args.path === "stub:mathzig") {
            return { contents: MATHZIG_STUB, loader: "js" };
          }
          if (args.path === "stub:loader") {
            return { contents: LOADER_STUB, loader: "js" };
          }
          if (args.path === "stub:ffi-backend") {
            return { contents: FFI_BACKEND_STUB, loader: "js" };
          }
          return { contents: "export {}", loader: "js" };
        });
      },
    },
  ],
});

if (!result.success) {
  console.error("graph bundle failed:");
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

// Bun may write to outfile or only fill result.outputs depending on version.
if (!fs.existsSync(outfile) || fs.statSync(outfile).size === 0) {
  const out = result.outputs?.find((o) => o.kind === "entry-point" || o.path.endsWith(".js"));
  if (out) {
    const text = await out.text();
    fs.writeFileSync(outfile, text);
  }
}

const size = fs.existsSync(outfile) ? fs.statSync(outfile).size : 0;
if (size === 0) {
  console.error("graph bundle is empty");
  console.error("outputs:", result.outputs?.map((o) => ({ path: o.path, size: o.size, kind: o.kind })));
  process.exit(1);
}
console.log(`Wrote ${path.relative(root, outfile)} (${size} bytes)`);
