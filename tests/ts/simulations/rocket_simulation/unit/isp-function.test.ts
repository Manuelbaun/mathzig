/**
 * ISP FUNCTION TESTS
 * 
 * Tests specific impulse (isp) function calculation and atmospheric density effects
 * From: debug_isp.ts
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

describe("ISP Function Tests", () => {
  let mz: MathZig;

  beforeAll(() => {
    mz = MathZig.create();
  });

  afterAll(() => {
    mz.destroy();
  });

  it("should calculate ISP at sea level correctly", () => {
    // From debug_isp.ts - ISP function components
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("isp_sea = 282 s");
    mz.eval("isp_vac = 311 s");
    
    // Simple density function
    mz.eval("density(r) = 1.2250 kg/m^3"); // Simplified for sea level
    
    // ISP function
    mz.eval("isp(r) = isp_vac + (isp_sea - isp_vac) * density(r)/density(r0)");

    const ispAtSeaLevel = toNum(mz.eval("isp(r0)") as number | Value);
    console.log("isp at sea level:", ispAtSeaLevel);
    
    // At sea level, density(r0) = density(r0), so isp should be isp_sea
    const expectedIsp = 282; // isp_sea
    expect(Math.abs(ispAtSeaLevel - expectedIsp)).toBeLessThan(1e-6);
  });

  it("should calculate ISP in vacuum correctly", () => {
    // Test ISP in vacuum (density approaches 0)
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("isp_sea = 282 s");
    mz.eval("isp_vac = 311 s");
    
    // Vacuum case: density contribution is 0
    mz.eval("isp_vac_case(r) = isp_vac + (isp_sea - isp_vac) * 0");
    const ispInVac = toNum(mz.eval("isp_vac_case(r0)") as number | Value);
    console.log("isp in vacuum:", ispInVac);
    
    // In vacuum, density = 0, so isp should be isp_vac
    const expectedIsp = 311; // isp_vac
    expect(Math.abs(ispInVac - expectedIsp)).toBeLessThan(1e-6);
  });

  it("should handle ISP with atmospheric density variation", () => {
    // Test ISP with proper atmospheric density function
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("isp_sea = 282 s");
    mz.eval("isp_vac = 311 s");
    
    // More realistic density function
    mz.eval("density(r) = 1.2250 kg/m^3 * exp(-g0 * (r - r0) / (83246.8 m^2/s^2))");
    
    // ISP function
    mz.eval("isp(r) = isp_vac + (isp_sea - isp_vac) * density(r)/density(r0)");

    const ispSeaLevel = toNum(mz.eval("isp(r0)") as number | Value);
    const isp10km = toNum(mz.eval("isp(r0 + 10 km)") as number | Value);
    const isp50km = toNum(mz.eval("isp(r0 + 50 km)") as number | Value);
    
    console.log("isp at sea level:", ispSeaLevel);
    console.log("isp at 10km:", isp10km);
    console.log("isp at 50km:", isp50km);
    
    // Redefining density(r) in the same context takes effect, so ISP rises
    // toward the vacuum value as density decays with altitude.
    expect(Math.abs(ispSeaLevel - 282)).toBeLessThan(1e-6);
    expect(isp10km).toBeGreaterThan(ispSeaLevel + 1);
    expect(isp50km).toBeGreaterThan(isp10km + 1);
    // exp(-g0 * 10 km / 83246.8) ≈ 0.308 → isp ≈ 302.07
    expect(Math.abs(isp10km - 302.07)).toBeLessThan(0.5);
    // At 50 km the atmosphere is nearly gone → isp approaches isp_vac.
    expect(Math.abs(isp50km - 311)).toBeLessThan(1);
  });

  it("should handle ISP function step-by-step evaluation", () => {
    // From debug_isp.ts - step-by-step evaluation
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("isp_sea = 282 s");
    mz.eval("isp_vac = 311 s");
    
    // Simplified density for debugging
    mz.eval("density(r) = 1.2250 kg/m^3");
    
    // Debug ISP calculation step by step
    const densitySeaLevel = toNum(mz.eval("density(r0)") as number | Value);
    console.log("density(r0):", densitySeaLevel);
    
    const ispSea = toNum(mz.eval("isp_sea") as number | Value);
    const ispVac = toNum(mz.eval("isp_vac") as number | Value);
    console.log("isp_sea:", ispSea);
    console.log("isp_vac:", ispVac);
    
    const difference = toNum(mz.eval("isp_sea - isp_vac") as number | Value);
    console.log("isp_sea - isp_vac:", difference);
    
    const ratio = toNum(mz.eval("density(r0)/density(r0)") as number | Value);
    console.log("density ratio:", ratio);
    
    const adjustment = toNum(mz.eval("(isp_sea - isp_vac) * density(r0)/density(r0)") as number | Value);
    console.log("adjustment:", adjustment);
    
    const ispResult = toNum(mz.eval("isp_vac + (isp_sea - isp_vac) * density(r0)/density(r0)") as number | Value);
    console.log("final isp:", ispResult);
    
    expect(Math.abs(ispResult - 282)).toBeLessThan(1e-6);
  });

  it("should handle ISP with thrust calculation", () => {
    // Test ISP in context of thrust calculation
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("isp_sea = 282 s");
    mz.eval("isp_vac = 311 s");
    mz.eval("dm = 2750 kg/s");
    
    // Functions
    mz.eval("density(r) = 1.2250 kg/m^3");
    mz.eval("isp(r) = isp_vac + (isp_sea - isp_vac) * density(r)/density(r0)");
    const ispAtSeaLevel = toNum(mz.eval("isp(r0)") as number | Value);
    const thrustAtSeaLevel = toNum(
      mz.eval("conv(g0, m/s^2) * conv(isp(r0), s) * conv(dm, kg/s)") as number | Value
    );
    
    console.log("isp at sea level:", ispAtSeaLevel);
    console.log("thrust at sea level:", thrustAtSeaLevel);
    
    // Verify thrust calculation
    const expectedThrust = 9.80665 * 282 * 2750; // g0 * isp * dm
    expect(Math.abs(thrustAtSeaLevel - expectedThrust)).toBeLessThan(1e-6);
    expect(thrustAtSeaLevel).toBeGreaterThan(0);
  });
});
