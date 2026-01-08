import {
  For,
  Index,
  Show,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
  untrack,
} from "solid-js";
import {
  FusedGraphRunner,
  GraphRunner,
  createDefaultScalarWasmImports,
  type GraphLoadProgress,
  type GraphNodeTiming,
  type GraphRunOutputs,
  type GraphValue,
} from "@mathzig/graph";
import {
  GraphCanvas,
  type GraphCanvasApi,
} from "../components/graph/GraphCanvas";
import { GraphInspector } from "../components/graph/GraphInspector";
import { GraphPalette } from "../components/graph/GraphPalette";
import {
  GraphCommandMenu,
  addNodeCommands,
  type CommandItem,
} from "../components/graph/GraphCommandMenu";
import { GraphOutline, GraphProblems } from "../components/graph/GraphProblems";
import { createBrowserAotCompiler } from "../engine/graph/compiler";
import {
  exportDocument,
  exportRunnerJson,
  parseImport,
  toFlow,
  toRunner,
} from "../engine/graph/editor_adapter";
import {
  CATEGORY_LABELS,
  DEFAULT_EXAMPLE_ID,
  EXAMPLE_GRAPH,
  GRAPH_EXAMPLES,
  getGraphExample,
  type GraphExample,
} from "../engine/graph/example";
import { formatGraphValue, paramSliderRange, type FormattedGraphValue } from "../engine/graph/format";
import { trajectoryFromGraphOutputs } from "../engine/graph/trajectory";
import { DocumentHistory } from "../engine/graph/history";
import { PlotHost } from "../components/plot/PlotHost";
import type { PlotEntry } from "../state/session";
import type { TrajectoryData } from "../engine/demos/rocket";
import {
  addNodeToDocument,
  alignSelectedNodes,
  applyAutoLayout,
  distributeSelectedNodes,
  type NodeKind,
} from "../engine/graph/node_draft";
import type { EditorDocument, FlowEdge, FlowNode, MzNodeData } from "../engine/graph/editor_types";
import {
  classifyGraphError,
  moduleSummary,
  validateEditorDocument,
} from "../engine/graph/validate_editor";
import {
  DUAL_MODEL_COPY,
  base64ToUint8Array,
  checkFuseExportSupport,
  compileModeLabel,
  downloadOptimizedExportPair,
  exportSummaryFromMeta,
  formatFusePlanJson,
  requestOptimizedExport,
  type GraphCompileMode,
} from "../engine/graph/export_optimized";

/** UI param row; `key` is what setParam uses (nodeId+name for modules, flat name for fused). */
type ParamEntry = { nodeId: string; name: string; value: number; key: string };
type InputEntry = { name: string; value: number };
type OutputEntry = {
  name: string;
  formatted: FormattedGraphValue;
  /** Recent scalar samples for sparkline (graph outputs history). */
  history: number[];
};

/** Max rows shown in the compact matrix table (full data still used for charts). */
const MATRIX_PREVIEW_ROWS = 6;
type Phase = "draft" | "compiling" | "ready" | "error" | "exporting";
type RunMode = "manual" | "continuous" | "onChange";

const OUTPUT_HISTORY_CAP = 48;

type ActiveRuntime =
  | { kind: "modules"; runner: GraphRunner }
  | { kind: "fused"; runner: FusedGraphRunner };

function initialDoc(): EditorDocument {
  return parseImport(EXAMPLE_GRAPH);
}

function formatSparkNumber(n: number): string {
  if (!Number.isFinite(n)) return String(n);
  if (Math.abs(n) >= 1e4 || (Math.abs(n) > 0 && Math.abs(n) < 1e-3)) return n.toExponential(2);
  return n.toFixed(3).replace(/\.?0+$/, "");
}

/** Tiny SVG sparkline for scalar graph-output history (continuous / multi-run). */
function OutputSparkline(props: { values: number[] }) {
  const w = 160;
  const h = 28;
  const path = () => {
    const vals = props.values.filter((v) => Number.isFinite(v));
    if (vals.length < 2) return "";
    let min = vals[0]!;
    let max = vals[0]!;
    for (const v of vals) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    const span = max - min || 1;
    return vals
      .map((v, i) => {
        const x = (i / (vals.length - 1)) * (w - 2) + 1;
        const y = h - 2 - ((v - min) / span) * (h - 4);
        return `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`;
      })
      .join(" ");
  };
  return (
    <svg
      width={w}
      height={h}
      viewBox={`0 0 ${w} ${h}`}
      class="block w-full max-w-[12rem] rounded border border-line bg-inset"
      aria-hidden="true"
    >
      <path d={path()} fill="none" stroke="currentColor" stroke-width="1.25" class="text-keyword" />
    </svg>
  );
}

/**
 * Graph editor: Design → Validate → Compile → Run.
 */
export function GraphPage() {
  const history = new DocumentHistory(initialDoc());
  const [doc, setDoc] = createSignal<EditorDocument>(history.present);
  const [canvasKey, setCanvasKey] = createSignal(1);
  const [focusNodeId, setFocusNodeId] = createSignal<string | null>(null);
  const [selected, setSelected] = createSignal<FlowNode | null>(null);
  const [selectedEdge, setSelectedEdge] = createSignal<FlowEdge | null>(null);
  const [showSource, setShowSource] = createSignal(false);
  const [jsonText, setJsonText] = createSignal(exportDocument(initialDoc()));
  const [error, setError] = createSignal<string | null>(null);
  const [phase, setPhase] = createSignal<Phase>("draft");
  const [statusDetail, setStatusDetail] = createSignal("Not compiled");
  const [params, setParams] = createSignal<ParamEntry[]>([]);
  const [inputs, setInputs] = createSignal<InputEntry[]>([]);
  const [outputs, setOutputs] = createSignal<OutputEntry[]>([]);
  /** Rocket trajectory series extracted from ODE matrix outputs (for charts). */
  const [trajectory, setTrajectory] = createSignal<TrajectoryData | null>(null);
  const [runMode, setRunMode] = createSignal<RunMode>("manual");
  const autoMs = 100;
  const [busy, setBusy] = createSignal(false);
  const [compiled, setCompiled] = createSignal(false);
  const [dirty, setDirty] = createSignal(true);
  const [moduleCount, setModuleCount] = createSignal(0);
  const [lastRunMs, setLastRunMs] = createSignal<number | null>(null);
  const [runCount, setRunCount] = createSignal(0);
  const [outputsStale, setOutputsStale] = createSignal(false);
  const [nodeTimings, setNodeTimings] = createSignal<Record<string, number>>({});
  const [cmdOpen, setCmdOpen] = createSignal(false);
  const [histTick, setHistTick] = createSignal(0);
  const [exportSummary, setExportSummary] = createSignal<string | null>(null);
  const [exporting, setExporting] = createSignal(false);
  /** Selected before Compile: multi-module vs single fused module. */
  const [compileMode, setCompileMode] = createSignal<GraphCompileMode>("modules");
  /** Mode that was actually loaded (may lag compileMode until recompile). */
  const [activeMode, setActiveMode] = createSignal<GraphCompileMode | null>(null);
  const [exampleId, setExampleId] = createSignal(DEFAULT_EXAMPLE_ID);

  let runtime: ActiveRuntime | null = null;
  let inputValues: Record<string, number> = {};
  let autoTimer: ReturnType<typeof setInterval> | null = null;
  let canvasApi: GraphCanvasApi | null = null;
  const compiler = createBrowserAotCompiler();

  const validation = createMemo(() => validateEditorDocument(doc()));
  const outlineNodes = createMemo(() => toFlow(doc()).nodes);
  const currentExample = createMemo(() => getGraphExample(exampleId()));

  onMount(() => {
    const onKey = (e: KeyboardEvent) => {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setCmdOpen((v) => !v);
        return;
      }
      if (meta && e.key.toLowerCase() === "z" && !e.shiftKey) {
        e.preventDefault();
        undo();
        return;
      }
      if (meta && (e.key.toLowerCase() === "y" || (e.key.toLowerCase() === "z" && e.shiftKey))) {
        e.preventDefault();
        redo();
      }
    };
    window.addEventListener("keydown", onKey);
    onCleanup(() => window.removeEventListener("keydown", onKey));
  });

  onCleanup(() => {
    stopAuto();
    disposeRuntime();
    canvasApi = null;
  });

  function disposeRuntime() {
    runtime?.runner.dispose();
    runtime = null;
    setActiveMode(null);
  }

  function bumpHistory() {
    setHistTick((t) => t + 1);
  }

  function stopAuto() {
    if (autoTimer != null) {
      clearInterval(autoTimer);
      autoTimer = null;
    }
    if (runMode() === "continuous") setRunMode("manual");
  }

  function applyDoc(
    next: EditorDocument,
    opts?: { remount?: boolean; history?: boolean; label?: string; focusId?: string | null },
  ) {
    if (opts?.history !== false) {
      history.commit(next, opts?.label ?? "edit");
    } else {
      history.replacePresent(next, opts?.label);
    }
    setDoc(history.present);
    setJsonText(exportDocument(history.present));
    markStructuralChange();
    bumpHistory();
    if (opts?.focusId !== undefined) {
      setFocusNodeId(opts.focusId);
    } else if (opts?.remount) {
      // Genuine document replacement — don't re-focus a stale node id.
      setFocusNodeId(null);
    }
    if (opts?.remount) {
      setSelected(null);
      setSelectedEdge(null);
      setCanvasKey((k) => k + 1);
    }
  }

  function markStructuralChange() {
    setDirty(true);
    setExportSummary(null);
    if (compiled() || outputs().length > 0) setOutputsStale(true);
  }

  function onDocumentChange(
    next: EditorDocument,
    meta?: { label?: string; history?: boolean },
  ) {
    applyDoc(next, {
      remount: false,
      history: meta?.history !== false,
      label: meta?.label,
    });
  }

  function undo() {
    const prev = history.undo();
    if (!prev) return;
    setDoc(prev);
    setJsonText(exportDocument(prev));
    markStructuralChange();
    setSelected(null);
    setSelectedEdge(null);
    setFocusNodeId(null);
    canvasApi?.selectNodeId(null);
    bumpHistory();
  }

  function redo() {
    const next = history.redo();
    if (!next) return;
    setDoc(next);
    setJsonText(exportDocument(next));
    markStructuralChange();
    setSelected(null);
    setSelectedEdge(null);
    setFocusNodeId(null);
    canvasApi?.selectNodeId(null);
    bumpHistory();
  }

  function seedInputsFromDoc() {
    const def = toRunner(doc());
    inputValues = {};
    for (const n of def.nodes) {
      if (n.type === "input") {
        const name = n.name || n.id;
        inputValues[name] = inputValues[name] ?? 0;
      }
    }
    setInputs(Object.entries(inputValues).map(([name, value]) => ({ name, value })));
  }

  function paramsFromModules(runner: GraphRunner): ParamEntry[] {
    return runner.listParams().map((p) => ({
      nodeId: p.nodeId,
      name: p.name,
      value: p.value,
      key: `${p.nodeId}.${p.name}`,
    }));
  }

  function paramsFromFused(runner: FusedGraphRunner): ParamEntry[] {
    return runner.listParams().map((p) => {
      const dot = p.name.indexOf(".");
      if (dot > 0) {
        return {
          nodeId: p.name.slice(0, dot),
          name: p.name.slice(dot + 1),
          value: p.value,
          key: p.name,
        };
      }
      return { nodeId: "", name: p.name, value: p.value, key: p.name };
    });
  }

  function applyOutputs(
    out: GraphRunOutputs,
    durationMs: number,
    timings?: GraphNodeTiming[],
  ) {
    const prev = outputs();
    const prevHist = new Map(prev.map((p) => [p.name, p.history] as const));
    setOutputs(
      Object.entries(out).map(([name, value]) => {
        const formatted = formatGraphValue(value as GraphValue);
        const hist = [...(prevHist.get(name) ?? [])];
        if (typeof value === "number" && Number.isFinite(value)) {
          hist.push(value);
          if (hist.length > OUTPUT_HISTORY_CAP) hist.splice(0, hist.length - OUTPUT_HISTORY_CAP);
        }
        return { name, formatted, history: hist };
      }),
    );
    setTrajectory(trajectoryFromGraphOutputs(out as Record<string, GraphValue>));
    setLastRunMs(durationMs);
    setRunCount((c) => c + 1);
    setOutputsStale(false);
    if (timings) {
      const map: Record<string, number> = {};
      for (const t of timings) map[t.nodeId] = t.ms;
      setNodeTimings(map);
    } else {
      setNodeTimings({});
    }
  }

  const trajectoryPlot = createMemo((): PlotEntry | null => {
    const t = trajectory();
    if (!t || t.time.length < 2) return null;
    return {
      id: 1,
      seq: 1,
      title: "Trajectory",
      mode: "uplot-grid",
      trajectory: t,
      timestamp: Date.now(),
    };
  });

  function loadExample(ex: GraphExample) {
    stopAuto();
    disposeRuntime();
    const next = parseImport(ex.definition);
    history.reset(next, `example: ${ex.id}`);
    setDoc(next);
    setJsonText(exportDocument(next));
    setExampleId(ex.id);
    setError(null);
    setPhase("draft");
    setStatusDetail(`Loaded “${ex.title}” — compile to prepare runtime`);
    setCompiled(false);
    setOutputsStale(false);
    setOutputs([]);
    setTrajectory(null);
    setLastRunMs(null);
    setRunCount(0);
    setNodeTimings({});
    setModuleCount(0);
    setExportSummary(null);
    setDirty(true);
    setSelected(null);
    setSelectedEdge(null);
    setFocusNodeId(null);
    setCanvasKey((k) => k + 1);
    bumpHistory();
  }

  function badgeText(): string {
    const v = validation();
    if (phase() === "exporting" || exporting()) return statusDetail();
    if (phase() === "compiling") return statusDetail();
    if (phase() === "error") return statusDetail();
    if (!v.ok) {
      const n = v.blocking.length;
      return n === 1 ? "1 graph issue" : `${n} graph issues`;
    }
    if (dirty() && compiled()) return "Changes not compiled";
    if (phase() === "ready" && compiled() && !dirty()) return statusDetail();
    if (v.totalModuleCount > 0) return `Not compiled · ${moduleSummary(v)}`;
    return statusDetail();
  }

  const fuseExport = createMemo(() => checkFuseExportSupport(doc()));
  const canExportOptimized = () =>
    !busy() && !exporting() && validation().ok && fuseExport().ok;

  function badgeTone(): "ok" | "warn" | "err" | "muted" {
    if (phase() === "error") return "err";
    if (!validation().ok) return "err";
    if (dirty() && compiled()) return "warn";
    if (phase() === "ready" && !dirty()) return "ok";
    return "muted";
  }

  function onCompileModeChange(mode: GraphCompileMode) {
    if (mode === compileMode()) return;
    setCompileMode(mode);
    // Switching mode requires a new compile for Run to match the selection.
    if (compiled() || runtime) {
      markStructuralChange();
      setStatusDetail(
        `Compile mode → ${compileModeLabel(mode)} — recompile to apply`,
      );
    }
  }

  async function compileGraph() {
    const v = validation();
    if (!v.ok) {
      setPhase("error");
      setError(v.blocking.map((i) => i.message).join("\n"));
      setStatusDetail("Graph invalid");
      return;
    }

    const mode = compileMode();
    if (mode === "fused") {
      const support = fuseExport();
      if (!support.ok) {
        setPhase("error");
        setError(support.reasons.join("\n"));
        setStatusDetail("Fused mode unavailable");
        return;
      }
    }

    setBusy(true);
    setError(null);
    setPhase("compiling");
    setStatusDetail(
      mode === "fused"
        ? "Compiling fused graph (1 module)…"
        : v.totalModuleCount > 0
          ? `Compiling graph… ${moduleSummary(v)}`
          : "Preparing graph runtime…",
    );
    stopAuto();
    try {
      const definition = toRunner(doc());
      disposeRuntime();
      setCompiled(false);
      setNodeTimings({});

      if (mode === "fused") {
        setStatusDetail("Fusing graph via compile-graph…");
        const result = await requestOptimizedExport(definition, { outMode: "table" });
        const wasm = base64ToUint8Array(result.wasmBase64);
        setStatusDetail("Instantiating fused module…");
        const fused = await FusedGraphRunner.load(wasm, {
          env: createDefaultScalarWasmImports(),
        });
        runtime = { kind: "fused", runner: fused };
        seedInputsFromDoc();
        setParams(paramsFromFused(fused));
        setCompiled(true);
        setDirty(false);
        setModuleCount(1);
        setActiveMode("fused");
        setExportSummary(exportSummaryFromMeta(result.meta));
        setPhase("ready");
        setStatusDetail(
          `Compiled · fused · 1 WASM module · ${result.meta.outputCount} output${
            result.meta.outputCount === 1 ? "" : "s"
          }`,
        );
      } else {
        const multi = await GraphRunner.load(definition, {
          compiler,
          env: createDefaultScalarWasmImports(),
          onProgress: (ev: GraphLoadProgress) => {
            setStatusDetail(ev.message);
          },
        });
        runtime = { kind: "modules", runner: multi };
        seedInputsFromDoc();
        setParams(paramsFromModules(multi));
        setCompiled(true);
        setDirty(false);
        setModuleCount(v.totalModuleCount);
        setActiveMode("modules");
        setPhase("ready");
        setStatusDetail(
          v.totalModuleCount > 0
            ? `Compiled · modules · ${v.totalModuleCount} WASM module${
                v.totalModuleCount === 1 ? "" : "s"
              } loaded`
            : "Compiled · modules · ready to run",
        );
      }
    } catch (e) {
      disposeRuntime();
      setCompiled(false);
      setParams([]);
      setInputs([]);
      setOutputs([]);
      setTrajectory(null);
      setModuleCount(0);
      setPhase("error");
      const msg = String((e as Error)?.message ?? e);
      setError(msg);
      setStatusDetail(classifyGraphError(msg).label);
    } finally {
      setBusy(false);
    }
  }

  function runOnce() {
    if (!runtime) {
      setError("Compile the graph first.");
      return;
    }
    if (dirty()) {
      setError("Graph changed since compilation — recompile, then run.");
      return;
    }
    try {
      setError(null);
      if (runtime.kind === "modules") {
        const profiled = runtime.runner.runProfiled({ ...inputValues });
        applyOutputs(profiled.outputs, profiled.totalMs, profiled.nodes);
      } else {
        const t0 = performance.now();
        const outputs = runtime.runner.run({ ...inputValues });
        applyOutputs(outputs, performance.now() - t0);
        setNodeTimings({});
      }
    } catch (e) {
      const msg = String((e as Error)?.message ?? e);
      setError(msg);
      setStatusDetail(classifyGraphError(msg).label);
      setPhase("error");
      stopAuto();
    }
  }

  function maybeRunOnChange() {
    if (runMode() === "onChange" && canRun()) runOnce();
  }

  function onParamChange(entry: ParamEntry, value: number) {
    if (!runtime) return;
    try {
      if (runtime.kind === "modules") {
        runtime.runner.setParam(entry.nodeId, entry.name, value);
      } else {
        runtime.runner.setParam(entry.key, value);
      }
      setParams((prev) =>
        prev.map((p) => (p.key === entry.key ? { ...p, value } : p)),
      );
      maybeRunOnChange();
    } catch (e) {
      setError(String((e as Error)?.message ?? e));
    }
  }

  function onInputChange(name: string, value: number) {
    inputValues[name] = value;
    setInputs((prev) => prev.map((i) => (i.name === name ? { ...i, value } : i)));
    maybeRunOnChange();
  }

  function setMode(mode: RunMode) {
    if (autoTimer != null) {
      clearInterval(autoTimer);
      autoTimer = null;
    }
    setRunMode(mode);
    if (mode === "continuous" && canRun()) {
      autoTimer = setInterval(() => {
        try {
          if (!runtime || dirty()) return;
          if (runtime.kind === "modules") {
            const profiled = runtime.runner.runProfiled({ ...inputValues });
            applyOutputs(profiled.outputs, profiled.totalMs, profiled.nodes);
          } else {
            const t0 = performance.now();
            const outputs = runtime.runner.run({ ...inputValues });
            applyOutputs(outputs, performance.now() - t0);
            setNodeTimings({});
          }
        } catch (e) {
          setError(String((e as Error)?.message ?? e));
          stopAuto();
        }
      }, Math.max(16, autoMs));
    }
  }

  function restoreExample() {
    const ex = getGraphExample(exampleId()) ?? GRAPH_EXAMPLES[0]!;
    loadExample(ex);
  }

  function applySource() {
    try {
      const parsed = JSON.parse(jsonText()) as unknown;
      applyDoc(parseImport(parsed), {
        remount: true,
        history: true,
        label: "import source",
      });
      setError(null);
      setStatusDetail("Imported graph source — compile to prepare runtime");
      setPhase("draft");
    } catch (e) {
      setError(String((e as Error)?.message ?? e));
    }
  }

  function exportExecutable() {
    const text = exportRunnerJson(doc());
    setJsonText(text);
    setShowSource(true);
    void navigator.clipboard?.writeText(text).catch(() => {});
  }

  function exportFullDocument() {
    const text = exportDocument(doc());
    setJsonText(text);
    setShowSource(true);
    void navigator.clipboard?.writeText(text).catch(() => {});
  }

  function copyFusePlan() {
    const support = fuseExport();
    if (!support.ok) {
      setError(support.reasons.join("\n"));
      return;
    }
    const text = formatFusePlanJson(support.plan);
    setJsonText(text);
    setShowSource(true);
    void navigator.clipboard?.writeText(text).catch(() => {});
    setStatusDetail("Fuse plan copied (advanced)");
  }

  /**
   * Export optimized WASM = fuse → one module download (.wasm + .graph.json).
   * Independent of Compile mode (Modules vs Fused). Failures stay non-blocking.
   */
  async function exportOptimizedWasm() {
    const v = validation();
    if (!v.ok) {
      setError(v.blocking.map((i) => i.message).join("\n"));
      return;
    }
    const support = fuseExport();
    if (!support.ok) {
      setError(support.reasons.join("\n"));
      return;
    }

    setExporting(true);
    setError(null);
    setPhase("exporting");
    setStatusDetail("Exporting optimized WASM (fuse)…");
    try {
      const definition = toRunner(doc());
      const result = await requestOptimizedExport(definition);
      const wasm = base64ToUint8Array(result.wasmBase64);
      const base =
        typeof crypto !== "undefined" && "randomUUID" in crypto
          ? `graph-${crypto.randomUUID().slice(0, 8)}`
          : `graph-export`;
      // Stagger wasm + sidecar downloads (Safari / multi-download blockers).
      downloadOptimizedExportPair(wasm, result.graphJson, base);
      const summary = exportSummaryFromMeta(result.meta);
      setExportSummary(summary);
      // Do not leave phase stuck on exporting — restore ready/draft based on active compile.
      if (compiled() && !dirty()) {
        setPhase("ready");
        const modeNote =
          activeMode() === "fused"
            ? "runtime still fused"
            : activeMode() === "modules"
              ? `runtime still modules${moduleCount() > 0 ? ` (${moduleCount()})` : ""}`
              : "runtime unchanged";
        setStatusDetail(`${summary} downloaded · ${modeNote}`);
      } else {
        setPhase("draft");
        setStatusDetail(`${summary} downloaded · select compile mode then Compile to run`);
      }
    } catch (e) {
      // Export failure must not block the editor runtime path.
      const msg = String((e as Error)?.message ?? e);
      setError(msg);
      setExportSummary(null);
      if (compiled() && !dirty()) {
        setPhase("ready");
        setStatusDetail(
          activeMode() === "fused"
            ? "Compiled · fused · export failed"
            : moduleCount() > 0
              ? `Compiled · modules · ${moduleCount()} WASM module${
                  moduleCount() === 1 ? "" : "s"
                } (export failed)`
              : "Compiled · export failed",
        );
      } else {
        setPhase("error");
        setStatusDetail(classifyGraphError(msg).label);
      }
    } finally {
      setExporting(false);
    }
  }

  function importFile() {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "application/json,.json";
    input.onchange = () => {
      const file = input.files?.[0];
      if (!file) return;
      void file.text().then((text) => {
        try {
          const parsed = JSON.parse(text) as unknown;
          applyDoc(parseImport(parsed), {
            remount: true,
            history: true,
            label: "import file",
          });
          setError(null);
          setStatusDetail("Imported file — compile to prepare runtime");
          setPhase("draft");
        } catch (e) {
          setError(String((e as Error)?.message ?? e));
        }
      });
    };
    input.click();
  }

  function onAdd(kind: NodeKind) {
    const { doc: next, nodeId } = addNodeToDocument(doc(), kind);
    applyDoc(next, {
      remount: false,
      history: true,
      label: `add ${kind}`,
      focusId: nodeId,
    });
  }

  function onInspectorChange(nodeId: string, data: MzNodeData) {
    if (canvasApi) {
      canvasApi.applyNodeData(nodeId, data);
      return;
    }
    markStructuralChange();
    setSelected((prev) => (prev && prev.id === nodeId ? { ...prev, data } : prev));
  }

  function selectedIds(): string[] {
    return canvasApi?.getSelectedNodeIds() ?? (selected() ? [selected()!.id] : []);
  }

  function layoutAlign(
    mode: "left" | "right" | "top" | "bottom" | "centerX" | "centerY",
  ) {
    const ids = selectedIds();
    if (ids.length < 2) {
      setError("Select 2+ nodes to align (Shift-drag or ⌘/Ctrl-click).");
      return;
    }
    applyDoc(alignSelectedNodes(doc(), ids, mode), {
      remount: false,
      history: true,
      label: `align ${mode}`,
    });
  }

  function layoutDistribute(axis: "x" | "y") {
    const ids = selectedIds();
    if (ids.length < 3) {
      setError("Select 3+ nodes to distribute.");
      return;
    }
    applyDoc(distributeSelectedNodes(doc(), ids, axis), {
      remount: false,
      history: true,
      label: `distribute ${axis}`,
    });
  }

  function layoutAuto() {
    applyDoc(applyAutoLayout(doc()), {
      remount: false,
      history: true,
      label: "auto-layout",
    });
  }

  function selectNodeFromPanel(id: string) {
    canvasApi?.selectNodeId(id);
    canvasApi?.fitToNode(id);
    const n = outlineNodes().find((x) => x.id === id) ?? null;
    setSelected(n);
  }

  const canCompile = () => {
    if (busy() || exporting() || !validation().ok) return false;
    if (compileMode() === "fused" && !fuseExport().ok) return false;
    return true;
  };
  const canRun = () => compiled() && !busy() && !exporting() && !dirty();
  const canUndo = createMemo(() => {
    void histTick();
    return history.canUndo;
  });
  const canRedo = createMemo(() => {
    void histTick();
    return history.canRedo;
  });

  const commands = createMemo((): CommandItem[] => {
    void histTick();
    return [
      ...addNodeCommands(onAdd),
      {
        id: "compile",
        label: "Compile graph",
        group: "Run",
        hint: compileModeLabel(compileMode()),
        disabled: !canCompile(),
        disabledReason: (() => {
          if (!validation().ok) {
            return validation().blocking[0]?.message ?? "Fix graph issues first";
          }
          if (compileMode() === "fused" && !fuseExport().ok) {
            return fuseExport().reason;
          }
          return undefined;
        })(),
        run: () => void compileGraph(),
      },
      {
        id: "mode-modules",
        label: "Compile mode: Modules",
        group: "Run",
        hint: "1 WASM per node",
        run: () => onCompileModeChange("modules"),
      },
      {
        id: "mode-fused",
        label: "Compile mode: Fused",
        group: "Run",
        hint: fuseExport().ok ? "1 WASM for graph" : fuseExport().reason,
        disabled: !fuseExport().ok,
        disabledReason: fuseExport().ok ? undefined : fuseExport().reason,
        run: () => onCompileModeChange("fused"),
      },
      { id: "run", label: "Run once", group: "Run", run: runOnce },
      {
        id: "run-cont",
        label: "Run continuously",
        group: "Run",
        run: () => setMode("continuous"),
      },
      {
        id: "run-change",
        label: "Run when inputs change",
        group: "Run",
        run: () => setMode("onChange"),
      },
      {
        id: "undo",
        label: "Undo",
        group: "Edit",
        hint: "⌘Z",
        run: undo,
      },
      {
        id: "redo",
        label: "Redo",
        group: "Edit",
        hint: "⌘⇧Z",
        run: redo,
      },
      {
        id: "auto-layout",
        label: "Auto-layout",
        group: "Layout",
        run: layoutAuto,
      },
      {
        id: "align-left",
        label: "Align left",
        group: "Layout",
        run: () => layoutAlign("left"),
      },
      {
        id: "export-optimized",
        label: "Export optimized WASM",
        group: "File",
        hint: (() => {
          const fe = fuseExport();
          return fe.ok ? "1 fused module" : fe.reason;
        })(),
        disabled: !canExportOptimized(),
        disabledReason: (() => {
          if (!validation().ok) {
            return validation().blocking[0]?.message ?? "Fix graph issues first";
          }
          const fe = fuseExport();
          return fe.ok ? undefined : fe.reason;
        })(),
        run: () => void exportOptimizedWasm(),
      },
      {
        id: "export-exec",
        label: "Export executable graph",
        group: "File",
        run: exportExecutable,
      },
      {
        id: "export-full",
        label: "Export full document",
        group: "File",
        run: exportFullDocument,
      },
      {
        id: "copy-fuse-plan",
        label: "Copy fuse plan (advanced)",
        group: "File",
        disabled: !fuseExport().ok,
        disabledReason: fuseExport().ok ? undefined : fuseExport().reason,
        run: copyFusePlan,
      },
      { id: "import-file", label: "Import graph file…", group: "File", run: importFile },
      {
        id: "restore",
        label: "Reload current example",
        group: "Examples",
        run: restoreExample,
      },
      ...GRAPH_EXAMPLES.map(
        (ex): CommandItem => ({
          id: `example:${ex.id}`,
          label: ex.title,
          group: `Examples · ${CATEGORY_LABELS[ex.category]}`,
          hint: ex.tags.join(", "),
          run: () => loadExample(ex),
        }),
      ),
    ];
  });

  return (
    <main class="flex min-h-0 flex-1 flex-col overflow-hidden">
      <GraphCommandMenu open={cmdOpen()} onClose={() => setCmdOpen(false)} commands={commands()} />
      <div class="flex min-h-0 flex-1 flex-col gap-2 p-2">
        <h1 class="sr-only">Graph editor</h1>
        <div class="flex shrink-0 flex-wrap items-center gap-1.5">
          <GraphPalette onAdd={onAdd} />
          <div class="mx-1 h-5 w-px bg-line" />
          <button
            type="button"
            class="ghost-btn"
            disabled={!canUndo()}
            title={history.undoLabel ? `Undo ${history.undoLabel}` : "Undo"}
            onClick={undo}
          >
            Undo
          </button>
          <button
            type="button"
            class="ghost-btn"
            disabled={!canRedo()}
            title={history.redoLabel ? `Redo ${history.redoLabel}` : "Redo"}
            onClick={redo}
          >
            Redo
          </button>
          <button type="button" class="ghost-btn" title="Command menu (⌘K)" onClick={() => setCmdOpen(true)}>
            ⌘K
          </button>
          <div class="mx-1 h-5 w-px bg-line" />
          <div class="relative" title="Load a starter graph (like the REPL rocket demo)">
            <details class="group" open={false}>
              <summary
                class="ghost-btn list-none [&::-webkit-details-marker]:hidden cursor-pointer max-w-[12rem] truncate"
                classList={{ "opacity-40 pointer-events-none": busy() || exporting() }}
              >
                Example · {currentExample()?.title ?? "…"}
              </summary>
              <div
                class="absolute left-0 z-40 mt-1 flex max-h-[min(70vh,24rem)] w-[min(20rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-md border border-line bg-panel shadow-lg"
                role="listbox"
                aria-label="Starter examples"
              >
                <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain py-1">
                  {(Object.keys(CATEGORY_LABELS) as Array<keyof typeof CATEGORY_LABELS>).map(
                    (cat) => (
                      <div>
                        <p class="sticky top-0 z-10 bg-panel px-3 py-1 text-[10px] font-semibold tracking-wider text-fg-muted uppercase border-b border-line/60">
                          {CATEGORY_LABELS[cat]}
                        </p>
                        {GRAPH_EXAMPLES.filter((ex) => ex.category === cat).map((ex) => (
                          <button
                            type="button"
                            role="option"
                            aria-selected={exampleId() === ex.id}
                            class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset"
                            classList={{
                              "bg-keyword/15 text-fg": exampleId() === ex.id,
                              "text-fg-secondary": exampleId() !== ex.id,
                            }}
                            title={ex.description}
                            onClick={(e) => {
                              loadExample(ex);
                              const details = (e.currentTarget as HTMLElement).closest(
                                "details",
                              ) as HTMLDetailsElement | null;
                              if (details) details.open = false;
                            }}
                          >
                            <span class="font-medium text-fg">{ex.title}</span>
                            <span class="mt-0.5 block text-[10px] leading-snug text-fg-muted">
                              {ex.tags.join(" · ")}
                            </span>
                          </button>
                        ))}
                      </div>
                    ),
                  )}
                </div>
              </div>
            </details>
          </div>
          <label class="flex items-center gap-1 text-[11px] text-fg-muted" title={DUAL_MODEL_COPY}>
            <span class="sr-only">Compile mode</span>
            <select
              class="rounded border border-line bg-inset px-1.5 py-1 text-[11px] text-fg"
              aria-label="Compile mode"
              value={compileMode()}
              disabled={busy() || exporting()}
              onChange={(e) =>
                onCompileModeChange(e.currentTarget.value as GraphCompileMode)
              }
            >
              <option value="modules">Modules (1 per node)</option>
              <option
                value="fused"
                disabled={!fuseExport().ok}
                title={fuseExport().ok ? "One WASM for the whole graph" : fuseExport().reason}
              >
                {fuseExport().ok ? "Fused (1 module)" : "Fused (unavailable)"}
              </option>
            </select>
          </label>
          <button
            type="button"
            class="ghost-btn !border-keyword !bg-keyword !text-app"
            disabled={!canCompile()}
            title={(() => {
              if (!validation().ok) {
                return validation().blocking[0]?.message ?? "Fix graph issues first";
              }
              if (compileMode() === "fused") {
                const fe = fuseExport();
                if (!fe.ok) return fe.reason;
                return `Compile fused · ${fe.summary}`;
              }
              return `Compile modules · ${moduleSummary(validation())}`;
            })()}
            onClick={() => void compileGraph()}
          >
            {busy() && phase() === "compiling"
              ? "Compiling…"
              : dirty() && compiled()
                ? "Recompile"
                : "Compile"}
          </button>
          <button
            type="button"
            class="ghost-btn"
            disabled={!canRun()}
            onClick={runOnce}
            title="Run once with current inputs and parameters"
          >
            Run
          </button>
          <select
            class="rounded border border-line bg-inset px-1.5 py-1 text-[11px] text-fg"
            title="Execution mode"
            aria-label="Execution mode"
            value={runMode()}
            disabled={!canRun() && runMode() === "manual"}
            onChange={(e) => setMode(e.currentTarget.value as RunMode)}
          >
            <option value="manual">Run once</option>
            <option value="onChange">On input change</option>
            <option value="continuous">Continuously</option>
          </select>
          <div class="mx-1 h-5 w-px bg-line" />
          <button type="button" class="ghost-btn" onClick={layoutAuto} title="Layered auto-layout">
            Auto-layout
          </button>
          <button type="button" class="ghost-btn" onClick={() => layoutAlign("left")} title="Align selected left">
            Align
          </button>
          <button type="button" class="ghost-btn" onClick={() => layoutDistribute("x")} title="Distribute selected horizontally">
            Distribute
          </button>
          <button
            type="button"
            class="ghost-btn"
            disabled={!canExportOptimized()}
            title={(() => {
              if (!validation().ok) {
                return validation().blocking[0]?.message ?? "Fix graph issues first";
              }
              const fe = fuseExport();
              if (!fe.ok) return fe.reason;
              return `Download one fused WASM module + sidecar · ${fe.summary}`;
            })()}
            onClick={() => void exportOptimizedWasm()}
          >
            {exporting() ? "Exporting…" : "Export optimized WASM"}
          </button>
          <div class="relative">
            <details class="group">
              <summary class="ghost-btn list-none [&::-webkit-details-marker]:hidden cursor-pointer">
                File
              </summary>
              <div class="absolute left-0 z-30 mt-1 flex max-h-[min(70vh,28rem)] min-w-[240px] w-[min(20rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-md border border-line bg-panel shadow-lg">
                <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain py-1">
                  <button type="button" class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset" onClick={importFile}>
                    Import graph file…
                  </button>
                  <button
                    type="button"
                    class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset disabled:opacity-40"
                    disabled={!canExportOptimized()}
                    title={(() => {
                      const fe = fuseExport();
                      return fe.ok ? DUAL_MODEL_COPY : fe.reason;
                    })()}
                    onClick={() => void exportOptimizedWasm()}
                  >
                    Export optimized WASM
                  </button>
                  <button type="button" class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset" onClick={exportExecutable}>
                    Export executable graph
                  </button>
                  <button type="button" class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset" onClick={exportFullDocument}>
                    Export full document
                  </button>
                  <button
                    type="button"
                    class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset disabled:opacity-40"
                    disabled={!fuseExport().ok}
                    title="Copy the fuse plan JSON (advanced)"
                    onClick={copyFusePlan}
                  >
                    Copy fuse plan (advanced)
                  </button>
                  <button
                    type="button"
                    class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset"
                    onClick={() => setShowSource((v) => !v)}
                  >
                    {showSource() ? "Hide graph source" : "Show graph source"}
                  </button>
                  <button type="button" class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset" onClick={restoreExample}>
                    Reload current example
                  </button>
                  <div class="my-1 border-t border-line" />
                  <p class="sticky top-0 z-10 bg-panel px-3 py-1 text-[10px] font-semibold tracking-wider text-fg-muted uppercase border-b border-line/60">
                    Examples
                  </p>
                  {GRAPH_EXAMPLES.map((ex) => (
                    <button
                      type="button"
                      class="block w-full px-3 py-1.5 text-left text-[12px] hover:bg-inset"
                      title={ex.description}
                      onClick={() => loadExample(ex)}
                    >
                      <span class="text-fg">{ex.title}</span>
                      <span class="mt-0.5 block text-[10px] text-fg-muted">
                        {CATEGORY_LABELS[ex.category]} · {ex.tags.join(" · ")}
                      </span>
                    </button>
                  ))}
                </div>
              </div>
            </details>
          </div>
          <div
            class="ml-auto max-w-[24rem] truncate rounded-md border border-line bg-panel px-2 py-1 font-mono text-[11px]"
            title={badgeText()}
            classList={{
              "text-ok": badgeTone() === "ok",
              "text-warn": badgeTone() === "warn",
              "text-err": badgeTone() === "err",
              "text-fg-muted": badgeTone() === "muted",
            }}
          >
            {badgeText()}
          </div>
        </div>
        <Show when={currentExample()}>
          {(ex) => (
            <p class="shrink-0 px-0.5 text-[11px] leading-snug text-fg-muted">
              <span class="font-medium text-fg-secondary">{ex().title}</span>
              <span class="mx-1.5 text-line">·</span>
              {ex().description}
              <span class="mx-1.5 text-line">·</span>
              Graph outputs:{" "}
              <span class="font-mono text-fg-secondary">
                {Object.keys(ex().definition.outputs ?? {}).join(", ") || "(auto)"}
              </span>
            </p>
          )}
        </Show>

        <div class="grid min-h-0 flex-1 gap-2 lg:grid-cols-[1fr_300px]">
          <section class="flex min-h-0 flex-col overflow-hidden rounded-lg border border-line bg-panel">
            <div class="min-h-0 flex-1">
              <Show when={canvasKey()} keyed>
                {(_k) => (
                  <GraphCanvas
                    document={doc()}
                    validationIssues={validation().issues}
                    focusNodeId={focusNodeId()}
                    onDocumentChange={onDocumentChange}
                    onSelectNode={setSelected}
                    onSelectEdge={setSelectedEdge}
                    onApi={(api) => {
                      canvasApi = api;
                    }}
                  />
                )}
              </Show>
            </div>
            <Show when={showSource()}>
              <div class="shrink-0 border-t border-line px-2 pb-2 pt-1.5">
                <p class="mb-1 text-[11px] text-fg-muted">
                  Advanced — graph source (definition + layout or executable)
                </p>
                <textarea
                  class="max-h-48 min-h-[120px] w-full resize-y rounded-md border border-line bg-inset px-3 py-2 font-mono text-[11px] leading-relaxed text-fg outline-none focus:border-focus"
                  spellcheck={false}
                  value={jsonText()}
                  onInput={(e) => setJsonText(e.currentTarget.value)}
                />
                <button type="button" class="ghost-btn mt-1.5" onClick={applySource}>
                  Import graph source
                </button>
              </div>
            </Show>
          </section>

          <section class="flex min-h-0 flex-col divide-y divide-line overflow-y-auto rounded-lg border border-line bg-panel">
            <Show when={validation().issues.length > 0}>
              <GraphProblems
                issues={validation().issues}
                nodes={outlineNodes()}
                onSelectNodeId={selectNodeFromPanel}
              />
            </Show>
            <GraphOutline
              nodes={outlineNodes()}
              selectedId={selected()?.id ?? null}
              onSelectNodeId={selectNodeFromPanel}
              nodeTimings={nodeTimings()}
            />

            <GraphInspector node={selected()} onChange={onInspectorChange} />

            <Show when={selectedEdge()}>
              {(e) => (
                <div class="px-3 py-2 font-mono text-[11px]">
                  <h2 class="mb-1.5 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
                    Edge
                  </h2>
                  <p class="text-fg-secondary">
                    {e().source}.{e().sourceHandle ?? "out"} → {e().target}.
                    {e().targetHandle ?? "in"}
                  </p>
                  <p class="mt-1 text-fg-muted">Drag endpoints on the edge to reconnect.</p>
                  <button
                    type="button"
                    class="ghost-btn mt-2 text-err"
                    onClick={() => canvasApi?.deleteSelected()}
                  >
                    Delete edge
                  </button>
                </div>
              )}
            </Show>

            <div class="px-3 py-2">
              <h2 class="mb-1.5 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
                Inputs
              </h2>
              <Show
                when={inputs().length > 0}
                fallback={
                  <p class="text-[12px] text-fg-muted">Compile the graph to drive graph inputs.</p>
                }
              >
                <div class="space-y-2">
                  {/* Index (not For): For remounts rows when map() yields new objects, which kills range drag. */}
                  <Index each={inputs()}>
                    {(inp) => (
                      <label class="grid grid-cols-[5rem_1fr_3.5rem] items-center gap-2 font-mono text-[11px]">
                        <span class="truncate text-fg-muted">{inp().name}</span>
                        <input
                          type="range"
                          min={0}
                          max={20}
                          step={0.1}
                          value={inp().value}
                          onInput={(e) => onInputChange(inp().name, Number(e.currentTarget.value))}
                        />
                        <input
                          type="number"
                          class="w-full rounded border border-line bg-inset px-1 py-0.5 text-fg"
                          step={0.1}
                          value={inp().value}
                          onInput={(e) => onInputChange(inp().name, Number(e.currentTarget.value))}
                        />
                      </label>
                    )}
                  </Index>
                </div>
              </Show>
            </div>

            <div class="px-3 py-2">
              <h2
                class="mb-1.5 text-[10px] font-semibold tracking-wider text-fg-muted uppercase"
                title="Change without recompiling while the graph is compiled"
              >
                Parameters
              </h2>
              <Show
                when={params().length > 0}
                fallback={<p class="text-[12px] text-fg-muted">Parameters appear after compile.</p>}
              >
                <div class="space-y-2">
                  {/* Index (not For): stable DOM across value updates so range thumbs can drag. */}
                  <Index each={params()}>
                    {(p) => {
                      // Freeze range at row create time so live value changes don't retune min/max mid-drag.
                      const range = paramSliderRange(untrack(() => p().value));
                      const entry = untrack(() => p());
                      const label = entry.nodeId ? `${entry.nodeId}.${entry.name}` : entry.name;
                      return (
                        <label class="grid grid-cols-[6.5rem_1fr_3.5rem] items-center gap-2 font-mono text-[11px]">
                          <span class="truncate text-fg-muted" title={label}>
                            {label}
                          </span>
                          <input
                            type="range"
                            min={range.min}
                            max={range.max}
                            step={range.step}
                            value={p().value}
                            onInput={(e) =>
                              onParamChange(p(), Number(e.currentTarget.value))
                            }
                          />
                          <input
                            type="number"
                            class="w-full rounded border border-line bg-inset px-1 py-0.5 text-fg"
                            step={range.step}
                            value={p().value}
                            onInput={(e) =>
                              onParamChange(p(), Number(e.currentTarget.value))
                            }
                          />
                        </label>
                      );
                    }}
                  </Index>
                </div>
              </Show>
            </div>

            <div class="px-3 py-2">
              <h2 class="mb-1.5 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
                Runtime model
              </h2>
              <p class="text-[11px] leading-snug text-fg-muted" title={DUAL_MODEL_COPY}>
                <strong class="font-medium text-fg-secondary">Compile mode</strong> (toolbar):{" "}
                {compileModeLabel(compileMode())}
                {activeMode() && compiled() && !dirty()
                  ? ` · active: ${compileModeLabel(activeMode()!)}`
                  : dirty() && compiled()
                    ? " · recompile to apply"
                    : " · not compiled yet"}
                .
              </p>
              <p class="mt-1 text-[11px] leading-snug text-fg-muted">
                <strong class="font-medium text-fg-secondary">Run</strong>{" "}
                {activeMode() === "fused" && compiled() && !dirty()
                  ? "uses 1 fused WASM module"
                  : activeMode() === "modules" && compiled() && !dirty()
                    ? `uses ${moduleCount()} module${moduleCount() === 1 ? "" : "s"} (1 per node)`
                    : compileMode() === "fused"
                      ? "will use 1 fused module after Compile"
                      : `will use ${moduleSummary(validation())} after Compile`}
                .
              </p>
              <p class="mt-1 text-[11px] leading-snug text-fg-muted">
                <strong class="font-medium text-fg-secondary">Export optimized WASM</strong> always
                downloads a fused artifact
                {exportSummary() ? ` (${exportSummary()})` : ""} — independent of Run mode.
                <Show when={!fuseExport().ok ? fuseExport().reason : null}>
                  {(reason) => (
                    <span class="mt-1 block text-warn">Fused unavailable: {reason()}</span>
                  )}
                </Show>
              </p>
            </div>

            <div class="px-3 py-2">
              <div class="mb-1.5 flex flex-wrap items-baseline justify-between gap-2">
                <h2 class="text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
                  Graph outputs
                </h2>
                <Show when={runCount() > 0}>
                  <span class="font-mono text-[10px] text-fg-muted">
                    Run {runCount()}
                    {lastRunMs() != null ? ` · ${lastRunMs()!.toFixed(2)} ms` : ""}
                    {activeMode() === "fused"
                      ? " · fused"
                      : moduleCount() > 0
                        ? ` · ${moduleCount()} modules`
                        : ""}
                  </span>
                </Show>
              </div>
              <p class="mb-2 text-[10px] leading-snug text-fg-muted">
                Named outputs from the graph definition (canvas{" "}
                <span class="font-mono">out_*</span> nodes). Multi-out examples show every key
                here after Run. ODE matrices with columns{" "}
                <span class="font-mono">[t, r, v, …, γ]</span> auto-plot as trajectory charts.
              </p>
              <Show when={outputsStale() && outputs().length > 0}>
                <p class="mb-2 rounded border border-warn/40 bg-inset px-2 py-1 text-[11px] text-warn">
                  Results from previous compilation. Recompile the graph to update them.
                </p>
              </Show>
              <Show when={trajectoryPlot()}>
                {(entry) => (
                  <div class="mb-3 overflow-x-auto rounded-md border border-line bg-inset p-2">
                    <div class="mb-1 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
                      Charts · {entry().trajectory?.time.length ?? 0} samples
                    </div>
                    <PlotHost entry={entry()} />
                  </div>
                )}
              </Show>
              <Show
                when={outputs().length > 0}
                fallback={
                  <p class="text-[12px] text-fg-muted">
                    Run the graph to see named graph outputs.
                  </p>
                }
              >
                <div class="divide-y divide-line">
                  <For each={outputs()}>
                    {(o) => (
                      <div class="py-2">
                        <div class="flex items-start gap-2 font-mono text-[12px]">
                          <span class="min-w-[4.5rem] shrink-0 text-fg-muted">{o().name}</span>
                          <div class="min-w-0 flex-1">
                            <div class="text-number">{o().formatted.text}</div>
                            <Show when={o().formatted.kind !== "number"}>
                              <div class="mt-0.5 text-[10px] text-fg-muted">
                                {o().formatted.kind}
                              </div>
                            </Show>
                            <Show when={o().formatted.matrix}>
                              {(m) => {
                                const previewRows = () =>
                                  Math.min(m().rows, MATRIX_PREVIEW_ROWS);
                                const cellCount = () => previewRows() * m().cols;
                                const truncated = () => m().rows > MATRIX_PREVIEW_ROWS;
                                // Large ODE trajectories: skip dense grid (charts cover them).
                                const skipGrid = () => m().rows > 24 && m().cols >= 6;
                                return (
                                  <Show when={!skipGrid()}>
                                    <div
                                      class="mt-1 grid gap-px overflow-x-auto rounded border border-line bg-line p-px font-mono text-[10px]"
                                      style={{
                                        "grid-template-columns": `repeat(${m().cols}, minmax(2.2rem, 1fr))`,
                                      }}
                                    >
                                      <For
                                        each={Array.from({ length: cellCount() }, (_, i) => i)}
                                      >
                                        {(i) => (
                                          <div class="bg-inset px-1 py-0.5 text-right text-number">
                                            {formatSparkNumber(m().data[i()] ?? 0)}
                                          </div>
                                        )}
                                      </For>
                                    </div>
                                    <Show when={truncated()}>
                                      <div class="mt-0.5 text-[9px] text-fg-muted">
                                        showing {previewRows()} of {m().rows} rows
                                      </div>
                                    </Show>
                                  </Show>
                                );
                              }}
                            </Show>
                            <Show when={o().history.length > 1}>
                              <div class="mt-1.5">
                                <OutputSparkline values={o().history} />
                                <div class="mt-0.5 flex justify-between font-mono text-[9px] text-fg-muted">
                                  <span>n={o().history.length}</span>
                                  <span>
                                    last {formatSparkNumber(o().history[o().history.length - 1]!)}
                                  </span>
                                </div>
                              </div>
                            </Show>
                          </div>
                        </div>
                      </div>
                    )}
                  </For>
                </div>
              </Show>
              <Show when={Object.keys(nodeTimings()).length > 0}>
                <div class="mt-3 border-t border-line pt-2">
                  <h3 class="mb-1 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
                    Per-node timing
                  </h3>
                  <ul class="space-y-0.5 font-mono text-[11px] text-fg-secondary">
                    <For each={Object.entries(nodeTimings())}>
                      {([id, ms]) => (
                        <li class="flex justify-between gap-2">
                          <button
                            type="button"
                            class="truncate text-left hover:text-fg"
                            onClick={() => selectNodeFromPanel(id)}
                          >
                            {id}
                          </button>
                          <span>{ms.toFixed(3)} ms</span>
                        </li>
                      )}
                    </For>
                  </ul>
                </div>
              </Show>
            </div>

            <Show when={error()}>
              <pre class="max-h-40 overflow-auto whitespace-pre-wrap bg-inset px-3 py-2 font-mono text-[11px] text-err">
                {error()}
              </pre>
            </Show>
          </section>
        </div>
      </div>
    </main>
  );
}
