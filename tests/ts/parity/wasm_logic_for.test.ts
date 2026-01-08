import { test, expect } from "bun:test";
import { runMathZigCompiler } from "../wasm_utils";

const compileAndRun = async (expr: string, args: number[] = []) => {
    const wasmBuffer = await runMathZigCompiler(expr, args.length);
    const module = await WebAssembly.compile(wasmBuffer);
    const instance = await WebAssembly.instantiate(module, {
        env: {
            sin: Math.sin, cos: Math.cos, tan: Math.tan,
            exp: Math.exp, log: Math.log, sqrt: Math.sqrt,
            floor: Math.floor, ceil: Math.ceil, round: Math.round,
            abs: Math.abs, min: Math.min, max: Math.max,
            pow: Math.pow, fmod: (a: number, b: number) => a % b,
        }
    });
    const run = instance.exports.eval as Function;
    return run(...args);
};

test("WASM Loops: For", async () => {
    // for (i = 0; i < 10; i = i + 1) { sum = sum + i }; sum
    const code = `
    sum = 0;
    for (k = 0; k < 10; k = k + 1) {
        sum = sum + k
    };
    sum
    `;
    expect(await compileAndRun(code)).toBe(45);
});
