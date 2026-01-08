import { createStore, produce } from "solid-js/store";
import { createMathZigRuntime, type MathZigRuntime } from "../engine/runtime";
import { ValueTag, type EvalResult, type VarEntry } from "../engine/value_tags";
import { buildPlotSeries } from "../engine/plot_parse";
import { createRocketDemo, type TrajectoryData } from "../engine/demos/rocket";
import { createLorenzDemo, type LorenzParams } from "../engine/demos/lorenz";
import { plainClone } from "../lib/plotly";

export type LogKind = "result" | "error" | "info" | "help" | "success";

export type LogEntry = {
  id: number;
  /** Shared stream order with plots (evaluate → inspect → plot chronology). */
  seq: number;
  expr: string;
  result: string;
  latex?: string | null;
  renderLatex?: boolean;
  type?: string;
  kind: LogKind;
  timestamp: number;
};

export type PlotEntry = {
  id: number;
  seq: number;
  title: string;
  mode: "uplot" | "uplot-grid" | "plotly3d";
  // uPlot single
  x?: number[];
  ys?: number[][];
  labels?: string[];
  // rocket grid
  trajectory?: TrajectoryData;
  // plotly 3d payload (cloned plain arrays)
  plotly?: { data: any[]; layout: any };
  collapsed?: boolean;
  timestamp: number;
};

export type StreamItem =
  | { kind: "log"; seq: number; log: LogEntry }
  | { kind: "plot"; seq: number; plot: PlotEntry };

export type RuntimeStatus = "loading" | "ready" | "error";

type SessionState = {
  status: RuntimeStatus;
  statusMessage: string;
  latexMode: boolean;
  history: string[];
  historyIndex: number;
  logs: LogEntry[];
  plots: PlotEntry[];
  variables: Record<string, VarEntry>;
  sidebarOpen: boolean;
  inspector: { open: boolean; name: string; data: VarEntry | null };
  lorenzVisible: boolean;
  lorenzParams: LorenzParams;
  inputDraft: string;
  /** Set when UI should focus the REPL after a state change. */
  focusInputToken: number;
};

let logSeq = 1;
let plotSeq = 1;
/** Monotonic order across logs and plots for the unified timeline. */
let eventSeq = 1;

const runtime: MathZigRuntime = createMathZigRuntime();

const [state, setState] = createStore<SessionState>({
  status: "loading",
  statusMessage: "Connecting…",
  latexMode: true,
  history: [],
  historyIndex: -1,
  logs: [],
  plots: [],
  variables: {},
  sidebarOpen: false,
  inspector: { open: false, name: "", data: null },
  lorenzVisible: false,
  lorenzParams: {
    sigma: 10,
    beta: 8 / 3,
    rho: 28,
    x0: 1,
    y0: 1,
    z0: 0,
    dt: 0.01,
    steps: 5000,
  },
  inputDraft: "",
  focusInputToken: 0,
});

function nextSeq() {
  return eventSeq++;
}

function addLog(expr: string, res: EvalResult & { type?: string }) {
  const kind: LogKind = res.error
    ? "error"
    : res.type === "help"
      ? "help"
      : res.type === "success"
        ? "success"
        : res.type === "info"
          ? "info"
          : "result";

  // Attach LaTeX for any successful eval log (interactive submit *and* demos like rocket).
  // Rocket previously called addLog(expr, evaluate(expr)) and skipped toLaTeX entirely.
  let latex = res.latex ?? null;
  let renderLatex = Boolean(res.renderLatex);
  if (kind === "result" && state.latexMode && expr.trim()) {
    renderLatex = true;
    if (!latex) {
      try {
        latex = runtime.toLaTeX(expr);
      } catch (e) {
        console.warn("LaTeX generation failed:", e);
        latex = null;
      }
    }
    // Never surface engine placeholders like \text{unsupported:.dynamic_access}
    if (latex && latex.includes("unsupported:")) {
      latex = null;
      renderLatex = false;
    }
  }

  setState(
    "logs",
    produce((logs) => {
      logs.push({
        id: logSeq++,
        seq: nextSeq(),
        expr,
        result: res.error || res.value || "",
        latex,
        renderLatex,
        type: res.type,
        kind,
        timestamp: Date.now(),
      });
    }),
  );
}

function pushPlot(entry: Omit<PlotEntry, "id" | "seq" | "timestamp" | "collapsed"> & { collapsed?: boolean }) {
  setState(
    "plots",
    produce((plots) => {
      plots.push({
        ...entry,
        id: plotSeq++,
        seq: nextSeq(),
        timestamp: Date.now(),
        collapsed: entry.collapsed ?? false,
      });
    }),
  );
}

function setVar(name: string, data: VarEntry) {
  setState("variables", name, data);
}

function evalAndAssign(expr: string): EvalResult {
  const res = runtime.evaluate(expr);
  if (res.assignName && res.tag !== ValueTag.err) {
    setVar(res.assignName, {
      value: res.value ?? "",
      type: res.type ?? "unknown",
      tag: res.tag ?? ValueTag.undefined,
      number: res.number,
      ptr: res.ptr,
      re: res.re,
      im: res.im,
    });
  }
  return res;
}

const rocket = createRocketDemo({
  evaluate: evalAndAssign,
  addLog,
  getVariables: () => state.variables,
  setVar,
  ValueTag,
  getWasm: () => runtime.getWasm(),
  readF64: runtime.readF64,
  readU32: runtime.readU32,
});

const lorenz = createLorenzDemo({
  eval: evalAndAssign,
  compile: runtime.compile,
  execute: runtime.execute,
  setVariable: runtime.setVariable,
  getMatrixView: runtime.getMatrixView,
  onError: (message) => addLog("lorenz", { error: message }),
  onPlot3d: (data, layout) => {
    // Always store plain JSON — Plotly mutates traces and breaks on Solid proxies
    const payload = plainClone({ data, layout });
    const idx = state.plots.findIndex((p) => p.mode === "plotly3d" && p.title.startsWith("Lorenz"));
    if (idx >= 0) {
      setState("plots", idx, "plotly", payload);
    } else {
      pushPlot({
        title: "Lorenz Attractor (RK4)",
        mode: "plotly3d",
        plotly: payload,
      });
    }
  },
});

/** Chronological stream: logs and plots interleaved by seq. */
export function buildStream(logs: LogEntry[], plots: PlotEntry[]): StreamItem[] {
  const items: StreamItem[] = [
    ...logs.map((log) => ({ kind: "log" as const, seq: log.seq, log })),
    ...plots.map((plot) => ({ kind: "plot" as const, seq: plot.seq, plot })),
  ];
  items.sort((a, b) => a.seq - b.seq || a.kind.localeCompare(b.kind));
  return items;
}

export const session = {
  state,
  runtime,

  async boot() {
    setState({ status: "loading", statusMessage: "Initializing WebAssembly…" });
    try {
      await runtime.init(["/mathzig_wasm.wasm", "./mathzig_wasm.wasm"]);
      setState({ status: "ready", statusMessage: "Ready" });
      addLog("", {
        value: "MathZig Engine Ready. Type help for commands.",
        type: "info",
      });
      session.requestInputFocus();
    } catch (e: any) {
      setState({ status: "error", statusMessage: e?.message || "Failed to load WASM" });
    }
  },

  requestInputFocus() {
    setState("focusInputToken", state.focusInputToken + 1);
  },

  setInputDraft(v: string) {
    setState("inputDraft", v);
  },

  setLatexMode(on: boolean) {
    setState("latexMode", on);
    setState(
      "logs",
      produce((logs) => {
        for (const log of logs) log.renderLatex = on;
      }),
    );
  },

  toggleLatex() {
    session.setLatexMode(!state.latexMode);
  },

  setSidebarOpen(open: boolean) {
    setState("sidebarOpen", open);
  },

  openInspector(name: string, data: VarEntry) {
    setState("inspector", { open: true, name, data });
  },

  closeInspector() {
    setState("inspector", { open: false, name: "", data: null });
  },

  clearOutput() {
    setState({ logs: [], plots: [] });
  },

  clearPlots() {
    setState("plots", []);
  },

  togglePlotCollapsed(id: number) {
    const idx = state.plots.findIndex((p) => p.id === id);
    if (idx < 0) return;
    setState("plots", idx, "collapsed", !state.plots[idx]!.collapsed);
  },

  removePlot(id: number) {
    setState(
      "plots",
      produce((plots) => {
        const i = plots.findIndex((p) => p.id === id);
        if (i >= 0) plots.splice(i, 1);
      }),
    );
  },

  historyPrev() {
    if (state.history.length === 0) return;
    const idx = state.historyIndex <= 0 ? 0 : state.historyIndex - 1;
    setState({ historyIndex: idx, inputDraft: state.history[idx] ?? "" });
  },

  historyNext() {
    if (state.historyIndex < 0) return;
    if (state.historyIndex >= state.history.length - 1) {
      setState({ historyIndex: state.history.length, inputDraft: "" });
      return;
    }
    const idx = state.historyIndex + 1;
    setState({ historyIndex: idx, inputDraft: state.history[idx] ?? "" });
  },

  insertSnippet(expr: string) {
    setState("inputDraft", expr);
    session.requestInputFocus();
  },

  setLorenzParam(id: keyof LorenzParams, value: number) {
    setState("lorenzParams", id, value);
    if (state.lorenzVisible) lorenz.run(state.lorenzParams);
  },

  fullReset() {
    try {
      runtime.reset();
      rocket.reset();
      lorenz.reset();
      setState({
        logs: [],
        plots: [],
        variables: {},
        history: [],
        historyIndex: -1,
        inputDraft: "",
        lorenzVisible: false,
        inspector: { open: false, name: "", data: null },
      });
      addLog("reset", { value: "Runtime reset. VM reinitialized.", type: "info" });
      session.requestInputFocus();
    } catch (e: any) {
      addLog("reset", { error: e?.message || "Failed to reset VM" });
    }
  },

  /** Re-submit a previous log expression into the REPL. */
  rerunExpr(expr: string) {
    if (!expr.trim() || state.status !== "ready") return;
    session.submit(expr);
  },

  submit(raw?: string) {
    const val = (raw ?? state.inputDraft).trim();
    if (!val) return;

    setState(
      produce((s) => {
        s.history.push(val);
        s.historyIndex = s.history.length;
        s.inputDraft = "";
      }),
    );

    if (val === "clear" || val === "cls") {
      session.clearOutput();
      return;
    }

    if (val === "help") {
      addLog(val, {
        value: `Commands
  help, clear, reset, sample, load, rocket, lorenz, version

Syntax
  x = 5 + 2i
  m = [1,2; 3,4]
  plot(x)              plot a variable
  plot(m, 0, 1)        matrix columns
  plot(x, y)           arrays or series

Simulations
  rocket               run trajectory, then plot
  plot                 show rocket trajectory
  lorenz               attractor + sidebar sliders

Data
  sample               load demo series demo_data
  load                 import CSV (time,value)

Graph workbench: open the Graph tab (stub).`,
        type: "help",
      });
      return;
    }

    if (val === "version()" || val === "version") {
      const v = runtime.version();
      if (!v) addLog(val, { error: "Version unavailable" });
      else addLog(val, { value: `"${v}"`, type: "string" });
      return;
    }

    if (val === "reset") {
      session.fullReset();
      return;
    }

    if (val === "rocket") {
      rocket.runRocketSimulation();
      return;
    }

    if (val === "lorenz") {
      setState("lorenzVisible", true);
      // Open drawer on narrow viewports so parameter sliders are visible
      if (typeof window !== "undefined" && window.matchMedia("(max-width: 767px)").matches) {
        setState("sidebarOpen", true);
      }
      try {
        lorenz.run(state.lorenzParams);
        addLog(val, {
          value: "Lorenz Attractor simulation started. Use sidebar sliders to interact.",
          type: "info",
        });
      } catch (e: any) {
        addLog(val, { error: e?.message || "Lorenz simulation failed" });
      }
      return;
    }

    if (val === "plot" || val === "trajectory") {
      const traj = rocket.getTrajectory();
      if (!traj) {
        addLog("plot", { error: 'No trajectory data. Run "rocket" first.' });
        return;
      }
      // Log first so the chart sits under the command that produced it.
      addLog("plot", { value: "Trajectory charts displayed", type: "success" });
      pushPlot({
        title: "Rocket Trajectory",
        mode: "uplot-grid",
        trajectory: traj,
      });
      return;
    }

    const plotMatch = val.match(/^plot\((.+)\)$/);
    if (plotMatch) {
      const built = buildPlotSeries(
        plotMatch[1]!.trim(),
        state.variables,
        (ptr) => runtime.readSeriesData(ptr),
        (ptr) => runtime.readMatrixData(ptr),
      );
      if ("error" in built) {
        addLog("plot", { error: built.error });
        return;
      }
      addLog(val, { value: built.title, type: "success" });
      pushPlot({
        title: built.title,
        mode: "uplot",
        x: built.x,
        ys: built.ys,
        labels: built.labels,
      });
      return;
    }

    if (val === "sample") {
      const ts: number[] = [];
      const vs: number[] = [];
      for (let i = 0; i < 50; i++) {
        ts.push(i);
        vs.push(Math.sin(i * 0.2) * 10 + Math.random());
      }
      const r = runtime.createSeries(ts, vs);
      if (!r) {
        addLog(val, { error: "Failed to allocate series" });
        return;
      }
      const nm = "demo_data";
      if (!runtime.setSeries(nm, r)) {
        addLog(val, { error: "Failed to bind demo series" });
        return;
      }
      setVar(nm, {
        value: "[Series: 50]",
        type: "series",
        tag: ValueTag.series,
        ptr: r,
        seriesData: { len: 50, timestamps: ts.slice(0, 10), values: vs.slice(0, 10) },
      });
      addLog(val, { value: 'Loaded demo series "demo_data"', type: "info" });
      return;
    }

    if (val === "load") {
      const fi = document.createElement("input");
      fi.type = "file";
      fi.accept = ".csv";
      fi.onchange = async () => {
        const f = fi.files?.[0];
        if (!f) return;
        const txt = await f.text();
        const nm = f.name.split(".")[0]!.replace(/\W/g, "_");
        const r = runtime.loadCSVAsSeries(txt, nm);
        if (r.success && r.varData) {
          setVar(nm, r.varData);
          addLog(`load ${f.name}`, { value: `Loaded ${nm}`, type: "info" });
        } else {
          addLog(`load ${f.name}`, { error: ("error" in r && r.error) || "Load failed" });
        }
      };
      fi.click();
      return;
    }

    // LaTeX is attached inside addLog when latexMode is on (shared with rocket/demos).
    addLog(val, evalAndAssign(val));
  },
};
