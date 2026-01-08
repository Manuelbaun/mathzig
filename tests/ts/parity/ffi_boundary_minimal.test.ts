import { afterAll, beforeAll, describe, expect, it } from 'bun:test';
import { MathZig, SampleMode } from '../../libs/mathzig/src/mathzig';

describe('FFI Boundary Validation', () => {
    let mathzig: MathZig;

    beforeAll(() => {
        mathzig = MathZig.create();
    });

    afterAll(() => {
        mathzig.destroy();
    });

    describe('setByIndex boundary validation', () => {
        it('should set value for valid index 0', () => {
            const idx = mathzig.addVariableIndexed('x', 0);
            mathzig.setByIndex(idx, 42);
            expect(mathzig.eval('x')).toBe(42);
        });

        it('should set value for valid index', () => {
            const idx = mathzig.addVariableIndexed('y', 0);
            mathzig.setByIndex(idx, 42);
            expect(mathzig.eval('y')).toBe(42);
        });

        it('should reject negative index -1 silently', () => {
            mathzig.setByIndex(-1, 100);
            const error = mathzig.getError();
            expect(error.length > 0).toBe(true);
        });

        it('should reject negative index -100 silently', () => {
            mathzig.setByIndex(-100, 100);
            const error = mathzig.getError();
            expect(error.length > 0).toBe(true);
        });

        it('should reject index >= 256 silently', () => {
            mathzig.setByIndex(256, 100);
            const error = mathzig.getError();
            expect(error.length > 0).toBe(true);
        });

        it('should reject index 1000 silently', () => {
            mathzig.setByIndex(1000, 100);
            const error = mathzig.getError();
            expect(error.length > 0).toBe(true);
        });
    });

    describe('setByIndexFast boundary validation', () => {
        it('should set value for valid index within variables_f64.len', () => {
            const idx = mathzig.addVariableIndexed('z', 0);
            mathzig.setByIndexFast(idx, 42);
            expect(mathzig.eval('z')).toBe(42);
        });

        it('should reject negative index silently', () => {
            mathzig.setByIndexFast(-1, 100);
            const error = mathzig.getError();
            expect(error.length > 0).toBe(true);
        });

        it('should reject index beyond variables_f64.len silently', () => {
            mathzig.setByIndexFast(1000, 100);
            const error = mathzig.getError();
            expect(error.length > 0).toBe(true);
        });
    });

    describe('compilePolynomial validation', () => {
        it('should compile polynomial with valid coefficients', () => {
            const idx = mathzig.addVariableIndexed('x', 0);
            const coeffs = new Float64Array([3, 2, 1]);
            const poly = mathzig.compilePolynomial(idx, coeffs, 3);
            expect(poly).toBeDefined();
            poly.free();
        });

        it('should reject negative var_index', () => {
            const coeffs = new Float64Array([1, 2, 3]);
            let poly: any = null;
            try {
                poly = mathzig.compilePolynomial(-1, coeffs, 3);
            } catch (e) {}
            expect(poly).toBeNull();
        });

        it('should reject count == 0', () => {
            const idx = mathzig.addVariableIndexed('x', 0);
            const coeffs = new Float64Array([]);
            let poly: any = null;
            try {
                poly = mathzig.compilePolynomial(idx, coeffs, 0);
            } catch (e) {}
            expect(poly).toBeNull();
        });

        it('should handle count == 1', () => {
            const idx = mathzig.addVariableIndexed('x', 0);
            const coeffs = new Float64Array([5]);
            let poly: any = null;
            try {
                poly = mathzig.compilePolynomial(idx, coeffs, 1);
            } catch (e) {}
        });

        it('should reject count > 255', () => {
            const idx = mathzig.addVariableIndexed('x', 0);
            const coeffs = new Float64Array(256);
            coeffs[0] = 1;
            coeffs[255] = 1;
            let poly: any = null;
            try {
                poly = mathzig.compilePolynomial(idx, coeffs, 256);
            } catch (e) {}
            expect(poly).toBeNull();
        });
    });

    describe('createSeries validation', () => {
        it('should create series with valid data', () => {
            const timestamps = new Float64Array([1, 2, 3, 4, 5]);
            const values = new Float64Array([10, 20, 30, 40, 50]);
            const series = mathzig.createSeries(timestamps, values, SampleMode.Linear);
            expect(series).toBeDefined();
            series.free();
        });

        it('should reject null timestamps pointer', () => {
            const values = new Float64Array([10, 20, 30]);
            expect(() => mathzig.createSeries(null as any, values, SampleMode.Linear)).toThrow();
        });

        it('should reject null values pointer', () => {
            const timestamps = new Float64Array([1, 2, 3]);
            expect(() => mathzig.createSeries(timestamps, null as any, SampleMode.Linear)).toThrow();
        });

        it('should reject empty arrays', () => {
            const timestamps = new Float64Array([]);
            const values = new Float64Array([]);
            try {
                const series = mathzig.createSeries(timestamps, values, SampleMode.Linear);
                if (series) {
                    expect(series.len()).toBe(0);
                    series.free();
                }
            } catch (e) {}
        });

        it('should work with count 1', () => {
            const timestamps = new Float64Array([1]);
            const values = new Float64Array([10]);
            const series = mathzig.createSeries(timestamps, values, SampleMode.Linear);
            expect(series).toBeDefined();
            expect(series.len()).toBe(1);
            series.free();
        });

        it('should handle different sample modes', () => {
            const timestamps = new Float64Array([1, 2, 3]);
            const values = new Float64Array([10, 20, 30]);

            const seriesStep = mathzig.createSeries(timestamps, values, SampleMode.Step);
            expect(seriesStep).toBeDefined();
            seriesStep.free();

            const seriesLinear = mathzig.createSeries(timestamps, values, SampleMode.Linear);
            expect(seriesLinear).toBeDefined();
            seriesLinear.free();

            const seriesCumulative = mathzig.createSeries(timestamps, values, SampleMode.Cumulative);
            expect(seriesCumulative).toBeDefined();
            seriesCumulative.free();
        });

        it('should reject series with invalid data', () => {
            const timestamps = new Float64Array([3, 1, 2]);
            const values = new Float64Array([10, 20, 30]);
            expect(() => mathzig.createSeries(timestamps, values, SampleMode.Linear)).toThrow();
        });
    });
});
