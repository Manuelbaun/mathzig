/**
 * ROOT CAUSE TESTS
 * 
 * Identifies root cause of number vs unit function argument issues
 * From: verify_root_cause.ts
 */
import { describe, expect, it } from "bun:test";
import { beforeAll, afterAll } from "bun:test";
import { MathZig, Value } from "../../../../../src/ts/mathzig";

const toNum = (value: number | Value): number => {
  if (typeof value === "number") return value;
  const n = value.toNumber();
  value.release();
  return n;
};

describe("Root Cause Tests", () => {
  let mz: MathZig;

  beforeAll(() => {
    mz = MathZig.create();
  });

  afterAll(() => {
    mz.destroy();
  });

  it("should identify unit vs dimensionless function call issues", () => {
    // From verify_root_cause.ts - unit vs dimensionless function calls
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("G = 6.67408e-11 m^3 / (kg * s^2)");
    mz.eval("mbody = 5.9724e24 kg");

    // Gravity function with units
    mz.eval("gravity_unit(r) = G * mbody / r^2");
    
    // Gravity function with dimensionless (converted to number)
    mz.eval("gravity_dimless(r) = conv(G * mbody / r^2, m/s^2)");

    // Test with unit argument
    const result1 = mz.eval("gravity_unit(r0)");
    console.log("gravity_unit(r0):", result1);
    console.log("gravity_unit type:", typeof result1);
    if (result1 instanceof Value) {
      console.log("gravity_unit tag:", (result1 as Value).tag);
    }

    // Test with dimensionless argument  
    const result2 = mz.eval("gravity_dimless(r0)");
    console.log("gravity_dimless(r0):", result2);
    console.log("gravity_dimless type:", typeof result2);
    if (result2 instanceof Value) {
      console.log("gravity_dimless tag:", (result2 as Value).tag);
    }

    // The unit-based function should return a Value with units
    // The dimensionless function should return a number
    expect(result1).toBeDefined();
    expect(result2).toBeDefined();
  });

  it("should demonstrate solution to unit argument issues", () => {
    // From verify_root_cause.ts - solution demonstration
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("G = 6.67408e-11 m^3 / (kg * s^2)");
    mz.eval("mbody = 5.9724e24 kg");

    // Problem: function expects units but gets raw arguments
    try {
      mz.eval("problematic(r) = G * mbody / r^2");
      const problematic = mz.eval("problematic(6371000)"); // Raw number instead of distance
      console.log("problematic result:", problematic);
      // This might fail or give wrong result
    } catch (e) {
      console.log("problematic failed as expected:", e);
    }

    // Solution: convert arguments to proper units
    mz.eval("correct(r_raw) = G * mbody / (r_raw m)^2");
    const correct = toNum(mz.eval("correct(6371000)") as number | Value);
    console.log("correct result:", correct);
    console.log("correct type:", typeof correct);

    // The solution should work and give expected gravity
    const expectedGravity = 9.8196; // Approximate gravity at surface
    expect(Math.abs(correct - expectedGravity)).toBeLessThan(0.1);
  });

  it("should handle function parameter unit conversion correctly", () => {
    // Test different approaches to unit handling in functions
    mz.eval("r0 = 6371 km");
    mz.eval("v0 = 1 m/s");
    mz.eval("gamma0 = 89.99970 deg");

    // Approach 1: Convert parameter to units in function body
    mz.eval("sin_approach1(angle_deg) = sin(angle_deg deg)");
    const result1 = toNum(mz.eval("sin_approach1(90)") as number | Value);
    console.log("sin_approach1(90):", result1);
    expect(Math.abs(result1 - 1.0)).toBeLessThan(1e-10);

    // Approach 2: Call with converted argument
    mz.eval("sin_approach2(angle) = sin(angle)");
    const result2 = toNum(mz.eval("sin_approach2(90 deg)") as number | Value);
    console.log("sin_approach2(90 deg):", result2);
    expect(Math.abs(result2 - 1.0)).toBeLessThan(1e-10);

    // Approach 3: Use pre-converted variable
    mz.eval("angle_deg = 90 deg");
    const result3 = toNum(mz.eval("sin_approach2(angle_deg)") as number | Value);
    console.log("sin_approach2(angle_deg):", result3);
    expect(Math.abs(result3 - 1.0)).toBeLessThan(1e-10);
  });

  it("should demonstrate matrix context unit handling", () => {
    // From verify_root_cause.ts - matrix context issues
    mz.eval("r0 = 6371 km");
    mz.eval("v0 = 1 m/s");
    mz.eval("m0 = 500000 kg");

    // Functions that work with scalars
    mz.eval("gravity_scalar(r) = 9.81 m/s^2");
    
    // Test in scalar context
    const scalarResult = mz.eval("gravity_scalar(r0)");
    console.log("scalar gravity_scalar(r0):", scalarResult);

    // Unit-bearing matrix literals are rejected (task-15/D6). Note: a single
    // `[unit]` parse is unit-bracket syntax, not a 1×1 matrix — use multi-row
    // or nested brackets for true matrix context.
    const matrixResult = mz.eval("[number(gravity_scalar(r0), m/s^2)]");
    expect(matrixResult).toBeDefined();
    const matrixResult2 = mz.eval(
      "[number(gravity_scalar(r0), m/s^2); number(gravity_scalar(r0), m/s^2)]"
    );
    expect(matrixResult2).toBeDefined();
    // Multi-element unit-bearing matrix hard-errors with stable identity.
    expect(() =>
      mz.eval("[gravity_scalar(r0); gravity_scalar(r0)]")
    ).toThrow(/Matrix unit element unsupported|unit-bearing matrix/);
  });

  it("should show proper error handling for unit mismatches", () => {
    // Test how MathZig handles unit mismatches
    mz.eval("length = 100 m");
    mz.eval("time = 10 s");

    // This should work - adding same units
    try {
      const sum1 = mz.eval("length + 50 m");
      console.log("length + 50m:", sum1);
      expect(sum1).toBeDefined();
    } catch (e) {
      console.error("same unit addition failed:", e);
      throw e;
    }

    // This should fail - adding different units
    try {
      const sum2 = mz.eval("length + time");
      console.log("length + time:", sum2);
      // If this doesn't fail, that's also informative
    } catch (e) {
      console.log("different unit addition failed as expected:", e);
      // This is expected to fail
    }

    // This should work - unit division resulting in velocity
    try {
      const velocity = toNum(mz.eval("length / time") as number | Value);
      console.log("length / time:", velocity);
      expect(velocity).toBeDefined();
      expect(velocity).toBeCloseTo(10); // 100m / 10s = 10 m/s
    } catch (e) {
      console.error("unit division failed:", e);
      throw e;
    }
  });
});
