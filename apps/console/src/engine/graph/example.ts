import type { GraphDefinition } from "@mathzig/graph";

/**
 * Graph editor starter examples (like the REPL rocket demo, but for the node graph).
 *
 * Each entry is a pure runner {@link GraphDefinition}. Canvas layout is applied by
 * `parseImport` → `autoLayoutUi` (including named **graph output** nodes).
 */

export type GraphExampleCategory =
  | "basics"
  | "signals"
  | "math"
  | "matrix"
  | "complex"
  | "multi_out"
  | "simulations";

export type GraphExample = {
  id: string;
  title: string;
  description: string;
  category: GraphExampleCategory;
  /** Short badge for the picker (e.g. "scalar", "matrix"). */
  tags: string[];
  definition: GraphDefinition;
};

// ─── Simulation graphs (multi-node; not one mega-expression) ─────────────────
//
// AOT graph nodes are isolated wasm modules: nested helper *functions* must live
// in the same expr node that calls ode_solve. Scalar/matrix *assignments* are
// separate const/expr nodes wired by edges (REPL-style variable graph).
// Boundary limit: ≤3 inputs+params per expr (x/y/z).

/** Lorenz RHS + integrate. `x` = y0 matrix; params t_end, dt. */
const LORENZ_SIM_EXPR =
  "f(t, u) = [10 * (u[1] - u[0]); u[0] * (28 - u[2]) - u[1]; u[0] * u[1] - (8/3) * u[2]]; " +
  'ode_solve("f", x, [0, t_end], dt)';

/**
 * Rocket stage-1 helpers + integrate.
 * `x` = y0 state [r;v;m;phi;gamma]; params t_end, dt.
 * SI numbers (REPL rocket stage 1 without the units system).
 */
const ROCKET_S1_EXPR =
  "density_v(r) = 1.2250 * exp(-9.80665 * (r - 6371000) / 83246.8); " +
  "isp_v(r) = 311 + (282 - 311) * density_v(r) / density_v(6371000); " +
  "thrust_v(isp) = 9.80665 * isp * 2750; " +
  "drag_v(r, v) = 0.5 * density_v(r) * v * v * (3.66 * 3.66 * 3.141592653589793) * 0.2; " +
  "mu = 3.986004418e14; " +
  "rocket_deriv(t, y) = [" +
  "y[1, 0] * sin(y[4, 0]); " +
  "-mu / y[0, 0]^2 * sin(y[4, 0]) + (thrust_v(isp_v(y[0, 0])) - drag_v(y[0, 0], y[1, 0])) / y[2, 0]; " +
  "-2750; " +
  "y[1, 0] / y[0, 0] * cos(y[4, 0]); " +
  "(y[1, 0] / y[0, 0] * cos(y[4, 0]) - (mu / y[0, 0]^2) * cos(y[4, 0]) / y[1, 0])" +
  "]; " +
  'ode_solve_euler("rocket_deriv", x, [0, t_end], dt)';

/**
 * Interstage coast: no thrust, mass held. `x` = state 5×1, `y` = t_start (s).
 * Params: dt. Duration baked at 10 s (REPL twin).
 */
const ROCKET_INTER_EXPR =
  "density_v(r) = 1.2250 * exp(-9.80665 * (r - 6371000) / 83246.8); " +
  "drag_v(r, v) = 0.5 * density_v(r) * v * v * (3.66 * 3.66 * 3.141592653589793) * 0.2; " +
  "mu = 3.986004418e14; " +
  "rocket_deriv_inter(t, st) = [" +
  "st[1, 0] * sin(max(0, st[4, 0])); " +
  "-mu / st[0, 0]^2 * sin(max(0, st[4, 0])) - drag_v(st[0, 0], st[1, 0]) / st[2, 0]; " +
  "0; " +
  "st[1, 0] / st[0, 0] * cos(st[4, 0]); " +
  "(st[1, 0] / st[0, 0] - mu / (st[0, 0]^2 * st[1, 0])) * cos(st[4, 0])" +
  "]; " +
  'ode_solve_euler("rocket_deriv_inter", x, [y, y + 10], dt)';

/**
 * Stage-2 burn: fixed vac thrust (Isp 348, mdot 270.8). `x` = state, `y` = t_start.
 * Params: dt. Duration baked at 397 s (REPL twin).
 */
const ROCKET_S2_EXPR =
  "density_v(r) = 1.2250 * exp(-9.80665 * (r - 6371000) / 83246.8); " +
  "drag_v(r, v) = 0.5 * density_v(r) * v * v * (3.66 * 3.66 * 3.141592653589793) * 0.2; " +
  "mu = 3.986004418e14; " +
  "thrust = 9.80665 * 348 * 270.8; " +
  "rocket_deriv_s2(t, st) = [" +
  "st[1, 0] * sin(max(0, st[4, 0])); " +
  "-mu / st[0, 0]^2 * sin(max(0, st[4, 0])) + (thrust - drag_v(st[0, 0], st[1, 0])) / st[2, 0]; " +
  "-270.8; " +
  "st[1, 0] / st[0, 0] * cos(st[4, 0]); " +
  "(st[1, 0] / st[0, 0] - mu / (st[0, 0]^2 * st[1, 0])) * cos(st[4, 0])" +
  "]; " +
  'ode_solve_euler("rocket_deriv_s2", x, [y, y + 397], dt)';

// ─── catalog ─────────────────────────────────────────────────────────────────

export const GRAPH_EXAMPLES: GraphExample[] = [
  {
    id: "lowpass_gain",
    title: "Lowpass + gain",
    description: "Source through a 1-pole lowpass (feedback via const) then gain. Two named graph outputs.",
    category: "signals",
    tags: ["scalar", "params", "2 outs"],
    definition: {
      nodes: [
        { id: "source", type: "input", name: "source" },
        {
          id: "lowpass",
          type: "expr",
          expr: "x * a + y * (1 - a)",
          inputs: ["x", "y"],
          params: { a: 0.2 },
        },
        {
          id: "gain",
          type: "expr",
          expr: "x * g",
          inputs: ["x"],
          params: { g: 1.5 },
        },
        { id: "prev", type: "const", value: 0 },
      ],
      edges: [
        { from: "source.out", to: "lowpass.x" },
        { from: "prev.out", to: "lowpass.y" },
        { from: "lowpass.out", to: "gain.x" },
      ],
      outputs: { value: "gain.out", filtered: "lowpass.out" },
    },
  },
  {
    id: "scale_offset",
    title: "Scale & offset",
    description: "Classic y = m·x + b with params m and b.",
    category: "basics",
    tags: ["scalar", "params"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        {
          id: "scale",
          type: "expr",
          expr: "x * m",
          inputs: ["x"],
          params: { m: 2 },
        },
        {
          id: "offset",
          type: "expr",
          expr: "x + b",
          inputs: ["x"],
          params: { b: 1 },
        },
      ],
      edges: [
        { from: "x.out", to: "scale.x" },
        { from: "scale.out", to: "offset.x" },
      ],
      outputs: { y: "offset.out" },
    },
  },
  {
    id: "quadratic",
    title: "Quadratic",
    description: "a·x² + b·x + c — three tunable params, one graph output.",
    category: "math",
    tags: ["scalar", "params"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        {
          id: "x2",
          type: "expr",
          expr: "x * x",
          inputs: ["x"],
        },
        {
          id: "ax2",
          type: "expr",
          expr: "x * a",
          inputs: ["x"],
          params: { a: 1 },
        },
        {
          id: "bx",
          type: "expr",
          expr: "x * b",
          inputs: ["x"],
          params: { b: -2 },
        },
        {
          id: "sum",
          type: "expr",
          expr: "x + y + c",
          inputs: ["x", "y"],
          params: { c: 1 },
        },
      ],
      edges: [
        { from: "x.out", to: "x2.x" },
        { from: "x2.out", to: "ax2.x" },
        { from: "x.out", to: "bx.x" },
        { from: "ax2.out", to: "sum.x" },
        { from: "bx.out", to: "sum.y" },
      ],
      outputs: { y: "sum.out" },
    },
  },
  {
    id: "pythagoras",
    title: "Pythagoras",
    description: "Hypotenuse length √(x² + y²) from two inputs.",
    category: "math",
    tags: ["scalar", "2 ins"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "y", type: "input", name: "y" },
        { id: "x2", type: "expr", expr: "x * x", inputs: ["x"] },
        { id: "y2", type: "expr", expr: "x * x", inputs: ["x"] },
        { id: "sum", type: "expr", expr: "x + y", inputs: ["x", "y"] },
        { id: "hyp", type: "expr", expr: "sqrt(x)", inputs: ["x"] },
      ],
      edges: [
        { from: "x.out", to: "x2.x" },
        { from: "y.out", to: "y2.x" },
        { from: "x2.out", to: "sum.x" },
        { from: "y2.out", to: "sum.y" },
        { from: "sum.out", to: "hyp.x" },
      ],
      outputs: { hypotenuse: "hyp.out", sum_sq: "sum.out" },
    },
  },
  {
    id: "temperature_f",
    title: "°C → °F",
    description: "Fahrenheit = C · 9/5 + 32 with intermediate Celsius-scaled term exposed.",
    category: "basics",
    tags: ["scalar", "2 outs"],
    definition: {
      nodes: [
        { id: "celsius", type: "input", name: "celsius" },
        {
          id: "scaled",
          type: "expr",
          expr: "x * 1.8",
          inputs: ["x"],
        },
        {
          id: "fahrenheit",
          type: "expr",
          expr: "x + 32",
          inputs: ["x"],
        },
      ],
      edges: [
        { from: "celsius.out", to: "scaled.x" },
        { from: "scaled.out", to: "fahrenheit.x" },
      ],
      outputs: { fahrenheit: "fahrenheit.out", scaled: "scaled.out" },
    },
  },
  {
    id: "clamp_like",
    title: "Soft clamp (tanh)",
    description: "Map input through gain then tanh for a soft saturation curve.",
    category: "signals",
    tags: ["scalar", "params"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        {
          id: "drive",
          type: "expr",
          expr: "x * g",
          inputs: ["x"],
          params: { g: 1.5 },
        },
        {
          id: "soft",
          type: "expr",
          expr: "tanh(x)",
          inputs: ["x"],
        },
      ],
      edges: [
        { from: "x.out", to: "drive.x" },
        { from: "drive.out", to: "soft.x" },
      ],
      outputs: { y: "soft.out", driven: "drive.out" },
    },
  },
  {
    id: "exp_decay",
    title: "Exponential decay",
    description: "y = A · e^(−k·t) with params A and k; input is time t.",
    category: "math",
    tags: ["scalar", "params"],
    definition: {
      nodes: [
        { id: "t", type: "input", name: "t" },
        {
          id: "neg_kt",
          type: "expr",
          expr: "0 - x * k",
          inputs: ["x"],
          params: { k: 0.5 },
        },
        {
          id: "expn",
          type: "expr",
          expr: "exp(x)",
          inputs: ["x"],
        },
        {
          id: "amp",
          type: "expr",
          expr: "x * A",
          inputs: ["x"],
          params: { A: 10 },
        },
      ],
      edges: [
        { from: "t.out", to: "neg_kt.x" },
        { from: "neg_kt.out", to: "expn.x" },
        { from: "expn.out", to: "amp.x" },
      ],
      outputs: { y: "amp.out" },
    },
  },
  {
    id: "weighted_avg",
    title: "Weighted average",
    description: "w·a + (1−w)·b of two inputs with blend param w.",
    category: "signals",
    tags: ["scalar", "2 ins", "params"],
    definition: {
      nodes: [
        { id: "a", type: "input", name: "a" },
        { id: "b", type: "input", name: "b" },
        {
          id: "wa",
          type: "expr",
          expr: "x * w",
          inputs: ["x"],
          params: { w: 0.3 },
        },
        {
          id: "wb",
          type: "expr",
          expr: "x * (1 - w)",
          inputs: ["x"],
          params: { w: 0.3 },
        },
        {
          id: "mix",
          type: "expr",
          expr: "x + y",
          inputs: ["x", "y"],
        },
      ],
      edges: [
        { from: "a.out", to: "wa.x" },
        { from: "b.out", to: "wb.x" },
        { from: "wa.out", to: "mix.x" },
        { from: "wb.out", to: "mix.y" },
      ],
      outputs: { avg: "mix.out" },
    },
  },
  {
    id: "diamond",
    title: "Diamond multi-out",
    description: "Shared intermediate (*2) fans into +1 and *3; two graph outputs.",
    category: "multi_out",
    tags: ["scalar", "2 outs", "DAG"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "mid", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "plus", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "times", type: "expr", expr: "x * 3", inputs: ["x"] },
      ],
      edges: [
        { from: "x.out", to: "mid.x" },
        { from: "mid.out", to: "plus.x" },
        { from: "mid.out", to: "times.x" },
      ],
      outputs: { plus_one: "plus.out", times_three: "times.out" },
    },
  },
  {
    id: "chain_depth",
    title: "Deep scalar chain",
    description: "Five alternating *2 / +1 stages — good for fused vs modules timing.",
    category: "basics",
    tags: ["scalar", "depth"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "n0", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "n1", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "n2", type: "expr", expr: "x * 2", inputs: ["x"] },
        { id: "n3", type: "expr", expr: "x + 1", inputs: ["x"] },
        { id: "n4", type: "expr", expr: "x * 2", inputs: ["x"] },
      ],
      edges: [
        { from: "x.out", to: "n0.x" },
        { from: "n0.out", to: "n1.x" },
        { from: "n1.out", to: "n2.x" },
        { from: "n2.out", to: "n3.x" },
        { from: "n3.out", to: "n4.x" },
      ],
      outputs: { value: "n4.out", mid: "n2.out" },
    },
  },
  {
    id: "trig_pair",
    title: "Sin & cos pair",
    description: "From phase input, emit both sin(x) and cos(x) as graph outputs.",
    category: "multi_out",
    tags: ["scalar", "trig", "2 outs"],
    definition: {
      nodes: [
        { id: "phase", type: "input", name: "phase" },
        { id: "s", type: "expr", expr: "sin(x)", inputs: ["x"] },
        { id: "c", type: "expr", expr: "cos(x)", inputs: ["x"] },
      ],
      edges: [
        { from: "phase.out", to: "s.x" },
        { from: "phase.out", to: "c.x" },
      ],
      outputs: { sine: "s.out", cosine: "c.out" },
    },
  },
  {
    id: "power_law",
    title: "Power law",
    description: "y = k · x^p with params k and p.",
    category: "math",
    tags: ["scalar", "params"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        {
          id: "pow",
          type: "expr",
          expr: "x ^ p",
          inputs: ["x"],
          params: { p: 2 },
        },
        {
          id: "scale",
          type: "expr",
          expr: "x * k",
          inputs: ["x"],
          params: { k: 1.5 },
        },
      ],
      edges: [
        { from: "x.out", to: "pow.x" },
        { from: "pow.out", to: "scale.x" },
      ],
      outputs: { y: "scale.out" },
    },
  },
  {
    id: "matrix_scale",
    title: "Matrix scale",
    description: "2×2 matrix times a scalar param — matrix graph output.",
    category: "matrix",
    tags: ["matrix", "params"],
    definition: {
      nodes: [
        {
          id: "base",
          type: "expr",
          expr: "[1, 2; 3, 4]",
          outputKind: "matrix",
        },
        {
          id: "scale",
          type: "expr",
          expr: "x * [s, 0; 0, s]",
          inputs: ["x"],
          inputKinds: ["matrix"],
          params: { s: 2 },
          outputKind: "matrix",
        },
      ],
      edges: [{ from: "base.out", to: "scale.x" }],
      outputs: { mat: "scale.out" },
    },
  },
  {
    id: "matrix_chain",
    title: "Matrix chain",
    description: "Literal matrix → scale → left-multiply by a second matrix. Matrix graph output.",
    category: "matrix",
    tags: ["matrix"],
    definition: {
      nodes: [
        {
          id: "m",
          type: "expr",
          expr: "[1, 2; 3, 4] * 2",
          outputKind: "matrix",
        },
        {
          id: "id",
          type: "expr",
          expr: "x * [1, 0; 0, 1]",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
      ],
      edges: [{ from: "m.out", to: "id.x" }],
      outputs: { matrix: "id.out" },
    },
  },
  {
    id: "complex_mul",
    title: "Complex multiply",
    description: "Multiply two complex constants; complex graph output.",
    category: "complex",
    tags: ["complex"],
    definition: {
      nodes: [
        {
          id: "a",
          type: "expr",
          expr: "1 + 2i",
          outputKind: "complex",
        },
        {
          id: "b",
          type: "expr",
          expr: "3 - 1i",
          outputKind: "complex",
        },
        {
          id: "prod",
          type: "expr",
          expr: "x * y",
          inputs: ["x", "y"],
          inputKinds: ["complex", "complex"],
          outputKind: "complex",
        },
      ],
      edges: [
        { from: "a.out", to: "prod.x" },
        { from: "b.out", to: "prod.y" },
      ],
      outputs: { product: "prod.out" },
    },
  },
  {
    id: "vector_mag2",
    title: "2D vector magnitude²",
    description: "From components x,y produce r² = x²+y² (two named scalar outs: parts + result).",
    category: "multi_out",
    tags: ["scalar", "2 ins", "2 outs"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "y", type: "input", name: "y" },
        { id: "x2", type: "expr", expr: "x * x", inputs: ["x"] },
        { id: "y2", type: "expr", expr: "x * x", inputs: ["x"] },
        { id: "r2", type: "expr", expr: "x + y", inputs: ["x", "y"] },
      ],
      edges: [
        { from: "x.out", to: "x2.x" },
        { from: "y.out", to: "y2.x" },
        { from: "x2.out", to: "r2.x" },
        { from: "y2.out", to: "r2.y" },
      ],
      outputs: { r_sq: "r2.out", x_sq: "x2.out" },
    },
  },
  {
    id: "const_fanout",
    title: "Constants fan-out",
    description: "Two const sources combine with an input — multi-const graph.",
    category: "basics",
    tags: ["const", "scalar"],
    definition: {
      nodes: [
        { id: "x", type: "input", name: "x" },
        { id: "two", type: "const", value: 2 },
        { id: "ten", type: "const", value: 10 },
        { id: "scaled", type: "expr", expr: "x * y", inputs: ["x", "y"] },
        { id: "shifted", type: "expr", expr: "x + y", inputs: ["x", "y"] },
      ],
      edges: [
        { from: "x.out", to: "scaled.x" },
        { from: "two.out", to: "scaled.y" },
        { from: "scaled.out", to: "shifted.x" },
        { from: "ten.out", to: "shifted.y" },
      ],
      outputs: { y: "shifted.out", scaled: "scaled.out" },
    },
  },
  {
    id: "ratio_guard",
    title: "Safe ratio",
    description: "num / max(den, eps) to avoid division by zero; both inputs free.",
    category: "math",
    tags: ["scalar", "2 ins", "params"],
    definition: {
      nodes: [
        { id: "num", type: "input", name: "num" },
        { id: "den", type: "input", name: "den" },
        {
          id: "safe",
          type: "expr",
          expr: "max(x, eps)",
          inputs: ["x"],
          params: { eps: 1e-6 },
        },
        {
          id: "ratio",
          type: "expr",
          expr: "x / y",
          inputs: ["x", "y"],
        },
      ],
      edges: [
        { from: "den.out", to: "safe.x" },
        { from: "num.out", to: "ratio.x" },
        { from: "safe.out", to: "ratio.y" },
      ],
      outputs: { ratio: "ratio.out", safe_den: "safe.out" },
    },
  },

  // ── Simulations (multi-node variable graphs; REPL rocket / lorenz twins) ──

  {
    id: "lorenz",
    title: "Lorenz attractor",
    description:
      "Multi-node Lorenz: ICs (x0,y0,z0) → state0 → ODE (classic σ=10,ρ=28,β=8/3 baked in RHS) → final. " +
      "Tune t_end / dt on sim. Nested f() lives on the sim node (wasm isolation).",
    category: "simulations",
    tags: ["ODE", "multi-node", "REPL twin"],
    definition: {
      nodes: [
        // Initial conditions as named assignments
        { id: "x0", type: "const", value: 1 },
        { id: "y0", type: "const", value: 1 },
        { id: "z0", type: "const", value: 0 },
        // state0 = [x0; y0; z0]
        {
          id: "state0",
          type: "expr",
          expr: "[x; y; z]",
          inputs: ["x", "y", "z"],
          inputKinds: ["number", "number", "number"],
          outputKind: "matrix",
        },
        // ODE integrate (RHS helpers stay on this node — AOT isolation)
        {
          id: "sim",
          type: "expr",
          expr: LORENZ_SIM_EXPR,
          inputs: ["x"],
          inputKinds: ["matrix"],
          params: { t_end: 5, dt: 0.02 },
          outputKind: "matrix",
        },
        {
          id: "final",
          type: "expr",
          expr: "last(x)",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
        // Scalar readouts from final state [t, x, y, z]
        {
          id: "x_final",
          type: "expr",
          expr: "x[0, 1]",
          inputs: ["x"],
          inputKinds: ["matrix"],
        },
        {
          id: "y_final",
          type: "expr",
          expr: "x[0, 2]",
          inputs: ["x"],
          inputKinds: ["matrix"],
        },
        {
          id: "z_final",
          type: "expr",
          expr: "x[0, 3]",
          inputs: ["x"],
          inputKinds: ["matrix"],
        },
      ],
      edges: [
        { from: "x0.out", to: "state0.x" },
        { from: "y0.out", to: "state0.y" },
        { from: "z0.out", to: "state0.z" },
        { from: "state0.out", to: "sim.x" },
        { from: "sim.out", to: "final.x" },
        { from: "final.out", to: "x_final.x" },
        { from: "final.out", to: "y_final.x" },
        { from: "final.out", to: "z_final.x" },
      ],
      outputs: {
        trajectory: "sim.out",
        final_state: "final.out",
        x: "x_final.out",
        y: "y_final.out",
        z: "z_final.out",
      },
    },
  },
  {
    id: "rocket",
    title: "Rocket full (3 stages)",
    description:
      "Multi-node Falcon-9 twin (SI): stage-1 burn → interstage coast → stage-2 burn. " +
      "Named trajectory matrices feed the chart panel; altitude/velocity from final state. " +
      "RHS helpers stay on each ODE node (wasm isolation). ≤3 ports per expr.",
    category: "simulations",
    tags: ["ODE", "multi-node", "rocket", "charts"],
    definition: {
      nodes: [
        // ── ICs (SI) ──────────────────────────────────────────────────────
        { id: "r0", type: "const", value: 6371000 },
        { id: "v0", type: "const", value: 1 },
        { id: "m0", type: "const", value: 551300 },
        { id: "phi0", type: "const", value: 0 },
        { id: "gamma0", type: "const", value: 1.57079632679 },
        // After stage-1 sep: m2+m3+mp = 111500+1700+5000
        { id: "m_coast", type: "const", value: 118200 },

        // y0 = [r; v; m; phi; gamma] via two ≤3-port assignments
        {
          id: "y0_rvm",
          type: "expr",
          expr: "[x; y; z]",
          inputs: ["x", "y", "z"],
          inputKinds: ["number", "number", "number"],
          outputKind: "matrix",
        },
        {
          id: "y0",
          type: "expr",
          expr: "[x[0, 0]; x[1, 0]; x[2, 0]; y; z]",
          inputs: ["x", "y", "z"],
          inputKinds: ["matrix", "number", "number"],
          outputKind: "matrix",
        },

        // ── Stage 1 burn [0, 149.5] s ─────────────────────────────────────
        {
          id: "stage1",
          type: "expr",
          expr: ROCKET_S1_EXPR,
          inputs: ["x"],
          inputKinds: ["matrix"],
          params: { t_end: 149.5, dt: 2 },
          outputKind: "matrix",
        },
        {
          id: "final1",
          type: "expr",
          expr: "last(x)",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
        {
          id: "t1",
          type: "expr",
          expr: "x[0, 0]",
          inputs: ["x"],
          inputKinds: ["matrix"],
        },
        // y_inter = [r; v; m_coast; phi; gamma] from last row [t,r,v,m,phi,gamma]
        {
          id: "y_inter",
          type: "expr",
          expr: "[x[0, 1]; x[0, 2]; y; x[0, 4]; x[0, 5]]",
          inputs: ["x", "y"],
          inputKinds: ["matrix", "number"],
          outputKind: "matrix",
        },

        // ── Interstage coast [t1, t1+10] ──────────────────────────────────
        {
          id: "interstage",
          type: "expr",
          expr: ROCKET_INTER_EXPR,
          inputs: ["x", "y"],
          inputKinds: ["matrix", "number"],
          params: { dt: 2 },
          outputKind: "matrix",
        },
        {
          id: "final_i",
          type: "expr",
          expr: "last(x)",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
        {
          id: "t2",
          type: "expr",
          expr: "x[0, 0]",
          inputs: ["x"],
          inputKinds: ["matrix"],
        },
        {
          id: "y_s2",
          type: "expr",
          expr: "[x[0, 1]; x[0, 2]; x[0, 3]; x[0, 4]; x[0, 5]]",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },

        // ── Stage 2 burn [t2, t2+397] ─────────────────────────────────────
        {
          id: "stage2",
          type: "expr",
          expr: ROCKET_S2_EXPR,
          inputs: ["x", "y"],
          inputKinds: ["matrix", "number"],
          params: { dt: 4 },
          outputKind: "matrix",
        },
        {
          id: "final2",
          type: "expr",
          expr: "last(x)",
          inputs: ["x"],
          inputKinds: ["matrix"],
          outputKind: "matrix",
        },
        {
          id: "r_final",
          type: "expr",
          expr: "x[0, 1]",
          inputs: ["x"],
          inputKinds: ["matrix"],
        },
        {
          id: "v_final",
          type: "expr",
          expr: "x[0, 2]",
          inputs: ["x"],
          inputKinds: ["matrix"],
        },
        {
          id: "alt_km",
          type: "expr",
          expr: "(x - 6371000) / 1000",
          inputs: ["x"],
        },
      ],
      edges: [
        { from: "r0.out", to: "y0_rvm.x" },
        { from: "v0.out", to: "y0_rvm.y" },
        { from: "m0.out", to: "y0_rvm.z" },
        { from: "y0_rvm.out", to: "y0.x" },
        { from: "phi0.out", to: "y0.y" },
        { from: "gamma0.out", to: "y0.z" },
        { from: "y0.out", to: "stage1.x" },
        { from: "stage1.out", to: "final1.x" },
        { from: "final1.out", to: "t1.x" },
        { from: "final1.out", to: "y_inter.x" },
        { from: "m_coast.out", to: "y_inter.y" },
        { from: "y_inter.out", to: "interstage.x" },
        { from: "t1.out", to: "interstage.y" },
        { from: "interstage.out", to: "final_i.x" },
        { from: "final_i.out", to: "t2.x" },
        { from: "final_i.out", to: "y_s2.x" },
        { from: "y_s2.out", to: "stage2.x" },
        { from: "t2.out", to: "stage2.y" },
        { from: "stage2.out", to: "final2.x" },
        { from: "final2.out", to: "r_final.x" },
        { from: "final2.out", to: "v_final.x" },
        { from: "r_final.out", to: "alt_km.x" },
      ],
      outputs: {
        trajectory_s1: "stage1.out",
        trajectory_inter: "interstage.out",
        trajectory_s2: "stage2.out",
        altitude_km: "alt_km.out",
        velocity: "v_final.out",
        final_state: "final2.out",
      },
    },
  },
];

/** Default first-load example (keeps existing tests / lowpass demo). */
export const EXAMPLE_GRAPH: GraphDefinition = GRAPH_EXAMPLES[0]!.definition;

export const EXAMPLE_GRAPH_JSON = JSON.stringify(EXAMPLE_GRAPH, null, 2);

export const DEFAULT_EXAMPLE_ID = GRAPH_EXAMPLES[0]!.id;

export function getGraphExample(id: string): GraphExample | undefined {
  return GRAPH_EXAMPLES.find((e) => e.id === id);
}

export function examplesByCategory(): Record<GraphExampleCategory, GraphExample[]> {
  const out: Record<GraphExampleCategory, GraphExample[]> = {
    basics: [],
    signals: [],
    math: [],
    matrix: [],
    complex: [],
    multi_out: [],
    simulations: [],
  };
  for (const ex of GRAPH_EXAMPLES) {
    out[ex.category].push(ex);
  }
  return out;
}

export const CATEGORY_LABELS: Record<GraphExampleCategory, string> = {
  basics: "Basics",
  signals: "Signals",
  math: "Math",
  matrix: "Matrix",
  complex: "Complex",
  multi_out: "Multi-output",
  simulations: "Simulations",
};
