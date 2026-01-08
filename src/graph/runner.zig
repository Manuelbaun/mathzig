//! VM-native graph evaluator v1 — load graph JSON, topo-sort, per-tick evaluate.
//!
//! Semantics mirror `src/ts/graph/runner.ts` for input/const/expr nodes.
//! Engine: in-process MathZig VM (see `engine.zig`). **Never loads .wasm bytes**
//! — `type: "wasm"` nodes require a dual-path `expr` or fail with `WasmPhase2Required`.

const std = @import("std");
const MathZig = @import("../mathzig.zig").MathZig;
const Value = @import("../core/value.zig").Value;
const CompiledExpr = @import("../vm/bytecode.zig").CompiledExpr;

const schema = @import("schema.zig");
const topo_mod = @import("topo.zig");
const value_transfer = @import("value_transfer.zig");
const engine_mod = @import("engine.zig");
const manifest_mod = @import("manifest.zig");
const live_handles = @import("../memory/live_handles.zig");

pub const GraphError = error{
    Cycle,
    KindMismatch,
    MissingInput,
    UndeclaredPort,
    UnconnectedPort,
    WasmPhase2Required,
    UnknownNode,
    UnknownParam,
    NoParams,
    OutputMissing,
    InvalidOutputRef,
    EvalError,
    CompileError,
    /// inputs+params exceeded corpus v1 common limit (abi.GRAPH_ALIAS_LIMIT).
    AliasLimitExceeded,
    /// @deprecated synonym; prefer AliasLimitExceeded.
    TooManyPorts,
    InvalidGraphJson,
    MissingNodes,
    MissingType,
    MissingExpr,
    InvalidConstValue,
    InvalidNumber,
    DuplicateNode,
    EmptyNodeId,
    UnknownPortKind,
    InvalidGraphRef,
    EdgeSourceMissing,
    EdgeTargetMissing,
    EdgeSourceMustBeOut,
    MultipleSources,
    InvalidManifest,
    UnknownKind,
    /// Documented adversarial cap exceeded (task-14 / C3).
    LimitExceeded,
    SourceTooLarge,
    IdentifierTooLong,
    /// Hot-reload rejected: new expr incompatible with existing ports / kinds.
    ReloadIncompatible,
} || error{OutOfMemory};

/// Test-only observability (task-16 / C5 debugStats).
pub const DebugStats = struct {
    /// Live Matrix + Series + Record objects process-wide (retain/release).
    live_value_handles: usize,
    live_matrix: usize,
    live_series: usize,
    live_record: usize,
    /// Dense value slot count for this runner.
    slot_count: usize,
    /// Number of loaded compute nodes (expr + dual-path wasm).
    instance_count: usize,
    /// Always 0 for VM-native evaluator (never loads .wasm).
    wasm_memory_pages: usize = 0,
};

pub const RunInputs = std.StringHashMap(Value);
pub const RunOutputs = std.StringHashMap(Value);

const LoadedExpr = struct {
    id: []const u8,
    expr_text: []const u8,
    inputs: []const []const u8,
    input_kinds: []const schema.PortKind,
    /// Mutable host param store (setParam writes here).
    params: []schema.ParamEntry,
    output_kind: schema.PortKind,
    /// Precompiled bytecode (optional — null means eval via source each tick).
    compiled: ?*CompiledExpr = null,
    /// Input source node ids parallel to `inputs` (filled at plan rebuild).
    input_source_ids: [][]const u8 = &.{},
};

const LoadedConst = struct {
    id: []const u8,
    value: Value,
    output_kind: schema.PortKind,
};

const LoadedInput = struct {
    id: []const u8,
    name: []const u8,
    output_kind: schema.PortKind,
};

/// Schema `type: "wasm"` node loaded as dual-path expr for VM-native graph evaluator v1.
/// `wasm_path` from JSON is ignored (v1 never loads .wasm bytes).
const LoadedWasm = struct {
    id: []const u8,
    /// Dual-path expr for VM engine; null → WasmPhase2Required at load.
    expr_text: ?[]const u8,
    inputs: []const []const u8,
    input_kinds: []const schema.PortKind,
    params: []schema.ParamEntry,
    output_kind: schema.PortKind,
    compiled: ?*CompiledExpr = null,
    input_source_ids: [][]const u8 = &.{},
};

const LoadedNode = union(enum) {
    input: LoadedInput,
    @"const": LoadedConst,
    expr: LoadedExpr,
    wasm: LoadedWasm,

    fn id(self: LoadedNode) []const u8 {
        return switch (self) {
            .input => |n| n.id,
            .@"const" => |n| n.id,
            .expr => |n| n.id,
            .wasm => |n| n.id,
        };
    }

    fn outputKind(self: LoadedNode) schema.PortKind {
        return switch (self) {
            .input => |n| n.output_kind,
            .@"const" => |n| n.output_kind,
            .expr => |n| n.output_kind,
            .wasm => |n| n.output_kind,
        };
    }
};

const OutputPlan = struct {
    name: []const u8,
    slot: usize,
};

pub const GraphRunner = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    def: schema.NormalizedGraphDefinition,
    topology: topo_mod.Topology,
    /// node_id → dense slot index (arena keys).
    slot_of: std.StringHashMap(usize),
    loaded: std.StringHashMap(LoadedNode),
    /// Evaluation order as loaded node pointers / ids.
    ordered_ids: [][]const u8,
    outputs_plan: []OutputPlan,
    value_slots: []?Value,
    ctx: *MathZig,
    engine: engine_mod.VmEngine,
    owns_ctx: bool,
    /// Last human-readable error (cycle nodes, kind mismatch detail).
    last_error_buf: [512]u8 = undefined,
    last_error_len: usize = 0,

    /// Load from graph JSON text. Creates an owned MathZig context.
    pub fn load(allocator: std.mem.Allocator, json_text: []const u8) GraphError!GraphRunner {
        const ctx = try MathZig.init(allocator);
        errdefer ctx.deinit();
        return loadWithContext(allocator, json_text, ctx, true);
    }

    /// Load using a caller-owned MathZig context (`owns_ctx=false` → not deinited on dispose).
    pub fn loadWithContext(
        allocator: std.mem.Allocator,
        json_text: []const u8,
        ctx: *MathZig,
        owns_ctx: bool,
    ) GraphError!GraphRunner {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const def = schema.parseGraphDefinition(a, json_text) catch |err| {
            return mapSchemaErr(err);
        };

        var topology = topo_mod.topoSort(allocator, def.nodes, def.edges) catch |err| {
            if (err == error.Cycle) {
                const cycle = topo_mod.takeLastCycleNodes();
                defer if (cycle.len > 0) allocator.free(cycle);
                var self_tmp: GraphRunner = undefined;
                self_tmp.last_error_len = 0;
                setErrFmt(&self_tmp, "Graph contains a cycle involving: {s}.", .{cycle});
                // Can't return self_tmp; stash via thread... Use a package buffer:
                cycle_error_store(cycle);
                return error.Cycle;
            }
            return mapTopoErr(err);
        };
        errdefer topology.deinit(allocator);

        try validateNodePorts(def, topology);
        try typeCheckEdges(def, topology);

        var loaded = std.StringHashMap(LoadedNode).init(allocator);
        errdefer {
            var lit = loaded.iterator();
            while (lit.next()) |e| freeLoaded(allocator, ctx, e.value_ptr);
            loaded.deinit();
        }

        var engine = engine_mod.VmEngine.init(ctx);

        for (topology.ordered) |node| {
            switch (node) {
                .input => |n| {
                    try loaded.put(n.id, .{ .input = .{
                        .id = n.id,
                        .name = n.name,
                        .output_kind = n.kind,
                    } });
                },
                .@"const" => |n| {
                    // Const value is owned by def; retain for loaded slot source.
                    n.value.retain();
                    try loaded.put(n.id, .{ .@"const" = .{
                        .id = n.id,
                        .value = n.value,
                        .output_kind = n.kind,
                    } });
                },
                .expr => |n| {
                    // Ensure ports exist as variables before compile.
                    for (n.inputs) |pname| ctx.setNumber(pname, 0);
                    for (n.params) |p| ctx.setNumber(p.name, p.value);

                    const compiled = engine.compile(n.expr) catch return error.CompileError;

                    // Copy params into allocator-owned mutable store.
                    const params_copy = try allocator.alloc(schema.ParamEntry, n.params.len);
                    errdefer allocator.free(params_copy);
                    @memcpy(params_copy, n.params);

                    const incoming = topology.incoming.get(n.id).?;
                    const src_ids = try allocator.alloc([]const u8, n.inputs.len);
                    errdefer allocator.free(src_ids);
                    for (n.inputs, 0..) |port, i| {
                        const src = incoming.get(port) orelse return error.UnconnectedPort;
                        src_ids[i] = src.node_id;
                    }

                    try loaded.put(n.id, .{ .expr = .{
                        .id = n.id,
                        .expr_text = n.expr,
                        .inputs = n.inputs,
                        .input_kinds = n.input_kinds,
                        .params = params_copy,
                        .output_kind = n.output_kind,
                        .compiled = compiled,
                        .input_source_ids = src_ids,
                    } });
                },
                .wasm => |n| {
                    if (n.expr == null) return error.WasmPhase2Required;
                    const expr_text = n.expr.?;
                    for (n.inputs) |pname| ctx.setNumber(pname, 0);
                    for (n.params) |p| ctx.setNumber(p.name, p.value);
                    const compiled = engine.compile(expr_text) catch return error.CompileError;

                    const params_copy = try allocator.alloc(schema.ParamEntry, n.params.len);
                    errdefer allocator.free(params_copy);
                    @memcpy(params_copy, n.params);

                    const inc = topology.incoming.get(n.id).?;
                    const src_ids = try allocator.alloc([]const u8, n.inputs.len);
                    errdefer allocator.free(src_ids);
                    for (n.inputs, 0..) |port, i| {
                        const src = inc.get(port) orelse return error.UnconnectedPort;
                        src_ids[i] = src.node_id;
                    }

                    // Optional manifest validation
                    if (n.manifest_json) |mj| {
                        _ = manifest_mod.parseManifestJson(a, mj) catch return error.InvalidManifest;
                    }

                    try loaded.put(n.id, .{ .wasm = .{
                        .id = n.id,
                        .expr_text = expr_text,
                        .inputs = n.inputs,
                        .input_kinds = n.input_kinds,
                        .params = params_copy,
                        .output_kind = n.output_kind,
                        .compiled = compiled,
                        .input_source_ids = src_ids,
                    } });
                },
            }
        }

        // Slot map + ordered ids
        var slot_of = std.StringHashMap(usize).init(allocator);
        errdefer slot_of.deinit();
        var ordered_ids = try allocator.alloc([]const u8, topology.ordered.len);
        errdefer allocator.free(ordered_ids);
        for (topology.ordered, 0..) |node, i| {
            ordered_ids[i] = node.id();
            try slot_of.put(node.id(), i);
        }

        var outputs_plan: std.ArrayListUnmanaged(OutputPlan) = .empty;
        errdefer outputs_plan.deinit(allocator);
        for (def.outputs) |out| {
            const parsed = schema.parseGraphRef(out.ref) catch return error.InvalidOutputRef;
            if (!std.mem.eql(u8, parsed.port, "out")) return error.InvalidOutputRef;
            const slot = slot_of.get(parsed.node_id) orelse return error.InvalidOutputRef;
            try outputs_plan.append(allocator, .{ .name = out.name, .slot = slot });
        }

        const value_slots = try allocator.alloc(?Value, topology.ordered.len);
        @memset(value_slots, null);

        return .{
            .allocator = allocator,
            .arena = arena,
            .def = def,
            .topology = topology,
            .slot_of = slot_of,
            .loaded = loaded,
            .ordered_ids = ordered_ids,
            .outputs_plan = try outputs_plan.toOwnedSlice(allocator),
            .value_slots = value_slots,
            .ctx = ctx,
            .engine = engine,
            .owns_ctx = owns_ctx,
            .last_error_len = 0,
        };
    }

    pub fn dispose(self: *GraphRunner) void {
        // Release slots
        for (self.value_slots) |slot| {
            if (slot) |v| v.release();
        }
        self.allocator.free(self.value_slots);

        var lit = self.loaded.iterator();
        while (lit.next()) |e| freeLoaded(self.allocator, self.ctx, e.value_ptr);
        self.loaded.deinit();

        self.slot_of.deinit();
        self.allocator.free(self.ordered_ids);
        self.allocator.free(self.outputs_plan);

        schema.deinitConstValues(&self.def);
        self.topology.deinit(self.allocator);
        self.arena.deinit();

        if (self.owns_ctx) self.ctx.deinit();
        self.* = undefined;
    }

    pub fn lastError(self: *const GraphRunner) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    /// Run one tick. `inputs` maps runtime input name → Value.
    /// Caller must `releaseOutputs` the returned map.
    pub fn run(self: *GraphRunner, inputs: *const RunInputs) GraphError!RunOutputs {
        // Clear previous slot values
        for (self.value_slots) |*slot| {
            if (slot.*) |v| v.release();
            slot.* = null;
        }

        for (self.ordered_ids) |nid| {
            const slot = self.slot_of.get(nid).?;
            const node = self.loaded.getPtr(nid).?;
            switch (node.*) {
                .input => |inp| {
                    const val = inputs.get(inp.name) orelse {
                        setErrFmt(self, "Missing graph input '{s}'.", .{inp.name});
                        return error.MissingInput;
                    };
                    self.value_slots[slot] = value_transfer.transferValue(val);
                },
                .@"const" => |c| {
                    self.value_slots[slot] = value_transfer.transferValue(c.value);
                },
                .expr => |*e| {
                    self.value_slots[slot] = try self.evalCompute(e);
                },
                .wasm => |*w| {
                    // Dual-path only (expr present was required at load).
                    var as_expr = LoadedExpr{
                        .id = w.id,
                        .expr_text = w.expr_text.?,
                        .inputs = w.inputs,
                        .input_kinds = w.input_kinds,
                        .params = w.params,
                        .output_kind = w.output_kind,
                        .compiled = w.compiled,
                        .input_source_ids = w.input_source_ids,
                    };
                    self.value_slots[slot] = try self.evalCompute(&as_expr);
                },
            }
        }

        var outputs = RunOutputs.init(self.allocator);
        errdefer {
            var oit = outputs.iterator();
            while (oit.next()) |e| e.value_ptr.release();
            outputs.deinit();
        }

        for (self.outputs_plan) |op| {
            const v = self.value_slots[op.slot] orelse {
                setErrFmt(self, "Output '{s}' has no value.", .{op.name});
                return error.OutputMissing;
            };
            try outputs.put(op.name, value_transfer.transferValue(v));
        }
        return outputs;
    }

    /// Convenience: run with scalar f64 inputs by name.
    pub fn runScalars(self: *GraphRunner, pairs: []const struct { []const u8, f64 }) GraphError!RunOutputs {
        var inputs = RunInputs.init(self.allocator);
        defer inputs.deinit();
        for (pairs) |p| {
            try inputs.put(p[0], Value.initNumber(p[1]));
        }
        return self.run(&inputs);
    }

    pub fn releaseOutputs(outputs: *RunOutputs) void {
        var it = outputs.iterator();
        while (it.next()) |e| e.value_ptr.release();
        outputs.deinit();
    }

    /// Update a runtime-tunable number param (next tick picks it up).
    pub fn setParam(self: *GraphRunner, node_id: []const u8, name: []const u8, value: f64) GraphError!void {
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        const node = self.loaded.getPtr(node_id) orelse {
            setErrFmt(self, "Unknown graph node '{s}'.", .{node_id});
            return error.UnknownNode;
        };
        switch (node.*) {
            .expr => |*e| {
                for (e.params) |*p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        p.value = value;
                        return;
                    }
                }
                setErrFmt(self, "Node '{s}' has no param '{s}'.", .{ node_id, name });
                return error.UnknownParam;
            },
            .wasm => |*w| {
                for (w.params) |*p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        p.value = value;
                        return;
                    }
                }
                setErrFmt(self, "Node '{s}' has no param '{s}'.", .{ node_id, name });
                return error.UnknownParam;
            },
            else => {
                setErrFmt(self, "Node '{s}' does not have params.", .{node_id});
                return error.NoParams;
            },
        }
    }

    /// Test-only observability: live Value handles + slot/instance counts.
    pub fn debugStats(self: *const GraphRunner) DebugStats {
        const snap = live_handles.snapshot();
        var instance_count: usize = 0;
        var it = self.loaded.iterator();
        while (it.next()) |e| {
            switch (e.value_ptr.*) {
                .expr, .wasm => instance_count += 1,
                else => {},
            }
        }
        return .{
            .live_value_handles = snap.total,
            .live_matrix = snap.matrix,
            .live_series = snap.series,
            .live_record = snap.record,
            .slot_count = self.value_slots.len,
            .instance_count = instance_count,
            .wasm_memory_pages = 0,
        };
    }

    /// Hot-reload one expr node: recompile, require compatible output kind,
    /// preserve param values. On incompatibility or compile failure, keep the
    /// previous node running (reject).
    pub fn reload(self: *GraphRunner, node_id: []const u8, expr: []const u8) GraphError!void {
        if (expr.len == 0) {
            setErrFmt(self, "reload('{s}'): expr must be non-empty.", .{node_id});
            return error.MissingExpr;
        }
        const node = self.loaded.getPtr(node_id) orelse {
            setErrFmt(self, "Unknown graph node '{s}'.", .{node_id});
            return error.UnknownNode;
        };
        if (node.* != .expr) {
            setErrFmt(self, "reload() only supports expr nodes; '{s}' is not expr.", .{node_id});
            return error.UnknownNode;
        }
        const e = &node.expr;

        // Compile first — on failure keep old compiled.
        const new_compiled = self.engine.compile(expr) catch {
            setErrFmt(self, "reload('{s}') compile failed: {s}", .{ node_id, self.engine.lastError() });
            return error.CompileError;
        };
        errdefer self.engine.freeCompiled(new_compiled);

        // Output kind is pinned by the graph definition / prior load. Native
        // VM cannot cheaply re-infer AOT result tags; accept same declared kind
        // (caller / tests use compatible exprs). Param store is preserved.
        const old_compiled = e.compiled;
        const old_text = e.expr_text;

        // Arena-copy new expr text so it outlives the caller's buffer.
        const owned_text = self.arena.allocator().dupe(u8, expr) catch {
            return error.OutOfMemory;
        };
        e.expr_text = owned_text;
        e.compiled = new_compiled;

        if (old_compiled) |c| self.engine.freeCompiled(c);
        _ = old_text; // previous arena text is abandoned with arena (ok)
    }

    fn evalCompute(self: *GraphRunner, e: *LoadedExpr) GraphError!Value {
        // Bind inputs by real port names.
        var bound: [engine_mod.MAX_PORTS]engine_mod.BoundPort = undefined;
        if (e.inputs.len > engine_mod.MAX_PORTS) return error.AliasLimitExceeded;
        for (e.inputs, 0..) |port, i| {
            const src_id = e.input_source_ids[i];
            const src_slot = self.slot_of.get(src_id) orelse return error.EvalError;
            const src_val = self.value_slots[src_slot] orelse {
                setErrFmt(self, "Node '{s}' input '{s}' has no value.", .{ e.id, port });
                return error.EvalError;
            };
            bound[i] = .{ .name = port, .value = src_val };
            self.ctx.setVariable(port, src_val);
        }
        for (e.params) |p| {
            self.ctx.setNumber(p.name, p.value);
        }

        if (e.compiled) |compiled| {
            const result = self.engine.evaluateCompiled(compiled) catch {
                setErrFmt(self, "Eval error on node '{s}': {s}", .{ e.id, self.engine.lastError() });
                return error.EvalError;
            };
            return result;
        }

        // Fallback: source eval
        const result = self.engine.evalExpr(e.expr_text, bound[0..e.inputs.len], e.params) catch {
            setErrFmt(self, "Eval error on node '{s}': {s}", .{ e.id, self.engine.lastError() });
            return error.EvalError;
        };
        return result;
    }
};

// --- helpers ---

fn freeLoaded(allocator: std.mem.Allocator, ctx: *MathZig, node: *LoadedNode) void {
    switch (node.*) {
        .@"const" => |c| c.value.release(),
        .expr => |e| {
            if (e.compiled) |c| ctx.freeExpr(c);
            allocator.free(e.params);
            allocator.free(e.input_source_ids);
        },
        .wasm => |w| {
            if (w.compiled) |c| ctx.freeExpr(c);
            allocator.free(w.params);
            allocator.free(w.input_source_ids);
        },
        .input => {},
    }
}

fn setErrFmt(self: *GraphRunner, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&self.last_error_buf, fmt, args) catch {
        const fallback = "graph error";
        @memcpy(self.last_error_buf[0..fallback.len], fallback);
        self.last_error_len = fallback.len;
        return;
    };
    self.last_error_len = msg.len;
}

fn validateNodePorts(def: schema.NormalizedGraphDefinition, topology: topo_mod.Topology) GraphError!void {
    for (def.nodes) |node| {
        switch (node) {
            .expr => |e| {
                if (e.inputs.len + e.params.len > engine_mod.MAX_PORTS) return error.AliasLimitExceeded;
                // Param/input name collision
                for (e.params) |p| {
                    for (e.inputs) |inp| {
                        if (std.mem.eql(u8, p.name, inp)) return error.UndeclaredPort;
                    }
                }
                const incoming = topology.incoming.get(e.id) orelse continue;
                var it = incoming.iterator();
                while (it.next()) |entry| {
                    const port = entry.key_ptr.*;
                    var declared = false;
                    for (e.inputs) |inp| {
                        if (std.mem.eql(u8, inp, port)) {
                            declared = true;
                            break;
                        }
                    }
                    if (!declared) return error.UndeclaredPort;
                }
                for (e.inputs) |inp| {
                    if (!incoming.contains(inp)) return error.UnconnectedPort;
                }
            },
            .wasm => |w| {
                if (w.expr == null) return error.WasmPhase2Required;
                const incoming = topology.incoming.get(w.id) orelse continue;
                for (w.inputs) |inp| {
                    if (!incoming.contains(inp)) return error.UnconnectedPort;
                }
                var it = incoming.iterator();
                while (it.next()) |entry| {
                    const port = entry.key_ptr.*;
                    var declared = false;
                    for (w.inputs) |inp| {
                        if (std.mem.eql(u8, inp, port)) {
                            declared = true;
                            break;
                        }
                    }
                    if (!declared) return error.UndeclaredPort;
                }
            },
            else => {},
        }
    }
}

fn typeCheckEdges(def: schema.NormalizedGraphDefinition, topology: topo_mod.Topology) GraphError!void {
    for (def.nodes) |node| {
        switch (node) {
            .expr, .wasm => {},
            else => continue,
        }
        const incoming = topology.incoming.get(node.id()) orelse continue;
        var it = incoming.iterator();
        while (it.next()) |entry| {
            const port = entry.key_ptr.*;
            const source = entry.value_ptr.*;
            const consumer_kind = schema.nodeInputKind(node, port) orelse continue;
            var producer_kind: schema.PortKind = .number;
            var found = false;
            for (def.nodes) |src| {
                if (std.mem.eql(u8, src.id(), source.node_id)) {
                    producer_kind = src.outputKind();
                    found = true;
                    break;
                }
            }
            if (!found) continue;
            if (!schema.kindsCompatible(producer_kind, consumer_kind)) return error.KindMismatch;
        }
    }
}

fn mapSchemaErr(err: anyerror) GraphError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownPortKind => error.UnknownPortKind,
        error.InvalidGraphRef => error.InvalidGraphRef,
        error.InvalidGraphJson => error.InvalidGraphJson,
        error.MissingNodes => error.MissingNodes,
        error.MissingType => error.MissingType,
        error.MissingExpr => error.MissingExpr,
        error.InvalidConstValue => error.InvalidConstValue,
        error.InvalidNumber => error.InvalidNumber,
        error.DuplicateNode => error.DuplicateNode,
        error.EmptyNodeId => error.EmptyNodeId,
        error.LimitExceeded => error.LimitExceeded,
        error.SourceTooLarge => error.SourceTooLarge,
        error.IdentifierTooLong => error.IdentifierTooLong,
        error.ManifestNotObject => error.InvalidManifest,
        error.IncompatibleAbiVersion => error.InvalidManifest,
        error.DuplicatePort => error.InvalidManifest,
        error.MalformedKind => error.InvalidManifest,
        error.InvalidManifest => error.InvalidManifest,
        else => error.InvalidGraphJson,
    };
}

fn mapTopoErr(err: anyerror) GraphError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EmptyNodeId => error.EmptyNodeId,
        error.DuplicateNode => error.DuplicateNode,
        error.EdgeSourceMissing => error.EdgeSourceMissing,
        error.EdgeTargetMissing => error.EdgeTargetMissing,
        error.EdgeSourceMustBeOut => error.EdgeSourceMustBeOut,
        error.MultipleSources => error.MultipleSources,
        error.Cycle => error.Cycle,
        else => error.InvalidGraphJson,
    };
}

/// Package-level last cycle message for load errors without GraphRunner instance.
var last_cycle_msg: [256]u8 = undefined;
var last_cycle_msg_len: usize = 0;

fn cycle_error_store(cycle: []const u8) void {
    const msg = std.fmt.bufPrint(&last_cycle_msg, "Graph contains a cycle involving: {s}.", .{cycle}) catch {
        last_cycle_msg_len = 0;
        return;
    };
    last_cycle_msg_len = msg.len;
}

pub fn lastCycleError() []const u8 {
    return last_cycle_msg[0..last_cycle_msg_len];
}

// --- unit smoke (full goldens in tests/zig/graph/) ---

test "GraphRunner scalar double-then-add" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "x", "type": "input"},
        \\    {"id": "g", "type": "expr", "expr": "x * 2", "inputs": ["x"]},
        \\    {"id": "f", "type": "expr", "expr": "x + 1", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "x.out", "to": "g.x"},
        \\    {"from": "g.out", "to": "f.x"}
        \\  ],
        \\  "outputs": {"value": "f.out"}
        \\}
    ;
    var runner = try GraphRunner.load(allocator, json);
    defer runner.dispose();

    var outs = try runner.runScalars(&.{.{ "x", 7 }});
    defer GraphRunner.releaseOutputs(&outs);
    const v = outs.get("value").?;
    try std.testing.expectApproxEqAbs(@as(f64, 15), v.toNumber().?, 1e-12);
}
