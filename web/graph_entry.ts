/**
 * Browser entry for the shared node-graph package (`src/ts/graph/`).
 *
 * Built to `web/graph_bundle.js` (see `tools/build_graph_bundle.ts`).
 * Bun tests import `src/ts/graph` directly — same source, no forks.
 */
export {
  GraphRunner,
  clearGraphCompileCache,
  createDefaultScalarWasmEnv,
  createDefaultScalarWasmImports,
  normalizeGraphDefinition,
  parseGraphRef,
  graphValuesEqual,
  kindsCompatible,
  normalizePortKind,
  readNodeManifest,
} from "../src/ts/graph/index.ts";

export type {
  GraphBatchLanes,
  GraphDefinition,
  GraphEdge,
  GraphNode,
  GraphRunInputs,
  GraphRunOutputs,
  GraphRunnerOptions,
  GraphValue,
  NodeManifest,
  PortKind,
  WasmCompiler,
} from "../src/ts/graph/index.ts";
