import { test, expect } from "bun:test";
import { createDefaultWasmImports, runMathZigCompiler } from "../wasm_utils";

const compileAndRun = async (expr: string, args: number[] = []) => {
    const wasmBuffer = await runMathZigCompiler(expr, args.length);
    const module = await WebAssembly.compile(wasmBuffer);
    const instance = await WebAssembly.instantiate(module, createDefaultWasmImports());

    const run = instance.exports.eval as Function;
    return {
        result: run(...args),
        instance
    };
};

test("WASM Matrices: Create and Index", async () => {
    // [1, 2; 3, 4][0, 1] -> 2
    const { result } = await compileAndRun("[1, 2; 3, 4][0, 1]");
    expect(result).toBe(2);
});

test("WASM Matrices: Dynamic Creation", async () => {
    // [x, x*2; x*3, x*4][1, 0] -> x*3
    const { result } = await compileAndRun("[x, x*2; x*3, x*4][1, 0]", [10]);
    expect(result).toBe(30);
});

test("WASM Matrices: Multiple Creations", async () => {
    // Two independent matrix allocations and indexed reads.
    // [1, 2][0, 0] + [3, 4][0, 1] -> 1 + 4 = 5
    const { result } = await compileAndRun("[1, 2][0, 0] + [3, 4][0, 1]");
    expect(result).toBe(5);
});

test("WASM Records: Create and Get", async () => {
    // {a: 1, b: 2}.a -> 1
    const { result } = await compileAndRun("{a: 1, b: 2}.a");
    expect(result).toBe(1);
});

test("WASM Matrices: Element-wise Arithmetic", async () => {
    // [1, 2] .* [3, 4] -> [3, 8]
    const { result, instance } = await compileAndRun("[1, 2] .* [3, 4]");
    const ptr = result;
    const memory = instance.exports.memory as WebAssembly.Memory;
    const view = new DataView(memory.buffer);
    
    expect(view.getFloat64(ptr + 8, true)).toBe(3);
    expect(view.getFloat64(ptr + 16, true)).toBe(8);
});

test("WASM User Functions: Direct Call", async () => {
    // f(x) = x * 2; f(10) -> 20
    const { result } = await compileAndRun("f(x) = x * 2; f(10)");
    expect(result).toBe(20);
});

test("WASM User Functions: Multiple Args", async () => {
    // add(a, b) = a + b; add(5, 7) -> 12
    const { result } = await compileAndRun("add(a, b) = a + b; add(5, 7)");
    expect(result).toBe(12);
});
