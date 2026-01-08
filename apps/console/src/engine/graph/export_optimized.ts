/**
 * Client helpers for Spec 06 — Export optimized (fused) WASM.
 *
 * Uses pure fuse lowerer for eligibility (browser-safe). Compile happens via
 * POST /api/compile_graph middleware (server shells to mathzig compile-graph).
 * Never import fused_compile / node:child_process / `./node` here.
 *
 * Fuse lowerer is imported via relative path into `src/ts/graph/fuse` (pure TS).
 * The `@mathzig/graph` barrel already omits fused_compile, but bun unit tests
 * under apps/console do not resolve that Vite alias — relative import keeps
 * preflight tests working without pulling Node-only modules.
 */
import {
  FuseError,
  lowerGraphToFusePlan,
  type FusePlan,
} from "../../../../../src/ts/graph/fuse";
import { toRunner } from "./editor_adapter";
import type { EditorDocument, GraphDefinition } from "./editor_types";

export type FuseExportMeta = {
  wasmBytes: number;
  outputCount: number;
  inputCount: number;
  paramCount: number;
  exportCount: number;
  outMode: string;
};

export type FuseExportOk = {
  ok: true;
  plan: FusePlan;
  summary: string;
};

export type FuseExportBlocked = {
  ok: false;
  reasons: string[];
  /** Short single-line reason for button title / badge. */
  reason: string;
};

export type FuseExportSupport = FuseExportOk | FuseExportBlocked;

/**
 * Preflight: can this editor document be fused into one WASM module?
 * Does not call the server — pure lowerer check.
 */
export function checkFuseExportSupport(doc: EditorDocument): FuseExportSupport {
  let def: GraphDefinition;
  try {
    def = toRunner(doc);
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    return { ok: false, reasons: [msg], reason: msg };
  }

  // Explicit wasm-without-expr messaging (product copy).
  const wasmNodes = def.nodes.filter((n) => n.type === "wasm");
  if (wasmNodes.length > 0) {
    const reasons = wasmNodes.map(
      (n) =>
        `WASM node '${n.id}' has no expression — optimized export requires expr nodes ` +
        `(use multi-module Compile/Run for opaque WASM nodes).`,
    );
    return {
      ok: false,
      reasons,
      reason:
        wasmNodes.length === 1
          ? reasons[0]!
          : `${wasmNodes.length} WASM nodes cannot be fused (need expr dual or multi-module only)`,
    };
  }

  try {
    const plan = lowerGraphToFusePlan(def);
    if (plan.nodes.length === 0) {
      const reason = "No expression compute nodes to fuse.";
      return { ok: false, reasons: [reason], reason };
    }
    const nOut = plan.outputs.length;
    return {
      ok: true,
      plan,
      summary: `1 fused module · ${nOut} output${nOut === 1 ? "" : "s"}`,
    };
  } catch (e) {
    const msg =
      e instanceof FuseError
        ? e.message
        : String((e as Error)?.message ?? e);
    return { ok: false, reasons: [msg], reason: msg };
  }
}

/** Human copy for dual product model (selectable compile mode + export). */
export const DUAL_MODEL_COPY =
  "Before Compile, choose Modules (one WASM per compute node) or Fused (one module " +
  "for the whole graph). Run uses whichever mode you compiled. " +
  "Export optimized WASM always downloads a fused .wasm + .graph.json. " +
  "Params stay runtime args — no recompile when sliders move.";

/** Compile/runtime mode chosen before Compile. */
export type GraphCompileMode = "modules" | "fused";

export function compileModeLabel(mode: GraphCompileMode): string {
  return mode === "fused" ? "Fused (1 module)" : "Modules (1 per node)";
}

export type CompileGraphApiResponse = {
  wasmBase64: string;
  graphJson: string;
  meta: FuseExportMeta;
};

/**
 * POST GraphDefinition to Vite middleware → fused wasm + sidecar.
 */
export async function requestOptimizedExport(
  def: GraphDefinition,
  options: { outMode?: "table" | "named_exports" } = {},
): Promise<CompileGraphApiResponse> {
  const res = await fetch("/api/compile_graph", {
    method: "POST",
    headers: { "content-type": "application/json;charset=utf-8" },
    body: JSON.stringify({
      graph: def,
      outMode: options.outMode ?? "table",
    }),
  });
  if (!res.ok) {
    const msg = await res.text();
    throw new Error(msg || `Optimized export failed (HTTP ${res.status})`);
  }
  return (await res.json()) as CompileGraphApiResponse;
}

export function base64ToUint8Array(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Trigger browser download of a binary blob. */
export function downloadBytes(
  bytes: Uint8Array,
  filename: string,
  mime = "application/octet-stream",
): void {
  // Copy into a fresh ArrayBuffer-backed view so BlobPart typing is clean.
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const blob = new Blob([copy.buffer], { type: mime });
  const url = URL.createObjectURL(blob);
  try {
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.rel = "noopener";
    document.body.appendChild(a);
    a.click();
    a.remove();
  } finally {
    // Delay revoke so the browser can start the download.
    setTimeout(() => URL.revokeObjectURL(url), 2_000);
  }
}

export function downloadText(text: string, filename: string, mime = "application/json"): void {
  const blob = new Blob([text], { type: mime });
  const url = URL.createObjectURL(blob);
  try {
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.rel = "noopener";
    document.body.appendChild(a);
    a.click();
    a.remove();
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 2_000);
  }
}

/**
 * Download .wasm then .graph.json with a short gap so multi-download blockers
 * (Safari / Chrome without “multiple downloads” permission) are less likely to
 * drop the sidecar. Prefer keeping both files; a single zip is future work.
 */
export function downloadOptimizedExportPair(
  wasm: Uint8Array,
  graphJson: string,
  baseName: string,
): void {
  downloadBytes(wasm, `${baseName}.wasm`, "application/wasm");
  setTimeout(() => {
    downloadText(graphJson, `${baseName}.graph.json`, "application/json");
  }, 150);
}

/** Format fuse plan for advanced "copy fuse plan" action. */
export function formatFusePlanJson(plan: FusePlan): string {
  return JSON.stringify(plan, null, 2);
}

export function exportSummaryFromMeta(meta: FuseExportMeta): string {
  const n = meta.outputCount;
  return `1 fused module · ${n} output${n === 1 ? "" : "s"}`;
}
