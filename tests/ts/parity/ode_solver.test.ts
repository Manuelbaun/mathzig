import { expect, test, describe } from "bun:test";
import { MathZig } from "../../../src/ts/mathzig";

describe("ODE Solver (FFI)", () => {
    test("Exponential Decay", () => {
        const mz = MathZig.create();
        
        // Define function in DSL
        mz.eval("f(t, y) = -y");
        
        // Solve
        // y0 = 1, t_span = [0, 1], dt = 0.1
        const sol_res = mz.eval('sol = ode_solve("f", 1, [0, 1], 0.1)');
        
        const rows = mz.eval("size(sol).rows");
        expect(rows).toBe(11);
        
        const y_last = mz.eval("sol[10, 1]"); // t is col 0, y is col 1
        expect(Math.abs(y_last - 0.367879)).toBeLessThan(0.001);
    });

    test("Harmonic Oscillator", () => {
        const mz = MathZig.create();
        
        // Define function: dy/dt = [y2, -y1]
        // y is vector. y[0] = y1, y[1] = y2.
        mz.eval("osc(t, y) = [y[1]; -y[0]]"); // Column vector [y2; -y1]
        
        // Solve
        // y0 = [0; 1] (column vector)
        // t_span = [0, 3.14159]
        // dt = 0.01
        mz.eval('sol = ode_solve("osc", [0; 1], [0, 3.14159], 0.01)');
        
        const rows = mz.eval("size(sol).rows");
        // Verify last point
        // y1 (col 1) should be sin(pi) ~ 0
        // y2 (col 2) should be cos(pi) ~ -1
        
        const y1_last = mz.eval(`sol[${rows - 1}, 1]`);
        const y2_last = mz.eval(`sol[${rows - 1}, 2]`);
        
        expect(Math.abs(y1_last)).toBeLessThan(0.01);
        expect(Math.abs(y2_last - (-1))).toBeLessThan(0.01);
    });
});
