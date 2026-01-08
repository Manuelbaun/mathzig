import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/multiply', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    it('should multiply two numbers correctly', () => {
        expect(mz.eval('2 * 3')).toBe(6);
        expect(mz.eval('-2 * 3')).toBe(-6);
        expect(mz.eval('-2 * -3')).toBe(6);
        expect(mz.eval('5 * 0')).toBe(0);
        expect(mz.eval('0 * 5')).toBe(0);
        expect(mz.eval('0 * Infinity')).toBe(0); // MathJS: NaN, MathZig: 0
        expect(mz.eval('2 * Infinity')).toBe(Infinity);
        expect(mz.eval('-2 * Infinity')).toBe(-Infinity);
    });

    it.todo('should multiply booleans', () => {
        expect(mz.eval('true * true')).toBe(1);
        expect(mz.eval('true * false')).toBe(0);
    });

    it('should multiply two complex numbers correctly', () => {
        const res = mz.eval('(2 + 3i) * 2');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Complex);
        expect(res.real()).toBe(4);
        expect(res.imag()).toBe(6);

        const res2 = mz.eval('(2 + 3i) * (1 + 1i)');
        // (2+3i)(1+i) = 2 + 2i + 3i + 3i^2 = 2 + 5i - 3 = -1 + 5i
        expect(res2.real()).toBe(-1);
        expect(res2.imag()).toBe(5);
    });

    it('should multiply a number and a unit correctly', () => {
        const res = mz.eval('2 * 5 mm');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        expect(res.toNumber()).toBe(0.01); // 10 mm = 0.01 m
    });

    it('should multiply two units correctly', () => {
        const res = mz.eval('2 m * 4 m');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        expect(res.toNumber()).toBe(8); // 8 m^2
    });

    describe('Array/Matrix', () => {
        it('should multiply matrix x matrix', () => {
            const res = mz.eval('[1, 2; 3, 4] * [5, 6; 7, 8]');
            expect(res).toBeInstanceOf(Matrix);
            // [1*5+2*7, 1*6+2*8; 3*5+4*7, 3*6+4*8] = [19, 22; 43, 50]
            expect(Array.from(res.data)).toEqual([19, 22, 43, 50]);
        });

        it.todo('should multiply vectors (dot product)', () => {
            const res = mz.eval('[1, 2, 3] * [4, 5, 6]');
            // MathJS returns scalar for vector*vector dot product
            expect(res).toBe(32);
        });

        it.todo('should multiply matrix x vector', () => {
            const res = mz.eval('[1, 2; 3, 4] * [5, 6]');
            // [1*5+2*6; 3*5+4*6] = [17; 39]
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([17, 39]);
        });
    });

    it('should throw an error in case of invalid number of arguments', () => {
        expect(() => mz.eval('multiply(1)')).toThrow();
    });
});
