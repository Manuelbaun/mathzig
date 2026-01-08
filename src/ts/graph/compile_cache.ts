export type WasmCompiler = {
  compile(expr: string, numParams: number): Promise<Uint8Array>;
  version?: string;
};

export type CompiledWasmModule = {
  expr: string;
  numParams: number;
  module: WebAssembly.Module;
  manifest: AotAbiManifest | null;
};

export type AotAbiManifest = {
  abi?: number;
  result_tag?: string;
  heap?: boolean;
  exports?: Array<{ name: string; params: number }>;
  imports?: Array<{ name: string; arity?: number; params?: number; where?: boolean; return?: string }>;
  heap_base?: number;
  /** Data-segment string constants (name → wasm offset) for rec_get matching. */
  strings?: Record<string, number>;
  /** Which series wire representation this module uses (task-07 hybrid). */
  series_repr?: "host_handle" | "linear_memory";
  /**
   * Unit runtime honesty (task-15): hosts may fail at load when
   * `host_dynamic` rather than on first call. Emit-accurate:
   * - none: no unit ops
   * - static: only compile-time folded unit ops / result_unit annotation
   * - host_dynamic: a non-folded dynamic unit op was actually emitted
   * Known host limitation until unit-descriptor ABI: target≈1 identity in
   * `AotHostEnv.convOrNumberWire` (see aot_env.ts + unit_abi_proposal.md).
   */
  unit_runtime?: "none" | "static" | "host_dynamic";
  /** SI-magnitude unit annotation for host re-attachment (task-07). */
  result_unit?: {
    dims: { m: number; l: number; t: number; i: number; k: number; n: number; j: number };
    scale: number;
    offset: number;
    name?: string;
  };
};

const moduleCache = new Map<string, Promise<CompiledWasmModule>>();

export async function compileCached(compiler: WasmCompiler, expr: string, numParams: number): Promise<CompiledWasmModule> {
  const key = await cacheKey(compiler, expr, numParams);
  let pending = moduleCache.get(key);
  if (!pending) {
    pending = compileModule(compiler, expr, numParams);
    moduleCache.set(key, pending);
  }
  return pending;
}

export function clearGraphCompileCache(): void {
  moduleCache.clear();
}

async function compileModule(compiler: WasmCompiler, expr: string, numParams: number): Promise<CompiledWasmModule> {
  const bytes = await compiler.compile(expr, numParams);
  const module = await WebAssembly.compile(bytes);
  return { expr, numParams, module, manifest: readAbiManifest(module) };
}

function readAbiManifest(module: WebAssembly.Module): AotAbiManifest | null {
  const sections = WebAssembly.Module.customSections(module, "mathzig.abi");
  if (sections.length === 0) return null;
  const text = new TextDecoder().decode(sections[0]);
  return JSON.parse(text) as AotAbiManifest;
}

async function cacheKey(compiler: WasmCompiler, expr: string, numParams: number): Promise<string> {
  const version = compiler.version ?? "unknown";
  const material = `${version}\0${numParams}\0${expr}`;
  const digest = await sha1Hex(material);
  return `${version}:${digest}`;
}

async function sha1Hex(text: string): Promise<string> {
  const subtle = globalThis.crypto?.subtle;
  if (subtle) {
    const digest = await subtle.digest("SHA-1", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  }
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}
