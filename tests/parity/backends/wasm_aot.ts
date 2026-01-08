import type { ParityBackend } from "../cli";
import { compileAot } from "../wasm_aot";
import {
  AotHostEnv,
  readAbiManifest,
  type MatrixData,
  type SeriesData,
} from "../../../src/ts/aot_env";

class SeriesHandle {
  constructor(public id: number, private data: SeriesData) {}
  len(): number {
    return this.data.values.length;
  }
  getTimestampsPtr(): number[] {
    return this.data.timestamps;
  }
  getValuesPtr(): number[] {
    return this.data.values;
  }
}

class RecordHandle {
  constructor(
    private map: Map<string, number>,
    private seriesStore: Map<number, SeriesData>,
  ) {}
  getField(key: string): unknown {
    const value = this.map.get(key);
    // Match VM: missing field → undefined (not number NaN).
    if (value === undefined) return undefined;
    const data = this.seriesStore.get(value);
    if (data) return new SeriesHandle(value, data);
    return value;
  }
}

function shouldPersistExpr(expr: string): boolean {
  const trimmed = expr.trim();
  // User function defs and assignments may contain ';' inside matrix literals.
  if (/^[A-Za-z_]\w*\s*\([^)]*\)\s*=/.test(trimmed)) return true;
  if (/^[A-Za-z_]\w*\s*=/.test(trimmed)) return true;
  return false;
}

/** Thrown when `-s` compile rejects a case; parity CLI treats as SKIP. */
export class StandaloneUnsupportedError extends Error {
  readonly skip = true as const;
  constructor(message: string) {
    super(message);
    this.name = "StandaloneUnsupportedError";
  }
}

/**
 * WASM AOT backend — uses the generated delegated host env (task A1).
 * Pass `{ standalone: true }` for the Tier-1/2 no-import sub-run (task A4).
 */
export class WasmAotBackend implements ParityBackend {
  name: string;
  private preamble: string[] = [];
  private host = new AotHostEnv();
  private standalone: boolean;

  constructor(opts: { standalone?: boolean; name?: string } = {}) {
    this.standalone = opts.standalone === true;
    this.name = opts.name ?? (this.standalone ? "wasm_aot_standalone" : "wasm_aot");
  }

  async init(): Promise<void> {}

  reset(): void {
    this.preamble = [];
    this.host.reset();
  }

  async evaluate(expr: string, vars: Record<string, number>): Promise<unknown> {
    const varSetup = Object.entries(vars)
      .map(([k, v]) => `${k} = ${v}`)
      .join("; ");
    const parts: string[] = [];
    if (this.preamble.length > 0) parts.push(this.preamble.join("; "));
    if (varSetup) parts.push(varSetup);
    parts.push(expr);
    const fullExpr = parts.join("; ");

    let compiled: Awaited<ReturnType<typeof compileAot>>;
    try {
      compiled = await compileAot(fullExpr, 0, { standalone: this.standalone });
    } catch (err: any) {
      const msg = String(err?.message ?? err);
      if (this.standalone && /standalone unsupported|StandaloneUnsupported/i.test(msg)) {
        throw new StandaloneUnsupportedError(msg);
      }
      throw err;
    }

    const module = await WebAssembly.compile(compiled.wasmBytes);
    const manifest = readAbiManifest(module);

    let instance: WebAssembly.Instance;
    if (this.standalone) {
      const imports = WebAssembly.Module.imports(module);
      if (imports.length > 0) {
        throw new StandaloneUnsupportedError(
          `standalone module still has ${imports.length} import(s): ${imports.map((i) => `${i.module}.${i.name}`).join(", ")}`,
        );
      }
      instance = await WebAssembly.instantiate(module, {});
    } else {
      const env = this.host.buildEnvForManifest(manifest);
      instance = await WebAssembly.instantiate(module, { env });
    }

    this.host.attachMemory((instance.exports as { memory?: WebAssembly.Memory }).memory ?? null);
    this.host.attachInstance(instance.exports as Record<string, unknown>);

    const evalFn = instance.exports.eval as (() => number) | undefined;
    if (typeof evalFn !== "function") {
      throw new Error("WASM module does not export an 'eval' function");
    }

    const raw = evalFn();
    if (varSetup) this.preamble.push(varSetup);
    if (shouldPersistExpr(expr)) this.preamble.push(expr);

    return this.decodeResult(raw, manifest);
  }

  private decodeResult(raw: number, manifest: ReturnType<typeof readAbiManifest>): unknown {
    // Prefer the shared host decoder (string length-prefix, matrix, complex, …).
    const shared = this.host.decodeResult(raw, manifest);
    if (typeof shared === "string") return shared;
    const tag = manifest?.result_tag ?? "number";
    if (tag === "matrix") {
      if (shared && typeof shared === "object" && "data" in (shared as object)) return shared;
      const m = this.host.readMatrix(raw);
      if (m) return m as MatrixData;
      const stored = this.host.matrixStore.get(raw);
      if (stored) return stored;
    }
    if (tag === "complex") {
      const c = this.host.readComplex(raw);
      if (c) return { tag: 1, re: c.re, im: c.im };
    }
    if (tag === "series") {
      const s = this.host.resolveSeries(raw);
      if (s) return new SeriesHandle(raw, s);
    }
    if (tag === "record") {
      const rec = this.host.recordStore.get(raw);
      if (rec) return new RecordHandle(rec, this.host.seriesStore);
      const entries = this.host.readWasmRecord(raw);
      if (entries) {
        return new RecordHandle(
          new Map(entries.map((e) => [e.key, e.wire])),
          this.host.seriesStore,
        );
      }
    }
    return shared;
  }

  dispose(): void {}
}