const std = @import("std");
const Value = @import("../core/value.zig").Value;
const euclideanMod = @import("../core/value.zig").euclideanMod;

/// Bytecode instruction opcodes
pub const Opcode = enum(u8) {
    // Stack operations
    push_const, // Push constant from pool (operand = index)
    pop, // Discard top of stack
    dup, // Duplicate top of stack

    // Variable operations
    load_var, // Load variable by index
    store_var, // Store to variable by index

    // Arithmetic operations
    add, // a + b
    sub, // a - b
    mul, // a * b
    div, // a / b
    mod, // a % b
    pow, // a ^ b
    neg, // -a
    pos, // +a (no-op for numbers)

    // Comparison operations
    eq, // a == b
    ne, // a != b
    lt, // a < b
    le, // a <= b
    gt, // a > b
    ge, // a >= b

    // Logical operations
    and_, // a && b
    or_, // a || b
    not_, // !a

    // Bitwise operations
    band, // a & b
    bor, // a | b
    bxor, // a ^^ b
    bnot, // ~a
    shl, // a << b
    shr, // a >> b

    // Function calls
    call_user, // Call user-defined function (operand encodes func_id and arg_count)
    def_user, // Define user function (operand = index into constant pool for metadata)
    call_builtin, // Call builtin function (operand encodes func_id and arg_count)
    call_builtin_where, // Call builtin with predicate (operand encodes func_id and arg_count)

    // Specialized operations for common patterns
    eval_poly, // Evaluate polynomial using Horner's method

    // Superinstructions (Instruction Fusion)
    fma, // Fused Multiply-Add: pop a, b, c -> push a * b + c
    // Optimized from: push a, push b, mul, push c, add
    fma_var_const_const, // FMA with embedded indices: x * c1 + c2
    // operand: var_idx (8) | c1_idx (8) | c2_idx (8)

    // Matrix operations
    mat_create, // Create matrix (operand encodes rows/cols)
    /// Legacy / dead opcode. Never emitted by the parser or compiler; matrix
    /// indexing uses `get_index` (and fused `load_var_index_*`). Kept in the
    /// enum for wire/bytecode ordinal stability. AOT refuses it with
    /// `error.UnsupportedOpcode`; the VM has no dispatch arm (falls through
    /// as an unknown opcode if present in handcrafted bytecode).
    mat_index, // DEAD — superseded by get_index; do not emit
    emul, // Element-wise multiplication
    ediv, // Element-wise division
    epow, // Element-wise power

    // Record operations
    rec_create, // Create record (operand = number of fields)
    rec_get, // Get field from record (operand = constant string index for field name)
    rec_get_dyn, // Get field from record dynamically (pops key, pops object)

    // Unit operations
    unit_create, // Create unit value (operand = unit_id)
    unit_convert, // Convert units (operand = target_unit_id)

    // Slice/Index operations
    make_slice, // Create slice value (pops step, end, start)
    get_index, // Get value by index/slice (operand = number of keys, pops object, then keys)
    set_index, // Set value by index/slice (operand = number of keys, pops object, keys, value; pushes value)

    // Control flow
    jmp, // Unconditional jump (operand = offset)
    jmp_if_false, // Jump if top of stack is false
    jmp_if_true, // Jump if top of stack is true

    // Special
    halt, // Stop execution and return top of stack
    nop, // No operation

    // Fused Opcodes (Superinstructions)
    load_var_index_0, // Load var, index with 0
    load_var_index_1, // Load var, index with 1
    load_var_index_2, // Load var, index with 2
    load_var_index_3, // Load var, index with 3
    load_var_index_const, // Load var, index with constant: operand = var_idx (12) | const_idx (12)
    load_mul, // Load two vars, multiply: operand = var_a (12) | var_b (12)
    load_sub, // Load two vars, subtract: operand = var_a (12) | var_b (12)
    const_mul, // Multiply TOS by constant: operand = const_idx
    mat_create_3, // Create 3-element vector from top 3 stack values
};

/// Builtins eligible for the widened f64 fast path: pure scalar
/// number(s) -> number, infallible for numeric arguments, no allocation and
/// no VM state beyond the stack (executeNumbersFast replicates each
/// callBuiltin number case op-for-op, including the config.angles degree
/// conversion, so results are bit-identical).
/// NOT eligible: sqrt (returns complex for negative input), random (RNG
/// state), factorial and anything series/matrix/record-typed.
/// IMPORTANT: this list must stay in exact sync with the call_builtin arm in
/// VM.executeNumbersFast — its per-arity switches use `unreachable` for
/// anything admitted here but not implemented there.
pub fn isFastPathBuiltin(func: BuiltinFn, arg_count: usize) bool {
    return switch (func) {
        // zig fmt: off
        .abs, .cbrt, .exp, .log10, .log2,
        .sin, .cos, .tan, .asin, .acos, .atan,
        .sinh, .cosh, .tanh, .asinh, .acosh, .atanh,
        .sec, .csc, .cot,
        .floor, .ceil, .trunc, .sign,
        .square, .cube, .log1p, .expm1, .erf,
        .gamma, .lgamma,
        => arg_count == 1,
        // zig fmt: on
        // round(x) or round(x, decimals)
        .round => arg_count == 1 or arg_count == 2,
        .log, .nthRoot => arg_count == 1 or arg_count == 2,
        // min/max: the fast interpreter only implements the 2-arg pair form
        .min, .max, .atan2, .hypot => arg_count == 2,
        else => false,
    };
}

/// A single bytecode instruction
pub const Instruction = packed struct {
    opcode: Opcode,
    operand: u24 = 0, // 24-bit operand for constants, variables, jumps

    pub fn init(opcode: Opcode) Instruction {
        return .{ .opcode = opcode, .operand = 0 };
    }

    pub fn initWithOperand(opcode: Opcode, operand: u24) Instruction {
        return .{ .opcode = opcode, .operand = operand };
    }
};

/// Compiled expression ready for execution
pub const CompiledExpr = struct {
    code: []const Instruction,
    source_offsets: []const u32,
    constants: []const Value,
    predicates: []const @import("../timeseries/predicates.zig").Predicate = &.{},
    /// Pre-extracted f64 constants for fast-path execution
    constants_f64: []const f64,
    max_stack: u16, // Maximum stack depth needed
    /// True if expression only uses numeric operations (enables fast-path)
    is_number_only: bool,
    /// True if the expression is numeric but also uses comparisons, boolean
    /// logic, ternaries or loops over numeric operands (enables the widened
    /// f64 fast path with control flow; see VM.executeNumbersFast).
    fast_path_ok: bool = false,
    /// Deduplicated variable indices referenced by the code (loads AND
    /// stores). Precomputed at compile time so the fast path only has to
    /// check these tags before executing, instead of rescanning the code.
    fast_check_vars: []const u24 = &.{},
    /// Whether the expression owns its memory (code, constants)
    owns_memory: bool = true,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledExpr) void {
        if (self.owns_memory) {
            self.allocator.free(@as([]Instruction, @constCast(self.code)));
            self.allocator.free(@as([]u32, @constCast(self.source_offsets)));

            // Unit names are now in MathZig.arena, no need to free here.
            self.allocator.free(@as([]Value, @constCast(self.constants)));

            if (self.predicates.len > 0) {
                self.allocator.free(@as([]@import("../timeseries/predicates.zig").Predicate, @constCast(self.predicates)));
            }
            if (self.constants_f64.len > 0) {
                self.allocator.free(@as([]f64, @constCast(self.constants_f64)));
            }
            if (self.fast_check_vars.len > 0) {
                self.allocator.free(@as([]u24, @constCast(self.fast_check_vars)));
            }
        }
    }
};

/// User-defined function metadata and code
pub const UserFunction = struct {
    name: []const u8,
    params: [][]const u8,
    body: CompiledExpr,
    /// Offset for parameter indices (used for nested functions to avoid conflict with parent scope)
    param_offset: u32 = 0,
    /// True when the compiler filled in the frame metadata below, enabling
    /// the frame-based call path (body runs on the caller VM; only write_vars
    /// are saved/restored instead of copying all variable arrays).
    frame_ok: bool = false,
    /// Deduplicated variable slots the body writes: store_var targets plus
    /// the parameter slots. Allocated from the same allocator as the body.
    write_vars: []const u24 = &.{},
    /// Highest variable index the body references anywhere; the frame path
    /// requires the caller's variable arrays to cover it.
    max_var_ref: u24 = 0,

    pub fn deinit(self: *UserFunction) void {
        self.body.deinit();
        // params and name are usually duped in session arena or similar
        // (write_vars lives in the same arena as the body's metadata)
    }
};
/// Bytecode builder for compiling expressions
pub const BytecodeBuilder = struct {
    code: std.ArrayListUnmanaged(Instruction),
    source_offsets: std.ArrayListUnmanaged(u32),
    constants: std.ArrayListUnmanaged(Value),
    predicates: std.ArrayListUnmanaged(@import("../timeseries/predicates.zig").Predicate),
    allocator: std.mem.Allocator,
    /// Track if we've seen any non-number operations
    is_number_only: bool,
    /// Stack tracking
    current_stack: i32 = 0,
    max_stack: i32 = 0,
    /// Constant folding: track if last instruction was a push_const
    /// Stores the index into constants array, or null if not a constant
    pending_const_1: ?u24,
    pending_const_2: ?u24,
    /// Interning map for numeric constants: f64 bit pattern -> pool index.
    /// Keeps the constant pool deduplicated (+0.0 and -0.0 stay distinct).
    const_intern: std.AutoHashMapUnmanaged(u64, u24),

    pub fn init(allocator: std.mem.Allocator) BytecodeBuilder {
        return .{
            .code = .empty,
            .source_offsets = .empty,
            .constants = .empty,
            .predicates = .empty,
            .allocator = allocator,
            .is_number_only = true, // Assume number-only until proven otherwise
            .current_stack = 0,
            .max_stack = 0,
            .pending_const_1 = null,
            .pending_const_2 = null,
            .const_intern = .{},
        };
    }

    fn updateStack(self: *BytecodeBuilder, opcode: Opcode, operand: u24) void {
        const delta: i32 = switch (opcode) {
            .push_const, .load_var, .dup => 1,
            .pop, .store_var => -1,
            .add, .sub, .mul, .div, .mod, .pow, .emul, .ediv, .epow => -1,
            .eq, .ne, .lt, .le, .gt, .ge => -1,
            .and_, .or_, .band, .bor, .bxor, .shl, .shr => -1,
            .neg, .pos, .not_, .bnot, .unit_create, .unit_convert, .rec_get => 0,
            .rec_get_dyn => -1,
            .fma => -2,
            .fma_var_const_const => 1,
            .call_builtin => blk: {
                const arg_count: u8 = @truncate((operand >> 16) & 0xFF);
                break :blk 1 - @as(i32, arg_count);
            },
            .call_builtin_where => blk: {
                const arg_count: u8 = @truncate((operand >> 16) & 0xFF);
                break :blk 1 - (@as(i32, arg_count) + 1); // +1 for predicate
            },
            .call_user => blk: {
                const arg_count: u8 = @truncate((operand >> 16) & 0xFF);
                break :blk 1 - @as(i32, arg_count);
            },
            .def_user => 1, // def_user pushes 'true'
            .mat_create => blk: {
                const rows: u32 = @as(u32, operand & 0xFFF);
                const cols: u32 = @as(u32, (operand >> 12) & 0xFFF);
                break :blk 1 - @as(i32, @intCast(rows * cols));
            },
            .rec_create => 1 - 2 * @as(i32, @intCast(operand)),
            .make_slice => -2, // pops 3, pushes 1
            .get_index => -@as(i32, @intCast(operand)), // pops operand (keys) + 1 (object), pushes 1 -> net -operand
            .set_index => -(@as(i32, @intCast(operand)) + 1), // pops operand (keys) + 2 (object,value), pushes 1
            .jmp_if_false, .jmp_if_true => -1,
            .jmp, .halt, .nop, .mat_index, .eval_poly => 0,

            // Fused opcodes
            .load_var_index_0, .load_var_index_1, .load_var_index_2, .load_var_index_3 => 1,
            .load_var_index_const => 1,
            .load_mul, .load_sub => 1,
            .const_mul => 0, // replaces 1 value with 1 result
            .mat_create_3 => -2, // pops 3, pushes 1
        };

        self.current_stack += delta;
        if (self.current_stack > self.max_stack) {
            self.max_stack = self.current_stack;
        }
    }

    /// Mark expression as using non-number types (disables fast-path)
    pub fn markNonNumeric(self: *BytecodeBuilder) void {
        self.is_number_only = false;
    }

    /// Clear pending constant tracking (called after non-constant ops)
    fn clearPendingConsts(self: *BytecodeBuilder) void {
        self.pending_const_1 = null;
        self.pending_const_2 = null;
    }

    pub fn deinit(self: *BytecodeBuilder) void {
        self.code.deinit(self.allocator);
        self.source_offsets.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.predicates.deinit(self.allocator);
        self.const_intern.deinit(self.allocator);
    }

    pub fn emit(self: *BytecodeBuilder, opcode: Opcode, source_offset: u32) !void {
        // Mark non-numeric if needed (these opcodes are not supported by the fast path)
        switch (opcode) {
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
            .mat_create_3,
            // Comparison operators return booleans, not numbers
            .lt,
            .le,
            .gt,
            .ge,
            .eq,
            .ne,
            // Boolean operators
            .and_,
            .or_,
            .not_,
            // Bitwise operators
            .band,
            .bor,
            .bxor,
            .bnot,
            .shl,
            .shr,
            // Modulo
            .mod,
            => self.markNonNumeric(),
            else => {},
        }

        // Try constant folding for binary operations
        if (self.tryFoldBinaryOp(opcode, source_offset)) {
            return; // Folded successfully
        }

        // Peephole Optimization: Fused Multiply-Add (FMA)
        // Pattern: [..., mul, push/load, add] -> [..., push/load, fma]
        if (opcode == .add and self.code.items.len >= 2) {
            const last_op = self.code.items[self.code.items.len - 1].opcode;
            const prev_op = self.code.items[self.code.items.len - 2].opcode;

            // Check for MUL followed by PUSH/LOAD
            if (prev_op == .mul and (last_op == .push_const or last_op == .load_var)) {
                // We have a match!
                // 1. Remove the 'mul' at index len-2
                //    This involves moving the last instruction (push/load) back one slot
                const last_instr = self.code.pop().?;
                const last_offset = self.source_offsets.pop().?;
                _ = self.code.pop().?; // Remove mul
                _ = self.source_offsets.pop().?;

                // Adjust stack tracking for the removed 'mul' and 'push/load'
                // mul was -1, push/load was +1.
                // We'll re-apply them correctly below.
                // Wait, it's easier to just reset and let re-emitting handle it.
                // But BytecodeBuilder doesn't support easy backtracking of current_stack.
                // Let's just manually fix it.
                self.current_stack -= 0; // (-1 from mul, +1 from push/load) cancelled out.

                // 2. Put the push/load back
                try self.code.append(self.allocator, last_instr);
                try self.source_offsets.append(self.allocator, last_offset);
                self.updateStack(last_instr.opcode, last_instr.operand);

                // 3. Emit 'fma' instead of 'add'
                try self.code.append(self.allocator, Instruction.init(.fma));
                try self.source_offsets.append(self.allocator, source_offset);
                self.updateStack(.fma, 0);

                // Aggressive Fusion: fma_var_const_const
                // Pattern: [..., load_var x, push_const a, push_const b, fma]
                if (self.code.items.len >= 4) {
                    const len = self.code.items.len;
                    const op3 = self.code.items[len - 4].opcode;
                    const op2 = self.code.items[len - 3].opcode;
                    const op1 = self.code.items[len - 2].opcode;
                    const op0 = self.code.items[len - 1].opcode;

                    if (op0 == .fma and op1 == .push_const and op2 == .push_const and op3 == .load_var) {
                        const var_idx = self.code.items[len - 4].operand;
                        const c1_idx = self.code.items[len - 3].operand;
                        const c2_idx = self.code.items[len - 2].operand;

                        if (var_idx <= 255 and c1_idx <= 255 and c2_idx <= 255) {
                            // Replace all 4 with one superinstruction
                            _ = self.code.pop(); // fma
                            _ = self.source_offsets.pop();
                            _ = self.code.pop(); // push b
                            _ = self.source_offsets.pop();
                            _ = self.code.pop(); // push a
                            _ = self.source_offsets.pop();
                            _ = self.code.pop(); // load x
                            _ = self.source_offsets.pop();

                            // Backtrack stack: fma was -2, b was +1, a was +1, x was +1. Total +1.
                            self.current_stack -= 1;

                            const operand: u24 = @as(u24, @intCast(var_idx)) |
                                (@as(u24, @intCast(c1_idx)) << 8) |
                                (@as(u24, @intCast(c2_idx)) << 16);
                            try self.code.append(self.allocator, Instruction.initWithOperand(.fma_var_const_const, operand));
                            try self.source_offsets.append(self.allocator, source_offset);
                            self.updateStack(.fma_var_const_const, operand);
                        }
                    }
                }

                self.clearPendingConsts();
                return;
            }
        }

        try self.code.append(self.allocator, Instruction.init(opcode));
        try self.source_offsets.append(self.allocator, source_offset);
        self.updateStack(opcode, 0);
        self.clearPendingConsts();
    }

    pub fn emitWithOperand(self: *BytecodeBuilder, opcode: Opcode, operand: u24, source_offset: u32) !void {
        switch (opcode) {
            .mat_create,
            .rec_create,
            .rec_get,
            .unit_create,
            .unit_convert,
            // Function calls and definitions are not supported by the fast path
            .call_builtin,
            .call_builtin_where,
            .call_user,
            .def_user,
            .get_index,
            .set_index,
            // Jumps are not supported by the fast path
            .jmp,
            .jmp_if_false,
            .jmp_if_true,
            => self.markNonNumeric(),
            else => {},
        }
        try self.code.append(self.allocator, Instruction.initWithOperand(opcode, operand));
        try self.source_offsets.append(self.allocator, source_offset);
        self.updateStack(opcode, operand);
        // Clear pending consts for non-constant operations
        if (opcode != .push_const) {
            self.clearPendingConsts();
        }
    }

    pub fn addConstant(self: *BytecodeBuilder, value: Value) !u24 {
        // Deduplicate numeric constants by bit pattern (NaN payloads and
        // signed zeros compare by bits, so distinct representations stay distinct)
        if (value.tag == .number) {
            const bits: u64 = @bitCast(value.data.number);
            const gop = try self.const_intern.getOrPut(self.allocator, bits);
            if (gop.found_existing) return gop.value_ptr.*;
            const index: u24 = @intCast(self.constants.items.len);
            try self.constants.append(self.allocator, value);
            gop.value_ptr.* = index;
            return index;
        }
        const index = self.constants.items.len;
        try self.constants.append(self.allocator, value);
        return @intCast(index);
    }

    pub fn addPredicate(self: *BytecodeBuilder, predicate: @import("../timeseries/predicates.zig").Predicate) !u24 {
        const index = self.predicates.items.len;
        try self.predicates.append(self.allocator, predicate);
        return @intCast(index);
    }

    pub fn emitConstant(self: *BytecodeBuilder, value: Value, source_offset: u32) !void {
        if (value.tag != .number) {
            self.markNonNumeric();
        }
        const index = try self.addConstant(value);
        try self.emitWithOperand(.push_const, index, source_offset);

        // Track pending constants for folding
        self.pending_const_1 = self.pending_const_2;
        self.pending_const_2 = index;
    }

    /// Try to fold a binary operation with two constant operands
    /// Returns true if folding was successful
    fn tryFoldBinaryOp(self: *BytecodeBuilder, opcode: Opcode, source_offset: u32) bool {
        // Need two pending constants
        const idx1 = self.pending_const_1 orelse return false;
        const idx2 = self.pending_const_2 orelse return false;

        // Both must be numbers for simple folding
        const val1 = self.constants.items[idx1];
        const val2 = self.constants.items[idx2];
        if (val1.tag != .number or val2.tag != .number) return false;

        const a = val1.data.number;
        const b = val2.data.number;

        // Compute the result
        const result: ?f64 = switch (opcode) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => blk: {
                if (b == 0) {
                    if (a > 0) break :blk std.math.inf(f64);
                    if (a < 0) break :blk -std.math.inf(f64);
                    break :blk std.math.nan(f64);
                }
                break :blk a / b;
            },
            .mod => euclideanMod(a, b),
            .pow => blk: {
                // Fast path for small integer exponents
                if (std.math.isFinite(b) and b >= 0 and b <= 10) {
                    const int_exp = @as(i32, @intFromFloat(b));
                    if (@as(f64, @floatFromInt(int_exp)) == b) {
                        var result_val: f64 = 1.0;
                        var i: i32 = 0;
                        while (i < int_exp) : (i += 1) {
                            result_val *= a;
                        }
                        break :blk result_val;
                    }
                }
                break :blk std.math.pow(f64, a, b);
            },
            else => null, // Can't fold this operation
        };

        const folded = result orelse return false;

        // Remove the two push_const instructions we added
        if (self.code.items.len >= 2) {
            _ = self.code.pop();
            _ = self.source_offsets.pop();
            _ = self.code.pop();
            _ = self.source_offsets.pop();
        } else {
            return false;
        }

        // Intern the folded result as its own constant. Do NOT overwrite
        // constants[idx2] in place: with deduplication that slot may be
        // referenced by other instructions.
        const folded_idx = self.addConstant(Value.initNumber(folded)) catch return false;

        // Re-emit a single push_const with the folded value
        self.code.append(self.allocator, Instruction.initWithOperand(.push_const, folded_idx)) catch return false;
        self.source_offsets.append(self.allocator, source_offset) catch return false;

        // Update pending tracking - result is now the only pending constant
        self.pending_const_1 = null;
        self.pending_const_2 = folded_idx;

        return true;
    }

    pub fn currentOffset(self: *BytecodeBuilder) u24 {
        return @intCast(self.code.items.len);
    }

    pub fn patchJump(self: *BytecodeBuilder, offset: u24) void {
        self.code.items[offset].operand = @intCast(self.code.items.len);
    }

    pub fn build(self: *BytecodeBuilder) !CompiledExpr {
        try self.emit(.halt, if (self.source_offsets.items.len > 0) self.source_offsets.items[self.source_offsets.items.len - 1] else 0);

        const constants = try self.constants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(constants);

        // Build f64 constant array for fast-path and fused-path execution
        var constants_f64: []f64 = &.{};
        if (constants.len > 0) {
            constants_f64 = try self.allocator.alloc(f64, constants.len);
            for (constants, 0..) |c, i| {
                constants_f64[i] = c.toNumber() orelse 0;
            }
        }
        errdefer if (constants_f64.len > 0) self.allocator.free(constants_f64);

        const predicates = try self.predicates.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(predicates);

        return .{
            .code = try self.code.toOwnedSlice(self.allocator),
            .source_offsets = try self.source_offsets.toOwnedSlice(self.allocator),
            .constants = constants,
            .constants_f64 = constants_f64,
            .predicates = predicates,
            .max_stack = @intCast(self.max_stack),
            .is_number_only = self.is_number_only,
            .owns_memory = true,
            .allocator = self.allocator,
        };
    }
};

/// Built-in function IDs
pub const BuiltinFn = enum(u16) {
    // Math functions
    abs,
    sqrt,
    cbrt,
    exp,
    log,
    log10,
    log2,

    // Trigonometry
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2,
    sinh,
    cosh,
    tanh,
    sec,
    csc,
    cot,
    asec,
    acsc,
    acot,

    // Rounding
    floor,
    ceil,
    round,
    trunc,
    sign,
    min,
    max,
    clamp,
    hypot,
    norm,
    random,
    randomInt,
    pickRandom,

    // Specialized Math
    square,
    cube,
    nthRoot,
    log1p,
    expm1,

    // Hyperbolic Inverses
    asinh,
    acosh,
    atanh,

    // Hyperbolic Reciprocal
    sech,
    csch,
    coth,
    asech,
    acsch,
    acoth,

    // Special
    factorial,
    gamma,
    lgamma,
    erf,

    // Combinatorics
    combinations,
    permutations,

    // Complex
    re,
    im,
    arg,
    conj,

    // Matrix
    det,
    inv,
    transpose,
    gemv,
    size,
    trace,
    dot,
    cross,
    reshape,
    flatten,
    concat,
    diag,
    identity,
    zeros,
    ones,

    // Statistics
    mean,
    sum,
    count,
    median,
    std,
    variance,
    mad,
    prod,

    // Number Theory
    gcd,
    lcm,
    isPrime,

    // Units
    conv,
    number,

    // I/O
    read_csv,
    write_csv,

    // Testing
    assert,

    cumsum,
    cummax,
    cummin,
    rolling_sum,
    rolling_mean,
    rolling_min,
    rolling_max,
    rolling_count,
    rolling_stddev,
    diff,
    pct_change,

    // Time-Series
    series,
    twa,
    derivative,
    integrate,
    sma,
    ema,
    rsi,
    last,
    duration,
    asofJoin,
    resample,
    align_,
    head,
    tail,
    slice,
    between,
    since,
    shift,
    dropna,
    fillna,
    clip,

    // Advanced Indicators (return Records)
    bollinger,
    macd,

    // Generators
    gen_range,
    linspace,
    logspace,
    agg_range,
    now,
    ode_solve,
    ode_solve_euler,
    toLaTeX,
    create_unit,
    config,
};

test "bytecode builder" {
    const allocator = std.testing.allocator;

    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();

    // Build: 2 + 3
    try builder.emitConstant(Value.initNumber(2), 0);
    try builder.emitConstant(Value.initNumber(3), 2);
    try builder.emit(.add, 1);

    var expr = try builder.build();
    defer expr.deinit();

    // Constant folding should reduce this to: push 5, halt
    try std.testing.expectEqual(@as(usize, 2), expr.code.len);
    // Pool holds [2, 3, 5]: the folded result is interned as a new constant
    // (never overwritten in place, since slots may be shared via dedup);
    // the operand slots become dead but harmless.
    try std.testing.expectEqual(@as(usize, 3), expr.constants.len);
    try std.testing.expectEqual(@as(f64, 5), expr.constants[expr.code[0].operand].data.number);
}

test "no stale constant fold across an intervening op" {
    const allocator = std.testing.allocator;

    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();

    // sin(2) + 3: the call consumes the 2. If an intervening op ever stopped
    // clearing pending_const_1/2, tryFoldBinaryOp would fold 2+3=5 and drop
    // the call result — lock the invariant.
    try builder.emitConstant(Value.initNumber(2), 0);
    const call_operand: u24 = @as(u24, @intFromEnum(BuiltinFn.sin)) | (@as(u24, 1) << 16);
    try builder.emitWithOperand(.call_builtin, call_operand, 1);
    try builder.emitConstant(Value.initNumber(3), 2);
    try builder.emit(.add, 3);

    var expr = try builder.build();
    defer expr.deinit();

    // push 2, call sin, push 3, add, halt — nothing folded away.
    try std.testing.expectEqual(@as(usize, 5), expr.code.len);
    try std.testing.expectEqual(Opcode.push_const, expr.code[0].opcode);
    try std.testing.expectEqual(Opcode.call_builtin, expr.code[1].opcode);
    try std.testing.expectEqual(Opcode.push_const, expr.code[2].opcode);
    try std.testing.expectEqual(Opcode.add, expr.code[3].opcode);
    try std.testing.expectEqual(Opcode.halt, expr.code[4].opcode);
}
