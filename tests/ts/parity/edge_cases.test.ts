import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Matrix, Vector, Series, Value, SampleMode } from '../../../src/ts/mathzig';

describe('API Edge Cases', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    describe('NaN and Infinity Handling', () => {
        it('should propagate NaN through arithmetic', () => {
            expect(mz.eval('NaN + 10')).toBeNaN();
            expect(mz.eval('10 / 0')).toBe(Infinity);
            expect(mz.eval('0 / 0')).toBeNaN();
        });

        it('should handle NaN in matrices', () => {
            const m = new Matrix(2, 2);
            m.data.set([1, NaN, 3, 4]);
            expect(m.sum()).toBeNaN();
            expect(m.mean()).toBeNaN();
        });

        it('should handle NaN in series', () => {
            const ts = new Float64Array([0, 1, 2]);
            const vs = new Float64Array([10, NaN, 30]);
            const series = mz.createSeries(ts, vs, SampleMode.Linear);

            // Set the series as a variable first
            mz.setSeries('s', series.handle);

            // Series mean skips NaN values, computing mean of valid values only
            // mean([10, 30]) = 20
            expect(mz.eval('mean(s)')).toBe(20);
            series.free();
        });
    });

    describe('Empty and Small Collections', () => {
        it('should handle 1x1 matrices', () => {
            const m = new Matrix(1, 1);
            m.data[0] = 42;
            expect(m.sum()).toBe(42);
            expect(m.determinant()).toBe(42);
            
            const success = m.inverse();
            expect(success).toBe(true);
            expect(m.data[0]).toBeCloseTo(1/42);
        });

        it('should handle zero-length series duration', () => {
            const ts = new Float64Array([100]);
            const vs = new Float64Array([42]);
            const series = mz.createSeries(ts, vs, SampleMode.Step);
            expect(series.duration()).toBe(0);
            series.free();
        });
    });

    describe('Large Input Stress', () => {
        it('should handle large matrices without crashing', () => {
            const size = 100;
            const m = new Matrix(size, size);
            m.data.fill(1.0);
            expect(m.sum()).toBe(size * size);
        });
    });
});
