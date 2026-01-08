/**
 * MathZig Performance Benchmark
 *
 * High-performance comparison of:
 * - Native JavaScript
 * - MathZig FFI (Scalar Fast Path)
 * - MathZig FFI (SIMD Batch Evaluation)
 * - MathZig FFI (Parallel SIMD Evaluation)
 */

import { MathZig, toArrayBuffer } from "../../../src/ts/mathzig";
import { MathZigWasm } from "../../../src/ts/mathzig_wasm";

const ITERATIONS = Number(Bun.env.BENCH_ITERS ?? 1_000_000);
const BATCH_SIZE = Number(Bun.env.BENCH_BATCH ?? 100_000);

function benchmark(name: string, iterations: number, fn: () => void) {
    const start = performance.now();
    fn();
    const end = performance.now();
    const duration = end - start;
    console.log(`${name.padEnd(30)}: ${duration.toFixed(2)}ms (${(iterations / (duration / 1000) / 1000000).toFixed(2)} M ops/sec)`);
}

async function main() {
    console.log("MathZig Performance Benchmark (Production Optimization)");
    console.log("======================================================");
    console.log(`Target: ${ITERATIONS.toLocaleString()} iterations\n`);

    const ctx = MathZig.create();
    const ctxWasm = await MathZigWasm.create();
    
    const exprStr = "x * 0.5 + 2.0";
    
    // FFI Setup
    const xIdx = ctx.addVariableIndexed("x", 0);
    const compiled = ctx.compile(exprStr);
    
    // WASM Setup
    const xIdxWasm = ctxWasm.addVariableIndexed("x", 0);
    const compiledWasm = ctxWasm.compile(exprStr);

    // 1. Native JS Baseline
    const jsFn = (x: number) => x * 0.5 + 2.0;
    benchmark("Native JS", ITERATIONS, () => {
        let sum = 0;
        for (let i = 0; i < ITERATIONS; i++) {
            sum += jsFn(i);
        }
        return sum;
    });

    // 2. FFI Scalar Fast Path
    const varsPtr = ctx.getVariablesPtr();
    const varsView = new Float64Array(toArrayBuffer(varsPtr, 0, 256 * 8));
    benchmark("MathZig FFI (Scalar Fast)", ITERATIONS, () => {
        let sum = 0;
        for (let i = 0; i < ITERATIONS; i++) {
            varsView[xIdx] = i; 
            sum += compiled.evaluateFast();
        }
        return sum;
    });

    // 3. WASM Scalar Path
    const varsPtrWasm = ctxWasm.getVariablesPtr();
    const varsViewWasm = new DataView(((ctxWasm as any).memory as WebAssembly.Memory).buffer);
    benchmark("MathZig WASM (Scalar)", ITERATIONS, () => {
        let sum = 0;
        for (let i = 0; i < ITERATIONS; i++) {
            varsViewWasm.setFloat64(varsPtrWasm + xIdxWasm * 8, i, true);
            sum += compiledWasm.evaluate();
        }
        return sum;
    });

    console.log("");

    // 4. SIMD Batch Evaluation
    const batchIterations = Math.max(1, Math.floor(ITERATIONS / BATCH_SIZE));
    
    // FFI Batch
    const inputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    const outputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    const inputsView = new Float64Array(toArrayBuffer(inputsPtr, 0, BATCH_SIZE * 8));
    for(let i=0; i<BATCH_SIZE; i++) inputsView[i] = i;

    benchmark("MathZig FFI (SIMD Batch)", ITERATIONS, () => {
        for (let i = 0; i < batchIterations; i++) {
            compiled.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);
        }
    });

    // WASM Batch
    const inputsPtrWasm = ctxWasm.malloc(BATCH_SIZE * 8);
    const outputsPtrWasm = ctxWasm.malloc(BATCH_SIZE * 8);
    const inputsViewWasm = new DataView(((ctxWasm as any).memory as WebAssembly.Memory).buffer);
    for (let i = 0; i < BATCH_SIZE; i++) {
        inputsViewWasm.setFloat64(inputsPtrWasm + i * 8, inputsView[i], true);
    }

    benchmark("MathZig WASM (SIMD Batch)", ITERATIONS, () => {
        for (let i = 0; i < batchIterations; i++) {
            compiledWasm.evaluateBatchSIMD(xIdxWasm, inputsPtrWasm, outputsPtrWasm, BATCH_SIZE);
        }
    });

    // 5. Parallel SIMD Evaluation (Multicore - FFI Only)
    if (batchIterations >= 1) {
        benchmark("MathZig FFI (Parallel SIMD)", ITERATIONS, () => {
            for (let i = 0; i < batchIterations; i++) {
                compiled.evaluateBatchParallel(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);
            }
        });
    }

    console.log("\nPolynomial Benchmark (Horner's Method)");
    // Coefficients for 25x^5 - 35x^4 - 15x^3 + 40x^2 - 15x + 1
    const polyCoeffs = new Float64Array([25, -35, -15, 40, -15, 1]);
    const polyExpr = "25*x^5 - 35*x^4 - 15*x^3 + 40*x^2 - 15*x + 1";
    
    const compiledPoly = ctx.compile(polyExpr);
    const compiledPolyWasm = ctxWasm.compile(polyExpr);

    benchmark("JS Polynomial", ITERATIONS, () => {
        let sum = 0;
        for (let i = 0; i < ITERATIONS; i++) {
            const x = i * 0.000001;
            sum += 25*x**5 - 35*x**4 - 15*x**3 + 40*x**2 - 15*x + 1;
        }
        return sum;
    });

    benchmark("MathZig FFI SIMD Poly", ITERATIONS, () => {
        for (let i = 0; i < batchIterations; i++) {
            compiledPoly.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);
        }
    });

    benchmark("MathZig WASM SIMD Poly", ITERATIONS, () => {
        for (let i = 0; i < batchIterations; i++) {
            compiledPolyWasm.evaluateBatchSIMD(xIdxWasm, inputsPtrWasm, outputsPtrWasm, BATCH_SIZE);
        }
    });

    const compiledPolyNative = ctx.compilePolynomial(xIdx, polyCoeffs);
    let compiledPolyNativeWasm: ReturnType<typeof ctxWasm.compilePolynomial> | null = null;
    try {
        compiledPolyNativeWasm = ctxWasm.compilePolynomial(xIdxWasm, polyCoeffs);
    } catch (err) {
        console.warn("Skipping WASM native polynomial benchmark:", (err as Error).message);
    }

    benchmark("MathZig FFI SIMD Poly (NATIVE)", ITERATIONS, () => {
        for (let i = 0; i < batchIterations; i++) {
            compiledPolyNative.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);
        }
    });

    if (compiledPolyNativeWasm) {
        const wasmNativePoly = compiledPolyNativeWasm;
        benchmark("MathZig WASM SIMD Poly (NATIVE)", ITERATIONS, () => {
            for (let i = 0; i < batchIterations; i++) {
                wasmNativePoly.evaluateBatchSIMD(xIdxWasm, inputsPtrWasm, outputsPtrWasm, BATCH_SIZE);
            }
        });
    }

    ctx.destroy();
    ctxWasm.destroy();
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
