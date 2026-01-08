/**
 * Adversarial input limits (task-14 / C3).
 *
 * Mirror of `src/wasm/abi.zig` C3 constants. Enforcement is pre-allocation:
 * hostile lengths are rejected by bound-check against memory size and/or these
 * caps before any large allocation.
 *
 * Surfaces: S1 DSL · S2 wire-decode · S3 manifest · S4 graph JSON.
 */

/** Max source bytes for DSL text / graph JSON / manifest JSON (1 MiB). */
export const MAX_SOURCE_BYTES = 1 << 20;
/** Max identifier / port / node-id length. */
export const MAX_IDENTIFIER_LEN = 256;
/** Max tokens produced by the graph DSL tokenizer. */
export const MAX_TOKEN_COUNT = 100_000;
/** Max brace/bracket/paren nesting depth. */
export const MAX_NESTING_DEPTH = 64;
/** Max matrix elements (rows*cols). */
export const MAX_MATRIX_ELEMENTS = 1 << 20;
/** Max matrix payload bytes (elements × f64). */
export const MAX_MATRIX_BYTES = MAX_MATRIX_ELEMENTS * 8;
/** Max record field entries. */
export const MAX_RECORD_ENTRIES = 4096;
/** Max series samples. */
export const MAX_SERIES_SAMPLES = 1 << 20;
/** Max nodes in one GraphDefinition. */
export const MAX_GRAPH_NODES = 10_000;
/** Max edges in one GraphDefinition. */
export const MAX_GRAPH_EDGES = 50_000;
/** Max topo / dependency depth. */
export const MAX_GRAPH_DEPTH = 10_000;
/** Max length-prefixed string payload from wasm linear memory. */
export const MAX_WIRE_STRING_BYTES = 1 << 20;

/** Corpus v1 common limit: inputs+params combined per expr node. */
export const GRAPH_ALIAS_LIMIT = 3;

/** Named bag of all limits (for tests / docs dumps). */
export const ADVERSARIAL_LIMITS = {
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
  GRAPH_ALIAS_LIMIT,
} as const;
