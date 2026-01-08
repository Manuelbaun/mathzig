import { describe, expect, it } from "bun:test";
import { MathZig } from "../../../src/ts/mathzig";

describe("Correctness Verification", () => {
  it("matches scalar, fast, SIMD, and parallel paths", () => {
    const mathzig = MathZig.create();

    try {
      const testCases = [
        { expr: "2 + 3 * 4", x: 0, expected: 14 },
        { expr: "sqrt(25) + 5", x: 0, expected: 10 },
        { expr: "sin(0) + cos(0)", x: 0, expected: 1 },
        { expr: "x * 2 + 1", x: 10, expected: 21 },
        { expr: "x^2", x: 4, expected: 16 },
        { expr: "(x + 1) * (x - 1)", x: 5, expected: 24 },
      ];

      for (const t of testCases) {
        const compiled = mathzig.compile(t.expr);
        const xIdx = mathzig.addVariableIndexed('x', 0);
        mathzig.setByIndex(xIdx, t.x);

        const scalarRaw = compiled.evaluate();
        const scalar =
          typeof scalarRaw === "number" ? scalarRaw : (scalarRaw as any).toNumber();
        if (typeof scalarRaw !== "number" && scalarRaw) (scalarRaw as any).release();

        const fast = compiled.evaluateFast();

        const inputsPtr = MathZig.allocAligned(32, 64);
        const outputsPtr = MathZig.allocAligned(32, 64);
        const outputsParallelPtr = MathZig.allocAligned(32, 64);

        try {
          const inputs = new Float64Array(mathzig.backend.toArrayBuffer(inputsPtr, 64), 0, 8);
          inputs.fill(t.x);

          const outputs = new Float64Array(
            mathzig.backend.toArrayBuffer(outputsPtr, 64),
            0,
            8
          );
          compiled.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, 1);
          const simd = outputs[0];

          const outputsParallel = new Float64Array(
            mathzig.backend.toArrayBuffer(outputsParallelPtr, 64),
            0,
            8
          );
          compiled.evaluateBatchParallel(xIdx, inputsPtr, outputsParallelPtr, 1);
          const parallel = outputsParallel[0];

          expect(scalar).toBeCloseTo(t.expected, 10);
          expect(fast).toBeCloseTo(t.expected, 10);
          expect(simd).toBeCloseTo(t.expected, 10);
          expect(parallel).toBeCloseTo(t.expected, 10);
        } finally {
          MathZig.free(inputsPtr);
          MathZig.free(outputsPtr);
          MathZig.free(outputsParallelPtr);
          compiled.free();
        }
      }
    } finally {
      mathzig.destroy();
    }
  });
});
