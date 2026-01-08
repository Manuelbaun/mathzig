/**
 * Fused graph-module manifest (`mathzig:graph` custom section + JSON sidecar).
 *
 * Mirrors `src/wasm/graph_manifest.zig`. Wire kinds reuse the same short names
 * as `mathzig:node` / `abi.WireKind` (number, matrix, …) — no second enum.
 *
 * Multi-value I/O contract (`abi: 1`):
 * - inputs then params (ordered); params may carry `default`
 * - outputs always a list of values; `out_mode` is `"table" | "named_exports"`
 * - table layout: [u32 count] × { [u32 kind_tag][f64 wire] } (names in manifest only)
 */

import { normalizePortKind } from "./value_transfer";
import { MAX_SOURCE_BYTES } from "./limits";
import { ManifestLoadError } from "./load_error";

/** Custom-section name (distinct from `mathzig:node` and `mathzig.abi`). */
export const GRAPH_MANIFEST_SECTION = "mathzig:graph";

/** Graph-manifest ABI version (independent of node-manifest). */
export const GRAPH_ABI_VERSION = 1;

/** Node custom-section name (shared with runner). */
export const NODE_MANIFEST_SECTION = "mathzig:node";

export type GraphOutMode = "table" | "named_exports";

export type GraphManifestPort = {
  name: string;
  kind: string;
  default?: number | null;
};

export type GraphManifestOutput = {
  name: string;
  kind: string;
  result_tag?: string;
  /** Present when `out_mode === "named_exports"`. */
  export?: string;
};

export type GraphManifestExport = {
  name: string;
  params: number;
};

/** Parsed `mathzig:graph` custom section / JSON sidecar. */
export type GraphManifest = {
  abi?: number;
  entry?: string;
  inputs: GraphManifestPort[];
  params: GraphManifestPort[];
  outputs: GraphManifestOutput[];
  out_mode?: GraphOutMode;
  exports?: GraphManifestExport[];
};

/**
 * Graph/node manifest validation failure (`phase: "manifest"`).
 * Extends the shared C3 load-error model.
 */
export class GraphManifestError extends ManifestLoadError {
  constructor(message: string, code = "InvalidManifest", path?: string) {
    super(code, message, path ? { position: { path } } : undefined);
    this.name = "GraphManifestError";
  }
}

/** Raw wasm-bytes scan for a named custom section (S3). */
export type CustomSectionScan =
  | { kind: "absent" }
  | { kind: "malformed_wasm"; reason: string }
  | { kind: "present"; payload: Uint8Array };

/**
 * Scan raw wasm bytes for a named custom section without instantiating.
 * Distinguishes malformed module bytes from an absent section (task-14 S3).
 */
export function scanCustomSectionBytes(
  wasmBytes: Uint8Array,
  sectionName: string,
): CustomSectionScan {
  if (wasmBytes.length < 8) {
    return { kind: "malformed_wasm", reason: "truncated header" };
  }
  if (
    wasmBytes[0] !== 0x00 ||
    wasmBytes[1] !== 0x61 ||
    wasmBytes[2] !== 0x73 ||
    wasmBytes[3] !== 0x6d
  ) {
    return { kind: "malformed_wasm", reason: "bad magic" };
  }
  let i = 8;
  const readLeb = (buf: Uint8Array, start: number): { value: number; next: number } | null => {
    let result = 0;
    let shift = 0;
    let j = start;
    while (j < buf.length) {
      const b = buf[j++]!;
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) === 0) return { value: result >>> 0, next: j };
      shift += 7;
      if (shift > 35) return null;
    }
    return null;
  };
  while (i < wasmBytes.length) {
    const secId = wasmBytes[i++]!;
    const sizeRes = readLeb(wasmBytes, i);
    if (!sizeRes) return { kind: "malformed_wasm", reason: "bad section size LEB" };
    i = sizeRes.next;
    const payloadLen = sizeRes.value;
    if (i + payloadLen > wasmBytes.length) {
      return { kind: "malformed_wasm", reason: "truncated section payload" };
    }
    const payload = wasmBytes.subarray(i, i + payloadLen);
    i += payloadLen;
    if (secId !== 0) continue;
    const nameRes = readLeb(payload, 0);
    if (!nameRes) return { kind: "malformed_wasm", reason: "bad custom-section name LEB" };
    const nameLen = nameRes.value;
    if (nameRes.next + nameLen > payload.length) {
      return { kind: "malformed_wasm", reason: "truncated custom-section name" };
    }
    const name = new TextDecoder().decode(
      payload.subarray(nameRes.next, nameRes.next + nameLen),
    );
    if (name !== sectionName) continue;
    return { kind: "present", payload: payload.subarray(nameRes.next + nameLen) };
  }
  return { kind: "absent" };
}

const OUT_MODES = new Set<string>(["table", "named_exports"]);

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Reuse graph kind table; always throw GraphManifestError (not plain Error). */
function assertKnownKind(kind: string, label: string): void {
  try {
    normalizePortKind(kind);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    throw new GraphManifestError(`${label}: ${msg}`);
  }
}

function assertPort(raw: unknown, label: string, allowDefault: boolean): GraphManifestPort {
  if (!isObject(raw)) throw new GraphManifestError(`${label} must be an object`);
  if (typeof raw.name !== "string" || raw.name.length === 0) {
    throw new GraphManifestError(`${label}.name must be a non-empty string`);
  }
  if (typeof raw.kind !== "string") {
    throw new GraphManifestError(`${label}.kind must be a string`);
  }
  assertKnownKind(raw.kind, `${label}.kind`);
  const port: GraphManifestPort = { name: raw.name, kind: raw.kind };
  if (allowDefault && "default" in raw) {
    const d = raw.default;
    if (d !== null && d !== undefined && typeof d !== "number") {
      throw new GraphManifestError(`${label}.default must be number | null`);
    }
    port.default = d as number | null | undefined;
  }
  return port;
}

function assertOutput(raw: unknown, index: number): GraphManifestOutput {
  if (!isObject(raw)) throw new GraphManifestError(`outputs[${index}] must be an object`);
  if (typeof raw.name !== "string" || raw.name.length === 0) {
    throw new GraphManifestError(`outputs[${index}].name must be a non-empty string`);
  }
  if (typeof raw.kind !== "string") {
    throw new GraphManifestError(`outputs[${index}].kind must be a string`);
  }
  assertKnownKind(raw.kind, `outputs[${index}].kind`);
  const out: GraphManifestOutput = { name: raw.name, kind: raw.kind };
  if (raw.result_tag !== undefined) {
    if (typeof raw.result_tag !== "string") {
      throw new GraphManifestError(`outputs[${index}].result_tag must be a string`);
    }
    out.result_tag = raw.result_tag;
  }
  if (raw.export !== undefined) {
    if (typeof raw.export !== "string") {
      throw new GraphManifestError(`outputs[${index}].export must be a string`);
    }
    out.export = raw.export;
  }
  return out;
}

function assertExport(raw: unknown, index: number): GraphManifestExport {
  if (!isObject(raw)) throw new GraphManifestError(`exports[${index}] must be an object`);
  if (typeof raw.name !== "string") {
    throw new GraphManifestError(`exports[${index}].name must be a string`);
  }
  if (typeof raw.params !== "number" || !Number.isFinite(raw.params)) {
    throw new GraphManifestError(`exports[${index}].params must be a finite number`);
  }
  return { name: raw.name, params: raw.params };
}

/**
 * Structural + kind validation for a parsed (or hand-built) graph manifest.
 * Throws `GraphManifestError` on empty outputs, unknown kinds, or bad shape.
 */
export function validateGraphManifest(raw: unknown): GraphManifest {
  if (!isObject(raw)) throw new GraphManifestError("manifest must be an object");

  const inputsRaw = raw.inputs ?? [];
  const paramsRaw = raw.params ?? [];
  const outputsRaw = raw.outputs;
  if (!Array.isArray(inputsRaw)) throw new GraphManifestError("inputs must be an array");
  if (!Array.isArray(paramsRaw)) throw new GraphManifestError("params must be an array");
  if (!Array.isArray(outputsRaw)) throw new GraphManifestError("outputs must be an array");
  if (outputsRaw.length === 0) throw new GraphManifestError("outputs must be non-empty");

  const inputs = inputsRaw.map((p, i) => assertPort(p, `inputs[${i}]`, false));
  const params = paramsRaw.map((p, i) => assertPort(p, `params[${i}]`, true));
  const outputs = outputsRaw.map((o, i) => assertOutput(o, i));

  // Duplicate port names within inputs, within params, or across both (task-14 S3).
  const seen = new Set<string>();
  for (const p of inputs) {
    if (seen.has(p.name)) {
      throw new GraphManifestError(`duplicate port name '${p.name}'`, "DuplicatePort", `inputs`);
    }
    seen.add(p.name);
  }
  for (const p of params) {
    if (seen.has(p.name)) {
      throw new GraphManifestError(`duplicate port name '${p.name}'`, "DuplicatePort", `params`);
    }
    seen.add(p.name);
  }

  let out_mode: GraphOutMode | undefined;
  if (raw.out_mode !== undefined) {
    if (typeof raw.out_mode !== "string" || !OUT_MODES.has(raw.out_mode)) {
      throw new GraphManifestError(`out_mode must be "table" | "named_exports"`);
    }
    out_mode = raw.out_mode as GraphOutMode;
  }

  let exportsList: GraphManifestExport[] | undefined;
  if (raw.exports !== undefined) {
    if (!Array.isArray(raw.exports)) throw new GraphManifestError("exports must be an array");
    exportsList = raw.exports.map((e, i) => assertExport(e, i));
  }

  const m: GraphManifest = {
    inputs,
    params,
    outputs,
  };
  if (typeof raw.abi === "number") m.abi = raw.abi;
  if (typeof raw.entry === "string") m.entry = raw.entry;
  if (out_mode !== undefined) m.out_mode = out_mode;
  if (exportsList !== undefined) m.exports = exportsList;
  return m;
}

/**
 * Read the `mathzig:graph` custom section from a compiled module.
 * Returns `null` when the section is absent (e.g. single-node or plain AOT).
 * When present, validates structure / kinds (throws `GraphManifestError` if bad).
 */
export function readGraphManifest(module: WebAssembly.Module): GraphManifest | null {
  const sections = WebAssembly.Module.customSections(module, GRAPH_MANIFEST_SECTION);
  if (sections.length === 0) return null;
  const text = new TextDecoder().decode(sections[0]);
  if (text.length > MAX_SOURCE_BYTES) {
    throw new GraphManifestError(
      `manifest JSON exceeds MAX_SOURCE_BYTES (${MAX_SOURCE_BYTES})`,
      "SourceTooLarge",
    );
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new GraphManifestError("manifest section is not valid JSON", "InvalidManifest");
  }
  return validateGraphManifest(parsed);
}

/**
 * S3 raw-bytes entry: scan wasm for `mathzig:graph`, distinguish absent vs
 * malformed wasm, then validate JSON payload.
 *
 * @returns `null` only when the section is **absent** on a well-formed module.
 * @throws `GraphManifestError` with code `MalformedWasm` for bad module bytes,
 *         or other codes for present-but-invalid manifests.
 */
export function readGraphManifestFromBytes(wasmBytes: Uint8Array): GraphManifest | null {
  const scan = scanCustomSectionBytes(wasmBytes, GRAPH_MANIFEST_SECTION);
  if (scan.kind === "absent") return null;
  if (scan.kind === "malformed_wasm") {
    throw new GraphManifestError(`malformed wasm: ${scan.reason}`, "MalformedWasm");
  }
  if (scan.payload.byteLength > MAX_SOURCE_BYTES) {
    throw new GraphManifestError(
      `manifest JSON exceeds MAX_SOURCE_BYTES (${MAX_SOURCE_BYTES})`,
      "SourceTooLarge",
    );
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(scan.payload);
  } catch {
    throw new GraphManifestError("manifest section is not valid UTF-8", "InvalidUtf8");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new GraphManifestError("manifest section is not valid JSON", "InvalidManifest");
  }
  return validateGraphManifest(parsed);
}

/**
 * S3 raw-bytes entry for `mathzig:node` (same absent/malformed distinction).
 * Returns the unvalidated JSON object when present; callers validate shape.
 */
export function readNodeManifestFromBytes(
  wasmBytes: Uint8Array,
): Record<string, unknown> | null {
  const scan = scanCustomSectionBytes(wasmBytes, NODE_MANIFEST_SECTION);
  if (scan.kind === "absent") return null;
  if (scan.kind === "malformed_wasm") {
    throw new GraphManifestError(`malformed wasm: ${scan.reason}`, "MalformedWasm");
  }
  if (scan.payload.byteLength > MAX_SOURCE_BYTES) {
    throw new GraphManifestError(
      `node manifest exceeds MAX_SOURCE_BYTES (${MAX_SOURCE_BYTES})`,
      "SourceTooLarge",
    );
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(scan.payload);
  } catch {
    throw new GraphManifestError("node manifest section is not valid UTF-8", "InvalidUtf8");
  }
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new GraphManifestError("node manifest must be a JSON object", "ManifestNotObject");
    }
    return parsed as Record<string, unknown>;
  } catch (e) {
    if (e instanceof GraphManifestError) throw e;
    throw new GraphManifestError("node manifest section is not valid JSON", "InvalidManifest");
  }
}
