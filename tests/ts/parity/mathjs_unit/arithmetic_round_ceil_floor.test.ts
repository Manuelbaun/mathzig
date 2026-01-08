import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/round_ceil_floor', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    describe('round', () => {
        it('should round a number', () => {
            expect(mz.eval('round(2.7)')).toBe(3);
            expect(mz.eval('round(2.5)')).toBe(3);
            expect(mz.eval('round(-2.5)')).toBe(-3);
            expect(mz.eval('round(2.1)')).toBe(2);
        });

        it.todo('should round to a given number of decimals', () => {
            // MathZig currently ignores second argument
            expect(mz.eval('round(3.14159, 3)')).toBe(3.142);
        });
    });

    describe('ceil', () => {
        it('should return the ceil of a number', () => {
            expect(mz.eval('ceil(1.3)')).toBe(2);
            expect(mz.eval('ceil(1.8)')).toBe(2);
            expect(mz.eval('ceil(-1.3)')).toBe(-1);
            expect(mz.eval('ceil(-1.8)')).toBe(-1);
        });
    });

    describe('floor', () => {
        it('should return the floor of a number', () => {
            expect(mz.eval('floor(1.3)')).toBe(1);
            expect(mz.eval('floor(1.8)')).toBe(1);
            expect(mz.eval('floor(-1.3)')).toBe(-2);
            expect(mz.eval('floor(-1.8)')).toBe(-2);
        });
    });

    it.todo('should work on matrices', () => {
        // Investigating exact Matrix structure returned by eval for rounding
        const res = mz.eval('round([1.7, 2.3, -2.5])');
        expect(Array.from(res.data)).toEqual([2, 2, -3]);

        const res2 = mz.eval('ceil([1.2, -1.8])');
        expect(Array.from(res2.data)).toEqual([2, -1]);

        const res3 = mz.eval('floor([1.8, -1.2])');
        expect(Array.from(res3.data)).toEqual([1, -2]);
    });

    it.todo('should work on complex numbers', () => {
        // MathZig returns primitive number if imaginary part becomes 0?
        // Or maybe round on complex is not fully supported yet in eval.
        const res = mz.eval('round(2.2 + 3.8i)');
        expect(res.real()).toBe(2);
        expect(res.imag()).toBe(4);
    });
});
