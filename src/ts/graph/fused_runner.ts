/**
 * Fused graph host runner (Spec 04).
 *
 * Instantiates **one** wasm module carrying a `mathzig:graph` custom section,
 * feeds multi input values + runtime params, and returns multi output values
 * as `Record<string, GraphValue>`.
 *
 * Does **not** replace multi-module {@link GraphRunner} (editor path).
 *
 * Browser-safe: no Node builtins. For interim graph→wasm, see
 * {@link compileFused} in `fused_compile.ts` (Node / bun only).
 */

import { AotHostEnv, readAbiManifest, type AotAbiManifest } from "../aot_env";
import {
  createDefaultScalarWasmEnv,
  createDefaultScalarWasmImports,
  type ScalarWasmImports,
} from "./env";
import {
  GraphManifestError,
  readGraphManifest,
  type GraphManifest,
  type GraphOutMode,
} from "./graph_manifest";
import type { GraphRunOutputs } from "./runner";
import {
  assertFiniteScalar,
  type GraphValue,
} from "./schema";
import {
  kindToResultTag,
  normalizePortKind,
  readWireValue,
  writeWireValue,
  type PortKind,
  type WasmNodeExports,
} from "./value_transfer";

// ── WireKind discriminant tags (must match src/wasm/abi.zig) ────────────────

const WIRE_KIND_TAG: Record<number, PortKind> = {
  0: "number",
  1: "boolean",
  2: "matrix",
  3: "complex",
  4: "record",
  5: "string",
  6: "series",
  // 7 = predicate_ptr (abi.WireKind); graph PortKind has no "predicate" — keep
  // as "any" so table-fallback decode does not treat the wire as a bare number.
  7: "any",
  8: "any",
};

export type FusedGraphRunnerOptions = {
  /** Shared full-Value host (matrix/record/series). Optional for pure scalar. */
  host?: AotHostEnv;
  /** Scalar-only env imports. Ignored when `host` is provided. */
  env?: ScalarWasmImports | { env?: Record<string, (...args: number[]) => number> };
};

/**
 * Host API for a single fused graph module (`mathzig:graph`).
 *
 * One `WebAssembly.instantiate` for the whole graph. Params live in a host-side
 * store and flow as trailing f64 args on every tick / out_* call.
 */
export class FusedGraphRunner {
  private constructor(
    readonly manifest: GraphManifest,
    private readonly instance: WebAssembly.Instance,
    private readonly abiManifest: AotAbiManifest | null,
    private readonly host: AotHostEnv | null,
    private readonly nodeExports: WasmNodeExports,
    private readonly entryFn: ((...args: number[]) => number) | null,
    /** Parallel to `manifest.outputs` — null when table mode. */
    private readonly outFns: Array<((...args: number[]) => number) | null>,
    private readonly outMode: GraphOutMode,
    private readonly params: Record<string, number>,
    private readonly arity: number,
    private readonly argsBuf: Float64Array,
  ) {}

  /**
   * Load a fused module. Requires a `mathzig:graph` custom section.
   * Throws a clear error when the section is missing (plain AOT / node modules).
   */
  static async load(
    wasm: Uint8Array | ArrayBuffer | WebAssembly.Module,
    options: FusedGraphRunnerOptions = {},
  ): Promise<FusedGraphRunner> {
    const module =
      wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(wasm);

    const manifest = readGraphManifest(module);
    if (!manifest) {
      throw new GraphManifestError(
        "not a fused graph module: missing custom section 'mathzig:graph' " +
          "(plain AOT / mathzig:node modules use GraphRunner, not FusedGraphRunner)",
      );
    }

    const abiManifest = readAbiManifest(module);
    const outMode: GraphOutMode = manifest.out_mode ?? "table";
    // Full-value host when boundary ports are non-scalar **or** the module
    // imports env builtins outside the pure-scalar libm set (e.g. sum on an
    // intermediate matrix → number-only outs still needs AotHostEnv).
    const needsFullValue =
      graphNeedsFullValue(manifest) || abiImportsNeedAotHost(abiManifest);
    const host: AotHostEnv | null =
      needsFullValue || options.host ? (options.host ?? new AotHostEnv()) : null;
    const scalarEnv: ScalarWasmImports | null = !host
      ? ((options.env as ScalarWasmImports | undefined) ?? createDefaultScalarWasmImports())
      : null;

    const imports = buildImports(host, scalarEnv, abiManifest);
    // Single instantiate for the whole fused graph.
    const instance = await WebAssembly.instantiate(module, imports);

    const memory = instance.exports.memory as WebAssembly.Memory | undefined;
    const alloc = instance.exports.alloc;
    const reset = instance.exports.reset_heap;
    const nodeExports: WasmNodeExports = {
      memory,
      alloc: typeof alloc === "function" ? (alloc as (n: number) => number) : undefined,
      reset_heap: typeof reset === "function" ? (reset as () => void) : undefined,
      // eval is not the fused entry; placeholder for value_transfer helpers.
      eval: (() => NaN) as (...args: number[]) => number,
      heap_ptr: instance.exports.heap_ptr as WebAssembly.Global | undefined,
    };

    if (host) {
      host.attachMemory(memory ?? null);
      host.attachInstance(instance.exports as Record<string, unknown>);
      host.useStringTable(abiManifest?.strings);
    }

    const entryName = manifest.entry ?? "tick";
    const entryRaw = instance.exports[entryName];
    const entryFn =
      typeof entryRaw === "function"
        ? (entryRaw as (...args: number[]) => number)
        : null;

    if (outMode === "table" && !entryFn) {
      throw new Error(
        `Fused module out_mode is 'table' but entry export '${entryName}' is missing.`,
      );
    }

    const outFns: Array<((...args: number[]) => number) | null> = [];
    for (const out of manifest.outputs) {
      if (outMode !== "named_exports") {
        outFns.push(null);
        continue;
      }
      const exportName = out.export ?? `out_${out.name}`;
      const fn = instance.exports[exportName];
      if (typeof fn !== "function") {
        throw new Error(
          `Fused module output '${out.name}' expects export '${exportName}' (out_mode named_exports).`,
        );
      }
      outFns.push(fn as (...args: number[]) => number);
    }

    // Host-side param store: defaults from manifest (runtime-tunable via setParam).
    const params: Record<string, number> = {};
    for (const p of manifest.params) {
      const def = p.default;
      params[p.name] =
        def !== null && def !== undefined && Number.isFinite(def) ? def : 0;
    }

    const arity = manifest.inputs.length + manifest.params.length;
    return new FusedGraphRunner(
      manifest,
      instance,
      abiManifest,
      host,
      nodeExports,
      entryFn,
      outFns,
      outMode,
      params,
      arity,
      new Float64Array(arity),
    );
  }

  /**
   * Run one tick. Keys of `inputs` must cover every manifest input name.
   * `paramOverrides` apply for this call only (do not mutate the param store).
   * Unknown override keys throw (same policy as {@link setParam}).
   */
  run(
    inputs: Record<string, GraphValue> = {},
    paramOverrides?: Record<string, number>,
  ): GraphRunOutputs {
    const buf = this.argsBuf;
    const host = this.host;

    if (host) {
      host.attachMemory(this.nodeExports.memory ?? null);
      host.attachInstance(this.instance.exports as Record<string, unknown>);
      host.useStringTable(this.abiManifest?.strings);
    }
    this.nodeExports.reset_heap?.();

    // Pack inputs then params (manifest order).
    for (let i = 0; i < this.manifest.inputs.length; i++) {
      const port = this.manifest.inputs[i]!;
      const value = inputs[port.name];
      if (value === undefined) {
        throw new Error(`Missing graph input '${port.name}'.`);
      }
      const kind = normalizePortKind(port.kind);
      if (kind === "number") {
        buf[i] = assertFiniteScalar(value, `input '${port.name}'`);
      } else if (kind === "boolean") {
        buf[i] = encodeBooleanInput(value, port.name);
      } else if (host) {
        buf[i] = writeWireValue(host, this.nodeExports, kind, value);
      } else {
        throw new Error(
          `Input '${port.name}' is kind '${kind}'; provide AotHostEnv via FusedGraphRunner.load({ host }).`,
        );
      }
    }

    if (paramOverrides) {
      for (const key of Object.keys(paramOverrides)) {
        if (!Object.hasOwn(this.params, key)) {
          const known =
            this.manifest.params.length > 0
              ? this.manifest.params.map((p) => p.name).join(", ")
              : "(none)";
          throw new Error(
            `Fused graph has no param '${key}' (paramOverrides). Known params: ${known}.`,
          );
        }
      }
    }

    const nIn = this.manifest.inputs.length;
    for (let p = 0; p < this.manifest.params.length; p++) {
      const port = this.manifest.params[p]!;
      const override = paramOverrides?.[port.name];
      const value =
        override !== undefined
          ? assertFiniteScalar(override, `param '${port.name}'`)
          : this.params[port.name]!;
      buf[nIn + p] = value;
    }

    const outputs: GraphRunOutputs = {};

    if (this.outMode === "named_exports") {
      for (let i = 0; i < this.manifest.outputs.length; i++) {
        const out = this.manifest.outputs[i]!;
        const fn = this.outFns[i];
        if (!fn) {
          throw new Error(`Fused output '${out.name}' has no export function.`);
        }
        // Named outs re-run the topo chain per call (Stage A interim); values OK.
        const raw = callArity(fn, buf, this.arity);
        outputs[out.name] = this.decodeOutput(out.name, out.kind, out.result_tag, raw);
      }
      return outputs;
    }

    // table mode: single tick → packed output table in linear memory
    if (!this.entryFn) {
      throw new Error("Fused module has no entry function for table out_mode.");
    }
    const baseRaw = callArity(this.entryFn, buf, this.arity);
    const mem = this.nodeExports.memory;
    if (!mem) {
      throw new Error("Fused table out_mode requires linear memory export.");
    }
    // Wasm linear-memory pointers are unsigned; avoid signed int32 trap on high addrs.
    const base = baseRaw >>> 0;
    const table = readOutputTable(mem, base);
    if (table.length !== this.manifest.outputs.length) {
      throw new Error(
        `Fused output table length ${table.length} != manifest outputs ${this.manifest.outputs.length}.`,
      );
    }
    for (let i = 0; i < this.manifest.outputs.length; i++) {
      const out = this.manifest.outputs[i]!;
      const entry = table[i]!;
      // Prefer manifest kind / result_tag (no regex result-type guessing).
      const kind = out.kind ?? WIRE_KIND_TAG[entry.kind] ?? "number";
      outputs[out.name] = this.decodeOutput(out.name, kind, out.result_tag, entry.wire);
    }
    return outputs;
  }

  /**
   * Pure-number multi-out batch (Spec 07 optional host wrapper).
   *
   * **Not** a fused wasm `tick_batch` / packed multi-lane export: this loops
   * `run()` N times on the host (correctness / API shape). Spec 08 may add a
   * true multi-out packed path if throughput requires it.
   *
   * Requires every graph input and every graph output to be number-kind.
   * Params stay at current host store values (same for all lanes).
   * Lane `i` of each output matches `run({…inputs[i]})` for that output.
   *
   * Non-scalar graphs keep {@link run} (host-written ptrs / one heap per tick).
   */
  runBatch(
    inputLanes: Record<string, Float64Array>,
    n: number,
  ): Record<string, Float64Array> {
    if (!Number.isInteger(n) || n < 0) {
      throw new Error(`runBatch: n must be a non-negative integer (got ${n}).`);
    }
    for (const port of this.manifest.inputs) {
      const kind = normalizePortKind(port.kind);
      if (kind !== "number") {
        throw new Error(
          `runBatch: input '${port.name}' is kind '${kind}'; only number inputs accepted in lanes.`,
        );
      }
      const lane = inputLanes[port.name];
      if (!lane) throw new Error(`runBatch: missing input lane '${port.name}'.`);
      if (lane.length < n) {
        throw new Error(
          `runBatch: input lane '${port.name}' length ${lane.length} < n=${n}.`,
        );
      }
    }
    for (const out of this.manifest.outputs) {
      const kind = normalizePortKind(out.kind);
      if (kind !== "number") {
        throw new Error(
          `runBatch requires all graph outputs to be number-kind; non-scalar outputs keep run().`,
        );
      }
    }

    const outputLanes: Record<string, Float64Array> = {};
    for (const out of this.manifest.outputs) {
      outputLanes[out.name] = new Float64Array(n);
    }
    if (n === 0) return outputLanes;

    // Reuse single-tick packing; pure scalar so no host heap writes needed.
    const inputs: Record<string, number> = {};
    for (let t = 0; t < n; t++) {
      for (const port of this.manifest.inputs) {
        inputs[port.name] = inputLanes[port.name]![t]!;
      }
      const outs = this.run(inputs);
      for (const out of this.manifest.outputs) {
        outputLanes[out.name]![t] = assertFiniteScalar(
          outs[out.name] as GraphValue,
          `output '${out.name}'`,
        );
      }
    }
    return outputLanes;
  }

  /**
   * Update a runtime-tunable param by its **flat** fused name (`nodeId.param`).
   * Does not re-instantiate the module; next `run` picks up the value.
   */
  setParam(name: string, value: number): void {
    if (!Object.hasOwn(this.params, name)) {
      const known =
        this.manifest.params.length > 0
          ? this.manifest.params.map((p) => p.name).join(", ")
          : "(none)";
      throw new Error(
        `Fused graph has no param '${name}'. Known params: ${known}.`,
      );
    }
    this.params[name] = assertFiniteScalar(value, `param '${name}'`);
  }

  /** Current host-side param store (flat names). */
  listParams(): Array<{ name: string; value: number }> {
    return this.manifest.params.map((p) => ({
      name: p.name,
      value: this.params[p.name]!,
    }));
  }

  dispose(): void {
    // Drop host attachment; instance is GC'd with this object.
    this.host?.attachMemory(null);
  }

  private decodeOutput(
    name: string,
    kindRaw: string,
    resultTag: string | undefined,
    raw: number,
  ): GraphValue {
    const kind = normalizePortKind(kindRaw);
    const tag = resultTag ?? kindToResultTag(kind);
    if (kind === "number") {
      return assertFiniteScalar(raw, `output '${name}'`);
    }
    if (kind === "boolean") {
      return raw !== 0;
    }
    if (!this.host) {
      throw new Error(
        `Output '${name}' is kind '${kind}'; provide AotHostEnv via FusedGraphRunner.load({ host }).`,
      );
    }
    return readWireValue(this.host, this.nodeExports, kind, raw, tag);
  }
}

// ── internals ──────────────────────────────────────────────────────────────

function buildImports(
  host: AotHostEnv | null,
  scalarEnv: ScalarWasmImports | null,
  manifest: AotAbiManifest | null,
): Record<string, unknown> {
  if (host) return { env: host.buildEnvForManifest(manifest) };
  // Pure-scalar fused modules often have zero imports; still provide env for
  // modules that pull libm-style builtins without a host.
  if (manifest?.imports && manifest.imports.length > 0) {
    return scalarEnv ?? createDefaultScalarWasmImports();
  }
  return scalarEnv ?? {};
}

function graphNeedsFullValue(manifest: GraphManifest): boolean {
  const check = (kind: string) => {
    const k = normalizePortKind(kind);
    return k !== "number" && k !== "boolean";
  };
  for (const p of manifest.inputs) if (check(p.kind)) return true;
  for (const p of manifest.params) if (check(p.kind)) return true;
  for (const o of manifest.outputs) if (check(o.kind)) return true;
  return false;
}

/**
 * True when `mathzig.abi` imports include builtins not provided by the pure
 * scalar libm env (`createDefaultScalarWasmEnv`). Intermediate matrix/series
 * graphs that only expose number outs still need {@link AotHostEnv} for
 * `sum` / gemm / series / etc.
 */
function abiImportsNeedAotHost(abi: AotAbiManifest | null): boolean {
  if (!abi?.imports?.length) return false;
  // Keys of the default scalar env (pow, sin, …). Built once per process.
  const scalarKeys = SCALAR_ENV_IMPORT_NAMES;
  for (const imp of abi.imports) {
    const name = imp.name;
    if (!name) continue;
    if (!scalarKeys.has(name)) return true;
  }
  return false;
}

/** Import names covered by {@link createDefaultScalarWasmEnv} (no AotHostEnv). */
const SCALAR_ENV_IMPORT_NAMES: ReadonlySet<string> = new Set(
  Object.keys(createDefaultScalarWasmEnv()),
);

/**
 * Boolean ports accept only `boolean | 0 | 1` (strict; no magnitude collapse).
 * Matches a safe subset of `writeWireValue` boolean handling.
 */
function encodeBooleanInput(value: GraphValue, label: string): number {
  if (typeof value === "boolean") return value ? 1 : 0;
  if (value === 0 || value === 1) return value;
  throw new Error(
    `input '${label}' must be boolean | 0 | 1 (got ${typeof value === "number" ? value : typeof value}).`,
  );
}

function callArity(fn: (...args: number[]) => number, buf: Float64Array, arity: number): number {
  switch (arity) {
    case 0:
      return fn();
    case 1:
      return fn(buf[0]!);
    case 2:
      return fn(buf[0]!, buf[1]!);
    case 3:
      return fn(buf[0]!, buf[1]!, buf[2]!);
    case 4:
      return fn(buf[0]!, buf[1]!, buf[2]!, buf[3]!);
    default: {
      const args = new Array<number>(arity);
      for (let i = 0; i < arity; i++) args[i] = buf[i]!;
      return fn(...args);
    }
  }
}

/** Spec 01 output table: [u32 count] × { [u32 kind_tag][f64 wire] }. */
function readOutputTable(
  mem: WebAssembly.Memory,
  base: number,
): Array<{ kind: number; wire: number }> {
  // `base` must already be an unsigned offset (caller uses `>>> 0`).
  if (!Number.isFinite(base) || base + 4 > mem.buffer.byteLength) {
    throw new Error(`Invalid fused output table base ${base}.`);
  }
  const view = new DataView(mem.buffer);
  const count = view.getUint32(base, true);
  if (count > 256) {
    throw new Error(`Fused output table count ${count} looks corrupt.`);
  }
  const need = base + 4 + count * 12;
  if (need > mem.buffer.byteLength) {
    throw new Error(`Fused output table extends past memory (${need} > ${mem.buffer.byteLength}).`);
  }
  const rows: Array<{ kind: number; wire: number }> = [];
  for (let i = 0; i < count; i++) {
    const off = base + 4 + i * 12;
    rows.push({
      kind: view.getUint32(off, true),
      wire: view.getFloat64(off + 4, true),
    });
  }
  return rows;
}
