/**
 * Time-Series Specs
 * 
 * Tests for time-series operations: aggregations, calculus, indicators, resampling.
 * Related docs: docs/guides/guide_timeseries.md, docs/plans/time_series_plan.md
 */

import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig } from '../../../src/ts/mathzig';

describe('Time-Series Operations', () => {
    let mathzig: MathZig;

    beforeAll(() => {
        mathzig = MathZig.create();
    });

    afterAll(() => {
        mathzig.destroy();
    });

    const evalNum = (expr: string): number => {
        const res = mathzig.eval(expr);
        if (typeof res === 'number') return res;
        if (res instanceof Value) {
            const val = res.toNumber();
            res.release();
            return val;
        }
        return Number(res);
    };

    describe('Series Creation', () => {
        it('should create a series from arrays', () => {
            const result = mathzig.eval('series([0, 5, 12, 30], [10, 10, 20, 15])');
            expect(result).toBeDefined();
            result.release();
        });
    });

    describe('Aggregations', () => {
        it('should compute sum', () => {
            expect(evalNum('sum(series([1, 2, 3, 4, 5], [10, 20, 30, 40, 50]))')).toBe(150);
        });

        it('should compute cumulative sum', () => {
            expect(evalNum('last(cumsum(series([1, 2, 3], [10, 20, 30])))')).toBe(60);
        });

        it('should compute cumulative max', () => {
            expect(evalNum('last(cummax(series([1, 2, 3], [10, 5, 30])))')).toBe(30);
        });

        it('should compute mean', () => {
            expect(evalNum('mean(series([1, 2, 3], [10, 20, 30]))')).toBe(20);
        });

        it('should compute min and max', () => {
            expect(evalNum('min(series([1, 2, 3], [10, 5, 30]))')).toBe(5);
            expect(evalNum('max(series([1, 2, 3], [10, 5, 30]))')).toBe(30);
        });

        it('should compute TWA (Time-Weighted Average)', () => {
            expect(evalNum('twa(series([0, 5, 12, 30], [10, 10, 20, 15]))')).toBeGreaterThan(0);
        });

        it('should handle single point TWA', () => {
            expect(evalNum('twa(series([100], [42.0]))')).toBe(42.0);
        });
    });

    describe('Rolling Operations', () => {
        it('should compute sample-based rolling sum', () => {
            expect(evalNum('last(rolling_sum(series([1, 2, 3, 4, 5], [10, 20, 30, 40, 50]), 2))')).toBe(90);
        });

        it('should compute sample-based rolling mean', () => {
            expect(evalNum('last(rolling_mean(series([1, 2, 3, 4, 5], [10, 20, 30, 40, 50]), 2))')).toBe(45);
        });

        it('should compute duration-based rolling sum', () => {
            expect(evalNum('last(rolling_sum(series([0, 5, 10, 12], [10, 10, 20, 15]), 5s))')).toBe(35); 
        });
    });

    describe('Calculus Operations', () => {
        it('should compute derivative', () => {
            expect(evalNum('last(derivative(series([0, 1, 2], [0, 10, 20])))')).toBe(10);
        });

        it('should compute n-period difference', () => {
            expect(evalNum('last(diff(series([1, 2, 3], [10, 20, 50]), 1))')).toBe(30);
        });

        it('should compute percentage change', () => {
            expect(evalNum('last(pct_change(series([1, 2, 3], [10, 20, 50]), 1))')).toBe(1.5);
        });

        it('should compute integral correctly with gaps', () => {
            expect(evalNum('last(integrate(series([0, 5, 105, 115], [10, 10, 0, 20])))')).toBeCloseTo(650, 0);
        });
    });

    describe('Technical Indicators', () => {
        it('should compute SMA (Simple Moving Average)', () => {
            const result = mathzig.eval('sma(series([1, 2, 3, 4, 5], [1, 2, 3, 4, 5]), 3)');
            expect(result).toBeDefined();
            result.release();
        });

        it('should compute EMA (Exponential Moving Average)', () => {
            const result = mathzig.eval('ema(series([1, 2, 3, 4, 5], [1, 2, 3, 4, 5]), 3)');
            expect(result).toBeDefined();
            result.release();
        });

        it('should compute RSI (Relative Strength Index)', () => {
            const result = evalNum('last(rsi(series([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30], [0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10, 0, 10]), 14))');
            expect(result).toBeGreaterThan(45);
            expect(result).toBeLessThan(55);
        });

        it('should compute SMA correctly for constant input', () => {
            expect(evalNum('last(sma(series([1, 2, 3, 4, 5], [10, 10, 10, 10, 10]), 3))')).toBe(10);
        });
    });

    describe('Resampling', () => {
        it('should resample to regular intervals', () => {
            const result = mathzig.eval('resample(series([0, 5, 12, 30], [10, 10, 20, 15]), 10s)');
            expect(result).toBeDefined();
            result.release();
        });
    });

    describe('Predicates & Filtering', () => {
        it('should filter with where clause', () => {
            expect(evalNum('mean(series([1, 2, 3, 4], [10, -5, 20, -3])) where value > 0')).toBe(15);
        });

        it('should filter by time', () => {
            expect(evalNum('sum(series([0, 100, 200], [1, 2, 3])) where time >= 100')).toBe(5);
        });

        it('should filter by dt (gap detection)', () => {
            expect(evalNum('last(derivative(series([0, 1, 10, 11], [0, 10, 5, 15])) where dt < 5s)')).toBe(10);
        });
    });

    describe('Alignment & Joins', () => {
        it('should align two series', () => {
            const result = mathzig.eval('align(series([0, 5], [1, 2]), series([3, 8], [3, 4]))');
            expect(result).toBeDefined();
            result.release();
        });

        it('should perform series arithmetic', () => {
            const s1 = 'series([0, 20], [10, 20])';
            const s2 = 'series([10, 30], [100, 200])';
            expect(evalNum(`twa(${s1} + ${s2})`)).toBe(142.5);
        });

        it('should perform as-of join correctly', () => {
            expect(evalNum('last(asof_join([0, 2, 4, 6], series([1, 3, 5], [100, 101, 102])))')).toBe(102);
        });
    });

    describe('Selection & Filtering Functions', () => {
        it('should get head(n)', () => {
            expect(evalNum('last(head(series([1, 2, 3, 4, 5], [10, 20, 30, 40, 50]), 2))')).toBe(20);
        });

        it('should get tail(n)', () => {
            expect(evalNum('last(tail(series([1, 2, 3, 4, 5], [10, 20, 30, 40, 50]), 2))')).toBe(50);
        });

        it('should slice by time', () => {
            expect(evalNum('last(slice(series([0, 10, 20, 30, 40], [1, 2, 3, 4, 5]), 10, 35))')).toBe(4);
        });

        it('should shift series', () => {
            expect(evalNum('last(shift(series([0, 1, 2], [10, 20, 30]), 1))')).toBe(20);
        });
    });

    describe('Null & NaN Handling', () => {
        it('should dropna', () => {
            expect(evalNum('len(dropna(series([0, 1, 2], [10, nan, 30])))')).toBe(2);
        });

        it('should fillna with constant', () => {
            expect(evalNum('last(head(fillna(series([0, 1, 2], [10, nan, 30]), 0), 2))')).toBe(0);
        });

        it('should fillna with forward method', () => {
            expect(evalNum('last(head(fillna(series([0, 1, 2], [10, nan, 30]), "forward"), 2))')).toBe(10);
        });

        it('should fillna with linear method', () => {
            expect(evalNum('last(head(fillna(series([0, 1, 2], [10, nan, 30]), "linear"), 2))')).toBe(20);
        });

        it('should clip values', () => {
            expect(evalNum('last(clip(series([0, 1, 2], [-10, 50, 110]), 0, 100))')).toBe(100);
        });
    });
});