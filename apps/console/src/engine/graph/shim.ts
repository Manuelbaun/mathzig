/**
 * Typecheck-only facade for `@mathzig/graph`.
 *
 * Vite resolves `@mathzig/graph` to the real `src/ts/graph` package (with
 * browser stubs for bun:ffi). tsc must not follow that graph into native
 * MathZig/FFI sources (erasableSyntaxOnly + bun:ffi fail under console tsconfig).
 *
 * Keep this API surface aligned with what GraphPage imports.
 */

export type PortKind = string;

export type GraphValue =
  | number
  | boolean
  | string
  | { rows: number; cols: number; data: ArrayLike<number> }
  | { timestamps?: number[]; values?: number[]; len?: () => number; id?: number }
  | { re: number; im: number }
  | unknown;

export type GraphDefinition = {
  nodes:
    | Array<Record<string, unknown> & { id: string; type: string }>
    | Record<string, Record<string, unknown> & { type: string }>;
  edges?: Array<{ from: string; to: string }> | Record<string, string>;
  outputs?: Record<string, string> | string[];
};

export type GraphRunOutputs = Record<string, GraphValue>;
export type GraphRunInputs = Record<string, GraphValue>;

export type WasmCompiler = {
  compile(expr: string, numParams: number): Promise<Uint8Array>;
  version?: string;
};

export type ScalarWasmImports = Record<string, Record<string, (...args: number[]) => number>>;

export function createDefaultScalarWasmEnv(
  _overrides?: Partial<Record<string, (...args: number[]) => number>>,
): Record<string, (...args: number[]) => number> {
  return {};
}

export function createDefaultScalarWasmImports(
  _overrides?: Partial<Record<string, (...args: number[]) => number>>,
): ScalarWasmImports {
  return { env: {} };
}

export type GraphLoadProgress = {
  stage: "validate" | "compile" | "instantiate" | "ready";
  message: string;
  nodeId?: string;
  nodeKind?: "expr" | "wasm";
  index?: number;
  total?: number;
};

export type GraphNodeTiming = {
  nodeId: string;
  kind: "input" | "const" | "expr" | "wasm";
  ms: number;
};

export class GraphRunner {
  static async load(
    _def: GraphDefinition,
    _options: {
      compiler: WasmCompiler;
      env?: ScalarWasmImports;
      host?: unknown;
      onProgress?: (e: GraphLoadProgress) => void;
    },
  ): Promise<GraphRunner> {
    return new GraphRunner();
  }

  run(_inputs?: GraphRunInputs): GraphRunOutputs {
    return {};
  }

  runProfiled(_inputs?: GraphRunInputs): {
    outputs: GraphRunOutputs;
    totalMs: number;
    nodes: GraphNodeTiming[];
  } {
    return { outputs: {}, totalMs: 0, nodes: [] };
  }

  setParam(_nodeId: string, _name: string, _value: number): void {}

  listParams(): Array<{ nodeId: string; name: string; value: number }> {
    return [];
  }

  async reload(_nodeId: string, _expr: string): Promise<void> {}

  dispose(): void {}

  getDefinition(): GraphDefinition {
    return { nodes: [] };
  }
}

export function clearGraphCompileCache(): void {}

/** Typecheck stub — real load is in @mathzig/graph (Vite). */
export class FusedGraphRunner {
  static async load(
    _wasm: Uint8Array | ArrayBuffer | WebAssembly.Module,
    _options?: { host?: unknown; env?: ScalarWasmImports },
  ): Promise<FusedGraphRunner> {
    return new FusedGraphRunner();
  }

  run(_inputs?: GraphRunInputs): GraphRunOutputs {
    return {};
  }

  setParam(_name: string, _value: number): void {}

  listParams(): Array<{ name: string; value: number }> {
    return [];
  }

  dispose(): void {}
}

/** Read `mathzig:node` custom section (runtime uses real graph package). */
export function readNodeManifest(_module: WebAssembly.Module): {
  inputs: Array<{ name: string; kind: string }>;
  params: Array<{ name: string; kind: string; default?: number | null }>;
  output: { name?: string; kind: string; result_tag?: string };
} | null {
  return null;
}
