//! VM-native graph evaluator v1 (task-11 Part 2).
//!
//! Architecture:
//! - `schema` — GraphDefinition JSON (mirror TS schema.ts)
//! - `topo` — Kahn topo-sort (mirror topo.ts)
//! - `fuse` — Graph → FusePlan lowerer (mirror TS fuse.ts; Spec 02/05)
//! - `value_transfer` — MathZig Value ownership on edges
//! - `manifest` — mathzig:node JSON / optional wasm custom-section scan helpers
//! - `engine` — VmEngine (in-process MathZig VM; no wasm interpreter in v1)
//! - `runner` — load, tick protocol, setParam, dispose (**never loads .wasm bytes**)
//!
//! Port binding: real port names as MathZig variables (no x/y/z rewrite).
//! Graphs with x/y/z ports match TS simple cases. Public semantics never
//! expose the TS AOT positional rewrite; alias limit = abi.GRAPH_ALIAS_LIMIT (3).

pub const schema = @import("schema.zig");
pub const topo = @import("topo.zig");
pub const fuse = @import("fuse.zig");
pub const value_transfer = @import("value_transfer.zig");
pub const manifest = @import("manifest.zig");
pub const engine = @import("engine.zig");
pub const runner = @import("runner.zig");
pub const load_error = @import("load_error.zig");

pub const GraphRunner = runner.GraphRunner;
pub const GraphError = runner.GraphError;
pub const DebugStats = runner.DebugStats;
pub const RunInputs = runner.RunInputs;
pub const RunOutputs = runner.RunOutputs;
pub const PortKind = schema.PortKind;
pub const VmEngine = engine.VmEngine;
pub const FusePlan = fuse.FusePlan;
pub const lowerGraphToFusePlan = fuse.lowerGraphToFusePlan;
pub const LoadError = load_error.LoadError;

test {
    _ = schema;
    _ = topo;
    _ = fuse;
    _ = value_transfer;
    _ = manifest;
    _ = engine;
    _ = runner;
}
