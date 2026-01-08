import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Value, ValueTag } from '../../../src/ts/mathzig';

describe('VM Core Operations', () => {
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

    describe('Scalar Evaluation', () => {
        it('should evaluate simple arithmetic expressions', () => {
            expect(evalNum('1 + 2')).toBe(3);
            expect(evalNum('10 * 20')).toBe(200);
            expect(evalNum('100 / 4')).toBe(25);
            expect(evalNum('5 - 2')).toBe(3);
        });

        it('should evaluate expressions with variables', () => {
            mathzig.setVariable('x', 5);
            const compiled = mathzig.compile('x * x + 1');
            const res = compiled.evaluate();
            expect(res).toBe(26);
            compiled.free();
        });
    });

    describe('Type Support', () => {
        it('should handle complex numbers', () => {
            const res = mathzig.eval('1 + 2i');
            expect(res instanceof Value).toBe(true);
            if (res instanceof Value) {
                expect(res.type).toBe(ValueTag.Complex);
                res.release();
            }
        });

        it('should handle matrices', () => {
            const res = mathzig.eval('[1, 2; 3, 4]');
            expect(res).toBeDefined();
            if (res instanceof Value) {
                expect(res.type).toBe(ValueTag.Matrix);
                res.release();
            }
        });
    });

    describe('Error Handling', () => {
        it('should handle division by zero gracefully', () => {
            // 1 / 0 returns Infinity (mathematically correct)
            const result = mathzig.eval('1 / 0') as number;
            expect(result).toBe(Infinity);
        });

        it('should report syntax errors', () => {
            expect(() => mathzig.compile('1 + * 2')).toThrow();
        });
    });

    describe('Compiled Expression Structure', () => {
        it('should provide correct bytecode metadata', () => {
            const compiled = mathzig.compile('x * x + 2 * x + 1');
            expect(compiled.getBytecodeSize()).toBeGreaterThan(0);
            expect(compiled.getStackSize()).toBeGreaterThan(0);
            compiled.free();
        });
    });
});
