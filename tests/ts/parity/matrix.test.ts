/**
 * Matrix Specs
 * 
 * Tests for matrix operations and BLAS kernels.
 * Related docs: docs/plans/matrix_blas_plan.md, docs/internals/values.md
 */

import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Value } from '../../../src/ts/mathzig';

describe('Matrix Operations', () => {
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
        if (res instanceof Value) {
            const val = res.toNumber();
            res.release();
            return val;
        }
        return Number(res);
    };

    describe('Matrix Creation', () => {
        it('should create matrices from literals', () => {
            const result = mathzig.eval('[1, 2; 3, 4]');
            expect(result).toBeDefined();
            if (result instanceof Value) result.release();
        });

        it('should create identity matrix', () => {
            const result = mathzig.eval('identity(3)');
            expect(result).toBeDefined();
            // identity returns a Matrix (Value), so we can release
            if (result instanceof Value) result.release();
        });

        it('should create zero matrix', () => {
            const result = mathzig.eval('zeros(2, 3)');
            expect(result).toBeDefined();
            if (result instanceof Value) result.release();
        });

        it('should create ones matrix', () => {
            const result = mathzig.eval('ones(3, 3)');
            expect(result).toBeDefined();
            if (result instanceof Value) result.release();
        });
    });

    describe('Matrix Arithmetic', () => {
        it('should multiply matrices and return scalar via sum', () => {
            const a = '[1, 2; 3, 4]';
            const b = '[5, 6; 7, 8]';
            expect(evalNum(`sum(${a} * ${b})`)).toBe(134);
        });

        it('should multiply matrix by scalar and return sum', () => {
            expect(evalNum('sum([1, 2; 3, 4] * 2)')).toBe(20);
        });
    });

    describe('Matrix Operations', () => {
        it('should transpose matrix and verify via trace', () => {
            expect(evalNum('trace(transpose([1, 2; 3, 4]))')).toBe(5);
        });

        it('should compute determinant', () => {
            expect(evalNum('det([1, 2; 3, 4])')).toBe(-2);
        });

        it('should compute matrix inverse and verify via det', () => {
            expect(evalNum('det(inv([1, 2; 3, 4]))')).toBeCloseTo(-0.5, 5);
        });

        it('should compute trace', () => {
            expect(evalNum('trace([1, 2; 3, 4])')).toBe(5);
        });

        it('should compute matrix sum', () => {
            expect(evalNum('sum([1, 2; 3, 4])')).toBe(10);
        });

        it('should compute matrix mean', () => {
            expect(evalNum('mean([1, 2; 3, 4])')).toBe(2.5);
        });
    });

    describe('Element-wise Operations', () => {
        it('should perform element-wise multiplication', () => {
            const result = mathzig.eval('[1, 2; 3, 4] .* [2, 2; 2, 2]');
            expect(result).toBeDefined();
            if ((result as any)?.release) (result as any).release();
        });

        it('should perform element-wise division', () => {
            const result = mathzig.eval('[4, 6; 8, 10] ./ [2, 3; 4, 5]');
            expect(result).toBeDefined();
            if ((result as any)?.release) (result as any).release();
        });
    });

    describe('Vector Operations', () => {
        it('should compute dot product', () => {
            expect(evalNum('dot([1, 2, 3], [4, 5, 6])')).toBe(32);
        });

        it('should compute cross product', () => {
            const result = mathzig.eval('cross([1, 0, 0], [0, 1, 0])');
            expect(result).toBeDefined();
            if ((result as any)?.release) (result as any).release();
        });

        it('should compute norm', () => {
            expect(evalNum('norm([3, 4])')).toBe(5);
        });
    });

    describe('SIMD Matrix Operations', () => {
        it('should use SIMD for large matrix multiplication', () => {
            const n = 16;
            const a = MathZig.createMatrix(n, n);
            const b = MathZig.createMatrix(n, n);
            
            a.fill(1.0);
            b.fill(1.0);
            
            const c = mathzig.matmulSIMD(a, b);
            expect(c).toBeDefined();
            expect(c.length).toBe(n * n);
            expect(c[0]).toBe(n);
            expect(c[n * n - 1]).toBe(n);
        });
    });

    describe('Error Handling', () => {
        it('should report error for singular matrix inverse', () => {
            try {
                const res = mathzig.eval('inv([1, 2; 2, 4])');
                res.release();
                expect(true).toBe(false);
            } catch (e) {
                const error = String(mathzig.getError());
                expect(error).not.toBe("No error");
            }
        });
    });
});
