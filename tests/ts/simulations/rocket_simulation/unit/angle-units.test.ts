/**
 * ANGLE UNITS TESTS
 * 
 * Tests sine function with angle units and degree/radian conversions
 * Combined from: debug_sin.ts, debug_sin2.ts
 */
import { beforeAll, afterAll, describe, expect, it } from "bun:test";
import { MathZig, Value } from "../../../../../src/ts/mathzig";

const toNum = (value: number | Value): number => {
  if (typeof value === "number") return value;
  const n = value.toNumber();
  value.release();
  return n;
};

describe("Angle Units Tests", () => {
  let mz: MathZig;

  beforeAll(() => {
    mz = MathZig.create();
  });

  afterAll(() => {
    mz.destroy();
  });

  it("should handle sine with degree units", () => {
    // From debug_sin.ts
    mz.eval("gamma0 = 89.99970 deg");
    
    // Test direct literal
    const sinLiteral = mz.eval("sin(90 deg)");
    console.log("sin(90 deg):", sinLiteral);
    
    // Test with variable
    const sinVariable = mz.eval("sin(gamma0)");
    console.log("sin(gamma0):", sinVariable);
    
    // Test conversion to radians
    const gamma0Rad = mz.eval("conv(gamma0, rad)");
    console.log("gamma0 in radians:", gamma0Rad);
    
    const sinConverted = mz.eval("sin(conv(gamma0, rad))");
    console.log("sin(conv(gamma0, rad)):", sinConverted);
    
    // Values should be close
    const diff = Math.abs((sinLiteral as number) - (sinVariable as number));
    expect(diff).toBeLessThan(1e-10);
  });

  it("should handle sine with different angle units", () => {
    // From debug_sin2.ts - concise testing
    mz.eval("gamma0 = 89.99970 deg");
    
    const sinDeg = mz.eval("sin(gamma0)");
    const sinRad = mz.eval("sin(conv(gamma0, rad))");
    
    console.log("sin(gamma0):", sinDeg);
    console.log("sin(conv(gamma0, rad)):", sinRad);
    
    // Both should be close to 1 (since 89.99970 degrees is almost 90 degrees)
    expect(Math.abs((sinDeg as number) - 1.0)).toBeLessThan(1e-6);
    expect(Math.abs((sinRad as number) - 1.0)).toBeLessThan(1e-6);
    
    // They should be equal to each other
    const diff = Math.abs((sinDeg as number) - (sinRad as number));
    expect(diff).toBeLessThan(1e-10);
  });

  it("should handle cosine with angle units", () => {
    mz.eval("gamma0 = 89.99970 deg");
    
    const cosDeg = toNum(mz.eval("cos(gamma0)") as number | Value);
    const cosRad = toNum(mz.eval("cos(conv(gamma0, rad))") as number | Value);
    
    console.log("cos(gamma0):", cosDeg);
    console.log("cos(conv(gamma0, rad)):", cosRad);
    
    // Both should be close to 0 (since 89.99970 degrees is almost 90 degrees)
    expect(Math.abs(cosDeg)).toBeLessThan(1e-5);
    expect(Math.abs(cosRad)).toBeLessThan(1e-5);
  });

  it("should handle angle unit conversions correctly", () => {
    const deg90 = mz.eval("90 deg");
    const radHalfPi = mz.eval("pi/2 rad");
    const convertedDeg = mz.eval("conv(90 deg, rad)");
    const convertedRad = mz.eval("conv(pi/2 rad, deg)");
    
    console.log("90 deg:", deg90);
    console.log("pi/2 rad:", radHalfPi);
    console.log("conv(90 deg, rad):", convertedDeg);
    console.log("conv(pi/2 rad, deg):", convertedRad);
    
    // 90 degrees should equal pi/2 radians
    const diff = Math.abs((convertedDeg as number) - Math.PI/2);
    expect(diff).toBeLessThan(1e-10);
    
    // pi/2 radians should equal 90 degrees
    const diff2 = Math.abs((convertedRad as number) - 90.0);
    expect(diff2).toBeLessThan(1e-10);
  });
});
