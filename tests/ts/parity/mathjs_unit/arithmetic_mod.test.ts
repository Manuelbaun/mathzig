import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/mod', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });


    it('should calculate the modulus of two numbers', () => {
        expect(mz.eval('7 % 2')).toBe(1);
        expect(mz.eval('9 % 3')).toBe(0);
        expect(mz.eval('10 % 4')).toBe(2);
        expect(mz.eval('-10 % 4')).toBe(2);
        expect(mz.eval('8.2 % 3')).toBeCloseTo(2.2, 10);
        expect(mz.eval('4 % 1.5')).toBe(1);
        expect(mz.eval('0 % 3')).toBe(0);
    });

    it('should handle negative dividend', () => {
        expect(mz.eval('-10 % 4')).toBe(2);
        expect(mz.eval('-5 % 3')).toBe(1);
    });

    it('should handle negative divisor', () => {
        // MathJS: mod(10, -4) = -2
        // MathZig: 10 % -4 = 2 (remainder behavior)
        expect(mz.eval('10 % -4')).toBe(2);
    });

    it.todo('should calculate the modulus of booleans', () => {
        expect(mz.eval('true % true')).toBe(0);
    });

    describe('Array/Matrix', () => {
        it.todo('should perform element-wise modulus', () => {
            const res = mz.eval('[7, 8, 9] % 3');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([1, 2, 0]);
        });
    });
});
