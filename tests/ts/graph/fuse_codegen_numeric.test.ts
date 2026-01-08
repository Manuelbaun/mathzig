/**
 * Spec 03 — numeric goldens for fused Stage B modules (WebAssembly.instantiate).
 *
 * Requires fixtures from: `zig build emit-fuse-goldens`
 * (auto-emitted if missing by spawning the build step once).
 */
import { describe, expect, it, beforeAll } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";

const ROOT = path.resolve(import.meta.dir, "../../..");
const FUSE_DIR = path.join(ROOT, "tests/artifacts/fuse");

function ensureFixtures() {
  const needed = [
    "chain_table.wasm",
    "chain_named.wasm",
    "chain_two_named.wasm",
    "diamond_named.wasm",
    "params_named.wasm",
  ];
  const missing = needed.some((f) => !fs.existsSync(path.join(FUSE_DIR, f)));
  if (!missing) return;
  const r = spawnSync("zig", ["build", "emit-fuse-goldens"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 120_000,
  });
  if (r.status !== 0) {
    throw new Error(
      `emit-fuse-goldens failed (status ${r.status})\nstdout: ${r.stdout}\nstderr: ${r.stderr}`,
    );
  }
}

function load(name: string): Uint8Array {
  return new Uint8Array(fs.readFileSync(path.join(FUSE_DIR, name)));
}

function readTable(mem: WebAssembly.Memory, base: number): Array<{ kind: number; value: number }> {
  const view = new DataView(mem.buffer);
  const count = view.getUint32(base, true);
  const outs: Array<{ kind: number; value: number }> = [];
  for (let i = 0; i < count; i++) {
    const off = base + 4 + i * 12;
    const kind = view.getUint32(off, true);
    const value = view.getFloat64(off + 4, true);
    outs.push({ kind, value });
  }
  return outs;
}

describe("fuse codegen numeric goldens (Spec 03)", () => {
  beforeAll(() => {
    ensureFixtures();
  });

  it("T1 table chain tick(3) → [7]", async () => {
    const bytes = load("chain_table.wasm");
    const mod = await WebAssembly.compile(bytes);
    const inst = await WebAssembly.instantiate(mod, {});
    const exports = inst.exports as {
      tick: (x: number) => number;
      memory: WebAssembly.Memory;
    };
    const base = exports.tick(3);
    const table = readTable(exports.memory, base);
    expect(table.length).toBe(1);
    expect(table[0]!.kind).toBe(0); // WireKind.number
    expect(table[0]!.value).toBeCloseTo(7, 12);
  });

  it("T1 named out_y(3) → 7", async () => {
    const bytes = load("chain_named.wasm");
    const mod = await WebAssembly.compile(bytes);
    const inst = await WebAssembly.instantiate(mod, {});
    const exports = inst.exports as { out_y: (x: number) => number };
    expect(exports.out_y(3)).toBeCloseTo(7, 12);
  });

  it("T2 diamond out_u(3)=7 out_v(3)=18", async () => {
    const bytes = load("diamond_named.wasm");
    const mod = await WebAssembly.compile(bytes);
    const inst = await WebAssembly.instantiate(mod, {});
    const exports = inst.exports as {
      out_u: (x: number) => number;
      out_v: (x: number) => number;
    };
    expect(exports.out_u(3)).toBeCloseTo(7, 12);
    expect(exports.out_v(3)).toBeCloseTo(18, 12);
  });

  it("T3 params trailing out_y(3,2)=6 out_y(3,5)=15", async () => {
    const bytes = load("params_named.wasm");
    const mod = await WebAssembly.compile(bytes);
    const inst = await WebAssembly.instantiate(mod, {});
    const exports = inst.exports as { out_y: (x: number, k: number) => number };
    expect(exports.out_y(3, 2)).toBeCloseTo(6, 12);
    expect(exports.out_y(3, 5)).toBeCloseTo(15, 12);
  });
});
