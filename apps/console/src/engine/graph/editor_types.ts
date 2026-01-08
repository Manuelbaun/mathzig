/**
 * Editor document model: GraphDefinition (execution IR) + UI layout sidecar.
 * See plan: visual node graph editor (Solid Flow).
 */

export type PortKind =
  | "number"
  | "boolean"
  | "matrix"
  | "complex"
  | "record"
  | "string"
  | "series"
  | "any";

export type GraphValue =
  | number
  | boolean
  | string
  | { rows: number; cols: number; data: number[] | Float64Array }
  | { re: number; im: number }
  | { timestamps: number[]; values: number[] }
  | unknown;

export type NodeManifest = {
  abi?: number;
  name?: string;
  inputs: Array<{ name: string; kind: string }>;
  params: Array<{ name: string; kind: string; default?: number | null }>;
  output: { name?: string; kind: string; result_tag?: string };
};

export type GraphNode =
  | {
      id: string;
      type: "input";
      name?: string;
      kind?: PortKind | string;
    }
  | {
      id: string;
      type: "const";
      value: GraphValue;
      kind?: PortKind | string;
    }
  | {
      id: string;
      type: "expr";
      expr: string;
      inputs?: string[];
      inputKinds?: Array<PortKind | string>;
      params?: Record<string, number>;
      outputKind?: PortKind | string;
    }
  | {
      id: string;
      type: "wasm";
      /** Browser: base64 data URL, http(s) URL, or session path marker. */
      wasm: string | Uint8Array | ArrayBuffer;
      manifest?: NodeManifest;
      params?: Record<string, number>;
    };

export type GraphEdge = { from: string; to: string };

export type GraphDefinition = {
  nodes: GraphNode[];
  edges?: GraphEdge[];
  outputs?: Record<string, string>;
};

export type EditorNodeUi = {
  position: { x: number; y: number };
  width?: number;
  height?: number;
};

export type EditorOutputNodeUi = {
  /** Canvas node id (not a runner node), e.g. `out_value` */
  id: string;
  /** Key in definition.outputs */
  name: string;
  position: { x: number; y: number };
};

export type EditorUi = {
  viewport?: { x: number; y: number; zoom: number };
  nodes: Record<string, EditorNodeUi>;
  outputNodes?: EditorOutputNodeUi[];
};

export type EditorDocument = {
  definition: GraphDefinition;
  ui: EditorUi;
};

/** Solid Flow custom node type keys */
export type MzNodeType = "mzInput" | "mzConst" | "mzExpr" | "mzWasm" | "mzOutput";

export type MzInputData = {
  mzType: "input";
  name: string;
  kind: PortKind;
};

export type MzConstData = {
  mzType: "const";
  value: GraphValue;
  kind: PortKind;
};

export type MzExprData = {
  mzType: "expr";
  expr: string;
  inputs: string[];
  inputKinds: PortKind[];
  params: Record<string, number>;
  outputKind: PortKind;
};

export type MzWasmData = {
  mzType: "wasm";
  /** Serialized wasm ref for the editor (base64 or url string). */
  wasmRef: string;
  manifest: NodeManifest | null;
  params: Record<string, number>;
};

export type MzOutputData = {
  mzType: "output";
  /** Graph output name (key in definition.outputs) */
  name: string;
};

export type MzNodeData = MzInputData | MzConstData | MzExprData | MzWasmData | MzOutputData;

/** Flow node as used by the adapter (library-agnostic shape). */
export type FlowNode = {
  id: string;
  type: MzNodeType;
  position: { x: number; y: number };
  data: MzNodeData;
  width?: number;
  height?: number;
};

export type FlowEdge = {
  id: string;
  source: string;
  target: string;
  sourceHandle?: string | null;
  targetHandle?: string | null;
};

export const PORT_KINDS: PortKind[] = [
  "number",
  "boolean",
  "matrix",
  "complex",
  "record",
  "string",
  "series",
  "any",
];
