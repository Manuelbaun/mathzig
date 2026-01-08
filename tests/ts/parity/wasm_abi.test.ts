import { describe, expect, it } from "bun:test";
import { compileAot } from "../../parity/wasm_aot";
import { createDefaultWasmImports } from "../wasm_utils";

/**
 * AOT ABI manifest (mathzig.abi custom section) and function-index-space
 * regression tests. Spec: src/wasm/abi.zig.
 */

async function instantiate(expr: string, numParams: number) {
  const { wasmBytes } = await compileAot(expr, numParams);
  const module = await WebAssembly.compile(wasmBytes);
  const instance = await WebAssembly.instantiate(module, createDefaultWasmImports());
  return { module, instance };
}

function readManifest(module: WebAssembly.Module): any {
  const sections = WebAssembly.Module.customSections(module, "mathzig.abi");
  expect(sections.length).toBe(1);
  return JSON.parse(new TextDecoder().decode(sections[0]));
}

describe("mathzig.abi custom section", () => {
  it("describes a scalar module (result_tag, exports, imports)", async () => {
    const { module } = await instantiate("sin(x) + atan(y) * 2", 2);
    const manifest = readManifest(module);
    expect(manifest.abi).toBe(1);
    expect(manifest.result_tag).toBe("number");
    expect(manifest.heap).toBe(false);
    expect(manifest.exports).toEqual([{ name: "eval", params: 2 }]);
    // sin is an internally generated body; atan is the only env import
    const names = manifest.imports.map((i: any) => i.name);
    expect(names).toContain("atan");
    expect(names).not.toContain("sin");
  });

  it("marks heap use and exports alloc for matrix modules", async () => {
    const { module, instance } = await instantiate("[1, 2, 3] * 2", 0);
    const manifest = readManifest(module);
    expect(manifest.heap).toBe(true);
    expect(manifest.result_tag).toBe("matrix");
    const alloc = instance.exports.alloc as (n: number) => number;
    expect(typeof alloc).toBe("function");
    // Bump allocation is 8-byte aligned and monotonic
    const a = alloc(5);
    const b = alloc(8);
    expect(a % 8).toBe(0);
    expect(b).toBe(a + 8);
  });
});

describe("function index space (imports before generated bodies)", () => {
  // Regression: sin (internal generated body) registered before atan (env
  // import) used to shift the function index space, silently evaluating
  // sin(x) as atan(x).
  it("mixes internal sin with imported atan correctly", async () => {
    const { instance } = await instantiate("sin(x) + atan(y) * 2", 2);
    const evalFn = instance.exports.eval as (x: number, y: number) => number;
    expect(evalFn(0.5, 1)).toBeCloseTo(Math.sin(0.5) + Math.atan(1) * 2, 12);
  });

  it("mixes pow helper, fmod import and internal sin correctly", async () => {
    const { instance } = await instantiate("2 ^ x + sin(x) % 3", 1);
    const evalFn = instance.exports.eval as (x: number) => number;
    expect(evalFn(1.7)).toBeCloseTo(2 ** 1.7 + (Math.sin(1.7) % 3), 12);
  });
});
