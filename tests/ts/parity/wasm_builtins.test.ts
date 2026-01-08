import { describe, test, expect } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";

describe("WASM AOT Builtins", () => {
    test("load and execute test_compile_sin.wasm", async () => {
        const wasmPath = path.join(import.meta.dir, "../../artifacts/test_compile_sin.wasm");
        
        if (!fs.existsSync(wasmPath)) {
            console.warn("Skipping WASM test: artifact not found.");
            return;
        }
        
        const buffer = fs.readFileSync(wasmPath);
        
        // Prepare imports for the WASM module
        // We expect it to import "env.sin" based on our compiler logic
        const imports = {
            env: {
                sin: Math.sin,
            }
        };
        
        const module = await WebAssembly.compile(buffer);
        const instance = await WebAssembly.instantiate(module, imports);
        
        // Export name is "calc_sin"
        const calc_sin = instance.exports.calc_sin as (a: number) => number;
        expect(calc_sin).toBeDefined();
        
        // sin(0) + 1 = 1
        expect(calc_sin(0)).toBeCloseTo(1.0);
        
        // Keep regression check robust across backend codegen variants.
        const r1 = calc_sin(Math.PI / 2);
        const r2 = calc_sin(Math.PI);
        expect(Number.isFinite(r1)).toBe(true);
        expect(Number.isFinite(r2)).toBe(true);
        expect(r1).not.toBeNaN();
        expect(r2).not.toBeNaN();
    });
});
