export type { WasmCompiler, CompiledWasmModule, AotAbiManifest } from "./compile_cache";
export { clearGraphCompileCache } from "./compile_cache";
export type { ScalarWasmEnv, ScalarWasmImports } from "./env";
export { createDefaultScalarWasmEnv, createDefaultScalarWasmImports } from "./env";
export type {
  GraphDefinition,
  GraphEdge,
  GraphNode,
  GraphNodeId,
  GraphPortName,
  GraphRef,
  GraphValue,
  NodeManifest,
  PortKind,
  ScalarGraphNode,
} from "./schema";
export type {
  GraphManifest,
  GraphManifestExport,
  GraphManifestOutput,
  GraphManifestPort,
  GraphOutMode,
} from "./graph_manifest";
export {
  GRAPH_ABI_VERSION,
  GRAPH_MANIFEST_SECTION,
  NODE_MANIFEST_SECTION,
  GraphManifestError,
  readGraphManifest,
  readGraphManifestFromBytes,
  readNodeManifestFromBytes,
  scanCustomSectionBytes,
  validateGraphManifest,
} from "./graph_manifest";
export type { CustomSectionScan } from "./graph_manifest";
export {
  GraphRunner,
  GraphAllocError,
  readNodeManifest,
  GRAPH_ALIAS_LIMIT,
  ALIAS_LIMIT_ERROR,
} from "./runner";
export type {
  GraphBatchLanes,
  GraphLoadProgress,
  GraphNodeTiming,
  GraphProfiledRun,
  GraphRunInputs,
  GraphRunOutputs,
  GraphRunnerOptions,
  GraphRunnerDebugStats,
} from "./runner";
export {
  normalizeGraphDefinition,
  parseGraphDefinitionJson,
  parseGraphDefinitionJsonBytes,
  parseGraphRef,
  assertFiniteScalar,
} from "./schema";
export {
  graphValuesEqual,
  kindsCompatible,
  normalizePortKind,
  readWireValue,
  writeWireValue,
  kindToResultTag,
  resultTagToPortKind,
} from "./value_transfer";
export type {
  MatrixValue,
  ComplexValue,
  RecordValue,
  SeriesValue,
  WasmNodeExports,
} from "./value_transfer";
export {
  parseGraphDsl,
  parseGraphDslBytes,
  dslToGraphDefinition,
  canonicalizeGraphDefinition,
  DslError,
} from "./dsl";
export type {
  DslSourcePosition,
  DslLibraryEntry,
  ParseGraphDslOptions,
  ParseGraphDslResult,
} from "./dsl";
export {
  MathZigLoadError,
  WireDecodeError,
  ManifestLoadError,
  GraphJsonError,
  loadErrorShapeOf,
} from "./load_error";
export type {
  TrustSurfacePhase,
  ErrorPosition,
  ErrorContext,
  LoadErrorShape,
} from "./load_error";
export {
  ADVERSARIAL_LIMITS,
  MAX_SOURCE_BYTES,
  MAX_IDENTIFIER_LEN,
  MAX_TOKEN_COUNT,
  MAX_NESTING_DEPTH,
  MAX_MATRIX_ELEMENTS,
  MAX_MATRIX_BYTES,
  MAX_RECORD_ENTRIES,
  MAX_SERIES_SAMPLES,
  MAX_GRAPH_NODES,
  MAX_GRAPH_EDGES,
  MAX_GRAPH_DEPTH,
  MAX_WIRE_STRING_BYTES,
} from "./limits";
export {
  FUSE_ERR,
  FuseError,
  lowerGraphToFusePlan,
} from "./fuse";
export type {
  FusePlan,
  FusePlanConst,
  FusePlanInput,
  FusePlanNode,
  FusePlanOutput,
  FusePlanParam,
} from "./fuse";
export { FusedGraphRunner } from "./fused_runner";
export type { FusedGraphRunnerOptions } from "./fused_runner";
// Node/bun-only compile (shells to mathzig compile-graph): import from
// `./node` or `./fused_compile` — NOT from this barrel. Re-exporting it here
// pulls `node:child_process` into browser bundles (Vite @mathzig/graph).
