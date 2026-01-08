import {
  AotHostEnv,
  AllocFailureError,
  readAbiManifest,
  type AotAbiManifest,
  type AotHostDebugStats,
} from "../aot_env";
import { compileCached, type WasmCompiler } from "./compile_cache";
import { createDefaultScalarWasmImports, type ScalarWasmEnv, type ScalarWasmImports } from "./env";
import {
  assertFiniteScalar,
  nodeInputKind,
  nodeOutputKind,
  normalizeGraphDefinition,
  parseGraphRef,
  type GraphDefinition,
  type GraphNode,
  type GraphNodeId,
  type GraphPortName,
  type GraphValue,
  type NodeManifest,
  type NormalizedGraphDefinition,
  type PortKind,
} from "./schema";
import { topoSort, type Topology } from "./topo";
import {
  kindsCompatible,
  normalizePortKind,
  readWireValue,
  resultTagToPortKind,
  writeWireValue,
  type WasmNodeExports,
} from "./value_transfer";

/**
 * Typed alloc-failure error naming the offending graph node (task-16 / C5).
 * Thrown when host-side fault injection or module alloc fails mid-tick.
 * Shared env handle counts are left unchanged (no partial durable store writes
 * that stick); the next tick with normal alloc succeeds.
 */
export class GraphAllocError extends Error {
  readonly code = "AllocFailure" as const;
  readonly nodeId: string;
  constructor(nodeId: string, cause?: unknown) {
    const detail =
      cause instanceof Error ? cause.message : cause != null ? String(cause) : "alloc failed";
    super(`AllocFailure on node '${nodeId}': ${detail}`);
    this.name = "GraphAllocError";
    this.nodeId = nodeId;
  }
}

/** Test-only runner observability (task-16 debugStats). */
export type GraphRunnerDebugStats = {
  instanceCount: number;
  exprInstanceCount: number;
  wasmInstanceCount: number;
  /** Per-node wasm memory pages (64KiB units). */
  wasmMemoryPagesByNode: Record<string, number>;
  /** Max wasm memory pages across instances. */
  maxWasmMemoryPages: number;
  host: AotHostDebugStats | null;
};

export type GraphLoadProgress = {
  /** High-level stage. */
  stage: "validate" | "compile" | "instantiate" | "ready";
  /** Human-readable status line. */
  message: string;
  /** Node currently being compiled/instantiated (expr/wasm). */
  nodeId?: GraphNodeId;
  nodeKind?: "expr" | "wasm";
  /** 1-based index among compute modules (expr + wasm). */
  index?: number;
  /** Total compute modules in this load. */
  total?: number;
};

export type GraphRunnerOptions = {
  compiler: WasmCompiler;
  /** Scalar-only env (B1 path). Ignored when `host` is provided. */
  env?: ScalarWasmImports | { env?: ScalarWasmEnv };
  /**
   * Shared AOT host env across all node instances (required for series handle
   * pass-through and full-Value edges). When omitted, a fresh env is created
   * for full-Value graphs; pure-scalar graphs keep the lightweight B1 env.
   */
  host?: AotHostEnv;
  /** Optional progress callback for multi-module compile/load UI. */
  onProgress?: (event: GraphLoadProgress) => void;
};

export type GraphRunInputs = Record<string, GraphValue>;
export type GraphRunOutputs = Record<string, GraphValue>;

/** Per-node timing from {@link GraphRunner.runProfiled}. */
export type GraphNodeTiming = {
  nodeId: GraphNodeId;
  kind: "input" | "const" | "expr" | "wasm";
  ms: number;
};

export type GraphProfiledRun = {
  outputs: GraphRunOutputs;
  totalMs: number;
  nodes: GraphNodeTiming[];
};

/** Per-input / per-output Float64Array lanes for {@link GraphRunner.runBatch}. */
export type GraphBatchLanes = Record<string, Float64Array>;

type LoadedExprNode = {
  kind: "expr";
  id: GraphNodeId;
  /** Original expression text (host names, before boundary rewrite). */
  expr: string;
  inputNames: GraphPortName[];
  inputKinds: PortKind[];
  paramNames: GraphPortName[];
  params: Record<string, number>;
  outputKind: PortKind;
  resultTag: string;
  instance: WebAssembly.Instance;
  exports: WasmNodeExports;
  scalarOnly: boolean;
  manifest: AotAbiManifest | null;
};

type LoadedWasmNode = {
  kind: "wasm";
  id: GraphNodeId;
  inputNames: GraphPortName[];
  inputKinds: PortKind[];
  paramNames: GraphPortName[];
  params: Record<string, number>;
  outputKind: PortKind;
  resultTag: string;
  instance: WebAssembly.Instance;
  exports: WasmNodeExports;
  scalarOnly: boolean;
  nodeManifest: NodeManifest;
  abiManifest: AotAbiManifest | null;
};

type LoadedConstNode = {
  kind: "const";
  id: GraphNodeId;
  value: GraphValue;
  outputKind: PortKind;
};

type LoadedInputNode = {
  kind: "input";
  id: GraphNodeId;
  name: string;
  outputKind: PortKind;
};

type LoadedNode = LoadedExprNode | LoadedWasmNode | LoadedConstNode | LoadedInputNode;

/** Precomputed tick plan: hoisted exports, slot indices, zero per-tick lookup. */
type InputPlan = {
  slot: number;
  name: string;
  outputKind: PortKind;
};

type ConstPlan = {
  slot: number;
  value: GraphValue;
  outputKind: PortKind;
  isNumber: boolean;
};

type ComputePlan = {
  slot: number;
  node: LoadedExprNode | LoadedWasmNode;
  eval: (...args: number[]) => number;
  resetHeap: (() => void) | undefined;
  /** Input source slots (parallel to node.inputNames). */
  inputSlots: number[];
  inputKinds: PortKind[];
  paramNames: GraphPortName[];
  /** Pre-sized arity buffer reused across ticks (length = inputs + params). */
  argsBuf: Float64Array;
  arity: number;
  scalarOnly: boolean;
  outputKind: PortKind;
  resultTag: string;
};

type OutputPlan = {
  name: string;
  slot: number;
  outputKind: PortKind;
};

type TickPlan = {
  /** nodeId → dense slot index */
  slotOf: Map<GraphNodeId, number>;
  slotCount: number;
  inputs: InputPlan[];
  consts: ConstPlan[];
  computes: ComputePlan[];
  outputs: OutputPlan[];
  /** True when every edge/value on the graph is a number (scalar fast path). */
  allNumber: boolean;
  /** True when every graph output is a number (runBatch can emit Float64 lanes). */
  outputsAreNumber: boolean;
};

/**
 * Internal AOT boundary aliases only — **not** the public graph port model.
 * Public semantics use real manifest / GraphDefinition port names (task-13 C2;
 * see `src/wasm/abi.zig` GRAPH_ALIAS_LIMIT). This rewrite is applied solely when
 * compiling expr nodes for the multi-module wasm boundary.
 */
const PARAM_ALIASES = ["x", "y", "z"] as const;

/** Corpus v1 common limit: inputs+params combined per expr node (== abi.GRAPH_ALIAS_LIMIT). */
export const GRAPH_ALIAS_LIMIT = PARAM_ALIASES.length;

/** Named error identity shared with the VM-native graph evaluator. */
export const ALIAS_LIMIT_ERROR = "AliasLimitExceeded";

export class GraphRunner {
  /** Reused across run() ticks to avoid Map alloc (cleared each tick). */
  private readonly valueSlots: Array<GraphValue | undefined> = [];
  /** Dense f64 scratch for pure-scalar run / runBatch (no per-tick alloc). */
  private scalarSlots: Float64Array = new Float64Array(0);
  private plan: TickPlan | null = null;

  private constructor(
    private readonly def: NormalizedGraphDefinition,
    private readonly topology: Topology,
    private readonly nodes: Map<GraphNodeId, LoadedNode>,
    private host: AotHostEnv | null,
    private scalarEnv: ScalarWasmImports | null,
    private readonly compiler: WasmCompiler,
  ) {
    this.rebuildPlan();
  }

  static async load(def: GraphDefinition, options: GraphRunnerOptions): Promise<GraphRunner> {
    const progress = options.onProgress;
    const normalized = normalizeGraphDefinition(def);
    const topology = topoSort(normalized.nodes, normalized.edges);

    let host: AotHostEnv | null =
      graphNeedsFullValue(normalized.nodes) || options.host ? (options.host ?? new AotHostEnv()) : null;
    let scalarEnv: ScalarWasmImports | null =
      !host
        ? ((options.env as ScalarWasmImports | undefined) ?? createDefaultScalarWasmImports())
        : null;

    progress?.({ stage: "validate", message: "Validating graph…" });
    validateNodePorts(normalized, topology);
    typeCheckEdges(normalized, topology);

    const loaded = new Map<GraphNodeId, LoadedNode>();
    const computeNodes = topology.ordered.filter((n) => n.type === "expr" || n.type === "wasm");
    const totalModules = computeNodes.length;
    let moduleIndex = 0;

    const ensureHost = (): AotHostEnv => {
      if (!host) {
        host = new AotHostEnv();
        scalarEnv = null;
      }
      return host;
    };

    for (const node of topology.ordered) {
      switch (node.type) {
        case "input":
          loaded.set(node.id, {
            kind: "input",
            id: node.id,
            name: node.name ?? node.id,
            outputKind: nodeOutputKind(node),
          });
          break;
        case "const":
          loaded.set(node.id, {
            kind: "const",
            id: node.id,
            value: node.value,
            outputKind: nodeOutputKind(node),
          });
          break;
        case "expr": {
          moduleIndex++;
          const inputNames = [...(node.inputs ?? [])];
          const inputKinds = inputNames.map((_, i) =>
            normalizePortKind(node.inputKinds?.[i] ?? "number"),
          );
          const params = { ...(node.params ?? {}) };
          const paramNames = Object.keys(params);
          for (const name of paramNames) assertFiniteScalar(params[name], `param '${node.id}.${name}'`);

          const allNames = [...inputNames, ...paramNames];
          const compiledExpr = rewriteExprForBoundary(node.expr, allNames);
          progress?.({
            stage: "compile",
            message: `Compiling ${node.id} · module ${moduleIndex} of ${totalModules}`,
            nodeId: node.id,
            nodeKind: "expr",
            index: moduleIndex,
            total: totalModules,
          });
          const compiled = await compileCached(options.compiler, compiledExpr, allNames.length);
          const resultTag = compiled.manifest?.result_tag ?? "number";
          const outputKind = normalizePortKind(node.outputKind ?? resultTagToPortKind(resultTag));
          const scalarOnly = outputKind === "number" && inputKinds.every((k) => k === "number");

          if (!scalarOnly) ensureHost();

          progress?.({
            stage: "instantiate",
            message: `Instantiating ${node.id} · module ${moduleIndex} of ${totalModules}`,
            nodeId: node.id,
            nodeKind: "expr",
            index: moduleIndex,
            total: totalModules,
          });
          const imports = buildImports(host, scalarEnv, compiled.manifest);
          const instance = await WebAssembly.instantiate(compiled.module, imports);
          const exports = asWasmExports(instance, node.id);

          if (host) {
            host.attachMemory(exports.memory ?? null);
            host.attachInstance(instance.exports as Record<string, unknown>);
          }

          loaded.set(node.id, {
            kind: "expr",
            id: node.id,
            expr: node.expr,
            inputNames,
            inputKinds,
            paramNames,
            params,
            outputKind,
            resultTag,
            instance,
            exports,
            scalarOnly,
            manifest: compiled.manifest,
          });
          break;
        }
        case "wasm": {
          moduleIndex++;
          progress?.({
            stage: "compile",
            message: `Loading WASM ${node.id} · module ${moduleIndex} of ${totalModules}`,
            nodeId: node.id,
            nodeKind: "wasm",
            index: moduleIndex,
            total: totalModules,
          });
          const bytes = await resolveWasmBytes(node.wasm);
          const module = await WebAssembly.compile(bytes);
          const abiManifest = readAbiManifest(module);
          const nodeManifest = node.manifest ?? readNodeManifest(module);
          if (!nodeManifest) {
            throw new Error(
              `Wasm node '${node.id}' has no node manifest (pass manifest or compile with --node).`,
            );
          }

          const inputNames = nodeManifest.inputs.map((p) => p.name);
          const inputKinds = nodeManifest.inputs.map((p) => normalizePortKind(p.kind));
          const paramNames = nodeManifest.params.map((p) => p.name);
          const params: Record<string, number> = {};
          for (const p of nodeManifest.params) {
            const override = node.params?.[p.name];
            const def = p.default;
            params[p.name] = assertFiniteScalar(
              override ?? (def ?? 0),
              `param '${node.id}.${p.name}'`,
            );
          }
          if (node.params) {
            for (const [k, v] of Object.entries(node.params)) {
              if (!Object.hasOwn(params, k)) {
                params[k] = assertFiniteScalar(v, `param '${node.id}.${k}'`);
              }
            }
          }

          const outputKind = normalizePortKind(
            nodeManifest.output.kind ?? nodeManifest.output.result_tag ?? "number",
          );
          const resultTag =
            nodeManifest.output.result_tag ?? abiManifest?.result_tag ?? kindToTag(outputKind);
          const scalarOnly = outputKind === "number" && inputKinds.every((k) => k === "number");
          if (!scalarOnly) ensureHost();

          // Re-validate ports now that the manifest is known.
          validateWasmPorts(node.id, nodeManifest, topology);

          progress?.({
            stage: "instantiate",
            message: `Instantiating ${node.id} · module ${moduleIndex} of ${totalModules}`,
            nodeId: node.id,
            nodeKind: "wasm",
            index: moduleIndex,
            total: totalModules,
          });
          const imports = buildImports(host, scalarEnv, abiManifest);
          const instance = await WebAssembly.instantiate(module, imports);
          const exports = asWasmExports(instance, node.id);

          if (host) {
            host.attachMemory(exports.memory ?? null);
            host.attachInstance(instance.exports as Record<string, unknown>);
          }

          // Type-check edges into this wasm node with known kinds.
          for (const [port, source] of topology.incoming.get(node.id) ?? []) {
            const srcLoaded = loaded.get(source.nodeId);
            const producerKind = srcLoaded?.outputKind ?? "number";
            const idx = inputNames.indexOf(port);
            const consumerKind = idx >= 0 ? inputKinds[idx]! : "number";
            if (!kindsCompatible(producerKind, consumerKind)) {
              throw new Error(
                `Kind mismatch on edge '${source.nodeId}.out' → '${node.id}.${port}': producer '${producerKind}' vs consumer '${consumerKind}'.`,
              );
            }
          }

          loaded.set(node.id, {
            kind: "wasm",
            id: node.id,
            inputNames,
            inputKinds,
            paramNames,
            params,
            outputKind,
            resultTag,
            instance,
            exports,
            scalarOnly,
            nodeManifest,
            abiManifest,
          });
          break;
        }
      }
    }

    progress?.({
      stage: "ready",
      message:
        totalModules > 0
          ? `Compiled · ${totalModules} WASM module${totalModules === 1 ? "" : "s"} loaded`
          : "Graph runtime ready",
      total: totalModules,
    });
    return new GraphRunner(normalized, topology, loaded, host, scalarEnv, options.compiler);
  }

  /**
   * Hot single-tick path (task-10 tick plan). No per-node timers / profile arrays.
   * For profiling UI, use {@link runProfiled}.
   */
  run(inputs: GraphRunInputs = {}): GraphRunOutputs {
    const plan = this.plan ?? this.rebuildPlan();

    // Pure-scalar fast path: no Map/object churn, pre-hoisted evals.
    if (plan.allNumber) {
      const slots = this.scalarSlots;
      for (const inp of plan.inputs) {
        const value = inputs[inp.name];
        if (value === undefined) throw new Error(`Missing graph input '${inp.name}'.`);
        slots[inp.slot] = assertFiniteScalar(value, `input '${inp.name}'`);
      }
      for (const c of plan.consts) {
        slots[c.slot] = c.value as number;
      }
      for (const step of plan.computes) {
        slots[step.slot] = this.evalComputeScalar(step, slots);
      }
      const outputs: GraphRunOutputs = {};
      for (const out of plan.outputs) {
        outputs[out.name] = slots[out.slot]!;
      }
      return outputs;
    }

    // Full-Value path: reuse dense valueSlots array (no per-tick Map alloc).
    // Track durable host handles so series/matrix/record stores stay flat across ticks.
    this.host?.beginTick();
    const values = this.valueSlots;
    for (let i = 0; i < plan.slotCount; i++) values[i] = undefined;

    try {
      for (const inp of plan.inputs) {
        const value = inputs[inp.name];
        if (value === undefined) throw new Error(`Missing graph input '${inp.name}'.`);
        if (inp.outputKind === "number") {
          values[inp.slot] = assertFiniteScalar(value, `input '${inp.name}'`);
        } else {
          values[inp.slot] = value;
        }
      }
      for (const c of plan.consts) {
        values[c.slot] = c.value;
      }
      for (const step of plan.computes) {
        values[step.slot] = this.evalComputePlanned(step, values);
      }

      const outputs: GraphRunOutputs = {};
      for (const out of plan.outputs) {
        const v = values[out.slot];
        if (v === undefined) {
          throw new Error(`Output '${out.name}' has no value.`);
        }
        outputs[out.name] = v;
      }
      this.host?.endTick(collectLiveHandles(outputs));
      return outputs;
    } catch (e) {
      // Failed tick: drop tick-created handles; do not retain partial outputs.
      this.host?.endTick([]);
      throw e;
    }
  }

  /**
   * Test-only observability: live host handle counts, wasm pages per instance.
   * Not a public product API — used by soak / leak regressions (task-16).
   */
  debugStats(): GraphRunnerDebugStats {
    const wasmMemoryPagesByNode: Record<string, number> = {};
    let exprInstanceCount = 0;
    let wasmInstanceCount = 0;
    let maxWasmMemoryPages = 0;
    for (const node of this.nodes.values()) {
      if (node.kind !== "expr" && node.kind !== "wasm") continue;
      if (node.kind === "expr") exprInstanceCount++;
      else wasmInstanceCount++;
      const mem = node.exports.memory;
      const pages = mem ? Math.floor(mem.buffer.byteLength / 65536) : 0;
      wasmMemoryPagesByNode[node.id] = pages;
      if (pages > maxWasmMemoryPages) maxWasmMemoryPages = pages;
    }
    return {
      instanceCount: exprInstanceCount + wasmInstanceCount,
      exprInstanceCount,
      wasmInstanceCount,
      wasmMemoryPagesByNode,
      maxWasmMemoryPages,
      host: this.host ? this.host.debugStats() : null,
    };
  }

  /** Shared host env (null for pure-scalar graphs). Test/injection use. */
  getHost(): AotHostEnv | null {
    return this.host;
  }

  /**
   * Run the graph and collect per-compute-node wall times (ms) for profiling UI.
   * Same evaluation as {@link run}, plus `performance.now` per compute node.
   * Not for microbench / hot ticks — use {@link run} or {@link runBatch}.
   */
  runProfiled(inputs: GraphRunInputs = {}): GraphProfiledRun {
    const plan = this.plan ?? this.rebuildPlan();
    const nodes: GraphNodeTiming[] = [];
    const t0 = performance.now();

    // Pure-scalar path with per-node timers (UI only).
    if (plan.allNumber) {
      const slots = this.scalarSlots;
      for (const inp of plan.inputs) {
        const value = inputs[inp.name];
        if (value === undefined) throw new Error(`Missing graph input '${inp.name}'.`);
        slots[inp.slot] = assertFiniteScalar(value, `input '${inp.name}'`);
      }
      for (const c of plan.consts) {
        slots[c.slot] = c.value as number;
      }
      for (const step of plan.computes) {
        const s = performance.now();
        slots[step.slot] = this.evalComputeScalar(step, slots);
        nodes.push({
          nodeId: step.node.id,
          kind: step.node.kind,
          ms: performance.now() - s,
        });
      }
      const outputs: GraphRunOutputs = {};
      for (const out of plan.outputs) {
        outputs[out.name] = slots[out.slot]!;
      }
      return { outputs, totalMs: performance.now() - t0, nodes };
    }

    // Full-Value path with per-node timers (UI only).
    this.host?.beginTick();
    const values = this.valueSlots;
    for (let i = 0; i < plan.slotCount; i++) values[i] = undefined;

    try {
      for (const inp of plan.inputs) {
        const value = inputs[inp.name];
        if (value === undefined) throw new Error(`Missing graph input '${inp.name}'.`);
        if (inp.outputKind === "number") {
          values[inp.slot] = assertFiniteScalar(value, `input '${inp.name}'`);
        } else {
          values[inp.slot] = value;
        }
      }
      for (const c of plan.consts) {
        values[c.slot] = c.value;
      }
      for (const step of plan.computes) {
        const s = performance.now();
        values[step.slot] = this.evalComputePlanned(step, values);
        nodes.push({
          nodeId: step.node.id,
          kind: step.node.kind,
          ms: performance.now() - s,
        });
      }

      const outputs: GraphRunOutputs = {};
      for (const out of plan.outputs) {
        const v = values[out.slot];
        if (v === undefined) {
          throw new Error(`Output '${out.name}' has no value.`);
        }
        outputs[out.name] = v;
      }
      this.host?.endTick(collectLiveHandles(outputs));
      return { outputs, totalMs: performance.now() - t0, nodes };
    } catch (e) {
      this.host?.endTick([]);
      throw e;
    }
  }

  /**
   * Batch-evaluate the graph for `n` ticks with per-input Float64Array lanes.
   *
   * - Scalar path: zero per-tick allocation (lanes + preallocated slot scratch only).
   * - Non-scalar edges keep the host-mediated per-tick copy protocol; only
   *   number-kind graph outputs are written to output lanes.
   * - Numerically: `outputLanes[name][i] === run({...inputs_i})[name]` for all i.
   */
  runBatch(inputLanes: GraphBatchLanes, n: number): GraphBatchLanes {
    if (!Number.isInteger(n) || n < 0) {
      throw new Error(`runBatch: n must be a non-negative integer (got ${n}).`);
    }
    const plan = this.plan ?? this.rebuildPlan();
    if (!plan.outputsAreNumber) {
      throw new Error(
        "runBatch requires all graph outputs to be number-kind; non-scalar outputs keep run().",
      );
    }
    for (const inp of plan.inputs) {
      if (inp.outputKind !== "number") {
        throw new Error(
          `runBatch: input '${inp.name}' is kind '${inp.outputKind}'; only number inputs accepted in lanes.`,
        );
      }
      const lane = inputLanes[inp.name];
      if (!lane) throw new Error(`runBatch: missing input lane '${inp.name}'.`);
      if (lane.length < n) {
        throw new Error(
          `runBatch: input lane '${inp.name}' length ${lane.length} < n=${n}.`,
        );
      }
    }

    const outputLanes: GraphBatchLanes = {};
    for (const out of plan.outputs) {
      outputLanes[out.name] = new Float64Array(n);
    }
    if (n === 0) return outputLanes;

    if (plan.allNumber) {
      this.runBatchScalar(plan, inputLanes, outputLanes, n);
    } else {
      this.runBatchMixed(plan, inputLanes, outputLanes, n);
    }
    return outputLanes;
  }

  /**
   * Update a runtime-tunable number param (host-side store; next tick picks it up).
   * Validates node id and param name against the loaded node's param list.
   */
  setParam(nodeId: string, name: string, value: number): void {
    const node = this.mustNode(nodeId);
    if (node.kind !== "expr" && node.kind !== "wasm") {
      throw new Error(`Node '${nodeId}' does not have params.`);
    }
    // Validate against the declared param names (manifest / graph params).
    if (!node.paramNames.includes(name) || !Object.hasOwn(node.params, name)) {
      const known = node.paramNames.length > 0 ? node.paramNames.join(", ") : "(none)";
      throw new Error(`Node '${nodeId}' has no param '${name}'. Known params: ${known}.`);
    }
    node.params[name] = assertFiniteScalar(value, `param '${nodeId}.${name}'`);
  }

  /**
   * List runtime-tunable number params for UI (sliders). Values are current host store.
   */
  listParams(): Array<{ nodeId: string; name: string; value: number }> {
    const out: Array<{ nodeId: string; name: string; value: number }> = [];
    for (const node of this.nodes.values()) {
      if (node.kind !== "expr" && node.kind !== "wasm") continue;
      for (const name of node.paramNames) {
        out.push({ nodeId: node.id, name, value: node.params[name]! });
      }
    }
    return out;
  }

  /** Snapshot of the normalized graph definition (expr strings may update after reload). */
  getDefinition(): NormalizedGraphDefinition {
    return {
      nodes: this.def.nodes.map((n) => ({ ...n })),
      edges: this.def.edges.map((e) => ({ ...e })),
      outputs: { ...this.def.outputs },
    };
  }

  /**
   * Hot-reload one expr node: recompile via injected compiler + compile cache,
   * require compatible ports (same input names/kinds + output kind), preserve
   * current param values. On incompatibility, reject and keep the graph running
   * with the previous module.
   */
  async reload(nodeId: string, expr: string): Promise<void> {
    const node = this.mustNode(nodeId);
    if (node.kind !== "expr") {
      throw new Error(`reload() only supports expr nodes; '${nodeId}' is '${node.kind}'.`);
    }
    if (typeof expr !== "string" || expr.trim().length === 0) {
      throw new Error(`reload('${nodeId}'): expr must be a non-empty string.`);
    }

    const allNames = [...node.inputNames, ...node.paramNames];
    const compiledExpr = rewriteExprForBoundary(expr, allNames);
    const compiled = await compileCached(this.compiler, compiledExpr, allNames.length);
    const newResultTag = compiled.manifest?.result_tag ?? "number";
    const newOutputKind = resultTagToPortKind(newResultTag);

    // Port compatibility: inputs fixed by graph wiring; output kind must match.
    const oldPorts = formatPortList(node.inputNames, node.inputKinds, node.outputKind);
    const newPorts = formatPortList(node.inputNames, node.inputKinds, newOutputKind);
    if (!kindsCompatible(node.outputKind, newOutputKind)) {
      throw new Error(
        `reload('${nodeId}') rejected: incompatible ports.\n` +
          `  current: ${oldPorts}\n` +
          `  new:     ${newPorts}`,
      );
    }

    // Also reject when a declared outputKind on the graph definition would disagree
    // (expr nodes may pin outputKind in the def).
    const defNode = this.def.nodes.find((n) => n.id === nodeId);
    if (defNode && defNode.type === "expr" && defNode.outputKind) {
      const pinned = normalizePortKind(defNode.outputKind);
      if (!kindsCompatible(pinned, newOutputKind)) {
        throw new Error(
          `reload('${nodeId}') rejected: new result '${newOutputKind}' is incompatible with declared outputKind '${pinned}'.\n` +
            `  current: ${oldPorts}\n` +
            `  new:     ${newPorts}`,
        );
      }
    }

    // Downstream consumers of this node's .out must still accept the new kind.
    // (kindsCompatible is symmetric for number/boolean; same kind otherwise.)
    for (const other of this.def.nodes) {
      if (other.type !== "expr" && other.type !== "wasm") continue;
      const incoming = this.topology.incoming.get(other.id);
      if (!incoming) continue;
      for (const [port, source] of incoming) {
        if (source.nodeId !== nodeId) continue;
        const consumerKind =
          other.type === "expr"
            ? nodeInputKind(other, port)
            : other.manifest
              ? nodeInputKind(other, port)
              : (() => {
                  const loaded = this.nodes.get(other.id);
                  if (loaded && (loaded.kind === "expr" || loaded.kind === "wasm")) {
                    const idx = loaded.inputNames.indexOf(port);
                    return idx >= 0 ? loaded.inputKinds[idx]! : null;
                  }
                  return null;
                })();
        if (consumerKind && !kindsCompatible(newOutputKind, consumerKind)) {
          throw new Error(
            `reload('${nodeId}') rejected: downstream edge '${nodeId}.out' → '${other.id}.${port}' ` +
              `needs '${consumerKind}', new output is '${newOutputKind}'.\n` +
              `  current: ${oldPorts}\n` +
              `  new:     ${newPorts}`,
          );
        }
      }
    }

    const scalarOnly = newOutputKind === "number" && node.inputKinds.every((k) => k === "number");
    if (!scalarOnly && !this.host) {
      this.host = new AotHostEnv();
      this.scalarEnv = null;
    }

    const imports = buildImports(this.host, this.scalarEnv, compiled.manifest);
    const instance = await WebAssembly.instantiate(compiled.module, imports);
    const exports = asWasmExports(instance, nodeId);

    if (this.host) {
      this.host.attachMemory(exports.memory ?? null);
      this.host.attachInstance(instance.exports as Record<string, unknown>);
    }

    // Preserve params (same names); swap module instance.
    const preservedParams = { ...node.params };
    this.nodes.set(nodeId, {
      kind: "expr",
      id: nodeId,
      expr,
      inputNames: node.inputNames,
      inputKinds: node.inputKinds,
      paramNames: node.paramNames,
      params: preservedParams,
      outputKind: node.outputKind, // keep declared graph kind; wire tag may refine
      resultTag: newResultTag,
      instance,
      exports,
      scalarOnly,
      manifest: compiled.manifest,
    });

    // Keep definition in sync for getDefinition / demo UI.
    if (defNode && defNode.type === "expr") {
      defNode.expr = expr;
    }

    this.rebuildPlan();
  }

  dispose(): void {
    this.nodes.clear();
    this.plan = null;
  }

  /** Rebuild hoisted tick plan after load / reload / setParam-affecting structure. */
  private rebuildPlan(): TickPlan {
    const ordered = this.topology.ordered;
    const slotOf = new Map<GraphNodeId, number>();
    let slot = 0;
    for (const n of ordered) slotOf.set(n.id, slot++);

    const inputs: InputPlan[] = [];
    const consts: ConstPlan[] = [];
    const computes: ComputePlan[] = [];
    let allNumber = true;

    for (const nodeDef of ordered) {
      const node = this.mustNode(nodeDef.id);
      const s = slotOf.get(node.id)!;
      switch (node.kind) {
        case "input":
          inputs.push({ slot: s, name: node.name, outputKind: node.outputKind });
          if (node.outputKind !== "number") allNumber = false;
          break;
        case "const":
          consts.push({
            slot: s,
            value: node.value,
            outputKind: node.outputKind,
            isNumber: node.outputKind === "number" && typeof node.value === "number",
          });
          if (node.outputKind !== "number" || typeof node.value !== "number") allNumber = false;
          break;
        case "expr":
        case "wasm": {
          if (!node.scalarOnly || node.outputKind !== "number") allNumber = false;
          const incoming = this.topology.incoming.get(node.id)!;
          const inputSlots: number[] = [];
          for (let i = 0; i < node.inputNames.length; i++) {
            const port = node.inputNames[i]!;
            const source = incoming.get(port);
            if (!source) {
              throw new Error(`Node '${node.id}' input '${port}' is not connected.`);
            }
            const srcSlot = slotOf.get(source.nodeId);
            if (srcSlot === undefined) {
              throw new Error(`Node '${node.id}' input '${port}' source not in plan.`);
            }
            inputSlots.push(srcSlot);
            if (node.inputKinds[i] !== "number") allNumber = false;
          }
          const arity = node.inputNames.length + node.paramNames.length;
          computes.push({
            slot: s,
            node,
            eval: node.exports.eval,
            resetHeap: node.exports.reset_heap,
            inputSlots,
            inputKinds: node.inputKinds,
            paramNames: node.paramNames,
            argsBuf: new Float64Array(arity),
            arity,
            scalarOnly: node.scalarOnly,
            outputKind: node.outputKind,
            resultTag: node.resultTag,
          });
          break;
        }
      }
    }

    const outputs: OutputPlan[] = [];
    let outputsAreNumber = true;
    for (const [name, ref] of Object.entries(this.def.outputs)) {
      const parsed = parseGraphRef(ref);
      if (parsed.port !== "out") throw new Error(`Output '${name}' must reference '<node>.out'.`);
      const outSlot = slotOf.get(parsed.nodeId);
      if (outSlot === undefined) {
        throw new Error(`Output '${name}' references unknown node '${parsed.nodeId}'.`);
      }
      const outNode = this.mustNode(parsed.nodeId);
      const kind = outNode.outputKind;
      if (kind !== "number") outputsAreNumber = false;
      outputs.push({ name, slot: outSlot, outputKind: kind });
    }

    const plan: TickPlan = {
      slotOf,
      slotCount: slot,
      inputs,
      consts,
      computes,
      outputs,
      allNumber,
      outputsAreNumber,
    };
    this.plan = plan;
    this.scalarSlots = new Float64Array(slot);
    // Ensure valueSlots length
    this.valueSlots.length = slot;
    return plan;
  }

  /** Pure-scalar compute: read f64 slots, call hoisted eval, no host. */
  private evalComputeScalar(step: ComputePlan, slots: Float64Array): number {
    const node = step.node;
    const buf = step.argsBuf;
    const nIn = step.inputSlots.length;
    for (let i = 0; i < nIn; i++) {
      buf[i] = slots[step.inputSlots[i]!]!;
    }
    for (let p = 0; p < step.paramNames.length; p++) {
      buf[nIn + p] = node.params[step.paramNames[p]!]!;
    }
    return callEval(step.eval, buf, step.arity);
  }

  /** Full-Value / mixed compute using dense valueSlots. */
  private evalComputePlanned(
    step: ComputePlan,
    values: Array<GraphValue | undefined>,
  ): GraphValue {
    const node = step.node;
    const host = this.host;

    try {
      if (host) {
        host.attachMemory(node.exports.memory ?? null);
        host.attachInstance(node.instance.exports as Record<string, unknown>);
        const strings =
          node.kind === "expr" ? node.manifest?.strings : node.abiManifest?.strings;
        host.useStringTable(strings);
      }
      step.resetHeap?.();

      const buf = step.argsBuf;
      const nIn = step.inputSlots.length;
      for (let i = 0; i < nIn; i++) {
        const port = node.inputNames[i]!;
        const portKind = step.inputKinds[i]!;
        const srcVal = values[step.inputSlots[i]!]!;
        if (srcVal === undefined) {
          throw new Error(`Node '${node.id}' input '${port}' has no value.`);
        }
        if (portKind === "number") {
          buf[i] = assertFiniteScalar(srcVal, `edge → ${node.id}.${port}`);
        } else if (host) {
          buf[i] = writeWireValue(host, node.exports, portKind, srcVal);
        } else {
          throw new Error(`Node '${node.id}' needs full-Value host for kind '${portKind}'.`);
        }
      }
      for (let p = 0; p < step.paramNames.length; p++) {
        buf[nIn + p] = node.params[step.paramNames[p]!]!;
      }

      const raw = callEval(step.eval, buf, step.arity);

      if (step.outputKind === "number") {
        return assertFiniteScalar(raw, `node '${node.id}' output`);
      }
      if (!host) throw new Error(`Node '${node.id}' produced non-scalar without host env.`);
      try {
        return readWireValue(host, node.exports, step.outputKind, raw, step.resultTag);
      } catch (e) {
        if (isAllocFailure(e)) throw new GraphAllocError(node.id, e);
        const msg = e instanceof Error ? e.message : String(e);
        throw new Error(`Node '${node.id}' (${step.outputKind}): ${msg}`);
      }
    } catch (e) {
      if (e instanceof GraphAllocError) throw e;
      if (isAllocFailure(e)) throw new GraphAllocError(node.id, e);
      throw e;
    }
  }

  /**
   * Zero per-tick allocation scalar batch: only writes into preallocated
   * scalarSlots + caller-provided / once-allocated output lanes.
   */
  private runBatchScalar(
    plan: TickPlan,
    inputLanes: GraphBatchLanes,
    outputLanes: GraphBatchLanes,
    n: number,
  ): void {
    const slots = this.scalarSlots;
    const computes = plan.computes;
    const inputs = plan.inputs;
    const consts = plan.consts;
    const outputs = plan.outputs;

    // Consts never change across the batch — seed once outside the loop.
    for (const c of consts) {
      slots[c.slot] = c.value as number;
    }

    // Hoist lane refs to avoid Record lookup per tick.
    const inLaneRefs: Float64Array[] = inputs.map((inp) => inputLanes[inp.name]!);
    const inSlots: number[] = inputs.map((inp) => inp.slot);
    const outLaneRefs: Float64Array[] = outputs.map((o) => outputLanes[o.name]!);
    const outSlots: number[] = outputs.map((o) => o.slot);

    for (let t = 0; t < n; t++) {
      for (let i = 0; i < inputs.length; i++) {
        slots[inSlots[i]!] = inLaneRefs[i]![t]!;
      }
      for (let c = 0; c < computes.length; c++) {
        const step = computes[c]!;
        slots[step.slot] = this.evalComputeScalar(step, slots);
      }
      for (let o = 0; o < outputs.length; o++) {
        outLaneRefs[o]![t] = slots[outSlots[o]!]!;
      }
    }
  }

  /**
   * Mixed/non-scalar batch: number inputs come from lanes; non-scalar edges
   * use the same host-mediated copy protocol as run() (per-tick, intentional).
   */
  private runBatchMixed(
    plan: TickPlan,
    inputLanes: GraphBatchLanes,
    outputLanes: GraphBatchLanes,
    n: number,
  ): void {
    const values = this.valueSlots;
    const outLaneRefs: Float64Array[] = plan.outputs.map((o) => outputLanes[o.name]!);

    for (let t = 0; t < n; t++) {
      this.host?.beginTick();
      for (let i = 0; i < plan.slotCount; i++) values[i] = undefined;

      try {
        for (const inp of plan.inputs) {
          // Only number inputs accepted (validated in runBatch).
          values[inp.slot] = inputLanes[inp.name]![t]!;
        }
        for (const c of plan.consts) {
          values[c.slot] = c.value;
        }
        for (const step of plan.computes) {
          values[step.slot] = this.evalComputePlanned(step, values);
        }
        for (let o = 0; o < plan.outputs.length; o++) {
          const out = plan.outputs[o]!;
          const v = values[out.slot];
          outLaneRefs[o]![t] = assertFiniteScalar(v as GraphValue, `output '${out.name}'`);
        }
        // Batch number outputs only — no durable handle retention across batch ticks.
        this.host?.endTick([]);
      } catch (e) {
        this.host?.endTick([]);
        throw e;
      }
    }
  }

  private mustNode(nodeId: string): LoadedNode {
    const node = this.nodes.get(nodeId);
    if (!node) throw new Error(`Unknown graph node '${nodeId}'.`);
    return node;
  }
}

/** Call wasm eval without allocating an args array (arity ≤ 3 is the graph boundary). */
function callEval(fn: (...args: number[]) => number, buf: Float64Array, arity: number): number {
  switch (arity) {
    case 0:
      return fn();
    case 1:
      return fn(buf[0]!);
    case 2:
      return fn(buf[0]!, buf[1]!);
    case 3:
      return fn(buf[0]!, buf[1]!, buf[2]!);
    default: {
      // Defensive: boundary is x/y/z so arity ≤ 3; keep a correct fallback.
      const args = new Array<number>(arity);
      for (let i = 0; i < arity; i++) args[i] = buf[i]!;
      return fn(...args);
    }
  }
}

// ── helpers ───────────────────────────────────────────────────────────────

function isAllocFailure(e: unknown): boolean {
  if (e instanceof AllocFailureError) return true;
  if (e instanceof GraphAllocError) return true;
  if (e && typeof e === "object" && (e as { code?: string }).code === "AllocFailure") return true;
  if (e instanceof Error && e.name === "AllocFailureError") return true;
  return false;
}

/** Collect durable host handle ids present in graph outputs (for endTick GC). */
function collectLiveHandles(outputs: GraphRunOutputs): number[] {
  const ids: number[] = [];
  for (const v of Object.values(outputs)) {
    if (v && typeof v === "object" && "id" in v && typeof (v as { id: unknown }).id === "number") {
      ids.push((v as { id: number }).id);
    }
  }
  return ids;
}

function graphNeedsFullValue(nodes: GraphNode[]): boolean {
  for (const node of nodes) {
    if (node.type === "wasm") return true;
    if (node.type === "input" && node.kind && normalizePortKind(node.kind) !== "number") return true;
    if (node.type === "const") {
      if (typeof node.value !== "number") return true;
      if (node.kind && normalizePortKind(node.kind) !== "number") return true;
    }
    if (node.type === "expr") {
      if (node.outputKind && normalizePortKind(node.outputKind) !== "number") return true;
      if (node.inputKinds?.some((k) => normalizePortKind(k) !== "number")) return true;
    }
  }
  return false;
}

function buildImports(
  host: AotHostEnv | null,
  scalarEnv: ScalarWasmImports | null,
  manifest: AotAbiManifest | null,
): Record<string, unknown> {
  if (host) return { env: host.buildEnvForManifest(manifest) };
  return scalarEnv ?? createDefaultScalarWasmImports();
}

function asWasmExports(instance: WebAssembly.Instance, nodeId: string): WasmNodeExports {
  const evalFn = instance.exports.eval;
  if (typeof evalFn !== "function") throw new Error(`Node '${nodeId}' module does not export eval.`);
  const reset = instance.exports.reset_heap;
  const alloc = instance.exports.alloc;
  return {
    memory: instance.exports.memory as WebAssembly.Memory | undefined,
    alloc: typeof alloc === "function" ? (alloc as (n: number) => number) : undefined,
    reset_heap: typeof reset === "function" ? (reset as () => void) : undefined,
    eval: evalFn as (...args: number[]) => number,
    heap_ptr: instance.exports.heap_ptr as WebAssembly.Global | undefined,
  };
}

function validateNodePorts(def: NormalizedGraphDefinition, topology: Topology): void {
  for (const node of def.nodes) {
    if (node.type === "expr") {
      const declared = new Set(node.inputs ?? []);
      const params = new Set(Object.keys(node.params ?? {}));
      const total = declared.size + params.size;
      if (total > GRAPH_ALIAS_LIMIT) {
        throw new Error(
          `${ALIAS_LIMIT_ERROR}: Expr node '${node.id}' has ${total} inputs/params; limit is ${GRAPH_ALIAS_LIMIT}.`,
        );
      }
      for (const param of params) {
        if (declared.has(param)) {
          throw new Error(`Expr node '${node.id}' uses '${param}' as both input and param.`);
        }
      }
      for (const port of topology.incoming.get(node.id)?.keys() ?? []) {
        if (!declared.has(port)) {
          throw new Error(`Expr node '${node.id}' has undeclared input port '${port}'.`);
        }
      }
      for (const port of declared) {
        if (!topology.incoming.get(node.id)?.has(port)) {
          throw new Error(`Expr node '${node.id}' input '${port}' is not connected.`);
        }
      }
    } else if (node.type === "wasm" && node.manifest) {
      validateWasmPorts(node.id, node.manifest, topology);
    }
  }
}

function validateWasmPorts(nodeId: string, manifest: NodeManifest, topology: Topology): void {
  const declared = new Set(manifest.inputs.map((p) => p.name));
  for (const port of topology.incoming.get(nodeId)?.keys() ?? []) {
    if (!declared.has(port)) {
      throw new Error(`Wasm node '${nodeId}' has undeclared input port '${port}'.`);
    }
  }
  for (const port of declared) {
    if (!topology.incoming.get(nodeId)?.has(port)) {
      throw new Error(`Wasm node '${nodeId}' input '${port}' is not connected.`);
    }
  }
}

function typeCheckEdges(def: NormalizedGraphDefinition, topology: Topology): void {
  const byId = new Map(def.nodes.map((n) => [n.id, n]));
  for (const node of def.nodes) {
    if (node.type !== "expr" && node.type !== "wasm") continue;
    const incoming = topology.incoming.get(node.id);
    if (!incoming) continue;
    for (const [port, source] of incoming) {
      const srcNode = byId.get(source.nodeId);
      if (!srcNode) continue;
      const consumerKind = nodeInputKind(node, port);
      if (!consumerKind) continue;
      // Skip when producer kind is not yet known (expr without outputKind, wasm without manifest).
      if (srcNode.type === "expr" && !srcNode.outputKind) {
        if (consumerKind !== "number" && consumerKind !== "any") {
          // Default producer is number — flag non-number consumer mismatch early.
          if (!kindsCompatible("number", consumerKind)) {
            throw new Error(
              `Kind mismatch on edge '${source.nodeId}.out' → '${node.id}.${port}': producer 'number' vs consumer '${consumerKind}'.`,
            );
          }
        }
        continue;
      }
      if (srcNode.type === "wasm" && !srcNode.manifest) continue;
      const producerKind = nodeOutputKind(srcNode);
      if (!kindsCompatible(producerKind, consumerKind)) {
        throw new Error(
          `Kind mismatch on edge '${source.nodeId}.out' → '${node.id}.${port}': producer '${producerKind}' vs consumer '${consumerKind}'.`,
        );
      }
    }
  }
}

/**
 * Internal only: map host-side input/param names onto AOT boundary aliases
 * (x/y/z). Public graph semantics keep real port names; this never runs for
 * VM-native evaluation. Two-phase rewrite so an original name that collides
 * with an earlier alias (e.g. ports ["sum","bias","x"]) is not double-substituted.
 */
function rewriteExprForBoundary(expr: string, names: string[]): string {
  if (names.length > GRAPH_ALIAS_LIMIT) {
    throw new Error(
      `${ALIAS_LIMIT_ERROR}: Graph supports at most ${GRAPH_ALIAS_LIMIT} parameters per expr node.`,
    );
  }
  // Already in boundary form (identity mapping) — skip.
  if (names.every((name, index) => name === PARAM_ALIASES[index])) return expr;

  let rewritten = expr;
  const placeholders = names.map((_, index) => `__mz_p${index}__`);
  names.forEach((name, index) => {
    rewritten = rewritten.replace(
      new RegExp(`\\b${escapeRegExp(name)}\\b`, "g"),
      placeholders[index]!,
    );
  });
  placeholders.forEach((ph, index) => {
    rewritten = rewritten.replace(new RegExp(escapeRegExp(ph), "g"), PARAM_ALIASES[index]!);
  });
  return rewritten;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function kindToTag(kind: PortKind): string {
  switch (kind) {
    case "matrix":
      return "matrix";
    case "complex":
      return "complex";
    case "record":
      return "record";
    case "series":
      return "series";
    case "string":
      return "string";
    case "boolean":
      return "boolean";
    default:
      return "number";
  }
}

/** Human-readable port summary for reload rejection diffs. */
function formatPortList(
  inputNames: GraphPortName[],
  inputKinds: PortKind[],
  outputKind: PortKind,
): string {
  const inputs =
    inputNames.length === 0
      ? "in=[]"
      : `in=[${inputNames.map((n, i) => `${n}:${inputKinds[i] ?? "number"}`).join(", ")}]`;
  return `${inputs} out=${outputKind}`;
}

export function readNodeManifest(module: WebAssembly.Module): NodeManifest | null {
  const sections = WebAssembly.Module.customSections(module, "mathzig:node");
  if (sections.length === 0) return null;
  return JSON.parse(new TextDecoder().decode(sections[0])) as NodeManifest;
}

async function resolveWasmBytes(wasm: Uint8Array | ArrayBuffer | string): Promise<Uint8Array> {
  if (typeof wasm === "string") {
    // Browser-friendly refs first (data URL / http(s)); Node fs last for file paths.
    if (wasm.startsWith("data:")) {
      const comma = wasm.indexOf(",");
      if (comma < 0) throw new Error("Invalid data URL for WASM module.");
      const meta = wasm.slice(0, comma);
      const payload = wasm.slice(comma + 1);
      if (meta.includes(";base64")) {
        const bin = atob(payload);
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
      }
      return new TextEncoder().encode(decodeURIComponent(payload));
    }
    if (/^https?:\/\//i.test(wasm)) {
      const res = await fetch(wasm);
      if (!res.ok) {
        throw new Error(`Failed to fetch WASM module (${res.status}): ${wasm}`);
      }
      return new Uint8Array(await res.arrayBuffer());
    }
    try {
      const fs = await import("node:fs");
      return new Uint8Array(fs.readFileSync(wasm));
    } catch (e) {
      const msg = String((e as Error)?.message ?? e);
      throw new Error(
        `Cannot load WASM ref '${wasm.slice(0, 80)}${wasm.length > 80 ? "…" : ""}': ${msg}. ` +
          `In the browser, import a .wasm file (data URL) or use an http(s) URL.`,
      );
    }
  }
  if (wasm instanceof Uint8Array) return wasm;
  return new Uint8Array(wasm);
}
