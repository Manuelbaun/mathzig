import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig } from '../../../src/ts/mathzig';
import { load as loadWasm } from '../../../src/bindings/generated/wasm';
import { join } from 'path';
import { existsSync, readFileSync } from 'fs';

function resolveWasmPath(): string {
  // zig build wasm → web/mathzig_wasm.wasm (build.zig install path)
  // some docs/scripts also place it at zig-out/bin/mathzig_wasm.wasm
  const candidates = [
    join(process.cwd(), 'zig-out/bin/mathzig_wasm.wasm'),
    join(process.cwd(), 'web/mathzig_wasm.wasm'),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  throw new Error(
    `mathzig_wasm.wasm not found (tried ${candidates.join(', ')}). Run: export PATH="$PWD/tools/macos-sdk-shim:$PATH" && zig build wasm`
  );
}

describe('MathZig WebAssembly', () => {
  let ctx: MathZig;

  beforeAll(async () => {
    const wasmPath = resolveWasmPath();
    const wasmBuffer = readFileSync(wasmPath);
    const backend = await loadWasm(wasmBuffer);
    ctx = MathZig.create(backend);
  });

  afterAll(() => {
    ctx.destroy();
  });

  it('should evaluate basic arithmetic', () => {
    expect(ctx.eval('2 + 3')).toBe(5);
    expect(ctx.eval('2 + 3 * 4')).toBe(14);
    expect(ctx.eval('(2 + 3) * 4')).toBe(20);
  });

  it('should evaluate with parentheses', () => {
    expect(ctx.eval('(1 + 2) * (3 + 4)')).toBe(21);
  });

  it('should evaluate power operator', () => {
    expect(ctx.eval('2 ^ 8')).toBe(256);
    expect(ctx.eval('3 ^ 2')).toBe(9);
  });

  it('should evaluate functions', () => {
    expect(ctx.eval('sqrt(16)')).toBe(4);
    expect(ctx.eval('sin(0)')).toBe(0);
    expect(ctx.eval('cos(0)')).toBe(1);
    expect(ctx.eval('abs(-5)')).toBe(5);
  });

  it('should handle variables', () => {
    ctx.setVariable('x', 5);
    ctx.setVariable('y', 3);
    expect(ctx.eval('x + y')).toBe(8);
    expect(ctx.eval('x * y')).toBe(15);
  });

  it('should handle variable assignment expressions', () => {
    expect(ctx.eval('x = 10')).toBe(10);
    expect(ctx.eval('x')).toBe(10);
    expect(ctx.eval('x * 2')).toBe(20);
  });

  it('should use indexed variables', () => {
    const aIdx = ctx.addVariableIndexed('a', 0);
    const expr = ctx.compile('a * a');
    
    ctx.setByIndex(aIdx, 4);
    expect(expr.evaluate()).toBe(16);
    
    ctx.setByIndex(aIdx, 10);
    expect(expr.evaluate()).toBe(100);
    
    expr.free();
  });

  it('should return version', () => {
    const version = ctx.version();
    // In exports.zig, mathzig_version returns a string
    // In mathzig.ts FFI it was returning version_number? 
    // Let's check what mathzig_version returns.
    expect(typeof version).toBe('string');
  });

  it('should solve ODE (ode_solve)', () => {
    // Define derivative function: dy/dt = -y
    ctx.eval('f(t, y) = -y');
    
    // Solve from t=0 to t=1 with y0=1, dt=0.1
    const result = ctx.eval('ode_solve("f", 1, [0, 1], 0.1)');
    
    console.log('ODE Result:', result);
    
    if (typeof result === 'object' && result !== null) {
        // eval returns Matrix object directly, not wrapped in Value with .type
        expect(result.rows).toBe(11);
        expect(result.cols).toBe(2);
        
        // Check the last value (y at t=1) directly from the Float64Array data
        // Row 10, Col 1 => index 10 * 2 + 1 = 21
        const data = result.data;
        const lastY = data[21];
        
        expect(lastY).toBeCloseTo(0.3678, 2);
    } else {
        const err = ctx.getError();
        console.error('ODE Failed. Error:', err);
        throw new Error('ODE Solve failed');
    }
  });
});
