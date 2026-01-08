const std = @import("std");
const mathzig = @import("../mathzig.zig");
const CompiledExpr = mathzig.CompiledExpr;
const Instruction = mathzig.Instruction;
const Opcode = mathzig.Opcode;
const BuiltinFn = mathzig.BuiltinFn;
const UserFunction = mathzig.UserFunction;
const Predicate = @import("../timeseries/predicates.zig").Predicate;
const Dimensions = @import("../units/unit_registry.zig").Dimensions;
const WasmModule = @import("module.zig").WasmModule;
const types = @import("types.zig");
const leb = @import("leb128.zig");
const list_writer = @import("list_writer.zig");
const math_lib = @import("math_lib.zig");
const abi = @import("abi.zig");
const graph_manifest = @import("graph_manifest.zig");

/// Host-visible unit runtime mode embedded in `mathzig.abi` (task-15).
/// Accurate emission only: `host_dynamic` requires an actual non-folded
/// dynamic unit op in the emitted module, not a pre-fold presence.
pub const UnitRuntimeMode = enum {
    none,
    static,
    host_dynamic,

    pub fn jsonName(self: UnitRuntimeMode) []const u8 {
        return switch (self) {
            .none => "none",
            .static => "static",
            .host_dynamic => "host_dynamic",
        };
    }
};

/// Compile-time unit metadata tracked in parallel with the type stack.
/// Values on the wasm stack are always SI-normalized magnitudes; this
/// records the dimensions (and preferred display unit) so conversion can
/// be folded and the host can re-attach the unit via the custom section.
const UnitMeta = struct {
    dims: Dimensions = .{},
    /// Scale of the *named* unit relative to SI (e.g. cm → 0.01). For derived
    /// products this is 1.0 (pure SI magnitude).
    scale: f64 = 1.0,
    offset: f64 = 0.0,
    name: ?[]const u8 = null,

    fn fromUnitValue(u: mathzig.UnitValue) UnitMeta {
        return .{
            .dims = u.info.dimensions,
            .scale = u.info.scale,
            .offset = u.info.offset,
            .name = u.info.name,
        };
    }

    fn isScalar(self: UnitMeta) bool {
        return self.dims.isScalar();
    }
};

pub const CompilerOptions = struct {
    function_name: []const u8 = "eval",
    num_params: usize = 0,
    standalone: bool = false,
    /// Dump bytecode / codegen traces to stderr.
    verbose: bool = false,
    /// Export eval_batch(in_ptr, out_ptr, count) for one-parameter numeric roots.
    export_batch: bool = true,
    /// Force memory + heap_ptr + reset_heap + alloc even when the expression
    /// itself never touches the heap (node-graph modules always need them so
    /// the host can write non-scalar inputs into the consumer heap).
    force_heap: bool = false,
    /// Optional per-param ValueTags (length == num_params). When set, seeds
    /// `inferUserParamTypes` so declared node ports (e.g. `--in x:matrix`)
    /// type-check as matrix/complex/… even without a matrix literal on the
    /// other side of an op (`x * alpha`). Owned by the caller.
    param_tags: ?[]const mathzig.ValueTag = null,
};

/// One root expression to place in a multi-unit module (Stage A scaffold).
pub const CompileUnit = struct {
    expr: *const CompiledExpr,
    name: []const u8,
    num_params: usize = 0,
    /// When false the function is defined (callable from tick) but not exported.
    export_fn: bool = true,
    /// Optional per-param ValueTags (length == num_params). Seeds
    /// `inferUserParamTypes` for this unit only (full-value fuse, Spec 07).
    /// Owned by the caller for the duration of `compileUnits` / `compileFusedTick`.
    param_tags: ?[]const mathzig.ValueTag = null,
};

/// Options shared by multi-unit and fused-tick compilation.
pub const MultiCompileOptions = struct {
    standalone: bool = false,
    verbose: bool = false,
    force_heap: bool = false,
    /// Only meaningful for a single 1-param root (same as CompilerOptions.export_batch).
    export_batch: bool = false,
    param_tags: ?[]const mathzig.ValueTag = null,
    /// Emit `mathzig.abi` custom section (disable when the caller will emit later).
    emit_abi: bool = true,
    /// Index into units for ABI result_tag; null = last unit (or number if empty).
    primary_unit: ?usize = null,
};

/// Where a fused node arg comes from when building `tick` (Spec 03 Stage B).
pub const FuseArgSource = union(enum) {
    /// Graph input slot (tick param index = this).
    graph_input: u32,
    /// Graph param slot (tick param index = n_inputs + this).
    graph_param: u32,
    /// Result of a prior topo node (local after tick params).
    node_result: u32,
    /// Compile-time constant (const plan nodes).
    const_value: f64,
};

/// One reachable compute node for fused tick codegen.
pub const FuseNodeUnit = struct {
    id: []const u8,
    expr: *const CompiledExpr,
    /// Parallel to the node's eval params (inputs then params, as compiled).
    arg_sources: []const FuseArgSource,
    /// Optional parallel to `arg_sources`: declared port kinds for seeding
    /// AOT param tags (matrix/complex/record/series). When empty, inference only.
    arg_kinds: []const abi.WireKind = &.{},
    /// Declared result kind of this node (used for force_heap + diagnostics).
    output_kind: abi.WireKind = .number,
};

/// Graph output value port for fused codegen.
pub const FuseOutput = struct {
    name: []const u8,
    kind: abi.WireKind = .number,
    /// Index into `FuseCompilePlan.nodes`.
    from_node: u32,
};

/// Fuse plan input for `compileFusedTick` (Zig mirror of TS FusePlan subset).
/// Spec 07: I/O kinds may be any `abi.WireKind` (matrix/complex/record/series/…).
/// Internal edges pass non-scalars as f64 wire (ptr/handle) in one shared heap.
pub const FuseCompilePlan = struct {
    inputs: []const graph_manifest.Port = &.{},
    params: []const graph_manifest.Port = &.{},
    nodes: []const FuseNodeUnit,
    outputs: []const FuseOutput,
    out_mode: graph_manifest.OutMode = .table,
    /// Export `n_<sanitized_id>` helpers (Stage A scaffold / debug).
    export_node_helpers: bool = false,
    entry_name: []const u8 = "tick",
};

const FunctionToCompile = struct {
    expr: *const CompiledExpr,
    name: []const u8,
    params_count: usize,
    param_offset: u32 = 0,
    wasm_idx: u32 = 0,
    /// When false, skip export section entry (still callable inside the module).
    export_fn: bool = true,
};

pub const WasmCompiler = struct {
    allocator: std.mem.Allocator,
    module: WasmModule,
    user_function_map: std.AutoHashMap(*const CompiledExpr, u32),
    user_function_params: std.AutoHashMap(*const CompiledExpr, u8),
    local_funcs: std.AutoHashMap(*const CompiledExpr, std.ArrayListUnmanaged(*const CompiledExpr)),
    scope_base: std.AutoHashMap(*const CompiledExpr, u32),
    string_map: std.AutoHashMap(*const CompiledExpr, std.AutoHashMap(usize, u32)),
    string_dedup: std.StringHashMap(u32),
    builtin_map: std.AutoHashMap(BuiltinFn, u32),
    builtin_where_map: std.AutoHashMap(BuiltinFn, u32),
    predicate_dedup: std.AutoHashMap(*const Predicate, u32),
    pow_func_idx: ?u32 = null,
    fmod_import_idx: ?u32 = null,
    gemm_import_idx: ?u32 = null,
    /// Bump allocator export index (set when linear memory is present).
    alloc_func_idx: ?u32 = null,
    /// Mutable i32 global: last eval result kind (ValueTag discriminant).
    /// Quiet NaN is the f64 transport for empty values; this side-channel lets
    /// the host recover `undefined` / `null` vs genuine math NaN.
    result_kind_idx: ?u32 = null,
    standalone: bool = false,
    heap_ptr_idx: u32 = 0,
    current_data_offset: u32 = 1024,
    next_user_func_id: u16 = 0,
    globals: std.AutoHashMap(u8, f64),
    var_types: std.AutoHashMapUnmanaged(u32, mathzig.ValueTag),
    type_stack: std.ArrayListUnmanaged(mathzig.ValueTag),
    /// Parallel to type_stack: unit metadata when the slot is a unit (or a
    /// number carrying known unit dimensions from static analysis); null
    /// otherwise. Kept in lock-step by pushType/popType.
    unit_stack: std.ArrayListUnmanaged(?UnitMeta) = .empty,
    loop_headers: std.AutoHashMap(usize, usize),
    verbose: bool = false,
    /// Env imports actually required by the compiled module (fills the
    /// mathzig.abi custom section; see src/wasm/abi.zig).
    import_manifest: std.ArrayListUnmanaged(abi.ImportEntry) = .empty,
    /// Builtin usages collected during discovery. Registration is deferred
    /// and runs in two phases (env imports first, generated bodies second)
    /// because the wasm function index space puts imports before defined
    /// functions and emitted code embeds indices immediately — an import
    /// added after any defined function silently shifts every recorded index.
    pending_builtins: std.ArrayListUnmanaged(abi.ImportEntry) = .empty,
    pending_needs_gemm: bool = false,
    pending_needs_pow: bool = false,
    pending_needs_fmod: bool = false,
    /// Required runtime set computed during discovery (abi.RequiredRuntimeSet).
    required_runtime: abi.RequiredRuntimeSet = .{},
    /// Diagnostic for the last standalone hard-error (named builtin + tier).
    standalone_error_msg: ?[]const u8 = null,
    standalone_error_buf: [160]u8 = undefined,
    /// Statically-inferred result tag of the root expression (from the
    /// codegen type stack), embedded in the custom section so hosts stop
    /// guessing the result type from the source text.
    result_tag: mathzig.ValueTag = .number,
    /// When result_tag is .unit (or a unit magnitude folded to SI), the
    /// dimensions/name for host re-attachment via the custom section.
    result_unit: ?UnitMeta = null,
    /// Honesty flag for hosts (task-15): whether this module needs dynamic
    /// unit support at load time. See `UnitRuntimeMode` / emitAbiManifest.
    /// - none: no unit ops observed
    /// - static: only compile-time folded unit ops / annotations
    /// - host_dynamic: a non-folded unit op was actually emitted (env.conv /
    ///   env.number / unresolvable-without-import path would have fired)
    unit_runtime: UnitRuntimeMode = .none,
    /// True once any static unit metadata was pushed or a static fold ran.
    saw_static_unit: bool = false,
    /// True once a non-folded dynamic unit builtin call was emitted.
    emitted_dynamic_unit_op: bool = false,
    /// Series wire representation for this module (custom section flag).
    /// Env-import mode keeps host handles; standalone Tier 4 uses linear memory.
    series_repr: abi.SeriesRepresentation = .host_handle,
    /// Seed tags for root-param inference (from CompilerOptions.param_tags).
    forced_param_tags: ?[]const mathzig.ValueTag = null,
    /// User function name → wasm function index (standalone ODE specialization).
    user_fn_name_map: std.StringHashMap(u32),
    /// Specialized ODE helpers: key = (is_euler ? 1 : 0) << 32 | deriv_wasm_idx
    ode_helper_map: std.AutoHashMap(u64, u32),
    /// Pending ODE code bodies (must emit after user-function codes to keep
    /// addFunction/addCode index alignment).
    pending_ode_codes: std.ArrayListUnmanaged(struct { func_idx: u32, code: []u8 }) = .empty,
    /// Series-specific helpers when a builtin also has a matrix body (mean/sum/…).
    series_helper_map: std.AutoHashMap(BuiltinFn, u32),
    /// Parallel to type_stack: static string value when the slot is a string const.
    string_hint_stack: std.ArrayListUnmanaged(?[]const u8) = .empty,
    /// Static ODE targets discovered during discovery (name for specialization).
    pending_ode_targets: std.ArrayListUnmanaged(struct { builtin: BuiltinFn, name: []const u8 }) = .empty,
    /// Complex constants pre-materialized in the data segment before the heap
    /// base is frozen. Key = re/im bit patterns.
    complex_const_offsets: std.AutoHashMap(u128, u32),
    /// Pre-folded `toLaTeX("static")` results (source string → data offset),
    /// materialized before the heap base is frozen.
    latex_fold_map: std.StringHashMap(u32),
    /// Set by ensureLinearMemoryAndHeap: the heap_ptr global's initializer is
    /// fixed, so any further data-segment append would overlap the heap.
    data_frozen: bool = false,
    /// Statically-inferred result tag per user function (pre-codegen pass),
    /// so call_user sites can type non-number results correctly.
    fn_result_tags: std.AutoHashMap(*const CompiledExpr, mathzig.ValueTag),
    /// Field name → statically-inferred value tag, recorded at rec_create
    /// sites so rec_get can type non-number fields (module-wide; a field name
    /// reused with different types keeps the last recorded tag).
    record_field_tags: std.StringHashMap(mathzig.ValueTag),

    pub fn init(allocator: std.mem.Allocator) WasmCompiler {
        return WasmCompiler{
            .allocator = allocator,
            .module = WasmModule.init(allocator),
            .user_function_map = std.AutoHashMap(*const CompiledExpr, u32).init(allocator),
            .user_function_params = std.AutoHashMap(*const CompiledExpr, u8).init(allocator),
            .local_funcs = std.AutoHashMap(*const CompiledExpr, std.ArrayListUnmanaged(*const CompiledExpr)).init(allocator),
            .scope_base = std.AutoHashMap(*const CompiledExpr, u32).init(allocator),
            .string_map = std.AutoHashMap(*const CompiledExpr, std.AutoHashMap(usize, u32)).init(allocator),
            .string_dedup = std.StringHashMap(u32).init(allocator),
            .builtin_map = std.AutoHashMap(BuiltinFn, u32).init(allocator),
            .builtin_where_map = std.AutoHashMap(BuiltinFn, u32).init(allocator),
            .predicate_dedup = std.AutoHashMap(*const Predicate, u32).init(allocator),
            .globals = std.AutoHashMap(u8, f64).init(allocator),
            .var_types = .empty,
            .type_stack = .empty,
            .unit_stack = .empty,
            .loop_headers = std.AutoHashMap(usize, usize).init(allocator),
            .user_fn_name_map = std.StringHashMap(u32).init(allocator),
            .ode_helper_map = std.AutoHashMap(u64, u32).init(allocator),
            .series_helper_map = std.AutoHashMap(BuiltinFn, u32).init(allocator),
            .complex_const_offsets = std.AutoHashMap(u128, u32).init(allocator),
            .latex_fold_map = std.StringHashMap(u32).init(allocator),
            .fn_result_tags = std.AutoHashMap(*const CompiledExpr, mathzig.ValueTag).init(allocator),
            .record_field_tags = std.StringHashMap(mathzig.ValueTag).init(allocator),
        };
    }

    pub fn deinit(self: *WasmCompiler) void {
        self.module.deinit();
        self.user_function_map.deinit();
        self.user_function_params.deinit();
        var it = self.local_funcs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.local_funcs.deinit();
        self.scope_base.deinit();
        var str_it = self.string_map.iterator();
        while (str_it.next()) |entry| {
            var m = entry.value_ptr;
            m.deinit();
        }
        self.string_map.deinit();
        self.string_dedup.deinit();
        self.builtin_map.deinit();
        self.builtin_where_map.deinit();
        self.predicate_dedup.deinit();
        self.globals.deinit();
        self.var_types.deinit(self.allocator);
        self.type_stack.deinit(self.allocator);
        self.unit_stack.deinit(self.allocator);
        self.loop_headers.deinit();
        self.import_manifest.deinit(self.allocator);
        self.pending_builtins.deinit(self.allocator);
        self.user_fn_name_map.deinit();
        self.ode_helper_map.deinit();
        for (self.pending_ode_codes.items) |e| self.allocator.free(e.code);
        self.pending_ode_codes.deinit(self.allocator);
        self.series_helper_map.deinit();
        self.string_hint_stack.deinit(self.allocator);
        self.pending_ode_targets.deinit(self.allocator);
        self.complex_const_offsets.deinit();
        self.latex_fold_map.deinit();
        self.fn_result_tags.deinit();
        self.record_field_tags.deinit();
    }

    fn isSimpleScalar(expr: *const CompiledExpr) bool {
        for (expr.code) |inst| {
            switch (inst.opcode) {
                .push_const,
                .pop,
                .dup,
                .load_var,
                .store_var,
                .add,
                .sub,
                .mul,
                .div,
                .mod,
                .neg,
                .pos,
                .eq,
                .ne,
                .lt,
                .le,
                .gt,
                .ge,
                .halt,
                .nop,
                => {},
                else => return false,
            }
        }
        return true;
    }

    fn isPureRange(expr: *const CompiledExpr, start: usize, end: usize) bool {
        var pc = start;
        while (pc < end) : (pc += 1) {
            const inst = expr.code[pc];

            switch (inst.opcode) {
                .push_const,
                .load_var,
                .add,
                .sub,
                .mul,
                .div,
                .mod,
                .neg,
                .pos,
                .eq,
                .ne,
                .lt,
                .le,
                .gt,
                .ge,
                .and_,
                .or_,
                .not_,
                .band,
                .bor,
                .bxor,
                .bnot,
                .shl,
                .shr,
                .nop,
                => {},
                else => return false,
            }
        }
        return true;
    }

    fn isCompareOp(op: Opcode) bool {
        return switch (op) {
            .lt, .le, .gt, .ge, .eq, .ne => true,
            else => false,
        };
    }

    fn loopHasBreakToEnd(expr: *const CompiledExpr, loop_start: usize, loop_end: usize) bool {
        var pc = loop_start;
        while (pc < loop_end) : (pc += 1) {
            const inst = expr.code[pc];
            if (inst.opcode == .jmp_if_false and inst.operand == loop_end) {
                return true;
            }
        }
        return false;
    }

    fn isFastPowAt(expr: *const CompiledExpr, idx: usize) bool {
        if (idx == 0) return false;
        const prev = expr.code[idx - 1];
        if (prev.opcode != .push_const) return false;
        const c_idx: u8 = @intCast(prev.operand);
        const val = expr.constants[c_idx];
        if (val.tag != .number) return false;
        const n = val.data.number;
        return n == 2.0 or n == 3.0;
    }

    fn usesHeap(expr: *const CompiledExpr) bool {
        for (expr.code) |inst| {
            switch (inst.opcode) {
                .mat_create,
                // Fused 3-element matrix create allocates via heap_ptr too
                .mat_create_3,
                .mat_index,
                .emul,
                .ediv,
                .epow,
                .rec_create,
                .rec_get,
                .rec_get_dyn,
                .unit_create,
                .unit_convert,
                .make_slice,
                .get_index,
                .set_index,
                // Fused matrix loads read through linear memory
                .load_var_index_0,
                .load_var_index_1,
                .load_var_index_2,
                .load_var_index_3,
                .load_var_index_const,
                => return true,
                else => {},
            }
        }
        return false;
    }

    pub fn compile(self: *WasmCompiler, expr: *const CompiledExpr, options: CompilerOptions) !void {
        const unit = CompileUnit{
            .expr = expr,
            .name = options.function_name,
            .num_params = options.num_params,
            .export_fn = true,
        };
        var idxs: [1]u32 = .{0};
        try self.compileUnits(&.{unit}, .{
            .standalone = options.standalone,
            .verbose = options.verbose,
            .force_heap = options.force_heap,
            .export_batch = options.export_batch,
            .param_tags = options.param_tags,
            .emit_abi = true,
            .primary_unit = 0,
        }, &idxs);
    }

    /// Stage A multi-export scaffold: one module, many named root exports.
    /// Shared env import table (union) and single heap when any unit needs it.
    /// Diamonds may recompute if the host chains exports — prefer
    /// `compileFusedTick` for single-pass multi-out (Stage B).
    /// Rejects duplicate `unit.name` values (`error.DuplicateExportName`).
    pub fn compileMany(self: *WasmCompiler, units: []const CompileUnit, options: MultiCompileOptions) !void {
        if (units.len == 0) return error.EmptyFusePlan;
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        for (units) |u| {
            const gop = try seen.getOrPut(u.name);
            if (gop.found_existing) return error.DuplicateExportName;
        }
        const idxs = try self.allocator.alloc(u32, units.len);
        defer self.allocator.free(idxs);
        try self.compileUnits(units, options, idxs);
    }

    /// Stage B fused tick: one entry `tick(inputs…, params…) -> i32` (table ptr)
    /// or named `out_*` exports. Node helpers optional via `export_node_helpers`.
    ///
    /// Each node's `expr` must already be compiled with its local ports as
    /// variables `0..arg_sources.len-1` (inputs then params), same as `--node`.
    ///
    /// Spec 07 full-value: non-scalar producers leave f64 wire (ptr/handle) in
    /// result locals; consumers take those as f64 args. One shared heap for the
    /// whole tick — host resets only around the whole tick, never between nodes.
    pub fn compileFusedTick(self: *WasmCompiler, plan: FuseCompilePlan, options: MultiCompileOptions) !void {
        try validateFusePlan(plan);

        // force_heap for table out_mode or any non-number I/O / intermediate node
        // (Spec 01/03/07). Defensive even when usesHeap would also catch mat_create.
        var force_heap = options.force_heap or plan.out_mode == .table;
        for (plan.outputs) |o| {
            if (wireKindNeedsHeap(o.kind)) force_heap = true;
        }
        for (plan.inputs) |inp| {
            if (wireKindNeedsHeap(inp.kind)) force_heap = true;
        }
        for (plan.params) |p| {
            if (wireKindNeedsHeap(p.kind)) force_heap = true;
        }
        for (plan.nodes) |n| {
            if (wireKindNeedsHeap(n.output_kind)) force_heap = true;
            for (n.arg_kinds) |k| {
                if (wireKindNeedsHeap(k)) force_heap = true;
            }
        }

        // Sanitize entry name (owned for the duration of this call; export section copies bytes).
        const entry_name = try sanitizeExportName(self.allocator, "", plan.entry_name);
        defer self.allocator.free(entry_name);
        if (entry_name.len == 0) return error.InvalidExportName;

        // Build owned sanitized export names for node helpers; reject collisions.
        var name_bufs = std.ArrayListUnmanaged([]u8).empty;
        defer {
            for (name_bufs.items) |n| self.allocator.free(n);
            name_bufs.deinit(self.allocator);
        }
        var seen_names = std.StringHashMap(void).init(self.allocator);
        defer seen_names.deinit();
        try seen_names.put(entry_name, {});

        // Per-unit ValueTag seeds (from declared arg_kinds). Freed after compileUnits.
        var tag_bufs = std.ArrayListUnmanaged([]mathzig.ValueTag).empty;
        defer {
            for (tag_bufs.items) |t| self.allocator.free(t);
            tag_bufs.deinit(self.allocator);
        }

        var units = try self.allocator.alloc(CompileUnit, plan.nodes.len);
        defer self.allocator.free(units);
        for (plan.nodes, 0..) |node, i| {
            const sanitized = try sanitizeExportName(self.allocator, "n_", node.id);
            try name_bufs.append(self.allocator, sanitized);
            const gop = try seen_names.getOrPut(sanitized);
            if (gop.found_existing) return error.DuplicateExportName;

            var unit_tags: ?[]const mathzig.ValueTag = null;
            if (node.arg_kinds.len > 0) {
                if (node.arg_kinds.len != node.arg_sources.len) return error.InvalidFuseArg;
                const tags = try self.allocator.alloc(mathzig.ValueTag, node.arg_kinds.len);
                errdefer self.allocator.free(tags);
                for (node.arg_kinds, 0..) |wk, ki| {
                    tags[ki] = wireKindToValueTag(wk);
                }
                try tag_bufs.append(self.allocator, tags);
                unit_tags = tags;
            }

            units[i] = .{
                .expr = node.expr,
                .name = sanitized,
                .num_params = node.arg_sources.len,
                .export_fn = plan.export_node_helpers,
                .param_tags = unit_tags,
            };
        }
        // Reserve out_* names for collision detection (emitted later for named_exports).
        var out_name_bufs = std.ArrayListUnmanaged([]u8).empty;
        defer {
            for (out_name_bufs.items) |n| self.allocator.free(n);
            out_name_bufs.deinit(self.allocator);
        }
        if (plan.out_mode == .named_exports) {
            for (plan.outputs) |o| {
                const on = try sanitizeExportName(self.allocator, "out_", o.name);
                try out_name_bufs.append(self.allocator, on);
                const gop = try seen_names.getOrPut(on);
                if (gop.found_existing) return error.DuplicateExportName;
            }
        }

        const node_idxs = try self.allocator.alloc(u32, plan.nodes.len);
        defer self.allocator.free(node_idxs);
        try self.compileUnits(units, .{
            .standalone = options.standalone,
            .verbose = options.verbose,
            .force_heap = force_heap,
            .export_batch = false,
            .param_tags = options.param_tags,
            .emit_abi = false,
            .primary_unit = 0,
        }, node_idxs);

        // Emit Stage B tick (and optional named out_*).
        const tick_params: u32 = @intCast(plan.inputs.len + plan.params.len);
        var plan_mut = plan;
        plan_mut.entry_name = entry_name;
        const tick_idx = try self.emitFusedTick(plan_mut, node_idxs, tick_params, out_name_bufs.items);

        // result_tag: first output's kind mapping, default number.
        self.result_tag = if (plan.outputs.len > 0) switch (plan.outputs[0].kind) {
            .number => .number,
            .boolean => .boolean,
            .matrix_ptr => .matrix,
            .complex_ptr => .complex,
            .record_ptr => .record,
            .string_ptr => .string,
            .series_handle => .series,
            .predicate_ptr => .predicate,
            .any => .number,
        } else .number;
        self.series_repr = if (self.standalone) .linear_memory else .host_handle;

        // ABI exports: tick, optional out_*, optional node helpers.
        // expr ptr is unused by emitAbiManifest (only name + params_count).
        var abi_exports = std.ArrayListUnmanaged(FunctionToCompile).empty;
        defer abi_exports.deinit(self.allocator);
        try abi_exports.append(self.allocator, .{
            .expr = plan.nodes[0].expr,
            .name = entry_name,
            .params_count = tick_params,
            .wasm_idx = tick_idx,
            .export_fn = true,
        });
        if (plan.out_mode == .named_exports) {
            for (out_name_bufs.items) |on| {
                try abi_exports.append(self.allocator, .{
                    .expr = plan.nodes[0].expr,
                    .name = on,
                    .params_count = tick_params,
                    .wasm_idx = 0, // unused by manifest
                    .export_fn = true,
                });
            }
        }
        if (plan.export_node_helpers) {
            for (plan.nodes, 0..) |node, i| {
                try abi_exports.append(self.allocator, .{
                    .expr = node.expr,
                    .name = units[i].name,
                    .params_count = node.arg_sources.len,
                    .wasm_idx = node_idxs[i],
                    .export_fn = true,
                });
            }
        }
        try self.emitAbiManifest(abi_exports.items, self.module.memory_count > 0);
        try self.emitGraphManifestSection(
            plan_mut,
            tick_params,
            out_name_bufs.items,
            if (plan.export_node_helpers) units else null,
        );
    }

    /// Shared multi-root compile path (import-first, single heap).
    /// `unit_wasm_idxs` must have length `units.len`; filled with each unit's wasm func index.
    fn compileUnits(
        self: *WasmCompiler,
        units: []const CompileUnit,
        options: MultiCompileOptions,
        unit_wasm_idxs: []u32,
    ) !void {
        std.debug.assert(unit_wasm_idxs.len == units.len);
        if (units.len == 0) return error.EmptyFusePlan;

        self.standalone = options.standalone;
        self.verbose = options.verbose;
        // Global fallback; per-unit tags (CompileUnit.param_tags) override during codegen.
        self.forced_param_tags = options.param_tags;

        if (self.verbose) {
            for (units) |u| {
                std.debug.print("Bytecode Dump ({s}):\n", .{u.name});
                for (u.expr.code, 0..) |inst, i| {
                    std.debug.print("{d}: {s} {d}\n", .{ i, @tagName(inst.opcode), inst.operand });
                }
            }
        }

        var functions = std.ArrayListUnmanaged(FunctionToCompile).empty;
        defer functions.deinit(self.allocator);

        const empty_inherited = [_]*const CompiledExpr{};
        // Track which discovered entries are unit roots so export_fn is applied.
        var root_export = std.AutoHashMap(*const CompiledExpr, bool).init(self.allocator);
        defer root_export.deinit();
        for (units) |u| {
            try root_export.put(u.expr, u.export_fn);
            try self.discoverFunctions(u.expr, u.name, u.num_params, 0, empty_inherited[0..], &functions);
        }
        // Apply export flags to root units (nested user funcs stay exported).
        for (functions.items) |*f| {
            if (root_export.get(f.expr)) |ex| f.export_fn = ex;
        }

        // Build RequiredRuntimeSet from discovery, then register in two phases:
        // ALL env imports first, generated function bodies second. Imports
        // occupy the first indices of the wasm function index space and
        // emitted code embeds indices immediately, so an import added after
        // any defined function would silently shift every already-recorded
        // index (module.addImport asserts this invariant).
        self.required_runtime = .{};
        self.required_runtime.needs_pow = self.pending_needs_pow;
        self.required_runtime.needs_fmod = self.pending_needs_fmod;
        self.required_runtime.needs_gemm = self.pending_needs_gemm;
        for (self.pending_builtins.items) |p| {
            self.required_runtime.addBuiltin(p.builtin, p.arg_count, p.is_where);
        }

        if (self.standalone) {
            if (self.required_runtime.formatUnresolved(&self.standalone_error_buf)) |msg| {
                self.standalone_error_msg = msg;
                return error.StandaloneUnsupportedImport;
            }
        }

        if (self.pending_needs_gemm and self.gemm_import_idx == null) {
            if (self.standalone) {
                // In-wasm gemm registered after heap setup.
            } else {
                const t = try self.module.addType(&[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, &[_]types.ValType{});
                self.gemm_import_idx = try self.module.addImport("env", "mathzig_gemm", .function, t);
            }
        }
        if (self.pending_needs_pow and !self.standalone) {
            try self.registerBuiltin(.log, 1);
            try self.registerBuiltin(.exp, 1);
        }
        if (self.pending_needs_fmod and !self.standalone) {
            try self.ensureFmodFunction();
        }
        for (self.pending_builtins.items) |p| {
            if (isGeneratedBodyBuiltin(p.builtin, self.standalone)) continue;
            if (p.is_where) {
                try self.registerBuiltinWhere(p.builtin, p.arg_count);
            } else {
                try self.registerBuiltin(p.builtin, p.arg_count);
            }
        }
        if (self.standalone) {
            try self.registerStandaloneScalarBodies();
            if (self.pending_needs_pow) try self.ensurePowFunction();
            if (self.pending_needs_fmod) try self.ensureFmodFunction();
            if (self.pending_needs_gemm) try self.ensureStandaloneGemm();
        } else {
            for (self.pending_builtins.items) |p| {
                if (!isGeneratedBodyBuiltin(p.builtin, self.standalone)) continue;
                try self.registerBuiltin(p.builtin, p.arg_count);
            }
            if (self.pending_needs_pow) try self.ensurePowFunction();
        }

        // Predicate, complex and folded-LaTeX constants must all be
        // materialized in data before heap_ptr is fixed — anything appended to
        // the data segment after that would overlap the runtime heap.
        for (functions.items) |f| {
            for (f.expr.constants) |val| {
                if (val.tag == .predicate) {
                    _ = try self.addPredicateData(val.data.predicate);
                } else if (val.tag == .complex) {
                    _ = try self.ensureComplexData(val.data.complex.re, val.data.complex.im);
                }
            }
            try self.prefoldLatexStrings(f.expr);
        }

        var needs_heap = self.current_data_offset > 1024;
        if (!needs_heap and self.standalone and self.requiresStandaloneHeap()) {
            needs_heap = true;
        }
        if (!needs_heap) {
            for (functions.items) |f| {
                for (f.expr.constants) |val| {
                    if (val.tag == .complex) {
                        needs_heap = true;
                        break;
                    }
                }
                if (needs_heap) break;
            }
        }
        if (!needs_heap) {
            for (functions.items) |f| {
                if (usesHeap(f.expr)) {
                    needs_heap = true;
                    break;
                }
            }
        }
        if (!needs_heap) {
            for (functions.items) |f| {
                // Prefer unit-declared tags when this expr is a multi-unit root.
                self.forced_param_tags = options.param_tags;
                for (units) |u| {
                    if (u.expr == f.expr) {
                        if (u.param_tags) |pt| self.forced_param_tags = pt;
                        break;
                    }
                }
                const param_tags = try self.inferUserParamTypes(f.expr, f.param_offset, f.params_count);
                defer self.allocator.free(param_tags);
                for (param_tags) |t| {
                    if (t == .matrix or t == .complex or t == .record or t == .string or t == .series) {
                        needs_heap = true;
                        break;
                    }
                }
                if (needs_heap) break;
            }
            self.forced_param_tags = options.param_tags;
        }
        if (!needs_heap) {
            for (functions.items) |f| {
                for (f.expr.constants) |val| {
                    if (val.tag == .string) {
                        needs_heap = true;
                        break;
                    }
                }
                if (needs_heap) break;
            }
        }
        // Also force heap when any unit declares non-scalar port tags (Spec 07).
        if (!needs_heap) {
            for (units) |u| {
                if (u.param_tags) |pt| {
                    for (pt) |t| {
                        if (t == .matrix or t == .complex or t == .record or t == .string or t == .series) {
                            needs_heap = true;
                            break;
                        }
                    }
                }
                if (needs_heap) break;
            }
        }
        if (options.force_heap) needs_heap = true;
        const wants_batch_export = options.export_batch and units.len == 1 and units[0].num_params == 1;
        const needs_linear_memory = needs_heap or wants_batch_export;

        if (needs_linear_memory) {
            try self.ensureLinearMemoryAndHeap();
        } else if (self.standalone and self.requiresStandaloneHeap()) {
            return error.StandaloneUnsupportedImport;
        }

        // Always present so host can distinguish miss/null NaN payloads from math NaN.
        try self.ensureResultKindGlobal();

        for (functions.items) |*f| {
            var p_types = std.ArrayListUnmanaged(types.ValType).empty;
            defer p_types.deinit(self.allocator);
            for (0..f.params_count) |_| try p_types.append(self.allocator, .f64);
            const r_types = [_]types.ValType{.f64};
            const type_idx = try self.module.addType(p_types.items, &r_types);
            f.wasm_idx = try self.module.addFunction(type_idx);
            if (f.export_fn) {
                try self.module.addExport(f.name, .function, f.wasm_idx);
            }
            try self.user_function_map.put(f.expr, f.wasm_idx);
            try self.user_fn_name_map.put(f.name, f.wasm_idx);
        }

        // Resolve unit root indices for the caller.
        for (units, 0..) |u, i| {
            unit_wasm_idxs[i] = self.user_function_map.get(u.expr) orelse return error.UserFunctionMissing;
        }

        if (self.standalone) {
            try self.declareStandaloneOdeBodies();
        }

        for (units) |u| {
            try self.collectOuterConstants(u.expr);
        }

        // Pre-infer each user function's result tag so call sites compiled
        // before their callee's body can type non-number results.
        for (functions.items) |f| {
            _ = try self.inferResultTag(f.expr);
        }

        const primary_expr = units[options.primary_unit orelse (units.len - 1)].expr;
        for (functions.items) |f| {
            if (self.verbose) {
                std.debug.print("Function '{s}' (params: {d}, idx: {d}):\n", .{ f.name, f.params_count, f.wasm_idx });
                for (f.expr.code, 0..) |inst, i| {
                    std.debug.print("  {d}: {s} {d}\n", .{ i, @tagName(inst.opcode), inst.operand });
                }
            }
            // Per-unit param tags (Spec 07 full-value) override multi-compile global.
            self.forced_param_tags = options.param_tags;
            for (units) |u| {
                if (u.expr == f.expr) {
                    if (u.param_tags) |pt| self.forced_param_tags = pt;
                    break;
                }
            }
            try self.generateFunctionCode(f.expr, @intCast(f.params_count), f.param_offset);
            if (f.expr == primary_expr) {
                self.result_tag = if (self.type_stack.items.len > 0)
                    self.type_stack.items[self.type_stack.items.len - 1]
                else
                    .number;
                self.result_unit = if (self.unit_stack.items.len > 0)
                    self.unit_stack.items[self.unit_stack.items.len - 1]
                else
                    null;
                self.series_repr = if (self.standalone) .linear_memory else .host_handle;
            }
        }
        self.forced_param_tags = options.param_tags;

        if (self.standalone) {
            try self.emitStandaloneOdeBodies();
        }

        if (wants_batch_export and self.result_tag == .number and !needs_heap) {
            try self.emitEvalBatch(unit_wasm_idxs[0]);
        }

        if (options.emit_abi) {
            // Only list exported roots (+ nested user funcs that were exported).
            var exported = std.ArrayListUnmanaged(FunctionToCompile).empty;
            defer exported.deinit(self.allocator);
            for (functions.items) |f| {
                if (f.export_fn) try exported.append(self.allocator, f);
            }
            try self.emitAbiManifest(exported.items, needs_linear_memory);
        }
    }

    /// Create/export the `result_kind` i32 global (ValueTag; 0 = number).
    fn ensureResultKindGlobal(self: *WasmCompiler) !void {
        if (self.result_kind_idx != null) return;
        const idx = try self.module.addGlobal(.i32, true, .i32_const, @as(i32, 0));
        self.result_kind_idx = idx;
        try self.module.addExport("result_kind", .global, idx);
    }

    /// Store a ValueTag discriminant into `result_kind` (miss/null vs number).
    fn emitSetResultKind(self: *WasmCompiler, writer: anytype, kind: mathzig.ValueTag) !void {
        try self.ensureResultKindGlobal();
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, @as(i32, @intFromEnum(kind)));
        try writer.writeByte(@intFromEnum(types.Op.global_set));
        _ = try leb.encodeUnsigned(writer, self.result_kind_idx.?);
    }

    fn ensureLinearMemoryAndHeap(self: *WasmCompiler) !void {
        if (self.module.memory_count > 0) return;

        _ = try self.module.addMemory(100, null);
        try self.module.addExport("memory", .memory, 0);

        const final_data_offset = (self.current_data_offset + 7) & ~@as(u32, 7);
        self.heap_ptr_idx = try self.module.addGlobal(.i32, true, .i32_const, @as(i32, @intCast(final_data_offset)));
        try self.module.addExport("heap_ptr", .global, self.heap_ptr_idx);
        // From here on the heap base is baked into the global/reset_heap;
        // further data-segment appends would overlap the heap and are refused.
        self.data_frozen = true;

        const reset_type_idx = try self.module.addType(&[_]types.ValType{}, &[_]types.ValType{});
        const reset_func_idx = try self.module.addFunction(reset_type_idx);
        try self.module.addExport("reset_heap", .function, reset_func_idx);

        var reset_code = std.ArrayListUnmanaged(u8).empty;
        defer reset_code.deinit(self.allocator);
        try reset_code.append(self.allocator, @intFromEnum(types.Op.i32_const));
        const reset_writer = list_writer.unmanagedByteWriter(&reset_code, self.allocator);
        _ = try leb.encodeSigned(reset_writer, @as(i32, @intCast(final_data_offset)));
        try reset_code.append(self.allocator, @intFromEnum(types.Op.global_set));
        _ = try leb.encodeUnsigned(reset_writer, self.heap_ptr_idx);
        try self.module.addCode(reset_code.items, &[_]types.ValType{});

        const alloc_type_idx = try self.module.addType(&[_]types.ValType{.i32}, &[_]types.ValType{.i32});
        const alloc_func_idx = try self.module.addFunction(alloc_type_idx);
        try self.module.addExport("alloc", .function, alloc_func_idx);
        self.alloc_func_idx = alloc_func_idx;

        var alloc_code = std.ArrayListUnmanaged(u8).empty;
        defer alloc_code.deinit(self.allocator);
        const aw = list_writer.unmanagedByteWriter(&alloc_code, self.allocator);
        // local 0 = size param; locals 1..3 = out_ptr / new_end / curr_bytes.
        // Same grow-or-trap path as internal allocations — a plain bump here
        // handed out pointers past the end of memory once the host requested
        // more than the initial pages.
        try self.emitHeapAllocChecked(aw, 0, 1, 2, 3);
        try alloc_code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(aw, 1);
        try self.module.addCode(alloc_code.items, &[_]types.ValType{ .i32, .i32, .i32 });

        if (self.standalone) {
            try self.registerStandaloneMatrixBodies();
            try self.registerStandaloneSeriesBodies();
        }
    }

    fn emitFusedTick(
        self: *WasmCompiler,
        plan: FuseCompilePlan,
        node_idxs: []const u32,
        tick_params: u32,
        /// Pre-sanitized out_* names (parallel to plan.outputs when named_exports).
        out_names: []const []const u8,
    ) !u32 {
        const n_nodes = plan.nodes.len;
        const n_outs = plan.outputs.len;
        const n_inputs = plan.inputs.len;

        // Locals after params: one f64 per node result; i32 table ptr only in table mode.
        // local layout: [0 .. tick_params) params | [tick_params .. +n_nodes) results | [table_ptr?]
        const result_base: u32 = tick_params;
        const table_ptr_local: u32 = result_base + @as(u32, @intCast(n_nodes));

        // tick returns i32 (table ptr) for table mode; for named_exports returns 0.
        var p_types = std.ArrayListUnmanaged(types.ValType).empty;
        defer p_types.deinit(self.allocator);
        for (0..tick_params) |_| try p_types.append(self.allocator, .f64);
        const type_idx = try self.module.addType(p_types.items, &[_]types.ValType{.i32});
        const tick_idx = try self.module.addFunction(type_idx);
        try self.module.addExport(plan.entry_name, .function, tick_idx);

        var code = std.ArrayListUnmanaged(u8).empty;
        defer code.deinit(self.allocator);
        const w = list_writer.unmanagedByteWriter(&code, self.allocator);

        // Evaluate nodes in topo order (plan.nodes is already topo-ordered).
        for (plan.nodes, 0..) |node, ni| {
            for (node.arg_sources) |src| {
                try emitArgPush(&code, self.allocator, w, src, @intCast(n_inputs), result_base);
            }
            try code.append(self.allocator, @intFromEnum(types.Op.call));
            _ = try leb.encodeUnsigned(w, node_idxs[ni]);
            try code.append(self.allocator, @intFromEnum(types.Op.local_set));
            _ = try leb.encodeUnsigned(w, result_base + @as(u32, @intCast(ni)));
        }

        if (plan.out_mode == .table) {
            if (self.alloc_func_idx == null) return error.FuseHeapRequired;
            const alloc_idx = self.alloc_func_idx.?;
            // table bytes = 4 + 12 * n_outs  (u32 count + [u32 kind][f64] * n)
            const table_bytes: i32 = @intCast(4 + 12 * n_outs);
            try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
            _ = try leb.encodeSigned(w, table_bytes);
            try code.append(self.allocator, @intFromEnum(types.Op.call));
            _ = try leb.encodeUnsigned(w, alloc_idx);
            try code.append(self.allocator, @intFromEnum(types.Op.local_tee));
            _ = try leb.encodeUnsigned(w, table_ptr_local);

            // store count at base (addr still on stack from tee)
            try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
            _ = try leb.encodeSigned(w, @as(i32, @intCast(n_outs)));
            try code.append(self.allocator, @intFromEnum(types.Op.i32_store));
            try code.append(self.allocator, 0x02); // align 4
            try code.append(self.allocator, 0x00); // offset 0

            for (plan.outputs, 0..) |out, oi| {
                const entry_off: i32 = @intCast(4 + oi * 12);
                try code.append(self.allocator, @intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(w, table_ptr_local);
                try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(w, @as(i32, @intFromEnum(out.kind)));
                try code.append(self.allocator, @intFromEnum(types.Op.i32_store));
                try code.append(self.allocator, 0x02);
                _ = try leb.encodeUnsigned(w, @as(u32, @intCast(entry_off)));

                try code.append(self.allocator, @intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(w, table_ptr_local);
                try code.append(self.allocator, @intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(w, result_base + out.from_node);
                try code.append(self.allocator, @intFromEnum(types.Op.f64_store));
                try code.append(self.allocator, 0x02); // align 4 (packed layout)
                _ = try leb.encodeUnsigned(w, @as(u32, @intCast(entry_off + 4)));
            }

            try code.append(self.allocator, @intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(w, table_ptr_local);
        } else {
            // named_exports: tick still evaluates nodes; return 0 (no table).
            try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
            _ = try leb.encodeSigned(w, @as(i32, 0));
        }

        // Locals: n_nodes f64 results; i32 table ptr only when table mode.
        var locals = std.ArrayListUnmanaged(types.ValType).empty;
        defer locals.deinit(self.allocator);
        for (0..n_nodes) |_| try locals.append(self.allocator, .f64);
        if (plan.out_mode == .table) try locals.append(self.allocator, .i32);
        try self.module.addCode(code.items, locals.items);

        // Named out_* exports: same params as tick, recompute nodes, return one f64.
        // Stage A interim for multi-call: each out_* re-runs the topo chain
        // (diamonds recompute). Prefer tick+table for single-pass multi-out.
        if (plan.out_mode == .named_exports) {
            std.debug.assert(out_names.len == plan.outputs.len);
            for (plan.outputs, 0..) |out, oi| {
                const out_name = out_names[oi];
                const out_type = try self.module.addType(p_types.items, &[_]types.ValType{.f64});
                const out_idx = try self.module.addFunction(out_type);
                try self.module.addExport(out_name, .function, out_idx);

                var oc = std.ArrayListUnmanaged(u8).empty;
                defer oc.deinit(self.allocator);
                const ow = list_writer.unmanagedByteWriter(&oc, self.allocator);

                for (plan.nodes, 0..) |node, ni| {
                    for (node.arg_sources) |src| {
                        try emitArgPush(&oc, self.allocator, ow, src, @intCast(n_inputs), result_base);
                    }
                    try oc.append(self.allocator, @intFromEnum(types.Op.call));
                    _ = try leb.encodeUnsigned(ow, node_idxs[ni]);
                    try oc.append(self.allocator, @intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(ow, result_base + @as(u32, @intCast(ni)));
                }
                try oc.append(self.allocator, @intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(ow, result_base + out.from_node);

                var olocals = std.ArrayListUnmanaged(types.ValType).empty;
                defer olocals.deinit(self.allocator);
                for (0..n_nodes) |_| try olocals.append(self.allocator, .f64);
                try self.module.addCode(oc.items, olocals.items);
            }
        }

        return tick_idx;
    }

    fn emitGraphManifestSection(
        self: *WasmCompiler,
        plan: FuseCompilePlan,
        tick_params: u32,
        out_names: []const []const u8,
        helper_units: ?[]const CompileUnit,
    ) !void {
        var outs = try self.allocator.alloc(graph_manifest.GraphOutputPort, plan.outputs.len);
        defer self.allocator.free(outs);
        for (plan.outputs, 0..) |o, i| {
            const export_name: ?[]const u8 = if (plan.out_mode == .named_exports and i < out_names.len)
                out_names[i]
            else
                null;
            outs[i] = .{
                .name = o.name,
                .kind = o.kind,
                .result_tag = graph_manifest.kindToResultTag(o.kind),
                .export_name = export_name,
            };
        }

        // Growable export inventory: entry + out_* + optional node helpers.
        var exports_list = std.ArrayListUnmanaged(graph_manifest.ExportEntry).empty;
        defer exports_list.deinit(self.allocator);
        try exports_list.append(self.allocator, .{ .name = plan.entry_name, .params = tick_params });
        if (plan.out_mode == .named_exports) {
            for (out_names) |on| {
                try exports_list.append(self.allocator, .{ .name = on, .params = tick_params });
            }
        }
        if (helper_units) |hu| {
            for (hu) |u| {
                try exports_list.append(self.allocator, .{
                    .name = u.name,
                    .params = @intCast(u.num_params),
                });
            }
        }

        const m = graph_manifest.GraphManifest{
            .entry = plan.entry_name,
            .inputs = plan.inputs,
            .params = plan.params,
            .outputs = outs,
            .out_mode = plan.out_mode,
            .exports = exports_list.items,
        };
        try graph_manifest.emitCustomSection(&self.module, self.allocator, m);
    }


    fn emitEvalBatch(self: *WasmCompiler, eval_func_idx: u32) !void {
        const type_idx = try self.module.addType(
            &[_]types.ValType{ .i32, .i32, .i32 },
            &[_]types.ValType{},
        );
        const func_idx = try self.module.addFunction(type_idx);
        try self.module.addExport("eval_batch", .function, func_idx);

        var code = std.ArrayListUnmanaged(u8).empty;
        defer code.deinit(self.allocator);
        const w = list_writer.unmanagedByteWriter(&code, self.allocator);

        // locals: 3 params (in_ptr, out_ptr, count), local 3 = i
        try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(w, @as(i32, 0));
        try code.append(self.allocator, @intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(w, 3);

        try code.append(self.allocator, @intFromEnum(types.Op.block));
        try code.append(self.allocator, @intFromEnum(types.ValType.void));
        try code.append(self.allocator, @intFromEnum(types.Op.loop));
        try code.append(self.allocator, @intFromEnum(types.ValType.void));

        // if (i >= count) break;
        try code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(w, 3);
        try code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(w, 2);
        try code.append(self.allocator, @intFromEnum(types.Op.i32_ge_u));
        try code.append(self.allocator, @intFromEnum(types.Op.br_if));
        _ = try leb.encodeUnsigned(w, 1);

        // out_ptr + i*8, left on stack for f64.store address.
        try code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(w, 1);
        try code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(w, 3);
        try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(w, @as(i32, 3));
        try code.append(self.allocator, @intFromEnum(types.Op.i32_shl));
        try code.append(self.allocator, @intFromEnum(types.Op.i32_add));

        // eval(f64.load(in_ptr + i*8)).
        try code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(w, 0);
        try code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(w, 3);
        try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(w, @as(i32, 3));
        try code.append(self.allocator, @intFromEnum(types.Op.i32_shl));
        try code.append(self.allocator, @intFromEnum(types.Op.i32_add));
        try code.append(self.allocator, @intFromEnum(types.Op.f64_load));
        try code.append(self.allocator, 0x03);
        try code.append(self.allocator, 0x00);
        try code.append(self.allocator, @intFromEnum(types.Op.call));
        _ = try leb.encodeUnsigned(w, eval_func_idx);
        try code.append(self.allocator, @intFromEnum(types.Op.f64_store));
        try code.append(self.allocator, 0x03);
        try code.append(self.allocator, 0x00);

        // i += 1
        try code.append(self.allocator, @intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(w, 3);
        try code.append(self.allocator, @intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(w, @as(i32, 1));
        try code.append(self.allocator, @intFromEnum(types.Op.i32_add));
        try code.append(self.allocator, @intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(w, 3);

        try code.append(self.allocator, @intFromEnum(types.Op.br));
        _ = try leb.encodeUnsigned(w, 0);
        try code.append(self.allocator, @intFromEnum(types.Op.end));
        try code.append(self.allocator, @intFromEnum(types.Op.end));

        try self.module.addCode(code.items, &[_]types.ValType{.i32});
    }

    /// Emit the `mathzig.abi` custom section: a JSON manifest describing the
    /// module's ABI version, required env imports, exported functions, the
    /// statically-inferred result tag, unit annotation, series representation,
    /// and heap usage. Hosts (generated env, parity backend, node-graph loaders)
    /// introspect this instead of guessing from source text. Spec: src/wasm/abi.zig.
    fn emitAbiManifest(self: *WasmCompiler, functions: []const FunctionToCompile, needs_heap: bool) !void {
        var manifest = std.ArrayListUnmanaged(u8).empty;
        defer manifest.deinit(self.allocator);
        const w = list_writer.unmanagedByteWriter(&manifest, self.allocator);

        self.finalizeUnitRuntime();
        try w.print("{{\"abi\":{d},\"result_tag\":\"{s}\",\"heap\":{},\"heap_base\":{d},\"series_repr\":\"{s}\",\"unit_runtime\":\"{s}\"", .{
            abi.ABI_VERSION,
            @tagName(self.result_tag),
            needs_heap,
            (self.current_data_offset + 7) & ~@as(u32, 7),
            self.series_repr.jsonName(),
            self.unit_runtime.jsonName(),
        });

        // Unit annotation for host re-attachment of SI magnitudes.
        if (self.result_unit) |u| {
            try w.print(
                \\,"result_unit":{{"dims":{{"m":{d},"l":{d},"t":{d},"i":{d},"k":{d},"n":{d},"j":{d}}},"scale":{d},"offset":{d}
            ,
                .{ u.dims.m, u.dims.l, u.dims.t, u.dims.i, u.dims.k, u.dims.n, u.dims.j, u.scale, u.offset },
            );
            if (u.name) |name| {
                try w.writeAll(",\"name\":\"");
                for (name) |ch| {
                    switch (ch) {
                        '"' => try w.writeAll("\\\""),
                        '\\' => try w.writeAll("\\\\"),
                        else => try w.writeAll(&.{ch}),
                    }
                }
                try w.writeAll("\"");
            }
            try w.writeAll("}");
        }

        try w.writeAll(",\"exports\":[");
        for (functions, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\",\"params\":{d}}}", .{ f.name, f.params_count });
        }
        try w.writeAll("],\"imports\":[");
        for (self.import_manifest.items, 0..) |entry, i| {
            if (i > 0) try w.writeAll(",");
            const s = abi.signature(entry.builtin);
            try w.print("{{\"name\":\"{s}{s}\",\"builtin\":\"{s}\",\"args\":{d},\"where\":{},\"ret\":\"{s}\"}}", .{
                @tagName(entry.builtin),
                if (entry.is_where) "_where" else "",
                @tagName(entry.builtin),
                entry.arg_count,
                entry.is_where,
                @tagName(s.ret),
            });
        }
        // Data-segment string constants (name -> wasm offset). rec_get matches
        // record keys by offset, so hosts writing records into module memory
        // need this table to produce entries the module can look up.
        try w.writeAll("],\"strings\":{");
        var str_it = self.string_dedup.iterator();
        var first_str = true;
        while (str_it.next()) |entry| {
            if (!first_str) try w.writeAll(",");
            first_str = false;
            try w.writeAll("\"");
            for (entry.key_ptr.*) |ch| {
                switch (ch) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => if (ch < 0x20)
                        try w.print("\\u{x:0>4}", .{ch})
                    else
                        try w.writeAll(&.{ch}),
                }
            }
            try w.print("\":{d}", .{entry.value_ptr.*});
        }
        try w.writeAll("}}");

        try self.module.addCustomSection(abi.CUSTOM_SECTION_NAME, manifest.items);
    }

    fn discoverFunctions(
        self: *WasmCompiler,
        expr: *const CompiledExpr,
        name: []const u8,
        param_count: usize,
        param_offset: u32,
        inherited_funcs: []const *const CompiledExpr,
        list: *std.ArrayListUnmanaged(FunctionToCompile),
    ) anyerror!void {
        var expr_string_map = std.AutoHashMap(usize, u32).init(self.allocator);
        var local_list = std.ArrayListUnmanaged(*const CompiledExpr).empty;
        defer local_list.deinit(self.allocator);
        var child_funcs = std.ArrayListUnmanaged(struct {
            expr: *const CompiledExpr,
            name: []const u8,
            params_count: usize,
            param_offset: u32,
        }).empty;
        defer child_funcs.deinit(self.allocator);

        for (expr.constants, 0..) |val, i| {
            if (val.tag == .string) {
                const str = val.data.string.toSlice();
                if (self.string_dedup.get(str)) |offset| {
                    try expr_string_map.put(i, offset);
                } else {
                    const offset = self.current_data_offset;
                    _ = try self.module.addData(@intCast(offset), str);
                    try self.string_dedup.put(str, offset);
                    try expr_string_map.put(i, offset);
                    self.current_data_offset += @intCast(str.len + 1);
                }
            }
        }
        try self.string_map.put(expr, expr_string_map);

        // Pre-scan for matrix multiply: need GEMM if a mul combines two matrix
        // sources. Producers are mat_create(_3) literals, matrix-returning
        // builtins, AND root parameters inferred as matrix (so `x * [2,0;1,2]`
        // with matrix param x registers gemm).
        var matrix_producer_count: usize = 0;
        const param_tags_for_gemm = try self.inferUserParamTypes(expr, param_offset, param_count);
        defer self.allocator.free(param_tags_for_gemm);
        var matrix_param_count: usize = 0;
        for (param_tags_for_gemm) |t| {
            if (t == .matrix) matrix_param_count += 1;
        }
        for (expr.code) |inst| {
            switch (inst.opcode) {
                .mat_create, .mat_create_3 => matrix_producer_count += 1,
                .call_builtin => {
                    const b: BuiltinFn = @enumFromInt(@as(u16, @truncate(inst.operand)));
                    if (abi.signature(b).ret == .matrix_ptr) matrix_producer_count += 1;
                },
                .mul => {
                    const matrix_sources = matrix_producer_count + matrix_param_count;
                    if (matrix_sources >= 2) self.pending_needs_gemm = true;
                },
                else => {},
            }
        }

        // Only COLLECT builtin usage here. Actual registration is deferred to
        // compile()'s two-phase pass: imports must all exist before the first
        // defined function (index-space invariant, see pending_builtins).
        // Stack-simulate (coarse) to capture static ODE deriv name strings.
        var hint_stack = std.ArrayListUnmanaged(?[]const u8).empty;
        defer hint_stack.deinit(self.allocator);
        const popN = struct {
            fn go(stack: *std.ArrayListUnmanaged(?[]const u8), n: usize) void {
                if (n == 0) return;
                const len = stack.items.len;
                if (len >= n) stack.shrinkRetainingCapacity(len - n) else stack.clearRetainingCapacity();
            }
        }.go;
        const pushNull = struct {
            fn go(stack: *std.ArrayListUnmanaged(?[]const u8), allocator: std.mem.Allocator) !void {
                try stack.append(allocator, null);
            }
        }.go;
        for (expr.code, 0..) |inst, i| {
            switch (inst.opcode) {
                .push_const => {
                    const val = expr.constants[inst.operand];
                    if (val.tag == .string) {
                        try hint_stack.append(self.allocator, val.data.string.toSlice());
                    } else {
                        try pushNull(&hint_stack, self.allocator);
                    }
                },
                .load_var, .dup => try pushNull(&hint_stack, self.allocator),
                .pop => popN(&hint_stack, 1),
                .mat_create => {
                    const rows: usize = @as(u12, @truncate(inst.operand));
                    const cols: usize = @as(u12, @truncate(inst.operand >> 12));
                    popN(&hint_stack, rows * cols);
                    try pushNull(&hint_stack, self.allocator);
                },
                .mat_create_3 => {
                    popN(&hint_stack, 3);
                    try pushNull(&hint_stack, self.allocator);
                },
                .call_builtin => {
                    const arg_count: u8 = @truncate((inst.operand >> 16) & 0xFF);
                    const builtin: BuiltinFn = @enumFromInt(@as(u16, @truncate(inst.operand)));
                    try self.pending_builtins.append(self.allocator, .{
                        .builtin = builtin,
                        .arg_count = arg_count,
                        .is_where = false,
                    });
                    // ODE: first of 4 args is the deriv name — deepest of the 4 stack slots.
                    if ((builtin == .ode_solve or builtin == .ode_solve_euler) and arg_count >= 4 and hint_stack.items.len >= arg_count) {
                        const name_hint = hint_stack.items[hint_stack.items.len - arg_count];
                        if (name_hint) |deriv_name| {
                            try self.pending_ode_targets.append(self.allocator, .{ .builtin = builtin, .name = deriv_name });
                        }
                    }
                    popN(&hint_stack, arg_count);
                    try pushNull(&hint_stack, self.allocator);
                },
                .call_builtin_where => {
                    const arg_count: u8 = @truncate((inst.operand >> 16) & 0xFF);
                    try self.pending_builtins.append(self.allocator, .{
                        .builtin = @enumFromInt(@as(u16, @truncate(inst.operand))),
                        .arg_count = arg_count,
                        .is_where = true,
                    });
                    popN(&hint_stack, arg_count + 1); // args + predicate
                    try pushNull(&hint_stack, self.allocator);
                },
                .call_user => {
                    const arg_count: u8 = @truncate((inst.operand >> 16) & 0xFF);
                    popN(&hint_stack, arg_count);
                    try pushNull(&hint_stack, self.allocator);
                },
                .add, .sub, .mul, .div, .mod, .pow, .epow, .eq, .ne, .lt, .le, .gt, .ge => {
                    if (inst.opcode == .pow or inst.opcode == .epow) {
                        if (!(inst.opcode == .pow and isFastPowAt(expr, i))) {
                            self.pending_needs_pow = true;
                        }
                    } else if (inst.opcode == .mod) {
                        self.pending_needs_fmod = true;
                    }
                    popN(&hint_stack, 2);
                    try pushNull(&hint_stack, self.allocator);
                },
                .neg, .pos => {
                    popN(&hint_stack, 1);
                    try pushNull(&hint_stack, self.allocator);
                },
                .def_user => {
                    const uf = expr.constants[inst.operand].data.function.user_func.?;
                    try local_list.append(self.allocator, &uf.body);
                    try child_funcs.append(self.allocator, .{
                        .expr = &uf.body,
                        .name = uf.name,
                        .params_count = uf.params.len,
                        .param_offset = uf.param_offset,
                    });
                },
                else => {
                    // Best-effort: leave stack alone for control-flow / stores.
                },
            }
        }

        var scope_list = std.ArrayListUnmanaged(*const CompiledExpr).empty;
        if (inherited_funcs.len > 0) {
            try scope_list.appendSlice(self.allocator, inherited_funcs);
        }
        if (local_list.items.len > 0) {
            try scope_list.appendSlice(self.allocator, local_list.items);
        }
        try self.local_funcs.put(expr, scope_list);
        try self.scope_base.put(expr, @intCast(inherited_funcs.len));

        const func = FunctionToCompile{
            .expr = expr,
            .name = name,
            .params_count = param_count,
            .param_offset = param_offset,
        };
        try self.user_function_params.put(expr, @intCast(param_count));
        try list.append(self.allocator, func);

        if (child_funcs.items.len > 0) {
            for (child_funcs.items) |child| {
                try self.discoverFunctions(
                    child.expr,
                    child.name,
                    child.params_count,
                    child.param_offset,
                    scope_list.items,
                    list,
                );
            }
        }
    }

    fn analyzeControlFlow(self: *WasmCompiler, expr: *const CompiledExpr) !void {
        self.loop_headers.clearRetainingCapacity();
        for (expr.code, 0..) |inst, i| {
            // Check for backward jumps
            if (inst.opcode == .jmp) {
                const target = inst.operand;
                if (target < i) {
                    // It's a backward jump (loop back-edge)
                    // The loop starts at 'target' and ends at 'i + 1'
                    const existing_end = self.loop_headers.get(target) orelse 0;
                    if (i + 1 > existing_end) {
                        try self.loop_headers.put(target, i + 1);
                    }
                }
            }
        }
    }

    const ParamStackEntry = union(enum) {
        tag: mathzig.ValueTag,
        param: usize,
    };

    /// Record compile-time outer bindings from the root expression so user
    /// functions can load captured scalars (e.g. ODE coeffs) as constants.
    fn collectOuterConstants(self: *WasmCompiler, root: *const CompiledExpr) !void {
        var stack = std.ArrayListUnmanaged(f64).empty;
        defer stack.deinit(self.allocator);

        for (root.code) |inst| {
            switch (inst.opcode) {
                .push_const => {
                    const val = root.constants[inst.operand];
                    if (val.tag == .number) {
                        try stack.append(self.allocator, val.data.number);
                    } else if (val.tag == .unit) {
                        // AOT treats units as their SI magnitude.
                        try stack.append(self.allocator, val.data.unit.value);
                    } else if (val.tag == .boolean) {
                        try stack.append(self.allocator, if (val.data.boolean) 1 else 0);
                    }
                },
                .load_var => {
                    // Replay prior stores / seeded globals (nan, pi, …).
                    if (self.globals.get(@intCast(inst.operand))) |v| {
                        try stack.append(self.allocator, v);
                    }
                },
                .store_var => {
                    if (stack.items.len > 0) {
                        const v = stack.items[stack.items.len - 1];
                        stack.items.len -= 1;
                        try self.globals.put(@intCast(inst.operand), v);
                    }
                },
                .add => outerBinop(&stack, .add),
                .sub => outerBinop(&stack, .sub),
                .mul => outerBinop(&stack, .mul),
                .div => outerBinop(&stack, .div),
                .neg => {
                    if (stack.items.len > 0) stack.items[stack.items.len - 1] *= -1;
                },
                .const_mul => {
                    if (stack.items.len > 0) {
                        const c = root.constants[inst.operand];
                        if (c.tag == .number) stack.items[stack.items.len - 1] *= c.data.number;
                    }
                },
                // Host-side builtins that are SI-identity for already-normalized
                // magnitudes (conv) or pure math (exp) — keep the top of stack.
                .call_builtin => {
                    const builtin: BuiltinFn = @enumFromInt(@as(u16, @truncate(inst.operand)));
                    const arg_count: u8 = @truncate((inst.operand >> 16) & 0xFF);
                    // Pop args; for identity/scalar builtins re-push a best-effort result.
                    var args: [8]f64 = undefined;
                    var n: usize = 0;
                    while (n < arg_count and stack.items.len > 0) : (n += 1) {
                        args[arg_count - 1 - n] = stack.items[stack.items.len - 1];
                        stack.items.len -= 1;
                    }
                    if (n != arg_count) continue;
                    switch (builtin) {
                        .conv => try stack.append(self.allocator, args[0]), // SI identity
                        .exp => try stack.append(self.allocator, @exp(args[0])),
                        .log => try stack.append(self.allocator, @log(args[0])),
                        .sin => try stack.append(self.allocator, @sin(args[0])),
                        .cos => try stack.append(self.allocator, @cos(args[0])),
                        .sqrt => try stack.append(self.allocator, @sqrt(args[0])),
                        .abs => try stack.append(self.allocator, @abs(args[0])),
                        else => {}, // leave nothing on stack
                    }
                },
                .pop => {
                    if (stack.items.len > 0) stack.items.len -= 1;
                },
                .dup => {
                    if (stack.items.len > 0) try stack.append(self.allocator, stack.items[stack.items.len - 1]);
                },
                else => {},
            }
        }
    }

    fn outerBinop(stack: *std.ArrayListUnmanaged(f64), op: enum { add, sub, mul, div }) void {
        if (stack.items.len < 2) return;
        const b = stack.items[stack.items.len - 1];
        const a = stack.items[stack.items.len - 2];
        stack.items.len -= 2;
        const r: f64 = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (b != 0) a / b else std.math.nan(f64),
        };
        stack.appendAssumeCapacity(r);
    }

    fn inferUserParamTypes(
        self: *WasmCompiler,
        expr: *const CompiledExpr,
        param_offset: u32,
        num_params: usize,
    ) ![]mathzig.ValueTag {
        const tags = try self.allocator.alloc(mathzig.ValueTag, num_params);
        @memset(tags, .number);

        // Seed from caller-declared port kinds (node CLI / graph manifests).
        // Only applied for the root function (param_offset == 0) where the
        // forced tags align with eval params.
        if (param_offset == 0) {
            if (self.forced_param_tags) |forced| {
                const n = @min(forced.len, num_params);
                @memcpy(tags[0..n], forced[0..n]);
            }
        }

        // Seed matrix tags only from unambiguous indexing patterns. A crude
        // "last loaded param + mul" heuristic falsely marks scalar params
        // (e.g. `atan(y) * 2`) and forces unnecessary heap allocation.
        // Spec 07: never demote a forced non-number tag (complex/record/series)
        // to matrix — declared arg_kinds must survive into codegen.
        for (expr.code) |inst| {
            if (inst.opcode == .load_var_index_0 or
                inst.opcode == .load_var_index_1 or
                inst.opcode == .load_var_index_2 or
                inst.opcode == .load_var_index_3 or
                inst.opcode == .load_var_index_const)
            {
                const var_idx: u8 = @intCast(inst.operand & 0x0FFF);
                if (var_idx >= param_offset and var_idx < param_offset + num_params) {
                    const pi = var_idx - param_offset;
                    if (tags[pi] == .number or tags[pi] == .boolean) {
                        tags[pi] = .matrix;
                    }
                }
            }
        }

        const markMatrix = struct {
            fn bump(tags_ptr: []mathzig.ValueTag, entry: ParamStackEntry) void {
                switch (entry) {
                    .param => |pi| {
                        // Only promote number/boolean → matrix; keep forced complex/record/series.
                        if (pi < tags_ptr.len and (tags_ptr[pi] == .number or tags_ptr[pi] == .boolean)) {
                            tags_ptr[pi] = .matrix;
                        }
                    },
                    else => {},
                }
            }
            fn bumpBinop(tags_ptr: []mathzig.ValueTag, a: ParamStackEntry, b: ParamStackEntry, a_tag: mathzig.ValueTag, b_tag: mathzig.ValueTag) void {
                if (a_tag == .matrix and b_tag != .matrix) bump(tags_ptr, b);
                if (b_tag == .matrix and a_tag != .matrix) bump(tags_ptr, a);
            }
        };

        const scratch = try self.allocator.alloc(mathzig.ValueTag, num_params);
        defer self.allocator.free(scratch);

        while (true) {
            @memcpy(scratch, tags);
            var stack = std.ArrayListUnmanaged(ParamStackEntry).empty;
            defer stack.deinit(self.allocator);
            for (expr.code) |inst| {
                switch (inst.opcode) {
                    .push_const => try stack.append(self.allocator, .{ .tag = expr.constants[inst.operand].tag }),
                    .load_var => {
                        const v_idx: u8 = @intCast(inst.operand);
                        if (v_idx >= param_offset and v_idx < param_offset + num_params) {
                            try stack.append(self.allocator, .{ .param = v_idx - param_offset });
                        } else {
                            try stack.append(self.allocator, .{ .tag = .number });
                        }
                    },
                    .mat_create => {
                        // operand = rows (low 12) | cols (next 12); pops rows*cols values.
                        const rows: usize = inst.operand & 0xFFF;
                        const cols: usize = (inst.operand >> 12) & 0xFFF;
                        const n = rows * cols;
                        if (stack.items.len >= n) stack.items.len -= n;
                        try stack.append(self.allocator, .{ .tag = .matrix });
                    },
                    .mat_create_3 => {
                        if (stack.items.len >= 3) stack.items.len -= 3;
                        try stack.append(self.allocator, .{ .tag = .matrix });
                    },
                    .load_mul, .load_sub => {
                        // Fused load two vars then binop. Mark either param as
                        // matrix if the other is already known matrix (iterative).
                        const va: u8 = @truncate(inst.operand & 0x0FFF);
                        const vb: u8 = @truncate((inst.operand >> 12) & 0x0FFF);
                        const a_entry: ParamStackEntry = if (va >= param_offset and va < param_offset + num_params)
                            .{ .param = va - param_offset }
                        else
                            .{ .tag = .number };
                        const b_entry: ParamStackEntry = if (vb >= param_offset and vb < param_offset + num_params)
                            .{ .param = vb - param_offset }
                        else
                            .{ .tag = .number };
                        const a_tag: mathzig.ValueTag = switch (a_entry) {
                            .tag => |t| t,
                            .param => |pi| tags[pi],
                        };
                        const b_tag: mathzig.ValueTag = switch (b_entry) {
                            .tag => |t| t,
                            .param => |pi| tags[pi],
                        };
                        markMatrix.bumpBinop(tags, a_entry, b_entry, a_tag, b_tag);
                        try stack.append(self.allocator, .{ .tag = if (a_tag == .matrix or b_tag == .matrix) .matrix else .number });
                    },
                    .mat_index => {
                        if (stack.items.len == 0) continue;
                        const base = stack.items[stack.items.len - 1];
                        stack.items.len -= 1;
                        markMatrix.bump(tags, base);
                        try stack.append(self.allocator, .{ .tag = .number });
                    },
                    .load_var_index_0, .load_var_index_1, .load_var_index_2, .load_var_index_3, .load_var_index_const => {
                        const var_idx: u8 = @intCast(inst.operand & 0x0FFF);
                        if (var_idx >= param_offset and var_idx < param_offset + num_params) {
                            markMatrix.bump(tags, .{ .param = var_idx - param_offset });
                        }
                        try stack.append(self.allocator, .{ .tag = .number });
                    },
                    .get_index => {
                        const key_count: usize = inst.operand;
                        if (stack.items.len < key_count + 1) continue;
                        const object = stack.items[stack.items.len - 1 - key_count];
                        stack.items.len -= key_count + 1;
                        markMatrix.bump(tags, object);
                        try stack.append(self.allocator, .{ .tag = .number });
                    },
                    .const_mul => {
                        if (stack.items.len == 0) continue;
                        const top = stack.items[stack.items.len - 1];
                        stack.items.len -= 1;
                        const top_tag: mathzig.ValueTag = switch (top) {
                            .tag => |t| t,
                            .param => |pi| tags[pi],
                        };
                        if (top_tag == .matrix) markMatrix.bump(tags, top);
                        try stack.append(self.allocator, .{ .tag = if (top_tag == .matrix) .matrix else .number });
                    },
                    .mul, .add, .sub, .div, .emul, .ediv, .epow => {
                        if (stack.items.len < 2) continue;
                        const b = stack.items[stack.items.len - 1];
                        const a = stack.items[stack.items.len - 2];
                        stack.items.len -= 2;
                        const a_tag: mathzig.ValueTag = switch (a) {
                            .tag => |t| t,
                            .param => |pi| tags[pi],
                        };
                        const b_tag: mathzig.ValueTag = switch (b) {
                            .tag => |t| t,
                            .param => |pi| tags[pi],
                        };
                        markMatrix.bumpBinop(tags, a, b, a_tag, b_tag);
                        try stack.append(self.allocator, .{ .tag = if (a_tag == .matrix or b_tag == .matrix) .matrix else .number });
                    },
                    .store_var, .pop => {
                        if (stack.items.len > 0) stack.items.len -= 1;
                    },
                    else => {},
                }
            }
            if (std.mem.eql(mathzig.ValueTag, scratch, tags)) break;
        }
        return tags;
    }

    /// Coarse static result-tag inference for a user function body, memoized
    /// in fn_result_tags. Conservative by design: any shape the linear walk
    /// cannot follow (control flow, unknown producers) resolves to .number —
    /// the historical call_user typing — because a wrong pointer tag is worse
    /// than a scalar one.
    fn inferResultTag(self: *WasmCompiler, expr: *const CompiledExpr) !mathzig.ValueTag {
        if (self.fn_result_tags.get(expr)) |t| return t;
        // Seed so recursive calls (direct or mutual) resolve instead of looping.
        try self.fn_result_tags.put(expr, .number);

        for (expr.code) |inst| {
            switch (inst.opcode) {
                .jmp, .jmp_if_false, .jmp_if_true => return .number,
                else => {},
            }
        }

        var stack = std.ArrayListUnmanaged(mathzig.ValueTag).empty;
        defer stack.deinit(self.allocator);

        const S = struct {
            fn popn(st: *std.ArrayListUnmanaged(mathzig.ValueTag), n: usize) void {
                st.shrinkRetainingCapacity(st.items.len -| n);
            }
            fn top(st: *const std.ArrayListUnmanaged(mathzig.ValueTag)) mathzig.ValueTag {
                return if (st.items.len > 0) st.items[st.items.len - 1] else .number;
            }
        };

        walk: for (expr.code) |inst| {
            switch (inst.opcode) {
                .push_const => try stack.append(self.allocator, expr.constants[inst.operand].tag),
                .load_var,
                .load_var_index_0,
                .load_var_index_1,
                .load_var_index_2,
                .load_var_index_3,
                .load_var_index_const,
                .load_mul,
                .load_sub,
                .eval_poly,
                => try stack.append(self.allocator, .number),
                .dup => try stack.append(self.allocator, S.top(&stack)),
                .pop, .store_var => S.popn(&stack, 1),
                .add, .sub, .mul, .div, .emul, .ediv, .epow => {
                    const b = S.top(&stack);
                    S.popn(&stack, 1);
                    const a = S.top(&stack);
                    S.popn(&stack, 1);
                    const t: mathzig.ValueTag = if (a == .matrix or b == .matrix)
                        .matrix
                    else if (a == .complex or b == .complex)
                        .complex
                    else
                        .number;
                    try stack.append(self.allocator, t);
                },
                .mod, .pow, .band, .bor, .bxor, .shl, .shr => {
                    S.popn(&stack, 2);
                    try stack.append(self.allocator, .number);
                },
                .neg, .pos, .bnot, .const_mul => {
                    const t = S.top(&stack);
                    S.popn(&stack, 1);
                    try stack.append(self.allocator, t);
                },
                .fma => {
                    S.popn(&stack, 3);
                    try stack.append(self.allocator, .number);
                },
                .fma_var_const_const => try stack.append(self.allocator, .number),
                .eq, .ne, .lt, .le, .gt, .ge, .and_, .or_ => {
                    S.popn(&stack, 2);
                    try stack.append(self.allocator, .boolean);
                },
                .not_ => {
                    S.popn(&stack, 1);
                    try stack.append(self.allocator, .boolean);
                },
                .mat_create => {
                    const rows: usize = @as(u12, @truncate(inst.operand));
                    const cols: usize = @as(u12, @truncate(inst.operand >> 12));
                    S.popn(&stack, rows * cols);
                    try stack.append(self.allocator, .matrix);
                },
                .mat_create_3 => {
                    S.popn(&stack, 3);
                    try stack.append(self.allocator, .matrix);
                },
                .rec_create => {
                    S.popn(&stack, @as(usize, inst.operand) * 2);
                    try stack.append(self.allocator, .record);
                },
                .rec_get => {
                    S.popn(&stack, 1);
                    try stack.append(self.allocator, .number);
                },
                .rec_get_dyn => {
                    S.popn(&stack, 2);
                    try stack.append(self.allocator, .number);
                },
                .make_slice => {
                    S.popn(&stack, 3);
                    try stack.append(self.allocator, .slice);
                },
                .get_index => {
                    // A slice key yields a sub-matrix; plain keys a scalar.
                    var sliced = false;
                    var ki: usize = 0;
                    while (ki < inst.operand) : (ki += 1) {
                        if (S.top(&stack) == .slice) sliced = true;
                        S.popn(&stack, 1);
                    }
                    S.popn(&stack, 1); // object
                    try stack.append(self.allocator, if (sliced) .matrix else .number);
                },
                .unit_create, .unit_convert => {
                    S.popn(&stack, 2);
                    try stack.append(self.allocator, .number);
                },
                .call_builtin => {
                    const builtin: BuiltinFn = @enumFromInt(@as(u16, @truncate(inst.operand)));
                    const argc: usize = @as(u8, @truncate((inst.operand >> 16) & 0xFF));
                    S.popn(&stack, argc);
                    try stack.append(self.allocator, wireKindToValueTag(abi.signature(builtin).ret));
                },
                .call_builtin_where => {
                    const builtin: BuiltinFn = @enumFromInt(@as(u16, @truncate(inst.operand)));
                    const argc: usize = @as(u8, @truncate((inst.operand >> 16) & 0xFF));
                    S.popn(&stack, argc + 1);
                    try stack.append(self.allocator, wireKindToValueTag(abi.signature(builtin).ret));
                },
                .call_user => {
                    const func_id: u16 = @truncate(inst.operand & 0x7FFF);
                    const is_local = (inst.operand & 0x8000) != 0;
                    const argc: usize = @as(u8, @truncate((inst.operand >> 16) & 0xFF));
                    S.popn(&stack, argc);
                    var t: mathzig.ValueTag = .number;
                    if (self.local_funcs.get(expr)) |scope_list| {
                        const base: u32 = @intCast(self.scope_base.get(expr) orelse 0);
                        const target: u32 = if (is_local) base + func_id else func_id;
                        if (target < scope_list.items.len) {
                            t = try self.inferResultTag(scope_list.items[target]);
                        }
                    }
                    try stack.append(self.allocator, t);
                },
                .def_user => try stack.append(self.allocator, .boolean),
                .halt => break :walk,
                .nop => {},
                else => return .number,
            }
        }

        const result = S.top(&stack);
        try self.fn_result_tags.put(expr, result);
        return result;
    }

    fn generateFunctionCode(self: *WasmCompiler, expr: *const mathzig.CompiledExpr, num_params: u32, param_offset: u32) !void {
        self.var_types.clearRetainingCapacity();
        self.type_stack.clearRetainingCapacity();
        self.unit_stack.clearRetainingCapacity();

        var has_jumps = false;
        for (expr.code) |inst| {
            if (inst.opcode == .jmp or inst.opcode == .jmp_if_false or inst.opcode == .jmp_if_true) {
                has_jumps = true;
                break;
            }
        }

        var transformed_code = std.ArrayListUnmanaged(Instruction).empty;
        var transformed_offsets = std.ArrayListUnmanaged(u32).empty;
        defer transformed_code.deinit(self.allocator);
        defer transformed_offsets.deinit(self.allocator);

        var expr_ptr = expr;
        var expr_local = expr.*;
        if (!has_jumps) {
            var used_transform = false;
            var i: usize = 0;
            while (i < expr.code.len) : (i += 1) {
                const inst = expr.code[i];
                if (inst.opcode == .fma_var_const_const) {
                    used_transform = true;
                    const var_idx: u8 = @truncate(inst.operand);
                    const c1_idx: u8 = @truncate(inst.operand >> 8);
                    const c2_idx: u8 = @truncate(inst.operand >> 16);
                    try transformed_code.append(self.allocator, Instruction.initWithOperand(.load_var, var_idx));
                    try transformed_offsets.append(self.allocator, 0);
                    try transformed_code.append(self.allocator, Instruction.initWithOperand(.push_const, c1_idx));
                    try transformed_offsets.append(self.allocator, 0);
                    try transformed_code.append(self.allocator, Instruction.init(.mul));
                    try transformed_offsets.append(self.allocator, 0);
                    try transformed_code.append(self.allocator, Instruction.initWithOperand(.push_const, c2_idx));
                    try transformed_offsets.append(self.allocator, 0);
                    try transformed_code.append(self.allocator, Instruction.init(.add));
                    try transformed_offsets.append(self.allocator, 0);
                    continue;
                }
                if (inst.opcode == .fma and transformed_code.items.len > 0) {
                    const prev = transformed_code.items[transformed_code.items.len - 1];
                    if (prev.opcode == .push_const or prev.opcode == .load_var) {
                        used_transform = true;
                        _ = transformed_code.pop();
                        _ = transformed_offsets.pop();
                        try transformed_code.append(self.allocator, Instruction.init(.mul));
                        try transformed_offsets.append(self.allocator, 0);
                        try transformed_code.append(self.allocator, prev);
                        try transformed_offsets.append(self.allocator, 0);
                        try transformed_code.append(self.allocator, Instruction.init(.add));
                        try transformed_offsets.append(self.allocator, 0);
                        continue;
                    }
                }
                try transformed_code.append(self.allocator, inst);
                try transformed_offsets.append(self.allocator, 0);
            }
            if (used_transform) {
                expr_local.code = transformed_code.items;
                expr_local.source_offsets = transformed_offsets.items;
                expr_ptr = &expr_local;
            }
        }

        try self.analyzeControlFlow(expr_ptr);

        // Map MathZig variables to WASM locals
        var var_map = std.AutoHashMap(u8, u32).init(self.allocator);
        defer var_map.deinit();

        const param_tags = try self.inferUserParamTypes(expr_ptr, param_offset, num_params);
        defer self.allocator.free(param_tags);
        for (0..num_params) |i| {
            try var_map.put(@intCast(param_offset + i), @intCast(i));
            try self.var_types.put(self.allocator, @intCast(param_offset + i), param_tags[i]);
        }
        if (self.verbose) std.debug.print("Gen Func: params={d}, offset={d}\n", .{ num_params, param_offset });
        for (0..num_params) |i| {
            if (self.verbose) std.debug.print("  Map v{d} -> local {d}\n", .{ param_offset + i, i });
        }

        var used_vars = std.AutoHashMap(u8, void).init(self.allocator);
        defer used_vars.deinit();
        for (expr_ptr.code) |inst| {
            if (inst.opcode == .load_var or inst.opcode == .store_var) {
                const v_idx: u8 = @intCast(inst.operand);
                // Param indices are [param_offset, param_offset + num_params)
                const is_param = v_idx >= param_offset and v_idx < param_offset + num_params;
                // Outer captures (indices below param_offset) load as f64.const
                // from the root's collectOuterConstants / seeded globals — they
                // must not become mutable locals in user functions. Root-level
                // stores still need locals even if a constant fold also recorded
                // them in globals (so store_var has a slot to write).
                const is_outer_capture = param_offset > 0 and v_idx < param_offset;
                if (!is_param and !is_outer_capture) {
                    // Seeded read-only globals (nan/pi/e) never store_var; skip
                    // allocating a local so load_var uses f64.const.
                    if (inst.opcode == .load_var and self.globals.contains(v_idx) and param_offset == 0) {
                        // still allow locals if this index is also stored in the same body
                        // (handled below by scanning store_var first would be ideal;
                        // keep a local only when not purely a constant seed — see pass2)
                    } else {
                        try used_vars.put(v_idx, {});
                    }
                }
            } else if (inst.opcode == .fma_var_const_const) {
                const v_idx: u8 = @truncate(inst.operand);
                const is_param = v_idx >= param_offset and v_idx < param_offset + num_params;
                const is_outer_capture = param_offset > 0 and v_idx < param_offset;
                if (!is_param and !is_outer_capture) try used_vars.put(v_idx, {});
            }
        }
        // Second pass: pure load of a seeded global (nan/pi/e) without store
        // in this body → drop from used_vars so load_var emits f64.const.
        if (param_offset == 0) {
            var stored = std.AutoHashMap(u8, void).init(self.allocator);
            defer stored.deinit();
            for (expr_ptr.code) |inst| {
                if (inst.opcode == .store_var) try stored.put(@intCast(inst.operand), {});
            }
            var drop = std.ArrayListUnmanaged(u8).empty;
            defer drop.deinit(self.allocator);
            var uit = used_vars.keyIterator();
            while (uit.next()) |k| {
                if (self.globals.contains(k.*) and !stored.contains(k.*)) {
                    try drop.append(self.allocator, k.*);
                }
            }
            for (drop.items) |k| _ = used_vars.remove(k);
        }

        var sorted_vars = std.ArrayListUnmanaged(u8).empty;
        defer sorted_vars.deinit(self.allocator);
        var it = used_vars.keyIterator();
        while (it.next()) |k| try sorted_vars.append(self.allocator, k.*);
        std.sort.block(u8, sorted_vars.items, {}, std.sort.asc(u8));

        var any_matrix_param = false;
        for (param_tags) |t| {
            if (t == .matrix) any_matrix_param = true;
        }
        const simple_scalar = isSimpleScalar(expr_ptr) and !any_matrix_param;
        const scratch_count: u32 = if (simple_scalar) 0 else 9;

        const scratch_f1: u32 = @intCast(num_params);
        const scratch_f2: u32 = @intCast(num_params + 1);
        const scratch_f3: u32 = @intCast(num_params + 2);
        const scratch_i1: u32 = @intCast(num_params + 3);
        const scratch_i2: u32 = @intCast(num_params + 4);
        const scratch_i3: u32 = @intCast(num_params + 5);
        const scratch_i4: u32 = @intCast(num_params + 6);
        const scratch_i5: u32 = @intCast(num_params + 7);
        const scratch_i64: u32 = @intCast(num_params + 8);

        var next_local = @as(u32, @intCast(num_params)) + scratch_count;
        for (sorted_vars.items) |v_idx| {
            try var_map.put(v_idx, next_local);
            next_local += 1;
        }

        var all_locals = std.ArrayListUnmanaged(types.ValType).empty;
        defer all_locals.deinit(self.allocator);
        if (!simple_scalar) {
            try all_locals.append(self.allocator, .f64);
            try all_locals.append(self.allocator, .f64);
            try all_locals.append(self.allocator, .f64);
            try all_locals.append(self.allocator, .i32);
            try all_locals.append(self.allocator, .i32);
            try all_locals.append(self.allocator, .i32);
            try all_locals.append(self.allocator, .i32);
            try all_locals.append(self.allocator, .i32);
            try all_locals.append(self.allocator, .i64);
        }
        for (0..used_vars.count()) |_| try all_locals.append(self.allocator, .f64);

        var code = std.ArrayListUnmanaged(u8).empty;
        defer code.deinit(self.allocator);
        const writer = list_writer.unmanagedByteWriter(&code, self.allocator);
        const expr_string_map = self.string_map.get(expr).?;

        // Reset empty-result kind so prior miss/null cannot leak across calls.
        try self.emitSetResultKind(writer, .number);

        try self.compileSequence(writer, expr_ptr, 0, expr_ptr.code.len, &var_map, &expr_string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);

        try self.module.addCode(code.items, all_locals.items);
    }

    /// Compile-time LaTeX generation for static `toLaTeX("...")` folds.
    fn compileTimeToLaTeX(self: *WasmCompiler, source: []const u8) ![]const u8 {
        var registry = try mathzig.units.UnitRegistry.init(self.allocator);
        defer registry.deinit();
        var config = mathzig.Config.init();
        var compiler = try mathzig.Compiler.initWithConfig(self.allocator, source, &config);
        defer compiler.deinit();
        compiler.registry = &registry;
        return try compiler.toLaTeX(self.allocator);
    }

    /// Embed a length-prefixed UTF-8 string `[u32 len][bytes]` in the data segment.
    fn addLengthPrefixedString(self: *WasmCompiler, content: []const u8) !u32 {
        if (self.data_frozen) return error.DataSegmentFrozen;
        const offset = self.current_data_offset;
        const len: u32 = @intCast(content.len);
        var buf = try self.allocator.alloc(u8, 4 + content.len);
        defer self.allocator.free(buf);
        std.mem.writeInt(u32, buf[0..4], len, .little);
        @memcpy(buf[4..], content);
        _ = try self.module.addData(@intCast(offset), buf);
        self.current_data_offset += @intCast(buf.len);
        return offset;
    }

    fn emitStringResultPtr(self: *WasmCompiler, writer: anytype, offset: u32) !void {
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        const ptr_val: f64 = @floatFromInt(offset);
        try writer.writeAll(std.mem.asBytes(&ptr_val));
        try self.pushType(.string);
    }

    fn compileSequence(
        self: *WasmCompiler,
        writer: anytype,
        expr: *const CompiledExpr,
        start: usize,
        end: usize,
        var_map: *const std.AutoHashMap(u8, u32),
        string_map: *const std.AutoHashMap(usize, u32),
        num_params: u32,
        param_offset: u32,
        scratch_f1: u32,
        scratch_f2: u32,
        scratch_f3: u32,
        scratch_i1: u32,
        scratch_i2: u32,
        scratch_i3: u32,
        scratch_i4: u32,
        scratch_i5: u32,
        scratch_i64: u32,
    ) anyerror!void {
        var pc = start;
        while (pc < end) {
            // Check if this is a loop header
            if (self.loop_headers.get(pc)) |loop_end| {
                // Avoid infinite recursion: if we are already processing this loop (start == pc and end == loop_end), don't emit it again
                const is_current_scope = (pc == start) and (loop_end == end);

                if (!is_current_scope and loop_end <= end) {
                    const needs_break_block = loopHasBreakToEnd(expr, pc, loop_end);
                    // Emit loop structure.
                    // If loop body has a break edge to loop_end, we need `block+loop` for `br_if 1`.
                    // Otherwise emit only `loop` and use `br 0` for continue.
                    if (needs_break_block) {
                        try writer.writeByte(@intFromEnum(types.Op.block));
                        try writer.writeByte(@intFromEnum(types.ValType.void));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.loop));
                    try writer.writeByte(@intFromEnum(types.ValType.void));

                    try self.compileSequence(writer, expr, pc, loop_end, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);

                    try writer.writeByte(@intFromEnum(types.Op.end)); // End loop
                    if (needs_break_block) {
                        try writer.writeByte(@intFromEnum(types.Op.end)); // End block
                    }

                    pc = loop_end;
                    continue;
                }
            }

            const inst = expr.code[pc];

            // Constant-fold `toLaTeX("static")` using the Zig LaTeX generator.
            if (pc + 1 < end and inst.opcode == .push_const) {
                const next = expr.code[pc + 1];
                if (next.opcode == .call_builtin and
                    @as(BuiltinFn, @enumFromInt(@as(u16, @truncate(next.operand)))) == .toLaTeX and
                    @as(u8, @truncate((next.operand >> 16) & 0xFF)) == 1)
                {
                    const val = expr.constants[inst.operand];
                    if (val.tag == .string) {
                        // Pre-folded before the heap base froze; folding here
                        // would append data that overlaps the runtime heap.
                        const source = val.data.string.toSlice();
                        const offset = self.latex_fold_map.get(source) orelse blk: {
                            const latex = try self.compileTimeToLaTeX(source);
                            defer self.allocator.free(latex);
                            break :blk try self.addLengthPrefixedString(latex);
                        };
                        try self.emitStringResultPtr(writer, offset);
                        pc += 2;
                        continue;
                    }
                }
            }

            if (inst.opcode == .def_user and pc + 1 < end and expr.code[pc + 1].opcode == .pop) {
                pc += 2;
                continue;
            }

            if (inst.opcode == .load_var and pc + 3 < end and expr.code[pc + 1].opcode == .load_var and isCompareOp(expr.code[pc + 2].opcode) and expr.code[pc + 3].opcode == .jmp_if_false) {
                const else_target = expr.code[pc + 3].operand;
                if (else_target > 0 and else_target < end) {
                    const before_else = expr.code[else_target - 1];
                    if (before_else.opcode == .jmp) {
                        const end_target = before_else.operand;
                        if (end_target <= end and isPureRange(expr, pc + 4, else_target - 1) and isPureRange(expr, else_target, end_target)) {
                            try self.compileSequence(writer, expr, pc + 4, else_target - 1, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                            try self.compileSequence(writer, expr, else_target, end_target, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);

                            const a_idx = var_map.get(@intCast(expr.code[pc].operand)) orelse return error.UnknownVariable;
                            const b_idx = var_map.get(@intCast(expr.code[pc + 1].operand)) orelse return error.UnknownVariable;
                            try self.pushType(.number);
                            try self.pushType(.number);
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, a_idx);
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, b_idx);
                            switch (expr.code[pc + 2].opcode) {
                                .lt => try writer.writeByte(@intFromEnum(types.Op.f64_lt)),
                                .le => try writer.writeByte(@intFromEnum(types.Op.f64_le)),
                                .gt => try writer.writeByte(@intFromEnum(types.Op.f64_gt)),
                                .ge => try writer.writeByte(@intFromEnum(types.Op.f64_ge)),
                                .eq => try writer.writeByte(@intFromEnum(types.Op.f64_eq)),
                                .ne => try writer.writeByte(@intFromEnum(types.Op.f64_ne)),
                                else => {},
                            }
                            _ = self.popType();
                            _ = self.popType();
                            try self.pushType(.number); // condition
                            _ = self.popType();
                            _ = self.popType();
                            _ = self.popType();
                            try self.pushType(.number);
                            try writer.writeByte(@intFromEnum(types.Op.select));
                            pc = end_target;
                            continue;
                        }
                    }
                }
            }

            if (inst.opcode == .push_const and pc + 1 < end and expr.code[pc + 1].opcode == .pow) {
                const c_idx: u8 = @intCast(inst.operand);
                const val = expr.constants[c_idx];
                if (val.tag == .number) {
                    const n = val.data.number;
                    if (n == 2.0 or n == 3.0) {
                        // Fast path for x^2 / x^3
                        if (pc > 0 and expr.code[pc - 1].opcode == .load_var) {
                            const var_idx: u8 = @intCast(expr.code[pc - 1].operand);
                            const wasm_idx = var_map.get(var_idx) orelse return error.UnknownVariable;
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, wasm_idx);
                            try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                            if (n == 3.0) {
                                try writer.writeByte(@intFromEnum(types.Op.local_get));
                                _ = try leb.encodeUnsigned(writer, wasm_idx);
                                try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                            }
                        } else if (pc > 0 and expr.code[pc - 1].opcode == .push_const and
                            expr.constants[expr.code[pc - 1].operand].tag == .number)
                        {
                            const base_idx: u8 = @intCast(expr.code[pc - 1].operand);
                            const base_val = expr.constants[base_idx].data.number;
                            try writer.writeByte(@intFromEnum(types.Op.f64_const));
                            try writer.writeAll(std.mem.asBytes(&base_val));
                            try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                            if (n == 3.0) {
                                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                                try writer.writeAll(std.mem.asBytes(&base_val));
                                try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                            }
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.local_tee));
                            _ = try leb.encodeUnsigned(writer, scratch_f1);
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_f1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                            if (n == 3.0) {
                                try writer.writeByte(@intFromEnum(types.Op.local_get));
                                _ = try leb.encodeUnsigned(writer, scratch_f1);
                                try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                            }
                        }
                        _ = self.popType();
                        try self.pushType(.number);
                        pc += 2;
                        continue;
                    }
                }
            }

            if (isCompareOp(inst.opcode) and pc + 1 < end and expr.code[pc + 1].opcode == .jmp_if_false) {
                const else_target = expr.code[pc + 1].operand;
                if (else_target > 0 and else_target < end) {
                    const before_else = expr.code[else_target - 1];
                    if (before_else.opcode == .jmp) {
                        const end_target = before_else.operand;
                        if (end_target <= end and isPureRange(expr, pc + 2, else_target - 1) and isPureRange(expr, else_target, end_target)) {
                            const then_len = (else_target - 1) - (pc + 2);
                            const else_len = end_target - else_target;
                            if (pc >= 2 and then_len == 1 and else_len == 1) {
                                const a = expr.code[pc - 2];
                                const b = expr.code[pc - 1];
                                const then_inst = expr.code[pc + 2];
                                const else_inst = expr.code[else_target];
                                if (a.opcode == .load_var and b.opcode == .load_var and then_inst.opcode == .load_var and else_inst.opcode == .load_var and then_inst.operand == a.operand and else_inst.operand == b.operand) {
                                    // Emit: a b a b cmp select (no local.set/get)
                                    const a_idx = var_map.get(@intCast(a.operand)) orelse return error.UnknownVariable;
                                    const b_idx = var_map.get(@intCast(b.operand)) orelse return error.UnknownVariable;
                                    try self.pushType(.number);
                                    try self.pushType(.number);
                                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                                    _ = try leb.encodeUnsigned(writer, a_idx);
                                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                                    _ = try leb.encodeUnsigned(writer, b_idx);
                                    switch (inst.opcode) {
                                        .lt => try writer.writeByte(@intFromEnum(types.Op.f64_lt)),
                                        .le => try writer.writeByte(@intFromEnum(types.Op.f64_le)),
                                        .gt => try writer.writeByte(@intFromEnum(types.Op.f64_gt)),
                                        .ge => try writer.writeByte(@intFromEnum(types.Op.f64_ge)),
                                        .eq => try writer.writeByte(@intFromEnum(types.Op.f64_eq)),
                                        .ne => try writer.writeByte(@intFromEnum(types.Op.f64_ne)),
                                        else => {},
                                    }
                                    _ = self.popType();
                                    _ = self.popType();
                                    try self.pushType(.number); // condition
                                    _ = self.popType();
                                    _ = self.popType();
                                    _ = self.popType();
                                    try self.pushType(.number);
                                    try writer.writeByte(@intFromEnum(types.Op.select));
                                    pc = end_target;
                                    continue;
                                }
                            }

                            // Emit comparison directly as i32 for select
                            switch (inst.opcode) {
                                .lt => try writer.writeByte(@intFromEnum(types.Op.f64_lt)),
                                .le => try writer.writeByte(@intFromEnum(types.Op.f64_le)),
                                .gt => try writer.writeByte(@intFromEnum(types.Op.f64_gt)),
                                .ge => try writer.writeByte(@intFromEnum(types.Op.f64_ge)),
                                .eq => try writer.writeByte(@intFromEnum(types.Op.f64_eq)),
                                .ne => try writer.writeByte(@intFromEnum(types.Op.f64_ne)),
                                else => {},
                            }
                            try writer.writeByte(@intFromEnum(types.Op.local_set));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);

                            _ = self.popType();
                            _ = self.popType();

                            try self.compileSequence(writer, expr, pc + 2, else_target - 1, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                            try self.compileSequence(writer, expr, else_target, end_target, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);

                            _ = self.popType();
                            _ = self.popType();
                            try self.pushType(.number);

                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);
                            try writer.writeByte(@intFromEnum(types.Op.select));
                            pc = end_target;
                            continue;
                        }
                    }
                }
            }

            if (inst.opcode == .jmp) {
                const target = inst.operand;
                if (target < pc) {
                    // Backward jump: treat as loop continue (br 0)
                    // We assume we are inside the loop corresponding to 'target'
                    // Since compileSequence recurses on loops, 'br 0' targets the innermost loop start
                    try writer.writeByte(@intFromEnum(types.Op.br));
                    _ = try leb.encodeUnsigned(writer, 0);
                    pc += 1;
                    continue;
                }
            }

            if (inst.opcode == .dup and pc + 2 < end) {
                const n1 = expr.code[pc + 1];
                const n2 = expr.code[pc + 2];
                if (n1.opcode == .jmp_if_false and n2.opcode == .pop) {
                    const target = n1.operand;
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try emitBoolFromF64NonZero(writer);
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.f64));
                    try self.compileSequence(writer, expr, pc + 3, target, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    pc = target;
                    continue;
                }

                if (n1.opcode == .jmp_if_true and n2.opcode == .pop) {
                    const target = n1.operand;
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try emitBoolFromF64NonZero(writer);
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.f64));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try self.compileSequence(writer, expr, pc + 3, target, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    pc = target;
                    continue;
                }
            }

            if (inst.opcode == .jmp_if_false) {
                const target = inst.operand;

                // Check if this jumps to the end of the current block (loop break)
                if (target == end) {
                    // Pattern: break if false.
                    // Stack has [cond_f64]. Emit direct compare+branch:
                    // [cond] -> [cond, 0.0] -> f64_eq -> [bool_i32] -> br_if 1
                    // This consumes the condition without extra local traffic.
                    try emitBoolFromF64IsZero(writer); // 1 if 0.0 (false), 0 if true
                    try writer.writeByte(@intFromEnum(types.Op.br_if));
                    _ = try leb.encodeUnsigned(writer, 1); // Break outer block

                    pc += 1;
                    continue;
                }

                const else_target = inst.operand;
                if (else_target > 0 and else_target < end) {
                    const before_else = expr.code[else_target - 1];
                    if (before_else.opcode == .jmp) {
                        const end_target = before_else.operand;
                        if (end_target <= end) {
                            if (isPureRange(expr, pc + 1, else_target - 1) and isPureRange(expr, else_target, end_target)) {
                                try emitBoolFromF64NonZero(writer);
                                try writer.writeByte(@intFromEnum(types.Op.local_set));
                                _ = try leb.encodeUnsigned(writer, scratch_i1);
                                try self.compileSequence(writer, expr, pc + 1, else_target - 1, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                                try self.compileSequence(writer, expr, else_target, end_target, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                                try writer.writeByte(@intFromEnum(types.Op.local_get));
                                _ = try leb.encodeUnsigned(writer, scratch_i1);
                                try writer.writeByte(@intFromEnum(types.Op.select));
                                pc = end_target;
                                continue;
                            }
                            try emitBoolFromF64NonZero(writer);
                            try writer.writeByte(@intFromEnum(types.Op.if_op));
                            try writer.writeByte(@intFromEnum(types.ValType.f64));
                            try self.compileSequence(writer, expr, pc + 1, else_target - 1, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                            try writer.writeByte(@intFromEnum(types.Op.else_op));
                            try self.compileSequence(writer, expr, else_target, end_target, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
                            try writer.writeByte(@intFromEnum(types.Op.end));
                            pc = end_target;
                            continue;
                        }
                    }
                }
            }

            try self.compileInstruction(writer, inst, expr, var_map, string_map, num_params, param_offset, scratch_f1, scratch_f2, scratch_f3, scratch_i1, scratch_i2, scratch_i3, scratch_i4, scratch_i5, scratch_i64);
            pc += 1;
        }
    }

    fn registerBuiltin(self: *WasmCompiler, builtin: BuiltinFn, arg_count: u8) !void {
        if (self.builtin_map.contains(builtin)) return;

        switch (builtin) {
            .sqrt => if (arg_count == 1) return,
            .abs, .floor, .ceil, .round, .trunc => return,
            // min/max: always register the import so non-scalar two-arg forms
            // (matrix/series) can call env.min/env.max. Scalar two-arg still
            // lowers to f64.min/max at emit when both arg types are number.
            else => {},
        }

        const name = @tagName(builtin);

        if (self.standalone) {
            // Standalone bodies are registered via registerStandaloneScalarBodies
            // / registerStandaloneMatrixBodies in dependency order. Reaching here
            // means an unresolved dependency slipped past RequiredRuntimeSet.
            if (self.required_runtime.formatUnresolved(&self.standalone_error_buf)) |msg| {
                self.standalone_error_msg = msg;
            } else {
                const msg = std.fmt.bufPrint(&self.standalone_error_buf, "standalone unsupported builtin '{s}' (tier={s})", .{
                    @tagName(builtin),
                    abi.tierName(abi.signature(builtin).tier),
                }) catch "standalone unsupported builtin";
                self.standalone_error_msg = msg;
            }
            return error.StandaloneUnsupportedImport;
        }

        if (builtin == .exp or builtin == .cos or builtin == .atan or builtin == .log) {
            var p = std.ArrayListUnmanaged(types.ValType).empty;
            defer p.deinit(self.allocator);
            for (0..arg_count) |_| try p.append(self.allocator, .f64);
            const r = [_]types.ValType{.f64};
            const t = try self.module.addType(p.items, &r);
            try self.builtin_map.put(builtin, try self.module.addImport("env", name, .function, t));
            try self.recordImport(builtin, arg_count, false);
            return;
        } else if (builtin == .sin) {
            const type_idx = try self.module.addType(&[_]types.ValType{.f64}, &[_]types.ValType{.f64});
            const func_idx = try self.module.addFunction(type_idx);
            try self.builtin_map.put(builtin, func_idx);
            const code = try math_lib.generateSinBody(self.allocator);
            defer self.allocator.free(code);
            try self.module.addCode(code, &[_]types.ValType{ .f64, .f64, .f64 });
            return;
        }

        var p = std.ArrayListUnmanaged(types.ValType).empty;
        defer p.deinit(self.allocator);
        for (0..arg_count) |_| {
            try p.append(self.allocator, .f64);
        }
        const r = [_]types.ValType{.f64};
        const t = try self.module.addType(p.items, &r);
        try self.builtin_map.put(builtin, try self.module.addImport("env", name, .function, t));
        try self.recordImport(builtin, arg_count, false);
    }

    /// True when registerBuiltin lowers this builtin to an internally
    /// GENERATED wasm function body (math_lib) instead of an env import.
    /// These must register after all imports (function index space).
    fn isGeneratedBodyBuiltin(builtin: BuiltinFn, standalone: bool) bool {
        if (standalone) {
            // In standalone, implemented builtins get generated bodies (opcode-only
            // forms are skipped at registration via early return in registerBuiltin).
            return abi.standaloneImplemented(builtin);
        }
        return switch (builtin) {
            .sin => true,
            else => false,
        };
    }

    fn requiresStandaloneHeap(self: *const WasmCompiler) bool {
        if (self.pending_needs_gemm) return true;
        var it = self.required_runtime.builtins.iterator();
        while (it.next()) |f| {
            switch (f) {
                .transpose, .inv, .identity, .zeros, .ones, .diag, .flatten, .reshape, .cross, .gemv => return true,
                .ode_solve, .ode_solve_euler => return true,
                .series, .head, .tail, .cumsum, .diff, .rolling_mean, .sma, .last => return true,
                else => {},
            }
        }
        return false;
    }

    fn addUnaryF64Body(self: *WasmCompiler, builtin: BuiltinFn, code: []const u8, locals: []const types.ValType) !void {
        const type_idx = try self.module.addType(&[_]types.ValType{.f64}, &[_]types.ValType{.f64});
        const func_idx = try self.module.addFunction(type_idx);
        try self.builtin_map.put(builtin, func_idx);
        try self.module.addCode(code, locals);
    }

    fn addBinaryF64Body(self: *WasmCompiler, builtin: BuiltinFn, code: []const u8, locals: []const types.ValType) !void {
        const type_idx = try self.module.addType(&[_]types.ValType{ .f64, .f64 }, &[_]types.ValType{.f64});
        const func_idx = try self.module.addFunction(type_idx);
        try self.builtin_map.put(builtin, func_idx);
        try self.module.addCode(code, locals);
    }

    fn addNaryF64Body(self: *WasmCompiler, builtin: BuiltinFn, arg_count: u8, code: []const u8, locals: []const types.ValType) !void {
        var p = std.ArrayListUnmanaged(types.ValType).empty;
        defer p.deinit(self.allocator);
        for (0..arg_count) |_| try p.append(self.allocator, .f64);
        const type_idx = try self.module.addType(p.items, &[_]types.ValType{.f64});
        const func_idx = try self.module.addFunction(type_idx);
        try self.builtin_map.put(builtin, func_idx);
        try self.module.addCode(code, locals);
    }

    fn ensureBaseHelper(self: *WasmCompiler, builtin: BuiltinFn) !u32 {
        if (self.builtin_map.get(builtin)) |idx| return idx;
        switch (builtin) {
            .exp => {
                const code = try math_lib.generateExpBody(self.allocator);
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.exp, code, &[_]types.ValType{ .f64, .f64 });
            },
            .log => {
                const code = try math_lib.generateLogBody(self.allocator);
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.log, code, &[_]types.ValType{ .i64, .f64, .f64, .f64, .f64 });
            },
            .sin => {
                const code = try math_lib.generateSinBody(self.allocator);
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.sin, code, &[_]types.ValType{ .f64, .f64, .f64 });
            },
            .cos => {
                // Prefer composition with sin when available; else poly.
                if (self.builtin_map.get(.sin)) |sin_idx| {
                    const code = try math_lib.generateCosBody(self.allocator, sin_idx);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.cos, code, &[_]types.ValType{});
                } else {
                    const code = try math_lib.generateCosPolyBody(self.allocator);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.cos, code, &[_]types.ValType{ .f64, .f64, .f64 });
                }
            },
            .atan => {
                const code = try math_lib.generateAtanBody(self.allocator);
                defer self.allocator.free(code);
                // locals 1..6: a/u, z, sign, complement, result, add_pi4
                try self.addUnaryF64Body(.atan, code, &[_]types.ValType{ .f64, .f64, .f64, .f64, .f64, .f64 });
            },
            else => return error.StandaloneUnsupportedImport,
        }
        return self.builtin_map.get(builtin).?;
    }

    /// Register Tier-1 scalar libm bodies in dependency order.
    fn registerStandaloneScalarBodies(self: *WasmCompiler) !void {
        const set = self.required_runtime;
        // Always ensure bases first when any dependent is present.
        const need_exp = set.builtins.contains(.exp) or set.builtins.contains(.sinh) or set.builtins.contains(.cosh) or
            set.builtins.contains(.tanh) or set.builtins.contains(.sech) or set.builtins.contains(.csch) or
            set.builtins.contains(.coth) or set.builtins.contains(.cbrt) or set.builtins.contains(.expm1) or
            set.needs_pow or set.builtins.contains(.nthRoot);
        const need_log = set.builtins.contains(.log) or set.builtins.contains(.log10) or set.builtins.contains(.log2) or
            set.builtins.contains(.log1p) or set.builtins.contains(.asinh) or set.builtins.contains(.acosh) or
            set.builtins.contains(.atanh) or set.builtins.contains(.asech) or set.builtins.contains(.acsch) or
            set.builtins.contains(.acoth) or set.builtins.contains(.cbrt) or set.needs_pow or set.builtins.contains(.nthRoot);
        const need_sin = set.builtins.contains(.sin) or set.builtins.contains(.cos) or set.builtins.contains(.tan) or
            set.builtins.contains(.sec) or set.builtins.contains(.csc) or set.builtins.contains(.cot);
        const need_cos = set.builtins.contains(.cos) or set.builtins.contains(.tan) or set.builtins.contains(.sec) or
            set.builtins.contains(.cot);
        const need_atan = set.builtins.contains(.atan) or set.builtins.contains(.asin) or set.builtins.contains(.acos) or
            set.builtins.contains(.atan2) or set.builtins.contains(.asec) or set.builtins.contains(.acsc) or
            set.builtins.contains(.acot);

        if (need_exp) _ = try self.ensureBaseHelper(.exp);
        if (need_log) _ = try self.ensureBaseHelper(.log);
        if (need_sin) _ = try self.ensureBaseHelper(.sin);
        if (need_cos) _ = try self.ensureBaseHelper(.cos);
        if (need_atan) _ = try self.ensureBaseHelper(.atan);

        // Composed / remaining scalars (log arity handled after, so unary stays for helpers)
        var it = set.builtins.iterator();
        while (it.next()) |b| {
            if (b == .log) continue; // bases already ensured; binary rewrite below
            if (self.builtin_map.contains(b)) continue;
            if (abi.RequiredRuntimeSet.isOpcodeOnlyScalar(b, set.max_args.get(b))) continue;
            // Matrix / ODE / series tiers deferred to later registration passes.
            switch (b) {
                .transpose, .det, .inv, .trace, .dot, .cross, .identity, .zeros, .ones, .diag, .flatten, .reshape, .gemv, .sum, .mean, .prod, .count, .norm => continue,
                .ode_solve, .ode_solve_euler => continue,
                .series, .last, .head, .tail, .cumsum, .diff, .rolling_mean, .sma => continue,
                else => {},
            }
            try self.emitStandaloneScalar(b, set.max_args.get(b));
        }
        // Binary log(x, base) overwrites the map entry after dependents registered.
        if (set.builtins.contains(.log) and set.max_args.get(.log) >= 2) {
            const unary = self.builtin_map.get(.log) orelse try self.ensureBaseHelper(.log);
            const bin = try math_lib.generateLogBaseBody(self.allocator, unary);
            defer self.allocator.free(bin);
            const type_idx = try self.module.addType(&[_]types.ValType{ .f64, .f64 }, &[_]types.ValType{.f64});
            const func_idx = try self.module.addFunction(type_idx);
            try self.builtin_map.put(.log, func_idx);
            try self.module.addCode(bin, &[_]types.ValType{});
        }
    }

    fn emitStandaloneScalar(self: *WasmCompiler, b: BuiltinFn, arg_count: u8) !void {
        if (self.builtin_map.contains(b)) return;
        const exp_idx = self.builtin_map.get(.exp);
        const log_idx = self.builtin_map.get(.log);
        const sin_idx = self.builtin_map.get(.sin);
        const cos_idx = self.builtin_map.get(.cos);
        const atan_idx = self.builtin_map.get(.atan);

        _ = arg_count;
        switch (b) {
            .log => _ = try self.ensureBaseHelper(.log),
            .log10 => {
                const code = try math_lib.generateLog10Body(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.log10, code, &[_]types.ValType{});
            },
            .log2 => {
                const code = try math_lib.generateLog2Body(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.log2, code, &[_]types.ValType{});
            },
            .log1p => {
                const code = try math_lib.generateLog1pBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.log1p, code, &[_]types.ValType{});
            },
            .expm1 => {
                const code = try math_lib.generateExpm1Body(self.allocator, exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.expm1, code, &[_]types.ValType{});
            },
            .tan => {
                const code = try math_lib.generateTanBody(self.allocator, sin_idx orelse try self.ensureBaseHelper(.sin), cos_idx orelse try self.ensureBaseHelper(.cos));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.tan, code, &[_]types.ValType{});
            },
            .asin => {
                const code = try math_lib.generateAsinBody(self.allocator, atan_idx orelse try self.ensureBaseHelper(.atan));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.asin, code, &[_]types.ValType{});
            },
            .acos => {
                const code = try math_lib.generateAcosBody(self.allocator, atan_idx orelse try self.ensureBaseHelper(.atan));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.acos, code, &[_]types.ValType{});
            },
            .atan2 => {
                const code = try math_lib.generateAtan2Body(self.allocator, atan_idx orelse try self.ensureBaseHelper(.atan));
                defer self.allocator.free(code);
                try self.addBinaryF64Body(.atan2, code, &[_]types.ValType{.f64});
            },
            .sinh => {
                const code = try math_lib.generateSinhBody(self.allocator, exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.sinh, code, &[_]types.ValType{});
            },
            .cosh => {
                const code = try math_lib.generateCoshBody(self.allocator, exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.cosh, code, &[_]types.ValType{});
            },
            .tanh => {
                const code = try math_lib.generateTanhBody(self.allocator, exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.tanh, code, &[_]types.ValType{.f64});
            },
            .asinh => {
                const code = try math_lib.generateAsinhBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.asinh, code, &[_]types.ValType{});
            },
            .acosh => {
                const code = try math_lib.generateAcoshBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.acosh, code, &[_]types.ValType{});
            },
            .atanh => {
                const code = try math_lib.generateAtanhBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.atanh, code, &[_]types.ValType{});
            },
            .sec => {
                const code = try math_lib.generateRecipTrigBody(self.allocator, cos_idx orelse try self.ensureBaseHelper(.cos));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.sec, code, &[_]types.ValType{});
            },
            .csc => {
                const code = try math_lib.generateRecipTrigBody(self.allocator, sin_idx orelse try self.ensureBaseHelper(.sin));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.csc, code, &[_]types.ValType{});
            },
            .cot => {
                const code = try math_lib.generateTanBody(self.allocator, cos_idx orelse try self.ensureBaseHelper(.cos), sin_idx orelse try self.ensureBaseHelper(.sin));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.cot, code, &[_]types.ValType{});
            },
            .asec => {
                const code = try math_lib.generateAsecBody(self.allocator, atan_idx orelse try self.ensureBaseHelper(.atan));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.asec, code, &[_]types.ValType{.f64});
            },
            .acsc => {
                const code = try math_lib.generateAcscBody(self.allocator, atan_idx orelse try self.ensureBaseHelper(.atan));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.acsc, code, &[_]types.ValType{.f64});
            },
            .acot => {
                const code = try math_lib.generateAcotBody(self.allocator, atan_idx orelse try self.ensureBaseHelper(.atan));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.acot, code, &[_]types.ValType{});
            },
            .sech => {
                const code = try math_lib.generateSechBody(self.allocator, exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.sech, code, &[_]types.ValType{});
            },
            .csch => {
                const code = try math_lib.generateCschBody(self.allocator, exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.csch, code, &[_]types.ValType{});
            },
            .coth => {
                const code = try math_lib.generateCothBody(self.allocator, exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.coth, code, &[_]types.ValType{.f64});
            },
            .asech => {
                const code = try math_lib.generateAsechBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.asech, code, &[_]types.ValType{.f64});
            },
            .acsch => {
                const code = try math_lib.generateAcschBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.acsch, code, &[_]types.ValType{.f64});
            },
            .acoth => {
                const code = try math_lib.generateAcothBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.acoth, code, &[_]types.ValType{});
            },
            .hypot => {
                const code = try math_lib.generateHypotBody(self.allocator);
                defer self.allocator.free(code);
                try self.addBinaryF64Body(.hypot, code, &[_]types.ValType{});
            },
            .sign => {
                const code = try math_lib.generateSignBody(self.allocator);
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.sign, code, &[_]types.ValType{});
            },
            .clamp => {
                const code = try math_lib.generateClampBody(self.allocator);
                defer self.allocator.free(code);
                try self.addNaryF64Body(.clamp, 3, code, &[_]types.ValType{});
            },
            .square => {
                const code = try math_lib.generateSquareBody(self.allocator);
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.square, code, &[_]types.ValType{});
            },
            .cube => {
                const code = try math_lib.generateCubeBody(self.allocator);
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.cube, code, &[_]types.ValType{});
            },
            .cbrt => {
                const code = try math_lib.generateCbrtBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log), exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addUnaryF64Body(.cbrt, code, &[_]types.ValType{.f64});
            },
            .nthRoot => {
                const code = try math_lib.generateNthRootBody(self.allocator, log_idx orelse try self.ensureBaseHelper(.log), exp_idx orelse try self.ensureBaseHelper(.exp));
                defer self.allocator.free(code);
                try self.addBinaryF64Body(.nthRoot, code, &[_]types.ValType{});
            },
            .exp, .sin, .cos, .atan => _ = try self.ensureBaseHelper(b),
            else => {
                const msg = std.fmt.bufPrint(&self.standalone_error_buf, "standalone unsupported builtin '{s}' (tier={s})", .{
                    @tagName(b),
                    abi.tierName(abi.signature(b).tier),
                }) catch "standalone unsupported builtin";
                self.standalone_error_msg = msg;
                return error.StandaloneUnsupportedImport;
            },
        }
    }

    fn ensureStandaloneGemm(self: *WasmCompiler) !void {
        if (self.gemm_import_idx != null) return;
        const t = try self.module.addType(&[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, &[_]types.ValType{});
        const func_idx = try self.module.addFunction(t);
        self.gemm_import_idx = func_idx;
        const code = try math_lib.generateGemmBody(self.allocator);
        defer self.allocator.free(code);
        // locals: 9=i,10=j,11=k i32; 12=sum f64; 13 unused
        try self.module.addCode(code, &[_]types.ValType{ .i32, .i32, .i32, .f64 });
    }

    fn registerStandaloneMatrixBodies(self: *WasmCompiler) !void {
        const heap = self.heap_ptr_idx;
        var it = self.required_runtime.builtins.iterator();
        while (it.next()) |b| {
            if (self.builtin_map.contains(b)) continue;
            const argc = self.required_runtime.max_args.get(b);
            switch (b) {
                .transpose => {
                    const code = try math_lib.generateTransposeBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.transpose, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .f64 });
                },
                .det => {
                    const code = try math_lib.generateDetBody(self.allocator);
                    defer self.allocator.free(code);
                    // locals after param0: 1=src i32, 2=n i32, 3=result f64
                    try self.addUnaryF64Body(.det, code, &[_]types.ValType{ .i32, .i32, .f64 });
                },
                .inv => {
                    const code = try math_lib.generateInvBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.inv, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .f64, .f64 });
                },
                .trace => {
                    const code = try math_lib.generateTraceBody(self.allocator);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.trace, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .f64 });
                },
                .zeros => {
                    const n: u8 = if (argc >= 2) 2 else 1;
                    const code = try math_lib.generateZerosBody(self.allocator, heap, n);
                    defer self.allocator.free(code);
                    // 2-arg: 7 i32 locals (rows..i); 1-arg: 7 i32 locals
                    try self.addNaryF64Body(.zeros, n, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .ones => {
                    const n: u8 = if (argc >= 2) 2 else 1;
                    const code = try math_lib.generateOnesBody(self.allocator, heap, n);
                    defer self.allocator.free(code);
                    try self.addNaryF64Body(.ones, n, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .identity => {
                    const code = try math_lib.generateIdentityBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.identity, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .sum => {
                    const code = try math_lib.generateMatrixSumBody(self.allocator);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.sum, code, &[_]types.ValType{ .i32, .i32, .i32, .f64 });
                },
                .mean => {
                    const code = try math_lib.generateMatrixMeanBody(self.allocator);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.mean, code, &[_]types.ValType{ .i32, .i32, .i32, .f64, .f64 });
                },
                .prod => {
                    const code = try math_lib.generateMatrixProdBody(self.allocator);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.prod, code, &[_]types.ValType{ .i32, .i32, .i32, .f64 });
                },
                // count: matrix form is rejected by the VM; series-only via
                // registerStandaloneSeriesBodies / series_helper_map.
                .dot => {
                    const code = try math_lib.generateDotBody(self.allocator);
                    defer self.allocator.free(code);
                    try self.addBinaryF64Body(.dot, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .f64 });
                },
                .cross => {
                    const code = try math_lib.generateCrossBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addBinaryF64Body(.cross, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .flatten => {
                    const code = try math_lib.generateFlattenBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.flatten, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .f64 });
                },
                .diag => {
                    const code = try math_lib.generateDiagBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.diag, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .f64 });
                },
                .reshape => {
                    const code = try math_lib.generateReshapeBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    // params 0..2 f64; locals 3..10 i32, 11 f64
                    try self.addNaryF64Body(.reshape, 3, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .f64 });
                },
                .gemv => {
                    const code = try math_lib.generateGemvBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addBinaryF64Body(.gemv, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .f64 });
                },
                .norm => {
                    const code = try math_lib.generateNormBody(self.allocator);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.norm, code, &[_]types.ValType{ .i32, .i32, .i32, .f64, .f64 });
                },
                else => {},
            }
        }
    }

    /// Tier 4 series helpers (SeriesLayout). mean/sum/count/last also get
    /// series variants stored in series_helper_map for dual dispatch.
    fn registerStandaloneSeriesBodies(self: *WasmCompiler) !void {
        const heap = self.heap_ptr_idx;
        var it = self.required_runtime.builtins.iterator();
        while (it.next()) |b| {
            const argc = self.required_runtime.max_args.get(b);
            switch (b) {
                .series => {
                    if (self.builtin_map.contains(.series)) continue;
                    const n: u8 = if (argc >= 2) 2 else 1;
                    const code = try math_lib.generateSeriesCtorBody(self.allocator, heap, n);
                    defer self.allocator.free(code);
                    // locals: up to base+7 with base=2 → locals 2..9 = 8 slots (i32×7 + spare)
                    try self.addNaryF64Body(.series, n, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .sum => {
                    if (self.series_helper_map.contains(.sum)) continue;
                    const code = try math_lib.generateSeriesSumBody(self.allocator);
                    defer self.allocator.free(code);
                    const type_idx = try self.module.addType(&[_]types.ValType{.f64}, &[_]types.ValType{.f64});
                    const func_idx = try self.module.addFunction(type_idx);
                    try self.series_helper_map.put(.sum, func_idx);
                    try self.module.addCode(code, &[_]types.ValType{ .i32, .i32, .i32, .f64, .f64, .f64 });
                },
                .mean => {
                    if (self.series_helper_map.contains(.mean)) continue;
                    const code = try math_lib.generateSeriesMeanBody(self.allocator);
                    defer self.allocator.free(code);
                    const type_idx = try self.module.addType(&[_]types.ValType{.f64}, &[_]types.ValType{.f64});
                    const func_idx = try self.module.addFunction(type_idx);
                    try self.series_helper_map.put(.mean, func_idx);
                    try self.module.addCode(code, &[_]types.ValType{ .i32, .i32, .i32, .f64, .f64, .f64 });
                },
                .count => {
                    // Always register series helper even if matrix count already occupies builtin_map.
                    if (self.series_helper_map.contains(.count)) continue;
                    const code = try math_lib.generateSeriesCountBody(self.allocator);
                    defer self.allocator.free(code);
                    const type_idx = try self.module.addType(&[_]types.ValType{.f64}, &[_]types.ValType{.f64});
                    const func_idx = try self.module.addFunction(type_idx);
                    try self.series_helper_map.put(.count, func_idx);
                    // Only default builtin_map if matrix path did not claim it.
                    if (!self.builtin_map.contains(.count)) {
                        try self.builtin_map.put(.count, func_idx);
                    }
                    try self.module.addCode(code, &[_]types.ValType{ .i32, .i32, .i32, .f64, .f64, .f64 });
                },
                .last => {
                    // Series last → number; matrix last → last row (also register matrix body in builtin_map).
                    if (!self.series_helper_map.contains(.last)) {
                        const code = try math_lib.generateSeriesLastBody(self.allocator);
                        defer self.allocator.free(code);
                        const type_idx = try self.module.addType(&[_]types.ValType{.f64}, &[_]types.ValType{.f64});
                        const func_idx = try self.module.addFunction(type_idx);
                        try self.series_helper_map.put(.last, func_idx);
                        try self.module.addCode(code, &[_]types.ValType{ .i32, .i32 });
                    }
                    if (!self.builtin_map.contains(.last)) {
                        const code = try math_lib.generateMatrixLastBody(self.allocator, heap);
                        defer self.allocator.free(code);
                        try self.addUnaryF64Body(.last, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                    }
                },
                .head => {
                    if (self.builtin_map.contains(.head)) continue;
                    const code = try math_lib.generateSeriesHeadTailBody(self.allocator, heap, false);
                    defer self.allocator.free(code);
                    try self.addBinaryF64Body(.head, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .tail => {
                    if (self.builtin_map.contains(.tail)) continue;
                    const code = try math_lib.generateSeriesHeadTailBody(self.allocator, heap, true);
                    defer self.allocator.free(code);
                    try self.addBinaryF64Body(.tail, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .cumsum => {
                    if (self.builtin_map.contains(.cumsum)) continue;
                    const code = try math_lib.generateSeriesCumsumBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addUnaryF64Body(.cumsum, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .f64, .f64 });
                },
                .diff => {
                    if (self.builtin_map.contains(.diff)) continue;
                    const code = try math_lib.generateSeriesDiffBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addBinaryF64Body(.diff, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 });
                },
                .rolling_mean, .sma => {
                    if (self.builtin_map.contains(b)) continue;
                    const code = try math_lib.generateSeriesRollingMeanBody(self.allocator, heap);
                    defer self.allocator.free(code);
                    try self.addBinaryF64Body(b, code, &[_]types.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .f64, .f64 });
                },
                else => {},
            }
        }
    }

    /// Tier 3: declare specialized ODE function indices (code deferred).
    fn declareStandaloneOdeBodies(self: *WasmCompiler) !void {
        const heap = self.heap_ptr_idx;

        for (self.pending_ode_targets.items) |t| {
            const is_euler = t.builtin == .ode_solve_euler;
            const deriv_idx = self.user_fn_name_map.get(t.name) orelse {
                const msg = std.fmt.bufPrint(&self.standalone_error_buf, "standalone ODE unknown deriv '{s}'", .{t.name}) catch "standalone ODE unknown deriv";
                self.standalone_error_msg = msg;
                return error.StandaloneUnsupportedImport;
            };
            const method: math_lib.OdeMethod = if (is_euler) .euler else .rk4;
            const map_key = self.odeHelperKey(is_euler, deriv_idx);
            if (self.ode_helper_map.contains(map_key)) continue;

            const code = try math_lib.generateOdeBody(self.allocator, heap, deriv_idx, method);
            const type_idx = try self.module.addType(&[_]types.ValType{ .f64, .f64, .f64, .f64 }, &[_]types.ValType{.f64});
            const func_idx = try self.module.addFunction(type_idx);
            try self.ode_helper_map.put(map_key, func_idx);
            // Default builtin_map entry: first specialization wins; call site may override.
            if (!self.builtin_map.contains(t.builtin)) {
                try self.builtin_map.put(t.builtin, func_idx);
            }
            try self.pending_ode_codes.append(self.allocator, .{ .func_idx = func_idx, .code = code });
        }

        // If ODE is required but no static targets were discovered, hard-error.
        if ((self.required_runtime.builtins.contains(.ode_solve) or self.required_runtime.builtins.contains(.ode_solve_euler)) and self.ode_helper_map.count() == 0) {
            const msg = std.fmt.bufPrint(&self.standalone_error_buf, "standalone ODE requires static deriv name string (tier=ode)", .{}) catch "standalone ODE needs static deriv";
            self.standalone_error_msg = msg;
            return error.StandaloneUnsupportedImport;
        }
    }

    fn emitStandaloneOdeBodies(self: *WasmCompiler) !void {
        for (self.pending_ode_codes.items) |e| {
            try self.module.addCode(e.code, &math_lib.ode_locals);
            self.allocator.free(e.code);
        }
        self.pending_ode_codes.clearRetainingCapacity();
    }

    fn odeHelperKey(_: *const WasmCompiler, is_euler: bool, deriv_idx: u32) u64 {
        return (@as(u64, if (is_euler) 1 else 0) << 32) | @as(u64, deriv_idx);
    }

    /// Record an env import in the module's ABI manifest (mathzig.abi custom
    /// section). Consulting abi.signature here is the totality check: a new
    /// BuiltinFn without a table entry fails to compile.
    fn recordImport(self: *WasmCompiler, builtin: BuiltinFn, arg_count: u8, is_where: bool) !void {
        _ = abi.signature(builtin);
        try self.import_manifest.append(self.allocator, .{
            .builtin = builtin,
            .arg_count = arg_count,
            .is_where = is_where,
        });
    }

    fn registerBuiltinWhere(self: *WasmCompiler, builtin: BuiltinFn, arg_count: u8) !void {
        if (self.builtin_where_map.contains(builtin)) return;
        if (self.standalone) {
            const msg = std.fmt.bufPrint(&self.standalone_error_buf, "standalone unsupported builtin '{s}_where' (tier={s}, where-variant)", .{
                @tagName(builtin),
                abi.tierName(abi.signature(builtin).tier),
            }) catch "standalone unsupported where-variant";
            self.standalone_error_msg = msg;
            return error.StandaloneUnsupportedImport;
        }

        // where-variant import always accepts original args + predicate payload.
        var p = std.ArrayListUnmanaged(types.ValType).empty;
        defer p.deinit(self.allocator);
        for (0..arg_count + 1) |_| {
            try p.append(self.allocator, .f64);
        }
        const r = [_]types.ValType{.f64};
        const t = try self.module.addType(p.items, &r);

        var name_buf: [96]u8 = undefined;
        const where_name = try std.fmt.bufPrint(&name_buf, "{s}_where", .{@tagName(builtin)});
        try self.builtin_where_map.put(builtin, try self.module.addImport("env", where_name, .function, t));
        try self.recordImport(builtin, arg_count, true);
    }

    /// Materialize a complex constant `[f64 re][f64 im]` in the data segment
    /// (deduplicated). Must run before the heap base is frozen.
    fn ensureComplexData(self: *WasmCompiler, re: f64, im: f64) !u32 {
        const key: u128 = (@as(u128, @as(u64, @bitCast(re))) << 64) | @as(u64, @bitCast(im));
        if (self.complex_const_offsets.get(key)) |off| return off;
        if (self.data_frozen) return error.DataSegmentFrozen;
        const offset = self.current_data_offset;
        var buf: [16]u8 = undefined;
        std.mem.copyForwards(u8, buf[0..8], std.mem.asBytes(&re));
        std.mem.copyForwards(u8, buf[8..16], std.mem.asBytes(&im));
        _ = try self.module.addData(@intCast(offset), &buf);
        self.current_data_offset += 16;
        try self.complex_const_offsets.put(key, offset);
        return offset;
    }

    /// Pre-fold `toLaTeX("static")` results into the data segment before the
    /// heap base is frozen; compileSequence reads them from latex_fold_map.
    fn prefoldLatexStrings(self: *WasmCompiler, expr: *const CompiledExpr) !void {
        if (expr.code.len < 2) return;
        for (0..expr.code.len - 1) |pc| {
            const inst = expr.code[pc];
            const next = expr.code[pc + 1];
            if (inst.opcode != .push_const or next.opcode != .call_builtin) continue;
            if (@as(BuiltinFn, @enumFromInt(@as(u16, @truncate(next.operand)))) != .toLaTeX) continue;
            if (@as(u8, @truncate((next.operand >> 16) & 0xFF)) != 1) continue;
            const val = expr.constants[inst.operand];
            if (val.tag != .string) continue;
            const source = val.data.string.toSlice();
            if (self.latex_fold_map.contains(source)) continue;
            const latex = try self.compileTimeToLaTeX(source);
            defer self.allocator.free(latex);
            const offset = try self.addLengthPrefixedString(latex);
            try self.latex_fold_map.put(source, offset);
        }
    }

    fn addPredicateData(self: *WasmCompiler, p: *const Predicate) !u32 {
        if (self.predicate_dedup.get(p)) |off| return off;
        if (self.data_frozen) return error.DataSegmentFrozen;

        var left_ptr: i32 = -1;
        var right_ptr: i32 = -1;
        if (p.left) |left| {
            left_ptr = @as(i32, @intCast(try self.addPredicateData(left)));
        }
        if (p.right) |right| {
            right_ptr = @as(i32, @intCast(try self.addPredicateData(right)));
        }

        const off = self.current_data_offset;
        var buf: [24]u8 = undefined;
        @memset(buf[0..], 0);
        std.mem.writeInt(u32, buf[0..4], @intFromEnum(p.op), .little);
        std.mem.writeInt(u32, buf[4..8], @intFromEnum(p.field), .little);
        std.mem.copyForwards(u8, buf[8..16], std.mem.asBytes(&p.constant));
        std.mem.writeInt(i32, buf[16..20], left_ptr, .little);
        std.mem.writeInt(i32, buf[20..24], right_ptr, .little);

        _ = try self.module.addData(@intCast(off), &buf);
        self.current_data_offset += buf.len;
        try self.predicate_dedup.put(p, off);
        return off;
    }

    fn ensurePowFunction(self: *WasmCompiler) !void {
        if (self.pow_func_idx != null) return;

        const log_idx: u32 = if (self.standalone)
            try self.ensureBaseHelper(.log)
        else blk: {
            try self.registerBuiltin(.log, 1);
            break :blk self.builtin_map.get(.log).?;
        };
        const exp_idx: u32 = if (self.standalone)
            try self.ensureBaseHelper(.exp)
        else blk: {
            try self.registerBuiltin(.exp, 1);
            break :blk self.builtin_map.get(.exp).?;
        };

        const type_idx = try self.module.addType(&[_]types.ValType{ .f64, .f64 }, &[_]types.ValType{.f64});
        const func_idx = try self.module.addFunction(type_idx);
        self.pow_func_idx = func_idx;

        const code = try math_lib.generatePowBody(self.allocator, log_idx, exp_idx);
        defer self.allocator.free(code);
        try self.module.addCode(code, &[_]types.ValType{});
    }

    fn ensureFmodFunction(self: *WasmCompiler) !void {
        if (self.fmod_import_idx != null) return;
        if (self.standalone) {
            const type_idx = try self.module.addType(&[_]types.ValType{ .f64, .f64 }, &[_]types.ValType{.f64});
            const func_idx = try self.module.addFunction(type_idx);
            self.fmod_import_idx = func_idx;
            const code = try math_lib.generateFmodBody(self.allocator);
            defer self.allocator.free(code);
            try self.module.addCode(code, &[_]types.ValType{});
            return;
        }

        const p = [_]types.ValType{ .f64, .f64 };
        const r = [_]types.ValType{.f64};
        const t = try self.module.addType(&p, &r);
        self.fmod_import_idx = try self.module.addImport("env", "fmod", .function, t);
    }

    fn pushType(self: *WasmCompiler, tag: mathzig.ValueTag) !void {
        try self.type_stack.append(self.allocator, tag);
        try self.unit_stack.append(self.allocator, null);
        try self.string_hint_stack.append(self.allocator, null);
    }

    fn pushStringType(self: *WasmCompiler, name: []const u8) !void {
        try self.type_stack.append(self.allocator, .string);
        try self.unit_stack.append(self.allocator, null);
        try self.string_hint_stack.append(self.allocator, name);
    }

    /// Push a unit-typed stack slot with static dimensional metadata.
    fn pushUnitType(self: *WasmCompiler, meta: UnitMeta) !void {
        self.saw_static_unit = true;
        try self.type_stack.append(self.allocator, .unit);
        try self.unit_stack.append(self.allocator, meta);
        try self.string_hint_stack.append(self.allocator, null);
    }

    /// Push a typed slot carrying optional unit metadata (e.g. arithmetic
    /// result that preserves dimensions).
    fn pushTypeWithUnit(self: *WasmCompiler, tag: mathzig.ValueTag, meta: ?UnitMeta) !void {
        if (meta != null) self.saw_static_unit = true;
        try self.type_stack.append(self.allocator, tag);
        try self.unit_stack.append(self.allocator, meta);
        try self.string_hint_stack.append(self.allocator, null);
    }

    /// Finalize `unit_runtime` from emit-accurate flags (call before ABI emit).
    fn finalizeUnitRuntime(self: *WasmCompiler) void {
        if (self.emitted_dynamic_unit_op) {
            self.unit_runtime = .host_dynamic;
        } else if (self.saw_static_unit or self.result_unit != null) {
            self.unit_runtime = .static;
        } else {
            self.unit_runtime = .none;
        }
    }

    /// Reject unit-bearing matrix-literal elements (task-15/D6). Scans the top
    /// `n` type-stack slots without popping. Must run before heap allocation.
    fn rejectUnitBearingMatrixElements(self: *WasmCompiler, n: usize) !void {
        if (n == 0) return;
        const tlen = self.type_stack.items.len;
        if (tlen < n) return; // underflow handled by later pops
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = tlen - 1 - i;
            if (self.type_stack.items[idx] == .unit)
                return error.MatrixUnitElementUnsupported;
        }
    }

    fn popType(self: *WasmCompiler) mathzig.ValueTag {
        if (self.unit_stack.items.len > 0) _ = self.unit_stack.pop();
        if (self.string_hint_stack.items.len > 0) _ = self.string_hint_stack.pop();
        if (self.type_stack.items.len == 0) {
            if (@import("builtin").mode == .Debug) {
                std.debug.panic("WASM type_stack underflow", .{});
            }
            return .number;
        }
        return self.type_stack.pop() orelse .number;
    }

    fn popTypeAndUnit(self: *WasmCompiler) struct { tag: mathzig.ValueTag, unit: ?UnitMeta } {
        const u = if (self.unit_stack.items.len > 0) self.unit_stack.pop() else null;
        if (self.string_hint_stack.items.len > 0) _ = self.string_hint_stack.pop();
        const t = if (self.type_stack.items.len == 0) .number else self.type_stack.pop() orelse .number;
        return .{ .tag = t, .unit = u orelse null };
    }

    fn popTypeAndStringHint(self: *WasmCompiler) struct { tag: mathzig.ValueTag, str: ?[]const u8 } {
        if (self.unit_stack.items.len > 0) _ = self.unit_stack.pop();
        const s = if (self.string_hint_stack.items.len > 0) self.string_hint_stack.pop() else null;
        const t = if (self.type_stack.items.len == 0) .number else self.type_stack.pop() orelse .number;
        return .{ .tag = t, .str = s orelse null };
    }

    fn peekType(self: *WasmCompiler) mathzig.ValueTag {
        if (self.type_stack.items.len == 0) return .number;
        return self.type_stack.items[self.type_stack.items.len - 1];
    }

    /// Emit conversion (source_si - offset) / scale for a known target unit.
    /// Stack top is target (dropped), below is source SI magnitude.
    fn emitUnitConversion(self: *WasmCompiler, writer: anytype, target: UnitMeta) !void {
        _ = self;
        // drop target unit magnitude
        try writer.writeByte(@intFromEnum(types.Op.drop));
        if (target.offset != 0.0) {
            try writer.writeByte(@intFromEnum(types.Op.f64_const));
            try writer.writeAll(std.mem.asBytes(&target.offset));
            try writer.writeByte(@intFromEnum(types.Op.f64_sub));
        }
        const scale = target.scale;
        if (scale != 1.0) {
            try writer.writeByte(@intFromEnum(types.Op.f64_const));
            try writer.writeAll(std.mem.asBytes(&scale));
            try writer.writeByte(@intFromEnum(types.Op.f64_div));
        }
    }

    /// Elementwise SI → target unit conversion for a matrix pointer on the
    /// stack (as f64). Drops the target unit magnitude, then broadcasts
    /// (x - offset) / scale over matrix elements. Result pushed as matrix.
    fn emitMatrixUnitConversion(
        self: *WasmCompiler,
        writer: anytype,
        target: UnitMeta,
        scratch_f1: u32,
        scratch_i1: u32,
        scratch_i2: u32,
        scratch_i3: u32,
        scratch_i4: u32,
        scratch_i5: u32,
    ) !void {
        // Stack: [matrix_f64, target_si] → drop target
        try writer.writeByte(@intFromEnum(types.Op.drop));
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, scratch_i2); // matrix ptr

        var mat_local: u32 = scratch_i2;
        if (target.offset != 0.0) {
            try writer.writeByte(@intFromEnum(types.Op.f64_const));
            try writer.writeAll(std.mem.asBytes(&target.offset));
            try writer.writeByte(@intFromEnum(types.Op.local_set));
            _ = try leb.encodeUnsigned(writer, scratch_f1);
            try self.emitMatrixScalarBroadcastOp(
                writer,
                mat_local,
                scratch_f1,
                scratch_i1,
                scratch_i4,
                scratch_i5,
                scratch_i3,
                .f64_sub,
                false,
            );
            mat_local = scratch_i1;
        }
        if (target.scale != 1.0) {
            try writer.writeByte(@intFromEnum(types.Op.f64_const));
            try writer.writeAll(std.mem.asBytes(&target.scale));
            try writer.writeByte(@intFromEnum(types.Op.local_set));
            _ = try leb.encodeUnsigned(writer, scratch_f1);
            try self.emitMatrixScalarBroadcastOp(
                writer,
                mat_local,
                scratch_f1,
                scratch_i1,
                scratch_i4,
                scratch_i5,
                scratch_i3,
                .f64_div,
                false,
            );
            mat_local = scratch_i1;
        }
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, mat_local);
        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
    }

    fn emitBoolFromF64NonZero(writer: anytype) !void {
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
        try writer.writeByte(@intFromEnum(types.Op.f64_ne));
    }

    fn emitBoolFromF64IsZero(writer: anytype) !void {
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
        try writer.writeByte(@intFromEnum(types.Op.f64_eq));
    }

    fn emitHeapAllocChecked(
        self: *WasmCompiler,
        writer: anytype,
        alloc_size_local: u32,
        out_ptr_local: u32,
        new_end_local: u32,
        curr_mem_bytes_local: u32,
    ) !void {
        // out_ptr = heap_ptr; new_end = out_ptr + align8(alloc_size)
        try writer.writeByte(@intFromEnum(types.Op.global_get));
        _ = try leb.encodeUnsigned(writer, self.heap_ptr_idx);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, alloc_size_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 7);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, -8);
        try writer.writeByte(@intFromEnum(types.Op.i32_and));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, new_end_local);

        // curr_mem_bytes = memory.size(0) << 16
        try writer.writeByte(@intFromEnum(types.Op.memory_size));
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 16);
        try writer.writeByte(@intFromEnum(types.Op.i32_shl));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, curr_mem_bytes_local);

        // Grow memory if new_end exceeds current bytes.
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, new_end_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, curr_mem_bytes_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_gt_u));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, new_end_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, curr_mem_bytes_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_sub));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 65535);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 16);
        try writer.writeByte(@intFromEnum(types.Op.i32_shr_u));
        try writer.writeByte(@intFromEnum(types.Op.memory_grow));
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, -1);
        try writer.writeByte(@intFromEnum(types.Op.i32_eq));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        // Allocation failure: trap hard rather than silently returning NaN.
        try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.end));

        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, new_end_local);
        try writer.writeByte(@intFromEnum(types.Op.global_set));
        _ = try leb.encodeUnsigned(writer, self.heap_ptr_idx);
    }

    fn emitHeapAllocConstChecked(
        self: *WasmCompiler,
        writer: anytype,
        alloc_size: i32,
        size_local: u32,
        out_ptr_local: u32,
        new_end_local: u32,
        curr_mem_bytes_local: u32,
    ) !void {
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, alloc_size);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, size_local);
        try self.emitHeapAllocChecked(writer, size_local, out_ptr_local, new_end_local, curr_mem_bytes_local);
    }

    fn emitMatrixScalarBroadcastOp(
        self: *WasmCompiler,
        writer: anytype,
        matrix_ptr_local: u32,
        scalar_local: u32,
        result_ptr_local: u32,
        loop_idx_local: u32,
        elem_count_local: u32,
        alloc_size_local: u32,
        wasm_op: types.Op,
        scalar_lhs: bool,
    ) !void {
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, matrix_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, matrix_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x04);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.local_tee));
        _ = try leb.encodeUnsigned(writer, elem_count_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, alloc_size_local);
        try self.emitHeapAllocChecked(writer, alloc_size_local, result_ptr_local, alloc_size_local, elem_count_local);

        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, matrix_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, matrix_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x04);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, elem_count_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, result_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, matrix_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.i64_load));
        try writer.writeByte(0x03);
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.i64_store));
        try writer.writeByte(0x03);
        try writer.writeByte(0x00);

        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, loop_idx_local);
        try writer.writeByte(@intFromEnum(types.Op.loop));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, loop_idx_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, elem_count_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));

        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, result_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, loop_idx_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        if (scalar_lhs) {
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, scalar_local);
        }
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, matrix_ptr_local);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, loop_idx_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.f64_load));
        try writer.writeByte(0x03);
        try writer.writeByte(0x08);
        if (!scalar_lhs) {
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, scalar_local);
        }
        try writer.writeByte(@intFromEnum(wasm_op));
        try writer.writeByte(@intFromEnum(types.Op.f64_store));
        try writer.writeByte(0x03);
        try writer.writeByte(0x08);

        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, loop_idx_local);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, loop_idx_local);
        try writer.writeByte(@intFromEnum(types.Op.br));
        _ = try leb.encodeUnsigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.end));
    }

    fn compileInstruction(
        self: *WasmCompiler,
        writer: anytype,
        inst: Instruction,
        expr: *const CompiledExpr,
        var_map: *const std.AutoHashMap(u8, u32),
        string_map: *const std.AutoHashMap(usize, u32),
        num_params: u32,
        param_offset: u32,
        scratch_f1: u32,
        scratch_f2: u32,
        scratch_f3: u32,
        scratch_i1: u32,
        scratch_i2: u32,
        scratch_i3: u32,
        scratch_i4: u32,
        scratch_i5: u32,
        scratch_i64: u32,
    ) !void {
        @setEvalBranchQuota(5000);
        _ = num_params;
        // std.debug.print("Compiling opcode: {s}\n", .{@tagName(inst.opcode)});
        switch (inst.opcode) {
            .push_const => {
                const val = expr.constants[inst.operand];
                if (val.tag == .number) {
                    // Clear empty kind so a prior miss cannot relabel math NaN / numbers.
                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&val.data.number));
                    try self.pushType(.number);
                } else if (val.tag == .boolean) {
                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    const num: f64 = if (val.data.boolean) 1.0 else 0.0;
                    try writer.writeAll(std.mem.asBytes(&num));
                    try self.pushType(.boolean);
                } else if (val.tag == .unit) {
                    // SI-normalized magnitude on the wire; dimensions tracked
                    // on unit_stack for static fold / custom-section annotation.
                    // No silent stripping: type stays .unit with metadata.
                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&val.data.unit.value));
                    try self.pushUnitType(UnitMeta.fromUnitValue(val.data.unit));
                } else if (val.tag == .complex) {
                    // Pre-materialized in compileUnits (before the heap base
                    // froze); ensureComplexData only dedup-hits here.
                    const offset = try self.ensureComplexData(val.data.complex.re, val.data.complex.im);

                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    const ptr_val: f64 = @floatFromInt(offset);
                    try writer.writeAll(std.mem.asBytes(&ptr_val));
                    try self.pushType(.complex);
                } else if (val.tag == .string) {
                    // String constants are pre-added to data section; push offset as f64
                    const off = string_map.get(inst.operand) orelse return error.StringConstantMissing;
                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    const ptr_val: f64 = @floatFromInt(off);
                    try writer.writeAll(std.mem.asBytes(&ptr_val));
                    try self.pushStringType(val.data.string.toSlice());
                } else if (val.tag == .predicate) {
                    const off = try self.addPredicateData(val.data.predicate);
                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    const ptr_val: f64 = @floatFromInt(off);
                    try writer.writeAll(std.mem.asBytes(&ptr_val));
                    try self.pushType(.predicate);
                } else if (val.tag == .null_val) {
                    // Null → quiet NaN payload, typed as null_val (not number).
                    // Slice omitted bounds use this encoding; resolve treats NaN as default.
                    // Kind side-channel is not set here: intermediate nulls must not
                    // contaminate a later math-NaN result. Pure-null expr result_tag
                    // is still .null_val for the host via the ABI custom section.
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&std.math.nan(f64)));
                    try self.pushType(.null_val);
                } else {
                    return error.UnsupportedType;
                }
            },
            .load_var => {
                const v_idx: u8 = @intCast(inst.operand);
                // Outer captures (below param_offset) always load as folded constants.
                if (param_offset > 0 and v_idx < param_offset) {
                    const val = self.globals.get(v_idx) orelse return error.UnknownVariable;
                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&val));
                    try self.pushType(.number);
                } else if (var_map.get(v_idx)) |local_idx| {
                    // Locals may hold prior miss NaN payloads; clear kind only when
                    // the static type is a non-empty tag. Runtime miss stored in a
                    // local and reloaded still needs host-side residual note.
                    const t = self.var_types.get(v_idx) orelse .number;
                    if (t != .undefined and t != .null_val) {
                        try self.emitSetResultKind(writer, .number);
                    }
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, local_idx);
                    try self.pushType(t);
                } else if (self.globals.get(v_idx)) |val| {
                    // Seeded globals include math `nan` — must not inherit miss kind.
                    try self.emitSetResultKind(writer, .number);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&val));
                    try self.pushType(.number);
                } else {
                    return error.UnknownVariable;
                }
            },
            .load_var_index_0,
            .load_var_index_1,
            .load_var_index_2,
            .load_var_index_3,
            .load_var_index_const,
            => {
                const var_idx: u16 = @truncate(inst.operand & 0x0FFF);
                const local_idx = var_map.get(@intCast(var_idx)) orelse return error.UnknownVariable;
                var index_val: f64 = 0;
                if (inst.opcode == .load_var_index_const) {
                    const const_idx: u16 = @truncate((inst.operand >> 12) & 0x0FFF);
                    index_val = expr.constants[const_idx].data.number;
                } else {
                    switch (inst.opcode) {
                        .load_var_index_0 => index_val = 0,
                        .load_var_index_1 => index_val = 1,
                        .load_var_index_2 => index_val = 2,
                        .load_var_index_3 => index_val = 3,
                        else => {},
                    }
                }
                // NOTE: no runtime bounds check here (speed/size tradeoff):
                // a fused constant index past the matrix length reads adjacent
                // heap silently, where the VM raises IndexOutOfBounds.
                const index_elem: i32 = @intFromFloat(index_val);
                const load_offset: u32 = @intCast(8 + index_elem * 8);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, local_idx);
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                _ = try leb.encodeUnsigned(writer, load_offset);
                try self.pushType(.number);
            },
            .load_mul => {
                const var_a: u16 = @truncate(inst.operand & 0x0FFF);
                const var_b: u16 = @truncate((inst.operand >> 12) & 0x0FFF);
                const idx_a = var_map.get(@intCast(var_a)) orelse return error.UnknownVariable;
                const idx_b = var_map.get(@intCast(var_b)) orelse return error.UnknownVariable;
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, idx_a);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, idx_b);
                try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                try self.pushType(.number);
            },
            .load_sub => {
                const var_a: u16 = @truncate(inst.operand & 0x0FFF);
                const var_b: u16 = @truncate((inst.operand >> 12) & 0x0FFF);
                const idx_a = var_map.get(@intCast(var_a)) orelse return error.UnknownVariable;
                const idx_b = var_map.get(@intCast(var_b)) orelse return error.UnknownVariable;
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, idx_a);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, idx_b);
                try writer.writeByte(@intFromEnum(types.Op.f64_sub));
                try self.pushType(.number);
            },
            .const_mul => {
                // Multiply TOS by a numeric constant. Matrix wire → elementwise
                // scale (Spec 07 / full-value); scalar keeps f64_mul.
                const s = self.popTypeAndUnit();
                const c = expr.constants[inst.operand].data.number;
                if (s.tag == .matrix) {
                    // Stack: matrix_f64. Store const scalar, convert ptr, broadcast mul.
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&c));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try self.emitMatrixScalarBroadcastOp(
                        writer,
                        scratch_i2,
                        scratch_f1,
                        scratch_i1,
                        scratch_i4,
                        scratch_i5,
                        scratch_i3,
                        .f64_mul,
                        false,
                    );
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (s.tag == .complex) {
                    // complex * scalar: new { re*c, im*c }
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // src ptr
                    try self.emitHeapAllocConstChecked(writer, 16, scratch_i4, scratch_i3, scratch_i5, scratch_i4);
                    // re
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&c));
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);
                    // im
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&c));
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.complex);
                } else {
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&c));
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                    try self.pushTypeWithUnit(if (s.unit != null) .unit else s.tag, s.unit);
                }
            },
            .store_var => {
                const v_idx: u8 = @intCast(inst.operand);
                const idx = var_map.get(v_idx) orelse return error.UnknownVariable;
                const t = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, idx);
                try self.var_types.put(self.allocator, v_idx, t);
            },
            .call_builtin => {
                const builtin: BuiltinFn = @enumFromInt(@as(u16, @truncate(inst.operand)));
                const arg_count: u8 = @truncate((inst.operand >> 16) & 0xFF);
                var single_arg_type: ?mathzig.ValueTag = null;
                var both_args_number = false;
                var arg0_unit: ?UnitMeta = null;
                var arg1_unit: ?UnitMeta = null;
                var arg0_tag: mathzig.ValueTag = .number;
                var ode_name_hint: ?[]const u8 = null;
                if (arg_count == 1) {
                    const s = self.popTypeAndUnit();
                    single_arg_type = s.tag;
                    arg0_unit = s.unit;
                    arg0_tag = s.tag;
                } else if (arg_count == 2) {
                    // Stack top is arg1, below is arg0.
                    const a1 = self.popTypeAndUnit();
                    const a0 = self.popTypeAndUnit();
                    both_args_number = a0.tag == .number and a1.tag == .number;
                    arg0_unit = a0.unit;
                    arg1_unit = a1.unit;
                    arg0_tag = a0.tag;
                } else if ((builtin == .ode_solve or builtin == .ode_solve_euler) and arg_count >= 4) {
                    // Pop dt, tspan, y0, name (top to bottom); capture static name string.
                    _ = self.popType(); // dt
                    _ = self.popType(); // tspan
                    _ = self.popType(); // y0
                    const name_slot = self.popTypeAndStringHint();
                    ode_name_hint = name_slot.str;
                    // Remaining args if any
                    for (4..arg_count) |_| _ = self.popType();
                } else {
                    // Pop argument types
                    for (0..arg_count) |_| _ = self.popType();
                }
                var result_tag: mathzig.ValueTag = .number;

                // Static unit conversion fold: scalar unit/number, and matrix
                // of SI magnitudes (numeric mat_create / homogeneous matrix*unit;
                // unit-bearing literals rejected earlier). Series/complex remain
                // delegated.
                if ((builtin == .conv or builtin == .number) and arg_count == 2) {
                    const source_is_scalar_unit = arg0_tag == .unit or arg0_tag == .number;
                    if (source_is_scalar_unit) {
                        if (arg1_unit) |target| {
                            if (arg0_unit) |source| {
                                if (!source.dims.equals(target.dims)) return error.UnitDimensionMismatch;
                                self.saw_static_unit = true;
                                try self.emitUnitConversion(writer, target);
                                try self.pushType(.number);
                                return; // folded — do not emit env.conv/number
                            }
                        }
                    }
                    // Matrix of SI magnitudes → elementwise convert to target unit.
                    if (arg0_tag == .matrix) {
                        if (arg1_unit) |target| {
                            self.saw_static_unit = true;
                            try self.emitMatrixUnitConversion(
                                writer,
                                target,
                                scratch_f1,
                                scratch_i1,
                                scratch_i2,
                                scratch_i3,
                                scratch_i4,
                                scratch_i5,
                            );
                            try self.pushType(.matrix);
                            return;
                        }
                    }
                    // Dynamic path: require an import when unit meta would
                    // otherwise be stripped silently.
                    if (arg0_unit != null and self.builtin_map.get(builtin) == null) {
                        return error.UnitOpNotResolvable;
                    }
                    // Non-folded conv/number will emit env import below → host_dynamic.
                    if (builtin == .conv or builtin == .number) {
                        self.emitted_dynamic_unit_op = true;
                    }
                }

                switch (builtin) {
                    .sqrt => {
                        if (arg_count == 1) {
                            try writer.writeByte(@intFromEnum(types.Op.f64_sqrt));
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.call));
                            _ = try leb.encodeUnsigned(writer, self.builtin_map.get(builtin).?);
                        }
                    },
                    .abs => {
                        if (single_arg_type == .complex) {
                            // Stack: [ptr_f64]
                            try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                            try writer.writeByte(@intFromEnum(types.Op.local_set));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_load));
                            try writer.writeByte(0x03);
                            try writer.writeByte(0x00);
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_load));
                            try writer.writeByte(0x03);
                            try writer.writeByte(0x00);
                            try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // re^2
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_load));
                            try writer.writeByte(0x03);
                            try writer.writeByte(0x08);
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_load));
                            try writer.writeByte(0x03);
                            try writer.writeByte(0x08);
                            try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // im^2
                            try writer.writeByte(@intFromEnum(types.Op.f64_add));
                            try writer.writeByte(@intFromEnum(types.Op.f64_sqrt));
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.f64_abs));
                        }
                    },
                    .floor => try writer.writeByte(@intFromEnum(types.Op.f64_floor)),
                    .ceil => try writer.writeByte(@intFromEnum(types.Op.f64_ceil)),
                    .round => {
                        // Match Zig `@round` / VM: half away from zero.
                        // WASM `f64.nearest` is ties-to-even (banker's), which
                        // disagrees on 0.5 → 0 vs 1.
                        // 1-arg: copysign(floor(abs(x) + 0.5), x)
                        // 2-arg round(x, decimals): use helper/import if registered;
                        // otherwise fail loudly (parity with unsupported multi-arg).
                        if (arg_count >= 2) {
                            if (self.builtin_map.get(builtin)) |idx| {
                                try writer.writeByte(@intFromEnum(types.Op.call));
                                _ = try leb.encodeUnsigned(writer, idx);
                            } else {
                                return error.UnsupportedOpcode;
                            }
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.local_tee));
                            _ = try leb.encodeUnsigned(writer, scratch_f1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_abs));
                            try writer.writeByte(@intFromEnum(types.Op.f64_const));
                            const half: f64 = 0.5;
                            try writer.writeAll(std.mem.asBytes(&half));
                            try writer.writeByte(@intFromEnum(types.Op.f64_add));
                            try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_f1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_copysign));
                        }
                    },
                    .trunc => try writer.writeByte(@intFromEnum(types.Op.f64_trunc)),
                    .min => {
                        if (arg_count == 2 and both_args_number) {
                            try writer.writeByte(@intFromEnum(types.Op.f64_min));
                        } else if (single_arg_type == .number) {
                            // pass-through for scalar min(x)
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.call));
                            _ = try leb.encodeUnsigned(writer, self.builtin_map.get(builtin).?);
                        }
                    },
                    .max => {
                        if (arg_count == 2 and both_args_number) {
                            try writer.writeByte(@intFromEnum(types.Op.f64_max));
                        } else if (single_arg_type == .number) {
                            // pass-through for scalar max(x)
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.call));
                            _ = try leb.encodeUnsigned(writer, self.builtin_map.get(builtin).?);
                        }
                    },
                    .ode_solve, .ode_solve_euler => {
                        // Standalone: specialized body with direct call to static deriv.
                        const idx: u32 = blk: {
                            if (self.standalone) {
                                if (ode_name_hint) |name| {
                                    if (self.user_fn_name_map.get(name)) |deriv_idx| {
                                        const is_euler = builtin == .ode_solve_euler;
                                        const key = self.odeHelperKey(is_euler, deriv_idx);
                                        if (self.ode_helper_map.get(key)) |h| break :blk h;
                                    }
                                }
                                // Fall back to default specialization if registered.
                                if (self.builtin_map.get(builtin)) |h| break :blk h;
                                return error.StandaloneUnsupportedImport;
                            }
                            break :blk self.builtin_map.get(builtin) orelse return error.UnknownFunction;
                        };
                        try writer.writeByte(@intFromEnum(types.Op.call));
                        _ = try leb.encodeUnsigned(writer, idx);
                        result_tag = .matrix;
                    },
                    .series,
                    .twa,
                    .resample,
                    .align_,
                    .asofJoin,
                    .rolling_sum,
                    .rolling_mean,
                    .rolling_min,
                    .rolling_max,
                    .rolling_count,
                    .rolling_stddev,
                    .rsi,
                    .last,
                    .duration,
                    .head,
                    .tail,
                    .slice,
                    .dropna,
                    .fillna,
                    .cumsum,
                    .diff,
                    .sma,
                    .sum,
                    .mean,
                    .count,
                    .size,
                    .transpose,
                    .reshape,
                    .flatten,
                    .concat,
                    .gen_range,
                    .linspace,
                    .logspace,
                    .diag,
                    .identity,
                    .zeros,
                    .ones,
                    .cross,
                    => {
                        // Dual-dispatch: series mean/sum/count/last use series helpers.
                        // count(matrix) is rejected by the VM — hard-error under -s.
                        if (self.standalone and builtin == .count and single_arg_type == .matrix) {
                            const msg = std.fmt.bufPrint(&self.standalone_error_buf, "standalone unsupported builtin 'count' on matrix (tier=matrix)", .{}) catch "standalone count(matrix) unsupported";
                            self.standalone_error_msg = msg;
                            return error.StandaloneUnsupportedImport;
                        }
                        const idx: u32 = blk: {
                            if (self.standalone and single_arg_type == .series) {
                                if (self.series_helper_map.get(builtin)) |h| break :blk h;
                            }
                            if (self.standalone and (builtin == .series or builtin == .cumsum or
                                builtin == .diff or builtin == .head or builtin == .tail or
                                builtin == .sma or builtin == .rolling_mean))
                            {
                                if (self.builtin_map.get(builtin)) |h| break :blk h;
                            }
                            break :blk self.builtin_map.get(builtin) orelse return error.UnknownFunction;
                        };
                        try writer.writeByte(@intFromEnum(types.Op.call));
                        _ = try leb.encodeUnsigned(writer, idx);
                        switch (builtin) {
                            .series, .resample, .align_, .asofJoin, .rolling_sum, .rolling_mean, .rolling_min, .rolling_max, .rolling_count, .rolling_stddev, .rsi, .dropna, .fillna, .head, .tail, .slice, .cumsum, .diff, .sma => result_tag = .series,
                            .transpose, .reshape, .flatten, .concat, .gen_range, .linspace, .logspace, .diag, .identity, .zeros, .ones, .cross => result_tag = .matrix,
                            .size => result_tag = .record,
                            .last => {
                                if (single_arg_type == .matrix) result_tag = .matrix;
                            },
                            else => result_tag = .number,
                        }
                    },
                    .toLaTeX => {
                        try writer.writeByte(@intFromEnum(types.Op.call));
                        _ = try leb.encodeUnsigned(writer, self.builtin_map.get(builtin).?);
                        result_tag = .string;
                    },
                    .read_csv => {
                        try writer.writeByte(@intFromEnum(types.Op.call));
                        _ = try leb.encodeUnsigned(writer, self.builtin_map.get(builtin).?);
                        // path-only -> one series; with a column-mapping
                        // record -> record of series
                        result_tag = if (arg_count >= 2) .record else .series;
                    },
                    else => {
                        try writer.writeByte(@intFromEnum(types.Op.call));
                        _ = try leb.encodeUnsigned(writer, self.builtin_map.get(builtin).?);
                        // Type the import's result from the ABI table so the
                        // manifest's result_tag (and downstream decode) is
                        // right for complex/record/etc. returning builtins.
                        result_tag = switch (abi.signature(builtin).ret) {
                            .complex_ptr => .complex,
                            .record_ptr => .record,
                            .matrix_ptr => .matrix,
                            .series_handle => .series,
                            .string_ptr => .string,
                            else => .number,
                        };
                    },
                }
                try self.pushType(result_tag);
            },
            .call_builtin_where => {
                const builtin: BuiltinFn = @enumFromInt(@as(u16, @truncate(inst.operand)));
                const arg_count: u8 = @truncate((inst.operand >> 16) & 0xFF);
                _ = self.popType(); // predicate payload
                var single_arg_type_where: ?mathzig.ValueTag = null;
                if (arg_count == 1) {
                    single_arg_type_where = self.popType();
                } else {
                    for (0..arg_count) |_| _ = self.popType();
                }

                try writer.writeByte(@intFromEnum(types.Op.call));
                _ = try leb.encodeUnsigned(writer, self.builtin_where_map.get(builtin) orelse return error.UnknownFunction);

                var result_tag: mathzig.ValueTag = .number;
                switch (builtin) {
                    .series, .resample, .align_, .asofJoin, .rolling_sum, .rolling_mean, .rolling_min, .rolling_max, .rolling_count, .rolling_stddev, .rsi, .dropna, .fillna, .head, .tail, .slice => result_tag = .series,
                    .last => {
                        if (single_arg_type_where == .matrix) result_tag = .matrix;
                    },
                    else => result_tag = .number,
                }
                try self.pushType(result_tag);
            },
            .call_user => {
                // Decode: bits 0-14=func_id, bit 15=is_local, bits 16-23=arg_count
                const func_id: u16 = @truncate(inst.operand & 0x7FFF);
                const is_local: bool = (inst.operand & 0x8000) != 0;
                const arg_count: u8 = @truncate((inst.operand >> 16) & 0xFF);

                // Pop argument types from type stack
                for (0..arg_count) |_| _ = self.popType();

                var result_tag: mathzig.ValueTag = .number;
                if (self.local_funcs.get(expr)) |scope_list| {
                    const base = self.scope_base.get(expr) orelse 0;
                    const base_u32: u32 = @intCast(base);
                    const id_u32: u32 = @intCast(func_id);
                    const target_idx: u32 = if (is_local) base_u32 + id_u32 else id_u32;
                    if (target_idx < scope_list.items.len) {
                        const child_expr = scope_list.items[@intCast(target_idx)];
                        const expected_args = self.user_function_params.get(child_expr) orelse return error.UserFunctionMissing;
                        if (arg_count != expected_args) return error.WrongArgumentCount;
                        if (self.user_function_map.get(child_expr)) |wasm_idx| {
                            try writer.writeByte(@intFromEnum(types.Op.call));
                            _ = try leb.encodeUnsigned(writer, wasm_idx);
                        } else return error.UserFunctionMissing;
                        // A callee returning a matrix/complex/record wires a
                        // pointer, not a scalar — typing it .number here made
                        // downstream ops treat the pointer as an f64.
                        result_tag = self.fn_result_tags.get(child_expr) orelse .number;
                    } else return error.UserFunctionMissing;
                } else return error.UserFunctionMissing;

                try self.pushType(result_tag);
            },
            .add => {
                const r = self.popTypeAndUnit();
                const l = self.popTypeAndUnit();
                const t2 = r.tag;
                const t1 = l.tag;
                if (t1 == .matrix and t2 == .matrix) {
                    // Element-wise matrix addition
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.local_tee));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try self.emitHeapAllocChecked(writer, scratch_i4, scratch_i1, scratch_i4, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.i64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 0);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.loop));
                    try writer.writeByte(@intFromEnum(types.ValType.void));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.void));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.f64_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.br));
                    _ = try leb.encodeUnsigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t1 == .matrix and t2 != .matrix and t2 != .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // scalar rhs
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // matrix lhs
                    try self.emitMatrixScalarBroadcastOp(writer, scratch_i2, scratch_f1, scratch_i1, scratch_i4, scratch_i5, scratch_i3, .f64_add, false);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t2 == .matrix and t1 != .matrix and t1 != .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // matrix rhs
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // scalar lhs
                    try self.emitMatrixScalarBroadcastOp(writer, scratch_i2, scratch_f1, scratch_i1, scratch_i4, scratch_i5, scratch_i3, .f64_add, false);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t1 == .complex or t2 == .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // rhs
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // lhs
                    try self.emitHeapAllocConstChecked(writer, 16, scratch_i4, scratch_i3, scratch_i5, scratch_i4);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.f64_const));
                        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.f64_const));
                        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.complex);
                } else {
                    // Scalar / unit: SI magnitudes add; dimensions must match.
                    const meta = try combineUnitAdd(l.unit, r.unit);
                    try writer.writeByte(@intFromEnum(types.Op.f64_add));
                    if (meta) |m|
                        try self.pushUnitType(m)
                    else
                        try self.pushType(.number);
                }
            },
            .sub => {
                const r = self.popTypeAndUnit();
                const l = self.popTypeAndUnit();
                const t2 = r.tag;
                const t1 = l.tag;
                if (t1 == .matrix and t2 == .matrix) {
                    // Element-wise matrix subtraction
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.local_tee));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try self.emitHeapAllocChecked(writer, scratch_i4, scratch_i1, scratch_i4, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.i64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 0);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.loop));
                    try writer.writeByte(@intFromEnum(types.ValType.void));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.void));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.f64_sub));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.br));
                    _ = try leb.encodeUnsigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t1 == .complex or t2 == .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try self.emitHeapAllocConstChecked(writer, 16, scratch_i4, scratch_i3, scratch_i5, scratch_i4);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_sub));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.f64_const));
                        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.f64_const));
                        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_sub));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.complex);
                } else {
                    const meta = try combineUnitAdd(l.unit, r.unit);
                    try writer.writeByte(@intFromEnum(types.Op.f64_sub));
                    if (meta) |m|
                        try self.pushUnitType(m)
                    else
                        try self.pushType(.number);
                }
            },
            .mul => {
                const r = self.popTypeAndUnit();
                const l = self.popTypeAndUnit();
                const t2 = r.tag;
                const t1 = l.tag;
                if (t1 == .matrix and t2 == .matrix) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // B
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // A

                    // Result: rows = A.rows, cols = B.cols
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3); // rows_c
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4); // cols_c

                    // Allocate C: rows * cols * 8 + 8
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try self.emitHeapAllocChecked(writer, scratch_i5, scratch_i3, scratch_i4, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);

                    // Reload rows_c/cols_c after allocator scratch usage.
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3); // rows_c
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i4); // cols_c

                    // Set metadata for C
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_store));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_store));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);

                    // Call mathzig_gemm(rows_a, cols_a, cols_b, A_data, stride_a, B_data, stride_b, C_data, stride_c)
                    // rows_a
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    // cols_a
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    // cols_b
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    // A_data
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    // stride_a (cols_a)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    // B_data
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    // stride_b (cols_b)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    // C_data
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    // stride_c (cols_c)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);

                    // The gemm import must have been pre-registered by the
                    // discovery heuristic — importing here, mid-codegen, would
                    // shift every already-emitted function index (silent
                    // miscompilation). Fail loudly instead so the heuristic
                    // gets widened rather than the module corrupted.
                    if (self.gemm_import_idx == null) return error.GemmImportNotPreRegistered;
                    try writer.writeByte(@intFromEnum(types.Op.call));
                    _ = try leb.encodeUnsigned(writer, self.gemm_import_idx.?);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t1 == .matrix and t2 != .matrix and t2 != .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // scalar rhs
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // matrix lhs
                    try self.emitMatrixScalarBroadcastOp(writer, scratch_i2, scratch_f1, scratch_i1, scratch_i4, scratch_i5, scratch_i3, .f64_mul, false);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t2 == .matrix and t1 != .matrix and t1 != .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // matrix rhs
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // scalar lhs
                    try self.emitMatrixScalarBroadcastOp(writer, scratch_i2, scratch_f1, scratch_i1, scratch_i4, scratch_i5, scratch_i3, .f64_mul, false);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t1 == .complex or t2 == .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try self.emitHeapAllocConstChecked(writer, 16, scratch_i4, scratch_i3, scratch_i5, scratch_i4);

                    // Real part: (a*c - b*d)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul));

                    if (t1 == .complex and t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                        try writer.writeByte(@intFromEnum(types.Op.f64_sub));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);

                    // Imag part: (a*d + b*c)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00);
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                    } else {
                        // a * 0 = 0 (if t2 is number)
                        try writer.writeByte(@intFromEnum(types.Op.drop));
                        try writer.writeByte(@intFromEnum(types.Op.f64_const));
                        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    }

                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08);
                        if (t2 == .complex) {
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i2);
                            try writer.writeByte(@intFromEnum(types.Op.f64_load));
                            try writer.writeByte(0x03);
                            try writer.writeByte(0x00);
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i2);
                            try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                        }
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                        try writer.writeByte(@intFromEnum(types.Op.f64_add));
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.complex);
                } else {
                    // Scalar / unit mul: SI product; dimensions multiply.
                    const meta = combineUnitMul(l.unit, r.unit);
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                    if (meta) |m|
                        try self.pushUnitType(m)
                    else
                        try self.pushType(.number);
                }
            },
            .div => {
                const r = self.popTypeAndUnit();
                const l = self.popTypeAndUnit();
                const t2 = r.tag;
                const t1 = l.tag;
                if (t1 == .matrix and t2 != .matrix and t2 != .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // scalar rhs
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // matrix lhs
                    try self.emitMatrixScalarBroadcastOp(writer, scratch_i2, scratch_f1, scratch_i1, scratch_i4, scratch_i5, scratch_i3, .f64_div, false);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t2 == .matrix and t1 != .matrix and t1 != .complex) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // matrix rhs
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // scalar lhs
                    try self.emitMatrixScalarBroadcastOp(writer, scratch_i2, scratch_f1, scratch_i1, scratch_i4, scratch_i5, scratch_i3, .f64_div, true);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.matrix);
                } else if (t1 == .complex or t2 == .complex) {
                    // Complex division: (a+bi)/(c+di) = ((ac+bd) + (bc-ad)i) / (c^2+d^2)
                    // Preserve raw operands first (f64 payload: either scalar value or complex pointer-as-f64).
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // rhs
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // lhs

                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_f2);
                        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                        try writer.writeByte(@intFromEnum(types.Op.local_set));
                        _ = try leb.encodeUnsigned(writer, scratch_i1); // lhs complex ptr
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_f1);
                        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                        try writer.writeByte(@intFromEnum(types.Op.local_set));
                        _ = try leb.encodeUnsigned(writer, scratch_i2); // rhs complex ptr
                    }

                    // Allocate result complex (16 bytes)
                    try self.emitHeapAllocConstChecked(writer, 16, scratch_i4, scratch_i3, scratch_i5, scratch_i4);

                    // den = c^2 + d^2
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00); // c
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00); // c
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // c^2
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08); // d
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08); // d
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // d^2
                        try writer.writeByte(@intFromEnum(types.Op.f64_add)); // den
                    } else {
                        // denominator is real scalar: d=0 -> den=c^2
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_f1);
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_f1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // den
                    }
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // den

                    // Real = (a*c + b*d) / den
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00); // a
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_f2); // a
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00); // c
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_f1); // c
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // a*c
                    if (t1 == .complex and t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08); // b
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08); // d
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // b*d
                        try writer.writeByte(@intFromEnum(types.Op.f64_add)); // a*c + b*d
                    }
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // den
                    try writer.writeByte(@intFromEnum(types.Op.f64_div));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);

                    // Imag = (b*c - a*d) / den
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    if (t1 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i1);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08); // b
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.f64_const));
                        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0))); // b=0
                    }
                    if (t2 == .complex) {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x00); // c
                    } else {
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_f1); // c
                    }
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // b*c
                    if (t2 == .complex) {
                        if (t1 == .complex) {
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_i1);
                            try writer.writeByte(@intFromEnum(types.Op.f64_load));
                            try writer.writeByte(0x03);
                            try writer.writeByte(0x00); // a
                        } else {
                            try writer.writeByte(@intFromEnum(types.Op.local_get));
                            _ = try leb.encodeUnsigned(writer, scratch_f2); // a
                        }
                        try writer.writeByte(@intFromEnum(types.Op.local_get));
                        _ = try leb.encodeUnsigned(writer, scratch_i2);
                        try writer.writeByte(@intFromEnum(types.Op.f64_load));
                        try writer.writeByte(0x03);
                        try writer.writeByte(0x08); // d
                        try writer.writeByte(@intFromEnum(types.Op.f64_mul)); // a*d
                        try writer.writeByte(@intFromEnum(types.Op.f64_sub)); // b*c - a*d
                    }
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // den
                    try writer.writeByte(@intFromEnum(types.Op.f64_div));
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);

                    // Return complex ptr as f64 payload.
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try self.pushType(.complex);
                } else {
                    const meta = combineUnitDiv(l.unit, r.unit);
                    try writer.writeByte(@intFromEnum(types.Op.f64_div));
                    if (meta) |m|
                        try self.pushUnitType(m)
                    else
                        try self.pushType(.number);
                }
            },
            .neg => {
                const s = self.popTypeAndUnit();
                try writer.writeByte(@intFromEnum(types.Op.f64_neg));
                try self.pushTypeWithUnit(s.tag, s.unit);
            },
            .dup => {
                const t = self.peekType();
                const u = if (self.unit_stack.items.len > 0)
                    self.unit_stack.items[self.unit_stack.items.len - 1]
                else
                    null;
                try writer.writeByte(@intFromEnum(types.Op.local_tee));
                _ = try leb.encodeUnsigned(writer, scratch_f1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_f1);
                try self.pushTypeWithUnit(t, u);
            },
            .pow => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.call));
                _ = try leb.encodeUnsigned(writer, self.pow_func_idx.?);
                try self.pushType(.number);
            },
            .mod => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.call));
                _ = try leb.encodeUnsigned(writer, self.fmod_import_idx.?);
                try self.pushType(.number);
            },
            .eq => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .ne => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.f64_ne));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .lt => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.f64_lt));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .le => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.f64_le));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .gt => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.f64_gt));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .ge => {
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .mat_create => {
                const num = (inst.operand & 0xFFF) * ((inst.operand >> 12) & 0xFFF);
                // Reject unit-bearing elements before allocation (task-15/D6).
                try self.rejectUnitBearingMatrixElements(num);
                // Pop the types of all element values being consumed
                for (0..num) |_| {
                    _ = self.popType();
                }
                try self.emitHeapAllocConstChecked(
                    writer,
                    @as(i32, @intCast(num * 8 + 8)),
                    scratch_i4,
                    scratch_i1,
                    scratch_i5,
                    scratch_i3,
                );
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, @as(i32, @intCast(inst.operand & 0xFFF)));
                try writer.writeByte(@intFromEnum(types.Op.i32_store));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, @as(i32, @intCast((inst.operand >> 12) & 0xFFF)));
                try writer.writeByte(@intFromEnum(types.Op.i32_store));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                var i: i32 = @as(i32, @intCast(num)) - 1;
                while (i >= 0) : (i -= 1) {
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    _ = try leb.encodeUnsigned(writer, @as(u32, @intCast(8 + i * 8)));
                }
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                try self.pushType(.matrix);
            },
            .mat_create_3 => {
                const num: i32 = 3;
                const rows: i32 = 3;
                const cols: i32 = 1;
                // Same stable rejection as mat_create (fused 3×1 path).
                try self.rejectUnitBearingMatrixElements(3);
                for (0..num) |_| {
                    _ = self.popType();
                }
                try self.emitHeapAllocConstChecked(
                    writer,
                    @as(i32, @intCast(num * 8 + 8)),
                    scratch_i4,
                    scratch_i1,
                    scratch_i5,
                    scratch_i3,
                );
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, rows);
                try writer.writeByte(@intFromEnum(types.Op.i32_store));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, cols);
                try writer.writeByte(@intFromEnum(types.Op.i32_store));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                var i: i32 = num - 1;
                while (i >= 0) : (i -= 1) {
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    _ = try leb.encodeUnsigned(writer, @as(u32, @intCast(8 + i * 8)));
                }
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                try self.pushType(.matrix);
            },
            .get_index => {
                // Pop key/object tags from type stack for compile-time behavior gating.
                // Unsupported index shapes fail at compile time (no silent NaN sentinels).
                if (inst.operand == 0 or inst.operand > 2) return error.UnsupportedOpcode;

                var has_slice_key = false;
                var key_is_slice: [2]bool = .{ false, false };
                {
                    var ki: u32 = inst.operand;
                    while (ki > 0) {
                        ki -= 1;
                        const key_t = self.popType();
                        key_is_slice[ki] = (key_t == .slice);
                        if (key_t == .slice) has_slice_key = true;
                    }
                }
                const object_t = self.popType();

                if (object_t == .matrix and has_slice_key and inst.operand == 1) {
                    // Matrix single-key slice path (needed for range(...)[a:b]).
                    // Stack: [matrix_ptr, slice_ptr]
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // slice ptr (f64)
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // matrix ptr (f64)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3); // slice ptr
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // matrix ptr

                    // Only row-vector slice is implemented in AOT for this path.
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_gt_u));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.f64));
                    // Resolve [start,len) with the shared axis-range helper:
                    // signed trunc + negative wrap + clamps (VM parity). The
                    // old inline version used i32_trunc_f64_u, which trapped
                    // the whole module on a negative bound like v[-2:].
                    try self.emitResolveAxisRange(
                        writer,
                        true,
                        scratch_f1,
                        scratch_i1,
                        false,
                        scratch_i2,
                        scratch_i3,
                        scratch_i5,
                        scratch_i4,
                    ); // start=i2, len=i3, step=i4
                    // Preserve len + step across allocator scratch clobber.
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i64_extend_i32_s));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i64); // step in i64

                    // Allocate result [1 x len]
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i5); // alloc size
                    try self.emitHeapAllocChecked(writer, scratch_i5, scratch_i4, scratch_i5, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3); // restore len
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_store));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_store));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);

                    // Copy selected columns with stride: src = start + i*step
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 0);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.loop));
                    try writer.writeByte(@intFromEnum(types.ValType.void));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.void));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // start
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5); // i
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i64);
                    try writer.writeByte(@intFromEnum(types.Op.i32_wrap_i64)); // step
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i5);
                    try writer.writeByte(@intFromEnum(types.Op.br));
                    _ = try leb.encodeUnsigned(writer, 1);
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.end));

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i4);
                    try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    // Non-row-vector single-key slice is not implemented in AOT yet:
                    // trap rather than silently returning NaN.
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try self.pushType(.matrix);
                } else if (object_t == .matrix and has_slice_key and inst.operand == 2) {
                    // 2-key slice/mixed read: mat[row_spec, col_spec] → submatrix
                    // Stack: [mat, key0, key1]
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // key1
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // key0
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // mat

                    try self.emitMatrixSliceGet(
                        writer,
                        key_is_slice[0],
                        key_is_slice[1],
                        scratch_f1,
                        scratch_f2,
                        scratch_f3,
                        scratch_i1,
                        scratch_i2,
                        scratch_i3,
                        scratch_i4,
                        scratch_i5,
                        scratch_i64,
                    );
                    try self.pushType(.matrix);
                } else if (object_t != .matrix or has_slice_key) {
                    // Unsupported object type or remaining slice shapes.
                    return error.UnsupportedOpcode;
                } else if (inst.operand == 2) {
                    // 2D indexing: matrix[row, col]
                    // Stack: [matrix_ptr, row, col] where col is on top
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // col
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // row
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // ptr

                    // Negative indices wrap (VM parity) before validation.
                    try emitNegativeIndexWrap(writer, scratch_f2, scratch_f3, .rows);
                    try emitNegativeIndexWrap(writer, scratch_f1, scratch_f3, .cols);

                    // Strict integer and non-negative validation for ptr,row,col to avoid truncation-based coercion.
                    // valid_row = row == floor(row) && row >= 0 && row <= u32_max
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 4294967295.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_le));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));

                    // valid_col
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 4294967295.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_le));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));

                    // valid_ptr
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 4294967295.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_le));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));

                    // if valid numeric indices: convert + bounds check; else trap
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.f64));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // col
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // row
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // ptr
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);

                    // Bounds check: row < rows && col < cols (zero-based indexing)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));

                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.f64));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    // Out-of-bounds / invalid numeric index: trap (match VM hard error).
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try self.pushType(.number);
                } else if (inst.operand == 1) {
                    // 1D indexing: matrix[index] or array[index]
                    // Stack: [matrix_ptr, index] where index is on top
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // index
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // ptr

                    // Negative indices wrap by element count (VM parity).
                    try emitNegativeIndexWrap(writer, scratch_f1, scratch_f2, .total);

                    // valid_index = index == floor(index) && index >= 0 && index <= u32_max
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 4294967295.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_le));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));

                    // valid_ptr
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 4294967295.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_le));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));

                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.f64));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);

                    // Bounds check: index < rows * cols
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));

                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.f64));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.f64_load));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try self.pushType(.number);
                } else {
                    // Unreachable: operand already gated to 1..2 above.
                    return error.UnsupportedOpcode;
                }
            },
            .emul => {
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.local_tee));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try self.emitHeapAllocChecked(writer, scratch_i4, scratch_i1, scratch_i4, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 0);
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.loop));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                try writer.writeByte(@intFromEnum(types.Op.if_op));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                try writer.writeByte(@intFromEnum(types.Op.f64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                try self.pushType(.matrix);
            },
            .ediv => {
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.local_tee));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try self.emitHeapAllocChecked(writer, scratch_i4, scratch_i1, scratch_i4, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 0);
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.loop));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                try writer.writeByte(@intFromEnum(types.Op.if_op));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.f64_div));
                try writer.writeByte(@intFromEnum(types.Op.f64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                try self.pushType(.matrix);
            },
            .epow => {
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.local_tee));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try self.emitHeapAllocChecked(writer, scratch_i4, scratch_i1, scratch_i4, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x04);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 0);
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.loop));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i5);
                try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                try writer.writeByte(@intFromEnum(types.Op.if_op));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.call));
                _ = try leb.encodeUnsigned(writer, self.pow_func_idx.?);
                try writer.writeByte(@intFromEnum(types.Op.f64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                try self.pushType(.matrix);
            },
            .eval_poly => {
                // Operand encoding: bits 0-15 = var_index, bits 16-23 = count
                const var_idx: u16 = @truncate(inst.operand & 0xFFFF);
                const count: u8 = @truncate((inst.operand >> 16) & 0xFF);

                const idx = var_map.get(@intCast(var_idx)) orelse return error.UnknownVariable;
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, idx);
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_f1); // x

                // result = c0
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&expr.constants[0].data.number));

                var i: u32 = 1;
                while (i < count) : (i += 1) {
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&expr.constants[i].data.number));
                    try writer.writeByte(@intFromEnum(types.Op.f64_add));
                }
                try self.pushType(.number);
            },

            .fma => {
                // pop a, b, c -> push a * b + c
                // Stack: [a, b, c] where c is on top
                _ = self.popType();
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_f1); // c
                try writer.writeByte(0xA2); // f64.mul (pops b, a -> a*b)
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_f1); // c
                try writer.writeByte(0xA0); // f64.add (pops c, a*b -> a*b+c)
                try self.pushType(.number);
            },
            .fma_var_const_const => {
                const var_idx: u8 = @truncate(inst.operand);
                const c1_idx: u8 = @truncate(inst.operand >> 8);
                const c2_idx: u8 = @truncate(inst.operand >> 16);
                const v_idx = var_map.get(var_idx) orelse return error.UnknownVariable;
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, v_idx);
                const c1 = expr.constants[c1_idx].data.number;
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&c1));
                try writer.writeByte(0xA2); // f64.mul
                const c2 = expr.constants[c2_idx].data.number;
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&c2));
                try writer.writeByte(0xA0); // f64.add
                try self.pushType(.number);
            },
            .make_slice => {
                _ = self.popType(); // step
                _ = self.popType(); // end
                _ = self.popType(); // start
                // Stack: [start, end, step]
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_f1); // step
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_f2); // end
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_f3); // start

                try self.emitHeapAllocConstChecked(writer, 24, scratch_i4, scratch_i1, scratch_i5, scratch_i3);

                // Store start at ptr+0
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_f3);
                try writer.writeByte(@intFromEnum(types.Op.f64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);

                // Store end at ptr+8
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_f2);
                try writer.writeByte(@intFromEnum(types.Op.f64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x08);

                // Store step at ptr+16
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_f1);
                try writer.writeByte(@intFromEnum(types.Op.f64_store));
                try writer.writeByte(0x03);
                try writer.writeByte(0x10);

                // Return ptr
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                try self.pushType(.slice);
            },
            .rec_create => {
                const num = inst.operand;
                // Entry stack shape is [v0 k0 v1 k1 ...]; capture each value's
                // statically-inferred kind before popping — it is baked into
                // the entry's pad slot so hosts can type the fields.
                var entry_kinds = std.ArrayListUnmanaged(u8).empty;
                defer entry_kinds.deinit(self.allocator);
                {
                    const ts = self.type_stack.items;
                    const hints = self.string_hint_stack.items;
                    const base = ts.len -| (num * 2);
                    for (0..num) |ei| {
                        const idx = base + ei * 2;
                        const tag: mathzig.ValueTag = if (idx < ts.len) ts[idx] else .number;
                        // Remember the field's static tag (key hint sits above
                        // its value) so rec_get can type non-number fields.
                        if (idx + 1 < hints.len) {
                            if (hints[idx + 1]) |key| try self.record_field_tags.put(key, tag);
                        }
                        try entry_kinds.append(self.allocator, switch (tag) {
                            .matrix => 1,
                            .series => 2,
                            .complex => 3,
                            .string => 4,
                            .record => 5,
                            else => 0,
                        });
                    }
                }
                for (0..num * 2) |_| _ = self.popType();
                // Record layout (aligned):
                // [u32 len][u32 pad][entries...],
                // entry = [f64 value][u32 key_off][u8 value_kind + 3B pad]
                // size = 8 + num * 16
                const alloc_size = 8 + num * 16;
                try self.emitHeapAllocConstChecked(
                    writer,
                    @as(i32, @intCast(alloc_size)),
                    scratch_i4,
                    scratch_i1,
                    scratch_i5,
                    scratch_i3,
                );
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, @as(i32, @intCast(num)));
                try writer.writeByte(@intFromEnum(types.Op.i32_store));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                var i: i32 = @as(i32, @intCast(num)) - 1;
                while (i >= 0) : (i -= 1) {
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_store));
                    try writer.writeByte(0x02);
                    _ = try leb.encodeUnsigned(writer, @as(u32, @intCast(8 + i * 16 + 8)));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    _ = try leb.encodeUnsigned(writer, @as(u32, @intCast(8 + i * 16)));
                    // value kind byte in the entry's pad slot (+12)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, @as(i32, entry_kinds.items[@intCast(i)]));
                    try writer.writeByte(@intFromEnum(types.Op.i32_store8));
                    try writer.writeByte(0x00);
                    _ = try leb.encodeUnsigned(writer, @as(u32, @intCast(8 + i * 16 + 12)));
                }
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
                try self.pushType(.record);
            },
            .rec_get => {
                // Pop record from type stack
                _ = self.popType();
                // Static field tag recorded at the rec_create site (if any):
                // a matrix/series field wires a pointer, not a scalar.
                const field_key = expr.constants[inst.operand];
                const field_tag: mathzig.ValueTag = if (field_key.tag == .string)
                    self.record_field_tags.get(field_key.data.string.toSlice()) orelse .number
                else
                    .number;
                const off = string_map.get(@intCast(inst.operand)) orelse return error.StringConstantMissing;
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 0);
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.block));
                try writer.writeByte(@intFromEnum(types.ValType.f64));
                try writer.writeByte(@intFromEnum(types.Op.loop));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i32_ge_u));
                try writer.writeByte(@intFromEnum(types.Op.if_op));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                // Miss: VM returns undefined — NaN payload + kind side-channel.
                try self.emitSetResultKind(writer, .undefined);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&std.math.nan(f64)));
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 2);
                try writer.writeByte(@intFromEnum(types.Op.end));

                // entry_ptr = record_ptr + index * 16 + 8 (points to entry value)
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 16);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, @as(i32, @intCast(off)));
                try writer.writeByte(@intFromEnum(types.Op.i32_eq));
                try writer.writeByte(@intFromEnum(types.Op.if_op));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                // Hit: clear empty kind so a prior miss cannot leak.
                try self.emitSetResultKind(writer, .number);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 2);
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 0);
                try writer.writeByte(@intFromEnum(types.Op.end));
                // Fallthrough safety miss (loop ends without hit).
                try self.emitSetResultKind(writer, .undefined);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&std.math.nan(f64)));
                try writer.writeByte(@intFromEnum(types.Op.end));
                try self.pushType(field_tag);
            },
            .rec_get_dyn => {
                // Pop key and record from type stack; a static string key hint
                // lets us type the field like rec_get does.
                const key_slot = self.popTypeAndStringHint(); // key
                _ = self.popType(); // record
                const field_tag: mathzig.ValueTag = if (key_slot.str) |k|
                    self.record_field_tags.get(k) orelse .number
                else
                    .number;
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i2); // Key (off)
                try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i1); // Object
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 0);
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.block));
                try writer.writeByte(@intFromEnum(types.ValType.f64));
                try writer.writeByte(@intFromEnum(types.Op.loop));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.i32_ge_u));
                try writer.writeByte(@intFromEnum(types.Op.if_op));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                // Miss / series-OOB-as-miss: VM returns undefined.
                try self.emitSetResultKind(writer, .undefined);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&std.math.nan(f64)));
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 2);
                try writer.writeByte(@intFromEnum(types.Op.end));

                // entry_ptr = record_ptr + index * 16 + 8 (points to entry value)
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i1);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 16);
                try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 8);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.i32_load));
                try writer.writeByte(0x02);
                try writer.writeByte(0x08);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i2);
                try writer.writeByte(@intFromEnum(types.Op.i32_eq));
                try writer.writeByte(@intFromEnum(types.Op.if_op));
                try writer.writeByte(@intFromEnum(types.ValType.void));
                try self.emitSetResultKind(writer, .number);
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i4);
                try writer.writeByte(@intFromEnum(types.Op.f64_load));
                try writer.writeByte(0x03);
                try writer.writeByte(0x00);
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 2);
                try writer.writeByte(@intFromEnum(types.Op.end));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.i32_const));
                _ = try leb.encodeSigned(writer, 1);
                try writer.writeByte(@intFromEnum(types.Op.i32_add));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i3);
                try writer.writeByte(@intFromEnum(types.Op.br));
                _ = try leb.encodeUnsigned(writer, 0);
                try writer.writeByte(@intFromEnum(types.Op.end));
                try self.emitSetResultKind(writer, .undefined);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&std.math.nan(f64)));
                try writer.writeByte(@intFromEnum(types.Op.end));
                try self.pushType(field_tag);
            },
            .unit_create => {
                // Stack: [magnitude, unit_prototype]. SI product of magnitude
                // and prototype's SI value; result carries unit dimensions.
                const proto = self.popTypeAndUnit();
                const mag = self.popTypeAndUnit();
                const meta = combineUnitMul(mag.unit, proto.unit) orelse proto.unit orelse mag.unit;
                try writer.writeByte(@intFromEnum(types.Op.f64_mul));
                if (meta) |m|
                    try self.pushUnitType(m)
                else
                    return error.UnitOpNotResolvable;
            },
            .unit_convert => {
                // Same semantics as conv(): (source_si - offset) / scale.
                // Static path when target unit metadata is known.
                // Matrix sources: elementwise SI → target (matches VM).
                const target = self.popTypeAndUnit();
                const source = self.popTypeAndUnit();
                if (target.unit) |t| {
                    self.saw_static_unit = true;
                    if (source.tag == .matrix) {
                        try self.emitMatrixUnitConversion(
                            writer,
                            t,
                            scratch_f1,
                            scratch_i1,
                            scratch_i2,
                            scratch_i3,
                            scratch_i4,
                            scratch_i5,
                        );
                        try self.pushType(.matrix);
                    } else {
                        if (source.unit) |s| {
                            if (!s.dims.equals(t.dims)) return error.UnitDimensionMismatch;
                        }
                        try self.emitUnitConversion(writer, t);
                        try self.pushType(.number);
                    }
                } else {
                    // No static target metadata — refuse silent strip.
                    return error.UnitOpNotResolvable;
                }
            },

            .pop => {
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.drop));
            },
            .halt => {},
            .def_user => {
                // Function definition pushes true (1.0) in the VM
                // The actual function is compiled separately via discoverFunctions
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&@as(f64, 1.0)));
                try self.pushType(.boolean);
            },
            .not_ => {
                // Logical NOT: if value == 0, return 1.0, else return 0.0
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .and_ => {
                // Logical AND: (a != 0) && (b != 0)
                // Stack: [a, b] where b is on top
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_f1);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                try writer.writeByte(@intFromEnum(types.Op.f64_ne)); // a != 0 -> i32
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_f1);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                try writer.writeByte(@intFromEnum(types.Op.f64_ne)); // b != 0 -> i32
                try writer.writeByte(@intFromEnum(types.Op.i32_and));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .or_ => {
                // Logical OR: (a != 0) || (b != 0)
                // Stack: [a, b] where b is on top
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_f1);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                try writer.writeByte(@intFromEnum(types.Op.f64_ne)); // a != 0 -> i32
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_f1);
                try writer.writeByte(@intFromEnum(types.Op.f64_const));
                try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                try writer.writeByte(@intFromEnum(types.Op.f64_ne)); // b != 0 -> i32
                try writer.writeByte(@intFromEnum(types.Op.i32_or));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_s));
                try self.pushType(.boolean);
            },
            .band => {
                // Bitwise AND: convert both to i64, AND, convert back to f64
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_and));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i64_s));
                try self.pushType(.number);
            },
            .bor => {
                // Bitwise OR: convert both to i64, OR, convert back to f64
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_or));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i64_s));
                try self.pushType(.number);
            },
            .bxor => {
                // Bitwise XOR: convert both to i64, XOR, convert back to f64
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_xor));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i64_s));
                try self.pushType(.number);
            },
            .shl => {
                // Shift left: a << b (WASM uses low 6 bits of shift amount for i64)
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_shl));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i64_s));
                try self.pushType(.number);
            },
            .shr => {
                // Shift right: a >> b (using unsigned shift to match VM behavior)
                _ = self.popType();
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_set));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.local_get));
                _ = try leb.encodeUnsigned(writer, scratch_i64);
                try writer.writeByte(@intFromEnum(types.Op.i64_shr_u));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i64_s));
                try self.pushType(.number);
            },
            .bnot => {
                // Bitwise NOT: ~a (XOR with -1)
                _ = self.popType();
                try writer.writeByte(@intFromEnum(types.Op.i64_trunc_f64_s));
                try writer.writeByte(@intFromEnum(types.Op.i64_const));
                _ = try leb.encodeSigned(writer, @as(i64, -1));
                try writer.writeByte(@intFromEnum(types.Op.i64_xor));
                try writer.writeByte(@intFromEnum(types.Op.f64_convert_i64_s));
                try self.pushType(.number);
            },
            .jmp, .jmp_if_false, .jmp_if_true => return error.UnexpectedUnstructuredJump,
            .pos => {
                const t = self.popType();
                try self.pushType(t);
            }, // Unary plus is no-op for numbers
            .nop => {}, // No operation
            // mat_index is a legacy/dead opcode: never emitted by the parser or
            // bytecode compiler (get_index + load_var_index_* supersede it).
            // Kept in Opcode enum for wire ordinal stability only — see
            // src/vm/bytecode.zig and docs/internals/bytecode.md.
            .mat_index => return error.UnsupportedOpcode,
            .set_index => {
                // Stack: [object, keys..., value]; result = value.
                if (inst.operand == 0 or inst.operand > 2) return error.UnsupportedOpcode;

                const value_t = self.popType();
                var has_slice_key = false;
                var key_is_slice: [2]bool = .{ false, false };
                var k: u32 = inst.operand;
                while (k > 0) {
                    k -= 1;
                    const kt = self.popType();
                    key_is_slice[k] = (kt == .slice);
                    if (kt == .slice) has_slice_key = true;
                }
                const object_t = self.popType();
                if (object_t != .matrix) return error.UnsupportedOpcode;

                if (inst.operand == 2 and !has_slice_key and value_t == .number) {
                    // Single-element assign: mat[row, col] = number
                    // Stack: [mat, row, col, val]
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // val
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // col
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // row
                    // Spill val bits so f1 can hold mat ptr for negative wrap (VM parity).
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.i64_reinterpret_f64));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i64);
                    // mat still on stack as f64
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // mat as f64
                    try emitNegativeIndexWrap(writer, scratch_f3, scratch_f1, .rows);
                    try emitNegativeIndexWrap(writer, scratch_f2, scratch_f1, .cols);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // mat
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i64);
                    try writer.writeByte(@intFromEnum(types.Op.f64_reinterpret_i64));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // restore val

                    // Validate integer non-neg indices (after wrap)
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.void));

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // row
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i3); // col

                    // row < rows && col < cols
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.void));

                    // *(&mat.data[row*cols+col]) = val
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i3);
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);

                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try self.pushType(.number);
                } else if (inst.operand == 1 and !has_slice_key and value_t == .number) {
                    // Vector 1D assign: mat[i] = number (flat row-major)
                    // Stack: [mat, idx, val]
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // val
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // idx
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // mat

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_floor));
                    try writer.writeByte(@intFromEnum(types.Op.f64_eq));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.f64_const));
                    try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
                    try writer.writeByte(@intFromEnum(types.Op.f64_ge));
                    try writer.writeByte(@intFromEnum(types.Op.i32_and));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.void));

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i2); // idx

                    // idx < rows*cols
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x00);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.i32_load));
                    try writer.writeByte(0x02);
                    try writer.writeByte(0x04);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
                    try writer.writeByte(@intFromEnum(types.Op.if_op));
                    try writer.writeByte(@intFromEnum(types.ValType.void));

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i1);
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_i2);
                    try writer.writeByte(@intFromEnum(types.Op.i32_const));
                    _ = try leb.encodeSigned(writer, 8);
                    try writer.writeByte(@intFromEnum(types.Op.i32_mul));
                    try writer.writeByte(@intFromEnum(types.Op.i32_add));
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try writer.writeByte(@intFromEnum(types.Op.f64_store));
                    try writer.writeByte(0x03);
                    try writer.writeByte(0x08);

                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));
                    try writer.writeByte(@intFromEnum(types.Op.else_op));
                    try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
                    try writer.writeByte(@intFromEnum(types.Op.end));

                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try self.pushType(.number);
                } else if (inst.operand == 2 and value_t == .matrix) {
                    // General 2-key matrix assign from matrix RHS (row/col/submatrix).
                    // Stack: [mat, key0, key1, rhs]
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f1); // rhs
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f2); // key1
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_f3); // key0
                    try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
                    try writer.writeByte(@intFromEnum(types.Op.local_set));
                    _ = try leb.encodeUnsigned(writer, scratch_i1); // mat

                    try self.emitMatrixSliceAssign(
                        writer,
                        key_is_slice[0],
                        key_is_slice[1],
                        scratch_f1,
                        scratch_f2,
                        scratch_f3,
                        scratch_i1,
                        scratch_i2,
                        scratch_i3,
                        scratch_i4,
                        scratch_i5,
                        scratch_i64,
                    ); // scratch_i64 packs rstep|cstep<<32
                    // Result of assignment is the RHS matrix pointer.
                    try writer.writeByte(@intFromEnum(types.Op.local_get));
                    _ = try leb.encodeUnsigned(writer, scratch_f1);
                    try self.pushType(.matrix);
                } else {
                    return error.UnsupportedOpcode;
                }
            },
            // Default case: fail-fast for any other unhandled opcodes
            // This ensures we catch missing implementations early
        }
    }

    /// Resolve one matrix axis key (number or slice) to (start, len, step).
    /// Matches VM `resolveMatrixSlice`: NaN start/end => full range; start>0 is
    /// 1-based inclusive → 0-based start; end>0 is 1-based inclusive end; step
    /// defaults to 1 (NaN/null), rejects 0 and negative (trap).
    const IndexAxis = enum { rows, cols, total };

    /// If the f64 index in `key_f` is negative, add the axis length of the
    /// matrix whose pointer (as f64) is in `ptr_f` — Python-style wrap,
    /// matching the VM's normalizeMatrixIndex. A still-negative result then
    /// fails the caller's `>= 0` validity check and traps as out of bounds.
    fn emitNegativeIndexWrap(writer: anytype, key_f: u32, ptr_f: u32, axis: IndexAxis) !void {
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
        try writer.writeByte(@intFromEnum(types.Op.f64_lt));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, ptr_f);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(if (axis == .cols) @as(u8, 0x04) else @as(u8, 0x00));
        if (axis == .total) {
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, ptr_f);
            try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
            try writer.writeByte(@intFromEnum(types.Op.i32_load));
            try writer.writeByte(0x02);
            try writer.writeByte(0x04);
            try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        }
        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
        try writer.writeByte(@intFromEnum(types.Op.f64_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.end));
    }

    fn emitResolveAxisRange(
        self: *WasmCompiler,
        writer: anytype,
        is_slice: bool,
        key_f: u32,
        mat_i: u32,
        axis_is_rows: bool,
        out_start: u32,
        out_len: u32,
        tmp_i: u32,
        out_step: u32,
    ) !void {
        _ = self;
        // axis_len
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, mat_i);
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(if (axis_is_rows) @as(u8, 0x00) else @as(u8, 0x04));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, tmp_i); // axis_len

        if (!is_slice) {
            // Number key: 0-based single element, step=1. Negative indices wrap
            // (idx += axis_len) like the VM's normalizeMatrixIndex.
            try writer.writeByte(@intFromEnum(types.Op.i32_const));
            _ = try leb.encodeSigned(writer, 1);
            try writer.writeByte(@intFromEnum(types.Op.local_set));
            _ = try leb.encodeUnsigned(writer, out_step);
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, key_f);
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, key_f);
            try writer.writeByte(@intFromEnum(types.Op.f64_floor));
            try writer.writeByte(@intFromEnum(types.Op.f64_eq));
            try writer.writeByte(@intFromEnum(types.Op.if_op));
            try writer.writeByte(@intFromEnum(types.ValType.void));
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, key_f);
            try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_s));
            try writer.writeByte(@intFromEnum(types.Op.local_tee));
            _ = try leb.encodeUnsigned(writer, out_start);
            try writer.writeByte(@intFromEnum(types.Op.i32_const));
            _ = try leb.encodeSigned(writer, 0);
            try writer.writeByte(@intFromEnum(types.Op.i32_lt_s));
            try writer.writeByte(@intFromEnum(types.Op.if_op));
            try writer.writeByte(@intFromEnum(types.ValType.void));
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, out_start);
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, tmp_i);
            try writer.writeByte(@intFromEnum(types.Op.i32_add));
            try writer.writeByte(@intFromEnum(types.Op.local_set));
            _ = try leb.encodeUnsigned(writer, out_start);
            try writer.writeByte(@intFromEnum(types.Op.end));
            // Unsigned bound check also rejects a still-negative index.
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, out_start);
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, tmp_i);
            try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
            try writer.writeByte(@intFromEnum(types.Op.if_op));
            try writer.writeByte(@intFromEnum(types.ValType.void));
            try writer.writeByte(@intFromEnum(types.Op.i32_const));
            _ = try leb.encodeSigned(writer, 1);
            try writer.writeByte(@intFromEnum(types.Op.local_set));
            _ = try leb.encodeUnsigned(writer, out_len);
            try writer.writeByte(@intFromEnum(types.Op.else_op));
            try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
            try writer.writeByte(@intFromEnum(types.Op.end));
            try writer.writeByte(@intFromEnum(types.Op.else_op));
            try writer.writeByte(@intFromEnum(types.Op.@"unreachable"));
            try writer.writeByte(@intFromEnum(types.Op.end));
            return;
        }

        // Slice key: layout start@0, end@8, step@16 (NaN = null)
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_start); // reuse as slice_ptr temporarily

        // start_raw
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_start);
        try writer.writeByte(@intFromEnum(types.Op.f64_load));
        try writer.writeByte(0x03);
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.local_tee));
        _ = try leb.encodeUnsigned(writer, key_f); // clobber key_f with start_raw (ok, slice ptr in out_start)
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        // f64_ne is true for NaN (NaN != NaN). Match existing slice path: if NaN → default.
        try writer.writeByte(@intFromEnum(types.Op.f64_ne));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.i32));
        // NaN start → 0
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.else_op));
        // finite start: if > 0 then trunc-1 else trunc (VM hybrid convention)
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
        try writer.writeByte(@intFromEnum(types.Op.f64_gt));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.i32));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_s));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.i32_sub));
        try writer.writeByte(@intFromEnum(types.Op.else_op));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_s));
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_len); // temp: start0 in out_len

        // step@16 while slice_ptr still in out_start (VM: null→1, 0→err, <0→err)
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_start);
        try writer.writeByte(@intFromEnum(types.Op.f64_load));
        try writer.writeByte(0x03);
        try writer.writeByte(0x10);
        try writer.writeByte(@intFromEnum(types.Op.local_tee));
        _ = try leb.encodeUnsigned(writer, key_f); // step_raw
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.f64_ne)); // true if NaN → default step 1
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.i32));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.else_op));
        // strict integer like VM strictI64FromNumber
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.f64_floor));
        try writer.writeByte(@intFromEnum(types.Op.f64_eq));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.i32));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_s));
        try writer.writeByte(@intFromEnum(types.Op.local_tee));
        _ = try leb.encodeUnsigned(writer, out_step);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.i32_eq));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.@"unreachable")); // InvalidStep
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_step);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_s));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.@"unreachable")); // InvalidArgument (neg step)
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_step);
        try writer.writeByte(@intFromEnum(types.Op.else_op));
        try writer.writeByte(@intFromEnum(types.Op.@"unreachable")); // non-integral step
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_step);

        // end_raw → end_excl in out_start after saving slice_ptr
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_start); // slice_ptr
        try writer.writeByte(@intFromEnum(types.Op.f64_load));
        try writer.writeByte(0x03);
        try writer.writeByte(0x08);
        try writer.writeByte(@intFromEnum(types.Op.local_tee));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.f64_ne)); // true if NaN
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.i32));
        // NaN end → axis_len
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, tmp_i);
        try writer.writeByte(@intFromEnum(types.Op.else_op));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
        try writer.writeByte(@intFromEnum(types.Op.f64_gt));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.i32));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_s)); // 1-based inclusive end == excl bound
        try writer.writeByte(@intFromEnum(types.Op.else_op));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, key_f);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_s));
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.end));
        // end_excl on stack; start0 in out_len; step in out_step
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_start); // end_excl

        // Negative bounds wrap (+= axis_len) before clamping — VM parity
        // (resolveMatrixSlice); previously they clamped straight to 0.
        inline for (.{ out_len, out_start }) |bound_local| {
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, bound_local);
            try writer.writeByte(@intFromEnum(types.Op.i32_const));
            _ = try leb.encodeSigned(writer, 0);
            try writer.writeByte(@intFromEnum(types.Op.i32_lt_s));
            try writer.writeByte(@intFromEnum(types.Op.if_op));
            try writer.writeByte(@intFromEnum(types.ValType.void));
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, bound_local);
            try writer.writeByte(@intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(writer, tmp_i);
            try writer.writeByte(@intFromEnum(types.Op.i32_add));
            try writer.writeByte(@intFromEnum(types.Op.local_set));
            _ = try leb.encodeUnsigned(writer, bound_local);
            try writer.writeByte(@intFromEnum(types.Op.end));
        }

        // Clamp start0 to [0, axis_len]
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_len); // start0
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_s));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_len);
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_len);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, tmp_i);
        try writer.writeByte(@intFromEnum(types.Op.i32_gt_s));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, tmp_i);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_len);
        try writer.writeByte(@intFromEnum(types.Op.end));

        // Clamp end_excl to [0, axis_len] (VM); empty when start>=end via positiveStepSliceLen
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_start);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_s));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_start);
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_start);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, tmp_i);
        try writer.writeByte(@intFromEnum(types.Op.i32_gt_s));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, tmp_i);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_start);
        try writer.writeByte(@intFromEnum(types.Op.end));

        // positiveStepSliceLen(start0, end_excl, step); then out_start=start, out_len=len
        // if start >= end → 0 else (end - start + step - 1) / step
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_len); // start0
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_start); // end_excl
        try writer.writeByte(@intFromEnum(types.Op.i32_ge_s));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.i32));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.else_op));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_start);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_len);
        try writer.writeByte(@intFromEnum(types.Op.i32_sub)); // span
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_step);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.i32_sub));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_step);
        try writer.writeByte(@intFromEnum(types.Op.i32_div_s));
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, tmp_i); // len in tmp
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, out_len);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_start); // start
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, tmp_i);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, out_len); // len
    }

    /// Assign RHS matrix into mat[row_range, col_range] with per-axis step.
    /// On entry: f_rhs, f_key1, f_key0, i_mat set. Clobbers listed scratches except f_rhs.
    /// i64_pack holds rstep in low 32 bits and cstep in high 32 bits after resolve.
    fn emitMatrixSliceAssign(
        self: *WasmCompiler,
        writer: anytype,
        key0_is_slice: bool,
        key1_is_slice: bool,
        f_rhs: u32,
        f_key1: u32,
        f_key0: u32,
        i_mat: u32,
        si2: u32,
        si3: u32,
        si4: u32,
        si5: u32,
        i64_pack: u32,
    ) !void {
        // Resolve rows → si2=rstart, si3=rlen, si5=rstep (tmp si4).
        try self.emitResolveAxisRange(writer, key0_is_slice, f_key0, i_mat, true, si2, si3, si4, si5);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.i64_extend_i32_s));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, i64_pack); // rstep in low 32
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si2);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        // Resolve cols → si2=cstart, si3=clen, si5=cstep.
        try self.emitResolveAxisRange(writer, key1_is_slice, f_key1, i_mat, false, si2, si3, si4, si5);
        // Pack cstep into high 32 of i64_pack.
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.i64_extend_i32_s));
        try writer.writeByte(@intFromEnum(types.Op.i64_const));
        _ = try leb.encodeSigned(writer, @as(i64, 32));
        try writer.writeByte(@intFromEnum(types.Op.i64_shl));
        try writer.writeByte(@intFromEnum(types.Op.i64_or));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        // Stack [rstart, rlen]; si2=cstart si3=clen → final si2=rstart si3=rlen si4=cstart si5=clen
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si2);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si4);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si2);

        // Check rhs.rows * rhs.cols == rlen * clen
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_rhs);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_rhs);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x04);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_eq));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));

        // f_key0 = ri (f64), f_key1 = ci (f64)
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_key0);

        try writer.writeByte(@intFromEnum(types.Op.loop)); // row loop
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));

        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 0.0)));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_key1);

        try writer.writeByte(@intFromEnum(types.Op.loop)); // col loop
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));

        // dest addr = mat + 8 + ((rstart+ri*rstep)*mat_cols + (cstart+ci*cstep))*8
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i_mat);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si2); // rstart
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u)); // ri
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        try writer.writeByte(@intFromEnum(types.Op.i32_wrap_i64)); // rstep
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i_mat);
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x04); // mat_cols
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si4); // cstart
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u)); // ci
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        try writer.writeByte(@intFromEnum(types.Op.i64_const));
        _ = try leb.encodeSigned(writer, @as(i64, 32));
        try writer.writeByte(@intFromEnum(types.Op.i64_shr_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_wrap_i64)); // cstep
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));

        // value = rhs.data[ri*rhs_cols + ci]
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_rhs);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_rhs);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x04); // rhs_cols
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.f64_load));
        try writer.writeByte(0x03);
        try writer.writeByte(0x08);

        try writer.writeByte(@intFromEnum(types.Op.f64_store));
        try writer.writeByte(0x03);
        try writer.writeByte(0x08);

        // ci++
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 1.0)));
        try writer.writeByte(@intFromEnum(types.Op.f64_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.br));
        _ = try leb.encodeUnsigned(writer, 1); // continue col loop
        try writer.writeByte(@intFromEnum(types.Op.end)); // end if ci
        try writer.writeByte(@intFromEnum(types.Op.end)); // end col loop

        // ri++
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.f64_const));
        try writer.writeAll(std.mem.asBytes(&@as(f64, 1.0)));
        try writer.writeByte(@intFromEnum(types.Op.f64_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.br));
        _ = try leb.encodeUnsigned(writer, 1); // continue row loop
        try writer.writeByte(@intFromEnum(types.Op.end)); // end if ri
        try writer.writeByte(@intFromEnum(types.Op.end)); // end row loop

        try writer.writeByte(@intFromEnum(types.Op.else_op));
        try writer.writeByte(@intFromEnum(types.Op.@"unreachable")); // dim mismatch
        try writer.writeByte(@intFromEnum(types.Op.end));
    }

    /// Extract submatrix mat[row_range, col_range] with per-axis step. Pushes result ptr as f64.
    /// On entry: f_key1, f_key0, i_mat set. Result left on wasm stack as f64 ptr.
    /// i64_pack holds rstep (low 32) | cstep<<32 after resolve.
    fn emitMatrixSliceGet(
        self: *WasmCompiler,
        writer: anytype,
        key0_is_slice: bool,
        key1_is_slice: bool,
        f_out: u32,
        f_key1: u32,
        f_key0: u32,
        i_mat: u32,
        si2: u32,
        si3: u32,
        si4: u32,
        si5: u32,
        i64_pack: u32,
    ) !void {
        // Resolve rows → si2=rstart, si3=rlen, si5=rstep (tmp si4).
        try self.emitResolveAxisRange(writer, key0_is_slice, f_key0, i_mat, true, si2, si3, si4, si5);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.i64_extend_i32_s));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, i64_pack); // rstep low 32
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si2);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        // Resolve cols → si2=cstart, si3=clen, si5=cstep.
        try self.emitResolveAxisRange(writer, key1_is_slice, f_key1, i_mat, false, si2, si3, si4, si5);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.i64_extend_i32_s));
        try writer.writeByte(@intFromEnum(types.Op.i64_const));
        _ = try leb.encodeSigned(writer, @as(i64, 32));
        try writer.writeByte(@intFromEnum(types.Op.i64_shl));
        try writer.writeByte(@intFromEnum(types.Op.i64_or));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        // Stack [rstart, rlen]; i2=cstart i3=clen → i2=rstart i3=rlen i4=cstart; clen → f_key1 as f64
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si2);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si4); // cstart
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_key1); // clen as f64
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si3); // rlen
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si2); // rstart

        // Spill rlen → f_key0, rstart → f_out (temps), size → si5
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_key0); // rlen
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si2);
        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_out); // rstart temp

        // size = 8 + rlen * clen * 8
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si5);

        // Alloc: size=si5, out=si3, new_end=si5, curr=si2 (rstart spilled)
        try self.emitHeapAllocChecked(writer, si5, si3, si5, si2);
        // Restore rstart; result ptr to f_out
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_out);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si2); // rstart restored
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.f64_convert_i32_u));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, f_out); // result ptr

        // store rows=rlen, cols=clen on result
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3); // out ptr
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u)); // rlen
        try writer.writeByte(@intFromEnum(types.Op.i32_store));
        try writer.writeByte(0x02);
        try writer.writeByte(0x00);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u)); // clen
        try writer.writeByte(@intFromEnum(types.Op.i32_store));
        try writer.writeByte(0x02);
        try writer.writeByte(0x04);

        // Layout: i_mat, i2=rstart, i4=cstart, f_out=out, f_key0=rlen, f_key1=clen, i64_pack=steps
        // Copy loop: ri in i3, ci in i5; src index = start + i*step
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si3); // ri=0

        try writer.writeByte(@intFromEnum(types.Op.loop));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key0);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));

        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 0);
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si5); // ci=0

        try writer.writeByte(@intFromEnum(types.Op.loop));
        try writer.writeByte(@intFromEnum(types.ValType.void));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_lt_u));
        try writer.writeByte(@intFromEnum(types.Op.if_op));
        try writer.writeByte(@intFromEnum(types.ValType.void));

        // dest = out + 8 + (ri*clen + ci)*8
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_out);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3); // ri
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_key1);
        try writer.writeByte(@intFromEnum(types.Op.i32_trunc_f64_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5); // ci
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));

        // src = mat + 8 + ((rstart+ri*rstep)*mat_cols + (cstart+ci*cstep))*8
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i_mat);
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si2); // rstart
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3); // ri
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        try writer.writeByte(@intFromEnum(types.Op.i32_wrap_i64)); // rstep
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i_mat);
        try writer.writeByte(@intFromEnum(types.Op.i32_load));
        try writer.writeByte(0x02);
        try writer.writeByte(0x04);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si4); // cstart
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5); // ci
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, i64_pack);
        try writer.writeByte(@intFromEnum(types.Op.i64_const));
        _ = try leb.encodeSigned(writer, @as(i64, 32));
        try writer.writeByte(@intFromEnum(types.Op.i64_shr_u));
        try writer.writeByte(@intFromEnum(types.Op.i32_wrap_i64)); // cstep
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 8);
        try writer.writeByte(@intFromEnum(types.Op.i32_mul));
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.f64_load));
        try writer.writeByte(0x03);
        try writer.writeByte(0x08);

        try writer.writeByte(@intFromEnum(types.Op.f64_store));
        try writer.writeByte(0x03);
        try writer.writeByte(0x08);

        // ci++
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si5);
        try writer.writeByte(@intFromEnum(types.Op.br));
        _ = try leb.encodeUnsigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.end));

        // ri++
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.i32_add));
        try writer.writeByte(@intFromEnum(types.Op.local_set));
        _ = try leb.encodeUnsigned(writer, si3);
        try writer.writeByte(@intFromEnum(types.Op.br));
        _ = try leb.encodeUnsigned(writer, 1);
        try writer.writeByte(@intFromEnum(types.Op.end));
        try writer.writeByte(@intFromEnum(types.Op.end));

        // push result ptr
        try writer.writeByte(@intFromEnum(types.Op.local_get));
        _ = try leb.encodeUnsigned(writer, f_out);
    }

    pub fn writeTo(self: *WasmCompiler, writer: anytype) !void {
        try self.module.writeTo(writer);
    }
};

/// Sanitize a node/output id into a wasm-legal export name: `prefix` +
/// alphanumeric/underscore only (other chars → `_`).
pub fn sanitizeExportName(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, prefix);
    if (id.len == 0) {
        try list.appendSlice(allocator, "anon");
    } else {
        for (id) |c| {
            const ok = (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or
                c == '_';
            try list.append(allocator, if (ok) c else '_');
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn validateFusePlan(plan: FuseCompilePlan) !void {
    if (plan.nodes.len == 0) return error.EmptyFusePlan;
    if (plan.outputs.len == 0) return error.EmptyFuseOutputs;
    for (plan.outputs) |o| {
        if (o.from_node >= plan.nodes.len) return error.InvalidFuseOutput;
        // Spec 07: concrete WireKinds only — reject `.any` (ambiguous seeding).
        if (o.kind == .any) return error.NonScalarFuse;
    }
    for (plan.inputs) |inp| {
        if (inp.kind == .any) return error.NonScalarFuse;
    }
    for (plan.params) |p| {
        // Params remain number-kind at the fused boundary (runtime-tunable f64).
        if (p.kind != .number and p.kind != .boolean) return error.NonScalarFuse;
    }
    // Strict topo: node_result indices must refer to earlier nodes only.
    for (plan.nodes, 0..) |n, ni| {
        if (n.arg_kinds.len != 0 and n.arg_kinds.len != n.arg_sources.len) {
            return error.InvalidFuseArg;
        }
        if (n.output_kind == .any) return error.NonScalarFuse;
        for (n.arg_kinds) |k| {
            if (k == .any) return error.NonScalarFuse;
        }
        for (n.arg_sources) |src| {
            switch (src) {
                .graph_input => |i| if (i >= plan.inputs.len) return error.InvalidFuseArg,
                .graph_param => |i| if (i >= plan.params.len) return error.InvalidFuseArg,
                .node_result => |i| {
                    if (i >= ni) return error.InvalidFuseArg; // no forward/self refs
                },
                .const_value => {},
            }
        }
    }
}

/// Wire kinds that need linear memory (ptr-backed values or host-written inputs).
fn wireKindNeedsHeap(kind: abi.WireKind) bool {
    return switch (kind) {
        .number, .boolean => false,
        // series host_handle does not need module heap for the handle itself,
        // but host may still write linear-memory series under series_repr; keep
        // heap available for mixed graphs.
        .series_handle => true,
        .matrix_ptr, .complex_ptr, .record_ptr, .string_ptr, .predicate_ptr, .any => true,
    };
}

/// Map ABI wire kind → ValueTag for AOT param-type seeding (Spec 07).
/// `.any` is rejected in `validateFusePlan` before this is used for seeds.
fn wireKindToValueTag(kind: abi.WireKind) mathzig.ValueTag {
    return switch (kind) {
        .number => .number,
        .boolean => .boolean,
        .matrix_ptr => .matrix,
        .complex_ptr => .complex,
        .record_ptr => .record,
        .string_ptr => .string,
        .series_handle => .series,
        .predicate_ptr => .predicate,
        // Defensive: callers must not seed `.any` (validate rejects it).
        .any => .number,
    };
}

fn emitArgPush(
    code: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    w: anytype,
    src: FuseArgSource,
    n_inputs: u32,
    result_base: u32,
) !void {
    switch (src) {
        .graph_input => |i| {
            try code.append(allocator, @intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(w, i);
        },
        .graph_param => |i| {
            try code.append(allocator, @intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(w, n_inputs + i);
        },
        .node_result => |i| {
            try code.append(allocator, @intFromEnum(types.Op.local_get));
            _ = try leb.encodeUnsigned(w, result_base + i);
        },
        .const_value => |v| {
            try code.append(allocator, @intFromEnum(types.Op.f64_const));
            var bits: [8]u8 = undefined;
            std.mem.writeInt(u64, &bits, @as(u64, @bitCast(v)), .little);
            try code.appendSlice(allocator, &bits);
        },
    }
}

/// Combine unit metadata for mul. null means dimensionless number.
fn combineUnitMul(a: ?UnitMeta, b: ?UnitMeta) ?UnitMeta {
    if (a == null and b == null) return null;
    const da = if (a) |u| u.dims else Dimensions{};
    const db = if (b) |u| u.dims else Dimensions{};
    const dims = Dimensions.multiply(da, db);
    if (dims.isScalar()) return null;
    // Product is SI-normalized (scale 1); name only preserved if one side
    // was dimensionless and the other had a name.
    if (a != null and b == null) return a;
    if (a == null and b != null) return b;
    return UnitMeta{ .dims = dims, .scale = 1.0, .offset = 0, .name = null };
}

fn combineUnitDiv(a: ?UnitMeta, b: ?UnitMeta) ?UnitMeta {
    if (a == null and b == null) return null;
    const da = if (a) |u| u.dims else Dimensions{};
    const db = if (b) |u| u.dims else Dimensions{};
    const dims = Dimensions.divide(da, db);
    if (dims.isScalar()) return null;
    if (a != null and b == null) return a;
    return UnitMeta{ .dims = dims, .scale = 1.0, .offset = 0, .name = null };
}

/// add/sub: dimensions must match when both sides carry units.
fn combineUnitAdd(a: ?UnitMeta, b: ?UnitMeta) !?UnitMeta {
    if (a == null and b == null) return null;
    if (a != null and b == null) return a;
    if (a == null and b != null) return b;
    const ua = a.?;
    const ub = b.?;
    if (!ua.dims.equals(ub.dims)) return error.UnitDimensionMismatch;
    // Prefer named unit when one side still has it.
    if (ua.name != null) return ua;
    return ub;
}

test "wasm type stack transitions match bytecode stack model" {
    const allocator = std.testing.allocator;
    const value_mod = @import("../core/value.zig");
    const BytecodeBuilder = @import("../vm/bytecode.zig").BytecodeBuilder;

    const constants = [_]mathzig.Value{
        mathzig.Value.initNumber(3.0), // 0
        mathzig.Value.initNumber(5.0), // 1
        mathzig.Value.initNumber(2.0), // 2
        mathzig.Value.initNumber(2.0), // 3
        mathzig.Value.initNumber(3.0), // 4
        mathzig.Value.initNumber(4.0), // 5
        mathzig.Value.initNumber(42.0), // 6
        .{ .tag = .string, .data = .{ .string = value_mod.StringHandle.fromSlice("k") } }, // 7
        mathzig.Value.initNumber(1.0), // 8
        mathzig.Value.initNumber(2.0), // 9
        mathzig.Value.initNumber(1.0), // 10
        mathzig.Value.initNumber(1.0), // 11
        mathzig.Value.initNumber(2.0), // 12
        mathzig.Value.initNumber(3.0), // 13
        mathzig.Value.initNumber(4.0), // 14
        mathzig.Value.initNumber(0.0), // 15
        mathzig.Value.initNumber(1.0), // 16
    };

    const code = [_]Instruction{
        Instruction.initWithOperand(.push_const, 0),
        Instruction.init(.neg),
        Instruction.init(.dup),
        Instruction.init(.pop),
        Instruction.initWithOperand(.push_const, 1),
        Instruction.init(.mod),
        Instruction.initWithOperand(.push_const, 2),
        Instruction.init(.pow),
        Instruction.initWithOperand(.push_const, 3),
        Instruction.initWithOperand(.push_const, 4),
        Instruction.initWithOperand(.push_const, 5),
        Instruction.init(.fma),
        Instruction.initWithOperand(.push_const, 6),
        Instruction.initWithOperand(.push_const, 7),
        Instruction.initWithOperand(.rec_create, 1),
        Instruction.initWithOperand(.push_const, 8),
        Instruction.initWithOperand(.push_const, 9),
        Instruction.initWithOperand(.push_const, 10),
        Instruction.init(.make_slice),
        Instruction.initWithOperand(.push_const, 11),
        Instruction.initWithOperand(.push_const, 12),
        Instruction.initWithOperand(.push_const, 13),
        Instruction.initWithOperand(.push_const, 14),
        Instruction.initWithOperand(.mat_create, (2 | (2 << 12))),
        Instruction.initWithOperand(.push_const, 15),
        Instruction.initWithOperand(.push_const, 16),
        Instruction.initWithOperand(.get_index, 2),
        Instruction.init(.def_user),
        Instruction.init(.halt),
    };

    var source_offsets: [code.len]u32 = undefined;
    @memset(source_offsets[0..], 0);

    const expr = CompiledExpr{
        .code = &code,
        .source_offsets = source_offsets[0..],
        .constants = &constants,
        .constants_f64 = &.{},
        .max_stack = 64,
        .is_number_only = false,
        .allocator = allocator,
        .owns_memory = false,
    };

    var compiler = WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.ensureImports(&expr);

    var var_map = std.AutoHashMap(u8, u32).init(allocator);
    defer var_map.deinit();
    var string_map = std.AutoHashMap(usize, u32).init(allocator);
    defer string_map.deinit();
    try string_map.put(7, 2048); // push_const string offset for rec_create key

    var bytecode_model = BytecodeBuilder.init(allocator);
    defer bytecode_model.deinit();

    var sink = std.ArrayListUnmanaged(u8).empty;
    defer sink.deinit(allocator);
    const writer = list_writer.unmanagedByteWriter(&sink, allocator);

    compiler.type_stack.clearRetainingCapacity();
    for (expr.code) |inst| {
        try bytecode_model.emitWithOperand(inst.opcode, inst.operand, 0);
        try compiler.compileInstruction(
            writer,
            inst,
            &expr,
            &var_map,
            &string_map,
            0,
            0,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
        );
        const expected: usize = @intCast(bytecode_model.current_stack);
        try std.testing.expectEqual(expected, compiler.type_stack.items.len);
    }
}

test "wasm heap allocations emit memory bounds checks" {
    const allocator = std.testing.allocator;

    const constants = [_]mathzig.Value{
        mathzig.Value.initNumber(1.0),
        mathzig.Value.initNumber(2.0),
        mathzig.Value.initNumber(3.0),
        mathzig.Value.initNumber(4.0),
    };
    const code = [_]Instruction{
        Instruction.initWithOperand(.push_const, 0),
        Instruction.initWithOperand(.push_const, 1),
        Instruction.initWithOperand(.push_const, 2),
        Instruction.initWithOperand(.push_const, 3),
        Instruction.initWithOperand(.mat_create, (2 | (2 << 12))),
        Instruction.init(.halt),
    };
    var source_offsets: [code.len]u32 = undefined;
    @memset(source_offsets[0..], 0);
    const expr = CompiledExpr{
        .code = &code,
        .source_offsets = source_offsets[0..],
        .constants = &constants,
        .constants_f64 = &.{},
        .max_stack = 16,
        .is_number_only = false,
        .allocator = allocator,
        .owns_memory = false,
    };

    var compiler = WasmCompiler.init(allocator);
    defer compiler.deinit();

    var var_map = std.AutoHashMap(u8, u32).init(allocator);
    defer var_map.deinit();
    var string_map = std.AutoHashMap(usize, u32).init(allocator);
    defer string_map.deinit();

    var sink = std.ArrayListUnmanaged(u8).empty;
    defer sink.deinit(allocator);
    const writer = list_writer.unmanagedByteWriter(&sink, allocator);

    compiler.type_stack.clearRetainingCapacity();
    for (expr.code) |inst| {
        try compiler.compileInstruction(
            writer,
            inst,
            &expr,
            &var_map,
            &string_map,
            0,
            0,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
        );
    }

    try std.testing.expect(std.mem.indexOfScalar(u8, sink.items, @intFromEnum(types.Op.memory_size)) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, sink.items, @intFromEnum(types.Op.memory_grow)) != null);
    // Allocation failure path traps via unreachable (no silent NaN return).
    try std.testing.expect(std.mem.indexOfScalar(u8, sink.items, @intFromEnum(types.Op.@"unreachable")) != null);
}

test "get_index with >2 keys is a hard compile error" {
    const allocator = std.testing.allocator;
    const constants = [_]mathzig.Value{
        mathzig.Value.initNumber(1.0),
        mathzig.Value.initNumber(2.0),
        mathzig.Value.initNumber(3.0),
        mathzig.Value.initNumber(4.0),
        mathzig.Value.initNumber(0.0),
        mathzig.Value.initNumber(0.0),
        mathzig.Value.initNumber(0.0),
    };
    // mat_create 2x2 then get_index with 3 keys → unsupported
    const code = [_]Instruction{
        Instruction.initWithOperand(.push_const, 0),
        Instruction.initWithOperand(.push_const, 1),
        Instruction.initWithOperand(.push_const, 2),
        Instruction.initWithOperand(.push_const, 3),
        Instruction.initWithOperand(.mat_create, (2 | (2 << 12))),
        Instruction.initWithOperand(.push_const, 4),
        Instruction.initWithOperand(.push_const, 5),
        Instruction.initWithOperand(.push_const, 6),
        Instruction.initWithOperand(.get_index, 3),
        Instruction.init(.halt),
    };
    var source_offsets: [code.len]u32 = undefined;
    @memset(source_offsets[0..], 0);
    const expr = CompiledExpr{
        .code = &code,
        .source_offsets = source_offsets[0..],
        .constants = &constants,
        .constants_f64 = &.{},
        .max_stack = 16,
        .is_number_only = false,
        .allocator = allocator,
        .owns_memory = false,
    };

    var compiler = WasmCompiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(error.UnsupportedOpcode, compiler.compile(&expr, .{ .function_name = "bad_index" }));
}

test "compile-time toLaTeX fold matches runtime LaTeX generator" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{ "1 + 2 * 3", "1 / 2", "sqrt(x^2 + y^2)" };

    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    var compiler = WasmCompiler.init(allocator);
    defer compiler.deinit();

    for (cases) |source| {
        const runtime = try ctx.toLaTeX(source, allocator);
        defer allocator.free(runtime);
        const folded = try compiler.compileTimeToLaTeX(source);
        defer allocator.free(folded);
        try std.testing.expectEqualStrings(runtime, folded);
    }
}
