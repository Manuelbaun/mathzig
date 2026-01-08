import type { EvalResult, VarEntry } from "../value_tags";
import { chartAxes, readThemeTokens, withAlpha } from "../theme";

export type TrajectoryData = {
  time: number[];
  altitude: number[];
  velocity: number[];
  gamma: number[];
};

type RocketDeps = {
  evaluate: (expr: string) => EvalResult;
  addLog: (expr: string, res: EvalResult & { type?: string }) => void;
  getVariables: () => Record<string, VarEntry>;
  setVar: (name: string, data: VarEntry) => void;
  ValueTag: { array: number };
  getWasm: () => any;
  readF64: (ptr: number) => number;
  readU32: (ptr: number) => number;
};

export function createRocketDemo(deps: RocketDeps) {
  const { evaluate, addLog, getVariables, setVar, ValueTag, getWasm, readF64, readU32 } = deps;
  let trajectoryResults: TrajectoryData | null = null;

  function runRocketSimulation() {
    addLog("rocket", { value: "Initializing Falcon 9 trajectory simulation…", type: "info" });

    try {
      const steps = [
        "G = 6.67408e-11 m^3 / (kg * s^2)",
        "mbody = 5.9724e24 kg",
        "mu = G * mbody",
        "g0 = 9.80665 m/s^2",
        "r0 = 6371 km",
        "isp_sea = 282 s",
        "isp_vac = 311 s",
        "gamma0 = 89.99970 deg",
        "v0 = 1 m/s",
        "phi0 = 0 deg",
        "m1 = 433100 kg",
        "m2 = 111500 kg",
        "m3 = 1700 kg",
        "mp = 5000 kg",
        "m0 = m1+m2+m3+mp",
        "dm = 2750 kg/s",
        "A = (3.66 m)^2 * pi",
        "dragCoef = 0.2",
        "mu_v = conv(mu, m^3/s^2)",
        "g0_v = conv(g0, m/s^2)",
        "r0_v = conv(r0, m)",
        "dm_v = conv(dm, kg/s)",
        "A_v = conv(A, m^2)",
        "isp_sea_v = conv(isp_sea, s)",
        "isp_vac_v = conv(isp_vac, s)",
        "density_v(r) = 1.2250 * exp(-g0_v * (r - r0_v) / 83246.8)",
        "isp_v(r) = isp_vac_v + (isp_sea_v - isp_vac_v) * density_v(r)/density_v(r0_v)",
        "thrust_v(isp) = g0_v * isp * dm_v",
        "drag_v(r, v) = 1/2 * density_v(r) * v^2 * A_v * dragCoef",
        "rad = 1",
        "rocket_deriv(t, y) = [y[1, 0] * sin(y[4, 0]); -mu_v / y[0, 0]^2 * sin(y[4, 0]) + (thrust_v(isp_v(y[0, 0])) - drag_v(y[0, 0], y[1, 0])) / y[2, 0]; -dm_v; y[1, 0]/y[0, 0] * cos(y[4, 0]) * rad; (y[1, 0]/y[0, 0] * cos(y[4, 0]) - (mu_v / y[0, 0]^2) * cos(y[4, 0]) / y[1, 0]) * rad]",
        "tfinal = 149.5",
        "y0 = [r0_v; v0; m0; phi0; gamma0]",
        'result_stage1 = ode_solve_euler("rocket_deriv", y0, [0, tfinal], 2.0)',
      ];

      for (const expr of steps) addLog(expr, evaluate(expr));

      const rows1 = evaluate("size(result_stage1).rows");
      if (rows1.error) {
        addLog("stage1", { error: rows1.error });
        return;
      }
      const r1 = typeof rows1.value === "string" ? parseInt(rows1.value, 10) : Number(rows1.value);

      const interstage = [
        "t_inter = 10",
        `x1 = [result_stage1[${r1 - 1}, 1]; result_stage1[${r1 - 1}, 2]; conv(m2 + m3 + mp, kg); result_stage1[${r1 - 1}, 4]; result_stage1[${r1 - 1}, 5]]`,
        `t1 = result_stage1[${r1 - 1}, 0]`,
        'rocket_deriv_inter(t, y) = [y[1, 0] * sin(max(0, y[4, 0])); -mu_v / y[0, 0]^2 * sin(max(0, y[4, 0])) - drag_v(y[0, 0], y[1, 0]) / y[2, 0]; 0; y[1, 0]/y[0, 0] * cos(y[4, 0]); (y[1, 0]/y[0, 0] - mu_v / (y[0, 0]^2 * y[1, 0])) * cos(y[4, 0])]',
        'result_interstage = ode_solve_euler("rocket_deriv_inter", x1, [t1, t1 + t_inter], 2.0)',
      ];
      for (const expr of interstage) addLog(expr, evaluate(expr));

      const rows_inter = evaluate("size(result_interstage).rows");
      const ri =
        typeof rows_inter.value === "string" ? parseInt(rows_inter.value, 10) : Number(rows_inter.value);

      const stage2 = [
        "t_s2 = 397",
        `x2 = [result_interstage[${ri - 1}, 1]; result_interstage[${ri - 1}, 2]; result_interstage[${ri - 1}, 3]; result_interstage[${ri - 1}, 4]; result_interstage[${ri - 1}, 5]]`,
        `t2 = result_interstage[${ri - 1}, 0]`,
        'rocket_deriv_s2(t, y) = [y[1, 0] * sin(max(0, y[4, 0])); -mu_v / y[0, 0]^2 * sin(max(0, y[4, 0])) + (g0_v * 348 * 270.8 - drag_v(y[0, 0], y[1, 0])) / y[2, 0]; -270.8; y[1, 0]/y[0, 0] * cos(y[4, 0]); (y[1, 0]/y[0, 0] - mu_v / (y[0, 0]^2 * y[1, 0])) * cos(y[4, 0])]',
        'result_stage2 = ode_solve_euler("rocket_deriv_s2", x2, [t2, t2 + t_s2], 4.0)',
      ];
      for (const expr of stage2) addLog(expr, evaluate(expr));

      const rows2 = evaluate("size(result_stage2).rows");
      const r2 = typeof rows2.value === "string" ? parseInt(rows2.value, 10) : Number(rows2.value);

      const final_h = evaluate(`(result_stage2[${r2 - 1}, 1] - r0_v) / 1000`);
      const final_v = evaluate(`result_stage2[${r2 - 1}, 2]`);
      const h = parseFloat(String(final_h.value)).toFixed(1);
      const v = parseFloat(String(final_v.value)).toFixed(0);

      addLog("Stage 2", { value: `Orbital insertion: Alt=${h}km, Vel=${v}m/s`, type: "success" });
      addLog("Mission", { value: `SUCCESS! Final orbit: ${h}km altitude at ${v}m/s`, type: "success" });

      extractTrajectoryData(r1, ri, r2);
      addLog("plot", { value: 'Type "plot" or "trajectory" to visualize the flight path', type: "info" });
    } catch (e: any) {
      addLog("error", { error: `JavaScript error: ${e.message}` });
      console.error("Rocket simulation error:", e);
    }
  }

  function extractTrajectoryData(rows1: number, rowsInter: number, rows2: number) {
    trajectoryResults = { time: [], altitude: [], velocity: [], gamma: [] };
    const userVariables = getVariables();
    const v1 = userVariables["result_stage1"];
    const vi = userVariables["result_interstage"];
    const v2 = userVariables["result_stage2"];

    if (!v1?.ptr || !vi?.ptr || !v2?.ptr) {
      addLog("error", { error: "Simulation results missing from memory" });
      return;
    }

    const wasm = getWasm();
    const readRow = (ptr: number, rowIdx: number, cols: number) => {
      let dataPtr: number;
      let stride: number;
      if (wasm?.mathzig_matrix_get_data) {
        dataPtr = wasm.mathzig_matrix_get_data(ptr);
        stride = wasm.mathzig_matrix_stride ? wasm.mathzig_matrix_stride(ptr) : cols;
      } else {
        dataPtr = readU32(ptr + 8);
        stride = readU32(ptr + 24);
      }
      if (dataPtr === 0) return new Array(cols).fill(0);
      const rowData: number[] = [];
      for (let c = 0; c < cols; c++) {
        rowData.push(readF64(dataPtr + (rowIdx * stride + c) * 8));
      }
      return rowData;
    };

    const r0_val = parseFloat(userVariables["r0_v"]?.value || "6371000");

    for (let i = 0; i < rows1; i++) {
      const r = readRow(v1.ptr, i, 6);
      trajectoryResults.time.push(r[0]!);
      trajectoryResults.altitude.push((r[1]! - r0_val) / 1000);
      trajectoryResults.velocity.push(r[2]!);
      trajectoryResults.gamma.push((r[5]! * 180) / Math.PI);
    }
    for (let i = 0; i < rowsInter; i++) {
      const r = readRow(vi.ptr, i, 6);
      trajectoryResults.time.push(r[0]!);
      trajectoryResults.altitude.push((r[1]! - r0_val) / 1000);
      trajectoryResults.velocity.push(r[2]!);
      trajectoryResults.gamma.push((r[5]! * 180) / Math.PI);
    }
    for (let i = 0; i < rows2; i++) {
      const r = readRow(v2.ptr, i, 6);
      trajectoryResults.time.push(r[0]!);
      trajectoryResults.altitude.push((r[1]! - r0_val) / 1000);
      trajectoryResults.velocity.push(r[2]!);
      trajectoryResults.gamma.push((r[5]! * 180) / Math.PI);
    }

    setVar("trajectory_time", {
      value: `[${trajectoryResults.time.length} points]`,
      type: "array",
      tag: ValueTag.array,
      data: trajectoryResults.time,
    });
    setVar("trajectory_alt", {
      value: `[${trajectoryResults.altitude.length} points]`,
      type: "array",
      tag: ValueTag.array,
      data: trajectoryResults.altitude,
    });
    setVar("trajectory_vel", {
      value: `[${trajectoryResults.velocity.length} points]`,
      type: "array",
      tag: ValueTag.array,
      data: trajectoryResults.velocity,
    });
  }

  function getTrajectory() {
    return trajectoryResults;
  }

  function reset() {
    trajectoryResults = null;
  }

  /** Theme helpers re-exported for plot hosts */
  function themeHelpers() {
    return { readThemeTokens, chartAxes, withAlpha };
  }

  return { runRocketSimulation, getTrajectory, reset, themeHelpers };
}
