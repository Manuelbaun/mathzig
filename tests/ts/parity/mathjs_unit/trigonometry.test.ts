import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { MathZig, ValueTag, Matrix, Value } from "../../../../src/ts/mathzig";

describe('trigonometry', () => {
    let mz: MathZig;
    const EPSILON = 1e-13;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    describe('sin', () => {
        it('should return the sine of a number', () => {
            expect(mz.eval('sin(0)')).toBe(0);
            expect(mz.eval('sin(pi / 2)')).toBe(1);
            expect(mz.eval('sin(pi)')).toBeCloseTo(0, EPSILON);
            expect(mz.eval('sin(pi * 3 / 2)')).toBe(-1);
            expect(mz.eval('sin(pi * 2)')).toBeCloseTo(0, EPSILON);
        });

        it('should return the sine of a boolean', () => {
            expect(mz.eval('sin(true)')).toBeCloseTo(Math.sin(1), EPSILON);
            expect(mz.eval('sin(false)')).toBe(0);
        });

        it('should return the sine of an angle unit', () => {
            expect(mz.eval('sin(90 deg)')).toBe(1);
            expect(mz.eval('sin(45 deg)')).toBeCloseTo(Math.SQRT1_2, EPSILON);
            expect(mz.eval('sin(0.5 rad)')).toBeCloseTo(Math.sin(0.5), EPSILON);
        });

        it.todo('should return the sine of a complex number', () => {
            // Currently fails with Type Error in eval
            const res = mz.eval('sin(1 + i)');
            expect(res.tag).toBe(ValueTag.Complex);
        });

        it.todo('should operate element-wise on a matrix', () => {
            // Currently returns scalar (first element)
            const res = mz.eval('sin([0, pi/2])');
            expect(res).toBeInstanceOf(Matrix);
            expect(Array.from(res.data)).toEqual([0, 1]);
        });
    });

    describe('cos', () => {
        it('should return the cosine of a number', () => {
            expect(mz.eval('cos(0)')).toBe(1);
            expect(mz.eval('cos(pi / 2)')).toBeCloseTo(0, EPSILON);
            expect(mz.eval('cos(pi)')).toBe(-1);
            expect(mz.eval('cos(pi * 3 / 2)')).toBeCloseTo(0, EPSILON);
            expect(mz.eval('cos(pi * 2)')).toBe(1);
        });

        it('should return the cosine of a boolean', () => {
            expect(mz.eval('cos(true)')).toBeCloseTo(Math.cos(1), EPSILON);
            expect(mz.eval('cos(false)')).toBe(1);
        });

        it('should return the cosine of an angle unit', () => {
            expect(mz.eval('cos(180 deg)')).toBe(-1);
            expect(mz.eval('cos(60 deg)')).toBeCloseTo(0.5, EPSILON);
        });
    });

    describe('tan', () => {
        it('should return the tangent of a number', () => {
            expect(mz.eval('tan(0)')).toBe(0);
            expect(mz.eval('tan(pi / 4)')).toBeCloseTo(1, EPSILON);
            expect(mz.eval('tan(pi)')).toBeCloseTo(0, EPSILON);
        });

        it('should return the tangent of an angle unit', () => {
            expect(mz.eval('tan(45 deg)')).toBeCloseTo(1, EPSILON);
        });
    });

    describe('inverse functions', () => {
        it('should return the inverse sine (asin)', () => {
            expect(mz.eval('asin(1)')).toBeCloseTo(Math.PI / 2, EPSILON);
            expect(mz.eval('asin(0)')).toBe(0);
        });

        it('should return the inverse cosine (acos)', () => {
            expect(mz.eval('acos(0)')).toBeCloseTo(Math.PI / 2, EPSILON);
            expect(mz.eval('acos(1)')).toBe(0);
        });

        it('should return the inverse tangent (atan)', () => {
            expect(mz.eval('atan(1)')).toBeCloseTo(Math.PI / 4, EPSILON);
            expect(mz.eval('atan(0)')).toBe(0);
        });

        it('should return the four-quadrant inverse tangent (atan2)', () => {
            expect(mz.eval('atan2(1, 1)')).toBeCloseTo(Math.PI / 4, EPSILON);
            expect(mz.eval('atan2(1, 0)')).toBeCloseTo(Math.PI / 2, EPSILON);
            expect(mz.eval('atan2(0, 1)')).toBe(0);
            expect(mz.eval('atan2(-1, 0)')).toBeCloseTo(-Math.PI / 2, EPSILON);
        });
    });

    describe('sec, csc, cot', () => {
        it('should return the secant of a number', () => {
            expect(mz.eval('sec(0)')).toBe(1);
        });
        it('should return the cosecant of a number', () => {
            expect(mz.eval('csc(pi / 2)')).toBe(1);
        });
        it('should return the cotangent of a number', () => {
            expect(mz.eval('cot(pi / 4)')).toBeCloseTo(1, EPSILON);
        });
    });

    describe('hyperbolic functions', () => {
        it('should return the hyperbolic sine (sinh)', () => {
            expect(mz.eval('sinh(0)')).toBe(0);
            expect(mz.eval('sinh(1)')).toBeCloseTo(Math.sinh(1), EPSILON);
        });

        it('should return the hyperbolic cosine (cosh)', () => {
            expect(mz.eval('cosh(0)')).toBe(1);
            expect(mz.eval('cosh(1)')).toBeCloseTo(Math.cosh(1), EPSILON);
        });

        it('should return the hyperbolic tangent (tanh)', () => {
            expect(mz.eval('tanh(0)')).toBe(0);
            expect(mz.eval('tanh(1)')).toBeCloseTo(Math.tanh(1), EPSILON);
        });

        it('should return the inverse hyperbolic sine (asinh)', () => {
            expect(mz.eval('asinh(0)')).toBe(0);
        });

        it('should return the inverse hyperbolic cosine (acosh)', () => {
            expect(mz.eval('acosh(1)')).toBe(0);
        });

        it('should return the inverse hyperbolic tangent (atanh)', () => {
            expect(mz.eval('atanh(0)')).toBe(0);
        });
    });
});
