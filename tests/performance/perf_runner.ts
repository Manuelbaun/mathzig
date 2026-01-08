/**
 * MathZig General Performance Runner
 * 
 * Usage: bun tests/performance/perf_runner.ts <feature_id>
 */

import { MathZig } from '../../src/mathzig';

const feature_id = process.argv[2] || "baseline";
const timestamp = Math.floor(Date.now() / 1000).toString();
const INCLUDE_EXTENDED = Bun.env.PERF_TS_EXTENDED === "1";

async function main() {
    const ctx = MathZig.create();
    
    // Stable core benchmarks
    await runArithmeticBenchmark(ctx);
    await runArithmeticBatchBenchmark(ctx);
    await runComplexBatchBenchmark(ctx);
    await runNativeJSBenchmark(ctx);
    
    // Optional extended benchmarks (can be heavier / less stable across environments)
    if (INCLUDE_EXTENDED) {
        await runMatrixBenchmark(ctx);
        await runTimeSeriesBenchmark(ctx);
        await runODEBenchmark(ctx);
    }

    ctx.destroy();
}

function logResult(ctx: MathZig, test_name: string, iterations: number, duration_ms: number) {
    const ops_per_sec = (iterations / (duration_ms / 1000)).toFixed(2);
    const mem_allocated = ctx.getMemoryUsed();
    const mem_reserved = ctx.getMemoryReserved();
    const mem_peak = ctx.getMemoryPeak();
    // Format: timestamp,feature_id,test_name,iterations,duration_ms,ops_per_sec,mem_allocated,mem_reserved,mem_peak
    console.log(`${timestamp},${feature_id},${test_name},${iterations},${duration_ms.toFixed(4)},${ops_per_sec},${mem_allocated},${mem_reserved},${mem_peak}`);
}

async function runComplexBatchBenchmark(ctx: MathZig) {
    const ITERATIONS = 1_000_000;
    const BATCH_SIZE = 10_000;
    
    // Expression: (z + 2*i) / (z - 2*i)
    const expr = "(z + 2*i) / (z - 2*i)";
    const zIdx = ctx.addVariableIndexed("z", 0);
    const compiled = ctx.compile(expr);
    
    const inputsRePtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    const inputsImPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    const outputsRePtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    const outputsImPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    
    const inputsRe = MathZig.toFloat64Array(inputsRePtr, BATCH_SIZE);
    const inputsIm = MathZig.toFloat64Array(inputsImPtr, BATCH_SIZE);
    
    for(let i=0; i<BATCH_SIZE; i++) {
        inputsRe[i] = i;
        inputsIm[i] = i * 0.5;
    }

    const start = performance.now();
    const loops = ITERATIONS / BATCH_SIZE;
    for (let i = 0; i < loops; i++) {
        compiled.evaluateBatchComplexSIMD(
            zIdx, 
            inputsRePtr, inputsImPtr, 
            outputsRePtr, outputsImPtr, 
            BATCH_SIZE
        );
    }
    const end = performance.now();
    
    logResult(ctx, "ffi_complex_div_batch_simd", ITERATIONS, end - start);
    
    MathZig.free(inputsRePtr);
    MathZig.free(inputsImPtr);
    MathZig.free(outputsRePtr);
    MathZig.free(outputsImPtr);
    compiled.free();
}

async function runArithmeticBenchmark(ctx: MathZig) {
    const ITERATIONS = 1_000_000;
    const expr = "x * 0.5 + 2.0";
    const xIdx = ctx.addVariableIndexed("x", 0);
    const compiled = ctx.compile(expr);
    const varsPtr = ctx.getVariablesPtr();
    const varsView = MathZig.toFloat64Array(varsPtr, 256);

    const start = performance.now();
    for (let i = 0; i < ITERATIONS; i++) {
        varsView[xIdx] = i;
        compiled.evaluateFast();
    }
    const end = performance.now();
    logResult(ctx, "ffi_arithmetic_scalar_fast", ITERATIONS, end - start);
    compiled.free();
}

async function runArithmeticBatchBenchmark(ctx: MathZig) {
    const ITERATIONS = 1_000_000;
    const expr = "x * 0.5 + 2.0";
    const xIdx = ctx.addVariableIndexed("x", 0);
    const compiled = ctx.compile(expr);
    
    // Allocate aligned memory for batch
    // Process in chunks to simulate realistic workloads (e.g. 10k items)
    const BATCH_SIZE = 10_000;
    const inputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    const outputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
    const inputs = MathZig.toFloat64Array(inputsPtr, BATCH_SIZE);
    
    for(let i=0; i<BATCH_SIZE; i++) inputs[i] = i;

    const start = performance.now();
    // Total iterations = loops * batch_size
    const loops = ITERATIONS / BATCH_SIZE;
    for (let i = 0; i < loops; i++) {
        compiled.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);
    }
    const end = performance.now();
    
    logResult(ctx, "ffi_arithmetic_batch_simd", ITERATIONS, end - start);
    
    MathZig.free(inputsPtr);
    MathZig.free(outputsPtr);
    compiled.free();
}

async function runNativeJSBenchmark(ctx: MathZig) {
    const ITERATIONS = 1_000_000;
    // Pre-allocate array
    const inputs = new Float64Array(ITERATIONS);
    for(let i=0; i<ITERATIONS; i++) inputs[i] = i;
    const outputs = new Float64Array(ITERATIONS);

    const start = performance.now();
    // Simple loop matching x * 0.5 + 2.0
    for (let i = 0; i < ITERATIONS; i++) {
        outputs[i] = inputs[i] * 0.5 + 2.0;
    }
    const end = performance.now();
    
    logResult(ctx, "native_js_arithmetic", ITERATIONS, end - start);
}

async function runMatrixBenchmark(ctx: MathZig) {
    const N = 100;
    const ITERATIONS = 100;
    const a = MathZig.createMatrix(N, N);
    const b = MathZig.createMatrix(N, N);
    a.fill(1.0);
    b.fill(1.0);

    const start = performance.now();
    for (let i = 0; i < ITERATIONS; i++) {
        ctx.matmulSIMD(a, b);
    }
    const end = performance.now();
    logResult(ctx, "ffi_matrix_multiply_100x100", ITERATIONS, end - start);
}

async function runTimeSeriesBenchmark(ctx: MathZig) {
    const SAMPLES = 100_000;
    const ITERATIONS = 10;
    const ts = new Float64Array(SAMPLES);
    const vs = new Float64Array(SAMPLES);
    for(let i=0; i<SAMPLES; i++) {
        ts[i] = i;
        vs[i] = Math.sin(i * 0.1);
    }

    const start = performance.now();
    for (let i = 0; i < ITERATIONS; i++) {
        const series = ctx.createSeries(ts, vs);
        ctx.setSeries("data", series);
        ctx.eval("twa(data)");
        ctx.eval("rsi(data, 14)");
        // Note: ctx.setSeries handles cleanup of old series bound to the same name
        // and ctx.destroy handles cleanup of the last one.
    }
    const end = performance.now();
    logResult(ctx, "ffi_timeseries_stats_100k", ITERATIONS, end - start);
}

async function runODEBenchmark(ctx: MathZig) {
    const ITERATIONS = 10;
    
    // Define harmonic oscillator: dy/dt = [y2, -y1]
    ctx.eval("osc(t, y) = [y[1]; -y[0]]");
    
    // y0 = [0; 1], t_span = [0, 100], dt = 0.01 (10,000 steps)
    const expr = "ode_solve(\"osc\", [0; 1], [0, 100], 0.01)";
    const compiled = ctx.compile(expr);

    const start = performance.now();
    for (let i = 0; i < ITERATIONS; i++) {
        const res = compiled.evaluate();
        res.release();
    }
    const end = performance.now();
    
    logResult(ctx, "ffi_ode_solve_10k_steps", ITERATIONS, end - start);
    compiled.free();
}

main().catch(e => {
    console.error(e);
    process.exit(1);
});
