// @ts-check
/**
 * Browser graph demo controller (no bun-only APIs).
 *
 * Expects the shared GraphRunner bundle (`graph_bundle.js` from `src/ts/graph`)
 * plus an injected WasmCompiler (and optional env/host) — same injection model
 * as bun tests. Compile is typically provided by the demo server's `/api/aot_compile`.
 *
 * Param slider range heuristic (documented):
 *   - default in [0, 1]  → range 0..1, step 0.01
 *   - default in (1, 10] → range 0..default*2, step 0.1
 *   - otherwise          → range default±max(10, |default|*10), step adaptive
 */

/**
 * @typedef {import('./graph_entry').GraphDefinition} GraphDefinition
 * @typedef {import('./graph_entry').GraphRunner} GraphRunner
 * @typedef {import('./graph_entry').WasmCompiler} WasmCompiler
 * @typedef {import('./graph_entry').GraphValue} GraphValue
 */

/**
 * @param {{
 *   GraphRunner: typeof import('./graph_entry').GraphRunner,
 *   createDefaultScalarWasmImports: () => unknown,
 *   compiler: WasmCompiler,
 *   env?: unknown,
 *   host?: unknown,
 * }} deps
 */
export function createGraphController(deps) {
  const { GraphRunner, createDefaultScalarWasmImports, compiler } = deps;
  const env = deps.env ?? createDefaultScalarWasmImports();
  const host = deps.host;

  /** @type {GraphRunner | null} */
  let runner = null;
  /** @type {GraphDefinition | null} */
  let definition = null;
  /** @type {Record<string, number>} */
  let inputValues = {};
  /** @type {number | null} */
  let autoTimer = null;
  let autoIntervalMs = 100;

  /**
   * @param {GraphDefinition} def
   * @returns {Promise<{ ok: true, params: Array<{nodeId:string,name:string,value:number}>, inputs: string[] } | { ok: false, error: string }>}
   */
  async function load(def) {
    try {
      if (runner) {
        runner.dispose();
        runner = null;
      }
      runner = await GraphRunner.load(def, { compiler, env, host });
      definition = def;
      // Seed input defaults to 0 for every input node.
      inputValues = {};
      const nodes = Array.isArray(def.nodes)
        ? def.nodes
        : Object.entries(def.nodes || {}).map(([id, n]) => ({ id, ...n }));
      for (const n of nodes) {
        if (n.type === "input") {
          const name = n.name || n.id;
          if (inputValues[name] === undefined) inputValues[name] = 0;
        }
      }
      return {
        ok: true,
        params: runner.listParams(),
        inputs: Object.keys(inputValues),
      };
    } catch (e) {
      runner = null;
      definition = null;
      return { ok: false, error: String(e?.message ?? e) };
    }
  }

  /**
   * @param {string} text
   */
  async function loadJson(text) {
    let def;
    try {
      def = JSON.parse(text);
    } catch (e) {
      return { ok: false, error: `JSON parse error: ${e?.message ?? e}` };
    }
    return load(def);
  }

  /**
   * @param {string} nodeId
   * @param {string} name
   * @param {number} value
   */
  function setParam(nodeId, name, value) {
    if (!runner) throw new Error("No graph loaded.");
    runner.setParam(nodeId, name, value);
  }

  /**
   * @param {string} name
   * @param {number} value
   */
  function setInput(name, value) {
    inputValues[name] = value;
  }

  /**
   * @returns {Record<string, GraphValue>}
   */
  function tick() {
    if (!runner) throw new Error("No graph loaded.");
    return runner.run({ ...inputValues });
  }

  /**
   * @param {boolean} enabled
   * @param {(outputs: Record<string, GraphValue>, err?: string) => void} onTick
   * @param {number} [intervalMs]
   */
  function setAutoTick(enabled, onTick, intervalMs) {
    if (intervalMs != null && intervalMs > 0) autoIntervalMs = intervalMs;
    if (autoTimer != null) {
      clearInterval(autoTimer);
      autoTimer = null;
    }
    if (!enabled) return;
    autoTimer = setInterval(() => {
      try {
        const out = tick();
        onTick(out);
      } catch (e) {
        onTick({}, String(e?.message ?? e));
      }
    }, autoIntervalMs);
  }

  /**
   * @param {string} nodeId
   * @param {string} expr
   */
  async function reload(nodeId, expr) {
    if (!runner) throw new Error("No graph loaded.");
    await runner.reload(nodeId, expr);
  }

  function dispose() {
    setAutoTick(false, () => {});
    if (runner) {
      runner.dispose();
      runner = null;
    }
    definition = null;
  }

  function getRunner() {
    return runner;
  }

  function getDefinition() {
    return definition;
  }

  function getInputValues() {
    return { ...inputValues };
  }

  return {
    load,
    loadJson,
    setParam,
    setInput,
    tick,
    setAutoTick,
    reload,
    dispose,
    getRunner,
    getDefinition,
    getInputValues,
    listParams: () => (runner ? runner.listParams() : []),
  };
}

/**
 * Slider range heuristic for a param default value.
 * @param {number} defaultValue
 * @returns {{ min: number, max: number, step: number }}
 */
export function paramSliderRange(defaultValue) {
  const d = Number.isFinite(defaultValue) ? defaultValue : 0;
  if (d >= 0 && d <= 1) {
    return { min: 0, max: 1, step: 0.01 };
  }
  if (d > 1 && d <= 10) {
    return { min: 0, max: d * 2, step: 0.1 };
  }
  const span = Math.max(10, Math.abs(d) * 10);
  const min = d - span;
  const max = d + span;
  const step = span > 100 ? 1 : span > 10 ? 0.1 : 0.01;
  return { min, max, step };
}

/**
 * Render a GraphValue for the demo panel.
 * @param {GraphValue} value
 * @returns {{ kind: string, html: string, text: string }}
 */
export function formatGraphValue(value) {
  if (typeof value === "number") {
    const text = Number.isFinite(value) ? formatNumber(value) : String(value);
    return { kind: "number", html: `<span class="gv-num">${escapeHtml(text)}</span>`, text };
  }
  if (typeof value === "boolean") {
    return { kind: "boolean", html: `<span class="gv-bool">${value}</span>`, text: String(value) };
  }
  if (typeof value === "string") {
    return {
      kind: "string",
      html: `<span class="gv-str">${escapeHtml(JSON.stringify(value))}</span>`,
      text: value,
    };
  }
  if (value && typeof value === "object") {
    // Matrix: { rows, cols, data }
    if ("rows" in value && "cols" in value && "data" in value) {
      const rows = /** @type {number} */ (value.rows);
      const cols = /** @type {number} */ (value.cols);
      const data = /** @type {ArrayLike<number>} */ (value.data);
      let html = `<table class="gv-matrix" data-rows="${rows}" data-cols="${cols}"><tbody>`;
      for (let r = 0; r < rows; r++) {
        html += "<tr>";
        for (let c = 0; c < cols; c++) {
          const n = Number(data[r * cols + c]);
          html += `<td>${escapeHtml(formatNumber(n))}</td>`;
        }
        html += "</tr>";
      }
      html += "</tbody></table>";
      return { kind: "matrix", html, text: `matrix ${rows}×${cols}` };
    }
    // Series: length + last value
    if ("timestamps" in value || "values" in value || "id" in value) {
      const vals = Array.isArray(value.values) ? value.values : [];
      const len =
        typeof value.len === "function"
          ? value.len()
          : vals.length || (Array.isArray(value.timestamps) ? value.timestamps.length : 0);
      const last = vals.length > 0 ? vals[vals.length - 1] : NaN;
      const text = `series len=${len} last=${formatNumber(Number(last))}`;
      const html =
        `<span class="gv-series">len=<b>${len}</b> last=<b>${escapeHtml(formatNumber(Number(last)))}</b></span>`;
      return { kind: "series", html, text };
    }
    // Complex
    if ("re" in value && "im" in value) {
      const text = `${formatNumber(Number(value.re))}${Number(value.im) >= 0 ? "+" : ""}${formatNumber(Number(value.im))}i`;
      return { kind: "complex", html: `<span class="gv-complex">${escapeHtml(text)}</span>`, text };
    }
  }
  const text = String(value);
  return { kind: "unknown", html: escapeHtml(text), text };
}

/** @param {number} n */
function formatNumber(n) {
  if (!Number.isFinite(n)) return String(n);
  if (Math.abs(n) >= 1e6 || (Math.abs(n) > 0 && Math.abs(n) < 1e-4)) return n.toExponential(4);
  const s = n.toFixed(6);
  return s.replace(/\.?0+$/, "") || "0";
}

/** @param {string} s */
function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Example graph: source → lowpass → gain (scalar). */
export const EXAMPLE_GRAPH = {
  nodes: [
    { id: "source", type: "input" },
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
};
