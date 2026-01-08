//! Graph lowerer: pure transform NormalizedGraphDefinition → FusePlan (Spec 02 / 05).
//!
//! Mirrors `src/ts/graph/fuse.ts`. No wasm instantiation or AOT compile.
//! Output is the sole input to multi-root / fused-tick codegen (Spec 03).
//!
//! ## Boundary rewrite policy
//!
//! **Keep real host port / param names** in each node's `expr` text.
//! Do **not** rewrite to GraphRunner's positional `x,y,z` aliases.
//!
//! ## Param naming
//!
//! Flattened fused entry params use `"${nodeId}.${param}"` (globally unique).
//! Order: topo order of reachable compute nodes, then each node's params
//! insertion order.
//!
//! ## Port kinds
//!
//! Known `PortKind`s are accepted (number/boolean + matrix/complex/record/
//! series/string/any — Spec 07 full-value). Unknown kind strings fail at
//! schema parse via `normalizePortKind`.
//!
//! ## v1 rejections
//!
//! - Reachable `type: "wasm"` nodes (opaque prebuilt modules)
//! - Missing edge for a required expr input port
//! - Undeclared input port, input+param name collision, non-finite param
//! - Duplicate host-facing input `name`s
//! - Output ref to a missing node / non-`.out` port
//! - Kind mismatch on an edge into a reachable expr node
//! - Cycles (via `topoSort`)

const std = @import("std");
const schema = @import("schema.zig");
const topo = @import("topo.zig");
const Value = @import("../core/value.zig").Value;

// ── Stable error messages (testable substrings; match TS FUSE_ERR) ───────────

pub const ERR = struct {
    pub const wasm_unsupported = "Fuse v1 does not support wasm nodes";
    pub const missing_input_edge = "missing edge for input";
    pub const missing_output_node = "output references missing node";
    pub const empty_outputs = "graph has no outputs";
    pub const cycle = "Graph contains a cycle";
    pub const undeclared_port = "has undeclared input port";
    pub const input_param_collision = "as both input and param";
    pub const non_finite_param = "must be a finite number";
    pub const output_not_out = "must reference '.out'";
    pub const invalid_ref = "Invalid graph reference";
    pub const duplicate_input_name = "duplicate graph input name";
    pub const kind_mismatch = "Kind mismatch on edge";
};

pub const FuseError = error{
    WasmUnsupported,
    MissingInputEdge,
    MissingOutputNode,
    EmptyOutputs,
    Cycle,
    UndeclaredPort,
    InputParamCollision,
    NonFiniteParam,
    OutputNotOut,
    InvalidRef,
    DuplicateInputName,
    KindMismatch,
    OutOfMemory,
};

// ── FusePlan types ──────────────────────────────────────────────────────────

pub const FusePlanInput = struct {
    /// Host-facing input name (`node.name ?? node.id`). Unique within plan.inputs.
    name: []const u8,
    kind: schema.PortKind,
    source_node_id: []const u8,
};

pub const FusePlanParam = struct {
    /// Globally unique flat name: `nodeId.param`.
    name: []const u8,
    kind: schema.PortKind = .number,
    node_id: []const u8,
    /// Local param key on the source node.
    param: []const u8,
    default: f64,
};

pub const FusePlanConst = struct {
    id: []const u8,
    value: Value,
    kind: schema.PortKind,
};

/// One reachable compute (`expr`) node in topo order.
pub const FusePlanNode = struct {
    id: []const u8,
    /// Authored expression (real port names — boundary policy).
    expr: []const u8,
    /// Declared input port names (order preserved from the graph node).
    inputs: []const []const u8,
    /// Producer node id for each entry in `inputs` (parallel).
    input_ports: []const []const u8,
    /// Consumer port kinds parallel to `inputs` (default number).
    input_kinds: []const schema.PortKind,
    /// Local param names on this node (order matches node.params).
    param_names: []const []const u8,
    output_kind: schema.PortKind,
};

pub const FusePlanOutput = struct {
    name: []const u8,
    from_node_id: []const u8,
    kind: schema.PortKind,
};

pub const FusePlan = struct {
    inputs: []const FusePlanInput,
    params: []const FusePlanParam,
    /// Reachable const nodes only.
    consts: []const FusePlanConst,
    /// Topo order among reachable compute (expr) nodes only.
    nodes: []const FusePlanNode,
    outputs: []const FusePlanOutput,
    /// Always `"real_names"` in v1 (no x,y,z rewrite).
    boundary_policy: []const u8 = "real_names",
};

// ── Last error detail (CLI / tests) ─────────────────────────────────────────

var last_error_buf: [512]u8 = undefined;
var last_error_len: usize = 0;

pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

fn setError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&last_error_buf, fmt, args) catch blk: {
        const fallback = "fuse error (message too long)";
        @memcpy(last_error_buf[0..fallback.len], fallback);
        last_error_len = fallback.len;
        break :blk last_error_buf[0..fallback.len];
    };
    last_error_len = msg.len;
}

fn setErrorCopy(msg: []const u8) void {
    const n = @min(msg.len, last_error_buf.len);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_len = n;
}

// ── Lowerer ─────────────────────────────────────────────────────────────────

/// Lower a normalized graph definition to a deterministic fuse plan.
/// All plan slices are allocated from `arena` (caller owns the arena).
/// Const Values in the plan are **not** retained (borrowed from `def`);
/// do not free const Values via the plan — use `schema.deinitConstValues` on def.
pub fn lowerGraphToFusePlan(
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    def: schema.NormalizedGraphDefinition,
) FuseError!FusePlan {
    last_error_len = 0;

    var topology = topo.topoSort(scratch, def.nodes, def.edges) catch |err| {
        if (err == error.Cycle) {
            const cycle_nodes = topo.takeLastCycleNodes();
            defer if (cycle_nodes.len > 0) scratch.free(cycle_nodes);
            if (cycle_nodes.len > 0) {
                setError("{s} involving: {s}", .{ ERR.cycle, cycle_nodes });
            } else {
                setErrorCopy(ERR.cycle);
            }
            return error.Cycle;
        }
        if (err == error.OutOfMemory) return error.OutOfMemory;
        setError("topo sort failed: {s}", .{@errorName(err)});
        return error.InvalidRef;
    };
    defer topology.deinit(scratch);

    var by_id = std.StringHashMap(schema.GraphNode).init(scratch);
    defer by_id.deinit();
    for (def.nodes) |node| {
        try by_id.put(node.id(), node);
    }

    if (def.outputs.len == 0) {
        setErrorCopy(ERR.empty_outputs);
        return error.EmptyOutputs;
    }

    // Resolve outputs first — missing refs are hard errors.
    var plan_outputs: std.ArrayListUnmanaged(FusePlanOutput) = .empty;
    errdefer plan_outputs.deinit(arena);

    var seed_ids = std.StringHashMap(void).init(scratch);
    defer seed_ids.deinit();

    for (def.outputs) |out| {
        const parsed = schema.parseGraphRef(out.ref) catch {
            setError("{s} '{s}' (output '{s}').", .{ ERR.invalid_ref, out.ref, out.name });
            return error.InvalidRef;
        };
        if (!std.mem.eql(u8, parsed.port, "out")) {
            setError("Output '{s}' {s} (got '{s}').", .{ out.name, ERR.output_not_out, out.ref });
            return error.OutputNotOut;
        }
        const src = by_id.get(parsed.node_id) orelse {
            setError("{s} '{s}' (output '{s}').", .{ ERR.missing_output_node, parsed.node_id, out.name });
            return error.MissingOutputNode;
        };
        try seed_ids.put(parsed.node_id, {});
        try plan_outputs.append(arena, .{
            .name = out.name,
            .from_node_id = parsed.node_id,
            .kind = src.outputKind(),
        });
    }

    var reachable = try markReachable(scratch, &seed_ids, &topology.incoming, &by_id);
    defer reachable.deinit();

    // Reject wasm among reachable nodes (v1).
    var rit = reachable.keyIterator();
    while (rit.next()) |id_ptr| {
        const node = by_id.get(id_ptr.*).?;
        if (node == .wasm) {
            setError("{s} (node '{s}'). Replace with an expr node or keep multi-module GraphRunner.", .{
                ERR.wasm_unsupported,
                id_ptr.*,
            });
            return error.WasmUnsupported;
        }
    }

    var inputs: std.ArrayListUnmanaged(FusePlanInput) = .empty;
    errdefer inputs.deinit(arena);
    var consts: std.ArrayListUnmanaged(FusePlanConst) = .empty;
    errdefer consts.deinit(arena);
    var nodes: std.ArrayListUnmanaged(FusePlanNode) = .empty;
    errdefer nodes.deinit(arena);
    var params: std.ArrayListUnmanaged(FusePlanParam) = .empty;
    errdefer params.deinit(arena);

    var seen_input_names = std.StringHashMap(void).init(scratch);
    defer seen_input_names.deinit();

    for (topology.ordered) |node| {
        if (!reachable.contains(node.id())) continue;

        switch (node) {
            .input => |n| {
                if (seen_input_names.contains(n.name)) {
                    var prior: []const u8 = "?";
                    for (inputs.items) |inp| {
                        if (std.mem.eql(u8, inp.name, n.name)) {
                            prior = inp.source_node_id;
                            break;
                        }
                    }
                    setError("{s} '{s}' (nodes '{s}' and '{s}').", .{
                        ERR.duplicate_input_name,
                        n.name,
                        prior,
                        n.id,
                    });
                    return error.DuplicateInputName;
                }
                try seen_input_names.put(n.name, {});
                try inputs.append(arena, .{
                    .name = n.name,
                    .kind = n.kind,
                    .source_node_id = n.id,
                });
            },
            .@"const" => |n| {
                try consts.append(arena, .{
                    .id = n.id,
                    .value = n.value,
                    .kind = n.kind,
                });
            },
            .expr => |n| {
                // Topo always inserts an empty incoming map per node.
                const incoming_ptr = topology.incoming.getPtr(n.id) orelse unreachable;

                var input_ports: std.ArrayListUnmanaged([]const u8) = .empty;
                errdefer input_ports.deinit(arena);

                for (n.inputs, 0..) |port, i| {
                    const src = incoming_ptr.get(port) orelse {
                        setError("Expr node '{s}' {s} '{s}'.", .{ n.id, ERR.missing_input_edge, port });
                        return error.MissingInputEdge;
                    };
                    try input_ports.append(arena, src.node_id);

                    // Lightweight kind check (aligned with GraphRunner / TS fuse).
                    if (by_id.get(src.node_id)) |src_node| {
                        const consumer_kind = n.input_kinds[i];
                        const producer_kind: schema.PortKind = switch (src_node) {
                            .expr => |en| en.output_kind, // schema defaults to .number
                            else => src_node.outputKind(),
                        };
                        if (!schema.kindsCompatible(producer_kind, consumer_kind)) {
                            setError("{s} '{s}.out' → '{s}.{s}': producer '{s}' vs consumer '{s}'.", .{
                                ERR.kind_mismatch,
                                src.node_id,
                                n.id,
                                port,
                                producer_kind.name(),
                                consumer_kind.name(),
                            });
                            return error.KindMismatch;
                        }
                    }
                }

                // Undeclared ports with edges → error.
                var port_it = incoming_ptr.keyIterator();
                while (port_it.next()) |port_ptr| {
                    const port = port_ptr.*;
                    var found = false;
                    for (n.inputs) |declared| {
                        if (std.mem.eql(u8, declared, port)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        setError("Expr node '{s}' {s} '{s}'.", .{ n.id, ERR.undeclared_port, port });
                        return error.UndeclaredPort;
                    }
                }

                var param_names: std.ArrayListUnmanaged([]const u8) = .empty;
                errdefer param_names.deinit(arena);

                for (n.params) |p| {
                    for (n.inputs) |declared| {
                        if (std.mem.eql(u8, declared, p.name)) {
                            setError("Expr node '{s}' uses '{s}' {s}.", .{
                                n.id,
                                p.name,
                                ERR.input_param_collision,
                            });
                            return error.InputParamCollision;
                        }
                    }
                    if (!std.math.isFinite(p.value)) {
                        setError("Param '{s}.{s}' {s}.", .{ n.id, p.name, ERR.non_finite_param });
                        return error.NonFiniteParam;
                    }
                    const flat = try std.fmt.allocPrint(arena, "{s}.{s}", .{ n.id, p.name });
                    try params.append(arena, .{
                        .name = flat,
                        .kind = .number,
                        .node_id = n.id,
                        .param = p.name,
                        .default = p.value,
                    });
                    try param_names.append(arena, p.name);
                }

                try nodes.append(arena, .{
                    .id = n.id,
                    .expr = n.expr,
                    .inputs = n.inputs,
                    .input_ports = try input_ports.toOwnedSlice(arena),
                    .input_kinds = n.input_kinds,
                    .param_names = try param_names.toOwnedSlice(arena),
                    .output_kind = n.output_kind,
                });
            },
            .wasm => {
                // Unreachable wasm is fine (dropped); reachable already rejected above.
            },
        }
    }

    return .{
        .inputs = try inputs.toOwnedSlice(arena),
        .params = try params.toOwnedSlice(arena),
        .consts = try consts.toOwnedSlice(arena),
        .nodes = try nodes.toOwnedSlice(arena),
        .outputs = try plan_outputs.toOwnedSlice(arena),
        .boundary_policy = "real_names",
    };
}

/// Backward reachability from graph outputs through edge producers.
fn markReachable(
    scratch: std.mem.Allocator,
    seeds: *const std.StringHashMap(void),
    incoming: *const std.StringHashMap(std.StringHashMap(topo.GraphRefSource)),
    by_id: *const std.StringHashMap(schema.GraphNode),
) error{OutOfMemory}!std.StringHashMap(void) {
    var reachable = std.StringHashMap(void).init(scratch);
    errdefer reachable.deinit();

    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(scratch);

    var sit = seeds.keyIterator();
    while (sit.next()) |id| {
        try stack.append(scratch, id.*);
    }

    while (stack.items.len > 0) {
        const id = stack.pop().?;
        if (reachable.contains(id)) continue;
        if (!by_id.contains(id)) continue;
        try reachable.put(id, {});
        const ports = incoming.get(id) orelse continue;
        var pit = ports.valueIterator();
        while (pit.next()) |src| {
            if (!reachable.contains(src.node_id)) {
                try stack.append(scratch, src.node_id);
            }
        }
    }
    return reachable;
}

// Unit tests: tests/zig/graph/fuse_lowerer_test.zig