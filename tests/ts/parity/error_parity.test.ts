import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Matrix, Vector, Series, Value, SampleMode } from '../../../src/ts/mathzig';

describe('Error Parity (Zig to TS)', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    describe('Compiler Errors', () => {
        it('should throw on syntax errors', () => {
            expect(() => mz.compile('2 + * 3')).toThrow();
        });

        it('should return 0 for undefined variables in direct eval (auto-created)', () => {
            expect(mz.eval('nonexistent_var')).toBe(0);
        });

        it('should throw on invalid unit conversions', () => {
            expect(() => mz.eval('conv(10[m], [kg])')).toThrow();
        });
    });

    describe('Runtime Errors', () => {
        it('should return false when inverting a singular matrix', () => {
            const m = new Matrix(2, 2);
            m.data.set([1, 2, 2, 4]); // Singular: 1*4 - 2*2 = 0
            expect(m.inverse()).toBe(false);
        });

        it('should handle division by zero in VM by returning Infinity', () => {
            // In MathZig, division by zero results in Inf or NaN, not a throw
            expect(mz.eval('10 / 0')).toBe(Infinity);
        });
    });

    describe('Validation Errors', () => {
        it('should fail to create series with unsorted timestamps', () => {
            const ts = new Float64Array([2000, 1000, 3000]);
            const vs = new Float64Array([1, 2, 3]);
            expect(() => mz.createSeries(ts, vs, SampleMode.Linear)).toThrow();
        });
    });
});
