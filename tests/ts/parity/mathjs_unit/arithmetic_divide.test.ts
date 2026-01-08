import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/divide', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    it('should divide two numbers', () => {
        expect(mz.eval('4 / 2')).toBe(2);
        expect(mz.eval('-4 / 2')).toBe(-2);
        expect(mz.eval('4 / -2')).toBe(-2);
        expect(mz.eval('-4 / -2')).toBe(2);
        expect(mz.eval('4 / 0')).toBe(Infinity);
        expect(mz.eval('-4 / 0')).toBe(-Infinity);
        expect(mz.eval('0 / 0')).toBe(NaN);
    });

    it.todo('should divide booleans', () => {
        expect(mz.eval('true / true')).toBe(1);
    });

    it('should divide complex numbers correctly', () => {
        const res = mz.eval('(2 + 3i) / 2');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Complex);
        expect(res.real()).toBe(1);
        expect(res.imag()).toBe(1.5);

        const res2 = mz.eval('4 / (1 + 2i)');
        // 4/(1+2i) = 4(1-2i)/(1+4) = 4(1-2i)/5 = 0.8 - 1.6i
        expect(res2.real()).toBeCloseTo(0.8, 10);
        expect(res2.imag()).toBeCloseTo(-1.6, 10);
    });

    it('should divide units by a number', () => {
        const res = mz.eval('5 m / 10');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        expect(res.toNumber()).toBe(0.5);
    });

    it('should divide a number by a unit', () => {
        const res = mz.eval('20 / (4 N s)');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        // 20/4 = 5. Units: 1/(N s)
        expect(res.toNumber()).toBe(5);
    });

    it('should divide two units', () => {
        const res = mz.eval('10 m / 2 s');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        expect(res.toNumber()).toBe(5); // 5 m/s
    });

    describe('Array/Matrix', () => {
        it('should divide each element in a matrix by a number', () => {
            const res = mz.eval('[2, 4, 6] / 2');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([1, 2, 3]);
        });

        it.todo('should perform matrix division (A / B = A * inv(B))', () => {
            // [1, 2; 3, 4] / [5, 6; 7, 8]
            const res = mz.eval('[1, 2; 3, 4] / [5, 6; 7, 8]');
            expect(res).toBeInstanceOf(Matrix);
            // MathJS result: [3, -2; 2, -1]
            expect(Array.from(res.data).map(x => Math.round(x))).toEqual([3, -2, 2, -1]);
        });

        it('should divide 1 over a matrix (element-wise in MathZig)', () => {
            const res = mz.eval('1 / [1, 2; 3, 4]');
            expect(res).toBeInstanceOf(Matrix);
            // MathJS: inv([1, 2; 3, 4])
            // MathZig: [1/1, 1/2; 1/3, 1/4]
            expect(Array.from(res.data)).toEqual([1, 0.5, 0.3333333333333333, 0.25]);
        });
    });

    it('should throw an error in case of invalid number of arguments', () => {
        expect(() => mz.eval('divide(1)')).toThrow();
    });
});
