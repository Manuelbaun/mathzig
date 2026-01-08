import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, ValueTag } from '../../../src/ts/mathzig';

describe('DSL Functions (FFI)', () => {
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
        if (typeof res === 'object' && res !== null && 'toNumber' in res) {
            const val = res.toNumber();
            res.release();
            return val;
        }
        return Number(res);
    };

    it('should define and call a simple function', () => {
        evalNum('f(x) = x * 2');
        expect(evalNum('f(10)')).toBe(20);
    });

    it('should list defined functions', () => {
        // "f" was defined in previous test
        const funcs = mathzig.getFunctions();
        expect(funcs).toContain('f');
    });

    it('should define multi-argument function', () => {
        evalNum('add(a, b) = a + b');
        expect(evalNum('add(5, 7)')).toBe(12);
        
        const funcs = mathzig.getFunctions();
        expect(funcs).toContain('add');
    });

    it('should handle function calling another function', () => {
        evalNum('double(x) = x * 2');
        evalNum('quad(x) = double(double(x))');
        expect(evalNum('quad(3)')).toBe(12);
    });

    it('should handle global variable capture (closure-like)', () => {
        evalNum('g = 100');
        evalNum('addG(x) = x + g');
        expect(evalNum('addG(50)')).toBe(150);
        
        // Update global
        evalNum('g = 200');
        expect(evalNum('addG(50)')).toBe(250);
    });

    it('should shadow global variable with parameter', () => {
        evalNum('p = 10');
        evalNum('shadow(p) = p * 2'); // parameter p should shadow global p
        expect(evalNum('shadow(5)')).toBe(10); // 5 * 2, not 10 * 2 or 10 + 5
    });
});
