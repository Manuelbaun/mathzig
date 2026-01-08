/**
 * Units Specs
 * 
 * Tests for unit system, conversions, and dimensional analysis.
 * Related docs: docs/internals/units.md
 */

import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Value, ValueTag } from '../../../src/ts/mathzig';

describe('Unit System', () => {
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

    describe('SI Base Units', () => {
        it('should recognize length units', () => {
            const result = mathzig.eval('1m');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize bracket-style unit literals', () => {
            expect(evalNum('10 [m]')).toBe(10);
        });

        it('should recognize mass units', () => {
            const result = mathzig.eval('1kg');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize time units', () => {
            const result = mathzig.eval('1s');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize current units', () => {
            const result = mathzig.eval('1A');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize temperature units', () => {
            const result = mathzig.eval('1K');
            expect(result).toBeDefined();
            result.release();
        });
    });

    describe('SI Derived Units', () => {
        it('should recognize frequency (Hz)', () => {
            const result = mathzig.eval('1Hz');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize force (N)', () => {
            const result = mathzig.eval('1N');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize energy (J)', () => {
            const result = mathzig.eval('1J');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize power (W)', () => {
            const result = mathzig.eval('1W');
            expect(result).toBeDefined();
            result.release();
        });

        it('should recognize pressure (Pa)', () => {
            const result = mathzig.eval('1Pa');
            expect(result).toBeDefined();
            result.release();
        });
    });

    describe('SI Prefixes', () => {
        it('should handle metric prefixes', () => {
            let res = mathzig.eval('1km');
            expect(res).toBeDefined();
            res.release();

            res = mathzig.eval('1mW');
            expect(res).toBeDefined();
            res.release();

            res = mathzig.eval('1MHz');
            expect(res).toBeDefined();
            res.release();

            res = mathzig.eval('1ns');
            expect(res).toBeDefined();
            res.release();
        });

        it('should correctly scale prefixed units', () => {
            // 1 km = 1000 m
            const km = mathzig.eval('1km');
            const m = mathzig.eval('1000m');
            expect(km.toNumber()).toBe(m.toNumber());
            km.release();
            m.release();
        });
    });

    describe('Unit Arithmetic', () => {
        it('should add compatible units', () => {
            const result = mathzig.eval('1m + 1m');
            expect(result).toBeDefined();
            result.release();
        });

        it('should subtract compatible units', () => {
            const result = mathzig.eval('5m - 2m');
            expect(result).toBeDefined();
            result.release();
        });

        it('should multiply units', () => {
            const result = mathzig.eval('1m * 1s');
            expect(result).toBeDefined();
            result.release();
        });

        it('should divide units', () => {
            const result = mathzig.eval('1m / 1s');
            expect(result).toBeDefined();
            result.release();
        });

        it('should handle power of units', () => {
            const result = mathzig.eval('1m ^ 2');
            expect(result).toBeDefined();
            result.release();
        });

        it('should handle complex unit multiplication and division', () => {
            // 1000 kg / (1m * 1m * 1m) = 1000 kg/m^3
            expect(evalNum('1000 [kg] / (1 [m] * 1 [m] * 1 [m])')).toBe(1000);
        });
    });

    describe('Unit Conversions', () => {
        it('should convert between length units', () => {
            // 1 m = 100 cm
            const m = mathzig.eval('1m');
            const cm = mathzig.eval('100cm');
            expect(m.toNumber()).toBe(cm.toNumber());
            m.release();
            cm.release();
        });

        it('should convert between mass units', () => {
            // 1 kg = 1000 g
            const kg = mathzig.eval('1kg');
            const g = mathzig.eval('1000g');
            expect(kg.toNumber()).toBe(g.toNumber());
            kg.release();
            g.release();
        });

        it('should convert between time units', () => {
            // 1 h = 3600 s
            const h = mathzig.eval('1h');
            const s = mathzig.eval('3600s');
            expect(h.toNumber()).toBe(s.toNumber());
            h.release();
            s.release();
        });

        it('should convert compound units', () => {
            // 1 km/h = 1000/3600 m/s
            const kmh = evalNum('1km/h');
            const ms = evalNum('1000/3600m/s');
            expect(kmh).toBeCloseTo(ms, 10);
        });

        it('should handle temperature conversions', () => {
            // 100 degC = 212 degF
            const f = evalNum('conv(100degC, degF)');
            expect(f).toBeCloseTo(212, 5);

            mathzig.setVariable('f_val', f);
            const c = evalNum('conv(f_val * degF, degC)');
            expect(c).toBeCloseTo(100, 5);
        });

        it('should handle complex compound unit conversions', () => {
            // Density * Flow = Mass Flow
            // 1000 kg/m^3 * 2 m^3/h = 2000 kg/h
            // 2000 kg/h = 2000000 g / 3600 s = 555.55... g/s
            const res = evalNum('conv(1000kg/m^3 * 2m^3/h, g/s)');
            expect(res).toBeCloseTo(555.555555, 5);
        });
    });

    describe('Dimensional Analysis', () => {
        it('should track dimensions', () => {
            const velocity = mathzig.eval('10m/s');
            expect(velocity).toBeDefined();
            velocity.release();
        });

        it('should detect dimension mismatches', () => {
            // Adding meters to seconds should fail or give NaN
            let didFail = false;
            let isNaNResult = false;
            try {
                const result = evalNum('1m + 1s');
                isNaNResult = isNaN(result);
            } catch {
                didFail = true;
            }
            expect(didFail || isNaNResult).toBe(true);
        });

        it('should simplify derived dimensions', () => {
            // N (newton) = kg·m/s²
            const n = evalNum('1N');
            const kgms2 = evalNum('1kg*m/s^2');
            expect(n).toBe(kgms2);
        });
    });

    describe('Physical Constants', () => {
        it('should have speed of light', () => {
            expect(evalNum('speedOfLight')).toBeCloseTo(299792458, 0);
        });

        it('should have Planck constant', () => {
            expect(evalNum('planckConstant')).toBeCloseTo(6.62607015e-34, 40);
        });

        it('should have gravitational constant', () => {
            expect(evalNum('gravitationalConstant')).toBeCloseTo(6.67430e-11, 15);
        });
    });

    describe('Complex Expressions', () => {
        it('should handle complex unit expressions', () => {
            // Kinetic energy: 0.5 * m * v^2
            expect(evalNum('0.5 * 1kg * (10m/s)^2')).toBeCloseTo(50, 0); // 0.5 * 1 * 100 = 50 J
        });

        it('should handle power calculations', () => {
            // Power = Energy / Time
            expect(evalNum('100J / 10s')).toBeCloseTo(10, 0); // 10 W
        });

        it('should handle pressure calculations', () => {
            // Pressure = Force / Area
            expect(evalNum('100N / 2m^2')).toBeCloseTo(50, 0); // 50 Pa
        });
    });

    describe('Unit Variables', () => {
        it('should preserve units when multiplying unit variables', () => {
            mathzig.eval('G = 6.67408e-11 m^3 / (kg * s^2)');
            mathzig.eval('mbody = 5.9724e24 kg');
            mathzig.eval('mu = G * mbody');
            const mu = evalNum('conv(mu, m^3/s^2)');
            expect(mu).toBeGreaterThan(0);
        });
    });
});
