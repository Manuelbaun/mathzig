/**
 * THRUST AND DRAG TESTS
 * 
 * Tests thrust vs drag unit compatibility and calculation issues
 * Combined from: debug_thrust_drag.ts, thrust_drag.ts
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

describe("Thrust and Drag Tests", () => {
  let mz: MathZig;

  beforeAll(() => {
    mz = MathZig.create();
  });

  afterAll(() => {
    mz.destroy();
  });

  it("should handle thrust and drag calculations separately", () => {
    // From debug_thrust_drag.ts
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("isp_sea = 282 s");
    mz.eval("dm = 2750 kg/s");
    mz.eval("A = (3.66 m)^2 * pi");
    mz.eval("dragCoef = 0.2");
    mz.eval("r0 = 6371 km");
    mz.eval("v0 = 1 m/s");

    // ISP function
    mz.eval("isp(r) = 311 s"); // Simplified isp for testing
    mz.eval("density(r) = 1.2250 kg/m^3"); // Simplified density
    
    // Thrust function
    mz.eval("thrust(isp) = g0 * isp * dm");
    
    // Drag function
    mz.eval("drag(r, v) = 1/2 * density(r) * v^2 * A * dragCoef");

    const thrust = toNum(mz.eval("thrust(isp(r0))") as number | Value);
    const drag = toNum(mz.eval("drag(r0, v0)") as number | Value);
    
    console.log("thrust(isp(r0)):", thrust);
    console.log("drag(r0, v0):", drag);

    // Thrust should be positive and much larger than drag at low velocity
    expect(thrust).toBeGreaterThan(0);
    expect(drag).toBeGreaterThan(0);
    expect(thrust).toBeGreaterThan(drag * 10); // Thrust should be much larger
  });

  it("should handle thrust minus drag operations", () => {
    // From thrust_drag.ts - investigating return type differences
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

    const thrustVal = mz.eval("thrust(isp(r0))");
    const dragVal = mz.eval("drag(r0, v0)");
    
    // Test types
    console.log("thrust type:", typeof thrustVal);
    console.log("drag type:", typeof dragVal);
    
    if (thrustVal instanceof Value) {
      console.log("thrust tag:", (thrustVal as Value).tag);
    }
    if (dragVal instanceof Value) {
      console.log("drag tag:", (dragVal as Value).tag);
    }
    
    // Test subtraction
    try {
      const result = mz.eval("thrust(isp(r0)) - drag(r0, v0)");
      console.log("thrust - drag:", result);
      console.log("result type:", typeof result);
      expect(result).toBeDefined();
    } catch (e) {
      console.error("thrust - drag failed:", e);
      throw e;
    }
  });

  it("should handle thrust and drag with unit conversions", () => {
    // From debug_thrust_drag.ts - unit dimension checking
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

    // Test with explicit unit conversion
    const thrustConv = mz.eval("conv(thrust(isp(r0)), N)");
    const dragConv = mz.eval("conv(drag(r0, v0), N)");
    
    console.log("conv(thrust(isp(r0)), N):", thrustConv);
    console.log("conv(drag(r0, v0), N):", dragConv);
    
    expect(typeof thrustConv).toBe("number");
    expect(typeof dragConv).toBe("number");
    
    // Now test subtraction with converted values
    try {
      const resultConv = mz.eval("conv(thrust(isp(r0)), N) - conv(drag(r0, v0), N)");
      console.log("conv(thrust) - conv(drag):", resultConv);
      expect(resultConv).toBeDefined();
    } catch (e) {
      console.error("conv(thrust) - conv(drag) failed:", e);
      throw e;
    }
  });

  it("should handle thrust and drag in matrix context", () => {
    // From debug_thrust_drag.ts - matrix context testing
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

    // Unit-bearing matrix literals are rejected (task-15/D6). Strip to SI
    // magnitude with number(..., N) before wrapping in a matrix.
    const netForce = mz.eval("number(thrust(isp(r0)) - drag(r0, v0), N)");
    expect(netForce).toBeDefined();
    const matrixResult = mz.eval("[number(thrust(isp(r0)) - drag(r0, v0), N)]");
    expect(matrixResult).toBeDefined();
    // Honest rejection of unit-bearing elements (no matrix-of-units type).
    expect(() => mz.eval("[thrust(isp(r0)) - drag(r0, v0)]")).toThrow(
      /Matrix unit element unsupported|unit-bearing matrix/
    );
  });
});
