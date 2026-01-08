import { plotlyVelocityScale, readThemeTokens } from "../theme";
import type { EvalResult } from "../value_tags";

export type LorenzParams = {
  sigma: number;
  beta: number;
  rho: number;
  x0: number;
  y0: number;
  z0: number;
  dt: number;
  steps: number;
};

type LorenzDeps = {
  eval: (expr: string) => EvalResult;
  compile: (expr: string) => number;
  execute: (ptr: number) => EvalResult;
  setVariable: (name: string, val: number) => void;
  getMatrixView: (ptr: number) => { rows: number; cols: number; stride: number; data: Float64Array } | null;
  onPlot3d: (data: any[], layout: any) => void;
  onError?: (message: string) => void;
};

export function createLorenzDemo(deps: LorenzDeps) {
  let isFuncDefined = false;
  let runSimPtr = 0;
  let pending = false;
  let latestParams: LorenzParams | null = null;

  const plotBuffers = {
    x: new Float64Array(0),
    y: new Float64Array(0),
    z: new Float64Array(0),
    colors: new Float64Array(0),
  };

  function schedule(fn: () => void) {
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(fn);
    else setTimeout(fn, 0);
  }

  function run(params: LorenzParams) {
    latestParams = params;
    if (pending) return;
    pending = true;
    schedule(() => {
      pending = false;
      if (latestParams) runNow(latestParams);
    });
  }

  function runNow(p: LorenzParams) {
    if (!isFuncDefined) {
      const initExpr = `
                lorenz_sim(sigma, b, r, x0, y0, z0, dt, steps) = {
                    f(t, u) = [sigma * (u[1] - u[0]); u[0] * (r - u[2]) - u[1]; u[0] * u[1] - b * u[2]];
                    ode_solve("f", [x0; y0; z0], [0, dt * steps], dt)
                }
            `;
      const res = deps.eval(initExpr);
      if (res.error) {
        console.error("Failed to compile lorenz_sim:", res.error);
        deps.onError?.(res.error);
        return;
      }
      runSimPtr = deps.compile("lorenz_sim(sigma_v, beta_v, rho_v, x0_v, y0_v, z0_v, dt_v, steps_v)");
      if (!runSimPtr) {
        const msg = "Failed to compile lorenz_sim call expression";
        console.error(msg);
        deps.onError?.(msg);
        return;
      }
      isFuncDefined = true;
    }

    deps.setVariable("sigma_v", p.sigma);
    deps.setVariable("beta_v", p.beta);
    deps.setVariable("rho_v", p.rho);
    deps.setVariable("x0_v", p.x0);
    deps.setVariable("y0_v", p.y0);
    deps.setVariable("z0_v", p.z0);
    deps.setVariable("dt_v", p.dt);
    deps.setVariable("steps_v", p.steps);

    const result = deps.execute(runSimPtr);
    if (result.error) {
      console.error("ODE Solve error:", result.error);
      deps.onError?.(result.error);
      return;
    }
    if (!result.ptr) {
      deps.onError?.("Lorenz ODE returned no matrix pointer");
      return;
    }

    const sol = deps.getMatrixView(result.ptr);
    if (!sol) {
      console.error("Failed to read matrix view from pointer:", result.ptr);
      deps.onError?.("Failed to read Lorenz solution matrix");
      return;
    }

    const { rows, stride, data } = sol;
    if (plotBuffers.x.length < rows) {
      plotBuffers.x = new Float64Array(rows);
      plotBuffers.y = new Float64Array(rows);
      plotBuffers.z = new Float64Array(rows);
      plotBuffers.colors = new Float64Array(rows);
    }

    const { x, y, z, colors } = plotBuffers;
    for (let i = 0; i < rows; i++) {
      const offset = i * stride;
      x[i] = data[offset + 1]!;
      y[i] = data[offset + 2]!;
      z[i] = data[offset + 3]!;
      if (i === 0) {
        colors[i] = 0;
      } else {
        const prev = (i - 1) * stride;
        const dx = x[i]! - data[prev + 1]!;
        const dy = y[i]! - data[prev + 2]!;
        const dz = z[i]! - data[prev + 3]!;
        colors[i] = Math.sqrt(dx * dx + dy * dy + dz * dz);
      }
    }

    // Copy into plain arrays (Plotly 3 + Solid store should not share WASM/typed views)
    const xs = Array.from(x.subarray(0, rows));
    const ys = Array.from(y.subarray(0, rows));
    const zs = Array.from(z.subarray(0, rows));
    const cs = Array.from(colors.subarray(0, rows));

    const theme = readThemeTokens();
    // Prefer sRGB strings for Plotly colorscales (oklch from CSS may fail in older plotly)
    const scale = plotlyVelocityScale(theme).map(([t, c]) => [t, cssColorToPlotly(c)] as [number, string]);

    const trace = {
      x: xs,
      y: ys,
      z: zs,
      type: "scatter3d" as const,
      mode: "lines" as const,
      line: {
        width: 2,
        color: cs,
        colorscale: scale,
        reversescale: true,
      },
    };

    // Keep layout plain JSON (no functions/proxies). Axis titles as objects for Plotly 3.
    const axisStyle = {
      title: { text: "" as string },
      gridcolor: cssColorToPlotly(theme.borderSubtle),
      color: cssColorToPlotly(theme.fgSecondary),
      showbackground: false,
      zeroline: false,
    };
    const layout = {
      title: { text: "Lorenz Attractor (RK4 Optimized)" },
      scene: {
        xaxis: { ...axisStyle, title: { text: "X" } },
        yaxis: { ...axisStyle, title: { text: "Y" } },
        zaxis: { ...axisStyle, title: { text: "Z" } },
        bgcolor: cssColorToPlotly(theme.bgApp),
      },
      margin: { l: 0, r: 0, b: 0, t: 36 },
      font: { color: cssColorToPlotly(theme.fgPrimary) },
      paper_bgcolor: cssColorToPlotly(theme.bgApp),
      plot_bgcolor: cssColorToPlotly(theme.bgApp),
      uirevision: "lorenz",
    };

    deps.onPlot3d([trace], layout);
  }

  function reset() {
    isFuncDefined = false;
    runSimPtr = 0;
  }

  /** Convert CSS color (rgb/rgba/oklch/hex) to something Plotly accepts. */
  function cssColorToPlotly(color: string): string {
    if (!color || color === "transparent") return "#1a1b1f";
    if (color.startsWith("#") || color.startsWith("rgb")) return color;
    // oklch / other: sample via canvas if available
    if (typeof document !== "undefined") {
      const c = document.createElement("canvas");
      c.width = c.height = 1;
      const ctx = c.getContext("2d");
      if (ctx) {
        ctx.fillStyle = "#000";
        ctx.fillStyle = color;
        ctx.fillRect(0, 0, 1, 1);
        const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data;
        return `rgb(${r}, ${g}, ${b})`;
      }
    }
    return color;
  }

  return { run, reset };
}
