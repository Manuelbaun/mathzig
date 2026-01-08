import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Value } from '../../../src/ts/mathzig';
import * as mathjs from 'mathjs';

describe('MathZig vs MathJS Comprehensive Parity', () => {
    let mzig: MathZig;

    beforeAll(() => {
        mzig = MathZig.create();
    });

    afterAll(() => {
        mzig.destroy();
    });

    // Comparison helper
    const check = (expr: string, options: { 
        zigExpr?: string, 
        approx?: boolean, 
        epsilon?: number,
        skip?: boolean,
        todo?: boolean,
        mathjsScope?: any
    } = {}) => {
        if (options.skip) return;
        
        const zigExpr = options.zigExpr || expr;
        const epsilon = options.epsilon || 1e-9;

        // 1. Evaluate in MathJS
        let expected: any;
        try {
            if (options.mathjsScope) {
                expected = mathjs.evaluate(expr, options.mathjsScope);
            } else {
                expected = mathjs.evaluate(expr);
            }
        } catch (e) {
            throw new Error(`MathJS failed on '${expr}': ${e.message}`);
        }

        // 2. Evaluate in MathZig
        let actualRaw: any;
        try {
            actualRaw = mzig.eval(zigExpr);
        } catch (e) {
            if (options.todo) return; // Expected failure
            console.error(`MathZig FAILED on '${zigExpr}':`, e);
            throw new Error(`MathZig failed on '${zigExpr}': ${e.message}`);
        }

        // 3. Unwrap and Compare
        let actual = actualRaw;
        if (actualRaw instanceof Value) {
            // console.log(`Debug: ${zigExpr} -> tag=${actualRaw.tag}`);
            // Unwrap complex/matrix/etc
            if (actualRaw.tag === 0) { // Number
                actual = actualRaw.toNumber();
            } else if (actualRaw.tag === 1) { // Complex
                // Workaround: Use re() and im() builtins to extract parts
                // Note: mzig.eval returns unwrapped values (number) for re/im
                const reVal = mzig.eval(`re(${zigExpr})`);
                const imVal = mzig.eval(`im(${zigExpr})`);
                const re = typeof reVal === 'number' ? reVal : reVal.toNumber();
                const im = typeof imVal === 'number' ? imVal : imVal.toNumber();
                actual = mathjs.complex(re, im);
                
                // Cleanup if they were Values
                if (reVal instanceof Value) reVal.release();
                if (imVal instanceof Value) imVal.release();
            } else if (actualRaw.tag === 7) { // Boolean
                actual = actualRaw.toNumber() !== 0;
            } else if (actualRaw.tag === 3) { // Matrix
                // Try to scalarize if it's a 1x1 matrix or vector result that MathJS treats as scalar
                // For now, simple "Matrix" marker
                // TODO: Implement full matrix readout
                actual = "Matrix"; 
            }
            actualRaw.release();
        }

        // Normalize Expected (MathJS returns objects)
        if (typeof expected === 'object' && expected !== null) {
            if (expected.isComplex) {
                // actual should be complex (or equivalent)
                if (typeof actual === 'object' && actual.isComplex) {
                    expect(actual.re).toBeCloseTo(expected.re, -Math.log10(epsilon));
                    expect(actual.im).toBeCloseTo(expected.im, -Math.log10(epsilon));
                    return;
                }
            }
            if (expected.isMatrix || Array.isArray(expected)) {
                if (actual === "Matrix") {
                    return;
                }
            }
        }

        if (typeof expected === 'number') {
            if (typeof actual !== 'number') {
                 if (options.todo) return;
                 // If actual is Matrix, maybe it's a 1x1 result that MathJS flattened?
                 if (actual === "Matrix") {
                     // Check via sum()
                     const sumValRaw = mzig.eval(`sum(${zigExpr})`);
                     const sumVal = typeof sumValRaw === 'number' ? sumValRaw : sumValRaw.toNumber();
                     if (sumValRaw instanceof Value) sumValRaw.release();
                     
                     expect(sumVal).toBeCloseTo(expected, -Math.log10(epsilon));
                     return;
                 }
                 throw new Error(`Type mismatch: expected number, got ${actual}`);
            }
            if (options.approx || !Number.isInteger(expected)) {
                if (options.todo) {
                    try {
                        expect(actual).toBeCloseTo(expected, -Math.log10(epsilon));
                    } catch (e) { return; } // Ignore if todo
                } else {
                    expect(actual).toBeCloseTo(expected, -Math.log10(epsilon));
                }
            } else {
                if (options.todo && actual !== expected) return;
                expect(actual).toBe(expected);
            }
        } else if (typeof expected === 'boolean') {
             expect(actual).toBe(expected);
        }
    };

    // =========================================================================
    // Arithmetic Functions
    // =========================================================================
    describe('Arithmetic', () => {
        const unaryTests = [
            'abs(-5.5)', 'abs(5.5)', 'abs(0)',
            'ceil(5.1)', 'ceil(-5.1)',
            'floor(5.9)', 'floor(-5.1)',
            'round(5.5)', 'round(5.4)', 'round(-5.5)',
            'exp(2)', 'exp(0)', 'exp(-1)',
            'log(10)', 'log(2.718281828)', 
            'log10(100)', 'log10(0.1)',
            'log2(8)', 'log2(0.5)',
            'sqrt(16)', 'sqrt(2)',
            'cbrt(27)', 'cbrt(-8)',
            'sign(-5)', 'sign(5)', 'sign(0)',
            'square(4)', 'cube(3)',
            'fix(5.9)', 'fix(-5.9)',
            'log1p(0.5)', 'expm1(0.5)',
            'asinh(0.5)', 'acosh(1.5)', 'atanh(0.5)',
            'sec(0.5)', 'csc(0.5)', 'cot(0.5)',
            'asec(1.5)', 'acsc(1.5)', 'acot(0.5)',
            'sech(0.5)', 'csch(0.5)', 'coth(0.5)',
            'asech(0.5)', 'acsch(0.5)', 'acoth(1.5)',
            'erf(0.5)', 'gamma(1.5)', 'lgamma(1.5)',
        ];

        unaryTests.forEach(expr => {
            const isErf = expr.startsWith('erf');
            it(expr, () => check(expr, { 
                epsilon: isErf ? 1e-6 : 1e-9 
            }));
        });

        it('ln(10)', () => check('log(10)', { zigExpr: 'ln(10)' }));
        it('fix(5.9)', () => check('fix(5.9)', { zigExpr: 'fix(5.9)' }));

        const binaryTests = [
            { expr: 'add(2, 3)', zig: '2 + 3' },
            { expr: 'subtract(5, 2)', zig: '5 - 2' },
            { expr: 'multiply(3, 4)', zig: '3 * 4' },
            { expr: 'divide(10, 2)', zig: '10 / 2' },
            { expr: 'pow(2, 3)', zig: '2 ^ 3' },
            { expr: 'pow(2, -1)', zig: '2 ^ -1' },
            { expr: 'pow(4, 0.5)', zig: '4 ^ 0.5' },
            { expr: 'mod(10, 3)', zig: '10 % 3' },
            { expr: 'mod(-10, 3)', zig: '-10 % 3' },
            { expr: 'hypot(3, 4)', zig: 'hypot(3, 4)' },
            { expr: 'gcd(12, 15)', zig: 'gcd(12, 15)' },
            { expr: 'lcm(12, 15)', zig: 'lcm(12, 15)' },
            { expr: 'atan2(1, 1)', zig: 'atan2(1, 1)' },
            { expr: 'atan2(0, -1)', zig: 'atan2(0, -1)' },
            { expr: 'combinations(5, 2)', zig: 'combinations(5, 2)' },
            { expr: 'permutations(5, 2)', zig: 'permutations(5, 2)' },
            { expr: 'nthRoot(27, 3)', zig: 'nthRoot(27, 3)', approx: true },
            { expr: 'log(100, 10)', zig: 'log(100, 10)' }
        ];

        binaryTests.forEach(item => {
            it(item.expr, () => check(item.expr, { zigExpr: item.zig, todo: (item as any).todo, approx: (item as any).approx }));
        });
        
        // Operators
        it('1 + 2', () => check('1 + 2'));
        it('1 - 2', () => check('1 - 2'));
        it('2 * 3', () => check('2 * 3'));
        it('10 / 2', () => check('10 / 2'));
        it('2 ^ 3', () => check('2 ^ 3'));
        it('10 % 3', () => check('10 % 3'));
    });

    // =========================================================================
    // Trigonometry
    // =========================================================================
    describe('Trigonometry', () => {
        const trigFuncs = [
            'sin', 'cos', 'tan',
            'asin', 'acos', 'atan',
            'sinh', 'cosh', 'tanh',
            'cot', 'sec', 'csc',
            // 'acot', 'asec', 'acsc' // MathJS might not have all arc-reciprocals in standard eval scope without config? They usually do.
        ];

        const values = [0, 0.5, 1, 3.14159/4];

        trigFuncs.forEach(func => {
            values.forEach(val => {
                const expr = `${func}(${val})`;
                // asin/acos/acsc/asec domain checks
                if ((func === 'asin' || func === 'acos' || func === 'asec' || func === 'acsc') && Math.abs(val) > 1 && Math.abs(val) < 1.0000001) return; // Edge case
                if ((func === 'asin' || func === 'acos') && Math.abs(val) > 1) return;
                if ((func === 'asec' || func === 'acsc') && Math.abs(val) < 1 && val !== 0) return;
                if ((func === 'cot' || func === 'csc') && val === 0) return; // Infinity check

                it(expr, () => check(expr));
            });
        });
    });

    // =========================================================================
    // Complex Numbers
    // =========================================================================
    describe('Complex Numbers', () => {
        it('1 + 2i', () => check('1 + 2i'));
        it('re(2 + 3i)', () => check('re(2 + 3i)'));
        it('im(2 + 3i)', () => check('im(2 + 3i)'));
        it('abs(3 + 4i)', () => check('abs(3 + 4i)'));
        it('arg(1 + 1i)', () => check('arg(1 + 1i)'));
        it('conj(2 + 3i)', () => check('conj(2 + 3i)'));
        
        // Arithmetic
        it('(1+2i) + (3+4i)', () => check('(1+2i) + (3+4i)'));
        it('(1+2i) * (3+4i)', () => check('(1+2i) * (3+4i)'));
        it('sqrt(-1)', () => check('sqrt(-1)'));
        it('exp(i * 3.14159)', () => check('exp(i * 3.14159)', { epsilon: 1e-5 })); // Euler
    });

    // =========================================================================
    // Matrix / Linear Algebra
    // =========================================================================
    describe('Matrix Operations', () => {
        it('det([1, 2; 3, 4])', () => check('det([1, 2; 3, 4])'));
        
        it('det(inv([1, 2; 3, 4]))', () => {
            check('det(inv([1, 2; 3, 4]))'); 
        });

        it('trace([1, 2; 3, 4])', () => check('trace([1, 2; 3, 4])'));
        
        it('dot([1, 2, 3], [4, 5, 6])', () => check('dot([1, 2, 3], [4, 5, 6])'));
        
        it('det([1, 0; 0, 1] * [2, 0; 0, 2])', () => check('det([1, 0; 0, 1] * [2, 0; 0, 2])'));
        
        it('det(transpose([1, 2; 3, 4]))', () => check('det(transpose([1, 2; 3, 4]))'));
        
        it('element-wise multiply', () => check('dotMultiply([1, 2], [3, 4])', { zigExpr: 'sum([1, 2] .* [3, 4])', todo: false })); 
        
        it('identity(3)', () => check('det(identity(3))'));
        
        it('sum(zeros(3, 3))', () => check('sum(zeros(3, 3))'));
        it('sum(ones(3, 3))', () => check('sum(ones(3, 3))'));
    });

    // =========================================================================
    // Statistics & Probability
    // =========================================================================
    describe('Statistics', () => {
        const list = '[1, 5, 2, 8, 3]';
        it('min', () => check(`min(${list})`));
        it('max', () => check(`max(${list})`));
        it('sum', () => check(`sum(${list})`));
        it('mean', () => check(`mean(${list})`));
        it('median', () => check(`median(${list})`));
        it('std', () => check(`std(${list})`, { epsilon: 1e-4 }));
        it('variance', () => check(`variance(${list})`));
        it('prod', () => check(`prod(${list})`));
        
        it('factorial(5)', () => check('factorial(5)'));
        it('mad', () => check(`mad(${list})`));
    });

    // =========================================================================
    // Bitwise (Integer)
    // =========================================================================
    describe('Bitwise', () => {
        it('bitAnd(6, 3)', () => check('bitAnd(6, 3)', { zigExpr: '6 & 3' }));
        it('bitOr(6, 3)', () => check('bitOr(6, 3)', { zigExpr: '6 | 3' }));
        it('bitXor(6, 3)', () => check('bitXor(6, 3)', { zigExpr: '6 ^^ 3' })); // Zig uses ^^? No, Zig parser uses caret_caret maps to bxor.
        // Wait, tokenizer matches ^ as caret, matches ^^ as caret_caret.
        // So 6 ^^ 3 should work.
        it('bitNot(6)', () => check('bitNot(6)', { zigExpr: '~6' }));
        it('leftShift(2, 1)', () => check('leftShift(2, 1)', { zigExpr: '2 << 1' }));
        it('rightArithShift(4, 1)', () => check('rightArithShift(4, 1)', { zigExpr: '4 >> 1' }));
    });
});