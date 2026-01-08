import { expect, test, describe } from "bun:test";
import { MathZig } from "../../../src/ts/mathzig";

describe("ODE Solver Debug", () => {
    test("Simple function resolution", () => {
        const mz = MathZig.create();

        // Define a simple derivative function
        mz.eval("simple_deriv(t, y) = -0.5 * y");

        // Check if function is registered
        const funcs = mz.getFunctions();
        console.log("Registered functions:", funcs);
        expect(funcs).toContain("simple_deriv");

        // Test the ODE solver with this simple function
        mz.eval("y0 = [1]");
        const result = mz.eval('ode_solve_euler("simple_deriv", y0, [0, 2], 0.1)');
        const error = mz.getError();
        console.log("Error after ode_solve_euler:", error);
        console.log("Result type:", typeof result, result);

        expect(error).toBe("No error");
    });

    test("Multi-stage function resolution", () => {
        const mz = MathZig.create();

        // Define first function (scalar form for compatibility with current solver semantics)
        mz.eval("deriv_stage1(t, y) = -y");
        console.log("Functions after stage1 def:", mz.getFunctions());

        // Run first ODE solve
        mz.eval("y0_s1 = 1");
        mz.eval('result1 = ode_solve_euler("deriv_stage1", y0_s1, [0, 1], 0.1)');
        console.log("Error after stage1:", mz.getError());

        // Define second function
        mz.eval("deriv_stage2(t, y) = -2*y");
        console.log("Functions after stage2 def:", mz.getFunctions());

        // Run second ODE solve - this is where the bug might appear
        mz.eval("y0_s2 = 1");
        mz.eval('result2 = ode_solve_euler("deriv_stage2", y0_s2, [0, 1], 0.1)');
        const error2 = mz.getError();
        console.log("Error after stage2:", error2);

        expect(error2).toBe("No error");
    });

    test("Function calling other functions in ODE", () => {
        const mz = MathZig.create();

        // Define helper functions
        mz.eval("helper1(x) = x * 2");
        mz.eval("helper2(x) = x + 1");

        // Define derivative that uses helpers
        mz.eval("deriv_with_helpers(t, y) = helper1(y) + helper2(t)");
        console.log("Functions:", mz.getFunctions());

        // Run ODE solve
        mz.eval("y0 = 1");
        const result = mz.eval('ode_solve_euler("deriv_with_helpers", y0, [0, 1], 0.1)');
        const error = mz.getError();
        console.log("Error:", error);
        console.log("Result:", result);

        expect(error).toBe("No error");
    });
});
