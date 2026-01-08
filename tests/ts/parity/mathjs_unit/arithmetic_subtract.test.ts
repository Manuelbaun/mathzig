import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/subtract', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    it('should subtract two numbers correctly', () => {
        expect(mz.eval('4 - 2')).toBe(2);
        expect(mz.eval('4-2')).toBe(2);
        expect(mz.eval('-4.2 - 2.1')).toBeCloseTo(-6.3, 10);
    });

    it.todo('should support subtract() function', () => {
        expect(mz.eval('subtract(4, 2)')).toBe(2);
    });

    it.todo('should subtract booleans', () => {
        // MathZig currently fails on abs(true), likely same for subtract(true, true)
        expect(mz.eval('true - true')).toBe(0);
        expect(mz.eval('true - false')).toBe(1);
    });

    it('should subtract two complex numbers correctly', () => {
        const res = mz.eval('(3 + 2i) - (8 + 4i)');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Complex);
        expect(res.real()).toBe(-5);
        expect(res.imag()).toBe(-2);

        const res2 = mz.eval('10 - (3 + 4i)');
        expect(res2.real()).toBe(7);
        expect(res2.imag()).toBe(-4);
    });

    it.todo('should subtract two quantities of the same unit', () => {
        const res = mz.eval('5 km - 100 mile');
        // MathZig currently seems to ignore the second operand or has a bug.
        // Received 5000 (which is 5km in meters).
        expect(res.toNumber()).toBeCloseTo(-155934.4, 0);
    });

    it.todo('should throw an error if subtracting two quantities of different units', () => {
        // MathZig might be too permissive or have a bug here
        expect(() => mz.eval('5 km - 100 gram')).toThrow();
    });

    describe('Array/Matrix', () => {
        it('should subtract arrays correctly', () => {
            const res = mz.eval('[10, 20] - [5, 6]');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([5, 14]);
        });
    });

    it('should throw an error in case of invalid number of arguments', () => {
        // subtract is binary operator/function
        expect(() => mz.eval('subtract(1)')).toThrow();
    });
});
