import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, ValueTag } from '../../../src/ts/mathzig';

describe('FFI Basic Operations', () => {
    let mathzig: MathZig;

    beforeAll(() => {
        mathzig = MathZig.create();
    });

    afterAll(() => {
        mathzig.destroy();
    });

    const evalNum = (expr: string): number => {
        const res = mathzig.eval(expr);
        if (typeof res === 'number') return res;
        if (typeof res === 'object' && res !== null) {
            const val = res.toNumber();
            res.release();
            return val;
        }
        return Number(res);
    };

    describe('Context Management', () => {
        it('should create a MathZig context', () => {
            expect(mathzig).toBeDefined();
        });

        it('should destroy context cleanly', () => {
            const temp = MathZig.create();
            temp.destroy();
            expect(true).toBe(true);
        });
    });

    describe('Expression Compilation', () => {
        it('should compile expressions', () => {
            const compiled = mathzig.compile('x * 2 + 1');
            expect(compiled).toBeDefined();
            expect(compiled.getBytecodeSize()).toBeGreaterThan(0);
            compiled.free();
        });

        it('should fail on invalid expressions', () => {
            expect(() => mathzig.compile('x =')).toThrow();
        });

        it('should provide compilation metadata', () => {
            const compiled = mathzig.compile('x + y * z');
            expect(compiled.getNumConstants()).toBeDefined();
            compiled.free();
        });
    });

    describe('Evaluation Methods', () => {
        it('should evaluate directly via eval()', () => {
            expect(evalNum('2 + 3 * 4')).toBe(14);
        });

        it('should evaluate compiled expressions', () => {
            const compiled = mathzig.compile('10 / 2');
            const res = compiled.evaluate();
            expect(res).toBe(5);
            compiled.free();
        });

        it('should use fast path for number-only expressions', () => {
            const compiled = mathzig.compile('10 * 10');
            expect(compiled.evaluateFast()).toBe(100);
            compiled.free();
        });
    });

    describe('Variable Management', () => {
        it('should add indexed variables', () => {
            const idx = mathzig.addVariableIndexed('var1', 10.5);
            expect(idx).toBeGreaterThanOrEqual(0);
        });

        it('should set variables by index', () => {
            const idx = mathzig.addVariableIndexed('x', 0);
            mathzig.setByIndex(idx, 42);
            expect(evalNum('x')).toBe(42);
        });

        it('should get direct variable pointer', () => {
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const varsPtr = mathzig.getVariablesPtr();
            expect(varsPtr).toBeDefined();
            
            // Use manual creation to avoid registering VM memory for freeing
            const varsBuf = mathzig.backend.toArrayBuffer(varsPtr, 256 * 8);
            const varsView = new Float64Array(varsBuf, 0, 256);
            varsView[xIdx] = 100;

            expect(evalNum('x')).toBe(100);
        });
    });

    describe('Memory Management', () => {
        it('should allocate aligned memory', () => {
            const ptr = MathZig.allocAligned(32, 1024);
            expect(ptr).toBeDefined();
            MathZig.free(ptr);
        });

        it('should handle batch evaluation with aligned buffers', () => {
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const compiled = mathzig.compile('x * 2');
            
            const count = 100;
            const inPtr = MathZig.allocAligned(32, count * 8);
            const outPtr = MathZig.allocAligned(32, count * 8);
            
            // Use manual creation to avoid auto-free since we free manually below
            const inBuf = mathzig.backend.toArrayBuffer(inPtr, count * 8);
            const inputs = new Float64Array(inBuf, 0, count);
            for (let i = 0; i < count; i++) inputs[i] = i;
            
            compiled.evaluateBatchSIMD(xIdx, inPtr, outPtr, count);
            
            const outBuf = mathzig.backend.toArrayBuffer(outPtr, count * 8);
            const outputs = new Float64Array(outBuf, 0, count);
            expect(outputs[10]).toBe(20);
            expect(outputs[50]).toBe(100);
            
            MathZig.free(inPtr);
            MathZig.free(outPtr);
            compiled.free();
        });
    });

    describe('SIMD Batch Operations', () => {
        it('should evaluate in batches using SIMD', () => {
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const compiled = mathzig.compile('x + 1');
            const results = compiled.evaluateBatch(xIdx, [1, 2, 3, 4, 5]);
            expect(results).toEqual([2, 3, 4, 5, 6]);
            compiled.free();
        });

        it('should support caller-provided output buffer for array inputs', () => {
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const compiled = mathzig.compile('x * 2');
            const out = new Float64Array(5);
            const returned = compiled.evaluateBatch(xIdx, [1, 2, 3, 4, 5], out, 5);
            expect(returned).toBe(out);
            expect(Array.from(out)).toEqual([2, 4, 6, 8, 10]);
            compiled.free();
        });

        it('should support parallel batch evaluation', () => {
            const BATCH_SIZE = 100000;
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const compiled = mathzig.compile('x * 0.5');
            
            const inputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
            const outputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
            
            compiled.evaluateBatchParallel(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);
            
            MathZig.free(inputsPtr);
            MathZig.free(outputsPtr);
            compiled.free();
        });
    });

    describe('Polynomial Compilation', () => {
        it('should compile polynomials efficiently', () => {
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const coeffs = new Float64Array([1, 2, 3]); // 1x^2 + 2x + 3
            const poly = mathzig.compilePolynomial(xIdx, coeffs);
            expect(poly).toBeDefined();
            poly.free();
        });
    });

    describe('Error Handling', () => {
        it('should report compilation errors via exception', () => {
            // Compilation errors are thrown as exceptions with error details
            expect(() => mathzig.compile('x +')).toThrow();
        });

        it('should handle invalid variable indices', () => {
            mathzig.setByIndex(-1, 10);
            mathzig.setByIndex(1000, 10);
            expect(true).toBe(true);
        });
    });
});
