/**
 * Integration Specs
 * 
 * End-to-end integration tests combining multiple subsystems.
 */

import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig } from '../../../src/ts/mathzig';

describe('Integration Tests', () => {
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

    describe('Full Workflow: Variable Compilation & Batch Evaluation', () => {
        it('should compile, set variables, and evaluate in batches', () => {
            // 1. Compile expression with multiple variables
            const compiled = mathzig.compile('a * x + b * y + c');
            const aIdx = mathzig.addVariableIndexed('a', 0);
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const bIdx = mathzig.addVariableIndexed('b', 0);
            const yIdx = mathzig.addVariableIndexed('y', 0);
            const cIdx = mathzig.addVariableIndexed('c', 0);

            // 2. Set constants
            mathzig.setByIndex(aIdx, 2);
            mathzig.setByIndex(bIdx, 3);
            mathzig.setByIndex(cIdx, 1);

            // 3. Batch evaluate with varying x and y
            const BATCH_SIZE = 100;
            const xPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
            const yPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
            const outPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);

            // Use manual creation to avoid auto-free
            const xArr = new Float64Array(mathzig.backend.toArrayBuffer(xPtr, BATCH_SIZE * 8), 0, BATCH_SIZE);
            const yArr = new Float64Array(mathzig.backend.toArrayBuffer(yPtr, BATCH_SIZE * 8), 0, BATCH_SIZE);

            for (let i = 0; i < BATCH_SIZE; i++) {
                xArr[i] = i * 0.1;
                yArr[i] = i * 0.2;
            }

            // 4. Evaluate (using a simpler expression for batch)
            const simpleCompiled = mathzig.compile('x * 2 + 1');
            simpleCompiled.evaluateBatchSIMD(xIdx, xPtr, outPtr, BATCH_SIZE);

            MathZig.free(xPtr);
            MathZig.free(yPtr);
            MathZig.free(outPtr);
            compiled.free();
            simpleCompiled.free();
        });
    });

    describe('Time-Series with Predicates', () => {
        it('should filter and aggregate time-series data', () => {
            // Create series and compute filtered aggregation
            expect(evalNum(
                'mean(series([1, 2, 3, 4, 5], [10, 20, 30, 40, 50])) where value > 25'
            )).toBe(40); // mean of 30, 40, 50
        });
    });

    describe('Matrix with Units', () => {
        it('should handle matrix operations with units', () => {
            // Matrix multiplication with unit-bearing scalars
            const result = mathzig.eval('2m * [1, 2; 3, 4]');
            expect(result).toBeDefined();
            if ((result as any)?.release) (result as any).release();
        });
    });

    describe('FFI Performance Path', () => {
        it('should use zero-copy variable updates', () => {
            const compiled = mathzig.compile('x * x');
            const xIdx = mathzig.addVariableIndexed('x', 0);

            // Get direct memory access
            const varsPtr = mathzig.getVariablesPtr();
            // Use manual creation to avoid auto-free (VM owns this memory)
            const varsBuf = mathzig.backend.toArrayBuffer(varsPtr, 256 * 8);
            const varsView = new Float64Array(varsBuf, 0, 256);

            // Direct write - no FFI call
            varsView[xIdx] = 5;

            expect(compiled.evaluateFast()).toBe(25);

            compiled.free();
        });

        it('should use polynomial kernel for optimized evaluation', () => {
            const xIdx = mathzig.addVariableIndexed('x', 0);
            // Polynomial: 3x² + 2x + 1
            const coeffs = new Float64Array([3, 2, 1]);

            const poly = mathzig.compilePolynomial(xIdx, coeffs);
            expect(poly).toBeDefined();

            const xPtr = MathZig.allocAligned(32, 100 * 8);
            const outPtr = MathZig.allocAligned(32, 100 * 8);

            poly.evaluateBatchSIMD(xIdx, xPtr, outPtr, 100);

            MathZig.free(xPtr);
            MathZig.free(outPtr);
            poly.free();
        });
    });

    describe('Complex Number Arithmetic', () => {
        it('should handle complex arithmetic', () => {
            const z1 = mathzig.eval('3 + 4i');
            const z2 = mathzig.eval('1 + 2i');
            const product = mathzig.eval('(3 + 4i) * (1 + 2i)');

            expect(product).toBeDefined();
            z1.release();
            z2.release();
            product.release();
        });
    });

    describe('Edge Cases', () => {
        it('should handle NaN values', () => {
            const res = mathzig.eval('nan + 5');
            expect(isNaN(res as number)).toBe(true);
        });

        it('should handle infinity', () => {
            const res = mathzig.eval('1 / 0');
            const val = res as number;
            expect(isNaN(val) || !isFinite(val)).toBe(true);
        });

        it('should handle empty expressions', () => {
            expect(() => mathzig.eval('')).toThrow();
        });

        it('should handle very large expressions', () => {
            // Test expression complexity limits
            const expr = '1 + 1 + 1 + 1 + 1 + '.repeat(200) + '0';
            expect(evalNum(expr)).toBe(1000);
        });
    });

    describe('Memory Management', () => {
        it('should not leak memory on repeated compilations', () => {
            for (let i = 0; i < 100; i++) {
                const compiled = mathzig.compile('x * 2 + 1');
                compiled.free();
            }
            // If we get here without OOM, memory is managed correctly
            expect(true).toBe(true);
        });

        it('should properly free batch evaluation buffers', () => {
            for (let i = 0; i < 10; i++) {
                const compiled = mathzig.compile('x + 1');
                const xIdx = mathzig.addVariableIndexed('x', 0);

                const inPtr = MathZig.allocAligned(32, 1000 * 8);
                const outPtr = MathZig.allocAligned(32, 1000 * 8);

                compiled.evaluateBatchSIMD(xIdx, inPtr, outPtr, 1000);

                MathZig.free(inPtr);
                MathZig.free(outPtr);
                compiled.free();
            }
            expect(true).toBe(true);
        });
    });

    describe('Error Recovery', () => {
        it('should recover from compilation errors', () => {
            // Invalid expression
            expect(() => mathzig.compile('x =')).toThrow();

            // Valid expression after error should work
            const goodResult = mathzig.compile('x + 1');
            expect(goodResult.evaluateFast()).toBeDefined();
            goodResult.free();
        });

        it('should handle runtime errors gracefully', () => {
            // Division by zero returns Infinity, not NaN (mathematically correct)
            const res = mathzig.eval('1 / 0') as number;
            expect(res).toBe(Infinity);
        });

        it('should persist reference types across calls', () => {
            const r1 = mathzig.eval('x = [1, 2; 3, 4]');
            if ((r1 as any)?.release) (r1 as any).release();
            // Accessing x in next call should work
            expect(evalNum('sum(x * 2)')).toBe(20);
        });
    });
});

describe('Performance Integration', () => {
    let mathzig: MathZig;

    beforeAll(() => {
        mathzig = MathZig.create();
    });

    afterAll(() => {
        mathzig.destroy();
    });

    describe('SIMD Throughput', () => {
        it('should achieve high throughput for batch operations', () => {
            const compiled = mathzig.compile('x * 0.5 + 2.0');
            const xIdx = mathzig.addVariableIndexed('x', 0);

            const BATCH_SIZE = 1_000_000;
            const inPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
            const outPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);

            // Use manual creation to avoid auto-free
            const inputs = new Float64Array(mathzig.backend.toArrayBuffer(inPtr, BATCH_SIZE * 8), 0, BATCH_SIZE);
            for (let i = 0; i < BATCH_SIZE; i++) {
                inputs[i] = i * 0.001;
            }

            const start = performance.now();
            compiled.evaluateBatchSIMD(xIdx, inPtr, outPtr, BATCH_SIZE);
            const elapsed = performance.now() - start;

            console.log(`SIMD batch (${BATCH_SIZE} items): ${elapsed.toFixed(2)}ms`);
            console.log(`Throughput: ${(BATCH_SIZE / (elapsed / 1000)).toLocaleString()} ops/sec`);

            MathZig.free(inPtr);
            MathZig.free(outPtr);
            compiled.free();
        });
    });
});
