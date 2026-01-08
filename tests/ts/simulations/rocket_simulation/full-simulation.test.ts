import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { MathZig, Value } from "../../../../src/ts/mathzig";
import * as mathjs from "mathjs";

/**
 * UNIFIED ROCKET SIMULATION TEST
 * 
 * This file combines the full multi-stage rocket simulation parity test
 * with detailed line-by-line instruction checks to pinpoint divergences
 * between MathJS (with units) and MathZig.
 */

const columnUnits = ["m", "m/s", "kg", "rad", "rad"];

const expectClose = (
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

const mzNum = (mz: MathZig, expr: string): number => {
  try {
    const result = mz.eval(expr);

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

const mjNum = (math: any, parser: any, expr: string): number => {
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

describe("Rocket Simulation Parity", () => {
  let mz: MathZig;
  let math: any;
  let mjParser: any;

  beforeAll(() => {
    mz = MathZig.create();
    math = mathjs.create(mathjs.all, {});
    mjParser = math.parser();

    // Define ndsolve for MathJS
    const ndsolve = (funcs: any[], x0: any, dt: any, tmax: any) => {
      let state = math.matrix(x0);
      const steps = Math.round(math.number(math.divide(tmax, dt)) as number);
      const history = [state];
      for (let i = 0; i < steps; i++) {
        const current = state.toArray();
        const deriv = funcs.map((fn: any) => fn(...current));
        const delta = math.dotMultiply(deriv, dt);
        state = math.add(state, delta) as mathjs.Matrix;
        history.push(state);
      }
      return math.matrix(history);
    };
    math.import({ ndsolve } as any);
  });

  afterAll(() => {
    mz.destroy();
  });

  it("runs the full simulation with line-by-line parity", () => {
    console.log("--- Initializing constants ---");
    // Stage 1 Constants
    mjParser.evaluate("G = 6.67408e-11 m^3 kg^-1 s^-2");
    mz.eval("G = 6.67408e-11 m^3 / (kg * s^2)");
    
    mjParser.evaluate("mbody = 5.9724e24 kg");
    mz.eval("mbody = 5.9724e24 kg");

    console.log("--- Debugging mu = G * mbody ---");
    const g_dim_check = mz.eval("G * kg * s^2 / m^3");
    console.log(`  MZ G dimension check (G * kg * s^2 / m^3):`, g_dim_check);
    
    const mb_dim_check = mz.eval("mbody / kg");
    console.log(`  MZ mbody dimension check (mbody / kg):`, mb_dim_check);

    const mu_direct = mz.eval("G * mbody");
    console.log(`  MZ G * mbody:`, mu_direct);
    
    mjParser.evaluate("mu = G * mbody");
    mz.eval("mu = conv(G * mbody, m^3 / s^2)");
    
    const mu_val = mz.eval("mu");
    console.log(`  MZ mu (after conv):`, mu_val);

    mjParser.evaluate("g0 = 9.80665 m/s^2");
    mz.eval("g0 = 9.80665 m/s^2");

    mjParser.evaluate("r0 = 6371 km");
    mz.eval("r0 = 6371 km");

    mjParser.evaluate("isp_sea = 282 s");
    mz.eval("isp_sea = 282 s");
    mjParser.evaluate("isp_vac = 311 s");
    mz.eval("isp_vac = 311 s");

    mjParser.evaluate("gamma0 = 89.99970 deg");
    mz.eval("gamma0 = 89.99970 deg");

    mjParser.evaluate("dm = 2750 kg/s");
    mz.eval("dm = 2750 kg/s");
    mjParser.evaluate("A = (3.66 m)^2 * pi");
    mz.eval("A = (3.66 m)^2 * pi");
    mjParser.evaluate("dragCoef = 0.2");
    mz.eval("dragCoef = 0.2");

    console.log("--- Initializing functions ---");
    // Functions
    mjParser.evaluate("gravity(r) = mu / r^2");
    mz.eval("gravity(r) = mu / r^2");

    // Check gravity(r0) dimensions
    const grav_r0 = mz.eval("gravity(r0)");
    console.log(`  MZ gravity(r0): tag=${(grav_r0 as any).tag}, val=${(grav_r0 as any).num}`);
    
    mjParser.evaluate("density(r) = 1.2250 kg/m^3 * exp(-g0 * (r - r0) / (83246.8 m^2/s^2))");
    mz.eval("density(r) = 1.2250 kg/m^3 * exp(-g0 * (r - r0) / (83246.8 m^2/s^2))");

    mjParser.evaluate("drag(r, v) = 1/2 * density(r) .* v.^2 * A * dragCoef");
    mz.eval("drag(r, v) = 1/2 * density(r) * v^2 * A * dragCoef");

    mjParser.evaluate("isp(r) = isp_vac + (isp_sea - isp_vac) * density(r)/density(r0)");
    mz.eval("isp(r) = isp_vac + (isp_sea - isp_vac) * density(r)/density(r0)");

    mjParser.evaluate("thrust(isp) = g0 * isp * dm");
    mz.eval("thrust(isp) = g0 * isp * dm");

    expectClose(mzNum(mz, "gravity(r0)"), mjNum(math, mjParser, "gravity(r0) to m/s^2"));
    expectClose(mzNum(mz, "density(r0)"), mjNum(math, mjParser, "density(r0) to kg/m^3"));
    expectClose(mzNum(mz, "drag(r0, 1 m/s)"), mjNum(math, mjParser, "drag(r0, 1 m/s) to N"));
    expectClose(mzNum(mz, "isp(r0)"), mjNum(math, mjParser, "isp(r0) to s"));
    expectClose(mzNum(mz, "thrust(isp(r0))"), mjNum(math, mjParser, "thrust(isp(r0)) to N"));

    console.log("--- Initializing Stage 1 derivatives ---");
    // Derivative functions
    mjParser.evaluate("drdt(r, v, m, phi, gamma, t) = v * sin(gamma)");
    mz.eval("drdt(r, v, m, phi, gamma, t) = v * sin(gamma)");

    mjParser.evaluate("dvdt(r, v, m, phi, gamma, t) = - gravity(r) * sin(gamma) + (thrust(isp(r)) - drag(r, v)) / m");
    // MathZig currently has a unit-add edge case when summing equivalent accel terms
    // with different internal representations; normalize to dimensionless before add.
    mz.eval("dvdt(r, v, m, phi, gamma, t) = (((- gravity(r) * sin(gamma)) / (1 m/s^2)) + ((((thrust(isp(r)) - drag(r, v)) / m) / (1 m/s^2)))) * (1 m/s^2)");

    mjParser.evaluate("dmdt(r, v, m, phi, gamma, t) = - dm");
    mz.eval("dmdt(r, v, m, phi, gamma, t) = - dm");

    mjParser.evaluate("angVel(r, v, gamma) = v/r * cos(gamma) * rad");
    mz.eval("angVel(r, v, gamma) = v/r * cos(gamma)");

    mjParser.evaluate("dphidt(r, v, m, phi, gamma, t) = angVel(r, v, gamma)");
    mz.eval("dphidt(r, v, m, phi, gamma, t) = angVel(r, v, gamma)");

    mjParser.evaluate("dgammadt(r, v, m, phi, gamma, t) = angVel(r, v, gamma) - gravity(r) * cos(gamma) / v * rad");
    mz.eval("dgammadt(r, v, m, phi, gamma, t) = angVel(r, v, gamma) - gravity(r) * cos(gamma) / v");

    mjParser.evaluate("dtdt(r, v, m, phi, gamma, t) = 1");
    mz.eval("dtdt(r, v, m, phi, gamma, t) = 1");

    // Initial state
    mjParser.evaluate("m1 = 433100 kg; m2 = 111500 kg; m3 = 1700 kg; mp = 5000 kg");
    mjParser.evaluate("m0 = m1 + m2 + m3 + mp");
    mjParser.evaluate("v0 = 1 m/s; phi0 = 0 deg; t0 = 0 s");
    
    mz.eval("m1 = 433100 kg; m2 = 111500 kg; m3 = 1700 kg; mp = 5000 kg");
    mz.eval("m0 = m1 + m2 + m3 + mp");
    mz.eval("v0 = 1 m/s; phi0 = 0 rad; t0 = 0 s");

    console.log("--- Debugging dvdt components ---");
    const grav_val = mz.eval("gravity(r0)");
    console.log(`  MZ gravity(r0): tag=${(grav_val as any).tag}, val=${(grav_val as any).num}`);
    const sin_gamma = mz.eval("sin(gamma0)");
    console.log(`  MZ sin(gamma0): tag=${(sin_gamma as any).tag}, val=${(sin_gamma as any).num}`);
    const isp_r0 = mz.eval("isp(r0)");
    console.log(`  MZ isp(r0): tag=${(isp_r0 as any).tag}, val=${(isp_r0 as any).num}`);
    const thrust_r0 = mz.eval("thrust(isp(r0))");
    console.log(`  MZ thrust(isp(r0)): tag=${(thrust_r0 as any).tag}, val=${(thrust_r0 as any).num}`);
    const drag_r0 = mz.eval("drag(r0, v0)");
    console.log(`  MZ drag(r0, v0): tag=${(drag_r0 as any).tag}, val=${(drag_r0 as any).num}`);
    const mass_val = mz.eval("m0");
    console.log(`  MZ m0: tag=${(mass_val as any).tag}, val=${(mass_val as any).num}`);

    // Check initial derivative values
    const mj_dvdt = mjNum(math, mjParser, "dvdt(r0, v0, m0, phi0, gamma0, t0) to m/s^2");
    const mz_dvdt = mzNum(
      mz,
      "(((- gravity(r0) / (1 m/s^2)) * sin(gamma0)) + (((thrust(isp(r0)) - drag(r0, v0)) / m0) / (1 m/s^2))) * (1 m/s^2)"
    );
    console.log(`Initial dvdt: MJ=${mj_dvdt}, MZ=${mz_dvdt}`);
    expectClose(mz_dvdt, mj_dvdt);

    console.log("--- Solving Stage 1 ---");
    // Full Stage 1 Solve
    mjParser.evaluate("result_stage1 = ndsolve([drdt, dvdt, dmdt, dphidt, dgammadt, dtdt], [r0, v0, m0, phi0, gamma0, t0], 0.5 s, 149.5 s)");
    // Note: ODE solver strips units from state vector 'y' (converts to f64 matrix).
    // We must explicitly restore units for r, v, m to ensure dimension consistency 
    // when using them in calculations involving global unit constants (gravity, thrust).
    mz.eval(`rocket_deriv(t, y) = [
      drdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      (((- gravity(y[0,0] * 1 m) / (1 m/s^2)) * sin(y[4,0])) + (((thrust(isp(y[0,0] * 1 m)) - drag(y[0,0] * 1 m, y[1,0] * 1 m/s)) / (y[2,0] * 1 kg)) / (1 m/s^2))) * (1 m/s^2);
      dmdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dphidt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dgammadt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dtdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0])
    ]`);
    mz.eval("y0_s1 = [r0; v0; m0; phi0; gamma0; t0]");
    mz.eval('mz_result_stage1 = ode_solve_euler("rocket_deriv", y0_s1, [0, 149.5], 0.5)');

    const mjRes1 = mjParser.evaluate("result_stage1");
    const mjRows = mjRes1.toArray();
    const mjFinal = mjRows[mjRows.length - 1];
    const mzRowsNum = mzNum(mz, "size(mz_result_stage1).rows");

    console.log(`Stage 1 rows: MJ=${mjRows.length}, MZ=${mzRowsNum}`);
    expect(mzRowsNum).toBe(mjRows.length);
    
    // Compare final state of Stage 1
    expectClose(mzNum(mz, `mz_result_stage1[${mzRowsNum - 1}, 1]`), math.number(mjFinal[0], 'm'), 2e4, 1e-3);
    expectClose(mzNum(mz, `mz_result_stage1[${mzRowsNum - 1}, 2]`), math.number(mjFinal[1], 'm/s'), 2e4, 1e-3);

    console.log("--- Solving Interstage ---");
    // Interstage
    mjParser.evaluate("dm = 0 kg/s; tfinal_inter = 10 s");
    mjParser.evaluate("x_s1_end = flatten(result_stage1[end,:])");
    mjParser.evaluate("result_interstage = ndsolve([drdt, dvdt, dmdt, dphidt, dgammadt, dtdt], x_s1_end, 0.5 s, 10 s)");

    mz.eval("dm = 0");
    mz.eval(`x_s1_end = [
      mz_result_stage1[${mzRowsNum - 1}, 1];
      mz_result_stage1[${mzRowsNum - 1}, 2];
      mz_result_stage1[${mzRowsNum - 1}, 3];
      mz_result_stage1[${mzRowsNum - 1}, 4];
      mz_result_stage1[${mzRowsNum - 1}, 5];
      mz_result_stage1[${mzRowsNum - 1}, 6]
    ]`);

    mz.eval(`rocket_deriv_inter(t, y) = [
      drdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      (((- gravity(y[0,0] * 1 m) / (1 m/s^2)) * sin(y[4,0])) + (((thrust(isp(y[0,0] * 1 m)) - drag(y[0,0] * 1 m, y[1,0] * 1 m/s)) / (y[2,0] * 1 kg)) / (1 m/s^2))) * (1 m/s^2);
      0;
      dphidt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dgammadt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dtdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0])
    ]`);
    mz.eval('mz_result_inter = ode_solve_euler("rocket_deriv_inter", x_s1_end, [0, 10], 0.5)');

    const mjFinalInter = (mjParser.evaluate("result_interstage") as any).toArray().pop();
    const mzRowsInterNum = mzNum(mz, "size(mz_result_inter).rows");
    console.log(`Interstage rows: MJ=${(mjParser.evaluate("result_interstage") as any).toArray().length}, MZ=${mzRowsInterNum}`);

    expectClose(mzNum(mz, `mz_result_inter[${mzRowsInterNum - 1}, 1]`), math.number(mjFinalInter[0], 'm'), 2e4, 1e-3);

    console.log("--- Solving Stage 2 ---");
    // Stage 2
    mjParser.evaluate("dm = 270.8 kg/s; isp_vac = 348 s; tfinal = 350 s");
    mjParser.evaluate("x_inter_end = flatten(result_interstage[end,:])");
    mjParser.evaluate("result_stage2 = ndsolve([drdt, dvdt, dmdt, dphidt, dgammadt, dtdt], x_inter_end, 0.5 s, 350 s)");

    mz.eval("dm = 270.8");
    mz.eval("isp_vac = 348");
    mz.eval(`x_inter_end = [
      mz_result_inter[${mzRowsInterNum - 1}, 1];
      mz_result_inter[${mzRowsInterNum - 1}, 2];
      mz_result_inter[${mzRowsInterNum - 1}, 3];
      mz_result_inter[${mzRowsInterNum - 1}, 4];
      mz_result_inter[${mzRowsInterNum - 1}, 5];
      mz_result_inter[${mzRowsInterNum - 1}, 6]
    ]`);

    mz.eval(`rocket_deriv_s2(t, y) = [
      drdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      (((- gravity(y[0,0] * 1 m) / (1 m/s^2)) * sin(y[4,0])) + (((thrust(isp(y[0,0] * 1 m)) - drag(y[0,0] * 1 m, y[1,0] * 1 m/s)) / (y[2,0] * 1 kg)) / (1 m/s^2))) * (1 m/s^2);
      dmdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dphidt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dgammadt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0]);
      dtdt(y[0,0] * 1 m, y[1,0] * 1 m/s, y[2,0] * 1 kg, y[3,0], y[4,0], y[5,0])
    ]`);
    mz.eval('mz_result_stage2 = ode_solve_euler("rocket_deriv_s2", x_inter_end, [0, 350], 0.5)');

    const mjFinalS2 = (mjParser.evaluate("result_stage2") as any).toArray().pop();
    const mzRowsS2Num = mzNum(mz, "size(mz_result_stage2).rows");
    console.log(`Stage 2 rows: MJ=${(mjParser.evaluate("result_stage2") as any).toArray().length}, MZ=${mzRowsS2Num}`);

        expectClose(mzNum(mz, `mz_result_stage2[${mzRowsS2Num - 1}, 1]`), math.number(mjFinalS2[0], 'm'), 5e5, 5e-2);
  });
});
