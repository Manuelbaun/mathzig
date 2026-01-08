/**
 * Compiler Specs
 * 
 * Tests for expression parsing, tokenization, and bytecode generation.
 * Related docs: docs/internals/compiler.md, docs/internals/bytecode.md
 */

import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig } from '../../../src/ts/mathzig';

describe('Parser & Tokenizer', () => {
    let mathzig: MathZig;

    beforeAll(() => {
        mathzig = MathZig.create();
    });

    afterAll(() => {
        mathzig.destroy();
    });

    describe('Number Parsing', () => {
        it('should parse integers', () => {
            const res = mathzig.eval('42');
            expect(res).toBe(42);
        });

        it('should parse floating point numbers', () => {
            const res = mathzig.eval('3.14159');
            expect(res).toBeCloseTo(3.14159, 5);
        });

        it('should parse scientific notation', () => {
            let res = mathzig.eval('1.5e3');
            expect(res).toBe(1500);

            res = mathzig.eval('1.5e-3');
            expect(res).toBeCloseTo(0.0015, 10);
        });

        it('should parse hex numbers', () => {
            let res = mathzig.eval('0xFF');
            expect(res).toBe(255);

            res = mathzig.eval('0x10');
            expect(res).toBe(16);
        });

        it('should parse binary numbers', () => {
            const res = mathzig.eval('0b1010');
            expect(res).toBe(10);
        });

        it('should parse underscores in numbers', () => {
            const res = mathzig.eval('1_000_000');
            expect(res).toBe(1000000);
        });

        it('should parse imaginary numbers and handle complex arithmetic', () => {
            // eval returns NaN for non-scalars (complex with im != 0) when cast to number if we used toNumber()
            // But here it returns a Value object for complex numbers
            let res = mathzig.eval('10i');
            // Check if it's a value object and release it
            expect(typeof res).not.toBe('number');
            if (typeof res !== 'number' && res) res.release();

            res = mathzig.eval('3 + 4i');
            expect(typeof res).not.toBe('number');
            if (typeof res !== 'number' && res) res.release();

            // (3 + 4i) - 4i should be 3 (scalar)
            res = mathzig.eval('(3 + 4i) - 4i');
            expect(res).toBe(3);
        });
    });

    describe('Operator Parsing', () => {
        it('should handle arithmetic operators', () => {
            let res = mathzig.eval('10 + 5');
            expect(res).toBe(15);

            res = mathzig.eval('10 - 5');
            expect(res).toBe(5);

            res = mathzig.eval('10 * 5');
            expect(res).toBe(50);

            res = mathzig.eval('10 / 5');
            expect(res).toBe(2);

            res = mathzig.eval('10 % 3');
            expect(res).toBe(1);
        });

        it('should handle power operator', () => {
            let res = mathzig.eval('2 ^ 10');
            expect(res).toBe(1024);

            res = mathzig.eval('9 ^ 0.5');
            expect(res).toBeCloseTo(3, 10);
        });

        it('should respect operator precedence', () => {
            let res = mathzig.eval('2 + 3 * 4');
            expect(res).toBe(14);

            res = mathzig.eval('(2 + 3) * 4');
            expect(res).toBe(20);
        });

        it('should handle comparison operators', () => {
            // Comparison operators return boolean values
            let res = mathzig.eval('5 > 3');
            expect(res).toBe(true);

            res = mathzig.eval('5 < 3');
            expect(res).toBe(false);

            res = mathzig.eval('5 == 5');
            expect(res).toBe(true);
        });

        it('should handle logical operators', () => {
            // 'and'/'or' return numeric (short-circuit returns last evaluated value)
            // 'not' returns boolean
            let res = mathzig.eval('1 and 1');
            expect(res).toBe(1);

            res = mathzig.eval('1 or 0');
            expect(res).toBe(1);

            res = mathzig.eval('not 0');
            expect(res).toBe(true);
        });
    });

    describe('Function Calls', () => {
        it('should parse math functions', () => {
            let res = mathzig.eval('abs(-5)');
            expect(res).toBe(5);

            res = mathzig.eval('sqrt(16)');
            expect(res).toBe(4);

            res = mathzig.eval('floor(3.7)');
            expect(res).toBe(3);

            res = mathzig.eval('ceil(3.2)');
            expect(res).toBe(4);
        });

        it('should parse trigonometric functions', () => {
            let res = mathzig.eval('sin(0)');
            expect(res).toBeCloseTo(0, 10);

            res = mathzig.eval('cos(0)');
            expect(res).toBeCloseTo(1, 10);

            res = mathzig.eval('tan(0)');
            expect(res).toBeCloseTo(0, 10);
        });

        it('should handle function composition', () => {
            const r1 = mathzig.eval('sin(cos(0))');
            const r2 = mathzig.eval('sin(1)');
            expect(r1).toBeCloseTo(r2 as number, 10);
        });
    });

    describe('Variables', () => {
        it('should parse variable assignments', () => {
            mathzig.setVariable('x', 10);
            const res = mathzig.eval('x');
            expect(res).toBe(10);
        });

        it('should handle multiple variables', () => {
            mathzig.setVariable('a', 3);
            mathzig.setVariable('b', 4);
            const res = mathzig.eval('a * a + b * b');
            expect(res).toBe(25); // 3² + 4²
        });
    });

    describe('Error Cases', () => {
        it('should report unmatched parentheses', () => {
            expect(() => mathzig.compile('(1 + 2')).toThrow();
        });

        it('should report invalid syntax', () => {
            // Test actual syntax errors (note: $ is a valid variable character)
            expect(() => mathzig.compile('1 ++ 2')).toThrow();
        });
    });
});

describe('Compiler Optimizations', () => {
    let mathzig: MathZig;

    beforeAll(() => {
        mathzig = MathZig.create();
    });

    afterAll(() => {
        mathzig.destroy();
    });

    describe('Constant Folding', () => {
        it('should fold constant expressions at compile time', () => {
            // 2 + 3 should be compiled as a single constant
            const compiled = mathzig.compile('2 + 3');
            expect(compiled.evaluateFast()).toBe(5);
            compiled.free();
        });

        it('should fold nested constants', () => {
            const compiled = mathzig.compile('(1 + 2) * (3 + 4)');
            expect(compiled.evaluateFast()).toBe(21);
            compiled.free();
        });
    });

    describe('FMA Fusion', () => {
        it('should fuse multiply-add patterns', () => {
            // x * 0.5 + 2.0 should be optimized to FMA
            const xIdx = mathzig.addVariableIndexed('x', 0);
            const compiled = mathzig.compile('x * 0.5 + 2.0');
            
            mathzig.setByIndex(xIdx, 10);
            expect(compiled.evaluateFast()).toBeCloseTo(7, 10);
            
            compiled.free();
        });
    });
});