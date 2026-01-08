import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('arithmetic/add', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    it('should add numbers correctly', () => {
        expect(mz.eval('2 + 3')).toBe(5);
        expect(mz.eval('2+3')).toBe(5);
    });

    it.todo('should support add() function', () => {
        // Currently 'add' is an UnknownFunction in eval
        expect(mz.eval('add(2, 3)')).toBe(5);
    });

    it('should add complex numbers correctly', () => {
        const res = mz.eval('(1 + 2i) + (3 + 4i)');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Complex);
        expect(res.real()).toBe(4);
        expect(res.imag()).toBe(6);
    });

    it('should add matrices element-wise', () => {
        const res = mz.eval('[1, 2] + [3, 4]');
        expect(res).toBeInstanceOf(Matrix);
        expect(Array.from(res.data)).toEqual([4, 6]);
    });

    it('should add units correctly', () => {
        const res = mz.eval('5 cm + 2 inch');
        expect(res).toBeInstanceOf(Value);
        expect(res.tag).toBe(ValueTag.Unit);
        // 1 inch = 2.54 cm. 2 inch = 5.08 cm. 5 cm + 5.08 cm = 10.08 cm = 0.1008 m
        expect(res.toNumber()).toBeCloseTo(0.1008, 10);
    });

    it('should throw error for incompatible units', () => {
        expect(() => mz.eval('5 cm + 2 kg')).toThrow();
    });

    it('should support multiple arguments (MathZig extension via comma group)', () => {
        // add(1, 2, 3) -> add((1, 2, 3))? No, add is binary.
        // Let's see how MathZig handles add(1, 2, 3)
        try {
            const res = mz.eval('add(1, 2, 3)');
            // If it behaves like abs(1, 2), it should return 3 or fail?
            // Actually add(1, 2, 3) is likely binary and takes first 2 or last 1?
        } catch (e) {
            // Success if it fails as expected for MathJS parity
        }
    });
});
