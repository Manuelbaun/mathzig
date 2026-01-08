/**
 * Probability Specs
 * 
 * Ported from tests/zig/probability_tests.zig
 */

import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig } from '../../../src/ts/mathzig';

describe('Probability Functions', () => {
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

    it('should generate random numbers', () => {
        for (let i = 0; i < 100; i++) {
            const val = evalNum('random()');
            expect(val).toBeGreaterThanOrEqual(0);
            expect(val).toBeLessThan(1.0);
        }
    });

    it('should generate random numbers in range', () => {
        for (let i = 0; i < 100; i++) {
            const val = evalNum('random(10.0)');
            expect(val).toBeGreaterThanOrEqual(0);
            expect(val).toBeLessThanOrEqual(10.0);
        }
    });

    it('should generate random integers in range', () => {
        for (let i = 0; i < 100; i++) {
            const val = evalNum('randomInt(5, 15)');
            expect(val).toBeGreaterThanOrEqual(5);
            expect(val).toBeLessThan(15);
            expect(Number.isInteger(val)).toBe(true);
        }
    });

    it('should pick random element from matrix', () => {
        for (let i = 0; i < 100; i++) {
            const val = evalNum('pickRandom([10, 20, 30])');
            expect([10, 20, 30]).toContain(val);
        }
    });
});