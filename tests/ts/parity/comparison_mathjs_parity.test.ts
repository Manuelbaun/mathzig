import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Value } from '../../../src/ts/mathzig';
import * as mathjs from 'mathjs';

describe('MathJS vs MathZig Comparison', () => {
    let mzig: MathZig;

    beforeAll(() => {
        mzig = MathZig.create();
    });

    afterAll(() => {
        mzig.destroy();
    });

    const compare = (expr: string, options: { iterations?: number, epsilon?: number, useWarm?: boolean } = {}) => {
        const { iterations = 1, epsilon = 1e-10, useWarm = false } = options;

        let resJS: any;
        let finalTimeJS: number;

        // MathJS
        const startJSVal = performance.now();
        if (useWarm) {
            const compiledJS = mathjs.compile(expr);
            for (let i = 0; i < iterations; i++) resJS = compiledJS.evaluate();
        } else {
            for (let i = 0; i < iterations; i++) resJS = mathjs.evaluate(expr);
        }
        finalTimeJS = (performance.now() - startJSVal) / iterations;

        // MathZig
        let resZigRaw: any;
        const startZigVal = performance.now();
        if (useWarm) {
            const compiledZig = mzig.compile(expr);
            for (let i = 0; i < iterations; i++) resZigRaw = compiledZig.evaluate();
            compiledZig.free();
        } else {
            for (let i = 0; i < iterations; i++) resZigRaw = mzig.eval(expr);
        }
        const finalTimeZig = (performance.now() - startZigVal) / iterations;

        // Unwrap results
        let valJS = resJS;
        if (typeof resJS === 'object' && resJS !== null) {
            if (resJS.toArray) valJS = resJS.toArray();
            else if (resJS.re !== undefined) valJS = { re: resJS.re, im: resJS.im };
        }

        let valZig = resZigRaw;
        if (resZigRaw instanceof Value) {
            const tag = resZigRaw.tag;
            if (tag === 0) valZig = resZigRaw.toNumber();
            else if (tag === 3) {
                valZig = "[Matrix]";
            } else if (tag === 1) {
                const c = (resZigRaw as any).data.complex;
                valZig = { re: c.re, im: c.im };
            }
            resZigRaw.release();
        }

        const speedup = finalTimeJS / finalTimeZig;
        console.log(`[COMP] ${expr.slice(0, 40)}${expr.length > 40 ? '...' : ''}`);
        console.log(`  MathJS:  ${finalTimeJS.toFixed(6)}ms`);
        console.log(`  MathZig: ${finalTimeZig.toFixed(6)}ms (${speedup.toFixed(2)}x faster)`);

        return { valJS, valZig, timeJS: finalTimeJS, timeZig: finalTimeZig, speedup };
    };

    describe('Basic Arithmetic', () => {
        it('should match arithmetic: 1 + 2 * 3 / 4', () => {
            const { valJS, valZig } = compare('1 + 2 * 3 / 4', { iterations: 1000, useWarm: true });
            expect(valZig).toBeCloseTo(valJS, 10);
        });

        it('should match complex arithmetic literals: 1 + 2i', () => {
            const resJS = mathjs.evaluate('1 + 2i') as any;
            const reZig = mzig.eval('re(1 + 2i)');
            const imZig = mzig.eval('im(1 + 2i)');
            
            expect(reZig).toBe(resJS.re);
            expect(imZig).toBe(resJS.im);
        });
    });

    describe('Matrix Operations', () => {
        it('should match matrix multiplication sum (2x2)', () => {
            const expr = 'sum([1, 2; 3, 4] * [5, 6; 7, 8])';
            const { valJS, valZig } = compare(expr, { iterations: 100, useWarm: true });
            expect(valZig).toBeCloseTo(valJS, 10);
        });

        it('should match determinant', () => {
            const expr = 'det([1, 2; 3, 4])';
            const { valJS, valZig } = compare(expr, { iterations: 100, useWarm: true });
            expect(valZig).toBeCloseTo(valJS, 10);
        });

        it('should match matrix inversion sum', () => {
            const expr = 'sum(inv([1, 2; 3, 4]))';
            const { valJS, valZig } = compare(expr, { iterations: 100, useWarm: true });
            expect(valZig).toBeCloseTo(valJS, 10);
        });

        it('should match element-wise operations', () => {
            const expr = 'sum([4, 6; 8, 10] ./ [2, 3; 4, 5])';
            const { valJS, valZig } = compare(expr, { iterations: 100, useWarm: true });
            expect(valZig).toBe(8); // (2+2+2+2)
        });
    });

    describe('Trigonometry & Functions', () => {
        it('should match sin/cos/exp', () => {
            const expr = 'sin(0.5) + cos(0.2) + exp(0.1)';
            const { valJS, valZig } = compare(expr, { iterations: 100, useWarm: true });
            expect(valZig).toBeCloseTo(valJS, 10);
        });

        it('should match log/sqrt/abs', () => {
            const expr = 'log(10) + sqrt(16) + abs(-5)';
            const { valJS, valZig } = compare(expr, { iterations: 100, useWarm: true });
            expect(valZig).toBeCloseTo(valJS, 10);
        });
    });

    describe('Units of Measurement', () => {
        it('should match unit conversion: 5 cm to inch', () => {
            const resJS = mathjs.evaluate('5 cm to inch') as any;
            const resZig = mzig.eval('conv(5 * cm, in)');
            
            const valJS = typeof resJS === 'number' ? resJS : resJS.toNumber('inch');
            const valZig = typeof resZig === 'number' ? resZig : (resZig as any).toNumber();
            
            expect(valZig).toBeCloseTo(valJS, 4);
            if (resZig instanceof Value) resZig.release();
        });
    });

    describe('Performance Benchmarks', () => {
        it('Large Matrix multiplication benchmark', () => {
            const n = 32;
            const rows: string[] = [];
            for (let i = 0; i < n; i++) {
                rows.push(Array(n).fill(1).join(','));
            }
            const mat = `[${rows.join(';')}]`;
            const expr = `sum(${mat} * ${mat})`;
            
            const { speedup } = compare(expr, { iterations: 10, useWarm: true });
            expect(speedup).toBeGreaterThan(0.1); 
        });

        it('Trig repeated evaluation benchmark', () => {
            const iterations = 1000;
            const expr = 'sin(0.5) * cos(0.5) + exp(0.1)';
            const { speedup } = compare(expr, { iterations, useWarm: true });
            expect(speedup).toBeDefined();
        });
    });
});
