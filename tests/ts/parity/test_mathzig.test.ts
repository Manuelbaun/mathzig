import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import {
  MathZig, evalExpression, evaluateBatch,
  vecAdd, vecSub, vecDot, vecNorm, vecScale, vecScaleInplace, vecAxpy,
  gemv, gemvSimple, gemm
} from '../../../src/ts/mathzig';

describe('MathZig Native FFI', () => {
  let ctx: MathZig;

  beforeAll(() => {
    ctx = MathZig.create();
  });

  afterAll(() => {
    ctx.destroy();
  });

  it('should evaluate basic arithmetic', () => {
    let res = ctx.eval('2 + 3');
    expect(res).toBe(5);

    res = ctx.eval('2 + 3 * 4');
    expect(res).toBe(14);

    res = ctx.eval('(2 + 3) * 4');
    expect(res).toBe(20);
  });

  it('should evaluate with parentheses', () => {
    const res = ctx.eval('(1 + 2) * (3 + 4)');
    expect(res).toBe(21);
  });

  it('should evaluate power operator', () => {
    let res = ctx.eval('2 ^ 8');
    expect(res).toBe(256);

    res = ctx.eval('3 ^ 2');
    expect(res).toBe(9);
  });

  it('should evaluate functions', () => {
    let res = ctx.eval('sqrt(16)');
    expect(res).toBe(4);

    res = ctx.eval('sin(0)');
    expect(res).toBe(0);

    res = ctx.eval('cos(0)');
    expect(res).toBe(1);

    res = ctx.eval('abs(-5)');
    expect(res).toBe(5);

    res = ctx.eval('floor(3.7)');
    expect(res).toBe(3);

    res = ctx.eval('ceil(3.2)');
    expect(res).toBe(4);
  });

  it('should handle variables', () => {
    ctx.setVariable('x', 5);
    ctx.setVariable('y', 3);
    let res = ctx.eval('x + y');
    expect(res).toBe(8);

    res = ctx.eval('x * y');
    expect(res).toBe(15);

    res = ctx.eval('x ^ y');
    expect(res).toBe(125);
  });

  it('should handle variable assignment expressions', () => {
    // Test that x = 5 returns 5
    let res = ctx.eval('x = 5');
    expect(res).toBe(5);
    
    // Now x should be 5
    res = ctx.eval('x');
    expect(res).toBe(5);
    
    // x^2 + 1 should be 26
    res = ctx.eval('x^2 + 1');
    expect(res).toBe(26);
    
    // y = x * x + 1 should be 26
    res = ctx.eval('y = x * x + 1');
    expect(res).toBe(26);
    
    // y should be 26
    res = ctx.eval('y');
    expect(res).toBe(26);
  });

  it('should use indexed variables for fast access', () => {
    const xIdx = ctx.addVariableIndexed('a', 0);
    const expr = ctx.compile('a * a + 1');
    
    ctx.setByIndex(xIdx, 3);
    let res = expr.evaluate();
    expect(res).toBe(10);
    
    ctx.setByIndex(xIdx, 5);
    res = expr.evaluate();
    expect(res).toBe(26);
    
    ctx.setByIndex(xIdx, 10);
    res = expr.evaluate();
    expect(res).toBe(101);
    
    expr.free();
  });

  it('should return version', () => {
    const version = ctx.version();
    expect(version).toMatch(/^\d+\.\d+\.\d+$/);
  });
});

describe('MathZig Utility Functions', () => {
  it('should evaluate expression with shortcut', () => {
    expect(evalExpression('2 + 3')).toBe(5);
    expect(evalExpression('sqrt(16)')).toBe(4);
    expect(evalExpression('sin(0)')).toBe(0);
  });

  it('should batch evaluate expressions', () => {
    const results = evaluateBatch('x * x', 'x', [1, 2, 3, 4, 5]);
    expect(results).toEqual([1, 4, 9, 16, 25]);
  });
});

describe('MathZig Compiled Expression', () => {
  it('should compile and evaluate multiple times', () => {
    const ctx = MathZig.create();
    try {
      const expr = ctx.compile('x * x + 2 * x + 1');
      ctx.setVariable('x', 0);
      expect(expr.evaluate()).toBe(1);
      
      ctx.setVariable('x', 1);
      expect(expr.evaluate()).toBe(4);
      
      ctx.setVariable('x', 2);
      expect(expr.evaluate()).toBe(9);
      
      ctx.setVariable('x', 3);
      expect(expr.evaluate()).toBe(16);
      
      expr.free();
    } finally {
      ctx.destroy();
    }
  });

  it('should batch evaluate compiled expressions', () => {
    const ctx = MathZig.create();
    try {
      const xIdx = ctx.addVariableIndexed('x', 0);
      const expr = ctx.compile('x * x');
      const results = expr.evaluateBatch(xIdx, [1, 2, 3, 4, 5]);
      expect(results).toEqual([1, 4, 9, 16, 25]);
      expr.free();
    } finally {
      ctx.destroy();
    }
  });
});

// ============================================================================
// BLAS Kernel Tests
// ============================================================================

describe('BLAS Level 1 (Vector-Vector)', () => {
  it('vecAdd should add two vectors', () => {
    const a = new Float64Array([1, 2, 3, 4, 5, 6, 7, 8]);
    const b = new Float64Array([8, 7, 6, 5, 4, 3, 2, 1]);
    const c = new Float64Array(8);

    vecAdd(a, b, c);

    for (let i = 0; i < 8; i++) {
      expect(c[i]).toBe(9);
    }
  });

  it('vecSub should subtract two vectors', () => {
    const a = new Float64Array([10, 20, 30, 40]);
    const b = new Float64Array([1, 2, 3, 4]);
    const c = new Float64Array(4);

    vecSub(a, b, c);

    expect(c[0]).toBe(9);
    expect(c[1]).toBe(18);
    expect(c[2]).toBe(27);
    expect(c[3]).toBe(36);
  });

  it('vecDot should compute dot product', () => {
    const a = new Float64Array([1, 2, 3, 4]);
    const b = new Float64Array([1, 1, 1, 1]);

    const result = vecDot(a, b);
    // Sum 1+2+3+4 = 10
    expect(result).toBe(10);
  });

  it('vecDot should return 0 for orthogonal vectors', () => {
    const a = new Float64Array([1, 0, 0, 0]);
    const b = new Float64Array([0, 1, 0, 0]);

    const result = vecDot(a, b);
    expect(result).toBe(0);
  });

  it('vecNorm should compute Euclidean norm', () => {
    const a = new Float64Array([3, 4]); // 3-4-5 triangle
    const result = vecNorm(a);
    expect(result).toBeCloseTo(5, 4);
  });

  it('vecScale should scale a vector', () => {
    const a = new Float64Array([1, 2, 3, 4]);
    const b = new Float64Array(4);

    vecScale(2.0, a, b);

    expect(b[0]).toBe(2);
    expect(b[1]).toBe(4);
    expect(b[2]).toBe(6);
    expect(b[3]).toBe(8);
  });

  it('vecScaleInplace should scale a vector in place', () => {
    const a = new Float64Array([1, 2, 3, 4]);

    vecScaleInplace(3.0, a);

    expect(a[0]).toBe(3);
    expect(a[1]).toBe(6);
    expect(a[2]).toBe(9);
    expect(a[3]).toBe(12);
  });

  it('vecAxpy should compute y = alpha*x + y', () => {
    const x = new Float64Array([1, 2, 3, 4]);
    const y = new Float64Array([10, 20, 30, 40]);

    vecAxpy(2.0, x, y); // y = 2*x + y

    expect(y[0]).toBe(12);
    expect(y[1]).toBe(24);
    expect(y[2]).toBe(36);
    expect(y[3]).toBe(48);
  });
});

describe('BLAS Level 2 (Matrix-Vector)', () => {
  it('gemvSimple should compute y = A * x with identity matrix', () => {
    const A = new Float64Array([
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ]);
    const x = new Float64Array([1, 2, 3, 4]);
    const y = new Float64Array(4);

    gemvSimple(4, 4, A, 4, x, y);

    expect(y[0]).toBe(1);
    expect(y[1]).toBe(2);
    expect(y[2]).toBe(3);
    expect(y[3]).toBe(4);
  });

  it('gemv should compute y = alpha * A * x + beta * y', () => {
    const A = new Float64Array([
      2, 0, 0, 0,
      0, 2, 0, 0,
      0, 0, 2, 0,
      0, 0, 0, 2,
    ]);
    const x = new Float64Array([1, 2, 3, 4]);
    const y = new Float64Array([10, 10, 10, 10]);

    // y = 0.5 * A * x + 1.0 * y = 0.5 * 2 * x + y = x + y
    gemv(4, 4, 0.5, A, 4, x, 1.0, y);

    expect(y[0]).toBe(11);
    expect(y[1]).toBe(12);
    expect(y[2]).toBe(13);
    expect(y[3]).toBe(14);
  });
});

describe('BLAS Level 3 (Matrix-Matrix)', () => {
  it('gemm should compute C = A * B for 2x2 matrices', () => {
    const A = new Float64Array([
      1, 2,
      3, 4,
    ]);
    const B = new Float64Array([
      5, 6,
      7, 8,
    ]);
    const C = new Float64Array(4);

    gemm(2, 2, 2, A, 2, B, 2, C, 2);

    // C = A * B
    // [1 2] * [5 6] = [1*5+2*7  1*6+2*8] = [19 22]
    // [3 4]   [7 8]   [3*5+4*7  3*6+4*8]   [43 50]
    expect(C[0]).toBe(19);
    expect(C[1]).toBe(22);
    expect(C[2]).toBe(43);
    expect(C[3]).toBe(50);
  });

  it('gemm should compute C = A * B for 4x4 matrices', () => {
    // 4x4 identity matrix
    const I = new Float64Array([
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ]);
    const A = new Float64Array([
      1, 2, 3, 4,
      5, 6, 7, 8,
      9, 10, 11, 12,
      13, 14, 15, 16,
    ]);
    const C = new Float64Array(16);

    // C = I * A = A
    gemm(4, 4, 4, I, 4, A, 4, C, 4);

    for (let i = 0; i < 16; i++) {
      expect(C[i]).toBe(A[i]);
    }
  });
});
