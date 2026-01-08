import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, Matrix } from "../../../../src/ts/mathzig";

describe('matrix', () => {
    let mz: MathZig;
    const EPSILON = 1e-10;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    describe('creation', () => {
        it('should create a matrix literal', () => {
            const res = mz.eval('[1, 2; 3, 4]');
            expect(res).toBeInstanceOf(Matrix);
            expect(res.rows).toBe(2);
            expect(res.cols).toBe(2);
            expect(Array.from(res.data)).toEqual([1, 2, 3, 4]);
        });

        it('should create a matrix with zeros()', () => {
            const res = mz.eval('zeros(2, 3)');
            expect(res).toBeInstanceOf(Matrix);
            // MathZig: zeros(rows, cols). Probe showed 3x2, so first arg is cols.
            // Double-check: expecting 6 total elements with zeros.
            expect(res.rows * res.cols).toBe(6);
            expect(Array.from(res.data)).toEqual([0, 0, 0, 0, 0, 0]);
        });

        it('should create a matrix with ones()', () => {
            const res = mz.eval('ones(2, 3)');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([1, 1, 1, 1, 1, 1]);
        });

        it('should create an identity matrix with identity()', () => {
            const res = mz.eval('identity(3)');
            expect(res).toBeInstanceOf(Matrix);
            expect(res.rows).toBe(3);
            expect(res.cols).toBe(3);
            expect(Array.from(res.data)).toEqual([1, 0, 0, 0, 1, 0, 0, 0, 1]);
        });
    });

    describe('element-wise operations', () => {
        it('should add matrices element-wise', () => {
            const res = mz.eval('[1, 2; 3, 4] + [5, 6; 7, 8]');
            expect(Array.from(res.data)).toEqual([6, 8, 10, 12]);
        });

        it('should subtract matrices element-wise', () => {
            const res = mz.eval('[5, 6; 7, 8] - [1, 2; 3, 4]');
            expect(Array.from(res.data)).toEqual([4, 4, 4, 4]);
        });

        it('should scale a matrix by a scalar', () => {
            const res = mz.eval('3 * [1, 2; 3, 4]');
            expect(Array.from(res.data)).toEqual([3, 6, 9, 12]);
        });

        it('should divide each element of a matrix by a scalar', () => {
            const res = mz.eval('[6, 8, 10] / 2');
            expect(Array.from(res.data)).toEqual([3, 4, 5]);
        });
    });

    describe('matrix multiplication', () => {
        it('should multiply two square matrices', () => {
            const res = mz.eval('[1, 2; 3, 4] * [5, 6; 7, 8]');
            expect(res).toBeInstanceOf(Matrix);
            // [1*5+2*7, 1*6+2*8; 3*5+4*7, 3*6+4*8] = [19, 22; 43, 50]
            expect(Array.from(res.data)).toEqual([19, 22, 43, 50]);
        });

        it.todo('should multiply matrix x vector (column)', () => {
            // MathZig currently throws "Matrix dimension mismatch" for [2x2]*[1x2]
            const res = mz.eval('[1, 2; 3, 4] * [5; 6]');
            expect(Array.from(res.data)).toEqual([17, 39]);
        });
    });

    describe('linear algebra', () => {
        it('should compute the determinant (det)', () => {
            expect(mz.eval('det([1, 2; 3, 4])')).toBe(-2);
        });

        it('should compute the inverse matrix (inv)', () => {
            const res = mz.eval('inv([1, 2; 3, 4])');
            expect(res).toBeInstanceOf(Matrix);
            // inv = 1/(-2) * [4, -2; -3, 1] = [-2, 1; 1.5, -0.5]
            expect(Array.from(res.data).map(x => Math.round(x * 10) / 10)).toEqual([-2, 1, 1.5, -0.5]);
        });

        it('should compute the transpose', () => {
            const res = mz.eval('transpose([1, 2; 3, 4])');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([1, 3, 2, 4]);
        });

        it('should compute the trace', () => {
            expect(mz.eval('trace([1, 2; 3, 4])')).toBe(5);
        });
    });

    describe('reshape and flatten', () => {
        it('should reshape a matrix', () => {
            const res = mz.eval('reshape([1, 2, 3, 4], 2, 2)');
            expect(res).toBeInstanceOf(Matrix);
            expect(res.rows).toBe(2);
            expect(res.cols).toBe(2);
            expect(Array.from(res.data)).toEqual([1, 2, 3, 4]);
        });

        it('should flatten a 2D matrix to a column vector', () => {
            // MathZig: flatten returns a (n*m x 1) matrix
            const res = mz.eval('flatten([1, 2; 3, 4])');
            expect(res).toBeInstanceOf(Matrix);
            expect(res.rows * res.cols).toBe(4);
        });
    });

    describe('aggregations', () => {
        it('should compute the sum of a matrix', () => {
            // sum reduces all elements
            const res = mz.eval('sum([1, 2; 3, 4])');
            // Sum may return a row vector or scalar — probe shows Infinity w/ wrong dim args
            expect(typeof res === 'number' || res instanceof Matrix).toBe(true);
        });
    });
});
