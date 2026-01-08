///! MathZig Bytecode Virtual Machine
const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("bytecode.zig");
const val_module = @import("../core/value.zig");
const Value = val_module.Value;
const ValueTag = val_module.ValueTag;
const Matrix = val_module.Matrix;
const Vec = val_module.Vec;
const VectorLen = val_module.VectorLen;
const Series = @import("../timeseries/series.zig").Series;
const Record = val_module.Record;
const Predicate = @import("../timeseries/predicates.zig").Predicate;
const CompiledExpr = bytecode.CompiledExpr;
const Opcode = bytecode.Opcode;
const BuiltinFn = bytecode.BuiltinFn;
const ts_bindings = @import("../functions/timeseries_bindings.zig");
const aggregations = @import("../timeseries/aggregations.zig");
const generators = @import("../functions/generators.zig");
const statistics = @import("../functions/statistics.zig");
const temporal = @import("../units/temporal.zig");
const csv = @import("../io/csv.zig");
const threading = @import("../core/threading.zig");

const is_wasm = builtin.cpu.arch.isWasm();

pub const VMError = error{
    StackOverflow,
    StackUnderflow,
    InvalidOpcode,
    TypeError,
    MismatchedDimensions,
    MismatchedLengths,
    ResultTooLarge,
    OutOfMemory,
    UnknownFunction,
    NotEnoughArgs,
    TooManyArgs,
    WrongArgumentCount,
    DivideByZero,
    RuntimeError,
    UnimplementedOpcode,
    InvalidArgument,
    NaNTimestamp,
    UnsortedTimestamps,
    InvalidValue,
    SingularMatrix,
    EmptySeries,
    InsufficientData,
    AssertionFailed,
    InvalidStep,
    IndexOutOfBounds,
    InvalidIndexCount,
    /// Matrix literals cannot contain unit-bearing elements (no matrix-of-units
    /// type yet). Same identity from mat_create and mat_create_3 (task-15/D6).
    MatrixUnitElementUnsupported,
    // File/IO related
    FileNotFound,
    AccessDenied,
    PermissionDenied,
    SystemResources,
    Unexpected,
    NameTooLong,
    SharingViolation,
    PathAlreadyExists,
    PipeBusy,
    NoDevice,
    InvalidUtf8,
    InvalidWtf8,
    BadPathName,
    NetworkNotFound,
    ProcessNotFound,
    AntivirusInterference,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    FileTooBig,
    IsDir,
    NoSpaceLeft,
    NotDir,
    DeviceBusy,
    FileLocksNotSupported,
    FileBusy,
    WouldBlock,
    InputOutput,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    Canceled,
    LockViolation,
    DiskQuota,
    NotOpenForWriting,
    MessageTooBig,
    // CSV
    InvalidHeader,
    MissingTimeColumn,
    ParseError,
    FileTooLarge,
};

/// MathJS-style round to `decimals` places: round(x * 10^d) / 10^d.
/// Non-finite decimals → plain @round(x). Half away from zero via @round.
fn roundToDecimals(x: f64, decimals: f64) f64 {
    if (!std.math.isFinite(decimals)) return @round(x);
    // Cap to avoid 10^d overflow / useless extremes
    const d: f64 = @max(-15.0, @min(15.0, @floor(decimals)));
    const factor = std.math.pow(f64, 10.0, d);
    if (!std.math.isFinite(factor) or factor == 0) return @round(x);
    return @round(x * factor) / factor;
}

pub const TrackedObject = union(enum) {
    matrix: *Matrix,
    series: *Series,
    record: *Record,
    slice: *val_module.Slice,

    pub fn release(self: TrackedObject) void {
        switch (self) {
            .matrix => |m| m.release(),
            .series => |s| s.release(),
            .record => |r| r.release(),
            .slice => |s| s.release(),
        }
    }
};

pub const VM = struct {
    const ComplexF64 = struct { re: f64, im: f64 };
    stack: []Value,
    sp: u16, // Stack pointer
    variables: []Value,
    /// Fast-path f64 stack for number-only expressions
    stack_f64: []f64,
    /// Fast-path f64 variables (mirrors variables array)
    variables_f64: []f64,
    /// Type tags for variables (SoA layout for fast type checking)
    variables_tags: []ValueTag,
    allocator: std.mem.Allocator,
    metadata_allocator: std.mem.Allocator,
    unit_registry: ?*@import("../units/unit_registry.zig").UnitRegistry = null,
    config: *@import("../core/config.zig").Config,

    /// Unified tracker for all intermediate objects to ensure deduplication.
    /// Maps raw pointer address to the TrackedObject union.
    intermediate_objects: std.AutoHashMapUnmanaged(usize, TrackedObject),

    /// Track intermediate unit names created during execution for cleanup
    intermediate_units: std.ArrayListUnmanaged([]const u8),
    user_functions: std.ArrayListUnmanaged(*const bytecode.UserFunction),
    /// Base offset for locally-defined functions (used to resolve func_id in nested scopes)
    user_functions_base: usize = 0,
    /// Pooled sub-VM reused across user-function calls (avoids re-allocating
    /// stacks/variable arrays on every call_user). One per nesting level.
    sub_vm_pool: ?*VM = null,
    thread_pool: if (is_wasm) void else ?*threading.Pool,
    prng: std.Random.DefaultPrng,
    debug_mode: bool = false,
    /// Source offset of the last error (for source mapping)
    last_error_offset: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, metadata_allocator: std.mem.Allocator, max_variables: usize, pool: if (is_wasm) void else ?*threading.Pool, config: *@import("../core/config.zig").Config) !VM {
        const vars = try allocator.alloc(Value, max_variables);
        @memset(vars, Value.initNumber(0));

        const vars_f64 = try allocator.alloc(f64, max_variables);
        @memset(vars_f64, 0);

        const vars_tags = try allocator.alloc(ValueTag, max_variables);
        @memset(vars_tags, .number);

        const stack = try allocator.alloc(Value, 4096);
        const stack_f64 = try allocator.alloc(f64, 4096);

        return .{
            .stack = stack,
            .sp = 0,
            .variables = vars,
            .stack_f64 = stack_f64,
            .variables_f64 = vars_f64,
            .variables_tags = vars_tags,
            .allocator = allocator,
            .metadata_allocator = metadata_allocator,
            .unit_registry = null,
            .config = config,
            .intermediate_objects = .{},
            .intermediate_units = .empty,
            .user_functions = .empty,
            .prng = std.Random.DefaultPrng.init(42),
            .thread_pool = pool,
        };
    }

    pub fn deinit(self: *VM) void {
        self.allocator.free(self.stack);
        self.allocator.free(self.stack_f64);

        // Release all values stored in variables (they were retained on setVariable)
        for (self.variables) |val| {
            val.release();
        }
        self.allocator.free(self.variables);
        self.allocator.free(self.variables_tags);
        self.allocator.free(self.variables_f64);

        // Release all tracked intermediate objects
        var it = self.intermediate_objects.valueIterator();
        while (it.next()) |obj| {
            obj.release();
        }
        self.intermediate_objects.deinit(self.allocator);

        // Note: Unit names are allocated from metadata_allocator (arena) and freed automatically
        self.intermediate_units.deinit(self.allocator);
        self.user_functions.deinit(self.allocator);

        if (self.sub_vm_pool) |sub| {
            sub.deinit();
            self.allocator.destroy(sub);
            self.sub_vm_pool = null;
        }
    }

    /// Acquire a sub-VM for a user-function call, reusing the pooled one when possible.
    fn acquireSubVM(self: *VM, max_vars: usize) !*VM {
        if (self.sub_vm_pool) |sub| {
            self.sub_vm_pool = null;
            if (sub.variables.len >= max_vars) return sub;
            sub.deinit();
            self.allocator.destroy(sub);
        }
        const sub = try self.allocator.create(VM);
        errdefer self.allocator.destroy(sub);
        sub.* = try VM.init(self.allocator, self.metadata_allocator, max_vars, self.thread_pool, self.config);
        return sub;
    }

    /// Bulk-copy the parent's variables into a freshly acquired sub-VM.
    /// Equivalent to calling setVariable for every slot — the sub-VM's slots
    /// are all pristine numbers after acquireSubVM, so there is nothing to
    /// release — but copies the three arrays directly and only walks the
    /// tags to retain non-number values.
    fn inheritVariablesFrom(sub: *VM, parent: *const VM) void {
        const n = parent.variables.len;
        @memcpy(sub.variables[0..n], parent.variables);
        @memcpy(sub.variables_f64[0..n], parent.variables_f64);
        @memcpy(sub.variables_tags[0..n], parent.variables_tags);
        for (parent.variables_tags, 0..) |tag, idx| {
            if (tag != .number) parent.variables[idx].retain();
        }
    }

    /// Return a sub-VM to the pool. Releases everything the sub-VM still
    /// references (exactly what deinit would release), so pooling does not
    /// extend any value lifetimes.
    fn releaseSubVM(self: *VM, sub: *VM) void {
        for (sub.variables_tags, 0..) |tag, idx| {
            if (tag != .number) sub.variables[idx].release();
        }
        @memset(sub.variables, Value.initNumber(0));
        @memset(sub.variables_f64, 0);
        @memset(sub.variables_tags, .number);
        sub.freeIntermediates();
        sub.user_functions.clearRetainingCapacity();
        sub.user_functions_base = 0;
        sub.unit_registry = null;
        sub.sp = 0;
        if (self.sub_vm_pool == null) {
            self.sub_vm_pool = sub;
        } else {
            sub.deinit();
            self.allocator.destroy(sub);
        }
    }

    /// Track a matrix for later cleanup (used for intermediate results)
    pub fn trackMatrix(self: *VM, matrix: *Matrix) void {
        self.intermediate_objects.put(self.allocator, @intFromPtr(matrix), .{ .matrix = matrix }) catch {};
    }

    pub fn trackSeries(self: *VM, series: *Series) void {
        self.intermediate_objects.put(self.allocator, @intFromPtr(series), .{ .series = series }) catch {};
    }

    pub fn trackRecord(self: *VM, record: *Record) void {
        self.intermediate_objects.put(self.allocator, @intFromPtr(record), .{ .record = record }) catch {};
    }

    pub fn trackSlice(self: *VM, slice: *val_module.Slice) void {
        self.intermediate_objects.put(self.allocator, @intFromPtr(slice), .{ .slice = slice }) catch {};
    }

    pub inline fn trackValue(self: *VM, val: Value) void {
        switch (val.tag) {
            .matrix => self.trackMatrix(val.data.matrix),
            .series => self.trackSeries(val.data.series),
            .record => self.trackRecord(val.data.record),
            .slice => self.trackSlice(val.data.slice),
            .unit => if (val.data.unit.info.name) |name| self.trackUnitName(name),
            else => {},
        }
    }

    pub fn trackUnitName(self: *VM, name: []const u8) void {
        self.intermediate_units.append(self.allocator, name) catch {};
    }

    /// Remove a matrix from tracking (used when returning result to caller)
    pub fn untrackMatrix(self: *VM, matrix: *Matrix) bool {
        return self.intermediate_objects.remove(@intFromPtr(matrix));
    }

    pub fn untrackSeries(self: *VM, series: *Series) bool {
        return self.intermediate_objects.remove(@intFromPtr(series));
    }

    pub fn untrackRecord(self: *VM, record: *Record) bool {
        return self.intermediate_objects.remove(@intFromPtr(record));
    }

    pub fn untrackSlice(self: *VM, slice: *val_module.Slice) bool {
        return self.intermediate_objects.remove(@intFromPtr(slice));
    }

    pub fn untrackUnitName(self: *VM, name: []const u8) void {
        var i: usize = 0;
        while (i < self.intermediate_units.items.len) {
            if (self.intermediate_units.items[i].ptr == name.ptr) {
                _ = self.intermediate_units.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Free all tracked intermediate objects
    pub fn freeIntermediates(self: *VM) void {
        var it = self.intermediate_objects.valueIterator();
        while (it.next()) |obj| {
            obj.release();
        }
        self.intermediate_objects.clearRetainingCapacity();

        // Note: Unit names are allocated from metadata_allocator (arena) and freed automatically
        self.intermediate_units.clearRetainingCapacity();
    }

    pub fn setVariable(self: *VM, index: usize, val: Value) void {
        std.debug.assert(index < self.variables.len);
        switch (val.tag) {
            .matrix => std.debug.assert(val.data.matrix.magic == 0x4D41545249583031),
            .series => std.debug.assert(val.data.series.magic == 0x5345524945533031),
            .record => std.debug.assert(val.data.record.magic == 0xDEADC0DE),
            else => {},
        }
        val.retain();
        const old_val = self.variables[index];
        old_val.release();
        // Note: Unit names are allocated from metadata_allocator (arena) and freed automatically

        self.variables[index] = val;
        self.variables_tags[index] = val.tag;
        // Keep f64 mirror in sync for fast-path
        self.variables_f64[index] = val.toNumber() orelse 0;
    }

    /// Set variable directly as f64 (fastest path)
    pub fn setVariableF64(self: *VM, index: usize, val: f64) void {
        std.debug.assert(index < self.variables.len);
        const old_val = self.variables[index];
        old_val.release();
        // Note: Unit names are allocated from metadata_allocator (arena) and freed automatically

        self.variables_f64[index] = val;
        self.variables_tags[index] = .number;
        self.variables[index] = Value.initNumber(val);
    }

    /// Invoke a user function with `args` (borrowed references, consumed
    /// before the body runs). Returns a value the caller owns one reference
    /// to, exactly like the historical sub-VM call path.
    fn invokeUser(self: *VM, func: *const bytecode.UserFunction, args: []const Value) VMError!Value {
        if (func.frame_ok and
            func.max_var_ref < self.variables.len and
            @as(usize, self.sp) + func.body.max_stack <= self.stack.len)
        {
            return self.invokeUserFrame(func, args);
        }
        return self.invokeUserSubVM(func, args);
    }

    const SavedVar = struct { val: Value, num: f64, tag: ValueTag };

    /// Frame-based call: the body runs on THIS VM, on the caller's stack at
    /// the current sp. Instead of copying all variable arrays into a sub-VM,
    /// only the slots the body can write (func.write_vars: param slots +
    /// store_var targets) are saved and restored, so variable rebinding stays
    /// function-local while reads see the caller's live variables — the same
    /// semantics the sub-VM's inherit/discard gave, minus the per-call
    /// memcpy of the whole arrays.
    fn invokeUserFrame(self: *VM, func: *const bytecode.UserFunction, args: []const Value) VMError!Value {
        const wv = func.write_vars;

        // Locally-defined functions resolve their ids relative to
        // user_functions_base; definitions made inside the body are
        // discarded afterwards (the sub-VM used to take a copy instead).
        const saved_fn_len = self.user_functions.items.len;
        const saved_fn_base = self.user_functions_base;
        self.user_functions_base = saved_fn_len;
        defer {
            self.user_functions.shrinkRetainingCapacity(saved_fn_len);
            self.user_functions_base = saved_fn_base;
        }

        var saved_buf: [16]SavedVar = undefined;
        const saved: []SavedVar = if (wv.len <= saved_buf.len)
            saved_buf[0..wv.len]
        else
            try self.allocator.alloc(SavedVar, wv.len);
        defer if (wv.len > saved_buf.len) self.allocator.free(saved);

        // Save every slot the body can write. Non-number values are retained
        // so a body store (which releases the slot's reference) cannot free
        // them before the restore below.
        for (wv, 0..) |idx, k| {
            const tag = self.variables_tags[idx];
            if (tag != .number) self.variables[idx].retain();
            saved[k] = .{ .val = self.variables[idx], .num = self.variables_f64[idx], .tag = tag };
        }
        defer for (wv, 0..) |idx, k| {
            // Release whatever the body left in the slot, then put the saved
            // value back (transferring our retain to the slot).
            if (self.variables_tags[idx] != .number) self.variables[idx].release();
            self.variables[idx] = saved[k].val;
            self.variables_f64[idx] = saved[k].num;
            self.variables_tags[idx] = saved[k].tag;
        };

        for (args, 0..) |arg, i| {
            self.setVariable(func.param_offset + i, arg);
        }

        if (func.body.is_number_only) {
            if (self.executeNumbersOnly(&func.body)) |num_res| {
                return Value.initNumber(num_res);
            }
        }
        if (func.body.fast_path_ok) {
            if (self.executeNumbersFast(&func.body)) |num_res| {
                return Value.initNumber(num_res);
            }
        }

        const frame_base = self.sp;
        const result = try self.executeFrame(&func.body, frame_base);
        self.sp = frame_base;

        // executeFrame retained the result once for us. A reference-type
        // result that is NOT in the intermediates tracker was not created
        // during the body (e.g. it is a caller variable's value); the caller
        // absorbs one reference into its tracker (trackValue after return),
        // so give it one — this mirrors the sub-VM path's retain-before-
        // release. Tracked results already carry their creation reference in
        // the tracker, so they need nothing extra.
        switch (result.tag) {
            .matrix => if (!self.intermediate_objects.contains(@intFromPtr(result.data.matrix))) result.retain(),
            .series => if (!self.intermediate_objects.contains(@intFromPtr(result.data.series))) result.retain(),
            .record => if (!self.intermediate_objects.contains(@intFromPtr(result.data.record))) result.retain(),
            .slice => if (!self.intermediate_objects.contains(@intFromPtr(result.data.slice))) result.retain(),
            else => {},
        }
        return result;
    }

    /// Pooled sub-VM call path (pre-frame behavior), used when the body
    /// references variable slots beyond this VM's arrays or the stack lacks
    /// headroom for a frame.
    fn invokeUserSubVM(self: *VM, func: *const bytecode.UserFunction, args: []const Value) VMError!Value {
        // We need enough space for ALL variables: local parameters may be
        // mapped to high indices (param_offset) when they shadow globals.
        const max_vars = @max(self.variables.len, func.param_offset + func.params.len + 64);
        const sub_vm = try self.acquireSubVM(max_vars);
        defer self.releaseSubVM(sub_vm);

        // Inherit user functions and set base offset for locally-defined functions
        try sub_vm.user_functions.appendSlice(self.allocator, self.user_functions.items);
        sub_vm.user_functions_base = sub_vm.user_functions.items.len;
        sub_vm.unit_registry = self.unit_registry;

        // Inherit current variables (globals/closure context)
        inheritVariablesFrom(sub_vm, self);

        // THE COMPILER maps params to param_offset, param_offset+1, ...
        for (args, 0..) |arg, i| {
            sub_vm.setVariable(func.param_offset + i, arg);
        }

        var result: Value = undefined;
        var fast_path_taken = false;

        if (func.body.is_number_only) {
            if (sub_vm.executeNumbersOnly(&func.body)) |num_res| {
                result = Value.initNumber(num_res);
                fast_path_taken = true;
            }
        }

        if (!fast_path_taken and func.body.fast_path_ok) {
            if (sub_vm.executeNumbersFast(&func.body)) |num_res| {
                result = Value.initNumber(num_res);
                fast_path_taken = true;
            }
        }

        if (!fast_path_taken) {
            result = try sub_vm.execute(&func.body);
        }

        // IMPORTANT: releaseSubVM releases all sub-VM variables; if the
        // result is one of those values we must retain it first.
        result.retain();
        return result;
    }

    pub fn execute(self: *VM, expr: *const CompiledExpr) VMError!Value {
        return self.executeFrame(expr, 0);
    }

    /// Interpreter core. `base` is the stack index this frame starts at:
    /// 0 for a top-level expression, the caller's sp for a frame-based user
    /// function call (see invokeUserFrame). Nested frames share the caller's
    /// intermediates tracker — it is only flushed when the outermost frame
    /// exits.
    fn executeFrame(self: *VM, expr: *const CompiledExpr, base_sp: u16) VMError!Value {
        std.debug.assert(@as(usize, base_sp) + expr.max_stack <= self.stack.len);
        self.sp = base_sp;
        self.last_error_offset = 0;
        var ip: usize = 0;

        defer if (base_sp == 0) self.freeIntermediates();

        // Capture source offset on error (ip-1 because ip was incremented before the switch)
        errdefer {
            const err_ip = if (ip > 0) ip - 1 else 0;
            self.last_error_offset = if (err_ip < expr.source_offsets.len) expr.source_offsets[err_ip] else 0;
        }

        // Auto-audit counter (see fetchNext: audits every 100 instructions in debug mode)
        var instr_count: usize = 0;

        const code = expr.code;
        if (code.len == 0) return Value.initUndefined();
        // The compiler always terminates code with halt, and every jump target
        // stays in bounds (optimizeBytecode remaps them), so the threaded
        // dispatch below never fetches past the end.
        std.debug.assert(code[code.len - 1].opcode == .halt);

        // Threaded dispatch: each arm fetches the next instruction and
        // re-dispatches via `continue :dispatch`, giving every opcode its own
        // indirect branch (better prediction than one shared loop branch).
        var instr = self.fetchNext(expr, &ip, &instr_count);
        dispatch: switch (instr.opcode) {
            .push_const => {
                try self.push(expr.constants[instr.operand]);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .pop => {
                if (self.sp == 0) return error.StackUnderflow;
                self.sp -= 1;
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .dup => {
                try self.push((try self.peek()));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_var => {
                const idx = instr.operand;
                if (idx >= self.variables.len) return error.IndexOutOfBounds;
                try self.push(self.variables[idx]);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .store_var => {
                const idx = instr.operand;
                if (idx >= self.variables.len) return error.IndexOutOfBounds;
                const val = (try self.pop());
                self.setVariable(idx, val);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .call_user => {
                // Decode: bits 0-14 = func_id, bit 15 = is_local flag, bits 16-23 = arg_count
                const func_id: u16 = @truncate(instr.operand & 0x7FFF);
                const is_local: bool = (instr.operand & 0x8000) != 0;
                const arg_count: u8 = @truncate((instr.operand >> 16) & 0xFF);

                // Apply base offset only for locally-defined functions (nested function calls)
                const actual_id = if (is_local) self.user_functions_base + func_id else func_id;
                if (actual_id >= self.user_functions.items.len) return error.UnknownFunction;
                const func = self.user_functions.items[actual_id];

                if (arg_count != func.params.len) return error.NotEnoughArgs;

                // Arguments stay in their stack slots as borrowed references;
                // invokeUser copies them into the parameter slots before the
                // body can overwrite this stack region.
                if (self.sp < arg_count) return error.StackUnderflow;
                self.sp -= arg_count;
                const args = self.stack[self.sp .. self.sp + arg_count];

                const result = try self.invokeUser(func, args);
                try self.push(result);
                self.trackValue(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .def_user => {
                const const_idx = instr.operand;
                const val = expr.constants[const_idx];
                if (val.tag != .function) return error.TypeError;
                try self.user_functions.append(self.allocator, val.data.function.user_func.?);
                try self.push(Value.initBoolean(true)); // Definition returns true
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .add => {
                // In place: read both operands through pointers, write the
                // result into the lhs slot (avoids three 56-byte copies)
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                // Fast path: same computation as Value.add's number+number case
                if (a.tag == .number and b.tag == .number) {
                    a.data.number = a.data.number + b.data.number;
                    instr = self.fetchNext(expr, &ip, &instr_count);
                    continue :dispatch instr.opcode;
                }
                const result = Value.add(a.*, b.*);
                self.trackValue(result);
                a.* = result;
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .sub => {
                // In place: read both operands through pointers, write the
                // result into the lhs slot (avoids three 56-byte copies)
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                // Fast path: same computation as Value.sub's number+number case
                if (a.tag == .number and b.tag == .number) {
                    a.data.number = a.data.number - b.data.number;
                    instr = self.fetchNext(expr, &ip, &instr_count);
                    continue :dispatch instr.opcode;
                }
                const result = Value.sub(a.*, b.*);
                self.trackValue(result);
                a.* = result;
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .mul => {
                if (self.sp < 2) return error.StackUnderflow;
                const a_ptr = &self.stack[self.sp - 2];
                const b_ptr = &self.stack[self.sp - 1];
                // Fast path: same computation as Value.mul's number+number case
                if (a_ptr.tag == .number and b_ptr.tag == .number) {
                    a_ptr.data.number = a_ptr.data.number * b_ptr.data.number;
                    self.sp -= 1;
                    instr = self.fetchNext(expr, &ip, &instr_count);
                    continue :dispatch instr.opcode;
                }
                const b = (try self.pop());
                const a = (try self.pop());

                var result: Value = undefined;

                if (a.tag == .matrix and b.tag == .matrix) {
                    const ma = a.data.matrix;
                    const mb = b.data.matrix;

                    if (ma.cols == mb.rows) {
                        const res = try Matrix.init(self.allocator, ma.rows, mb.cols);
                        self.trackMatrix(res);
                        const kernels = @import("../functions/matrix_kernels.zig");
                        if (comptime !is_wasm) {
                            if (self.thread_pool) |pool| {
                                kernels.gemmParallel(pool, ma.rows, ma.cols, mb.cols, ma.data, ma.stride, mb.data, mb.stride, res.data, res.stride);
                            } else {
                                kernels.gemm(ma.rows, ma.cols, mb.cols, ma.data, ma.stride, mb.data, mb.stride, res.data, res.stride);
                            }
                        } else {
                            kernels.gemm(ma.rows, ma.cols, mb.cols, ma.data, ma.stride, mb.data, mb.stride, res.data, res.stride);
                        }
                        result = .{ .tag = .matrix, .data = .{ .matrix = res } };
                    } else {
                        return error.MismatchedDimensions;
                    }
                } else {
                    result = Value.mul(a, b, self.metadata_allocator);
                    self.trackValue(result);
                }

                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .div => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                // Fast path: same computation as Value.div's number+number
                // case (incl. its custom division-by-zero handling)
                if (a.tag == .number and b.tag == .number) {
                    const an = a.data.number;
                    const bn = b.data.number;
                    a.data.number = if (bn == 0)
                        (if (an > 0) std.math.inf(f64) else if (an < 0) -std.math.inf(f64) else std.math.nan(f64))
                    else
                        an / bn;
                    instr = self.fetchNext(expr, &ip, &instr_count);
                    continue :dispatch instr.opcode;
                }
                const result = Value.div(a.*, b.*, self.metadata_allocator);
                self.trackValue(result);
                a.* = result;
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .emul => {
                const b = (try self.pop());
                const a = (try self.pop());
                const result = Value.emul(a, b, self.metadata_allocator);
                self.trackValue(result);
                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .ediv => {
                const b = (try self.pop());
                const a = (try self.pop());
                const result = Value.ediv(a, b, self.metadata_allocator);
                self.trackValue(result);
                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .epow => {
                const b = (try self.pop());
                const a = (try self.pop());
                const result = Value.epow(a, b, self.metadata_allocator);
                self.trackValue(result);
                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .mod => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                // Fast path: same computation as Value.mod's number case
                if (a.tag == .number and b.tag == .number) {
                    a.data.number = val_module.euclideanMod(a.data.number, b.data.number);
                    instr = self.fetchNext(expr, &ip, &instr_count);
                    continue :dispatch instr.opcode;
                }
                a.* = Value.mod(a.*, b.*);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .pow => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                // Fast path for small integer exponents with number types
                if (a.tag == .number and b.tag == .number) {
                    const base = a.data.number;
                    const exp = b.data.number;
                    if (std.math.isFinite(exp) and exp >= 0 and exp <= 10) {
                        const int_exp = @as(i32, @intFromFloat(exp));
                        if (@as(f64, @floatFromInt(int_exp)) == exp) {
                            var res_val: f64 = 1.0;
                            var i: i32 = 0;
                            while (i < int_exp) : (i += 1) {
                                res_val *= base;
                            }
                            a.data.number = res_val;
                            instr = self.fetchNext(expr, &ip, &instr_count);
                            continue :dispatch instr.opcode;
                        }
                    }
                }
                a.* = Value.pow(a.*, b.*);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .fma => {
                const c = (try self.pop());
                const b = (try self.pop());
                const a = (try self.pop());
                // Basic fma implementation for Value
                const prod = Value.mul(a, b, self.metadata_allocator);
                if (prod.tag == .matrix) self.trackMatrix(prod.data.matrix);
                if (prod.tag == .unit) {
                    if (prod.data.unit.info.name) |name| self.trackUnitName(name);
                }
                const result = Value.add(prod, c);
                if (result.tag == .matrix) self.trackMatrix(result.data.matrix);
                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .fma_var_const_const => {
                const var_idx: u8 = @truncate(instr.operand & 0xFF);
                const c1_idx: u8 = @truncate((instr.operand >> 8) & 0xFF);
                const c2_idx: u8 = @truncate((instr.operand >> 16) & 0xFF);

                // The builder caps these at 255, but variables.len is
                // caller-chosen and may be smaller — check like .load_var.
                if (var_idx >= self.variables.len) return error.IndexOutOfBounds;
                if (c1_idx >= expr.constants.len or c2_idx >= expr.constants.len) return error.IndexOutOfBounds;

                const x = self.variables[var_idx];
                const a = expr.constants[c1_idx];
                const b = expr.constants[c2_idx];

                const prod = Value.mul(x, a, self.metadata_allocator);
                if (prod.tag == .matrix) self.trackMatrix(prod.data.matrix);
                if (prod.tag == .unit) {
                    if (prod.data.unit.info.name) |name| self.trackUnitName(name);
                }
                const result = Value.add(prod, b);
                if (result.tag == .matrix) self.trackMatrix(result.data.matrix);
                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .unit_convert => {
                const target = (try self.pop());
                const source = (try self.pop());
                if (source.tag == .unit and target.tag == .unit) {
                    if (source.data.unit.info.dimensions.equals(target.data.unit.info.dimensions)) {
                        // Formula: (normalized_value - target_offset) / target_scale
                        const target_scale = target.data.unit.value - target.data.unit.info.offset;
                        const res = (source.data.unit.value - target.data.unit.info.offset) / target_scale;
                        try self.push(Value.initNumber(res));
                    } else {
                        try self.push(Value.initError(2)); // Dimension mismatch
                    }
                } else if (source.tag == .number and target.tag == .unit) {
                    const target_scale = target.data.unit.value - target.data.unit.info.offset;
                    const res = source.data.number * target_scale + target.data.unit.info.offset;
                    try self.push(Value.initUnitFull(res, target_scale, target.data.unit.info.offset, target.data.unit.info.dimensions, target.data.unit.info.name));
                } else if (source.tag == .matrix and target.tag == .unit) {
                    // Matrix elements are SI magnitudes (homogeneous matrix*unit
                    // scale, or plain numeric mat_create). Unit-bearing literals
                    // are rejected at mat_create / mat_create_3.
                    // Convert each element to the target unit: (si - offset) / scale.
                    try self.push(try self.convertMatrixSiToUnit(source.data.matrix, target));
                } else {
                    try self.push(Value.initError(1)); // Type error
                }
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .neg => {
                const a = (try self.pop());
                const result = Value.neg(a);
                self.trackValue(result);
                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .pos => {
                // No-op for numbers
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .eq => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const result = if (a.toNumber()) |an| if (b.toNumber()) |bn| an == bn else false else false;
                a.* = Value.initBoolean(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .ne => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const result = if (a.toNumber()) |an| if (b.toNumber()) |bn| an != bn else true else true;
                a.* = Value.initBoolean(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .lt => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const result = if (a.toNumber()) |an| if (b.toNumber()) |bn| an < bn else false else false;
                a.* = Value.initBoolean(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .le => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const result = if (a.toNumber()) |an| if (b.toNumber()) |bn| an <= bn else false else false;
                a.* = Value.initBoolean(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .gt => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const result = if (a.toNumber()) |an| if (b.toNumber()) |bn| an > bn else false else false;
                a.* = Value.initBoolean(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .ge => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const result = if (a.toNumber()) |an| if (b.toNumber()) |bn| an >= bn else false else false;
                a.* = Value.initBoolean(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .and_ => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const ab = if (a.tag == .boolean) a.data.boolean else (a.toNumber() orelse 0) != 0;
                const bb = if (b.tag == .boolean) b.data.boolean else (b.toNumber() orelse 0) != 0;
                a.* = Value.initBoolean(ab and bb);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .or_ => {
                if (self.sp < 2) return error.StackUnderflow;
                const a = &self.stack[self.sp - 2];
                const b = &self.stack[self.sp - 1];
                self.sp -= 1;
                const ab = if (a.tag == .boolean) a.data.boolean else (a.toNumber() orelse 0) != 0;
                const bb = if (b.tag == .boolean) b.data.boolean else (b.toNumber() orelse 0) != 0;
                a.* = Value.initBoolean(ab or bb);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .not_ => {
                if (self.sp == 0) return error.StackUnderflow;
                const a = &self.stack[self.sp - 1];
                const ab = if (a.tag == .boolean) a.data.boolean else (a.toNumber() orelse 0) != 0;
                a.* = Value.initBoolean(!ab);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .band, .bor, .bxor, .shl, .shr => {
                // Bitwise operations - convert to integers
                const b = (try self.pop());
                const a = (try self.pop());
                const ai: u64 = @bitCast(safeFloatToInt(a.toNumber() orelse 0));
                const bi: u64 = @bitCast(safeFloatToInt(b.toNumber() orelse 0));
                const result: u64 = switch (instr.opcode) {
                    .band => ai & bi,
                    .bor => ai | bi,
                    .bxor => ai ^ bi,
                    .shl => ai << @intCast(@mod(bi, 64)),
                    .shr => ai >> @intCast(@mod(bi, 64)),
                    else => unreachable,
                };
                try self.push(Value.initNumber(@floatFromInt(@as(i64, @bitCast(result)))));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .bnot => {
                const a = (try self.pop());
                const ai: u64 = @bitCast(safeFloatToInt(a.toNumber() orelse 0));
                const res: u64 = ~ai;
                try self.push(Value.initNumber(@floatFromInt(@as(i64, @bitCast(res)))));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .call_builtin => {
                const func_id: u16 = @truncate(instr.operand & 0xFFFF);
                const arg_count: u8 = @truncate((instr.operand >> 16) & 0xFF);
                try self.callBuiltin(@enumFromInt(func_id), arg_count, null);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .call_builtin_where => {
                const func_id: u16 = @truncate(instr.operand & 0xFFFF);
                const arg_count: u8 = @truncate((instr.operand >> 16) & 0xFF);
                const pred_val = (try self.pop());
                if (!pred_val.isPredicate()) return error.TypeError;

                try self.callBuiltin(@enumFromInt(func_id), arg_count, pred_val.data.predicate);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .mat_create => {
                // operand: rows (12) | cols (12)
                const rows: u32 = @as(u32, instr.operand & 0xFFF);
                const cols: u32 = @as(u32, (instr.operand >> 12) & 0xFFF);
                const n_cells: u32 = rows * cols;

                // Reject unit-bearing elements before allocation (honest:
                // no matrix-of-units type; same error as mat_create_3).
                if (self.sp < n_cells) return error.StackUnderflow;
                var ui: u32 = 0;
                while (ui < n_cells) : (ui += 1) {
                    if (self.stack[self.sp - 1 - ui].tag == .unit)
                        return error.MatrixUnitElementUnsupported;
                }

                const mat = try Matrix.init(self.allocator, rows, cols);
                self.trackMatrix(mat);
                // Pop values from stack in reverse order
                var r: u32 = rows;
                while (r > 0) {
                    r -= 1;
                    var c: u32 = cols;
                    while (c > 0) {
                        c -= 1;
                        const val = (try self.pop());
                        mat.set(r, c, val.toNumber() orelse 0);
                    }
                }
                try self.push(.{ .tag = .matrix, .data = .{ .matrix = mat } });
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .jmp => {
                ip = instr.operand;
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .jmp_if_false => {
                if (self.sp == 0) return error.StackUnderflow;
                self.sp -= 1;
                const cond = &self.stack[self.sp];
                const is_false = if (cond.tag == .boolean) !cond.data.boolean else (cond.toNumber() orelse 0) == 0;
                if (is_false) {
                    ip = instr.operand;
                }
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .jmp_if_true => {
                if (self.sp == 0) return error.StackUnderflow;
                self.sp -= 1;
                const cond = &self.stack[self.sp];
                const is_true = if (cond.tag == .boolean) cond.data.boolean else (cond.toNumber() orelse 0) != 0;
                if (is_true) {
                    ip = instr.operand;
                }
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .halt => {},

            .nop => {
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_var_index_0 => {
                const idx = instr.operand;
                try self.executeLoadVarIndex(idx, Value.initNumber(0));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_var_index_1 => {
                const idx = instr.operand;
                try self.executeLoadVarIndex(idx, Value.initNumber(1));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_var_index_2 => {
                const idx = instr.operand;
                try self.executeLoadVarIndex(idx, Value.initNumber(2));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_var_index_3 => {
                const idx = instr.operand;
                try self.executeLoadVarIndex(idx, Value.initNumber(3));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_var_index_const => {
                const var_idx = instr.operand & 0xFFF;
                const const_idx = (instr.operand >> 12) & 0xFFF;
                try self.executeLoadVarIndex(var_idx, expr.constants[const_idx]);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_mul => {
                const var_a = instr.operand & 0xFFF;
                const var_b = (instr.operand >> 12) & 0xFFF;
                if (var_a >= self.variables.len or var_b >= self.variables.len) return error.IndexOutOfBounds;
                if (self.variables_tags[var_a] != .number or self.variables_tags[var_b] != .number) {
                    // Variable rebound to a non-number since compilation:
                    // the f64 mirror is meaningless, do the un-fused op.
                    const result = Value.mul(self.variables[var_a], self.variables[var_b], self.metadata_allocator);
                    self.trackValue(result);
                    try self.push(result);
                } else {
                    const a = self.variables_f64[var_a];
                    const b = self.variables_f64[var_b];
                    try self.push(Value.initNumber(a * b));
                }
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .load_sub => {
                const var_a = instr.operand & 0xFFF;
                const var_b = (instr.operand >> 12) & 0xFFF;
                if (var_a >= self.variables.len or var_b >= self.variables.len) return error.IndexOutOfBounds;
                if (self.variables_tags[var_a] != .number or self.variables_tags[var_b] != .number) {
                    const result = Value.sub(self.variables[var_a], self.variables[var_b]);
                    self.trackValue(result);
                    try self.push(result);
                } else {
                    const a = self.variables_f64[var_a];
                    const b = self.variables_f64[var_b];
                    try self.push(Value.initNumber(a - b));
                }
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .const_mul => {
                const c = expr.constants_f64[instr.operand];
                const a = (try self.pop());
                if (a.tag != .number) return error.TypeError;
                try self.push(Value.initNumber(a.data.number * c));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .mat_create_3 => {
                const c = (try self.pop());
                const b = (try self.pop());
                const a = (try self.pop());
                // Stable identity shared with mat_create (task-15/D6): unit
                // elements are not TypeError — they are MatrixUnitElementUnsupported.
                if (a.tag == .unit or b.tag == .unit or c.tag == .unit)
                    return error.MatrixUnitElementUnsupported;
                if (a.tag != .number or b.tag != .number or c.tag != .number) return error.TypeError;

                const mat = try Matrix.init(self.allocator, 3, 1);
                mat.data[0] = a.data.number;
                mat.data[1] = b.data.number;
                mat.data[2] = c.data.number;
                const res = Value.initMatrix(mat);
                self.trackMatrix(mat);
                try self.push(res);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .rec_create => {
                const field_count = instr.operand;
                const record = try Record.initCapacity(self.allocator, self.metadata_allocator, field_count);
                self.trackRecord(record);

                var i: u24 = 0;
                while (i < field_count) : (i += 1) {
                    const key_val = (try self.pop());
                    const field_val = (try self.pop());

                    if (key_val.tag != .string) {
                        threading.debugPrint("rec_create FAILURE: Expected .string, got {any}. Value tag: {any}\n", .{ key_val.tag, field_val.tag });
                        return error.TypeError;
                    }

                    const key = key_val.data.string.toSlice();

                    // Only release if we took ownership from intermediate tracking.
                    // If it was a variable, we are borrowing the reference from the variable map.
                    var owned = false;
                    if (field_val.tag == .matrix) owned = self.untrackMatrix(field_val.data.matrix);
                    if (field_val.tag == .series) owned = self.untrackSeries(field_val.data.series);
                    if (field_val.tag == .record) owned = self.untrackRecord(field_val.data.record);
                    if (field_val.tag == .slice) owned = self.untrackSlice(field_val.data.slice);

                    try record.setOwned(key, field_val);

                    if (owned) {
                        field_val.release();
                    }
                }
                try self.push(Value.initRecord(record));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .rec_get => {
                const field_name_idx = instr.operand;
                std.debug.assert(field_name_idx < expr.constants.len);
                const field_name_val = expr.constants[field_name_idx];
                std.debug.assert(field_name_val.tag == .string);

                const field_name = field_name_val.data.string.toSlice();

                const record_val = (try self.pop());
                if (record_val.tag != .record) {
                    return error.TypeError;
                }

                const record = record_val.data.record;
                std.debug.assert(record.magic == 0xDEADC0DE);
                const field_value = record.get(field_name) orelse Value.initUndefined();

                // For reference types retrieved from a record, we need to retain before tracking.
                // This is because the record already owns the value, and we're getting a shared reference.
                // freeIntermediates will release our temporary reference, not the record's reference.
                field_value.retain();
                self.trackValue(field_value);

                try self.push(field_value);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .rec_get_dyn => {
                const field_name_val = (try self.pop());
                const record_val = (try self.pop());

                if (record_val.tag == .record) {
                    if (field_name_val.tag != .string) {
                        return error.TypeError;
                    }
                    const field_name = field_name_val.data.string.toSlice();
                    const record = record_val.data.record;
                    std.debug.assert(record.magic == 0xDEADC0DE);

                    const field_value = record.get(field_name) orelse Value.initUndefined();

                    // For reference types retrieved from a record, we need to retain before tracking.
                    // This is because the record already owns the value, and we're getting a shared reference.
                    // freeIntermediates will release our temporary reference, not the record's reference.
                    field_value.retain();
                    self.trackValue(field_value);

                    try self.push(field_value);
                } else if (record_val.tag == .series) {
                    const idx_f = field_name_val.toNumber() orelse return error.TypeError;
                    const s = record_val.data.series;
                    std.debug.assert(s.magic == 0x5345524945533031);
                    // NaN/negative/huge indexes are out of bounds, not UB.
                    if (std.math.isFinite(idx_f) and idx_f >= 0 and idx_f < @as(f64, @floatFromInt(s.len))) {
                        try self.push(Value.initNumber(s.values[@intFromFloat(idx_f)]));
                    } else {
                        try self.push(Value.initUndefined());
                    }
                } else {
                    return error.TypeError;
                }
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .make_slice => {
                const step = (try self.pop());
                const end = (try self.pop());
                const start = (try self.pop());
                const s = try val_module.Slice.init(self.allocator, start, end, step);
                self.trackSlice(s);
                try self.push(Value.initSlice(s));
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            .get_index => {
                const count: usize = instr.operand;
                if (count > 1024) return error.InvalidIndexCount;
                var keys_stack: [4]Value = undefined;
                var keys_heap: ?[]Value = null;
                defer if (keys_heap) |buf| self.allocator.free(buf);
                const keys: []Value = if (count <= keys_stack.len)
                    keys_stack[0..count]
                else blk: {
                    const buf = try self.allocator.alloc(Value, count);
                    keys_heap = buf;
                    break :blk buf;
                };

                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    keys[i] = (try self.pop());
                }

                const object = (try self.pop());
                // We don't own object from pop unless we retained it earlier when pushing?
                // VM stack values are owned by stack or tracked intermediate.
                // We just use it.

                const result = try self.getIndex(object, keys);

                // Track result if it's a new object or we retained it
                self.trackValue(result);
                try self.push(result);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },
            .set_index => {
                const count: usize = instr.operand;
                if (count > 1024) return error.InvalidIndexCount;
                const value = (try self.pop());

                var keys_stack: [4]Value = undefined;
                var keys_heap: ?[]Value = null;
                defer if (keys_heap) |buf| self.allocator.free(buf);
                const keys: []Value = if (count <= keys_stack.len)
                    keys_stack[0..count]
                else blk: {
                    const buf = try self.allocator.alloc(Value, count);
                    keys_heap = buf;
                    break :blk buf;
                };

                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    keys[i] = (try self.pop());
                }

                const object = (try self.pop());
                _ = try self.setIndex(object, keys, value);

                // Assignment expression result is the assigned value.
                try self.push(value);
                instr = self.fetchNext(expr, &ip, &instr_count);
                continue :dispatch instr.opcode;
            },

            else => {
                // Unimplemented opcode
                return error.UnimplementedOpcode;
            },
        }

        if (self.sp > base_sp) {
            const result = (try self.pop());
            // Caller owns the result, so we retain it.
            // The tracker still has a reference which will be released via defer freeIntermediates().
            result.retain();

            if (result.tag == .unit) {
                if (result.data.unit.info.name) |name| self.untrackUnitName(name);
            }
            return result;
        }
        return Value.initUndefined();
    }

    pub fn callBuiltin(self: *VM, func: BuiltinFn, arg_count: u8, predicate: ?*const Predicate) !void {
        switch (func) {
            .abs => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.isNumber()) {
                    try self.push(Value.initNumber(@abs(a.data.number)));
                } else if (a.isComplex()) {
                    try self.push(Value.initNumber(a.data.complex.abs()));
                } else if (a.isUnit()) {
                    var res = a;
                    res.data.unit.value = @abs(a.data.unit.value);
                    try self.push(res);
                } else return error.TypeError;
            },
            .sqrt => {
                if (arg_count < 1) return error.NotEnoughArgs;
                if (arg_count == 1) {
                    const a = (try self.pop());
                    try self.push(Value.sqrt(a));
                } else {
                    const n = (try self.pop()).toNumber() orelse return error.TypeError;
                    const a = (try self.pop()).toNumber() orelse return error.TypeError;
                    try self.push(Value.initNumber(std.math.pow(f64, a, 1.0 / n)));
                }
            },
            .nthRoot => {
                if (arg_count < 1) return error.NotEnoughArgs;
                if (arg_count == 1) {
                    const a = (try self.pop()).toNumber() orelse return error.TypeError;
                    try self.push(Value.initNumber(@sqrt(a)));
                } else {
                    const n = (try self.pop()).toNumber() orelse return error.TypeError;
                    const a = (try self.pop()).toNumber() orelse return error.TypeError;
                    try self.push(Value.initNumber(std.math.pow(f64, a, 1.0 / n)));
                }
            },
            .cbrt => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.cbrt(n)));
            },
            .sin => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                var n = a.toNumber() orelse return error.TypeError;
                if (self.config.angles == .degrees) n = n * (std.math.pi / 180.0);
                try self.push(Value.initNumber(@sin(n)));
            },
            .cos => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                var n = a.toNumber() orelse return error.TypeError;
                if (self.config.angles == .degrees) n = n * (std.math.pi / 180.0);
                try self.push(Value.initNumber(@cos(n)));
            },
            .tan => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                var n = a.toNumber() orelse return error.TypeError;
                if (self.config.angles == .degrees) n = n * (std.math.pi / 180.0);
                try self.push(Value.initNumber(@tan(n)));
            },
            .asin => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                var res = std.math.asin(n);
                if (self.config.angles == .degrees) res = res * (180.0 / std.math.pi);
                try self.push(Value.initNumber(res));
            },
            .acos => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                var res = std.math.acos(n);
                if (self.config.angles == .degrees) res = res * (180.0 / std.math.pi);
                try self.push(Value.initNumber(res));
            },
            .atan => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                var res = std.math.atan(n);
                if (self.config.angles == .degrees) res = res * (180.0 / std.math.pi);
                try self.push(Value.initNumber(res));
            },
            .atan2 => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const b = (try self.pop());
                const a = (try self.pop());
                const an = a.toNumber() orelse return error.TypeError;
                const bn = b.toNumber() orelse return error.TypeError;
                var res = std.math.atan2(an, bn);
                if (self.config.angles == .degrees) res = res * (180.0 / std.math.pi);
                try self.push(Value.initNumber(res));
            },
            .erf => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(statistics.erf(n)));
            },
            .agg_range => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const s = a.toSeries() orelse return error.TypeError;

                try self.push(Value.initNumber(aggregations.range(s, predicate)));
            },
            .gen_range => {
                var start: f64 = 0;
                var end: f64 = 0;
                var step: f64 = 1;
                var is_temporal = false;

                if (arg_count == 1) {
                    const val = (try self.pop());
                    if (val.tag == .string or val.tag == .unit) is_temporal = true;
                    end = val.toTimestamp() orelse return error.TypeError;
                } else if (arg_count == 2) {
                    const v_end = (try self.pop());
                    const v_start = (try self.pop());
                    if (v_end.tag == .string or v_end.tag == .unit or v_start.tag == .string or v_start.tag == .unit) is_temporal = true;
                    end = v_end.toTimestamp() orelse return error.TypeError;
                    start = v_start.toTimestamp() orelse return error.TypeError;
                } else if (arg_count == 3) {
                    const v_step = (try self.pop());
                    const v_end = (try self.pop());
                    const v_start = (try self.pop());
                    if (v_step.tag == .string or v_step.tag == .unit or v_end.tag == .string or v_end.tag == .unit or v_start.tag == .string or v_start.tag == .unit) is_temporal = true;
                    step = v_step.toNumber() orelse return error.TypeError;
                    end = v_end.toTimestamp() orelse return error.TypeError;
                    start = v_start.toTimestamp() orelse return error.TypeError;
                } else {
                    return error.WrongArgumentCount;
                }

                const val = if (is_temporal)
                    try generators.rangeSeries(start, end, step, self.allocator)
                else
                    try generators.range(start, end, step, self.allocator);
                self.trackValue(val);
                try self.push(val);
            },
            .linspace => {
                if (arg_count != 3) return error.WrongArgumentCount;
                const v_count = (try self.pop());
                const v_end = (try self.pop());
                const v_start = (try self.pop());

                const is_temporal = (v_end.tag == .string or v_end.tag == .unit or v_start.tag == .string or v_start.tag == .unit);
                const count_val = v_count.toNumber() orelse return error.TypeError;
                const end = v_end.toTimestamp() orelse return error.TypeError;
                const start = v_start.toTimestamp() orelse return error.TypeError;

                const count = try checkedUint(usize, count_val);
                if (count > max_alloc_elements) return error.ResultTooLarge;
                const val = if (is_temporal)
                    try generators.linspaceSeries(start, end, count, self.allocator)
                else
                    try generators.linspace(start, end, count, self.allocator);
                self.trackValue(val);
                try self.push(val);
            },
            .logspace => {
                if (arg_count != 3) return error.WrongArgumentCount;
                const count_val = (try self.pop()).toNumber() orelse return error.TypeError;
                const end = (try self.pop()).toNumber() orelse return error.TypeError;
                const start = (try self.pop()).toNumber() orelse return error.TypeError;

                const count = try checkedUint(usize, count_val);
                if (count > max_alloc_elements) return error.ResultTooLarge;
                const val = try generators.logspace(start, end, count, self.allocator);
                self.trackValue(val);
                try self.push(val);
            },
            .now => {
                if (arg_count != 0) return error.WrongArgumentCount;
                try self.push(Value.initNumber(temporal.now()));
            },
            .ode_solve => {
                if (arg_count != 4) return error.WrongArgumentCount;
                const dt = (try self.pop()).toNumber() orelse return error.TypeError;
                const t_span = (try self.pop());
                const y0 = (try self.pop());
                const deriv_func = (try self.pop());

                const res = try @import("../functions/ode.zig").ode_solve(self, deriv_func, y0, t_span, dt);
                try self.push(res);
            },
            .ode_solve_euler => {
                if (arg_count != 4) return error.WrongArgumentCount;
                const dt = (try self.pop()).toNumber() orelse return error.TypeError;
                const t_span = (try self.pop());
                const y0 = (try self.pop());
                const deriv_func = (try self.pop());

                const res = try @import("../functions/ode.zig").ode_solve_euler(self, deriv_func, y0, t_span, dt);
                try self.push(res);
            },

            .lgamma => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.lgamma(f64, n)));
            },
            .gamma => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.gamma(f64, n)));
            },
            .sinh => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.sinh(n)));
            },
            .cosh => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.cosh(n)));
            },
            .tanh => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.tanh(n)));
            },
            .sec => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(1.0 / @cos(n)));
            },
            .csc => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(1.0 / @sin(n)));
            },
            .cot => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(1.0 / @tan(n)));
            },
            .asec => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.acos(1.0 / n)));
            },
            .acsc => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.asin(1.0 / n)));
            },
            .acot => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.atan(1.0 / n)));
            },
            .exp => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.isNumber()) {
                    try self.push(Value.initNumber(@exp(a.data.number)));
                } else if (a.isComplex()) {
                    const r = @exp(a.data.complex.re);
                    const theta = a.data.complex.im;
                    try self.push(Value.initComplex(r * @cos(theta), r * @sin(theta)));
                } else if (a.isUnit()) {
                    // Argument to exp must be dimensionless
                    if (!a.data.unit.info.dimensions.isScalar()) return error.TypeError;
                    try self.push(Value.initNumber(@exp(a.data.unit.value)));
                } else return error.TypeError;
            },
            .log => {
                if (arg_count < 1) return error.NotEnoughArgs;
                if (arg_count == 1) {
                    const a = (try self.pop());
                    const n = a.toNumber() orelse return error.TypeError;
                    try self.push(Value.initNumber(@log(n)));
                } else {
                    const base = (try self.pop()).toNumber() orelse return error.TypeError;
                    const x = (try self.pop()).toNumber() orelse return error.TypeError;
                    try self.push(Value.initNumber(@log(x) / @log(base)));
                }
            },
            .log10 => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(@log10(n)));
            },
            .log2 => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(@log2(n)));
            },
            .floor => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(@floor(n)));
            },
            .ceil => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(@ceil(n)));
            },
            .round => {
                if (arg_count < 1) return error.NotEnoughArgs;
                // round(x) or round(x, decimals) — MathJS-compatible decimal places
                if (arg_count >= 2) {
                    const d_val = try self.pop();
                    const a = try self.pop();
                    const x = a.toNumber() orelse return error.TypeError;
                    const decimals = d_val.toNumber() orelse return error.TypeError;
                    try self.push(Value.initNumber(roundToDecimals(x, decimals)));
                } else {
                    const a = try self.pop();
                    const n = a.toNumber() orelse return error.TypeError;
                    try self.push(Value.initNumber(@round(n)));
                }
            },
            .trunc => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(@trunc(n)));
            },
            .sign => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                if (n > 0) try self.push(Value.initNumber(1)) else if (n < 0) try self.push(Value.initNumber(-1)) else try self.push(Value.initNumber(0));
            },
            .square => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(n * n));
            },
            .cube => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(n * n * n));
            },
            .log1p => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.log1p(n)));
            },
            .expm1 => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.expm1(n)));
            },
            .asinh => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.asinh(n)));
            },
            .acosh => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.acosh(n)));
            },
            .atanh => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.atanh(n)));
            },
            .sech => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(1.0 / std.math.cosh(n)));
            },
            .csch => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(1.0 / std.math.sinh(n)));
            },
            .coth => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(1.0 / std.math.tanh(n)));
            },
            .asech => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.acosh(1.0 / n)));
            },
            .acsch => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.asinh(1.0 / n)));
            },
            .acoth => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(std.math.atanh(1.0 / n)));
            },
            .combinations => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const k = (try self.pop());
                const n = (try self.pop());
                const kn = k.toNumber() orelse return error.TypeError;
                const nn = n.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(@import("../functions/number_theory.zig").combinations(nn, kn)));
            },
            .permutations => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const k = (try self.pop());
                const n = (try self.pop());
                const kn = k.toNumber() orelse return error.TypeError;
                const nn = n.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(@import("../functions/number_theory.zig").permutations(nn, kn)));
            },
            .mad => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const res = try @import("../functions/statistics.zig").matrixMad(a.data.matrix, self.allocator);
                    try self.push(Value.initNumber(res));
                } else {
                    try self.push(Value.initNumber(0));
                }
            },
            .min => {
                if (arg_count < 1) return error.NotEnoughArgs;
                if (arg_count == 1) {
                    const a = (try self.pop());
                    if (a.tag == .series) {
                        try self.push(Value.initNumber(@import("../timeseries/aggregations.zig").min(a.data.series, predicate)));
                    } else if (a.tag == .matrix) {
                        try self.push(Value.initNumber(@import("../functions/matrix_kernels.zig").vecMin(a.data.matrix.data)));
                    } else try self.push(a);
                } else if (arg_count >= 2) {
                    const b = (try self.pop());
                    const a = (try self.pop());
                    const an = a.toNumber() orelse return error.TypeError;

                    const bn = b.toNumber() orelse return error.TypeError;

                    try self.push(Value.initNumber(@min(an, bn)));
                } else return error.NotEnoughArgs;
            },
            .max => {
                if (arg_count < 1) return error.NotEnoughArgs;
                if (arg_count == 1) {
                    const a = (try self.pop());
                    if (a.tag == .series) {
                        try self.push(Value.initNumber(@import("../timeseries/aggregations.zig").max(a.data.series, predicate)));
                    } else if (a.tag == .matrix) {
                        try self.push(Value.initNumber(@import("../functions/matrix_kernels.zig").vecMax(a.data.matrix.data)));
                    } else try self.push(a);
                } else if (arg_count >= 2) {
                    const b = (try self.pop());
                    const a = (try self.pop());
                    const an = a.toNumber() orelse return error.TypeError;

                    const bn = b.toNumber() orelse return error.TypeError;

                    try self.push(Value.initNumber(@max(an, bn)));
                } else return error.NotEnoughArgs;
            },
            .clamp => {
                if (arg_count < 3) return error.NotEnoughArgs;
                const high = (try self.pop());
                const low = (try self.pop());
                const val = (try self.pop());
                const vn = val.toNumber() orelse return error.TypeError;

                const ln = low.toNumber() orelse return error.TypeError;

                const hn = high.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.clamp(vn, ln, hn)));
            },
            .hypot => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const b = (try self.pop());
                const a = (try self.pop());
                const an = a.toNumber() orelse return error.TypeError;

                const bn = b.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(std.math.hypot(an, bn)));
            },
            .norm => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const m = a.data.matrix;
                    const res = @import("../functions/matrix_kernels.zig").vecNorm(m.data);
                    try self.push(Value.initNumber(res));
                } else if (a.toNumber()) |n| {
                    try self.push(Value.initNumber(@abs(n)));
                } else return error.TypeError;
            },
            .re => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.isComplex()) {
                    try self.push(Value.initNumber(a.data.complex.re));
                } else if (a.isNumber()) {
                    try self.push(a);
                } else return error.TypeError;
            },
            .im => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.isComplex()) {
                    try self.push(Value.initNumber(a.data.complex.im));
                } else if (a.isNumber()) {
                    try self.push(Value.initNumber(0));
                } else return error.TypeError;
            },
            .arg => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.isComplex()) {
                    try self.push(Value.initNumber(a.data.complex.arg()));
                } else if (a.isNumber()) {
                    try self.push(Value.initNumber(if (a.data.number >= 0) 0 else std.math.pi));
                } else return error.TypeError;
            },
            .conj => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.isComplex()) {
                    try self.push(Value.initComplex(a.data.complex.re, -a.data.complex.im));
                } else if (a.isNumber()) {
                    try self.push(a);
                } else return error.TypeError;
            },
            .det => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag != .matrix) return error.TypeError;

                const m = a.data.matrix;
                if (m.rows != m.cols) return error.MismatchedDimensions;
                const res = try @import("../functions/matrix_kernels.zig").determinant(m.rows, m.data, m.stride, self.allocator);
                try self.push(Value.initNumber(res));
            },
            .inv => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag != .matrix) return error.TypeError;

                const m = a.data.matrix;
                if (m.rows != m.cols) return error.MismatchedDimensions;
                const res = try Matrix.init(self.allocator, m.rows, m.cols);
                self.trackMatrix(res);
                @memcpy(res.data, m.data);
                const success = try @import("../functions/matrix_kernels.zig").matrixInverse(m.rows, res.data, res.stride, self.allocator);
                if (!success) return error.SingularMatrix;
                try self.push(.{ .tag = .matrix, .data = .{ .matrix = res } });
            },
            .transpose => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag != .matrix) return error.TypeError;

                const m = a.data.matrix;
                const res = try Matrix.init(self.allocator, m.cols, m.rows);
                self.trackMatrix(res);
                for (0..m.rows) |r| {
                    for (0..m.cols) |c| {
                        res.set(@intCast(c), @intCast(r), m.get(@intCast(r), @intCast(c)));
                    }
                }
                try self.push(.{ .tag = .matrix, .data = .{ .matrix = res } });
            },
            .gemv => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const x_val = (try self.pop());
                const a_val = (try self.pop());
                if (a_val.tag != .matrix or x_val.tag != .matrix) return error.TypeError;

                const ma = a_val.data.matrix;
                const mx = x_val.data.matrix;

                // For GEMV, mx must be a vector (1 column or 1 row)
                const x_len = if (mx.rows == 1) mx.cols else if (mx.cols == 1) mx.rows else return error.MismatchedDimensions;
                if (ma.cols != x_len) return error.MismatchedDimensions;

                const res = try Matrix.init(self.allocator, ma.rows, 1);
                self.trackMatrix(res);
                @import("../functions/matrix_kernels.zig").gemvSimple(ma.rows, ma.cols, ma.data, ma.stride, mx.data, res.data);
                try self.push(.{ .tag = .matrix, .data = .{ .matrix = res } });
            },
            .random => {
                const rand = self.prng.random();
                if (arg_count == 0) {
                    try self.push(Value.initNumber(rand.float(f64)));
                } else if (arg_count == 1) {
                    const max_val = (try self.pop()).toNumber() orelse return error.TypeError;

                    var rf = rand.float(f64);
                    // Extremely rare edge case where float() might return 1.0 depending on implementation
                    while (rf >= 1.0) rf = rand.float(f64);
                    try self.push(Value.initNumber(rf * max_val));
                } else {
                    const max_val = (try self.pop()).toNumber() orelse return error.TypeError;

                    const min_val = (try self.pop()).toNumber() orelse return error.TypeError;

                    const real_min = @min(min_val, max_val);
                    const real_max = @max(min_val, max_val);
                    var rf = rand.float(f64);
                    while (rf >= 1.0) rf = rand.float(f64);
                    try self.push(Value.initNumber(real_min + rf * (real_max - real_min)));
                }
            },
            .randomInt => {
                const rand = self.prng.random();
                if (arg_count == 0) {
                    try self.push(Value.initNumber(@floatFromInt(rand.uintLessThan(u64, 100))));
                } else if (arg_count == 1) {
                    const max_val = try checkedUint(u64, (try self.pop()).toNumber() orelse return error.TypeError);
                    if (max_val == 0) return error.InvalidArgument;
                    try self.push(Value.initNumber(@floatFromInt(rand.uintLessThan(u64, max_val))));
                } else {
                    const max_val_f = (try self.pop()).toNumber() orelse return error.TypeError;

                    const min_val_f = (try self.pop()).toNumber() orelse return error.TypeError;

                    const min_val = try checkedInt(i64, min_val_f);
                    const max_val = try checkedInt(i64, max_val_f);

                    const actual_min = @min(min_val, max_val);
                    const actual_max = @max(min_val, max_val);

                    if (actual_max <= actual_min) {
                        try self.push(Value.initNumber(@floatFromInt(actual_min)));
                    } else {
                        // Widen: maxInt(i64) - minInt(i64) overflows i64.
                        const range = @as(u64, @intCast(@as(i128, actual_max) - actual_min));
                        const r_val = actual_min + @as(i64, @intCast(rand.uintLessThan(u64, range)));
                        try self.push(Value.initNumber(@floatFromInt(r_val)));
                    }
                }
            },
            .pickRandom => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const rand = self.prng.random();
                if (a.tag == .matrix) {
                    const m = a.data.matrix;
                    const total_elements = m.rows * m.cols;
                    if (total_elements == 0) {
                        try self.push(Value.initNull());
                    } else {
                        const idx = rand.uintLessThan(usize, total_elements);
                        const r = @as(u32, @intCast(idx / m.cols));
                        const c = @as(u32, @intCast(idx % m.cols));
                        try self.push(Value.initNumber(m.get(r, c)));
                    }
                } else if (a.tag == .series) {
                    const s = a.data.series;
                    if (s.len == 0) {
                        try self.push(Value.initNull());
                    } else {
                        const idx = rand.uintLessThan(usize, s.len);
                        try self.push(Value.initNumber(s.values[idx]));
                    }
                } else {
                    try self.push(a); // Scalar fallback
                }
            },
            .factorial => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;

                try self.push(Value.initNumber(@import("../functions/number_theory.zig").factorial(n)));
            },
            .conv, .number => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const target = (try self.pop());
                const source = (try self.pop());
                if (source.tag == .unit and target.tag == .unit) {
                    if (source.data.unit.info.dimensions.equals(target.data.unit.info.dimensions)) {
                        // Formula: (normalized_value - target_offset) / target_scale
                        const target_scale = target.data.unit.value - target.data.unit.info.offset;
                        const res = (source.data.unit.value - target.data.unit.info.offset) / target_scale;
                        try self.push(Value.initNumber(res));
                    } else {
                        try self.push(Value.initError(2)); // Dimension mismatch
                    }
                } else if (source.tag == .number and target.tag == .unit) {
                    const target_scale = target.data.unit.value - target.data.unit.info.offset;
                    const res = source.data.number * target_scale + target.data.unit.info.offset;
                    try self.push(Value.initUnitFull(res, target_scale, target.data.unit.info.offset, target.data.unit.info.dimensions, target.data.unit.info.name));
                } else if (source.tag == .matrix and target.tag == .unit) {
                    // Matrix elements are SI magnitudes (numeric mat_create or
                    // homogeneous matrix*unit). Unit-bearing literals are rejected.
                    // Convert each element to the target unit: (si - offset) / scale.
                    try self.push(try self.convertMatrixSiToUnit(source.data.matrix, target));
                } else {
                    try self.push(Value.initError(1)); // Type error
                }
            },
            .read_csv => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const mapping_val = (try self.pop());
                const path_val = (try self.pop());

                if (path_val.tag != .string or mapping_val.tag != .record) return error.TypeError;

                const path = path_val.data.string.toSlice();
                const mapping = mapping_val.data.record;

                const result = try csv.readCsv(self.allocator, self.metadata_allocator, path, mapping, .{});
                self.trackRecord(result);
                try self.push(Value.initRecord(result));
            },
            .write_csv => {
                if (arg_count < 2) return error.NotEnoughArgs;

                var opt_record: csv.CsvOptions = .{};
                if (arg_count >= 3) {
                    const opt_val = (try self.pop());
                    if (opt_val.tag == .record) {
                        const r = opt_val.data.record;
                        if (r.fields.get("delimiter")) |v| {
                            if (v.tag == .string and v.data.string.len > 0) {
                                opt_record.delimiter = v.data.string.ptr[0];
                            }
                        }
                        if (r.fields.get("header")) |v| {
                            if (v.tag == .boolean) {
                                opt_record.has_header = v.data.boolean;
                            }
                        }
                    }
                }

                const data = (try self.pop());
                const path_val = (try self.pop());

                if (path_val.tag != .string) return error.TypeError;
                const path = path_val.data.string.toSlice();

                try csv.writeCsv(path, data, opt_record);
                try self.push(Value.initBoolean(true));
            },
            .assert => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const expected = (try self.pop());
                const actual = (try self.pop());
                if (!actual.equals(expected)) {
                    // We don't have a good way to format expected/actual here easily without allocation
                    // but we can return an error.
                    return error.AssertionFailed;
                }
                try self.push(Value.initBoolean(true));
            },
            .mean => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .series) {
                    try self.push(Value.initNumber(@import("../timeseries/aggregations.zig").mean(a.data.series, predicate)));
                } else if (a.tag == .matrix) {
                    try self.push(Value.initNumber(@import("../functions/matrix_kernels.zig").vecMean(a.data.matrix.data)));
                } else {
                    try self.push(a); // Return as is for scalars
                }
            },
            .median => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const res = try @import("../functions/statistics.zig").matrixMedian(a.data.matrix, self.allocator);
                    try self.push(Value.initNumber(res));
                } else {
                    try self.push(a);
                }
            },
            .std => {
                if (arg_count < 1) return error.NotEnoughArgs;
                var biased = false;
                if (arg_count >= 2) {
                    const norm_val = (try self.pop());
                    if (norm_val.tag == .string) {
                        const norm = norm_val.data.string.toSlice();
                        if (std.mem.eql(u8, norm, "biased")) {
                            biased = true;
                        }
                    }
                }
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const stats = @import("../functions/statistics.zig");
                    const res = if (biased) stats.matrixStddevBiased(a.data.matrix) else stats.matrixStddev(a.data.matrix);
                    try self.push(Value.initNumber(res));
                } else {
                    try self.push(Value.initNumber(0));
                }
            },
            .variance => {
                if (arg_count < 1) return error.NotEnoughArgs;
                var biased = false;
                if (arg_count >= 2) {
                    const norm_val = (try self.pop());
                    if (norm_val.tag == .string) {
                        const norm = norm_val.data.string.toSlice();
                        if (std.mem.eql(u8, norm, "biased")) {
                            biased = true;
                        }
                    }
                }
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const stats = @import("../functions/statistics.zig");
                    const res = if (biased) stats.matrixVarianceBiased(a.data.matrix) else stats.matrixVariance(a.data.matrix);
                    try self.push(Value.initNumber(res));
                } else {
                    try self.push(Value.initNumber(0));
                }
            },
            .prod => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const res = @import("../functions/matrix_kernels.zig").vecProd(a.data.matrix.data);
                    try self.push(Value.initNumber(res));
                } else {
                    try self.push(a);
                }
            },
            .gcd => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const b = (try self.pop());
                const a = (try self.pop());
                const an = a.toNumber() orelse return error.TypeError;
                const bn = b.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(@import("../functions/number_theory.zig").gcd(an, bn)));
            },
            .lcm => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const b = (try self.pop());
                const a = (try self.pop());
                const an = a.toNumber() orelse return error.TypeError;
                const bn = b.toNumber() orelse return error.TypeError;
                try self.push(Value.initNumber(@import("../functions/number_theory.zig").lcm(an, bn)));
            },
            .isPrime => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                const n = a.toNumber() orelse return error.TypeError;
                try self.push(Value.initBoolean(@import("../functions/number_theory.zig").isPrime(n)));
            },
            .trace => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const m = a.data.matrix;
                    const data = m.data[m.offset..][0 .. m.rows * m.cols];
                    try self.push(Value.initNumber(@import("../functions/matrix_kernels.zig").matrixTrace(m.rows, m.cols, data, m.stride)));
                } else {
                    try self.push(a);
                }
            },
            .reshape => {
                if (arg_count < 3) return error.NotEnoughArgs;
                const cols = try checkedUint(u32, (try self.pop()).toNumber() orelse return error.TypeError);
                const rows = try checkedUint(u32, (try self.pop()).toNumber() orelse return error.TypeError);
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    try a.data.matrix.reshape(rows, cols);
                    try self.push(a);
                } else {
                    return error.TypeError;
                }
            },
            .flatten => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    try a.data.matrix.flatten();
                    try self.push(a);
                } else {
                    try self.push(a);
                }
            },
            .concat => {
                if (arg_count < 2) return error.NotEnoughArgs;
                var dim: u32 = 0;
                var b_val: Value = undefined;
                var a_val: Value = undefined;

                if (arg_count == 3) {
                    const dim_val = (try self.pop());
                    dim = try checkedUint(u32, dim_val.toNumber() orelse return error.TypeError);
                    b_val = (try self.pop());
                    a_val = (try self.pop());
                } else {
                    // Default dim 0
                    b_val = (try self.pop());
                    a_val = (try self.pop());
                }

                if (a_val.tag == .matrix and b_val.tag == .matrix) {
                    const ma = a_val.data.matrix;
                    const mb = b_val.data.matrix;

                    var res: *Matrix = undefined;

                    if (dim == 0) {
                        // Vertical (rows)
                        if (ma.cols != mb.cols) return error.MismatchedDimensions;
                        res = try Matrix.init(self.allocator, ma.rows + mb.rows, ma.cols);
                        for (0..ma.rows) |r| {
                            for (0..ma.cols) |c| res.set(@intCast(r), @intCast(c), ma.get(@intCast(r), @intCast(c)));
                        }
                        for (0..mb.rows) |r| {
                            for (0..mb.cols) |c| res.set(ma.rows + @as(u32, @intCast(r)), @as(u32, @intCast(c)), mb.get(@intCast(r), @intCast(c)));
                        }
                    } else {
                        // Horizontal (cols)
                        if (ma.rows != mb.rows) return error.MismatchedDimensions;
                        res = try Matrix.init(self.allocator, ma.rows, ma.cols + mb.cols);
                        for (0..ma.rows) |r| {
                            for (0..ma.cols) |c| res.set(@intCast(r), @intCast(c), ma.get(@intCast(r), @intCast(c)));
                        }
                        for (0..mb.rows) |r| {
                            for (0..mb.cols) |c| res.set(@intCast(r), ma.cols + @as(u32, @intCast(c)), mb.get(@intCast(r), @intCast(c)));
                        }
                    }
                    self.trackMatrix(res);
                    try self.push(Value.initMatrix(res));
                } else {
                    return error.TypeError;
                }
            },
            .diag => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .matrix) {
                    const res = try a.data.matrix.getDiagonal(self.allocator);
                    self.trackMatrix(res);
                    try self.push(.{ .tag = .matrix, .data = .{ .matrix = res } });
                } else {
                    return error.TypeError;
                }
            },
            .identity => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const n = try checkedUint(u32, (try self.pop()).toNumber() orelse return error.TypeError);
                try checkedMatrixDims(n, n);
                const res = try Matrix.init(self.allocator, n, n);
                self.trackMatrix(res);
                for (0..n) |i| res.set(@intCast(i), @intCast(i), 1.0);
                try self.push(.{ .tag = .matrix, .data = .{ .matrix = res } });
            },
            .zeros => {
                if (arg_count < 1) return error.NotEnoughArgs;
                var rows: u32 = 0;
                var cols: u32 = 0;
                if (arg_count >= 2) {
                    const c_val = (try self.pop());
                    const r_val = (try self.pop());
                    rows = try checkedUint(u32, r_val.toNumber() orelse return error.TypeError);
                    cols = try checkedUint(u32, c_val.toNumber() orelse return error.TypeError);
                } else {
                    rows = try checkedUint(u32, (try self.pop()).toNumber() orelse return error.TypeError);
                    cols = rows;
                }
                try checkedMatrixDims(rows, cols);
                const res = try Matrix.init(self.allocator, rows, cols);
                self.trackMatrix(res);
                try self.push(.{ .tag = .matrix, .data = .{ .matrix = res } });
            },
            .ones => {
                if (arg_count < 1) return error.NotEnoughArgs;
                var rows: u32 = 0;
                var cols: u32 = 0;
                if (arg_count >= 2) {
                    const c_val = (try self.pop());
                    const r_val = (try self.pop());
                    rows = try checkedUint(u32, r_val.toNumber() orelse return error.TypeError);
                    cols = try checkedUint(u32, c_val.toNumber() orelse return error.TypeError);
                } else {
                    rows = try checkedUint(u32, (try self.pop()).toNumber() orelse return error.TypeError);
                    cols = rows;
                }
                try checkedMatrixDims(rows, cols);
                const res = try Matrix.init(self.allocator, rows, cols);
                self.trackMatrix(res);
                @memset(res.data, 1.0);
                try self.push(.{ .tag = .matrix, .data = .{ .matrix = res } });
            },
            .dot => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const b = (try self.pop());
                const a = (try self.pop());
                if (a.tag == .matrix and b.tag == .matrix) {
                    const ma = a.data.matrix;
                    const mb = b.data.matrix;
                    const da = ma.data[ma.offset..][0 .. ma.rows * ma.cols];
                    const db = mb.data[mb.offset..][0 .. mb.rows * mb.cols];
                    try self.push(Value.initNumber(@import("../functions/matrix_kernels.zig").vecDot(da, db)));
                } else {
                    try self.push(Value.mul(a, b, self.metadata_allocator)); // Fallback to normal mul
                }
            },
            .cross => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const b = (try self.pop());
                const a = (try self.pop());
                if (a.tag == .matrix and b.tag == .matrix) {
                    const ma = a.data.matrix;
                    const mb = b.data.matrix;
                    const da = ma.data[ma.offset..][0 .. ma.rows * ma.cols];
                    const db = mb.data[mb.offset..][0 .. mb.rows * mb.cols];
                    const res_data = @import("../functions/matrix_kernels.zig").vecCross(da, db);

                    const res_mat = try Matrix.init(self.allocator, 3, 1);
                    self.trackMatrix(res_mat);
                    @memcpy(res_mat.data[0..3], &res_data);
                    try self.push(.{ .tag = .matrix, .data = .{ .matrix = res_mat } });
                } else {
                    return error.TypeError;
                }
            },
            .sum => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const a = (try self.pop());
                if (a.tag == .series) {
                    try self.push(Value.initNumber(@import("../timeseries/aggregations.zig").sum(a.data.series, predicate)));
                } else if (a.tag == .matrix) {
                    try self.push(Value.initNumber(@import("../functions/matrix_kernels.zig").vecSum(a.data.matrix.data)));
                } else try self.push(a);
            },
            .series, .twa, .cumsum, .cummax, .cummin, .rolling_sum, .rolling_mean, .rolling_min, .rolling_max, .rolling_count, .rolling_stddev, .derivative, .integrate, .sma, .ema, .rsi, .last, .duration, .asofJoin, .resample, .align_, .head, .tail, .slice, .between, .since, .shift, .dropna, .fillna, .clip, .size, .diff, .pct_change, .bollinger, .macd, .count => {
                if (arg_count < 1) return error.NotEnoughArgs;
                var args: [4]Value = undefined;
                if (arg_count > 4) return error.TooManyArgs;

                // Pop args in reverse order (stack is LIFO)
                var i: usize = arg_count;
                while (i > 0) {
                    i -= 1;
                    args[i] = (try self.pop());
                }

                const result = try ts_bindings.callTimeSeriesFn(func, args[0..arg_count], predicate, self.metadata_allocator);
                self.trackValue(result);

                // Special case for matrix.size - return record instead of series
                if (func == .size and result.tag == .undefined) {
                    const a = args[0];
                    if (a.tag == .matrix) {
                        const size_val = try Record.init(self.allocator, self.metadata_allocator);
                        errdefer size_val.release();

                        try size_val.setOwned("rows", Value.initNumber(@floatFromInt(a.data.matrix.rows)));
                        try size_val.setOwned("cols", Value.initNumber(@floatFromInt(a.data.matrix.cols)));

                        const size_rec_val = Value.initRecord(size_val);
                        self.trackValue(size_rec_val);
                        try self.push(size_rec_val);
                    } else {
                        try self.push(result);
                    }
                } else {
                    try self.push(result);
                }
            },
            .toLaTeX => {
                if (arg_count < 1) return error.NotEnoughArgs;
                const source_val = (try self.pop());
                defer source_val.release();
                if (source_val.tag != .string) return error.TypeError;
                const source = source_val.data.string.toSlice();

                var compiler = try @import("../parser/compiler.zig").Compiler.initWithConfig(
                    self.allocator,
                    source,
                    self.config,
                );
                defer compiler.deinit();
                if (self.unit_registry) |registry| compiler.registry = registry;
                compiler.metadata_allocator = self.metadata_allocator;

                const latex = compiler.toLaTeX(self.metadata_allocator) catch return error.RuntimeError;
                try self.push(Value{
                    .tag = .string,
                    .data = .{ .string = .{ .ptr = latex.ptr, .len = @intCast(latex.len) } },
                });
            },
            .create_unit => {
                if (arg_count < 2) return error.NotEnoughArgs;
                const base_val = (try self.pop());
                const name_val = (try self.pop());

                if (name_val.tag != .string) return error.TypeError;
                const name = name_val.data.string.toSlice();

                const registry = self.unit_registry orelse return error.RuntimeError;

                if (base_val.tag == .unit) {
                    const u = base_val.data.unit;
                    // If the base is a UnitValue (result of an expression like 50000 * USD),
                    // its 'value' is the normalized magnitude.
                    // We want the new unit to have this magnitude as its scale.
                    const new_scale = u.value - u.info.offset;
                    try registry.addUnitWithOffset(name, u.info.dimensions, new_scale, u.info.offset);
                } else if (base_val.isNumber()) {
                    try registry.addUnit(name, .{}, base_val.data.number);
                } else {
                    return error.TypeError;
                }

                try self.push(Value.initBoolean(true));
            },
            .config => {
                if (arg_count == 0) {
                    // Return current config as record
                    const rec = try Record.init(self.allocator, self.metadata_allocator);
                    self.trackRecord(rec);

                    const angle_str = if (self.config.angles == .radians) "radians" else "degrees";
                    const angle_val = try self.metadata_allocator.dupe(u8, angle_str);
                    try rec.setOwned("angles", Value{ .tag = .string, .data = .{ .string = .{ .ptr = angle_val.ptr, .len = @intCast(angle_val.len) } } });

                    const row_sep = try self.metadata_allocator.alloc(u8, 1);
                    row_sep[0] = self.config.row_separator;
                    try rec.setOwned("row_separator", Value{ .tag = .string, .data = .{ .string = .{ .ptr = row_sep.ptr, .len = 1 } } });

                    try self.push(Value.initRecord(rec));
                } else {
                    const opt_val = (try self.pop());
                    if (opt_val.tag != .record) return error.TypeError;
                    const r = opt_val.data.record;

                    if (r.fields.get("angles")) |v| {
                        if (v.tag == .string) {
                            const mode = v.data.string.toSlice();
                            if (std.mem.eql(u8, mode, "radians")) {
                                self.config.angles = .radians;
                            } else if (std.mem.eql(u8, mode, "degrees")) {
                                self.config.angles = .degrees;
                            }
                        }
                    }
                    if (r.fields.get("row_separator")) |v| {
                        if (v.tag == .string and v.data.string.len > 0) {
                            self.config.row_separator = v.data.string.ptr[0];
                        }
                    }
                    try self.push(Value.initBoolean(true));
                }
            },
        }
    }

    /// Fetch the next instruction for execute()'s threaded-dispatch loop.
    /// Debug tracing / periodic auditing lives here so every
    /// `continue :dispatch` site stays a two-liner.
    inline fn fetchNext(self: *VM, expr: *const CompiledExpr, ip: *usize, instr_count: *usize) bytecode.Instruction {
        const instr = expr.code[ip.*];
        if (self.debug_mode) {
            @branchHint(.unlikely);
            self.traceInstruction(ip.*, instr, expr);
            // Auto-audit: check VM integrity periodically
            instr_count.* += 1;
            if (instr_count.* % 100 == 0) self.audit();
        }
        ip.* += 1;
        return instr;
    }

    pub inline fn push(self: *VM, val: Value) VMError!void {
        if (self.sp >= self.stack.len) return error.StackOverflow;
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    pub inline fn pop(self: *VM) VMError!Value {
        if (self.sp == 0) return error.StackUnderflow;
        self.sp -= 1;
        return self.stack[self.sp];
    }

    inline fn peek(self: *VM) VMError!Value {
        if (self.sp == 0) return error.StackUnderflow;
        return self.stack[self.sp - 1];
    }

    /// Cap for user-specified allocation sizes (zeros/ones/identity/linspace…):
    /// 100M f64 elements ≈ 800 MB.
    const max_alloc_elements: u64 = 100_000_000;

    /// Strict f64 → unsigned integer for user-supplied counts, dimensions and
    /// indices. Rejects NaN/inf/negative/out-of-range instead of hitting
    /// @intFromFloat safety-checked illegal behavior. Fractional values are
    /// truncated (matches the previous @intFromFloat behavior for valid input).
    fn checkedUint(comptime T: type, n: f64) VMError!T {
        if (!std.math.isFinite(n) or n < 0) return error.InvalidArgument;
        if (n >= @as(f64, @floatFromInt(std.math.maxInt(T))) + 1) return error.InvalidArgument;
        return @intFromFloat(@trunc(n));
    }

    /// Signed variant of checkedUint.
    fn checkedInt(comptime T: type, n: f64) VMError!T {
        if (!std.math.isFinite(n)) return error.InvalidArgument;
        const limit = @as(f64, @floatFromInt(std.math.maxInt(T))) + 1;
        if (n >= limit or n < -limit) return error.InvalidArgument;
        return @intFromFloat(@trunc(n));
    }

    /// Value.div's number-case semantics: x/0 resolved by the numerator's
    /// sign (a -0.0 divisor behaves like +0, unlike IEEE division).
    inline fn divNumberSemantics(a: f64, b: f64) f64 {
        if (b == 0) {
            return if (a > 0) std.math.inf(f64) else if (a < 0) -std.math.inf(f64) else std.math.nan(f64);
        }
        return a / b;
    }

    fn checkedMatrixDims(rows: u32, cols: u32) VMError!void {
        if (@as(u64, rows) * @as(u64, cols) > max_alloc_elements) return error.ResultTooLarge;
    }

    fn safeFloatToInt(f: f64) i64 {
        if (!std.math.isFinite(f)) return 0;
        if (f >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
        if (f <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
        return @intFromFloat(f);
    }

    inline fn fastPowIfSmallInt(base: f64, exp: f64) ?f64 {
        if (!std.math.isFinite(exp)) return null;
        if (exp < -10.0 or exp > 10.0) return null;
        const int_exp: i32 = @intFromFloat(exp);
        if (@as(f64, @floatFromInt(int_exp)) != exp) return null;

        return switch (int_exp) {
            0 => 1.0,
            1 => base,
            2 => base * base,
            3 => base * base * base,
            -1 => 1.0 / base,
            -2 => 1.0 / (base * base),
            -3 => 1.0 / (base * base * base),
            else => blk: {
                var n: i32 = if (int_exp < 0) -int_exp else int_exp;
                var b = base;
                var acc: f64 = 1.0;
                while (n > 0) : (n >>= 1) {
                    if ((n & 1) != 0) acc *= b;
                    b *= b;
                }
                break :blk if (int_exp < 0) 1.0 / acc else acc;
            },
        };
    }

    /// FAST PATH: Batch evaluation using SIMD (AVX/NEON/WASM SIMD128)
    /// Processes inputs in groups of 4 (Vec)
    /// UNSAFE: Caller must ensure all pointers are valid and aligned
    pub fn executeBatchSIMD(
        self: *VM,
        expr: *const CompiledExpr,
        var_index: u24,
        inputs: []const f64,
        outputs: []f64,
        count: usize,
    ) void {
        if (expr.max_stack > 64) return; // Vector stack size limit
        const code = expr.code;
        const vec_inputs = @as([*]const Vec, @ptrCast(@alignCast(inputs.ptr)));
        const vec_outputs = @as([*]Vec, @ptrCast(@alignCast(outputs.ptr)));

        var i: usize = 0;
        const UnrollFactor = 4;
        const vec_unrolled_count = count / (VectorLen * UnrollFactor);

        // Setup SIMD stack outside the loops to avoid repeated allocation
        var stack_vec: [64]Vec = undefined;

        while (i < vec_unrolled_count) : (i += 1) {
            const base_idx = i * UnrollFactor;

            inline for (0..UnrollFactor) |u| {
                var sp: u8 = 0;
                var ip: usize = 0;

                const input_vec = vec_inputs[base_idx + u];

                // Hot unrolling of the interpreter loop for small expressions
                // This significantly reduces branch mispredictions in WASM
                while (true) {
                    const instr = code[ip];
                    ip += 1;

                    switch (instr.opcode) {
                        .push_const => {
                            stack_vec[sp] = @splat(expr.constants_f64[instr.operand]);
                            sp += 1;
                        },

                        .load_var => {
                            if (instr.operand == var_index) {
                                stack_vec[sp] = input_vec;
                            } else {
                                stack_vec[sp] = @splat(self.variables_f64[instr.operand]);
                            }
                            sp += 1;
                        },

                        .add => {
                            stack_vec[sp - 2] = stack_vec[sp - 2] + stack_vec[sp - 1];
                            sp -= 1;
                        },

                        .sub => {
                            stack_vec[sp - 2] = stack_vec[sp - 2] - stack_vec[sp - 1];
                            sp -= 1;
                        },

                        .mul => {
                            stack_vec[sp - 2] = stack_vec[sp - 2] * stack_vec[sp - 1];
                            sp -= 1;
                        },

                        .div => {
                            // NOTE: plain IEEE division; diverges from Value.div only
                            // for a -0.0 divisor (vector branch not worth the cost here).
                            stack_vec[sp - 2] = stack_vec[sp - 2] / stack_vec[sp - 1];
                            sp -= 1;
                        },

                        .neg => {
                            stack_vec[sp - 1] = -stack_vec[sp - 1];
                        },

                        .pow => {
                            // SIMD pow requires scalar fallback for each lane
                            const base = stack_vec[sp - 2];
                            const exp = stack_vec[sp - 1];
                            var result: Vec = undefined;
                            inline for (0..VectorLen) |lane| {
                                result[lane] = fastPowIfSmallInt(base[lane], exp[lane]) orelse std.math.pow(f64, base[lane], exp[lane]);
                            }
                            stack_vec[sp - 2] = result;
                            sp -= 1;
                        },

                        .fma => {
                            stack_vec[sp - 3] = @mulAdd(Vec, stack_vec[sp - 3], stack_vec[sp - 2], stack_vec[sp - 1]);
                            sp -= 2;
                        },

                        .fma_var_const_const => {
                            const var_idx: u8 = @truncate(instr.operand & 0xFF);
                            const c1_idx: u8 = @truncate((instr.operand >> 8) & 0xFF);
                            const c2_idx: u8 = @truncate((instr.operand >> 16) & 0xFF);

                            const x = if (var_idx == var_index) input_vec else @as(Vec, @splat(self.variables_f64[var_idx]));
                            const a = @as(Vec, @splat(expr.constants_f64[c1_idx]));
                            const b = @as(Vec, @splat(expr.constants_f64[c2_idx]));

                            stack_vec[sp] = @mulAdd(Vec, x, a, b);
                            sp += 1;
                        },

                        .load_mul => {
                            const var_a = instr.operand & 0xFFF;
                            const var_b = (instr.operand >> 12) & 0xFFF;
                            const a = if (var_a == var_index) input_vec else @as(Vec, @splat(self.variables_f64[var_a]));
                            const b = if (var_b == var_index) input_vec else @as(Vec, @splat(self.variables_f64[var_b]));
                            stack_vec[sp] = a * b;
                            sp += 1;
                        },

                        .load_sub => {
                            const var_a = instr.operand & 0xFFF;
                            const var_b = (instr.operand >> 12) & 0xFFF;
                            const a = if (var_a == var_index) input_vec else @as(Vec, @splat(self.variables_f64[var_a]));
                            const b = if (var_b == var_index) input_vec else @as(Vec, @splat(self.variables_f64[var_b]));
                            stack_vec[sp] = a - b;
                            sp += 1;
                        },

                        .const_mul => {
                            const c = expr.constants_f64[instr.operand];
                            stack_vec[sp - 1] *= @as(Vec, @splat(c));
                        },

                        .eval_poly => {
                            // Operand encoding: bits 0-15 = var_index, bits 16-23 = coeff_count
                            const var_idx: u16 = @truncate(instr.operand & 0xFFFF);
                            const coeff_count: u8 = @truncate((instr.operand >> 16) & 0xFF);
                            const x = if (var_idx == var_index) input_vec else @as(Vec, @splat(self.variables_f64[var_idx]));

                            // Horner's method: result = c0; for ci in 1..n: result = result * x + c[ci]
                            var result = @as(Vec, @splat(expr.constants_f64[0]));
                            for (1..coeff_count) |ci| {
                                result = @mulAdd(Vec, result, x, @as(Vec, @splat(expr.constants_f64[ci])));
                            }
                            stack_vec[sp] = result;
                            sp += 1;
                        },

                        .halt => {
                            vec_outputs[base_idx + u] = stack_vec[0];
                            break;
                        },

                        else => unreachable,
                    }
                }
            }
        }

        // Handle remaining items
        var j = vec_unrolled_count * VectorLen * UnrollFactor;
        while (j < count) : (j += 1) {
            outputs[j] = self.executeNumbersOnlyScalar(expr, inputs[j], var_index);
        }
    }

    /// Optimized fallback for number-only expressions (non-batch)
    pub fn executeNumbersOnly(self: *VM, expr: *const CompiledExpr) ?f64 {
        if (expr.max_stack > self.stack_f64.len) return null;
        var sp: usize = 0;
        // Optimization: Use the VM's pre-allocated f64 stack
        const stack_vec = self.stack_f64;
        const code = expr.code;

        var ip: usize = 0;
        while (true) {
            const instr = code[ip];
            ip += 1;

            switch (instr.opcode) {
                .push_const => {
                    stack_vec[sp] = expr.constants_f64[instr.operand];
                    sp += 1;
                },

                .load_var => {
                    if (instr.operand >= self.variables_f64.len) return null;
                    // SAFETY CHECK: If the variable is not a number (e.g. Unit, Matrix),
                    // we must fall back to the full interpreter to handle it correctly.
                    if (self.variables_tags[instr.operand] != .number) return null;
                    stack_vec[sp] = self.variables_f64[instr.operand];
                    sp += 1;
                },

                .store_var => {
                    sp -= 1;
                    const val = stack_vec[sp];
                    const idx = instr.operand;
                    if (idx >= self.variables_f64.len) return null;
                    self.variables_f64[idx] = val;
                    self.variables_tags[idx] = .number;
                    // Mirror to standard Value array for mixed compatibility
                    self.variables[idx] = Value.initNumber(val);
                },

                .dup => {
                    stack_vec[sp] = stack_vec[sp - 1];
                    sp += 1;
                },

                .add => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 1;
                },

                .sub => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] - stack_vec[sp - 1];
                    sp -= 1;
                },

                .mul => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] * stack_vec[sp - 1];
                    sp -= 1;
                },

                .div => {
                    stack_vec[sp - 2] = divNumberSemantics(stack_vec[sp - 2], stack_vec[sp - 1]);
                    sp -= 1;
                },

                .neg => {
                    stack_vec[sp - 1] = -stack_vec[sp - 1];
                },

                .pow => {
                    stack_vec[sp - 2] = fastPowIfSmallInt(stack_vec[sp - 2], stack_vec[sp - 1]) orelse std.math.pow(f64, stack_vec[sp - 2], stack_vec[sp - 1]);
                    sp -= 1;
                },

                .fma => {
                    stack_vec[sp - 3] = stack_vec[sp - 3] * stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 2;
                },

                .fma_var_const_const => {
                    const var_idx: u8 = @truncate(instr.operand & 0xFF);
                    const c1_idx: u8 = @truncate((instr.operand >> 8) & 0xFF);
                    const c2_idx: u8 = @truncate((instr.operand >> 16) & 0xFF);

                    if (self.variables_tags[var_idx] != .number) return null;

                    const x = self.variables_f64[var_idx];
                    const a = expr.constants_f64[c1_idx];
                    const b = expr.constants_f64[c2_idx];

                    stack_vec[sp] = x * a + b;
                    sp += 1;
                },

                .eval_poly => {
                    // Operand encoding: bits 0-15 = var_index, bits 16-23 = count
                    const var_idx: u16 = @truncate(instr.operand & 0xFFFF);
                    const count: u8 = @truncate((instr.operand >> 16) & 0xFF);

                    if (self.variables_tags[var_idx] != .number) return null;
                    const x = self.variables_f64[var_idx];

                    // Horner's method: result = c0; for i in 1..n: result = result * x + c[i]
                    var result = expr.constants_f64[0];
                    for (1..count) |i| {
                        result = @mulAdd(f64, result, x, expr.constants_f64[i]);
                    }
                    stack_vec[sp] = result;
                    sp += 1;
                },

                .pop => {
                    sp -= 1;
                },

                .pos => {},
                .const_mul => {
                    stack_vec[sp - 1] *= expr.constants_f64[instr.operand];
                },

                .load_mul => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    if (self.variables_tags[var_a] != .number) return null;
                    if (self.variables_tags[var_b] != .number) return null;
                    stack_vec[sp] = self.variables_f64[var_a] * self.variables_f64[var_b];
                    sp += 1;
                },

                .load_sub => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    if (self.variables_tags[var_a] != .number) return null;
                    if (self.variables_tags[var_b] != .number) return null;
                    stack_vec[sp] = self.variables_f64[var_a] - self.variables_f64[var_b];
                    sp += 1;
                },

                .halt => {
                    return stack_vec[0];
                },

                else => unreachable,
            }
        }
    }

    /// Widened f64 fast path: numeric expressions with comparisons, boolean
    /// logic, ternaries and loops (see CompiledExpr.fast_path_ok). Booleans
    /// live on the stack as 1.0/0.0. Every arithmetic op replicates the
    /// general interpreter's number-case semantics exactly (incl. Value.div's
    /// custom zero handling and the pow integer-exponent loop), so results
    /// are bit-identical to execute().
    ///
    /// Returns null (before executing anything) when a referenced variable is
    /// not currently a number; the prescan guarantees no mid-run fallback, so
    /// side effects (store_var) never run twice.
    pub fn executeNumbersFast(self: *VM, expr: *const CompiledExpr) ?f64 {
        if (expr.max_stack > self.stack_f64.len) return null;

        const code = expr.code;

        // Before any side effect runs: every variable this code loads OR
        // stores must currently be a number. (Stores must not silently
        // overwrite an object variable: the general path releases the old
        // value; this path could not.) The list — and the guarantee that all
        // opcodes are implemented here — is precomputed at compile time
        // (fast_check_vars), so no mid-run fallback is possible and store
        // side effects can never run twice.
        for (expr.fast_check_vars) |idx| {
            if (idx >= self.variables_f64.len) return null;
            if (self.variables_tags[idx] != .number) return null;
        }

        const stack_vec = self.stack_f64;
        var sp: usize = 0;
        var ip: usize = 0;
        while (true) {
            const instr = code[ip];
            ip += 1;

            switch (instr.opcode) {
                .push_const => {
                    stack_vec[sp] = expr.constants_f64[instr.operand];
                    sp += 1;
                },

                .load_var => {
                    stack_vec[sp] = self.variables_f64[instr.operand];
                    sp += 1;
                },

                .store_var => {
                    sp -= 1;
                    const val = stack_vec[sp];
                    const idx = instr.operand;
                    self.variables_f64[idx] = val;
                    self.variables_tags[idx] = .number;
                    // Mirror to standard Value array for mixed compatibility
                    self.variables[idx] = Value.initNumber(val);
                },

                .dup => {
                    stack_vec[sp] = stack_vec[sp - 1];
                    sp += 1;
                },

                .pop => {
                    sp -= 1;
                },

                .add => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 1;
                },

                .sub => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] - stack_vec[sp - 1];
                    sp -= 1;
                },

                .mul => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] * stack_vec[sp - 1];
                    sp -= 1;
                },

                .div => {
                    // Same semantics as Value.div's number case (NOT plain
                    // IEEE division: x/0 is resolved by the numerator's sign)
                    const a = stack_vec[sp - 2];
                    const b = stack_vec[sp - 1];
                    stack_vec[sp - 2] = if (b == 0)
                        (if (a > 0) std.math.inf(f64) else if (a < 0) -std.math.inf(f64) else std.math.nan(f64))
                    else
                        a / b;
                    sp -= 1;
                },

                .mod => {
                    // Same as Value.mod's number case
                    stack_vec[sp - 2] = val_module.euclideanMod(stack_vec[sp - 2], stack_vec[sp - 1]);
                    sp -= 1;
                },

                .neg => {
                    stack_vec[sp - 1] = -stack_vec[sp - 1];
                },

                .pos => {},

                .pow => {
                    // Same branch structure as the general interpreter's pow
                    // opcode: integer exponents in [0, 10] use a multiply
                    // loop, everything else falls to std.math.pow.
                    const base = stack_vec[sp - 2];
                    const exp = stack_vec[sp - 1];
                    sp -= 1;
                    if (std.math.isFinite(exp) and exp >= 0 and exp <= 10) {
                        const int_exp = @as(i32, @intFromFloat(exp));
                        if (@as(f64, @floatFromInt(int_exp)) == exp) {
                            var res_val: f64 = 1.0;
                            var i: i32 = 0;
                            while (i < int_exp) : (i += 1) {
                                res_val *= base;
                            }
                            stack_vec[sp - 1] = res_val;
                            continue;
                        }
                    }
                    stack_vec[sp - 1] = std.math.pow(f64, base, exp);
                },

                .fma => {
                    // Matches the general path: Value.mul then Value.add (two roundings)
                    stack_vec[sp - 3] = stack_vec[sp - 3] * stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 2;
                },

                .fma_var_const_const => {
                    const var_idx: u8 = @truncate(instr.operand & 0xFF);
                    const c1_idx: u8 = @truncate((instr.operand >> 8) & 0xFF);
                    const c2_idx: u8 = @truncate((instr.operand >> 16) & 0xFF);
                    stack_vec[sp] = self.variables_f64[var_idx] * expr.constants_f64[c1_idx] + expr.constants_f64[c2_idx];
                    sp += 1;
                },

                .const_mul => {
                    stack_vec[sp - 1] *= expr.constants_f64[instr.operand];
                },

                .load_mul => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    stack_vec[sp] = self.variables_f64[var_a] * self.variables_f64[var_b];
                    sp += 1;
                },

                .load_sub => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    stack_vec[sp] = self.variables_f64[var_a] - self.variables_f64[var_b];
                    sp += 1;
                },

                // Comparisons: same number-case semantics as the general
                // interpreter (booleans there convert via toNumber to 1/0,
                // which is exactly this path's boolean representation).
                .lt => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] < stack_vec[sp - 1]) 1.0 else 0.0;
                    sp -= 1;
                },
                .le => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] <= stack_vec[sp - 1]) 1.0 else 0.0;
                    sp -= 1;
                },
                .gt => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] > stack_vec[sp - 1]) 1.0 else 0.0;
                    sp -= 1;
                },
                .ge => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] >= stack_vec[sp - 1]) 1.0 else 0.0;
                    sp -= 1;
                },
                .eq => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] == stack_vec[sp - 1]) 1.0 else 0.0;
                    sp -= 1;
                },
                .ne => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] != stack_vec[sp - 1]) 1.0 else 0.0;
                    sp -= 1;
                },

                // Truthiness (!= 0) matches the general path's
                // boolean-or-toNumber handling for numbers and booleans.
                .and_ => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] != 0 and stack_vec[sp - 1] != 0) 1.0 else 0.0;
                    sp -= 1;
                },
                .or_ => {
                    stack_vec[sp - 2] = if (stack_vec[sp - 2] != 0 or stack_vec[sp - 1] != 0) 1.0 else 0.0;
                    sp -= 1;
                },
                .not_ => {
                    stack_vec[sp - 1] = if (stack_vec[sp - 1] != 0) 0.0 else 1.0;
                },

                .jmp => {
                    ip = instr.operand;
                },
                .jmp_if_false => {
                    sp -= 1;
                    if (stack_vec[sp] == 0) ip = instr.operand;
                },
                .jmp_if_true => {
                    sp -= 1;
                    if (stack_vec[sp] != 0) ip = instr.operand;
                },

                // Whitelisted scalar builtins (bytecode.isFastPathBuiltin).
                // Each case performs the same operations in the same order as
                // the corresponding callBuiltin number case — including the
                // config.angles degree conversion — so results stay
                // bit-identical to the general interpreter.
                .call_builtin => {
                    const func_id: u16 = @truncate(instr.operand & 0xFFFF);
                    const argc: u8 = @truncate((instr.operand >> 16) & 0xFF);
                    const func: BuiltinFn = @enumFromInt(func_id);
                    const degrees = self.config.angles == .degrees;
                    switch (argc) {
                        1 => {
                            const n = stack_vec[sp - 1];
                            stack_vec[sp - 1] = switch (func) {
                                .sin => @sin(if (degrees) n * (std.math.pi / 180.0) else n),
                                .cos => @cos(if (degrees) n * (std.math.pi / 180.0) else n),
                                .tan => @tan(if (degrees) n * (std.math.pi / 180.0) else n),
                                .asin => if (degrees) std.math.asin(n) * (180.0 / std.math.pi) else std.math.asin(n),
                                .acos => if (degrees) std.math.acos(n) * (180.0 / std.math.pi) else std.math.acos(n),
                                .atan => if (degrees) std.math.atan(n) * (180.0 / std.math.pi) else std.math.atan(n),
                                .sec => 1.0 / @cos(n),
                                .csc => 1.0 / @sin(n),
                                .cot => 1.0 / @tan(n),
                                .sinh => std.math.sinh(n),
                                .cosh => std.math.cosh(n),
                                .tanh => std.math.tanh(n),
                                .asinh => std.math.asinh(n),
                                .acosh => std.math.acosh(n),
                                .atanh => std.math.atanh(n),
                                .exp => @exp(n),
                                .log => @log(n),
                                .log10 => @log10(n),
                                .log2 => @log2(n),
                                .log1p => std.math.log1p(n),
                                .expm1 => std.math.expm1(n),
                                .cbrt => std.math.cbrt(n),
                                .abs => @abs(n),
                                .floor => @floor(n),
                                .ceil => @ceil(n),
                                .round => @round(n),
                                .trunc => @trunc(n),
                                .sign => if (n > 0) @as(f64, 1) else if (n < 0) @as(f64, -1) else @as(f64, 0),
                                .square => n * n,
                                .cube => n * n * n,
                                .gamma => std.math.gamma(f64, n),
                                .lgamma => std.math.lgamma(f64, n),
                                .erf => statistics.erf(n),
                                .nthRoot => @sqrt(n),
                                else => unreachable, // prescan whitelist
                            };
                        },
                        2 => {
                            const a = stack_vec[sp - 2];
                            const b = stack_vec[sp - 1];
                            sp -= 1;
                            stack_vec[sp - 1] = switch (func) {
                                .atan2 => if (degrees) std.math.atan2(a, b) * (180.0 / std.math.pi) else std.math.atan2(a, b),
                                .hypot => std.math.hypot(a, b),
                                .min => @min(a, b),
                                .max => @max(a, b),
                                // log(x, base) / nthRoot(x, n): b is the 2nd popped arg
                                .log => @log(a) / @log(b),
                                .nthRoot => std.math.pow(f64, a, 1.0 / b),
                                // a = x, b = decimals (push order: x then decimals)
                                .round => roundToDecimals(a, b),
                                else => unreachable, // prescan whitelist
                            };
                        },
                        else => unreachable, // prescan whitelist
                    }
                },

                .halt => {
                    return stack_vec[0];
                },

                // Unreachable in practice: the prescan whitelists opcodes
                // before execution starts. Kept as a safe bail-out.
                else => return null,
            }
        }
    }

    pub fn executeNumbersOnlyUnchecked(self: *VM, expr: *const CompiledExpr) f64 {
        var sp: usize = 0;
        const stack_vec = self.stack_f64;
        const code = expr.code;

        var ip: usize = 0;
        while (true) {
            const instr = code[ip];
            ip += 1;

            switch (instr.opcode) {
                .push_const => {
                    stack_vec[sp] = expr.constants_f64[instr.operand];
                    sp += 1;
                },

                .load_var => {
                    stack_vec[sp] = self.variables_f64[instr.operand];
                    sp += 1;
                },

                .store_var => {
                    sp -= 1;
                    const val = stack_vec[sp];
                    const idx = instr.operand;
                    self.variables_f64[idx] = val;
                    self.variables_tags[idx] = .number;
                    // Mirror to standard Value array for mixed compatibility
                    self.variables[idx] = Value.initNumber(val);
                },

                .dup => {
                    stack_vec[sp] = stack_vec[sp - 1];
                    sp += 1;
                },

                .add => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 1;
                },

                .sub => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] - stack_vec[sp - 1];
                    sp -= 1;
                },

                .mul => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] * stack_vec[sp - 1];
                    sp -= 1;
                },

                .div => {
                    stack_vec[sp - 2] = divNumberSemantics(stack_vec[sp - 2], stack_vec[sp - 1]);
                    sp -= 1;
                },

                .neg => {
                    stack_vec[sp - 1] = -stack_vec[sp - 1];
                },

                .pow => {
                    stack_vec[sp - 2] = fastPowIfSmallInt(stack_vec[sp - 2], stack_vec[sp - 1]) orelse std.math.pow(f64, stack_vec[sp - 2], stack_vec[sp - 1]);
                    sp -= 1;
                },

                .fma => {
                    stack_vec[sp - 3] = stack_vec[sp - 3] * stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 2;
                },

                .fma_var_const_const => {
                    const var_idx: u8 = @truncate(instr.operand & 0xFF);
                    const c1_idx: u8 = @truncate((instr.operand >> 8) & 0xFF);
                    const c2_idx: u8 = @truncate((instr.operand >> 16) & 0xFF);

                    const x = self.variables_f64[var_idx];
                    const a = expr.constants_f64[c1_idx];
                    const b = expr.constants_f64[c2_idx];

                    stack_vec[sp] = x * a + b;
                    sp += 1;
                },

                .eval_poly => {
                    // Operand encoding: bits 0-15 = var_index, bits 16-23 = count
                    const var_idx: u16 = @truncate(instr.operand & 0xFFFF);
                    const count: u8 = @truncate((instr.operand >> 16) & 0xFF);
                    const x = self.variables_f64[var_idx];

                    // Horner's method: result = c0; for i in 1..n: result = result * x + c[i]
                    var result = expr.constants_f64[0];
                    for (1..count) |i| {
                        result = @mulAdd(f64, result, x, expr.constants_f64[i]);
                    }
                    stack_vec[sp] = result;
                    sp += 1;
                },

                .const_mul => {
                    stack_vec[sp - 1] *= expr.constants_f64[instr.operand];
                },

                .load_mul => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    stack_vec[sp] = self.variables_f64[var_a] * self.variables_f64[var_b];
                    sp += 1;
                },

                .load_sub => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    stack_vec[sp] = self.variables_f64[var_a] - self.variables_f64[var_b];
                    sp += 1;
                },

                .halt => {
                    return stack_vec[0];
                },

                else => unreachable,
            }
        }
    }

    fn executeNumbersOnlyScalar(self: *VM, expr: *const CompiledExpr, input: f64, var_index: u24) f64 {
        var sp: u8 = 0;
        var stack_vec: [64]f64 = undefined;
        const code = expr.code;

        var ip: usize = 0;
        while (true) {
            const instr = code[ip];
            ip += 1;

            switch (instr.opcode) {
                .push_const => {
                    stack_vec[sp] = expr.constants_f64[instr.operand];
                    sp += 1;
                },

                .load_var => {
                    if (instr.operand == var_index) {
                        stack_vec[sp] = input;
                    } else {
                        stack_vec[sp] = self.variables_f64[instr.operand];
                    }
                    sp += 1;
                },

                .add => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 1;
                },

                .sub => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] - stack_vec[sp - 1];
                    sp -= 1;
                },

                .mul => {
                    stack_vec[sp - 2] = stack_vec[sp - 2] * stack_vec[sp - 1];
                    sp -= 1;
                },

                .div => {
                    stack_vec[sp - 2] = divNumberSemantics(stack_vec[sp - 2], stack_vec[sp - 1]);
                    sp -= 1;
                },

                .neg => {
                    stack_vec[sp - 1] = -stack_vec[sp - 1];
                },

                .pow => {
                    stack_vec[sp - 2] = fastPowIfSmallInt(stack_vec[sp - 2], stack_vec[sp - 1]) orelse std.math.pow(f64, stack_vec[sp - 2], stack_vec[sp - 1]);
                    sp -= 1;
                },

                .fma => {
                    stack_vec[sp - 3] = stack_vec[sp - 3] * stack_vec[sp - 2] + stack_vec[sp - 1];
                    sp -= 2;
                },

                .fma_var_const_const => {
                    const var_idx: u8 = @truncate(instr.operand & 0xFF);
                    const c1_idx: u8 = @truncate((instr.operand >> 8) & 0xFF);
                    const c2_idx: u8 = @truncate((instr.operand >> 16) & 0xFF);

                    const x = if (var_idx == var_index) input else self.variables_f64[var_idx];
                    const a = expr.constants_f64[c1_idx];
                    const b = expr.constants_f64[c2_idx];

                    stack_vec[sp] = x * a + b;
                    sp += 1;
                },

                .load_mul => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    const a = if (var_a == var_index) input else self.variables_f64[var_a];
                    const b = if (var_b == var_index) input else self.variables_f64[var_b];
                    stack_vec[sp] = a * b;
                    sp += 1;
                },

                .load_sub => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    const a = if (var_a == var_index) input else self.variables_f64[var_a];
                    const b = if (var_b == var_index) input else self.variables_f64[var_b];
                    stack_vec[sp] = a - b;
                    sp += 1;
                },

                .const_mul => {
                    const c = expr.constants_f64[instr.operand];
                    stack_vec[sp - 1] *= c;
                },

                .eval_poly => {
                    // Operand encoding: bits 0-15 = var_index, bits 16-23 = count
                    const var_idx: u16 = @truncate(instr.operand & 0xFFFF);
                    const count: u8 = @truncate((instr.operand >> 16) & 0xFF);
                    const x = if (var_idx == var_index) input else self.variables_f64[var_idx];

                    // Horner's method: result = c0; for i in 1..n: result = result * x + c[i]
                    var result = expr.constants_f64[0];
                    for (1..count) |i| {
                        result = @mulAdd(f64, result, x, expr.constants_f64[i]);
                    }
                    stack_vec[sp] = result;
                    sp += 1;
                },

                .halt => {
                    return stack_vec[0];
                },

                else => unreachable,
            }
        }
    }

    /// Execute a single complex value through the expression (scalar fallback)
    fn executeComplexScalar(self: *VM, expr: *const CompiledExpr, input_re: f64, input_im: f64, var_index: u24) ComplexF64 {
        var sp: u8 = 0;
        var stack_re: [64]f64 = undefined;
        var stack_im: [64]f64 = undefined;
        const code = expr.code;

        var ip: usize = 0;
        while (true) {
            const instr = code[ip];
            ip += 1;

            switch (instr.opcode) {
                .push_const => {
                    stack_re[sp] = expr.constants_f64[instr.operand];
                    stack_im[sp] = 0;
                    sp += 1;
                },
                .load_var => {
                    if (instr.operand == var_index) {
                        stack_re[sp] = input_re;
                        stack_im[sp] = input_im;
                    } else {
                        stack_re[sp] = self.variables_f64[instr.operand];
                        stack_im[sp] = 0;
                    }
                    sp += 1;
                },
                .add => {
                    stack_re[sp - 2] += stack_re[sp - 1];
                    stack_im[sp - 2] += stack_im[sp - 1];
                    sp -= 1;
                },
                .sub => {
                    stack_re[sp - 2] -= stack_re[sp - 1];
                    stack_im[sp - 2] -= stack_im[sp - 1];
                    sp -= 1;
                },
                .load_mul => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    const a = if (var_a == var_index) ComplexF64{ .re = input_re, .im = input_im } else blk: {
                        const val = self.variables[var_a];
                        break :blk if (val.tag == .number) ComplexF64{ .re = val.data.number, .im = 0 } else ComplexF64{ .re = val.data.complex.re, .im = val.data.complex.im };
                    };
                    const b = if (var_b == var_index) ComplexF64{ .re = input_re, .im = input_im } else blk: {
                        const val = self.variables[var_b];
                        break :blk if (val.tag == .number) ComplexF64{ .re = val.data.number, .im = 0 } else ComplexF64{ .re = val.data.complex.re, .im = val.data.complex.im };
                    };
                    stack_re[sp] = a.re * b.re - a.im * b.im;
                    stack_im[sp] = a.re * b.im + a.im * b.re;
                    sp += 1;
                },
                .load_sub => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    const a = if (var_a == var_index) ComplexF64{ .re = input_re, .im = input_im } else blk: {
                        const val = self.variables[var_a];
                        break :blk if (val.tag == .number) ComplexF64{ .re = val.data.number, .im = 0 } else ComplexF64{ .re = val.data.complex.re, .im = val.data.complex.im };
                    };
                    const b = if (var_b == var_index) ComplexF64{ .re = input_re, .im = input_im } else blk: {
                        const val = self.variables[var_b];
                        break :blk if (val.tag == .number) ComplexF64{ .re = val.data.number, .im = 0 } else ComplexF64{ .re = val.data.complex.re, .im = val.data.complex.im };
                    };
                    stack_re[sp] = a.re - b.re;
                    stack_im[sp] = a.im - b.im;
                    sp += 1;
                },
                .const_mul => {
                    const c_val = expr.constants[instr.operand];
                    const c_re = if (c_val.tag == .number) c_val.data.number else c_val.data.complex.re;
                    const c_im = if (c_val.tag == .number) 0.0 else c_val.data.complex.im;
                    const a_re = stack_re[sp - 1];
                    const a_im = stack_im[sp - 1];
                    stack_re[sp - 1] = a_re * c_re - a_im * c_im;
                    stack_im[sp - 1] = a_re * c_im + a_im * c_re;
                },
                .mul => {
                    const a_re = stack_re[sp - 2];
                    const a_im = stack_im[sp - 2];
                    const b_re = stack_re[sp - 1];
                    const b_im = stack_im[sp - 1];
                    stack_re[sp - 2] = a_re * b_re - a_im * b_im;
                    stack_im[sp - 2] = a_re * b_im + a_im * b_re;
                    sp -= 1;
                },
                .div => {
                    const a_re = stack_re[sp - 2];
                    const a_im = stack_im[sp - 2];
                    const b_re = stack_re[sp - 1];
                    const b_im = stack_im[sp - 1];
                    const denom = b_re * b_re + b_im * b_im;
                    stack_re[sp - 2] = (a_re * b_re + a_im * b_im) / denom;
                    stack_im[sp - 2] = (a_im * b_re - a_re * b_im) / denom;
                    sp -= 1;
                },
                .neg => {
                    stack_re[sp - 1] = -stack_re[sp - 1];
                    stack_im[sp - 1] = -stack_im[sp - 1];
                },
                .halt => {
                    return .{ .re = stack_re[0], .im = stack_im[0] };
                },
                else => unreachable,
            }
        }
    }

    /// Complex SIMD Batch execution
    pub fn executeBatchComplexSIMD(
        self: *VM,
        expr: *const CompiledExpr,
        var_index: u24,
        inputs_re: []const f64,
        inputs_im: []const f64,
        outputs_re: []f64,
        outputs_im: []f64,
        count: usize,
    ) void {
        if (expr.max_stack > 64) return;
        const code = expr.code;
        const v_in_re = @as([*]const Vec, @ptrCast(@alignCast(inputs_re.ptr)));
        const v_in_im = @as([*]const Vec, @ptrCast(@alignCast(inputs_im.ptr)));
        const v_out_re = @as([*]Vec, @ptrCast(@alignCast(outputs_re.ptr)));
        const v_out_im = @as([*]Vec, @ptrCast(@alignCast(outputs_im.ptr)));

        const vec_count = count / VectorLen;
        var stack_re: [64]Vec = undefined;
        var stack_im: [64]Vec = undefined;

        for (0..vec_count) |i| {
            var sp: u8 = 0;
            var ip: usize = 0;

            while (true) {
                const instr = code[ip];
                ip += 1;

                switch (instr.opcode) {
                    .push_const => {
                        const val = expr.constants[instr.operand];
                        if (val.tag == .number) {
                            stack_re[sp] = @splat(val.data.number);
                            stack_im[sp] = @splat(0.0);
                        } else if (val.tag == .complex) {
                            stack_re[sp] = @splat(val.data.complex.re);
                            stack_im[sp] = @splat(val.data.complex.im);
                        }
                        sp += 1;
                    },
                    .load_var => {
                        if (instr.operand == var_index) {
                            stack_re[sp] = v_in_re[i];
                            stack_im[sp] = v_in_im[i];
                        } else {
                            const val = self.variables[instr.operand];
                            if (val.tag == .number) {
                                stack_re[sp] = @splat(val.data.number);
                                stack_im[sp] = @splat(0.0);
                            } else if (val.tag == .complex) {
                                stack_re[sp] = @splat(val.data.complex.re);
                                stack_im[sp] = @splat(val.data.complex.im);
                            }
                        }
                        sp += 1;
                    },
                    .add => {
                        stack_re[sp - 2] += stack_re[sp - 1];
                        stack_im[sp - 2] += stack_im[sp - 1];
                        sp -= 1;
                    },
                    .sub => {
                        stack_re[sp - 2] -= stack_re[sp - 1];
                        stack_im[sp - 2] -= stack_im[sp - 1];
                        sp -= 1;
                    },
                    .load_mul => {
                        const var_a = instr.operand & 0xFFF;
                        const var_b = (instr.operand >> 12) & 0xFFF;
                        const a_re = if (var_a == var_index) v_in_re[i] else blk: {
                            const val = self.variables[var_a];
                            break :blk @as(Vec, @splat(if (val.tag == .number) val.data.number else val.data.complex.re));
                        };
                        const a_im = if (var_a == var_index) v_in_im[i] else blk: {
                            const val = self.variables[var_a];
                            break :blk @as(Vec, @splat(if (val.tag == .number) 0.0 else val.data.complex.im));
                        };
                        const b_re = if (var_b == var_index) v_in_re[i] else blk: {
                            const val = self.variables[var_b];
                            break :blk @as(Vec, @splat(if (val.tag == .number) val.data.number else val.data.complex.re));
                        };
                        const b_im = if (var_b == var_index) v_in_im[i] else blk: {
                            const val = self.variables[var_b];
                            break :blk @as(Vec, @splat(if (val.tag == .number) 0.0 else val.data.complex.im));
                        };
                        stack_re[sp] = a_re * b_re - a_im * b_im;
                        stack_im[sp] = a_re * b_im + a_im * b_re;
                        sp += 1;
                    },
                    .load_sub => {
                        const var_a = instr.operand & 0xFFF;
                        const var_b = (instr.operand >> 12) & 0xFFF;
                        const a_re = if (var_a == var_index) v_in_re[i] else blk: {
                            const val = self.variables[var_a];
                            break :blk @as(Vec, @splat(if (val.tag == .number) val.data.number else val.data.complex.re));
                        };
                        const a_im = if (var_a == var_index) v_in_im[i] else blk: {
                            const val = self.variables[var_a];
                            break :blk @as(Vec, @splat(if (val.tag == .number) 0.0 else val.data.complex.im));
                        };
                        const b_re = if (var_b == var_index) v_in_re[i] else blk: {
                            const val = self.variables[var_b];
                            break :blk @as(Vec, @splat(if (val.tag == .number) val.data.number else val.data.complex.re));
                        };
                        const b_im = if (var_b == var_index) v_in_im[i] else blk: {
                            const val = self.variables[var_b];
                            break :blk @as(Vec, @splat(if (val.tag == .number) 0.0 else val.data.complex.im));
                        };
                        stack_re[sp] = a_re - b_re;
                        stack_im[sp] = a_im - b_im;
                        sp += 1;
                    },
                    .const_mul => {
                        const c_val = expr.constants[instr.operand];
                        const c_re = @as(Vec, @splat(if (c_val.tag == .number) c_val.data.number else c_val.data.complex.re));
                        const c_im = @as(Vec, @splat(if (c_val.tag == .number) 0.0 else c_val.data.complex.im));
                        const a_re = stack_re[sp - 1];
                        const a_im = stack_im[sp - 1];
                        stack_re[sp - 1] = a_re * c_re - a_im * c_im;
                        stack_im[sp - 1] = a_re * c_im + a_im * c_re;
                    },
                    .mul => {
                        const a_re = stack_re[sp - 2];
                        const a_im = stack_im[sp - 2];
                        const b_re = stack_re[sp - 1];
                        const b_im = stack_im[sp - 1];

                        stack_re[sp - 2] = a_re * b_re - a_im * b_im;
                        stack_im[sp - 2] = a_re * b_im + a_im * b_re;
                        sp -= 1;
                    },
                    .div => {
                        const a_re = stack_re[sp - 2];
                        const a_im = stack_im[sp - 2];
                        const b_re = stack_re[sp - 1];
                        const b_im = stack_im[sp - 1];

                        const denom = b_re * b_re + b_im * b_im;
                        stack_re[sp - 2] = (a_re * b_re + a_im * b_im) / denom;
                        stack_im[sp - 2] = (a_im * b_re - a_re * b_im) / denom;
                        sp -= 1;
                    },
                    .neg => {
                        stack_re[sp - 1] = -stack_re[sp - 1];
                        stack_im[sp - 1] = -stack_im[sp - 1];
                    },
                    .halt => {
                        v_out_re[i] = stack_re[0];
                        v_out_im[i] = stack_im[0];
                        break;
                    },
                    else => unreachable,
                }
            }
        }

        // Scalar remainder
        var j = vec_count * VectorLen;
        while (j < count) : (j += 1) {
            const res = self.executeComplexScalar(expr, inputs_re[j], inputs_im[j], var_index);
            outputs_re[j] = res.re;
            outputs_im[j] = res.im;
        }
    }

    fn traceInstruction(self: *VM, ip: usize, instr: bytecode.Instruction, expr: *const CompiledExpr) void {
        const source_offset = if (ip < expr.source_offsets.len) expr.source_offsets[ip] else 0;
        threading.debugPrint("[IP: {d:0>3}] [Op: {s: <15}] [Operand: {d: <8}] [SP: {d: >3}] ", .{
            ip,
            @tagName(instr.opcode),
            instr.operand,
            self.sp,
        });

        if (self.sp > 0) {
            threading.debugPrint("[Top: ", .{});
            self.dumpValue(self.peek() catch Value.initUndefined());
            threading.debugPrint("] ", .{});
        }

        threading.debugPrint("[Offset: {d}]\n", .{source_offset});
    }

    fn dumpValue(self: *VM, val: Value) void {
        _ = self;
        switch (val.tag) {
            .number => threading.debugPrint("{d:.4}", .{val.data.number}),
            .boolean => threading.debugPrint("{}", .{val.data.boolean}),
            .complex => threading.debugPrint("{d:.2}+{d:.2}i", .{ val.data.complex.re, val.data.complex.im }),
            .string => threading.debugPrint("\"{s}\"", .{val.data.string.toSlice()}),
            .unit => threading.debugPrint("{d:.2}[{s}]", .{ val.data.unit.value, val.data.unit.info.name orelse "unit" }),
            .matrix => threading.debugPrint("Matrix({d}x{d})", .{ val.data.matrix.rows, val.data.matrix.cols }),
            .series => threading.debugPrint("Series(len={d})", .{val.data.series.len}),
            .record => threading.debugPrint("Record(len={d})", .{val.data.record.len()}),
            .err => threading.debugPrint("Error({d})", .{val.data.err}),
            .null_val => threading.debugPrint("null", .{}),
            .undefined => threading.debugPrint("undefined", .{}),
            else => threading.debugPrint("{s}", .{@tagName(val.tag)}),
        }
    }

    pub fn setDebug(self: *VM, debug: bool) void {
        self.debug_mode = debug;
    }

    /// Get the source offset of the last error (for source mapping in error messages)
    pub fn getLastErrorOffset(self: *VM) u32 {
        return self.last_error_offset;
    }

    const SliceRange = struct { start: u32, end: u32, step: i32, len: u32 };

    fn strictI64FromNumber(n: f64) !i64 {
        if (!std.math.isFinite(n)) return error.TypeError;
        if (n > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.IndexOutOfBounds;
        if (n < @as(f64, @floatFromInt(std.math.minInt(i64)))) return error.IndexOutOfBounds;

        const i: i64 = @intFromFloat(n);
        if (@as(f64, @floatFromInt(i)) != n) return error.TypeError;
        return i;
    }

    fn positiveStepSliceLen(start: i64, end_exclusive: i64, step: i64) u32 {
        if (start >= end_exclusive) return 0;
        const span = end_exclusive - start;
        const len_i = @divFloor(span + step - 1, step);
        return @intCast(len_i);
    }

    fn resolveSlice(len: u32, val: Value) !SliceRange {
        if (val.tag == .slice) {
            const s = val.data.slice;
            const start_val = s.start;
            const end_val = s.end;
            const step_val = s.step;

            const start = if (start_val.toNumber()) |v| try strictI64FromNumber(v) else 0;
            const end = if (end_val.tag != .null_val) (if (end_val.toNumber()) |v| try strictI64FromNumber(v) else len) else len;
            const step = if (step_val.toNumber()) |v| try strictI64FromNumber(v) else 1;

            if (step == 0) return error.InvalidStep;
            if (step < 0) return error.InvalidArgument;

            var r_start = start;
            var r_end = end;
            const len_i: i64 = @intCast(len);

            if (r_start < 0) r_start += len_i;
            if (r_end < 0) r_end += len_i;

            if (r_start < 0) r_start = 0;
            if (r_start > len_i) r_start = len_i;
            if (r_end < 0) r_end = 0;
            if (r_end > len_i) r_end = len_i;

            return SliceRange{
                .start = @intCast(r_start),
                .end = @intCast(r_end),
                .step = @intCast(step),
                .len = positiveStepSliceLen(r_start, r_end, step),
            };
        } else if (val.toNumber()) |v| {
            const idx = try strictI64FromNumber(v);
            if (idx < 0 or idx >= len) return error.IndexOutOfBounds;
            return SliceRange{ .start = @intCast(idx), .end = @intCast(idx + 1), .step = 1, .len = 1 };
        }
        return error.TypeError;
    }

    fn normalizeMatrixIndex(len: i64, raw: i64) !i64 {
        // Zero-based indexing with negative index support.
        var idx = raw;
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) return error.IndexOutOfBounds;
        return idx;
    }

    fn resolveMatrixSlice(len: u32, val: Value) !SliceRange {
        const len_i: i64 = @intCast(len);
        if (val.tag == .slice) {
            const s = val.data.slice;
            const start_raw: ?i64 = if (s.start.toNumber()) |v| try strictI64FromNumber(v) else null;
            const end_raw: ?i64 = if (s.end.tag != .null_val) (if (s.end.toNumber()) |v| try strictI64FromNumber(v) else null) else null;
            const step_raw: i64 = if (s.step.toNumber()) |v| try strictI64FromNumber(v) else 1;

            if (step_raw == 0) return error.InvalidStep;
            if (step_raw < 0) return error.InvalidArgument;

            var start0: i64 = 0;
            if (start_raw) |sv| {
                if (sv > 0) {
                    start0 = sv - 1;
                } else {
                    start0 = sv;
                }
            }

            var end_excl: i64 = len_i;
            if (end_raw) |ev| {
                if (ev > 0) {
                    // one-based inclusive end -> exclusive bound
                    end_excl = ev;
                } else {
                    end_excl = ev;
                }
            }

            if (start0 < 0) start0 += len_i;
            if (end_excl < 0) end_excl += len_i;

            if (start0 < 0) start0 = 0;
            if (start0 > len_i) start0 = len_i;
            if (end_excl < 0) end_excl = 0;
            if (end_excl > len_i) end_excl = len_i;

            return SliceRange{
                .start = @intCast(start0),
                .end = @intCast(end_excl),
                .step = @intCast(step_raw),
                .len = positiveStepSliceLen(start0, end_excl, step_raw),
            };
        }

        if (val.toNumber()) |v| {
            const idx = try normalizeMatrixIndex(len_i, try strictI64FromNumber(v));
            return SliceRange{ .start = @intCast(idx), .end = @intCast(idx + 1), .step = 1, .len = 1 };
        }

        return error.TypeError;
    }

    /// Elementwise SI → target unit conversion for matrices.
    /// Matrix storage is SI magnitudes after numeric mat_create or homogeneous
    /// matrix*unit scale (unit-bearing literals are rejected). Formula matches
    /// scalar conv: (si - offset) / scale.
    fn convertMatrixSiToUnit(self: *VM, m: *Matrix, target: Value) !Value {
        std.debug.assert(target.tag == .unit);
        const target_scale = target.data.unit.value - target.data.unit.info.offset;
        if (target_scale == 0) return Value.initError(1);
        const offset = target.data.unit.info.offset;
        const res = try Matrix.init(self.allocator, m.rows, m.cols);
        self.trackMatrix(res);
        var r: u32 = 0;
        while (r < m.rows) : (r += 1) {
            var c: u32 = 0;
            while (c < m.cols) : (c += 1) {
                res.set(r, c, (m.get(r, c) - offset) / target_scale);
            }
        }
        return .{ .tag = .matrix, .data = .{ .matrix = res } };
    }

    fn tryFastVectorSingleIndex(mat: *Matrix, key: Value) !?Value {
        if (key.tag != .number) return null;
        if (!(mat.rows == 1 or mat.cols == 1)) return null;

        const len_i: i64 = if (mat.rows == 1) @intCast(mat.cols) else @intCast(mat.rows);
        const idx = try normalizeMatrixIndex(len_i, try strictI64FromNumber(key.data.number));
        const pos: u32 = @intCast(idx);

        if (mat.rows == 1) return Value.initNumber(mat.get(0, pos));
        return Value.initNumber(mat.get(pos, 0));
    }

    fn executeLoadVarIndex(self: *VM, var_idx: u24, key: Value) !void {
        const object = self.variables[var_idx];

        if (object.tag == .matrix) {
            if (try tryFastVectorSingleIndex(object.data.matrix, key)) |fast| {
                try self.push(fast);
                return;
            }
        }

        var keys = [_]Value{key};
        const result = try self.getIndex(object, keys[0..]);
        self.trackValue(result);
        try self.push(result);
    }

    fn getIndex(self: *VM, object: Value, keys: []Value) !Value {
        switch (object.tag) {
            .matrix => {
                const mat = object.data.matrix;
                if (keys.len == 2) {
                    return try self.sliceMatrix(mat, keys[0], keys[1]);
                } else if (keys.len == 1) {
                    if (try tryFastVectorSingleIndex(mat, keys[0])) |fast| {
                        return fast;
                    }
                    const all_slice_struct = try val_module.Slice.init(self.allocator, Value.initNull(), Value.initNull(), Value.initNull());
                    self.trackSlice(all_slice_struct);
                    const all_slice = Value.initSlice(all_slice_struct);

                    if (mat.rows == 1 and mat.cols > 1) {
                        // For row vectors, apply single index to columns
                        return try self.sliceMatrix(mat, all_slice, keys[0]);
                    } else {
                        // Default: apply to rows
                        return try self.sliceMatrix(mat, keys[0], all_slice);
                    }
                }
                return error.InvalidIndexCount;
            },
            .series => {
                if (keys.len == 1) {
                    return try self.sliceSeries(object.data.series, keys[0]);
                }
                return error.InvalidIndexCount;
            },
            .record => {
                if (keys.len == 1) {
                    const key = keys[0];
                    if (key.tag == .string) {
                        const val = object.data.record.get(key.data.string.toSlice()) orelse Value.initUndefined();
                        val.retain();
                        return val;
                    }
                    return error.TypeError;
                }
                return error.InvalidIndexCount;
            },
            else => return error.TypeError,
        }
    }

    fn setIndex(self: *VM, object: Value, keys: []Value, value: Value) !void {
        switch (object.tag) {
            .matrix => {
                const mat = object.data.matrix;
                if (keys.len == 2) {
                    try self.assignMatrixSlice(mat, keys[0], keys[1], value);
                    return;
                } else if (keys.len == 1) {
                    const all_slice_struct = try val_module.Slice.init(self.allocator, Value.initNull(), Value.initNull(), Value.initNull());
                    self.trackSlice(all_slice_struct);
                    const all_slice = Value.initSlice(all_slice_struct);

                    if (mat.rows == 1 and mat.cols > 1) {
                        try self.assignMatrixSlice(mat, all_slice, keys[0], value);
                    } else {
                        try self.assignMatrixSlice(mat, keys[0], all_slice, value);
                    }
                    return;
                }
                return error.InvalidIndexCount;
            },
            .record => {
                if (keys.len != 1) return error.InvalidIndexCount;
                const key = keys[0];
                if (key.tag != .string) return error.TypeError;
                try object.data.record.set(key.data.string.toSlice(), value);
                return;
            },
            else => return error.TypeError,
        }
    }

    fn sliceMatrix(self: *VM, mat: *Matrix, row_spec: Value, col_spec: Value) !Value {
        if (row_spec.tag == .number and col_spec.tag == .number) {
            const r_idx = try normalizeMatrixIndex(@intCast(mat.rows), try strictI64FromNumber(row_spec.data.number));
            const c_idx = try normalizeMatrixIndex(@intCast(mat.cols), try strictI64FromNumber(col_spec.data.number));
            return Value.initNumber(mat.get(@intCast(r_idx), @intCast(c_idx)));
        }

        const row_range = try resolveMatrixSlice(mat.rows, row_spec);
        const col_range = try resolveMatrixSlice(mat.cols, col_spec);

        const res_rows = row_range.len;
        const res_cols = col_range.len;

        const res = try Matrix.init(self.allocator, res_rows, res_cols);
        self.trackMatrix(res);

        var r: u32 = 0;
        var src_r = row_range.start;
        while (r < res_rows) : (r += 1) {
            var c: u32 = 0;
            var src_c = col_range.start;
            while (c < res_cols) : (c += 1) {
                res.set(r, c, mat.get(src_r, src_c));
                src_c = @intCast(@as(i64, src_c) + col_range.step);
            }
            src_r = @intCast(@as(i64, src_r) + row_range.step);
        }

        return Value.initMatrix(res);
    }

    fn assignMatrixSlice(self: *VM, mat: *Matrix, row_spec: Value, col_spec: Value, rhs: Value) !void {
        _ = self;
        const row_range = try resolveMatrixSlice(mat.rows, row_spec);
        const col_range = try resolveMatrixSlice(mat.cols, col_spec);
        const target_rows = row_range.len;
        const target_cols = col_range.len;
        const target_count: usize = @intCast(target_rows * target_cols);

        if (target_count == 0) return;

        if (rhs.tag == .matrix) {
            const src = rhs.data.matrix;
            const src_count = src.rows * src.cols;
            if (src_count != target_count) return error.MismatchedDimensions;

            var dst_r: u32 = 0;
            var src_i: usize = 0;
            var src_r = row_range.start;
            while (dst_r < target_rows) : (dst_r += 1) {
                var dst_c: u32 = 0;
                var src_c = col_range.start;
                while (dst_c < target_cols) : (dst_c += 1) {
                    const src_cols: usize = @intCast(src.cols);
                    const v = src.get(@intCast(src_i / src_cols), @intCast(src_i % src_cols));
                    mat.set(src_r, src_c, v);
                    src_i += 1;
                    src_c = @intCast(@as(i64, src_c) + col_range.step);
                }
                src_r = @intCast(@as(i64, src_r) + row_range.step);
            }
            return;
        }

        if (rhs.toNumber()) |n| {
            if (target_count != 1) return error.MismatchedDimensions;
            mat.set(row_range.start, col_range.start, n);
            return;
        }

        return error.TypeError;
    }

    fn sliceSeries(self: *VM, s: *Series, spec: Value) !Value {
        if (spec.tag == .number) {
            const idx = try strictI64FromNumber(spec.data.number);
            if (idx < 0 or idx >= s.len) return error.IndexOutOfBounds;
            return Value.initNumber(s.values[@intCast(idx)]);
        }

        const range = try resolveSlice(@intCast(s.len), spec);
        const res_len = range.len;

        const res = try Series.init(self.allocator, res_len, s.sample_mode, s.dimensions);
        self.trackSeries(res);

        var i: u32 = 0;
        var src_i = range.start;
        while (i < res_len) : (i += 1) {
            res.timestamps[i] = s.timestamps[src_i];
            res.values[i] = s.values[src_i];
            res.validity[i] = s.validity[src_i];
            src_i = @intCast(@as(i64, src_i) + range.step);
        }
        try res.validate();
        return Value.initSeries(res);
    }

    // =========================================================================
    // Specialized Vector ODE Execution
    // =========================================================================
    // These functions provide an optimized execution path for small fixed-size
    // vector ODEs that bypasses the general Matrix type entirely.
    // Key optimizations:
    // - Passes state as []f64 array directly (no Matrix wrapper)
    // - Writes output to pre-allocated []f64 buffer (no allocation per call)
    // - Uses streamlined interpreter with direct array access for vector indexing
    // - Avoids Value boxing for intermediate results
    // =========================================================================

    /// Execute a derivative function optimized for small vector ODEs.
    /// Avoids all matrix allocation by working directly with f64 arrays.
    ///
    /// Requirements:
    /// - func must take (t: f64, y: vector) and return vector
    /// - y_in and y_out must have the same length (the ODE dimension)
    /// - Dimension must be <= 16 for stack allocation efficiency
    pub fn executeVectorDerivative(
        self: *VM,
        func: *const bytecode.UserFunction,
        t: f64,
        y_in: []const f64,
        y_out: []f64,
    ) VMError!void {
        const dim = y_in.len;
        std.debug.assert(dim == y_out.len);
        std.debug.assert(dim <= 16);

        // Set time parameter (first param at func.param_offset)
        self.variables_f64[func.param_offset] = t;
        self.variables_tags[func.param_offset] = .number;

        // Execute with vector-aware interpreter
        // y parameter index is at func.param_offset + 1
        try self.executeVectorBody(
            &func.body,
            @intCast(func.param_offset + 1),
            y_in,
            y_out,
        );
    }

    /// Specialized interpreter for vector derivative functions.
    /// Key differences from execute():
    /// - Vector parameter accessed via y_in array (no Matrix indirection)
    /// - Vector indexing is direct array access (no get_index allocation)
    /// - Result written directly to y_out (no matrix creation)
    /// - Uses f64 stack only (no Value boxing)
    pub fn executeVectorBody(
        self: *VM,
        expr: *const CompiledExpr,
        y_param_index: u24,
        y_in: []const f64,
        y_out: []f64,
    ) VMError!void {
        if (expr.max_stack > 64) return error.StackOverflow;
        // Stack for intermediate f64 values
        var stack: [64]f64 = undefined;
        var sp: usize = 0;

        // Track which stack slot holds the "vector" for indexing
        // We use a compact bitset instead of bool array
        var stack_is_vector: u64 = 0;

        const code = expr.code;
        var ip: usize = 0;

        while (ip < code.len) {
            const instr = code[ip];
            ip += 1;

            switch (instr.opcode) {
                .push_const => {
                    // Use constants_f64 if available, otherwise fall back to constants
                    stack[sp] = if (expr.constants_f64.len > 0)
                        expr.constants_f64[instr.operand]
                    else
                        expr.constants[instr.operand].toNumber() orelse 0;
                    // Clear vector flag for this slot
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .load_var => {
                    const var_idx = instr.operand;
                    if (var_idx == y_param_index) {
                        // Loading the vector parameter - mark it
                        // We don't push actual data, just mark that this is the vector reference
                        stack[sp] = 0; // Placeholder
                        stack_is_vector |= (@as(u64, 1) << @intCast(sp));
                    } else {
                        stack[sp] = self.variables_f64[var_idx];
                        stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    }
                    sp += 1;
                },

                .get_index => {
                    // Pop index
                    sp -= 1;
                    const idx: usize = @intFromFloat(stack[sp]);

                    // Pop object (should be vector reference)
                    sp -= 1;
                    const is_vector = (stack_is_vector & (@as(u64, 1) << @intCast(sp))) != 0;
                    if (is_vector) {
                        // Direct array access - THE KEY OPTIMIZATION!
                        if (idx >= y_in.len) return error.IndexOutOfBounds;
                        stack[sp] = y_in[idx];
                        stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                        sp += 1;
                    } else {
                        return error.InvalidArgument;
                    }
                },

                // Arithmetic operations
                .add => {
                    stack[sp - 2] = stack[sp - 2] + stack[sp - 1];
                    sp -= 1;
                },

                .sub => {
                    stack[sp - 2] = stack[sp - 2] - stack[sp - 1];
                    sp -= 1;
                },

                .load_var_index_0 => {
                    const var_idx = instr.operand;
                    const obj = self.variables[var_idx];
                    stack[sp] = obj.data.matrix.data[0];
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .load_var_index_1 => {
                    const var_idx = instr.operand;
                    const obj = self.variables[var_idx];
                    stack[sp] = obj.data.matrix.data[1];
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .load_var_index_2 => {
                    const var_idx = instr.operand;
                    const obj = self.variables[var_idx];
                    stack[sp] = obj.data.matrix.data[2];
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .load_var_index_3 => {
                    const var_idx = instr.operand;
                    const obj = self.variables[var_idx];
                    stack[sp] = obj.data.matrix.data[3];
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .load_var_index_const => {
                    const var_idx = instr.operand & 0xFFF;
                    const const_idx = (instr.operand >> 12) & 0xFFF;
                    const obj = self.variables[var_idx];
                    const index: usize = @intFromFloat(expr.constants_f64[const_idx]);
                    stack[sp] = obj.data.matrix.data[index];
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .load_mul => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    stack[sp] = self.variables_f64[var_a] * self.variables_f64[var_b];
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .load_sub => {
                    const var_a = instr.operand & 0xFFF;
                    const var_b = (instr.operand >> 12) & 0xFFF;
                    stack[sp] = self.variables_f64[var_a] - self.variables_f64[var_b];
                    stack_is_vector &= ~(@as(u64, 1) << @intCast(sp));
                    sp += 1;
                },

                .const_mul => {
                    const c = expr.constants_f64[instr.operand];
                    stack[sp - 1] *= c;
                },

                .mat_create_3 => {
                    const c = stack[sp - 1];
                    const b = stack[sp - 2];
                    const a = stack[sp - 3];
                    sp -= 3;
                    y_out[0] = a;
                    y_out[1] = b;
                    y_out[2] = c;
                    // Result is in y_out, we don't push to stack
                },

                .mul => {
                    stack[sp - 2] = stack[sp - 2] * stack[sp - 1];
                    sp -= 1;
                },
                .div => {
                    stack[sp - 2] = stack[sp - 2] / stack[sp - 1];
                    sp -= 1;
                },
                .neg => {
                    stack[sp - 1] = -stack[sp - 1];
                },
                .pow => {
                    stack[sp - 2] = fastPowIfSmallInt(stack[sp - 2], stack[sp - 1]) orelse std.math.pow(f64, stack[sp - 2], stack[sp - 1]);
                    sp -= 1;
                },

                .mat_create => {
                    // Creating result vector - write directly to y_out
                    // Operand: rows (12) | cols (12)
                    const rows: u32 = @as(u32, instr.operand & 0xFFF);
                    const cols: u32 = @as(u32, (instr.operand >> 12) & 0xFFF);
                    const count = rows * cols;

                    if (count != y_out.len) return error.MismatchedDimensions;

                    // Pop values in reverse order into y_out
                    var i: usize = count;
                    while (i > 0) {
                        i -= 1;
                        sp -= 1;
                        y_out[i] = stack[sp];
                    }
                    // Don't push anything - result is in y_out
                    // Mark that we've produced output
                },

                .call_builtin => {
                    // Support simple math builtins (sin, cos, exp, etc.)
                    const func_id: u16 = @truncate(instr.operand & 0xFFFF);
                    const arg_count: u8 = @truncate((instr.operand >> 16) & 0xFF);

                    const builtin_fn: BuiltinFn = @enumFromInt(func_id);

                    // Handle single-argument math functions
                    if (arg_count == 1) {
                        const arg = stack[sp - 1];
                        const result = switch (builtin_fn) {
                            .sin => @sin(arg),
                            .cos => @cos(arg),
                            .tan => @tan(arg),
                            .exp => @exp(arg),
                            .log => @log(arg),
                            .sqrt => @sqrt(arg),
                            .abs => @abs(arg),
                            .floor => @floor(arg),
                            .ceil => @ceil(arg),
                            .round => @round(arg),
                            .sinh => std.math.sinh(arg),
                            .cosh => std.math.cosh(arg),
                            .tanh => std.math.tanh(arg),
                            .asin => std.math.asin(arg),
                            .acos => std.math.acos(arg),
                            .atan => std.math.atan(arg),
                            .log10 => std.math.log10(arg),
                            .log2 => std.math.log2(arg),
                            .cbrt => std.math.cbrt(arg),
                            .sign => std.math.sign(arg),
                            else => return error.UnimplementedOpcode,
                        };
                        stack[sp - 1] = result;
                    } else if (arg_count == 2) {
                        const arg2 = stack[sp - 1];
                        const arg1 = stack[sp - 2];
                        sp -= 1;
                        const result = switch (builtin_fn) {
                            .atan2 => std.math.atan2(arg1, arg2),
                            .hypot => std.math.hypot(arg1, arg2),
                            .min => @min(arg1, arg2),
                            .max => @max(arg1, arg2),
                            .round => roundToDecimals(arg1, arg2),
                            else => return error.UnimplementedOpcode,
                        };
                        stack[sp - 1] = result;
                    } else {
                        return error.UnimplementedOpcode;
                    }
                },

                .halt => break,

                else => {
                    // Unsupported opcode in vector path
                    return error.UnimplementedOpcode;
                },
            }
        }
    }

    /// Check if a function is suitable for vector optimization path.
    /// Returns true if the function only uses supported opcodes.
    pub fn canUseVectorPath(func: *const bytecode.UserFunction, dim: usize) bool {
        if (dim > 16) return false;
        if (func.params.len != 2) return false;

        // Check bytecode for unsupported operations
        for (func.body.code) |instr| {
            switch (instr.opcode) {
                // Supported operations
                .push_const,
                .load_var,
                .get_index,
                .add,
                .sub,
                .mul,
                .div,
                .neg,
                .pow,
                .mat_create,
                .halt,
                => {},

                .call_builtin => {
                    // Check if it's a supported builtin
                    const func_id: u16 = @truncate(instr.operand & 0xFFFF);
                    const builtin_fn: BuiltinFn = @enumFromInt(func_id);
                    switch (builtin_fn) {
                        .sin,
                        .cos,
                        .tan,
                        .exp,
                        .log,
                        .sqrt,
                        .abs,
                        .floor,
                        .ceil,
                        .round,
                        .sinh,
                        .cosh,
                        .tanh,
                        .asin,
                        .acos,
                        .atan,
                        .atan2,
                        .log10,
                        .log2,
                        .cbrt,
                        .sign,
                        .hypot,
                        .min,
                        .max,
                        => {},
                        else => return false,
                    }
                },

                // Unsupported - fall back to general path
                else => return false,
            }
        }
        return true;
    }

    /// Debug-only integrity audit of the entire VM state
    pub fn audit(self: *VM) void {
        // sp is u16, check for overflow
        std.debug.assert(self.sp <= self.stack.len);

        // 2. Scan intermediate objects
        var it = self.intermediate_objects.valueIterator();
        while (it.next()) |obj| {
            switch (obj.*) {
                .matrix => |m| std.debug.assert(m.magic == 0x4D41545249583031 and m.ref_count > 0),
                .series => |s| std.debug.assert(s.magic == 0x5345524945533031 and s.ref_count > 0),
                .record => |r| std.debug.assert(r.magic == 0xDEADC0DE and r.ref_count > 0),
                .slice => |s| std.debug.assert(s.ref_count > 0),
            }
        }

        // 3. Scan variables
        for (self.variables) |val| {
            switch (val.tag) {
                .matrix => std.debug.assert(val.data.matrix.magic == 0x4D41545249583031),
                .series => std.debug.assert(val.data.series.magic == 0x5345524945533031),
                .record => std.debug.assert(val.data.record.magic == 0xDEADC0DE),
                else => {},
            }
        }
    }
};
