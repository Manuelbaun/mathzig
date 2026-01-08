/**
 * COMPREHENSIVE PARITY TESTS
 * 
 * Comprehensive MathZig vs MathJS parity analysis with divergence detection
 * From: parity_analysis.ts
 */
import { describe, expect, it } from "bun:test";
import { beforeAll, afterAll } from "bun:test";
import { MathZig, Value } from "../../../../../src/ts/mathzig";
import * as mathjs from "mathjs";
import { setupMathJS, compareValues } from "../helpers";

describe("Comprehensive Parity Tests", () => {
  let mz: MathZig;
  let math: any;
  let mjParser: any;

  beforeAll(() => {
    mz = MathZig.create();
    const setup = setupMathJS();
    math = setup.math;
    mjParser = setup.mjParser;
  });

  afterAll(() => {
    mz.destroy();
  });

  it("should maintain parity in basic constants", () => {
    // Test basic physical constants
    const constants = [
      { expr: "6.67408e-11", name: "G" },
      { expr: "5.9724e24", name: "mbody" },
      { expr: "9.80665", name: "g0" },
      { expr: "6371000", name: "r0_m" },
      { expr: "282", name: "isp_sea" },
      { expr: "311", name: "isp_vac" }
    ];

    let allPass = true;
    
    constants.forEach(({ expr, name }) => {
      const mjVal = mjParser.evaluate(expr);
      const mzVal = mz.eval(expr);
      
      const pass = compareValues(name, mjVal, mzVal as number, 1e-12);
      allPass = allPass && pass;
    });

    expect(allPass).toBe(true);
  });

  it("should maintain parity in unit expressions", () => {
    // Test expressions with units
    const unitExprs = [
      { 
        mjExpr: "6.67408e-11 m^3 kg^-1 s^-2", 
        mzExpr: "6.67408e-11 m^3 / (kg * s^2)", 
        name: "G with units",
        conv: "m^3 / (kg * s^2)"
      },
      { 
        mjExpr: "5.9724e24 kg", 
        mzExpr: "5.9724e24 kg", 
        name: "mbody with units",
        conv: "kg"
      },
      { 
        mjExpr: "9.80665 m/s^2", 
        mzExpr: "9.80665 m/s^2", 
        name: "g0 with units",
        conv: "m/s^2"
      },
      { 
        mjExpr: "6371 km", 
        mzExpr: "6371 km", 
        name: "r0 in km",
        conv: "m"
      },
      { 
        mjExpr: "282 s", 
        mzExpr: "282 s", 
        name: "isp_sea with units",
        conv: "s"
      },
      { 
        mjExpr: "89.99970 deg", 
        mzExpr: "89.99970 deg", 
        name: "gamma0 with units",
        conv: "rad"
      }
    ];

    let allPass = true;
    
    unitExprs.forEach(({ mjExpr, mzExpr, name, conv }) => {
      try {
        const mjVal = math.number(mjParser.evaluate(mjExpr), conv);
        const mzVal = mz.eval(`conv(${mzExpr}, ${conv})`);
        
        const pass = compareValues(name, mjVal, mzVal as number, 1e-9);
        allPass = allPass && pass;
      } catch (e) {
        console.error(`Failed ${name}:`, e);
        allPass = false;
      }
    });

    expect(allPass).toBe(true);
  });

  it("should maintain parity in function definitions", () => {
    // Numeric function parity (scalar radius input in meters)
    mjParser.evaluate("mu_num = 6.67408e-11 * 5.9724e24");
    mz.eval("mu_num = 6.67408e-11 * 5.9724e24");
    mjParser.evaluate("gravity(r_m) = mu_num / (r_m^2)");
    mz.eval("gravity(r_m) = mu_num / (r_m^2)");

    // Test at different radii
    const testRadii = ["6371000", "6400000", "7000000"];
    
    let allPass = true;
    
    testRadii.forEach(r => {
      const mjVal = math.number(mjParser.evaluate(`gravity(${r})`));
      const mzVal = mz.eval(`gravity(${r})`);
      
      const pass = compareValues(`gravity at ${r}m`, mjVal, mzVal as number, 1e-6);
      allPass = allPass && pass;
    });

    expect(allPass).toBe(true);
  });

  it("should maintain parity in complex expressions", () => {
    // Test complex numeric expressions (unit conversions are already covered above)
    mjParser.evaluate("mu_num = 6.67408e-11 * 5.9724e24");
    mz.eval("mu_num = 6.67408e-11 * 5.9724e24");

    const complexExprs = [
      {
        mjExpr: "mu_num / (6371000^2)",
        mzExpr: "mu_num / (6371000^2)",
        name: "surface gravity",
        conv: ""
      },
      {
        mjExpr: "sqrt(mu_num / 6371000)",
        mzExpr: "sqrt(mu_num / 6371000)",
        name: "orbital velocity",
        conv: ""
      },
      {
        mjExpr: "2 * pi * 6371000 / (2 * 7800)",
        mzExpr: "2 * pi * 6371000 / (2 * 7800)",
        name: "orbital period component",
        conv: ""
      }
    ];

    let allPass = true;
    
    complexExprs.forEach(({ mjExpr, mzExpr, name, conv }) => {
      try {
        const mjVal = conv.length > 0 ? math.number(mjParser.evaluate(mjExpr), conv) : math.number(mjParser.evaluate(mjExpr));
        const mzVal = conv.length > 0 ? mz.eval(`conv(${mzExpr}, ${conv})`) : mz.eval(mzExpr);
        
        const pass = compareValues(name, mjVal, mzVal as number, 1e-9);
        allPass = allPass && pass;
      } catch (e) {
        console.error(`Failed ${name}:`, e);
        allPass = false;
      }
    });

    expect(allPass).toBe(true);
  });

  it("should detect divergences in ODE solutions", () => {
    // From parity_analysis.ts - divergence detection
    // Set up rocket physics
    mjParser.evaluate("G = 6.67408e-11 m^3 kg^-1 s^-2");
    mjParser.evaluate("mbody = 5.9724e24 kg");
    mjParser.evaluate("mu = G * mbody");
    mjParser.evaluate("g0 = 9.80665 m/s^2");
    mjParser.evaluate("r0 = 6371 km");
    mjParser.evaluate("isp_sea = 282 s");
    mjParser.evaluate("isp_vac = 311 s");
    mjParser.evaluate("gamma0 = 89.99970 deg");
    mjParser.evaluate("dm = 2750 kg/s");
    mjParser.evaluate("A = (3.66 m)^2 * pi");
    mjParser.evaluate("dragCoef = 0.2");

    // Functions
    mjParser.evaluate("density(r) = 1.2250 kg/m^3 * exp(-g0 * (r - r0) / (83246.8 m^2/s^2))");
    mjParser.evaluate("drag(r, v) = 1/2 * density(r) .* v.^2 * A * dragCoef");
    mjParser.evaluate("isp(r) = isp_vac + (isp_sea - isp_vac) * density(r)/density(r0)");
    mjParser.evaluate("thrust(isp) = g0 * isp * dm");

    // MathZig setup
    mz.eval("G = 6.67408e-11 m^3 / (kg * s^2)");
    mz.eval("mbody = 5.9724e24 kg");
    mz.eval("mu = G * mbody");
    mz.eval("g0 = 9.80665 m/s^2");
    mz.eval("r0 = 6371 km");
    mz.eval("isp_sea = 282 s");
    mz.eval("isp_vac = 311 s");
    mz.eval("gamma0 = 89.99970 deg");
    mz.eval("dm = 2750 kg/s");
    mz.eval("A = (3.66 m)^2 * pi");
    mz.eval("dragCoef = 0.2");

    mz.eval("density(r) = 1.2250 kg/m^3 * exp(-g0 * (r - r0) / (83246.8 m^2/s^2))");
    mz.eval("drag(r, v) = 1/2 * density(r) * v^2 * A * dragCoef");
    mz.eval("isp(r) = isp_vac + (isp_sea - isp_vac) * density(r)/density(r0)");
    mz.eval("thrust(isp) = g0 * isp * dm");

    // Test function values at various conditions
    const conditions = [
      { r: "r0", v: "1 m/s" },
      { r: "r0 + 10 km", v: "100 m/s" },
      { r: "r0 + 50 km", v: "1000 m/s" }
    ];

    let allPass = true;
    
    conditions.forEach(({ r, v }, i) => {
      // Test density
      const mjDensity = math.number(mjParser.evaluate(`density(${r})`), 'kg/m^3');
      const mzDensity = mz.eval(`conv(density(${r}), kg/m^3)`);
      const densityPass = compareValues(`density at condition ${i}`, mjDensity, mzDensity as number, 1e-6);

      // Test drag
      const mjDrag = math.number(mjParser.evaluate(`drag(${r}, ${v})`), 'N');
      const mzDrag = mz.eval(`conv(drag(${r}, ${v}), N)`);
      const dragPass = compareValues(`drag at condition ${i}`, mjDrag, mzDrag as number, 1e-6);

      // Test isp
      const mjIsp = math.number(mjParser.evaluate(`isp(${r})`), 's');
      const mzIsp = mz.eval(`conv(isp(${r}), s)`);
      const ispPass = compareValues(`isp at condition ${i}`, mjIsp, mzIsp as number, 1e-6);

      // Test thrust
      const mjThrust = math.number(mjParser.evaluate(`thrust(isp(${r}))`), 'N');
      const mzThrust = mz.eval(`conv(thrust(isp(${r})), N)`);
      const thrustPass = compareValues(`thrust at condition ${i}`, mjThrust, mzThrust as number, 1e-6);

      allPass = allPass && densityPass && dragPass && ispPass && thrustPass;
    });

    expect(allPass).toBe(true);
  });

  it("should track cumulative divergence over multiple operations", () => {
    // Test how small errors accumulate
    mjParser.evaluate("base_val = 100.0");
    mz.eval("base_val = 100.0");

    let mjVal = mjParser.evaluate("base_val");
    let mzVal = mz.eval("base_val");
    
    let allPass = true;
    
    // Perform multiple operations
    for (let i = 0; i < 10; i++) {
      const operation = `base_val + ${i * 0.1} * sqrt(base_val) / ${i + 1}`;
      
      mjVal = math.number(mjParser.evaluate(operation));
      mzVal = mz.eval(operation);
      
      const pass = compareValues(`operation ${i}`, mjVal, mzVal as number, 1e-12);
      allPass = allPass && pass;
    }

    expect(allPass).toBe(true);
  });
});
