import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { MathZig, Value } from "../../../../src/ts/mathzig";
import * as mathjs from "mathjs";

/**
 * Helper utilities for rocket simulation tests
 */

export const expectClose = (
  actual: number,
  expected: number,
  absTol = 2e-3,
  relTol = 1e-6
) => {
  const diff = Math.abs(actual - expected);
  const scale = Math.max(Math.abs(actual), Math.abs(expected));
  const allowed = Math.max(absTol, relTol * scale);
  expect(diff).toBeLessThanOrEqual(allowed);
};

export const mzNum = (mz: MathZig, expr: string): number => {
  try {
    const result = mz.eval(expr);
    
    // Log formatted value to see units (optional, can be disabled)
    try {
        const formatted = mz.eval(`"${expr} = " + format(${expr})`);
        console.log(`  MZ [${expr}] formatted: ${formatted}`);
    } catch (e) {}

    if (typeof result === "number") return result;
    if (result instanceof Value) {
      const tag = result.tag;
      if (tag === 14) {
         console.log(`  MZ [${expr}]: ERROR tag=14, code=${result.num}, msg=${mz.getError()}`);
         return NaN;
      }
      const n = result.toNumber();
      result.release();
      return n;
    }
    const n = Number(result);
    return isNaN(n) ? NaN : n;
  } catch (e) {
    console.error(`MathZig eval failed for: ${expr}`, e);
    return NaN;
  }
};

export const mjNum = (math: any, parser: any, expr: string): number => {
  try {
    const result = parser.evaluate(expr);
    if (typeof result === "number") return result;
    
    // Handle MathJS Unit
    if (result && result.type === 'Unit') {
      const n = result.toNumber();
      console.log(`  MJ [${expr}]: unit, value=${n}, unit=${result.formatUnits()}`);
      return n;
    }
    
    if (result && typeof result.toNumber === "function") {
      const n = result.toNumber();
      console.log(`  MJ [${expr}]: has toNumber(), value=${n}`);
      return n;
    }
    
    try {
      const n = math.number(result);
      if (typeof n === 'number') {
        console.log(`  MJ [${expr}]: math.number() success, value=${n}`);
        return n;
      }
    } catch (e) {}

    console.log(`  MJ [${expr}]: fallback to Number(), result type=${typeof result}`);
    const n = Number(result);
    return isNaN(n) ? NaN : n;
  } catch (e) {
    console.error(`MathJS eval failed for: ${expr}`, e);
    return NaN;
  }
};

export const columnUnits = ["m", "m/s", "kg", "rad", "rad"];

// Test setup interface
export interface TestSetup {
  mz: MathZig;
  math: any;
  mjParser: any;
}

// Setup function for MathJS with ndsolve
export const setupMathJS = () => {
  const math = mathjs.create(mathjs.all, {} as any);
  const mjParser = math.parser();

  // Define ndsolve for MathJS
  const ndsolve = (funcs: any[], x0: any, dt: any, tmax: any) => {
    let state = math.matrix(x0);
    const steps = Math.round(math.number(math.divide(tmax, dt)) as number);
    const history = [state];
    for (let i = 0; i < steps; i++) {
      const current = state.toArray();
      const deriv = funcs.map((fn: any) => fn(...current));
      const delta = math.dotMultiply(deriv, dt);
      state = math.add(state, delta) as any;
      history.push(state);
    }
    return math.matrix(history);
  };
  
  math.import({ ndsolve } as any);

  return { math, mjParser };
};

// Common test setup for rocket simulation tests
export const setupRocketTest = (): TestSetup => {
  const mz = MathZig.create();
  const { math, mjParser } = setupMathJS();
  return { mz, math, mjParser };
};

// Cleanup function for MathZig
export const cleanupMathZig = (mz: MathZig) => {
  mz.destroy();
};

// Helper to compare values with tolerance
export const compareValues = (
  name: string, 
  mjVal: number, 
  mzVal: number, 
  tol = 1e-9
): boolean => {
  const diff = Math.abs(mjVal - mzVal);
  const relDiff = Math.abs(diff / Math.max(Math.abs(mjVal), Math.abs(mzVal), 1e-15));
  const pass = diff < tol || relDiff < tol;
  console.log(`${pass ? "✓" : "✗"} ${name}`);
  console.log(`    MathJS:  ${mjVal}`);
  console.log(`    MathZig: ${mzVal}`);
  if (!pass) console.log(`    DIFF: ${diff} (rel: ${relDiff})`);
  console.log();
  return pass;
};