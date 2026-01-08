import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { MathZigWasm } from "../../../src/ts/mathzig_wasm";

describe("MathZigWasm batch wrapper helpers", () => {
  let ctx: MathZigWasm;

  beforeAll(async () => {
    ctx = await MathZigWasm.create();
  });

  afterAll(() => {
    ctx.destroy();
  });

  it("evaluateBatchArray returns expected outputs", () => {
    const xIdx = ctx.addVariableIndexed("x", 0);
    const expr = ctx.compile("x * 2 + 1");

    const out = expr.evaluateBatchArray(xIdx, [0, 1, 2, 3, 4]);
    expect(Array.from(out)).toEqual([1, 3, 5, 7, 9]);

    expr.free();
  });

  it("evaluateBatchSIMDArray returns expected outputs", () => {
    const xIdx = ctx.addVariableIndexed("x", 0);
    const expr = ctx.compile("x * 0.5 + 2");

    const out = expr.evaluateBatchSIMDArray(xIdx, new Float64Array([0, 2, 4, 6]));
    expect(Array.from(out)).toEqual([2, 3, 4, 5]);

    expr.free();
  });
});
