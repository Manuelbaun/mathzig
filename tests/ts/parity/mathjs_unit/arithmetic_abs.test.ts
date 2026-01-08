import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/abs', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    it.todo('should return the abs value of a boolean', () => {
        expect(mz.eval('abs(true)')).toBe(1);
        expect(mz.eval('abs(false)')).toBe(0);
    });

    it('should return the abs value of a number', () => {
        expect(mz.eval('abs(-4.2)')).toBeCloseTo(4.2, 10);
        expect(mz.eval('abs(-3.5)')).toBeCloseTo(3.5, 10);
        expect(mz.eval('abs(100)')).toBe(100);
        expect(mz.eval('abs(0)')).toBe(0);
    });

    it('should return the absolute value of a complex number', () => {
        // abs(3 - 4i) = sqrt(3^2 + (-4)^2) = 5
        expect(mz.eval('abs(3 - 4i)')).toBe(5);
        // MathZig handles this correctly without overflow
        expect(mz.eval('abs(3e100 - 4e100i)')).toBeCloseTo(5e100, 100);
    });

    it('should return the absolute number of a complex number with zero', () => {
        expect(mz.eval('abs(1 + 0i)')).toBe(1);
        expect(mz.eval('abs(0 + 1i)')).toBe(1);
        expect(mz.eval('abs(0 + 0i)')).toBe(0);
        expect(mz.eval('abs(-1 + 0i)')).toBe(1);
        expect(mz.eval('abs(0 - 1i)')).toBe(1);
    });

    it.todo('should return the absolute value of all elements in a matrix', () => {
        const res = mz.eval('abs([1, -2, 3])');
        expect(res).toBeInstanceOf(Matrix);
        expect(res.rows).toBe(1);
        expect(res.cols).toBe(3);
        expect(Array.from(res.data)).toEqual([1, 2, 3]);
    });

    it('should return the absolute value of a unit', () => {
        const res = mz.eval('abs(5 m)');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        expect(res.toNumber()).toBe(5);

        const res2 = mz.eval('abs(-5 m)');
        expect(res2).toBeInstanceOf(Value);
        expect(res2.tag).toBe(ValueTag.Unit);
        expect(res2.toNumber()).toBe(5);
    });

    it('should support comma operator in arguments (MathZig extension)', () => {
        expect(mz.eval('abs(1, 2)')).toBe(2);
    });

    it('should throw an error in case of invalid number of arguments', () => {
        expect(() => mz.eval('abs()')).toThrow();
    });
});
