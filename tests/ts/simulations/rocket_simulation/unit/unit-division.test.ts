/**
 * UNIT DIVISION TESTS
 * 
 * Tests unit division and mixed operations between units and numbers
 * From: debug_unit_div.ts
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

describe("Unit Division Tests", () => {
  let mz: MathZig;

  beforeAll(() => {
    mz = MathZig.create();
  });

  afterAll(() => {
    mz.destroy();
  });

  it("should handle unit number division", () => {
    // From debug_unit_div.ts - unit/number division
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    
    // Test division of unit by number
    const result1 = toNum(mz.eval("r0 / 1000") as number | Value);
    console.log("r0 / 1000:", result1);
    
    const result2 = toNum(mz.eval("g0 / 2") as number | Value);
    console.log("g0 / 2:", result2);
    
    // Check values
    expect(result1).toBeCloseTo(6371); // 6371000m / 1000 = 6371
    expect(result2).toBeCloseTo(4.903325); // 9.80665 / 2 = 4.903325
  });

  it("should handle thrust-drag comparison with unit operations", () => {
    // From debug_unit_div.ts - thrust-drag comparison
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("isp_sea = 282 s");
    mz.eval("dm = 2750 kg/s");
    mz.eval("A = (3.66 m)^2 * pi");
    mz.eval("dragCoef = 0.2");
    mz.eval("r0 = 6371 km");
    mz.eval("v0 = 1 m/s");

    // Functions
    mz.eval("isp(r) = 311 s"); // Simplified
    mz.eval("density(r) = 1.2250 kg/m^3"); // Simplified
    mz.eval("thrust(isp) = g0 * isp * dm");
    mz.eval("drag(r, v) = 1/2 * density(r) * v^2 * A * dragCoef");

    // Test hardcoded values
    const thrustHard = toNum(mz.eval("9.80665 m/s^2 * 311 s * 2750 kg/s") as number | Value);
    const dragHard = toNum(mz.eval("1/2 * 1.2250 kg/m^3 * (1 m/s)^2 * (3.66 m)^2 * pi * 0.2") as number | Value);
    
    console.log("hardcoded thrust:", thrustHard);
    console.log("hardcoded drag:", dragHard);
    
    // Test with variables
    const thrustVar = toNum(mz.eval("thrust(isp(r0))") as number | Value);
    const dragVar = toNum(mz.eval("drag(r0, v0)") as number | Value);
    
    console.log("variable thrust:", thrustVar);
    console.log("variable drag:", dragVar);
    
    // Both should be similar
    expect(Math.abs(thrustHard - thrustVar)).toBeLessThan(1e-6);
    expect(Math.abs(dragHard - dragVar)).toBeLessThan(1e-6);
  });

  it("should handle thrust minus drag with unit conversion", () => {
    // From debug_unit_div.ts - unit conversion in thrust-drag
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("isp_sea = 282 s");
    mz.eval("dm = 2750 kg/s");
    mz.eval("A = (3.66 m)^2 * pi");
    mz.eval("dragCoef = 0.2");
    mz.eval("r0 = 6371 km");
    mz.eval("v0 = 1 m/s");

    mz.eval("isp(r) = 311 s");
    mz.eval("density(r) = 1.2250 kg/m^3");
    mz.eval("thrust(isp) = g0 * isp * dm");
    mz.eval("drag(r, v) = 1/2 * density(r) * v^2 * A * dragCoef");

    // Test with unit conversion
    try {
      const result = toNum(mz.eval("conv(thrust(isp(r0)), N) - conv(drag(r0, v0), N)") as number | Value);
      console.log("conv(thrust) - conv(drag):", result);
      expect(result).toBeDefined();
    } catch (e) {
      console.error("conv(thrust) - conv(drag) failed:", e);
      throw e;
    }
  });

  it("should handle mixed unit and number operations", () => {
    // Test various mixed operations
    mz.eval("len_u = 100 m");
    mz.eval("dt_u = 10 s");
    mz.eval("mass_u = 50 kg");

    // Unit * number
    const length2 = toNum(mz.eval("len_u * 2") as number | Value);
    console.log("length * 2:", length2);
    expect(length2).toBeCloseTo(200);

    // Unit / number  
    const time2 = toNum(mz.eval("dt_u / 2") as number | Value);
    console.log("time / 2:", time2);
    expect(time2).toBeCloseTo(5);

    // Unit + Unit (same units)
    const length3 = toNum(mz.eval("len_u + 50 m") as number | Value);
    console.log("length + 50m:", length3);
    expect(length3).toBeCloseTo(150);

    // Unit * Unit (different units)
    const velocity = toNum(mz.eval("len_u / dt_u") as number | Value);
    console.log("length / time:", velocity);
    expect(velocity).toBeCloseTo(10);

    // Unit * Unit (same type operation)
    const area = toNum(mz.eval("len_u * len_u") as number | Value);
    console.log("length * length:", area);
    expect(area).toBeCloseTo(10000); // 100m * 100m = 10000 m^2
  });

  it("should handle complex unit expressions", () => {
    // Test more complex unit expressions
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("mass_u = 1000 kg");
    mz.eval("force_u = mass_u * g0");
    
    console.log("mass_u * g0:", mz.eval("force_u"));
    
    // Check unit consistency
    const forceNum = toNum(mz.eval("force_u") as number | Value);
    expect(forceNum).toBeCloseTo(9806.65); // 1000 * 9.80665
    
    // Test acceleration = force / mass
    const accel = toNum(mz.eval("force_u / mass_u") as number | Value);
    console.log("force / mass:", accel);
    expect(accel).toBeCloseTo(9.80665); // Should equal g0
    
    // Test work = force * distance
    mz.eval("distance_u = 100 m");
    const work = toNum(mz.eval("force_u * distance_u") as number | Value);
    console.log("force * distance:", work);
    expect(work).toBeCloseTo(980665); // 9806.65 * 100 = 980665 J
  });
});
