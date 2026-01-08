/**
 * task-15: unit_runtime field round-trip from bun (three modules).
 * Exact assert — independent of tests/parity/compare.ts.
 */
import { describe, expect, it } from "bun:test";
import { runMathZigCompiler } from "./wasm_utils";
import { readAbiManifest } from "../../src/ts/aot_env";

async function manifestFor(expr: string, numParams = 0) {
  const wasmBytes = await runMathZigCompiler(expr, numParams);
  const module = await WebAssembly.compile(wasmBytes);
  return readAbiManifest(module);
}

describe("unit_runtime custom section (task-15)", () => {
  it("none for pure scalar (no units)", async () => {
    const m = await manifestFor("1 + 2");
    expect(m).not.toBeNull();
    expect(m!.unit_runtime).toBe("none");
  });

  it("static for AOT-folded unit conversion (not host_dynamic)", async () => {
    // Runtime magnitude + static units: folds at AOT without env.conv.
    const m = await manifestFor("conv(x * cm, in)", 1);
    expect(m).not.toBeNull();
    expect(m!.unit_runtime).toBe("static");
    expect(m!.unit_runtime).not.toBe("host_dynamic");
  });

  it("static for unit sum with result_unit annotation", async () => {
    const m = await manifestFor("(2 * m) + (50 * cm)");
    expect(m).not.toBeNull();
    expect(m!.unit_runtime).toBe("static");
    expect(m!.result_unit).toBeDefined();
    expect(m!.result_unit!.dims.l).toBe(1);
  });

  it("host_dynamic when non-folded conv is emitted", async () => {
    const m = await manifestFor("conv(x, m)", 1);
    expect(m).not.toBeNull();
    expect(m!.unit_runtime).toBe("host_dynamic");
  });

  it("AOT compile rejects unit-bearing matrix literal", async () => {
    await expect(runMathZigCompiler("[1m, 2m]", 0)).rejects.toThrow();
  });
});
