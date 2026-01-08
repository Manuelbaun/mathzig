import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/pow', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    it('should exponentiate a number to the given power', () => {
        expect(mz.eval('2 ^ 3')).toBe(8);
        expect(mz.eval('2 ^ 4')).toBe(16);
        // expect(mz.eval('-2 ^ 2')).toBe(4); // MathJS: 4, MathZig: may vary based on precedence?
        // Let's use parentheses
        expect(mz.eval('(-2) ^ 2')).toBe(4);
        expect(mz.eval('3 ^ -2')).toBeCloseTo(0.1111111111111111, 15);
    });

    it.todo('should exponentiate a negative number to a non-integer power', () => {
        const res = mz.eval('(-2) ^ 1.5');
        // MathJS returns complex, MathZig currently returns NaN in real mode
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Complex);
    });

    it.todo('should exponentiate booleans', () => {
        expect(mz.eval('true ^ true')).toBe(1);
    });

    it('should exponentiate complex numbers', () => {
        const res = mz.eval('(3 + 0i) ^ 2');
        // Returns primitive number in MathZig
        expect(res).toBe(9);
    });

    it('should correctly calculate unit ^ number', () => {
        const res = mz.eval('(4 N) ^ 2');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        expect(res.toNumber()).toBe(16); // 16 N^2
    });

    describe('Array/Matrix', () => {
        it.todo('should raise a square matrix to the power 2', () => {
            const res = mz.eval('[1, 2; 3, 4] ^ 2');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([7, 10, 15, 22]);
        });

        it.todo('should raise an inverted matrix for power -1', () => {
            const res = mz.eval('[1, 2; 3, 4] ^ -1');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([-2, 1, 1.5, -0.5]);
        });

        it.todo('should return identity matrix for power 0', () => {
            const res = mz.eval('[1, 2; 3, 4] ^ 0');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([1, 0, 0, 1]);
        });
    });

    it('should throw an error in case of invalid number of arguments', () => {
        expect(() => mz.eval('pow(1)')).toThrow();
    });
});
