import { readFile } from "fs/promises";

async function main() {
  try {
    const wasmBuffer = await readFile(new URL("../artifacts/wasm/lorenz.wasm", import.meta.url));
    const wasmModule = await WebAssembly.compile(wasmBuffer);
    
    let wasmExports: any = null;
    let wasmMemory: WebAssembly.Memory = null as any;

    const env = {
        // ode_solve(func_name_ptr, y0_ptr, t_span_ptr, dt) -> result_ptr
        ode_solve: (funcNamePtr: number, y0Ptr: number, tSpanPtr: number, dt: number) => {
            if (!wasmExports || !wasmMemory) throw new Error("WASM not initialized");
            
            // 1. Read function name
            const mem8 = new Uint8Array(wasmMemory.buffer);
            let nameLen = 0;
            while (mem8[funcNamePtr + nameLen] !== 0) nameLen++;
            const funcName = new TextDecoder().decode(mem8.slice(funcNamePtr, funcNamePtr + nameLen));
            console.log(`ode_solve called: func=${funcName}`);
            
            const derivFunc = wasmExports[funcName];
            if (typeof derivFunc !== 'function') throw new Error(`Derivative function '${funcName}' not found in exports`);

            // 2. Read y0 (Matrix)
            // Matrix layout: [reserved, reserved, data_ptr, data_len, rows, cols, stride]?
            // Actually, in AOT, matrices are likely just pointers to data if they are simple arrays?
            // Wait, MathZig passes matrix pointers. The layout is defined in `types.zig` or `value.zig`.
            // In AOT `compiler.zig`:
            // mat_create:
            // Allocates: header (8 bytes) + data (8 * count).
            // Header: rows (4 bytes), cols (4 bytes).
            // Actually:
            // try writer.writeByte(@intFromEnum(types.Op.i32_store)); ... rows
            // try writer.writeByte(@intFromEnum(types.Op.i32_store)); ... cols
            // Layout at ptr:
            // ptr+0: rows (i32)
            // ptr+4: cols (i32)
            // ptr+8: data start (f64...)
            
            const mem32 = new Uint32Array(wasmMemory.buffer);
            const rowsY0 = mem32[y0Ptr / 4];
            const colsY0 = mem32[(y0Ptr + 4) / 4];
            console.log(`y0: ${rowsY0}x${colsY0}`);
            const lenY0 = rowsY0 * colsY0;
            const y0Data = new Float64Array(wasmMemory.buffer, y0Ptr + 8, lenY0);
            
            // 3. Read t_span
            const rowsT = mem32[tSpanPtr / 4];
            const colsT = mem32[(tSpanPtr + 4) / 4];
            console.log(`t_span: ${rowsT}x${colsT}`);
            const lenT = rowsT * colsT;
            const tData = new Float64Array(wasmMemory.buffer, tSpanPtr + 8, lenT);
            const tStart = tData[0];
            const tEnd = tData[lenT - 1];
            console.log(`Time: [${tStart}, ${tEnd}], dt=${dt}`);

            // 4. Solve
            const steps = Math.ceil((tEnd - tStart) / dt);
            console.log(`Steps: ${steps}`);
            const dim = lenY0;
            
            // Result matrix: (steps + 1) rows, (dim + 1) cols (t + y)
            const resRows = steps + 1;
            console.log(`ResRows: ${resRows}`);
            const resCols = dim + 1;
            const resSize = resRows * resCols * 8 + 8; // +8 header
            
            // Allocate result in WASM memory
            // We need `heap_ptr` global to know where to alloc
            const heapPtrIdx = wasmExports.heap_ptr.value; 
            const resultPtr = heapPtrIdx;
            console.log(`Allocating result at ${resultPtr}`);
            
            // Update heap_ptr (simple bump allocator)
            // Note: In a real scenario, we'd call an allocator function if exported
            // For this test, we just bump the global if it's mutable
            wasmExports.heap_ptr.value += resSize;

            // Write header
            mem32[resultPtr / 4] = resRows;
            mem32[(resultPtr + 4) / 4] = resCols;
            
            const resData = new Float64Array(wasmMemory.buffer, resultPtr + 8, resRows * resCols);
            
            // Simulation Loop (Euler/RK4)
            let t = tStart;
            const y = new Float64Array(y0Data); // Copy initial state
            const k1 = new Float64Array(dim);
            const tempY = new Float64Array(dim);
            const args = new Float64Array(dim); // Args for derivFunc if it takes specialized args?
            
            // Does `derivFunc` take (t, y_ptr)?
            // The compiled `f` in `lorenz_sim` takes `(t, u)`.
            // In AOT, `u` is passed as a pointer.
            // But `f` expects `u` to be a matrix pointer (with header).
            // So we need to allocate a temporary matrix for `u` in WASM memory to pass to `f`.
            
            const uPtr = wasmExports.heap_ptr.value;
            wasmExports.heap_ptr.value += (8 + dim * 8); // Header + data
            mem32[uPtr / 4] = rowsY0;
            mem32[(uPtr + 4) / 4] = colsY0;
            const uData = new Float64Array(wasmMemory.buffer, uPtr + 8, dim);

            for (let i = 0; i <= steps; i++) {
                // Store result
                resData[i * resCols] = t;
                for (let j = 0; j < dim; j++) resData[i * resCols + j + 1] = y[j];
                
                if (i === steps) break;

                // Euler step: y_next = y + dt * f(t, y)
                // Copy y to uData
                uData.set(y);
                
                // Call f(t, uPtr)
                const dydtPtr = derivFunc(t, uPtr);
                
                // Read dydt
                // Check dims
                // const rowsD = mem32[dydtPtr / 4];
                const dydtData = new Float64Array(wasmMemory.buffer, dydtPtr + 8, dim);
                
                for (let j = 0; j < dim; j++) {
                    y[j] += dt * dydtData[j];
                }
                t += dt;
            }

            return resultPtr;
        },
        // Needed imports
        fmod: (a: number, b: number) => a % b,
        pow: (a: number, b: number) => Math.pow(a, b),
        mathzig_gemm: () => { throw new Error("GEMM not implemented in test runner"); }
    };

    const instance = await WebAssembly.instantiate(wasmModule, { env });
    wasmExports = instance.exports;
    wasmMemory = wasmExports.memory;

    if (!wasmExports.eval) {
        // In lorenz_aot.mz, the last expression is a call `lorenz_sim(...)`.
        // The CLI compiler compiles the *file*. The top-level expression is compiled into the export named "eval".
        // `lorenz_sim` definition is a side effect (creating a function).
        // The result of the top-level sequence is the result of the last expression.
        console.error("Export 'eval' not found");
        return;
    }

    console.log("Running Lorenz simulation via WASM AOT...");
    const start = performance.now();
    const resultPtr = wasmExports.eval();
    const end = performance.now();
    console.log(`Simulation took ${(end - start).toFixed(2)}ms`);

    // Read result
    const mem32 = new Uint32Array(wasmMemory.buffer);
    const rows = mem32[resultPtr / 4];
    const cols = mem32[(resultPtr + 4) / 4];
    console.log(`Result Matrix: ${rows}x${cols}`);
    
    // Print first few rows
    const data = new Float64Array(wasmMemory.buffer, resultPtr + 8, rows * cols);
    for (let i = 0; i < Math.min(5, rows); i++) {
        const row = [];
        for (let j = 0; j < cols; j++) row.push(data[i * cols + j].toFixed(4));
        console.log(`Row ${i}: [${row.join(", ")}]`);
    }
    console.log("...");
    const lastRow = [];
    const lastIdx = (rows - 1) * cols;
    for (let j = 0; j < cols; j++) lastRow.push(data[lastIdx + j].toFixed(4));
    console.log(`Row ${rows - 1}: [${lastRow.join(", ")}]`);

  } catch (e) {
      console.error("Error running WASM:", e);
  }
}

main();
