const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TokenType = @import("tokenizer.zig").TokenType;
const Token = @import("tokenizer.zig").Token;
const Value = @import("../core/value.zig").Value;
const bytecode = @import("../vm/bytecode.zig");
const BytecodeBuilder = bytecode.BytecodeBuilder;
const CompiledExpr = bytecode.CompiledExpr;
const Instruction = bytecode.Instruction;
const Opcode = bytecode.Opcode;
const BuiltinFn = bytecode.BuiltinFn;
const UnitRegistry = @import("../units/unit_registry.zig").UnitRegistry;
const ast = @import("../core/ast.zig");
const Node = ast.Node;
const NodeType = ast.NodeType;
const ValueTag = @import("../core/value.zig").ValueTag;
const Config = @import("../core/config.zig").Config;
const latex = @import("latex.zig");

// Type alias for record field to match AST definition exactly
const RecordField = struct { key: []const u8, value: *Node };

const CompileError = error{
    UnexpectedToken,
    InvalidNumber,
    ExpectedRightParen,
    ExpectedRightBracket,
    ExpectedRightBrace,
    UnknownFunction,
    UnknownUnit,
    OutOfMemory,
    CompileError,
};

/// Operator precedence levels (higher = binds tighter)
const Precedence = enum(u8) {
    none,
    assignment, // =
    conversion, // to in as
    conditional, // ?:
    or_, // or ||
    and_, // and &&
    bitwise_or, // |
    bitwise_xor, // ^^
    bitwise_and, // &
    equality, // == !=
    comparison, // < > <= >=
    shift, // << >> >>>
    term, // + -
    factor, // * / %
    implicit_mul, // juxtaposition
    unary, // - ! ~ not
    power, // ^
    postfix, // ' () []
    primary,
};

/// Compiler that parses and compiles expressions to bytecode
pub const Compiler = struct {
    tokenizer: Tokenizer,
    current: Token,
    previous: Token,
    next: Token, // Lookahead token
    builder: BytecodeBuilder,
    source: []const u8,
    variables: std.StringHashMap(u24),
    user_functions: std.StringHashMap(u32),
    /// Id the next `def_user` will occupy in the VM's runtime function table.
    /// Must equal the VM table length at compile start; `user_functions.count()`
    /// is wrong once a name is redefined (put overwrites, the table still appends).
    next_user_func_id: u32 = 0,
    parent: ?*Compiler = null,
    registry: *const UnitRegistry,
    node_arena: std.heap.ArenaAllocator,
    /// Allocator for metadata that needs to outlive the compiler (e.g., unit names in bytecode)
    metadata_allocator: ?std.mem.Allocator = null,
    had_error: bool,
    next_var_index: u24,
    variable_tags: ?[]const ValueTag = null,
    /// Optional snapshot of runtime variable values for tag verification
    variable_values: ?[]const Value = null,
    /// Field to pass variable name from identifier() to assignment()
    pending_var_name: []const u8 = "",
    error_msg: ?[]const u8 = null,
    error_offset: u32 = 0,
    /// Set of names currently shadowed (e.g., function parameters) during parsing of a body
    shadow_scope: ?*const std.StringHashMap(void) = null,
    config: ?*const Config = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Compiler {
        var tokenizer = Tokenizer.init(source);
        const first_token = tokenizer.next();
        const second_token = tokenizer.next();

        const node_arena = std.heap.ArenaAllocator.init(allocator);
        return Compiler{
            .tokenizer = tokenizer,
            .current = first_token,
            .previous = first_token,
            .next = second_token,
            .builder = BytecodeBuilder.init(allocator),
            .source = source,
            .variables = std.StringHashMap(u24).init(allocator),
            .user_functions = std.StringHashMap(u32).init(allocator),
            .parent = null,
            .registry = undefined, // Must be set by caller
            .node_arena = node_arena,
            .had_error = false,
            .next_var_index = 0,
            .pending_var_name = "",
            .error_msg = null,
            .error_offset = 0,
            .shadow_scope = null,
            .variable_tags = null,
            .variable_values = null,
            .config = null,
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, source: []const u8, config: *const Config) !Compiler {
        var tokenizer = Tokenizer.initWithConfig(source, config);
        const first_token = tokenizer.next();
        const second_token = tokenizer.next();

        const node_arena = std.heap.ArenaAllocator.init(allocator);
        return Compiler{
            .tokenizer = tokenizer,
            .current = first_token,
            .previous = first_token,
            .next = second_token,
            .builder = BytecodeBuilder.init(allocator),
            .source = source,
            .variables = std.StringHashMap(u24).init(allocator),
            .user_functions = std.StringHashMap(u32).init(allocator),
            .parent = null,
            .registry = undefined, // Must be set by caller
            .node_arena = node_arena,
            .had_error = false,
            .next_var_index = 0,
            .pending_var_name = "",
            .error_msg = null,
            .error_offset = 0,
            .shadow_scope = null,
            .variable_tags = null,
            .variable_values = null,
            .config = config,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.builder.deinit();
        self.variables.deinit();
        self.user_functions.deinit();
        self.node_arena.deinit();
    }

    fn peekNext(self: *Compiler) u8 {
        return self.tokenizer.peekNext();
    }

    fn setError(self: *Compiler, msg: []const u8) void {
        self.had_error = true;
        self.error_msg = self.node_arena.allocator().dupe(u8, msg) catch msg;
        self.error_offset = self.current.start;
    }

    fn setErrorFrom(self: *Compiler, err: CompileError) void {
        self.had_error = true;
        self.error_offset = self.current.start;

        // Don't overwrite detailed messages with generic one
        if (err == error.CompileError and self.error_msg != null) return;

        const msg = switch (err) {
            error.UnexpectedToken => "Unexpected token",
            error.InvalidNumber => "Invalid number format",
            error.ExpectedRightParen => "Expected ')'",
            error.ExpectedRightBracket => "Expected ']'",
            error.ExpectedRightBrace => "Expected '}'",
            error.UnknownFunction => "Unknown function",
            error.UnknownUnit => "Unknown unit",
            error.OutOfMemory => "Out of memory",
            error.CompileError => "Compilation error",
        };
        self.error_msg = msg;
    }

    pub fn compile(self: *Compiler) !CompiledExpr {
        var root = self.expression() catch |err| {
            self.setErrorFrom(err);
            return err;
        };

        // Handle semicolon-separated expressions (sequence)
        if (self.current.type == .semicolon) {
            var exprs = std.ArrayListUnmanaged(*Node).empty;
            const allocator = self.node_arena.allocator();
            try exprs.append(allocator, root);

            while (self.current.type == .semicolon) {
                self.advance(); // consume semicolon
                if (self.current.type == .eof) break; // trailing semicolon is ok
                const next_expr = self.expression() catch |err| {
                    self.setErrorFrom(err);
                    return err;
                };
                try exprs.append(allocator, next_expr);
            }

            // Create sequence node
            const seq_node = try self.allocNode();
            seq_node.* = .{
                .type = .sequence,
                .start = root.start,
                .data = .{ .sequence = .{ .exprs = try exprs.toOwnedSlice(allocator) } },
            };
            root = seq_node;
        }

        if (self.current.type != .eof) {
            self.setError("Unexpected token at end of expression");
            return error.CompileError;
        }

        if (self.had_error) {
            return error.CompileError;
        }

        root = try self.simplify(root);

        try self.emitBytecode(root);

        // Widened f64 fast path: numeric expressions that additionally use
        // comparisons / boolean logic / ternaries / loops (which clear
        // is_number_only) can still run on an f64-only interpreter as long as
        // every value-producing subexpression is numeric. Decided on the AST,
        // where result types are known statically; per-variable numeric-ness
        // is re-checked at runtime (VM.executeNumbersFast prescan).
        var fast_ok = !self.builder.is_number_only and self.isFastPathNumeric(root);

        // Peephole Optimization Pass
        try self.optimizeBytecode();

        // Emit halt instruction
        try self.builder.emit(.halt, if (self.builder.source_offsets.items.len > 0)
            self.builder.source_offsets.items[self.builder.source_offsets.items.len - 1]
        else
            0);

        const constants = try self.builder.constants.toOwnedSlice(self.builder.allocator);
        errdefer self.builder.allocator.free(constants);

        // Build f64 constant array for fast-path execution
        var constants_f64: []f64 = &.{};
        if (constants.len > 0) {
            constants_f64 = try self.builder.allocator.alloc(f64, constants.len);
            for (constants, 0..) |c, i| {
                constants_f64[i] = c.toNumber() orelse 0;
            }
        }
        errdefer if (constants_f64.len > 0) self.builder.allocator.free(constants_f64);

        var fast_check_vars: []u24 = &.{};
        if (fast_ok) {
            if (try computeFastCheckVars(self.builder.allocator, self.builder.code.items)) |vars| {
                fast_check_vars = vars;
            } else {
                fast_ok = false;
            }
        }
        errdefer if (fast_check_vars.len > 0) self.builder.allocator.free(fast_check_vars);

        return CompiledExpr{
            .code = try self.builder.code.toOwnedSlice(self.builder.allocator),
            .source_offsets = try self.builder.source_offsets.toOwnedSlice(self.builder.allocator),
            .constants = constants,
            .constants_f64 = constants_f64,
            .max_stack = @intCast(self.builder.max_stack),
            .is_number_only = self.builder.is_number_only,
            .fast_path_ok = fast_ok,
            .fast_check_vars = fast_check_vars,
            .owns_memory = true,
            .allocator = self.builder.allocator,
        };
    }

    /// For the widened fast path: collect the deduplicated variable indices
    /// the final code references (so the VM only checks those tags at
    /// runtime), and double-check every emitted opcode against the
    /// interpreter's whitelist. Returns null if any opcode is not supported
    /// (the expression must then not carry fast_path_ok). The returned slice
    /// is allocated with `allocator` (empty slice = eligible, no variables).
    fn computeFastCheckVars(allocator: std.mem.Allocator, code: []const Instruction) !?[]u24 {
        var seen = std.AutoArrayHashMapUnmanaged(u24, void){};
        defer seen.deinit(allocator);
        for (code) |instr| {
            switch (instr.opcode) {
                .load_var, .store_var => try seen.put(allocator, instr.operand, {}),
                .load_mul, .load_sub => {
                    try seen.put(allocator, instr.operand & 0xFFF, {});
                    try seen.put(allocator, (instr.operand >> 12) & 0xFFF, {});
                },
                .fma_var_const_const => try seen.put(allocator, instr.operand & 0xFF, {}),
                .call_builtin => {
                    const func_id: u16 = @truncate(instr.operand & 0xFFFF);
                    const arg_count: u8 = @truncate((instr.operand >> 16) & 0xFF);
                    if (!bytecode.isFastPathBuiltin(@enumFromInt(func_id), arg_count)) return null;
                },
                // zig fmt: off
                .push_const, .dup, .pop,
                .add, .sub, .mul, .div, .mod, .neg, .pos, .pow,
                .fma, .const_mul,
                .lt, .le, .gt, .ge, .eq, .ne,
                .and_, .or_, .not_,
                .jmp, .jmp_if_false, .jmp_if_true,
                .halt,
                => {},
                // zig fmt: on
                else => return null,
            }
        }
        if (seen.count() == 0) return @as([]u24, &.{});
        return try allocator.dupe(u24, seen.keys());
    }

    /// True if `node` statically produces an f64 number using only operations
    /// the widened fast path implements with semantics identical to the
    /// general interpreter. Variables are allowed (their runtime tag is
    /// checked by the VM prescan before execution).
    fn isFastPathNumeric(self: *Compiler, node: *const Node) bool {
        return switch (node.type) {
            .number => true,
            .variable => true,
            .binary_op => switch (node.data.binary_op.op) {
                .add, .sub, .mul, .div, .pow, .mod => self.isFastPathNumeric(node.data.binary_op.lhs) and
                    self.isFastPathNumeric(node.data.binary_op.rhs),
                // Assignment to a plain variable; value is the (numeric) rhs
                .store_var => node.data.binary_op.lhs.type == .variable and
                    self.isFastPathNumeric(node.data.binary_op.rhs),
                else => false,
            },
            .unary_op => switch (node.data.unary_op.op) {
                .neg, .pos => self.isFastPathNumeric(node.data.unary_op.expr),
                else => false,
            },
            .ternary => self.isFastPathCond(node.data.ternary.cond) and
                self.isFastPathNumeric(node.data.ternary.then_expr) and
                self.isFastPathNumeric(node.data.ternary.else_expr),
            .sequence => blk: {
                const exprs = node.data.sequence.exprs;
                if (exprs.len == 0) break :blk false;
                for (exprs[0 .. exprs.len - 1]) |e| {
                    if (!self.isFastPathStatement(e)) break :blk false;
                }
                break :blk self.isFastPathNumeric(exprs[exprs.len - 1]);
            },
            // Loops leave a numeric 0.0 as their result
            .while_loop => self.isFastPathCond(node.data.while_loop.cond) and
                self.isFastPathStatement(node.data.while_loop.body),
            .for_loop => blk: {
                const f = node.data.for_loop;
                if (f.init) |n| if (!self.isFastPathStatement(n)) break :blk false;
                if (f.cond) |n| if (!self.isFastPathCond(n)) break :blk false;
                if (f.post) |n| if (!self.isFastPathStatement(n)) break :blk false;
                break :blk self.isFastPathStatement(f.body);
            },
            // Whitelisted scalar builtins (sin/cos/exp/...): number -> number,
            // replicated bit-exactly by executeNumbersFast. Named args and
            // predicates change emission order / semantics — excluded.
            .function_call => blk: {
                // The parser always allocates arg_names (null entries for
                // positional args); only actual named args change emission.
                if (node.data.function_call.arg_names) |names| {
                    for (names) |n| if (n != null) break :blk false;
                }
                if (node.data.function_call.predicate != null) break :blk false;
                const resolved = self.resolveFunction(node.data.function_call.name) orelse break :blk false;
                if (resolved.tag != .builtin) break :blk false;
                const args = node.data.function_call.args;
                if (!bytecode.isFastPathBuiltin(@enumFromInt(resolved.id), args.len)) break :blk false;
                for (args) |arg| {
                    if (!self.isFastPathNumeric(arg)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    /// True if `node` is valid in a condition position of the widened fast
    /// path: booleans are represented as 1.0/0.0 and numbers use the same
    /// truthiness (!= 0) as the general interpreter's jmp_if_false/jmp_if_true.
    fn isFastPathCond(self: *Compiler, node: *const Node) bool {
        return switch (node.type) {
            .boolean => true,
            .binary_op => switch (node.data.binary_op.op) {
                .lt, .le, .gt, .ge, .eq, .ne => self.isFastPathCond(node.data.binary_op.lhs) and
                    self.isFastPathCond(node.data.binary_op.rhs),
                .and_, .or_ => self.isFastPathCond(node.data.binary_op.lhs) and
                    self.isFastPathCond(node.data.binary_op.rhs),
                else => self.isFastPathNumeric(node),
            },
            .unary_op => switch (node.data.unary_op.op) {
                .not_ => self.isFastPathCond(node.data.unary_op.expr),
                else => self.isFastPathNumeric(node),
            },
            else => self.isFastPathNumeric(node),
        };
    }

    /// Statements in sequences/loop bodies have their value discarded, so
    /// both numeric and boolean-producing expressions are allowed.
    fn isFastPathStatement(self: *Compiler, node: *const Node) bool {
        return self.isFastPathNumeric(node) or self.isFastPathCond(node);
    }

    pub fn toLaTeX(self: *Compiler, allocator: std.mem.Allocator) ![]const u8 {
        const root = self.expression() catch |err| {
            self.setErrorFrom(err);
            return err;
        };
        return try latex.nodeToLaTeX(root, allocator);
    }

    /// Peephole optimizer pass after initial compilation.
    /// Single O(n) compaction pass: `r` reads the original stream, `w` writes
    /// the fused stream in place (w <= r always). Backward-looking patterns
    /// inspect the already-written output at w-1, forward-looking patterns the
    /// not-yet-consumed input at r+1/r+2.
    ///
    /// Fusions delete instructions, which shifts the indices absolute jump
    /// operands point at, so a remap table (old index -> new index) is built
    /// during compaction and every jmp/jmp_if_* operand is rewritten at the
    /// end. Instructions consumed into a fusion map to the fused head, which
    /// is only valid for targets at the head itself — compiler-emitted jumps
    /// always land on expression starts, and fusion windows never span a jump,
    /// so interior targets cannot occur (asserted in debug builds).
    fn optimizeBytecode(self: *Compiler) !void {
        const code = self.builder.code.items;
        const offsets = self.builder.source_offsets.items;

        var has_jumps = false;
        for (code) |instr| {
            switch (instr.opcode) {
                .jmp, .jmp_if_false, .jmp_if_true => has_jumps = true,
                else => {},
            }
        }

        // old instruction index -> new index (+1 slot for end-of-code targets)
        const remap: []u32 = if (has_jumps)
            try self.node_arena.allocator().alloc(u32, code.len + 1)
        else
            &.{};
        // Marks instructions consumed as the 2nd/3rd element of a fusion; a
        // jump target on one of these would be a miscompile (see doc comment).
        const interior: []bool = if (has_jumps)
            try self.node_arena.allocator().alloc(bool, code.len + 1)
        else
            &.{};
        if (has_jumps) @memset(interior, false);

        var r: usize = 0;
        var w: usize = 0;
        while (r < code.len) {
            // Pattern: load_var + push_const + get_index 1 (Matrix indexing)
            if (r + 2 < code.len) {
                const op1 = code[r];
                const op2 = code[r + 1];
                const op3 = code[r + 2];

                if (op1.opcode == .load_var and
                    op2.opcode == .push_const and
                    op3.opcode == .get_index and op3.operand == 1)
                {
                    const var_idx = op1.operand;
                    const const_idx = op2.operand;

                    // Check if constant is a small integer (0-3) for even faster path
                    const idx_val = self.builder.constants.items[const_idx];
                    if (idx_val.tag == .number) {
                        const idx = idx_val.data.number;
                        var fused: ?Instruction = null;
                        if (idx == 0) {
                            fused = Instruction.initWithOperand(.load_var_index_0, var_idx);
                        } else if (idx == 1) {
                            fused = Instruction.initWithOperand(.load_var_index_1, var_idx);
                        } else if (idx == 2) {
                            fused = Instruction.initWithOperand(.load_var_index_2, var_idx);
                        } else if (idx == 3) {
                            fused = Instruction.initWithOperand(.load_var_index_3, var_idx);
                        } else if (var_idx <= 0xFFF and const_idx <= 0xFFF) {
                            // General case: load_var_index_const
                            const operand: u24 = @as(u24, var_idx) | (@as(u24, const_idx) << 12);
                            fused = Instruction.initWithOperand(.load_var_index_const, operand);
                        }

                        if (fused) |fused_instr| {
                            if (has_jumps) {
                                remap[r] = @intCast(w);
                                remap[r + 1] = @intCast(w);
                                remap[r + 2] = @intCast(w);
                                interior[r + 1] = true;
                                interior[r + 2] = true;
                            }
                            code[w] = fused_instr;
                            offsets[w] = offsets[r];
                            w += 1;
                            r += 3;
                            continue;
                        }
                    }
                }
            }

            // Pattern: load_var + load_var + mul/sub
            if (r + 2 < code.len) {
                const op1 = code[r];
                const op2 = code[r + 1];
                const op3 = code[r + 2];

                if (op1.opcode == .load_var and op2.opcode == .load_var) {
                    if (op3.opcode == .mul or op3.opcode == .sub) {
                        const var_a = op1.operand;
                        const var_b = op2.operand;

                        // Safety gate: only fuse when both operands are known numeric variables.
                        // Otherwise matrix/series/unit values would be miscompiled into numeric ops.
                        const gate_ok = if (self.variable_tags) |tags|
                            var_a < tags.len and var_b < tags.len and
                                tags[var_a] == .number and tags[var_b] == .number
                        else
                            true;

                        if (!gate_ok) {
                            // Copy the instruction unchanged (matches the old
                            // `i += 1; continue` which skipped later patterns).
                            if (has_jumps) remap[r] = @intCast(w);
                            code[w] = code[r];
                            offsets[w] = offsets[r];
                            w += 1;
                            r += 1;
                            continue;
                        }

                        if (var_a <= 0xFFF and var_b <= 0xFFF) {
                            const new_op: bytecode.Opcode = if (op3.opcode == .mul) .load_mul else .load_sub;
                            const operand: u24 = @as(u24, var_a) | (@as(u24, var_b) << 12);
                            if (has_jumps) {
                                remap[r] = @intCast(w);
                                remap[r + 1] = @intCast(w);
                                remap[r + 2] = @intCast(w);
                                interior[r + 1] = true;
                                interior[r + 2] = true;
                            }
                            code[w] = Instruction.initWithOperand(new_op, operand);
                            offsets[w] = offsets[r];
                            w += 1;
                            r += 3;
                            continue;
                        }
                    }
                }
            }

            // Pattern: dup + store_var + pop -> store_var
            // (assignment whose result is discarded; store_var pops its value anyway)
            if (r + 2 < code.len) {
                if (code[r].opcode == .dup and
                    code[r + 1].opcode == .store_var and
                    code[r + 2].opcode == .pop)
                {
                    if (has_jumps) {
                        remap[r] = @intCast(w);
                        remap[r + 1] = @intCast(w);
                        remap[r + 2] = @intCast(w);
                        interior[r + 1] = true;
                        interior[r + 2] = true;
                    }
                    code[w] = code[r + 1];
                    offsets[w] = offsets[r + 1];
                    w += 1;
                    r += 3;
                    continue;
                }
            }

            // Pattern: ... + push_const + mul -> ... + const_mul
            if (self.builder.is_number_only and w > 0) {
                const op_prev = code[w - 1];
                const op_curr = code[r];

                if (op_prev.opcode == .push_const and op_curr.opcode == .mul) {
                    if (has_jumps) {
                        remap[r] = @intCast(w - 1);
                        interior[r] = true;
                    }
                    code[w - 1] = Instruction.initWithOperand(.const_mul, op_prev.operand);
                    r += 1;
                    continue;
                }
            }

            // Pattern: [val, val, val, mat_create 3] -> [val, val, val, mat_create_3]
            // Note: mat_create operand for [3; 1] is (3) | (1 << 12) = 4099
            var instr = code[r];
            if (instr.opcode == .mat_create and instr.operand == 4099) {
                instr.opcode = .mat_create_3;
            }
            if (has_jumps) remap[r] = @intCast(w);
            code[w] = instr;
            offsets[w] = offsets[r];
            w += 1;
            r += 1;
        }

        // Rewrite absolute jump targets through the remap table.
        if (has_jumps) {
            remap[code.len] = @intCast(w); // jumps may target end-of-code
            for (code[0..w]) |*out_instr| {
                switch (out_instr.opcode) {
                    .jmp, .jmp_if_false, .jmp_if_true => {
                        std.debug.assert(!interior[out_instr.operand]);
                        out_instr.operand = @intCast(remap[out_instr.operand]);
                    },
                    else => {},
                }
            }
        }

        self.builder.code.items.len = w;
        self.builder.source_offsets.items.len = w;
    }

    fn allocNode(self: *Compiler) !*Node {
        return self.node_arena.allocator().create(Node);
    }

    /// Get or create variable index
    pub fn getOrCreateVariable(self: *Compiler, name: []const u8) u24 {
        if (self.variables.get(name)) |index| {
            return index;
        }

        if (self.parent) |p| {
            return p.getOrCreateVariable(name);
        }

        const index = self.next_var_index;
        self.variables.put(name, index) catch {};
        self.next_var_index += 1;
        return index;
    }

    fn isShadowed(self: *const Compiler, name: []const u8) bool {
        if (self.shadow_scope) |scope| {
            if (scope.contains(name)) return true;
        }
        if (self.parent) |p| {
            return p.isShadowed(name);
        }
        return false;
    }

    fn whileLoop(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;
        // Parse condition
        const cond = try self.expression();

        // Parse body
        const body = try self.expression();

        const node = try self.allocNode();
        node.* = .{ .type = .while_loop, .start = start, .data = .{ .while_loop = .{
            .cond = cond,
            .body = body,
        } } };
        return node;
    }

    fn forLoop(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;

        if (self.current.type == .lparen) {
            self.advance();
        } else {
            self.had_error = true;
            return error.ExpectedRightParen;
        }

        // Init
        var init_node: ?*Node = null;
        if (self.current.type != .semicolon) {
            init_node = try self.expression();
        }
        if (self.current.type == .semicolon) {
            self.advance();
        } else {
            self.had_error = true;
            return error.UnexpectedToken;
        }

        // Cond
        var cond: ?*Node = null;
        if (self.current.type != .semicolon) {
            cond = try self.expression();
        }
        if (self.current.type == .semicolon) {
            self.advance();
        } else {
            self.had_error = true;
            return error.UnexpectedToken;
        }

        // Post
        var post: ?*Node = null;
        if (self.current.type != .rparen) {
            post = try self.expression();
        }

        if (self.current.type == .rparen) {
            self.advance();
        } else {
            self.had_error = true;
            return error.ExpectedRightParen;
        }

        // Body
        const body = try self.expression();

        const node = try self.allocNode();
        node.* = .{ .type = .for_loop, .start = start, .data = .{ .for_loop = .{
            .init = init_node,
            .cond = cond,
            .post = post,
            .body = body,
        } } };
        return node;
    }

    // fn whileLoop removed (duplicate)
    // fn forLoop removed (duplicate)

    fn expression(self: *Compiler) CompileError!*Node {
        return try self.parsePrecedence(.assignment);
    }

    fn parsePrecedence(self: *Compiler, min_prec: Precedence) CompileError!*Node {
        self.advance();

        // Prefix expression
        var left = try switch (self.previous.type) {
            .number => self.number(),
            .string => self.string_literal(),
            .identifier, .kw_in, .kw_to => self.identifier(),
            .lparen => self.grouping(),
            .lbracket => self.matrix(),
            .lbrace => self.blockOrRecord(),
            .minus => self.unary(.neg),
            .bang, .kw_not => self.unary(.not_),
            .tilde => self.unary(.bnot),
            .kw_true => self.literal(Value.initBoolean(true)),
            .kw_false => self.literal(Value.initBoolean(false)),
            .kw_while => self.whileLoop(),
            .kw_for => self.forLoop(),
            .complex_i => self.complexI(),
            .unit_literal => self.unitLiteral(),
            else => {
                self.had_error = true;
                return error.UnexpectedToken;
            },
        };

        // Infix expressions
        while (true) {
            const next_prec = self.getInfixPrecedence();
            if (@intFromEnum(next_prec) < @intFromEnum(min_prec)) {
                // Check for implicit multiplication (juxtaposition)
                // Implicit multiplication has precedence higher than * /
                if (@intFromEnum(Precedence.implicit_mul) >= @intFromEnum(min_prec) and self.isImplicitMulFollows()) {
                    const right = try self.parsePrecedence(Precedence.implicit_mul);
                    const node = try self.allocNode();
                    node.* = .{ .type = .binary_op, .data = .{ .binary_op = .{ .op = .mul, .lhs = left, .rhs = right } } };
                    left = node;
                    continue;
                }
                break;
            }

            self.advance();
            left = try self.infix(left);
        }

        // Ternary operator support
        if (min_prec == .assignment and self.current.type == .question) {
            const start = self.current.start;
            self.advance(); // consume '?'
            const then_expr = try self.expression();
            if (self.current.type != .colon) {
                self.had_error = true;
                return error.UnexpectedToken;
            }
            self.advance(); // consume ':'
            const else_expr = try self.expression();

            const node = try self.allocNode();
            node.* = .{ .type = .ternary, .start = start, .data = .{ .ternary = .{
                .cond = left,
                .then_expr = then_expr,
                .else_expr = else_expr,
            } } };
            left = node;
        }

        return left;
    }

    fn isImplicitMulFollows(self: *Compiler) bool {
        if (self.getInfixPrecedence() != .none) {
            return false;
        }
        return switch (self.current.type) {
            .number, .identifier, .lparen, .unit_literal, .complex_i => true,
            else => false,
        };
    }

    fn unitLiteral(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;
        const lexeme = self.previous.lexeme(self.source);
        const inner = lexeme[1 .. lexeme.len - 1]; // strip [ and ]

        // For now, we resolve it by recursively parsing it as an expression
        // but restricted to units.
        var sub_compiler = try Compiler.init(self.node_arena.allocator(), inner);
        sub_compiler.registry = self.registry;
        defer sub_compiler.deinit();

        var root = sub_compiler.expression() catch return error.UnknownUnit;

        if (sub_compiler.current.type != .eof) {
            return error.UnknownUnit;
        }

        root = sub_compiler.simplify(root) catch return error.UnknownUnit;

        // The result of parsing the inner expression should ideally be a Unit node
        // or a combination of units.
        // We just return the AST node from the sub-parser.
        // Note: We need to clone the node into our arena.
        const res = try self.cloneNode(root);
        res.start = start;
        return res;
    }

    fn cloneNode(self: *Compiler, node: *Node) !*Node {
        const new_node = try self.allocNode();
        new_node.type = node.type;
        new_node.start = node.start;
        switch (node.type) {
            .number => new_node.data = .{ .number = node.data.number },
            .boolean => new_node.data = .{ .boolean = node.data.boolean },
            .complex => new_node.data = .{ .complex = node.data.complex },
            .variable => new_node.data = .{ .variable = try self.node_arena.allocator().dupe(u8, node.data.variable) },
            .string => new_node.data = .{ .string = try self.node_arena.allocator().dupe(u8, node.data.string) },
            .unit => {
                new_node.data = .{ .unit = node.data.unit };
                if (node.data.unit.name) |n| {
                    new_node.data.unit.name = try self.node_arena.allocator().dupe(u8, n);
                }
            },
            .binary_op => {
                new_node.data = .{ .binary_op = .{
                    .op = node.data.binary_op.op,
                    .lhs = try self.cloneNode(node.data.binary_op.lhs),
                    .rhs = try self.cloneNode(node.data.binary_op.rhs),
                } };
            },
            .unary_op => {
                new_node.data = .{ .unary_op = .{
                    .op = node.data.unary_op.op,
                    .expr = try self.cloneNode(node.data.unary_op.expr),
                } };
            },
            .member_access => {
                new_node.data = .{ .member_access = .{
                    .object = try self.cloneNode(node.data.member_access.object),
                    .field = try self.node_arena.allocator().dupe(u8, node.data.member_access.field),
                } };
            },
            .dynamic_access => {
                const keys = try self.node_arena.allocator().alloc(*Node, node.data.dynamic_access.keys.len);
                for (node.data.dynamic_access.keys, 0..) |k, i| {
                    keys[i] = try self.cloneNode(k);
                }
                new_node.data = .{ .dynamic_access = .{
                    .object = try self.cloneNode(node.data.dynamic_access.object),
                    .keys = keys,
                } };
            },
            .slice => {
                new_node.data = .{ .slice = .{
                    .start = if (node.data.slice.start) |s| try self.cloneNode(s) else null,
                    .end = if (node.data.slice.end) |e| try self.cloneNode(e) else null,
                    .step = if (node.data.slice.step) |s| try self.cloneNode(s) else null,
                } };
            },
            .function_call => {
                const args = try self.node_arena.allocator().alloc(*Node, node.data.function_call.args.len);
                for (node.data.function_call.args, 0..) |arg, i| {
                    args[i] = try self.cloneNode(arg);
                }
                new_node.data = .{ .function_call = .{
                    .name = try self.node_arena.allocator().dupe(u8, node.data.function_call.name),
                    .args = args,
                } };
            },
            .matrix => {
                const elements = try self.node_arena.allocator().alloc(*Node, node.data.matrix.elements.len);
                for (node.data.matrix.elements, 0..) |el, i| {
                    elements[i] = try self.cloneNode(el);
                }
                new_node.data = .{ .matrix = .{
                    .rows = node.data.matrix.rows,
                    .cols = node.data.matrix.cols,
                    .elements = elements,
                } };
            },
            .polynomial => {
                new_node.data = .{ .polynomial = .{
                    .var_name = try self.node_arena.allocator().dupe(u8, node.data.polynomial.var_name),
                    .coeffs = try self.node_arena.allocator().dupe(f64, node.data.polynomial.coeffs),
                } };
            },
            .ternary => {
                new_node.data = .{ .ternary = .{
                    .cond = try self.cloneNode(node.data.ternary.cond),
                    .then_expr = try self.cloneNode(node.data.ternary.then_expr),
                    .else_expr = try self.cloneNode(node.data.ternary.else_expr),
                } };
            },
            .record_literal => {
                const fields = try self.node_arena.allocator().alloc(RecordField, node.data.record_literal.fields.len);
                for (node.data.record_literal.fields, 0..) |field, i| {
                    fields[i] = .{
                        .key = try self.node_arena.allocator().dupe(u8, field.key),
                        .value = try self.cloneNode(field.value),
                    };
                }
                new_node.data = .{ .record_literal = .{ .fields = @ptrCast(fields) } };
            },
            .function_def => {
                const params = try self.node_arena.allocator().alloc([]const u8, node.data.function_def.params.len);
                for (node.data.function_def.params, 0..) |p, i| {
                    params[i] = try self.node_arena.allocator().dupe(u8, p);
                }
                new_node.data = .{ .function_def = .{
                    .name = try self.node_arena.allocator().dupe(u8, node.data.function_def.name),
                    .params = params,
                    .body = try self.cloneNode(node.data.function_def.body),
                } };
            },
            .sequence => {
                const exprs = try self.node_arena.allocator().alloc(*Node, node.data.sequence.exprs.len);
                for (node.data.sequence.exprs, 0..) |expr, i| {
                    exprs[i] = try self.cloneNode(expr);
                }
                new_node.data = .{ .sequence = .{ .exprs = exprs } };
            },
            .while_loop => {
                new_node.data = .{ .while_loop = .{
                    .cond = try self.cloneNode(node.data.while_loop.cond),
                    .body = try self.cloneNode(node.data.while_loop.body),
                } };
            },
            .for_loop => {
                // Not implemented parsing yet, but AST exists
                new_node.data = .{ .for_loop = .{
                    .init = if (node.data.for_loop.init) |n| try self.cloneNode(n) else null,
                    .cond = if (node.data.for_loop.cond) |n| try self.cloneNode(n) else null,
                    .post = if (node.data.for_loop.post) |n| try self.cloneNode(n) else null,
                    .body = try self.cloneNode(node.data.for_loop.body),
                } };
            },
        }
        return new_node;
    }

    fn number(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;
        const raw_lexeme = self.previous.lexeme(self.source);

        // Strip underscores if present
        var buffer: [128]u8 = undefined;
        var lexeme: []const u8 = raw_lexeme;
        var i: usize = 0;

        // If it starts with '.', prepend '0' for parseFloat compatibility
        if (raw_lexeme.len > 0 and raw_lexeme[0] == '.') {
            buffer[0] = '0';
            i = 1;
        }

        for (raw_lexeme) |c| {
            if (c != '_') {
                if (i >= buffer.len) {
                    self.had_error = true;
                    return error.InvalidNumber;
                }
                buffer[i] = c;
                i += 1;
            }
        }
        lexeme = buffer[0..i];

        var val: f64 = 0;

        if (std.mem.startsWith(u8, lexeme, "0x") or std.mem.startsWith(u8, lexeme, "0X")) {
            val = @floatFromInt(std.fmt.parseInt(i64, lexeme[2..], 16) catch {
                self.had_error = true;
                return error.InvalidNumber;
            });
        } else if (std.mem.startsWith(u8, lexeme, "0b") or std.mem.startsWith(u8, lexeme, "0B")) {
            val = @floatFromInt(std.fmt.parseInt(i64, lexeme[2..], 2) catch {
                self.had_error = true;
                return error.InvalidNumber;
            });
        } else {
            val = std.fmt.parseFloat(f64, lexeme) catch {
                self.had_error = true;
                return error.InvalidNumber;
            };
        }

        const node = try self.allocNode();
        node.* = .{ .type = .number, .start = start, .data = .{ .number = val } };
        return node;
    }

    fn string_literal(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;
        const lexeme = self.previous.lexeme(self.source);
        const inner = lexeme[1 .. lexeme.len - 1]; // strip quotes

        const node = try self.allocNode();
        node.* = .{ .type = .string, .start = start, .data = .{ .string = try self.node_arena.allocator().dupe(u8, inner) } };
        return node;
    }

    fn identifier(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;
        const name = self.previous.lexeme(self.source);

        if (self.current.type == .lparen) {
            return try self.functionCall(name);
        }

        // 1. Check if it's an existing variable or shadowed (e.g., parameter)
        if (self.variables.contains(name) or self.isShadowed(name)) {
            return try self.createVarNode(name);
        }

        // 2. Resolve as unit
        if (self.registry.findUnit(name)) |res| {
            const node = try self.allocNode();
            const scale = res.unit.scale * res.prefix_scale;
            node.* = .{
                .type = .unit,
                .start = start,
                .data = .{
                    .unit = .{
                        .value = scale + res.unit.offset, // Normalized value for 1 unit
                        .scale = scale,
                        .offset = res.unit.offset,
                        .dimensions = res.unit.dimensions,
                        .name = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, name) else try self.node_arena.allocator().dupe(u8, name),
                    },
                },
            };
            return node;
        }

        // Prioritize built-in names as identifiers to allow shadowing
        // (Prevents decomposition into units like sin -> s * in)
        if (getBuiltinId(name)) |_| {
            return try self.createVarNode(name);
        }

        // 3. Attempt to decompose into multiple units (e.g. "sm" -> "s" * "m")
        if (try self.decomposeUnit(name)) |node| {
            node.start = start;
            return node;
        }

        return try self.createVarNode(name);
    }

    fn decomposeUnit(self: *Compiler, name: []const u8) CompileError!?*Node {
        // Simple greedy decomposition: find longest prefix that is a valid unit
        if (name.len == 0) return null;

        var longest_match_len: usize = 0;
        const FindUnitResult = @TypeOf(self.registry.findUnit("").?);
        var longest_match_res: ?FindUnitResult = null;

        var i: usize = name.len;
        while (i > 0) : (i -= 1) {
            const prefix = name[0..i];
            if (self.registry.findUnit(prefix)) |res| {
                longest_match_len = i;
                longest_match_res = res;
                break; // Greedy match found
            }
        }

        if (longest_match_res) |res| {
            // We found a unit prefix. Now check if the rest is valid (recursively)
            // But first, "rest" must handle being empty? No, handled above.
            if (longest_match_len == name.len) return null; // Should have been caught by direct findUnit

            const rest = name[longest_match_len..];

            // Recursively decompose the rest
            // We can treat the rest as another decomposition attempt or a direct unit lookup
            // Let's try recursive decompose first, which covers single unit rest too.
            // But we need to be careful about infinite recursion if decompose returns null for single unit?
            // Actually decompose returns AST node.

            var rest_node: ?*Node = null;

            // Try finding rest as a unit directly first
            if (self.registry.findUnit(rest)) |rest_res| {
                const node = try self.allocNode();
                const scale = rest_res.unit.scale * rest_res.prefix_scale;
                node.* = .{
                    .type = .unit,
                    .data = .{
                        .unit = .{
                            .value = scale + rest_res.unit.offset,
                            .scale = scale,
                            .offset = rest_res.unit.offset,
                            .dimensions = rest_res.unit.dimensions,
                            .name = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, rest) else try self.node_arena.allocator().dupe(u8, rest),
                        },
                    },
                };
                rest_node = node;
            } else {
                // Try decomposing rest
                rest_node = try self.decomposeUnit(rest);
            }

            if (rest_node) |rhs| {
                // Success! Create the LHS unit node
                const lhs = try self.allocNode();
                const scale = res.unit.scale * res.prefix_scale;
                const lhs_name = name[0..longest_match_len];
                lhs.* = .{
                    .type = .unit,
                    .data = .{
                        .unit = .{
                            .value = scale + res.unit.offset,
                            .scale = scale,
                            .offset = res.unit.offset,
                            .dimensions = res.unit.dimensions,
                            .name = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, lhs_name) else try self.node_arena.allocator().dupe(u8, lhs_name),
                        },
                    },
                };

                // Create Mul node
                const mul = try self.allocNode();
                mul.* = .{
                    .type = .binary_op,
                    .data = .{
                        .binary_op = .{
                            .op = .mul,
                            .lhs = lhs,
                            .rhs = rhs,
                        },
                    },
                };
                return mul;
            }
        }

        return null;
    }

    fn createVarNode(self: *Compiler, name: []const u8) !*Node {
        const node = try self.allocNode();
        node.* = .{ .type = .variable, .start = self.previous.start, .data = .{ .variable = name } };
        return node;
    }

    fn functionCall(self: *Compiler, name: []const u8) CompileError!*Node {
        const start = self.previous.start;
        self.advance(); // consume '('

        // Count and compile arguments
        var args = std.ArrayListUnmanaged(*Node).empty;
        var arg_names = std.ArrayListUnmanaged(?[]const u8).empty;
        const allocator = self.node_arena.allocator();

        if (self.current.type != .rparen) {
            while (true) {
                if (self.current.type == .identifier and self.next.type == .colon) {
                    const arg_name = self.current.lexeme(self.source);
                    self.advance(); // identifier
                    self.advance(); // colon
                    try args.append(allocator, try self.expression());
                    try arg_names.append(allocator, try allocator.dupe(u8, arg_name));
                } else {
                    try args.append(allocator, try self.expression());
                    try arg_names.append(allocator, null);
                }

                if (self.current.type != .comma) break;
                self.advance();
            }
        }

        if (self.current.type != .rparen) {
            self.had_error = true;
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        var predicate: ?*Node = null;
        if (self.current.type == .kw_where) {
            self.advance(); // consume 'where'
            predicate = try self.expression();
            predicate = try self.simplify(predicate.?);
        }

        const node = try self.allocNode();
        node.* = .{ .type = .function_call, .start = start, .data = .{ .function_call = .{
            .name = name,
            .args = try args.toOwnedSlice(allocator),
            .arg_names = try arg_names.toOwnedSlice(allocator),
            .predicate = predicate,
        } } };
        return node;
    }

    fn grouping(self: *Compiler) CompileError!*Node {
        const node = try self.expression();
        if (self.current.type != .rparen) {
            self.had_error = true;
            return error.ExpectedRightParen;
        }
        self.advance();
        return node;
    }

    fn matrix(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;
        var elements = std.ArrayListUnmanaged(*Node).empty;
        const allocator = self.node_arena.allocator();
        var rows: u32 = 0;
        var cols: u32 = 0;
        var current_row_cols: u32 = 0;

        if (self.current.type != .rbracket) {
            rows = 1;
            while (true) {
                try elements.append(allocator, try self.expression());
                current_row_cols += 1;

                if (self.current.type == .comma) {
                    self.advance();
                    continue;
                } else if (self.current.type == .semicolon) {
                    if (cols == 0) cols = current_row_cols else if (cols != current_row_cols) return error.CompileError;
                    current_row_cols = 0;
                    rows += 1;
                    self.advance();
                    continue;
                } else if (self.current.type == .rbracket) {
                    if (cols == 0) cols = current_row_cols else if (cols != current_row_cols) return error.CompileError;
                    break;
                } else {
                    return error.UnexpectedToken;
                }
            }
        }

        if (self.current.type != .rbracket) {
            self.had_error = true;
            return error.ExpectedRightBracket;
        }
        self.advance();

        const node = try self.allocNode();
        node.* = .{ .type = .matrix, .start = start, .data = .{ .matrix = .{
            .rows = rows,
            .cols = cols,
            .elements = try elements.toOwnedSlice(allocator),
        } } };
        return node;
    }

    fn blockOrRecord(self: *Compiler) CompileError!*Node {
        const start = self.previous.start;

        // Disambiguation:
        // If next token is 'colon', it's a record literal: { key: ... }
        // Otherwise it's a block: { expr; ... }

        if (self.current.type == .rbrace) {
            self.advance();
            const node = try self.allocNode();
            node.* = .{ .type = .record_literal, .start = start, .data = .{ .record_literal = .{ .fields = &.{} } } };
            return node;
        }

        var is_record = false;
        if ((self.current.type == .identifier or self.current.type == .string) and self.next.type == .colon) {
            is_record = true;
        }

        if (is_record) {
            return try self.recordLiteral(start);
        } else {
            return try self.block(start);
        }
    }

    fn recordLiteral(self: *Compiler, start: u32) CompileError!*Node {
        var fields = std.ArrayListUnmanaged(RecordField).empty;
        const allocator = self.node_arena.allocator();

        while (true) {
            // ... (existing record literal parsing)
            // Parse field name
            var key: []const u8 = undefined;
            if (self.current.type == .identifier) {
                self.advance();
                key = self.previous.lexeme(self.source);
            } else if (self.current.type == .string) {
                self.advance();
                const raw = self.previous.lexeme(self.source);
                key = raw[1 .. raw.len - 1];
            } else {
                self.had_error = true;
                return error.UnexpectedToken;
            }

            if (self.current.type != .colon) {
                self.had_error = true;
                return error.UnexpectedToken;
            }
            self.advance(); // :

            const value = try self.expression();
            try fields.append(allocator, .{ .key = key, .value = value });

            if (self.current.type == .comma) {
                self.advance();
            } else if (self.current.type == .rbrace) {
                break;
            } else {
                self.had_error = true;
                return error.UnexpectedToken;
            }
        }

        self.advance(); // }
        const node = try self.allocNode();
        const fields_slice = try fields.toOwnedSlice(allocator);
        node.* = .{ .type = .record_literal, .start = start, .data = .{ .record_literal = .{ .fields = @ptrCast(fields_slice) } } };
        return node;
    }

    fn block(self: *Compiler, start: u32) CompileError!*Node {
        var exprs = std.ArrayListUnmanaged(*Node).empty;
        const allocator = self.node_arena.allocator();

        while (self.current.type != .rbrace and self.current.type != .eof) {
            const expr = try self.expression();
            try exprs.append(allocator, expr);

            if (self.current.type == .semicolon) {
                self.advance();
            }
        }

        if (self.current.type != .rbrace) {
            self.had_error = true;
            return error.ExpectedRightBrace;
        }
        self.advance();

        const node = try self.allocNode();
        node.* = .{ .type = .sequence, .start = start, .data = .{ .sequence = .{ .exprs = try exprs.toOwnedSlice(allocator) } } };
        return node;
    }

    // fn whileLoop removed (duplicate)
    // fn forLoop removed (duplicate)

    // fn blockOrRecord removed (duplicate)

    // fn recordLiteral removed (duplicate 2)
    // fn block removed (duplicate 2)

    fn unary(self: *Compiler, op: Opcode) CompileError!*Node {
        const start = self.previous.start;
        const expr = try self.parsePrecedence(.unary);
        const node = try self.allocNode();
        node.* = .{ .type = .unary_op, .start = start, .data = .{ .unary_op = .{ .op = op, .expr = expr } } };
        return node;
    }

    fn literal(self: *Compiler, value: Value) CompileError!*Node {
        const node = try self.allocNode();
        node.start = self.previous.start;
        if (value.tag == .boolean) {
            node.* = .{ .type = .boolean, .start = self.previous.start, .data = .{ .boolean = value.data.boolean } };
        } else {
            node.* = .{ .type = .number, .start = self.previous.start, .data = .{ .number = value.toNumber() orelse 0 } };
        }
        return node;
    }

    fn complexI(self: *Compiler) CompileError!*Node {
        const node = try self.allocNode();
        node.* = .{ .type = .complex, .start = self.previous.start, .data = .{ .complex = .{ .re = 0, .im = 1 } } };
        return node;
    }

    fn parseSlice(self: *Compiler) CompileError!*Node {
        const start = self.current.start;
        var start_expr: ?*Node = null;
        var end_expr: ?*Node = null;
        var step_expr: ?*Node = null;
        var is_slice = false;

        // Check for leading colon (start omitted)
        if (self.current.type == .colon) {
            is_slice = true;
            self.advance();
            // Parse end (optional)
            if (self.current.type != .comma and self.current.type != .rbracket and self.current.type != .colon) {
                end_expr = try self.expression();
            }
        } else {
            // Parse start
            start_expr = try self.expression();

            // Check for colon
            if (self.current.type == .colon) {
                is_slice = true;
                self.advance();
                // Parse end (optional)
                if (self.current.type != .comma and self.current.type != .rbracket and self.current.type != .colon) {
                    end_expr = try self.expression();
                }
            }
        }

        // Check for second colon (step)
        if (is_slice and self.current.type == .colon) {
            self.advance();
            step_expr = try self.expression();
        }

        if (is_slice) {
            const node = try self.allocNode();
            node.* = .{ .type = .slice, .start = start, .data = .{ .slice = .{
                .start = start_expr,
                .end = end_expr,
                .step = step_expr,
            } } };
            return node;
        } else {
            if (start_expr) |e| return e;
            return error.UnexpectedToken;
        }
    }

    fn infix(self: *Compiler, left: *Node) CompileError!*Node {
        const start = self.previous.start;
        const op_token = self.previous.type;

        if (op_token == .dot) {
            if (self.current.type != .identifier) {
                self.had_error = true;
                return error.UnexpectedToken;
            }
            self.advance();
            const field = self.previous.lexeme(self.source);
            const node = try self.allocNode();
            node.* = .{ .type = .member_access, .start = start, .data = .{ .member_access = .{
                .object = left,
                .field = try self.node_arena.allocator().dupe(u8, field),
            } } };
            return node;
        }

        if (op_token == .lbracket) {
            var keys = std.ArrayListUnmanaged(*Node).empty;
            const allocator = self.node_arena.allocator();

            if (self.current.type != .rbracket) {
                while (true) {
                    try keys.append(allocator, try self.parseSlice());
                    if (self.current.type == .comma) {
                        self.advance();
                    } else {
                        break;
                    }
                }
            }

            if (self.current.type != .rbracket) {
                self.had_error = true;
                return error.ExpectedRightBracket;
            }
            self.advance(); // consume ']'
            const node = try self.allocNode();
            node.* = .{ .type = .dynamic_access, .start = start, .data = .{ .dynamic_access = .{
                .object = left,
                .keys = try keys.toOwnedSlice(allocator),
            } } };
            return node;
        }

        const prec = getInfixPrecedenceOf(op_token);

        // For right-associative operators (^), don't increment precedence
        const next_prec: Precedence = if (op_token == .caret)
            prec
        else
            @enumFromInt(@intFromEnum(prec) + 1);

        const node = try self.allocNode();
        node.start = start;
        if (op_token == .equal) {
            if (left.type == .function_call) {
                // Function definition: f(x, y) = body
                const name = left.data.function_call.name;
                const args = left.data.function_call.args;

                // Check if we are redefining a built-in (Task 0075)
                if (getBuiltinId(name)) |_| {
                    self.setError(try std.fmt.allocPrint(self.node_arena.allocator(), "Cannot redefine built-in function '{s}'", .{name}));
                    return error.CompileError;
                }

                var params = try self.node_arena.allocator().alloc([]const u8, args.len);
                for (args, 0..) |arg, i| {
                    if (arg.type == .variable) {
                        params[i] = arg.data.variable;
                    } else if (arg.type == .unit and arg.data.unit.name != null) {
                        // Allow shadowing units in parameter names (Task 0075)
                        params[i] = arg.data.unit.name.?;
                    } else {
                        self.setError("Parameters must be identifiers");
                        if (arg.type == .number) {
                            self.setError("Parameters must be identifiers, not numbers");
                        }
                        return error.CompileError;
                    }
                }

                // Temporarily add parameters to a shadow scope so the parser treats them as variables
                // during the parsing of the function body.
                var shadow_map = std.StringHashMap(void).init(self.node_arena.allocator());
                for (params) |p| try shadow_map.put(p, {});
                const old_shadow = self.shadow_scope;
                self.shadow_scope = &shadow_map;
                defer self.shadow_scope = old_shadow;

                const body = try self.expression();
                node.* = .{ .type = .function_def, .start = start, .data = .{ .function_def = .{
                    .name = name,
                    .params = params,
                    .body = body,
                } } };
                return node;
            } else {
                // Variable assignment: x = value
                const right = try self.parsePrecedence(next_prec);
                if (!checkAssignmentTarget(left)) {
                    self.had_error = true;
                    return error.CompileError;
                }
                // Handle unit names being shadowed by variables (e.g., m = [1,2;3,4] shadows meter)
                if (left.type == .unit and left.data.unit.name != null) {
                    const unit_name = left.data.unit.name.?;
                    _ = self.getOrCreateVariable(unit_name);
                    // Convert unit node to variable node for the assignment
                    left.type = .variable;
                    left.data = .{ .variable = unit_name };
                } else if (left.type == .variable) {
                    _ = self.getOrCreateVariable(left.data.variable);
                }
                node.* = .{ .type = .binary_op, .start = start, .data = .{ .binary_op = .{ .op = .store_var, .lhs = left, .rhs = right } } };
                return node;
            }
        }

        const op: Opcode = switch (op_token) {
            .kw_to, .kw_in, .kw_as => .unit_convert,
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .dot_star => .emul,
            .dot_slash => .ediv,
            .dot_caret => .epow,
            .percent => .mod,
            .caret => .pow,
            .equal_equal => .eq,
            .not_equal => .ne,
            .less => .lt,
            .less_equal => .le,
            .greater => .gt,
            .greater_equal => .ge,
            .ampersand_ampersand, .kw_and => .and_,
            .pipe_pipe, .kw_or => .or_,
            .ampersand => .band,
            .pipe => .bor,
            .caret_caret, .kw_xor => .bxor,
            .less_less => .shl,
            .greater_greater => .shr,
            .question => {
                const then_expr = try self.expression();
                if (self.current.type != .colon) {
                    self.had_error = true;
                    return error.UnexpectedToken;
                }
                self.advance(); // consume ':'
                const else_expr = try self.parsePrecedence(prec);
                node.* = .{ .type = .ternary, .start = start, .data = .{ .ternary = .{
                    .cond = left,
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                } } };
                return node;
            },
            .lparen => {
                const right_juxta = try self.expression();
                if (self.current.type != .rparen) {
                    self.had_error = true;
                    return error.UnexpectedToken;
                }
                self.advance(); // consume ')'
                node.* = .{ .type = .binary_op, .start = start, .data = .{ .binary_op = .{ .op = .mul, .lhs = left, .rhs = right_juxta } } };
                return node;
            },
            else => return error.UnexpectedToken,
        };

        const right = try self.parsePrecedence(next_prec);
        node.* = .{ .type = .binary_op, .start = start, .data = .{ .binary_op = .{ .op = op, .lhs = left, .rhs = right } } };
        return node;
    }

    fn simplify(self: *Compiler, node: *Node) !*Node {
        switch (node.type) {
            .binary_op => {
                node.data.binary_op.lhs = try self.simplify(node.data.binary_op.lhs);
                node.data.binary_op.rhs = try self.simplify(node.data.binary_op.rhs);

                const lhs = node.data.binary_op.lhs;
                const rhs = node.data.binary_op.rhs;
                const op = node.data.binary_op.op;

                // 1. Constant Folding
                if (lhs.type == .number and rhs.type == .number) {
                    const a = lhs.data.number;
                    const b = rhs.data.number;
                    const res: ?f64 = switch (op) {
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
                        else => null,
                    };
                    if (res) |val| {
                        const new_node = try self.allocNode();
                        new_node.* = .{ .type = .number, .data = .{ .number = val } };
                        return new_node;
                    }
                }

                // Complex Constant Folding
                if ((lhs.type == .number or lhs.type == .complex) and (rhs.type == .number or rhs.type == .complex)) {
                    const v_lhs = if (lhs.type == .number) Value.initNumber(lhs.data.number) else Value.initComplex(lhs.data.complex.re, lhs.data.complex.im);
                    const v_rhs = if (rhs.type == .number) Value.initNumber(rhs.data.number) else Value.initComplex(rhs.data.complex.re, rhs.data.complex.im);

                    const res_v = switch (op) {
                        .add => Value.add(v_lhs, v_rhs),
                        .sub => Value.sub(v_lhs, v_rhs),
                        .mul => Value.mul(v_lhs, v_rhs, null),
                        .div => Value.div(v_lhs, v_rhs, null),
                        else => Value.initUndefined(),
                    };

                    if (res_v.tag == .number) {
                        const new_node = try self.allocNode();
                        new_node.* = .{ .type = .number, .data = .{ .number = res_v.data.number } };
                        return new_node;
                    } else if (res_v.tag == .complex) {
                        const new_node = try self.allocNode();
                        new_node.* = .{ .type = .complex, .data = .{ .complex = .{ .re = res_v.data.complex.re, .im = res_v.data.complex.im } } };
                        return new_node;
                    }
                }

                // Folding Number * Unit (Attachment)
                if (op == .mul) {
                    if (lhs.type == .number and rhs.type == .unit) {
                        const new_node = try self.allocNode();
                        const mag = rhs.data.unit.value - rhs.data.unit.offset;
                        new_node.* = .{ .type = .unit, .data = .{ .unit = .{
                            .scale = rhs.data.unit.scale,
                            .offset = rhs.data.unit.offset,
                            .dimensions = rhs.data.unit.dimensions,
                            .value = mag * lhs.data.number + rhs.data.unit.offset,
                            .name = if (rhs.data.unit.name) |n| (if (self.metadata_allocator) |alloc| try alloc.dupe(u8, n) else try self.node_arena.allocator().dupe(u8, n)) else null,
                        } } };
                        return new_node;
                    }
                    if (lhs.type == .unit and rhs.type == .number) {
                        const new_node = try self.allocNode();
                        const mag = lhs.data.unit.value - lhs.data.unit.offset;
                        new_node.* = .{ .type = .unit, .data = .{ .unit = .{
                            .scale = lhs.data.unit.scale,
                            .offset = lhs.data.unit.offset,
                            .dimensions = lhs.data.unit.dimensions,
                            .value = mag * rhs.data.number + lhs.data.unit.offset,
                            .name = if (lhs.data.unit.name) |n| (if (self.metadata_allocator) |alloc| try alloc.dupe(u8, n) else try self.node_arena.allocator().dupe(u8, n)) else null,
                        } } };
                        return new_node;
                    }
                }

                // 2. Identity Rules
                if (op == .add) {
                    if (lhs.type == .number and lhs.data.number == 0) return rhs;
                    if (rhs.type == .number and rhs.data.number == 0) return lhs;
                }
                if (op == .mul) {
                    if (lhs.type == .number and lhs.data.number == 1) return rhs;
                    if (rhs.type == .number and rhs.data.number == 1) return lhs;
                    if (lhs.type == .number and lhs.data.number == 0) return lhs; // 0 * x = 0
                    if (rhs.type == .number and rhs.data.number == 0) return rhs; // x * 0 = 0
                }

                // 3. Unit Arithmetic Simplification
                if (lhs.type == .unit and rhs.type == .unit) {
                    if (op == .mul) {
                        const node_u = try self.allocNode();
                        node_u.* = .{
                            .type = .unit,
                            .data = .{
                                .unit = .{
                                    .value = lhs.data.unit.value * rhs.data.unit.value,
                                    .scale = lhs.data.unit.scale * rhs.data.unit.scale,
                                    .offset = 0, // Composite units don't inherit offsets easily
                                    .dimensions = lhs.data.unit.dimensions.multiply(rhs.data.unit.dimensions),
                                },
                            },
                        };
                        return node_u;
                    }
                    if (op == .div) {
                        const node_u = try self.allocNode();
                        node_u.* = .{
                            .type = .unit,
                            .data = .{
                                .unit = .{
                                    .value = lhs.data.unit.value / rhs.data.unit.value,
                                    .scale = lhs.data.unit.scale / rhs.data.unit.scale,
                                    .offset = 0,
                                    .dimensions = lhs.data.unit.dimensions.divide(rhs.data.unit.dimensions),
                                },
                            },
                        };
                        return node_u;
                    }
                }

                return node;
            },
            .unary_op => {
                node.data.unary_op.expr = try self.simplify(node.data.unary_op.expr);

                // Constant-fold negation of a numeric literal (same computation
                // as the runtime neg opcode, so results are bit-identical).
                // Also unlocks binary folding for e.g. `2 * -3`.
                if (node.data.unary_op.op == .neg and node.data.unary_op.expr.type == .number) {
                    const folded = try self.allocNode();
                    folded.* = .{ .type = .number, .data = .{ .number = -node.data.unary_op.expr.data.number } };
                    return folded;
                }

                return node;
            },
            .function_call => {
                for (node.data.function_call.args) |*arg| {
                    arg.* = try self.simplify(arg.*);
                }

                // 4. conv() Compile-time Evaluation
                if (std.mem.eql(u8, node.data.function_call.name, "conv") and node.data.function_call.args.len == 2) {
                    const val_node = node.data.function_call.args[0];
                    const unit_node = node.data.function_call.args[1];

                    if (unit_node.type == .unit) {
                        if (val_node.type == .number) {
                            // Number to unit conversion (interpret as unit, return UnitValue)
                            const target_scale = unit_node.data.unit.scale;
                            const res = val_node.data.number * target_scale + unit_node.data.unit.offset;
                            const new_node = try self.allocNode();
                            new_node.* = .{ .type = .unit, .data = .{ .unit = .{
                                .value = res,
                                .scale = target_scale,
                                .offset = unit_node.data.unit.offset,
                                .dimensions = unit_node.data.unit.dimensions,
                                .name = if (unit_node.data.unit.name) |n| try self.node_arena.allocator().dupe(u8, n) else null,
                            } } };
                            return new_node;
                        } else if (val_node.type == .unit) {
                            // Unit to unit conversion
                            if (val_node.data.unit.dimensions.equals(unit_node.data.unit.dimensions)) {
                                const target_scale = unit_node.data.unit.scale;
                                const res = (val_node.data.unit.value - unit_node.data.unit.offset) / target_scale;
                                const new_node = try self.allocNode();
                                new_node.* = .{ .type = .number, .data = .{ .number = res } };
                                return new_node;
                            }
                        }
                    }
                }

                return node;
            },
            .ternary => {
                node.data.ternary.cond = try self.simplify(node.data.ternary.cond);
                node.data.ternary.then_expr = try self.simplify(node.data.ternary.then_expr);
                node.data.ternary.else_expr = try self.simplify(node.data.ternary.else_expr);
                return node;
            },
            .matrix => {
                for (node.data.matrix.elements) |*el| {
                    el.* = try self.simplify(el.*);
                }
                return node;
            },
            .member_access => {
                node.data.member_access.object = try self.simplify(node.data.member_access.object);
                return node;
            },
            .dynamic_access => {
                node.data.dynamic_access.object = try self.simplify(node.data.dynamic_access.object);
                for (node.data.dynamic_access.keys) |*k| {
                    k.* = try self.simplify(k.*);
                }

                // Static Optimization: record["field"] -> record.field
                if (node.data.dynamic_access.keys.len == 1 and node.data.dynamic_access.keys[0].type == .string) {
                    const field_name = node.data.dynamic_access.keys[0].data.string;
                    const object = node.data.dynamic_access.object;
                    node.type = .member_access;
                    node.data = .{ .member_access = .{
                        .object = object,
                        .field = field_name,
                    } };
                    return node;
                }

                return node;
            },
            .slice => {
                if (node.data.slice.start) |*s| s.* = try self.simplify(s.*);
                if (node.data.slice.end) |*e| e.* = try self.simplify(e.*);
                if (node.data.slice.step) |*s| s.* = try self.simplify(s.*);
                return node;
            },
            .function_def => {
                node.data.function_def.body = try self.simplify(node.data.function_def.body);
                return node;
            },
            .complex, .number, .boolean, .variable, .string, .unit, .polynomial => return node,
            .record_literal => {
                // Since fields slice is const, we need to create new simplified fields
                const allocator = self.node_arena.allocator();
                const new_fields = try allocator.alloc(RecordField, node.data.record_literal.fields.len);
                for (node.data.record_literal.fields, 0..) |field, i| {
                    new_fields[i] = .{
                        .key = field.key,
                        .value = try self.simplify(field.value),
                    };
                }
                node.data.record_literal.fields = @ptrCast(new_fields);
                return node;
            },
            .sequence => {
                // Simplify all expressions in the sequence
                for (node.data.sequence.exprs) |*expr| {
                    expr.* = try self.simplify(expr.*);
                }
                return node;
            },
            .while_loop => {
                node.data.while_loop.cond = try self.simplify(node.data.while_loop.cond);
                node.data.while_loop.body = try self.simplify(node.data.while_loop.body);
                return node;
            },
            .for_loop => {
                if (node.data.for_loop.init) |n| node.data.for_loop.init = try self.simplify(n);
                if (node.data.for_loop.cond) |n| node.data.for_loop.cond = try self.simplify(n);
                if (node.data.for_loop.post) |n| node.data.for_loop.post = try self.simplify(n);
                node.data.for_loop.body = try self.simplify(node.data.for_loop.body);
                return node;
            },
        }
    }

    fn checkAssignmentTarget(node: *Node) bool {
        // Allow variables and unit names (for shadowing units with variables)
        return node.type == .variable or
            (node.type == .unit and node.data.unit.name != null) or
            node.type == .dynamic_access;
    }

    fn lowerPredicate(self: *Compiler, node: *Node) CompileError!*const @import("../timeseries/predicates.zig").Predicate {
        return try self.lowerPredicateRecursive(node);
    }

    fn lowerPredicateRecursive(self: *Compiler, node: *Node) CompileError!*const @import("../timeseries/predicates.zig").Predicate {
        const ts = @import("../timeseries/predicates.zig");
        const allocator = self.metadata_allocator orelse self.node_arena.allocator();

        switch (node.type) {
            .binary_op => {
                const op = node.data.binary_op.op;
                const lhs = node.data.binary_op.lhs;
                const rhs = node.data.binary_op.rhs;

                // Logical ops
                if (op == .and_ or op == .or_) {
                    const left = try allocator.create(ts.Predicate);
                    left.* = (try self.lowerPredicateRecursive(lhs)).*;
                    const right = try allocator.create(ts.Predicate);
                    right.* = (try self.lowerPredicateRecursive(rhs)).*;

                    const res = try allocator.create(ts.Predicate);
                    res.* = ts.Predicate{
                        .op = if (op == .and_) .and_ else .or_,
                        .left = left,
                        .right = right,
                    };
                    return res;
                }

                // Comparison ops
                const pred_op: ts.PredicateOp = switch (op) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    else => return error.CompileError, // Not a valid predicate op
                };

                // Pattern: <field> <op> <constant>
                if (lhs.type == .variable and (rhs.type == .number or rhs.type == .unit)) {
                    const field: ts.Field = if (std.mem.eql(u8, lhs.data.variable, "value"))
                        .value
                    else if (std.mem.eql(u8, lhs.data.variable, "time") or std.mem.eql(u8, lhs.data.variable, "timestamp"))
                        .timestamp
                    else if (std.mem.eql(u8, lhs.data.variable, "dt"))
                        .dt
                    else
                        return error.CompileError;

                    const res = try allocator.create(ts.Predicate);
                    res.* = ts.Predicate{
                        .op = pred_op,
                        .field = field,
                        .constant = if (rhs.type == .number) rhs.data.number else rhs.data.unit.value,
                    };
                    return res;
                }

                // Pattern: <constant> <op> <field> (flip it)
                if ((lhs.type == .number or lhs.type == .unit) and rhs.type == .variable) {
                    const field: ts.Field = if (std.mem.eql(u8, rhs.data.variable, "value"))
                        .value
                    else if (std.mem.eql(u8, rhs.data.variable, "time") or std.mem.eql(u8, rhs.data.variable, "timestamp"))
                        .timestamp
                    else if (std.mem.eql(u8, rhs.data.variable, "dt"))
                        .dt
                    else
                        return error.CompileError;

                    const flipped_op: ts.PredicateOp = switch (pred_op) {
                        .gt => .lt,
                        .ge => .le,
                        .lt => .gt,
                        .le => .ge,
                        else => pred_op,
                    };

                    const res = try allocator.create(ts.Predicate);
                    res.* = ts.Predicate{
                        .op = flipped_op,
                        .field = field,
                        .constant = if (lhs.type == .number) lhs.data.number else lhs.data.unit.value,
                    };
                    return res;
                }

                return error.CompileError;
            },
            .unary_op => {
                if (node.data.unary_op.op == .not_) {
                    const inner = try allocator.create(ts.Predicate);
                    inner.* = (try self.lowerPredicateRecursive(node.data.unary_op.expr)).*;

                    const res = try allocator.create(ts.Predicate);
                    res.* = ts.Predicate{
                        .op = .not_,
                        .left = inner,
                    };
                    return res;
                }
                return error.CompileError;
            },
            .slice => return error.CompileError,
            .complex, .number, .boolean, .string, .unit, .matrix, .polynomial, .ternary, .variable, .function_call, .record_literal, .member_access, .dynamic_access, .function_def, .sequence, .while_loop, .for_loop => return error.CompileError,
        }
    }

    fn emitBytecode(self: *Compiler, node: *Node) !void {
        const start = node.start;
        switch (node.type) {
            .number => {
                try self.builder.emitConstant(Value.initNumber(node.data.number), start);
            },
            .function_def => {
                self.builder.markNonNumeric();

                // Create child compiler for body
                const meta_alloc = self.metadata_allocator orelse self.node_arena.allocator();
                const child_allocator = meta_alloc;
                var child = try Compiler.init(child_allocator, self.source);
                child.user_functions = std.StringHashMap(u32).init(child_allocator);
                child.parent = self;
                child.registry = self.registry;
                child.metadata_allocator = self.metadata_allocator;

                // Register params in child compiler.
                // To avoid conflict with parent variables (which are inherited in the VM),
                // nested function parameters must start AFTER all parent variables.
                // This ensures inner function params don't overwrite outer scope variables.
                const param_offset: u24 = self.next_var_index;
                const param_names = node.data.function_def.params;
                for (param_names, 0..) |param, i| {
                    try child.variables.put(param, @intCast(param_offset + i));
                }
                child.next_var_index = param_offset + @as(u24, @intCast(param_names.len));

                // Compile body using child's builder
                try child.emitBytecode(node.data.function_def.body);
                try child.builder.emit(.halt, node.data.function_def.body.start);
                var compiled_body = try child.builder.build();

                // Function bodies can use the widened f64 fast path too
                if (!compiled_body.is_number_only and child.isFastPathNumeric(node.data.function_def.body)) {
                    if (try computeFastCheckVars(child_allocator, compiled_body.code)) |vars| {
                        compiled_body.fast_path_ok = true;
                        compiled_body.fast_check_vars = vars;
                    }
                }

                // Frame metadata for the frame-based call path: which slots
                // the body writes (param slots + store_var targets) and the
                // highest slot it references at all.
                var write_vars: []u24 = &.{};
                var max_var_ref: u24 = 0;
                {
                    var seen = std.AutoArrayHashMapUnmanaged(u24, void){};
                    defer seen.deinit(child_allocator);
                    for (0..param_names.len) |i| {
                        const slot: u24 = param_offset + @as(u24, @intCast(i));
                        try seen.put(child_allocator, slot, {});
                        max_var_ref = @max(max_var_ref, slot);
                    }
                    for (compiled_body.code) |in| {
                        switch (in.opcode) {
                            .store_var => {
                                try seen.put(child_allocator, in.operand, {});
                                max_var_ref = @max(max_var_ref, in.operand);
                            },
                            .load_var, .load_var_index_0, .load_var_index_1, .load_var_index_2, .load_var_index_3 => {
                                max_var_ref = @max(max_var_ref, in.operand);
                            },
                            .load_var_index_const => {
                                max_var_ref = @max(max_var_ref, in.operand & 0xFFF);
                            },
                            .load_mul, .load_sub => {
                                max_var_ref = @max(max_var_ref, in.operand & 0xFFF);
                                max_var_ref = @max(max_var_ref, (in.operand >> 12) & 0xFFF);
                            },
                            .fma_var_const_const => {
                                max_var_ref = @max(max_var_ref, in.operand & 0xFF);
                            },
                            .eval_poly => {
                                max_var_ref = @max(max_var_ref, in.operand & 0xFFFF);
                            },
                            else => {},
                        }
                    }
                    write_vars = try child_allocator.dupe(u24, seen.keys());
                }

                // Create UserFunction metadata
                const user_func = try meta_alloc.create(bytecode.UserFunction);
                const func_name = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, node.data.function_def.name) else node.data.function_def.name;

                var params_dupe = try meta_alloc.alloc([]const u8, param_names.len);
                for (param_names, 0..) |p, i| {
                    params_dupe[i] = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, p) else p;
                }

                user_func.* = .{
                    .name = func_name,
                    .params = params_dupe,
                    .body = compiled_body,
                    .param_offset = param_offset,
                    .frame_ok = true,
                    .write_vars = write_vars,
                    .max_var_ref = max_var_ref,
                };

                // Add to constants pool
                const const_idx = try self.builder.addConstant(Value.initUserFunction(user_func));
                try self.builder.emitWithOperand(.def_user, const_idx, start);

                // Register in current compiler's user_functions map so subsequent calls can resolve it
                const next_func_id = self.next_user_func_id;
                self.next_user_func_id += 1;
                try self.user_functions.put(func_name, next_func_id);
            },
            .boolean => {
                self.builder.markNonNumeric();
                try self.builder.emitConstant(Value.initBoolean(node.data.boolean), start);
            },
            .variable => {
                const idx = self.getOrCreateVariable(node.data.variable);
                if (self.variable_tags) |tags| {
                    if (idx < tags.len and tags[idx] != .number) {
                        self.builder.markNonNumeric();
                    } else if (self.variable_values) |values| {
                        if (idx < values.len and values[idx].tag != .number) {
                            self.builder.markNonNumeric();
                        }
                    }
                }
                try self.builder.emitWithOperand(.load_var, idx, start);
            },
            .string => {
                self.builder.markNonNumeric();
                // Duplicate string to session arena so it persists beyond compilation
                const str = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, node.data.string) else node.data.string;
                try self.builder.emitConstant(Value{
                    .tag = .string,
                    .data = .{
                        .string = .{
                            .ptr = str.ptr,
                            .len = @intCast(str.len),
                        },
                    },
                }, start);
            },
            .unit => {
                // Check if this unit name is actually shadowed by a variable (e.g. function parameter)
                // This happens because the body AST was parsed in the parent scope (where 's' is a unit),
                // but we are now compiling in the child scope (where 's' is a parameter).
                if (node.data.unit.name) |name| {
                    // Check if variable exists in current scope (or parents)
                    // We use get() to check existence without creating, but parameters are already in self.variables
                    if (self.variables.get(name)) |idx| {
                        if (self.variable_tags) |tags| {
                            if (idx < tags.len and tags[idx] != .number) {
                                self.builder.markNonNumeric();
                            }
                        }
                        try self.builder.emitWithOperand(.load_var, idx, start);
                        return;
                    }
                }

                self.builder.markNonNumeric();
                try self.builder.emitConstant(Value.initUnitFull(
                    node.data.unit.value,
                    node.data.unit.scale,
                    node.data.unit.offset,
                    node.data.unit.dimensions,
                    node.data.unit.name,
                ), start);
            },
            .binary_op => {
                if (node.data.binary_op.op == .store_var) {
                    const lhs = node.data.binary_op.lhs;
                    if (lhs.type == .dynamic_access) {
                        // Indexed assignment: obj[keys...] = rhs
                        // Stack: obj, keys..., rhs -> set_index -> rhs
                        try self.emitBytecode(lhs.data.dynamic_access.object);
                        for (lhs.data.dynamic_access.keys) |k| {
                            try self.emitBytecode(k);
                        }
                        try self.emitBytecode(node.data.binary_op.rhs);
                        const count = lhs.data.dynamic_access.keys.len;
                        try self.builder.emitWithOperand(.set_index, @intCast(count), start);
                    } else {
                        // Variable assignment: rhs -> dup -> store lhs
                        try self.emitBytecode(node.data.binary_op.rhs);
                        try self.builder.emit(.dup, start);
                        const idx = self.getOrCreateVariable(lhs.data.variable);
                        try self.builder.emitWithOperand(.store_var, idx, start);
                    }
                } else if (node.data.binary_op.op == .and_) {
                    // Short-circuit AND: lhs -> dup -> jmp_if_false label_end -> pop -> rhs -> label_end
                    try self.emitBytecode(node.data.binary_op.lhs);
                    try self.builder.emit(.dup, start);
                    const jump_idx = self.builder.currentOffset();
                    try self.builder.emitWithOperand(.jmp_if_false, 0, start);
                    try self.builder.emit(.pop, start);
                    try self.emitBytecode(node.data.binary_op.rhs);
                    self.builder.patchJump(jump_idx);
                } else if (node.data.binary_op.op == .or_) {
                    // Short-circuit OR: lhs -> dup -> jmp_if_true label_end -> pop -> rhs -> label_end
                    try self.emitBytecode(node.data.binary_op.lhs);
                    try self.builder.emit(.dup, start);
                    const jump_idx = self.builder.currentOffset();
                    try self.builder.emitWithOperand(.jmp_if_true, 0, start);
                    try self.builder.emit(.pop, start);
                    try self.emitBytecode(node.data.binary_op.rhs);
                    self.builder.patchJump(jump_idx);
                } else {
                    try self.emitBytecode(node.data.binary_op.lhs);
                    try self.emitBytecode(node.data.binary_op.rhs);
                    try self.builder.emit(node.data.binary_op.op, start);
                }
            },
            .unary_op => {
                try self.emitBytecode(node.data.unary_op.expr);
                try self.builder.emit(node.data.unary_op.op, start);
            },
            .member_access => {
                self.builder.markNonNumeric();
                try self.emitBytecode(node.data.member_access.object);
                const field_name = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, node.data.member_access.field) else node.data.member_access.field;
                const const_idx = try self.builder.addConstant(Value{
                    .tag = .string,
                    .data = .{
                        .string = .{
                            .ptr = field_name.ptr,
                            .len = @intCast(field_name.len),
                        },
                    },
                });
                try self.builder.emitWithOperand(.rec_get, const_idx, start);
            },
            .dynamic_access => {
                self.builder.markNonNumeric();
                try self.emitBytecode(node.data.dynamic_access.object);
                for (node.data.dynamic_access.keys) |k| {
                    try self.emitBytecode(k);
                }
                const count = node.data.dynamic_access.keys.len;
                try self.builder.emitWithOperand(.get_index, @intCast(count), start);
            },
            .slice => {
                self.builder.markNonNumeric();
                if (node.data.slice.start) |s| try self.emitBytecode(s) else try self.builder.emitConstant(Value.initNull(), start);
                if (node.data.slice.end) |e| try self.emitBytecode(e) else try self.builder.emitConstant(Value.initNull(), start);
                if (node.data.slice.step) |s| try self.emitBytecode(s) else try self.builder.emitConstant(Value.initNull(), start);
                try self.builder.emit(.make_slice, start);
            },
            .function_call => {
                const func_name = node.data.function_call.name;
                const resolved = self.resolveFunction(func_name) orelse return error.UnknownFunction;

                if (resolved.tag == .builtin) {
                    var func_id = resolved.id;

                    // Handle 'range' overloading: 1 arg = aggregation, 2-3 args = generation
                    if (func_id == @intFromEnum(BuiltinFn.gen_range)) {
                        const arg_count = node.data.function_call.args.len;
                        if (arg_count == 1) {
                            func_id = @intFromEnum(BuiltinFn.agg_range);
                        } else if (arg_count == 2 or arg_count == 3) {
                            // Keep gen_range
                        } else {
                            return error.CompileError; // Wrong arg count for range
                        }
                    }

                    if (isNonNumericBuiltin(@enumFromInt(func_id))) {
                        self.builder.markNonNumeric();
                    }

                    const param_names = BuiltinParamNames.get(func_name);
                    var final_arg_count = node.data.function_call.args.len;

                    if (node.data.function_call.arg_names != null and param_names != null) {
                        const args = node.data.function_call.args;
                        const arg_names = node.data.function_call.arg_names.?;
                        const params = param_names.?;

                        var ordered_args = try self.node_arena.allocator().alloc(?*Node, params.len);
                        @memset(ordered_args, null);
                        var filled = try self.node_arena.allocator().alloc(bool, params.len);
                        @memset(filled, false);

                        // 1. Fill named arguments
                        for (args, 0..) |arg, i| {
                            if (arg_names[i]) |name| {
                                var found = false;
                                for (params, 0..) |p_name, j| {
                                    if (std.mem.eql(u8, name, p_name)) {
                                        if (filled[j]) return error.CompileError; // Duplicate argument
                                        ordered_args[j] = arg;
                                        filled[j] = true;
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) return error.CompileError; // Unknown parameter name
                            }
                        }

                        // 2. Fill positional arguments into remaining slots
                        var next_param: usize = 0;
                        for (args, 0..) |arg, i| {
                            if (arg_names[i] == null) {
                                while (next_param < params.len and filled[next_param]) : (next_param += 1) {}
                                if (next_param >= params.len) return error.CompileError; // Too many arguments
                                ordered_args[next_param] = arg;
                                filled[next_param] = true;
                            }
                        }

                        // 3. Emit in order
                        var emitted_count: u24 = 0;
                        for (ordered_args) |maybe_arg| {
                            if (maybe_arg) |arg| {
                                try self.emitBytecode(arg);
                                emitted_count += 1;
                            }
                        }
                        final_arg_count = emitted_count;
                    } else {
                        for (node.data.function_call.args) |arg| {
                            try self.emitBytecode(arg);
                        }
                    }

                    if (node.data.function_call.predicate) |p| {
                        const pred_ptr = try self.lowerPredicate(p);
                        // Add predicate to constants pool wrapped in Value
                        const pred_val = Value.initPredicate(pred_ptr);
                        const const_idx = try self.builder.addConstant(pred_val);
                        try self.builder.emitWithOperand(.push_const, const_idx, start);

                        const operand: u24 = @as(u24, func_id) | (@as(u24, @intCast(final_arg_count)) << 16);
                        try self.builder.emitWithOperand(.call_builtin_where, operand, start);
                    } else {
                        const operand: u24 = @as(u24, func_id) | (@as(u24, @intCast(final_arg_count)) << 16);
                        try self.builder.emitWithOperand(.call_builtin, operand, start);
                    }
                } else {
                    // User-defined function call
                    self.builder.markNonNumeric();
                    for (node.data.function_call.args) |arg| {
                        try self.emitBytecode(arg);
                    }
                    // Encode: bits 0-14 = func_id, bit 15 = is_local flag, bits 16-23 = arg_count
                    const local_flag: u24 = if (resolved.is_local) 0x8000 else 0;
                    const operand: u24 = @as(u24, resolved.id & 0x7FFF) | local_flag | (@as(u24, @intCast(node.data.function_call.args.len)) << 16);
                    try self.builder.emitWithOperand(.call_user, operand, start);
                }
            },
            .matrix => {
                self.builder.markNonNumeric();
                for (node.data.matrix.elements) |el| {
                    try self.emitBytecode(el);
                }
                const operand: u24 = @as(u24, @intCast(node.data.matrix.rows)) | (@as(u24, @intCast(node.data.matrix.cols)) << 12);
                try self.builder.emitWithOperand(.mat_create, operand, start);
            },
            .ternary => {
                // lhs (cond) -> jmp_if_false label_else -> then_expr -> jmp label_end -> label_else -> else_expr -> label_end
                try self.emitBytecode(node.data.ternary.cond);
                const else_jump = self.builder.currentOffset();
                try self.builder.emitWithOperand(.jmp_if_false, 0, start);

                try self.emitBytecode(node.data.ternary.then_expr);
                const end_jump = self.builder.currentOffset();
                try self.builder.emitWithOperand(.jmp, 0, start);

                self.builder.patchJump(else_jump);
                try self.emitBytecode(node.data.ternary.else_expr);
                self.builder.patchJump(end_jump);
            },
            .complex => {
                self.builder.markNonNumeric();
                try self.builder.emitConstant(Value.initComplex(node.data.complex.re, node.data.complex.im), start);
            },
            .record_literal => {
                self.builder.markNonNumeric();
                // Emit all field values and keys onto the stack
                for (node.data.record_literal.fields) |field| {
                    try self.emitBytecode(field.value);
                    // Emit key as a string constant
                    const key_name = if (self.metadata_allocator) |alloc| try alloc.dupe(u8, field.key) else field.key;
                    const key_idx = try self.builder.addConstant(Value{
                        .tag = .string,
                        .data = .{
                            .string = .{
                                .ptr = key_name.ptr,
                                .len = @intCast(key_name.len),
                            },
                        },
                    });
                    try self.builder.emitWithOperand(.push_const, key_idx, start);
                }
                // Emit record creation instruction
                const operand: u24 = @intCast(node.data.record_literal.fields.len);
                try self.builder.emitWithOperand(.rec_create, operand, start);
            },
            .polynomial => {
                // Not reached via parser currently
            },
            .sequence => {
                // Emit all expressions, pop all but the last
                const exprs = node.data.sequence.exprs;
                for (exprs, 0..) |expr, i| {
                    try self.emitBytecode(expr);
                    // Pop all results except the last one
                    if (i < exprs.len - 1) {
                        try self.builder.emit(.pop, expr.start);
                    }
                }
            },
            .while_loop => {
                const loop_start = self.builder.currentOffset();

                // Condition
                try self.emitBytecode(node.data.while_loop.cond);
                const jump_exit = self.builder.currentOffset();
                try self.builder.emitWithOperand(.jmp_if_false, 0, start);
                // jmp_if_false consumes the condition in VM

                // Body
                try self.emitBytecode(node.data.while_loop.body);
                try self.builder.emit(.pop, start); // Discard body result

                // Jump back to start
                try self.builder.emitWithOperand(.jmp, loop_start, start);

                // Exit label
                self.builder.patchJump(jump_exit);

                // Push result of loop (e.g. 0.0)
                try self.builder.emitConstant(Value.initNumber(0.0), start);
            },
            .for_loop => {
                // Init
                if (node.data.for_loop.init) |init_node| {
                    try self.emitBytecode(init_node);
                    try self.builder.emit(.pop, start); // Discard init result
                }

                const loop_start = self.builder.currentOffset();
                var jump_exit: ?u24 = null;

                // Condition
                if (node.data.for_loop.cond) |cond| {
                    try self.emitBytecode(cond);
                    jump_exit = self.builder.currentOffset();
                    try self.builder.emitWithOperand(.jmp_if_false, 0, start);
                    // jmp_if_false consumes
                } else {
                    // Infinite loop if no condition
                }

                // Body
                try self.emitBytecode(node.data.for_loop.body);
                try self.builder.emit(.pop, start); // Discard body result

                // Step
                if (node.data.for_loop.post) |post| {
                    try self.emitBytecode(post);
                    try self.builder.emit(.pop, start); // Discard step result
                }

                // Jump back
                try self.builder.emitWithOperand(.jmp, loop_start, start);

                // Exit
                if (jump_exit) |je| {
                    self.builder.patchJump(je);
                }

                try self.builder.emitConstant(Value.initNumber(0.0), start);
            },
        }
    }

    fn getInfixPrecedence(self: *Compiler) Precedence {
        return getInfixPrecedenceOf(self.current.type);
    }

    fn getInfixPrecedenceOf(token_type: TokenType) Precedence {
        return switch (token_type) {
            .equal => .assignment,
            .kw_to, .kw_in, .kw_as => .conversion,
            .question => .conditional,
            .pipe_pipe, .kw_or => .or_,
            .ampersand_ampersand, .kw_and => .and_,
            .pipe => .bitwise_or,
            .caret_caret, .kw_xor => .bitwise_xor,
            .ampersand => .bitwise_and,
            .equal_equal, .not_equal => .equality,
            .less, .less_equal, .greater, .greater_equal => .comparison,
            .less_less, .greater_greater, .greater_greater_greater => .shift,
            .plus, .minus => .term,
            .star, .slash, .percent, .dot_star, .dot_slash => .factor,
            .caret, .dot_caret => .power,
            .lparen, .lbracket, .apostrophe, .dot => .postfix,
            else => .none,
        };
    }

    fn advance(self: *Compiler) void {
        self.previous = self.current;
        self.current = self.next;
        self.next = self.tokenizer.next();
    }

    const ResolvedFunction = struct {
        tag: enum { builtin, user },
        id: u16,
        /// True if the function was defined in the current scope (not inherited from parent)
        is_local: bool = false,
    };

    fn resolveFunction(self: *Compiler, name: []const u8) ?ResolvedFunction {
        // 1. Check user-defined functions in current and parent compilers
        var curr: ?*Compiler = self;
        var is_local = true; // First iteration is current scope
        while (curr) |c| : (curr = c.parent) {
            if (c.user_functions.get(name)) |id| {
                return .{ .tag = .user, .id = @intCast(id), .is_local = is_local };
            }
            is_local = false; // Subsequent iterations are parent scopes
        }

        // 2. Check builtin functions
        if (getBuiltinId(name)) |id| {
            return .{ .tag = .builtin, .id = id };
        }

        return null;
    }

    /// Look up builtin function ID by name
    fn getBuiltinId(name: []const u8) ?u16 {
        const builtins = std.StaticStringMap(u16).initComptime(.{
            .{ "abs", @intFromEnum(BuiltinFn.abs) },
            .{ "sqrt", @intFromEnum(BuiltinFn.sqrt) },
            .{ "cbrt", @intFromEnum(BuiltinFn.cbrt) },
            .{ "exp", @intFromEnum(BuiltinFn.exp) },
            .{ "log", @intFromEnum(BuiltinFn.log) },
            .{ "ln", @intFromEnum(BuiltinFn.log) },
            .{ "log10", @intFromEnum(BuiltinFn.log10) },
            .{ "log2", @intFromEnum(BuiltinFn.log2) },
            .{ "sin", @intFromEnum(BuiltinFn.sin) },
            .{ "cos", @intFromEnum(BuiltinFn.cos) },
            .{ "tan", @intFromEnum(BuiltinFn.tan) },
            .{ "asin", @intFromEnum(BuiltinFn.asin) },
            .{ "acos", @intFromEnum(BuiltinFn.acos) },
            .{ "atan", @intFromEnum(BuiltinFn.atan) },
            .{ "atan2", @intFromEnum(BuiltinFn.atan2) },
            .{ "sinh", @intFromEnum(BuiltinFn.sinh) },
            .{ "cosh", @intFromEnum(BuiltinFn.cosh) },
            .{ "tanh", @intFromEnum(BuiltinFn.tanh) },
            .{ "sec", @intFromEnum(BuiltinFn.sec) },
            .{ "csc", @intFromEnum(BuiltinFn.csc) },
            .{ "cot", @intFromEnum(BuiltinFn.cot) },
            .{ "asec", @intFromEnum(BuiltinFn.asec) },
            .{ "acsc", @intFromEnum(BuiltinFn.acsc) },
            .{ "acot", @intFromEnum(BuiltinFn.acot) },
            .{ "floor", @intFromEnum(BuiltinFn.floor) },
            .{ "ceil", @intFromEnum(BuiltinFn.ceil) },
            .{ "round", @intFromEnum(BuiltinFn.round) },
            .{ "trunc", @intFromEnum(BuiltinFn.trunc) },
            .{ "fix", @intFromEnum(BuiltinFn.trunc) },
            .{ "sign", @intFromEnum(BuiltinFn.sign) },
            .{ "min", @intFromEnum(BuiltinFn.min) },
            .{ "max", @intFromEnum(BuiltinFn.max) },
            .{ "clamp", @intFromEnum(BuiltinFn.clamp) },
            .{ "hypot", @intFromEnum(BuiltinFn.hypot) },
            .{ "random", @intFromEnum(BuiltinFn.random) },
            .{ "randomInt", @intFromEnum(BuiltinFn.randomInt) },
            .{ "pickRandom", @intFromEnum(BuiltinFn.pickRandom) },
            .{ "square", @intFromEnum(BuiltinFn.square) },
            .{ "cube", @intFromEnum(BuiltinFn.cube) },
            .{ "nthRoot", @intFromEnum(BuiltinFn.nthRoot) },
            .{ "log1p", @intFromEnum(BuiltinFn.log1p) },
            .{ "expm1", @intFromEnum(BuiltinFn.expm1) },
            .{ "asinh", @intFromEnum(BuiltinFn.asinh) },
            .{ "acosh", @intFromEnum(BuiltinFn.acosh) },
            .{ "atanh", @intFromEnum(BuiltinFn.atanh) },
            .{ "sech", @intFromEnum(BuiltinFn.sech) },
            .{ "csch", @intFromEnum(BuiltinFn.csch) },
            .{ "coth", @intFromEnum(BuiltinFn.coth) },
            .{ "asech", @intFromEnum(BuiltinFn.asech) },
            .{ "acsch", @intFromEnum(BuiltinFn.acsch) },
            .{ "acoth", @intFromEnum(BuiltinFn.acoth) },
            .{ "erf", @intFromEnum(BuiltinFn.erf) },
            .{ "lgamma", @intFromEnum(BuiltinFn.lgamma) },
            .{ "combinations", @intFromEnum(BuiltinFn.combinations) },
            .{ "permutations", @intFromEnum(BuiltinFn.permutations) },
            .{ "re", @intFromEnum(BuiltinFn.re) },
            .{ "im", @intFromEnum(BuiltinFn.im) },
            .{ "arg", @intFromEnum(BuiltinFn.arg) },
            .{ "conj", @intFromEnum(BuiltinFn.conj) },
            .{ "read_csv", @intFromEnum(BuiltinFn.read_csv) },
            .{ "write_csv", @intFromEnum(BuiltinFn.write_csv) },
            .{ "assert", @intFromEnum(BuiltinFn.assert) },
            .{ "conv", @intFromEnum(BuiltinFn.conv) },
            .{ "number", @intFromEnum(BuiltinFn.number) },
            .{ "norm", @intFromEnum(BuiltinFn.norm) },
            .{ "gemv", @intFromEnum(BuiltinFn.gemv) },
            .{ "det", @intFromEnum(BuiltinFn.det) },
            .{ "inv", @intFromEnum(BuiltinFn.inv) },
            .{ "transpose", @intFromEnum(BuiltinFn.transpose) },
            .{ "mean", @intFromEnum(BuiltinFn.mean) },
            .{ "sum", @intFromEnum(BuiltinFn.sum) },
            .{ "count", @intFromEnum(BuiltinFn.count) },
            .{ "median", @intFromEnum(BuiltinFn.median) },
            .{ "std", @intFromEnum(BuiltinFn.std) },
            .{ "variance", @intFromEnum(BuiltinFn.variance) },
            .{ "mad", @intFromEnum(BuiltinFn.mad) },
            .{ "prod", @intFromEnum(BuiltinFn.prod) },
            .{ "factorial", @intFromEnum(BuiltinFn.factorial) },
            .{ "gamma", @intFromEnum(BuiltinFn.gamma) },
            .{ "lgamma", @intFromEnum(BuiltinFn.lgamma) },
            .{ "gcd", @intFromEnum(BuiltinFn.gcd) },
            .{ "lcm", @intFromEnum(BuiltinFn.lcm) },
            .{ "isPrime", @intFromEnum(BuiltinFn.isPrime) },
            .{ "trace", @intFromEnum(BuiltinFn.trace) },
            .{ "reshape", @intFromEnum(BuiltinFn.reshape) },
            .{ "flatten", @intFromEnum(BuiltinFn.flatten) },
            .{ "concat", @intFromEnum(BuiltinFn.concat) },
            .{ "diag", @intFromEnum(BuiltinFn.diag) },
            .{ "dot", @intFromEnum(BuiltinFn.dot) },
            .{ "cross", @intFromEnum(BuiltinFn.cross) },
            .{ "identity", @intFromEnum(BuiltinFn.identity) },
            .{ "zeros", @intFromEnum(BuiltinFn.zeros) },
            .{ "ones", @intFromEnum(BuiltinFn.ones) },
            .{ "cumsum", @intFromEnum(BuiltinFn.cumsum) },
            .{ "cummax", @intFromEnum(BuiltinFn.cummax) },
            .{ "cummin", @intFromEnum(BuiltinFn.cummin) },
            .{ "rolling_sum", @intFromEnum(BuiltinFn.rolling_sum) },
            .{ "rolling_mean", @intFromEnum(BuiltinFn.rolling_mean) },
            .{ "rolling_min", @intFromEnum(BuiltinFn.rolling_min) },
            .{ "rolling_max", @intFromEnum(BuiltinFn.rolling_max) },
            .{ "rolling_count", @intFromEnum(BuiltinFn.rolling_count) },
            .{ "rolling_stddev", @intFromEnum(BuiltinFn.rolling_stddev) },
            .{ "diff", @intFromEnum(BuiltinFn.diff) },
            .{ "pct_change", @intFromEnum(BuiltinFn.pct_change) },
            .{ "series", @intFromEnum(BuiltinFn.series) },
            .{ "twa", @intFromEnum(BuiltinFn.twa) },
            .{ "derivative", @intFromEnum(BuiltinFn.derivative) },
            .{ "integrate", @intFromEnum(BuiltinFn.integrate) },
            .{ "sma", @intFromEnum(BuiltinFn.sma) },
            .{ "ema", @intFromEnum(BuiltinFn.ema) },
            .{ "rsi", @intFromEnum(BuiltinFn.rsi) },
            .{ "last", @intFromEnum(BuiltinFn.last) },
            .{ "duration", @intFromEnum(BuiltinFn.duration) },
            .{ "asofJoin", @intFromEnum(BuiltinFn.asofJoin) },
            .{ "asof_join", @intFromEnum(BuiltinFn.asofJoin) },
            .{ "resample", @intFromEnum(BuiltinFn.resample) },
            .{ "align", @intFromEnum(BuiltinFn.align_) },
            .{ "head", @intFromEnum(BuiltinFn.head) },
            .{ "tail", @intFromEnum(BuiltinFn.tail) },
            .{ "slice", @intFromEnum(BuiltinFn.slice) },
            .{ "between", @intFromEnum(BuiltinFn.between) },
            .{ "since", @intFromEnum(BuiltinFn.since) },
            .{ "shift", @intFromEnum(BuiltinFn.shift) },
            .{ "dropna", @intFromEnum(BuiltinFn.dropna) },
            .{ "fillna", @intFromEnum(BuiltinFn.fillna) },
            .{ "clip", @intFromEnum(BuiltinFn.clip) },
            .{ "size", @intFromEnum(BuiltinFn.size) },
            .{ "len", @intFromEnum(BuiltinFn.size) },
            .{ "bollinger", @intFromEnum(BuiltinFn.bollinger) },
            .{ "macd", @intFromEnum(BuiltinFn.macd) },
            .{ "range", @intFromEnum(BuiltinFn.gen_range) },
            .{ "linspace", @intFromEnum(BuiltinFn.linspace) },
            .{ "logspace", @intFromEnum(BuiltinFn.logspace) },
            .{ "now", @intFromEnum(BuiltinFn.now) },
            .{ "ode_solve", @intFromEnum(BuiltinFn.ode_solve) },
            .{ "ode_solve_euler", @intFromEnum(BuiltinFn.ode_solve_euler) },
            .{ "toLaTeX", @intFromEnum(BuiltinFn.toLaTeX) },
            .{ "create_unit", @intFromEnum(BuiltinFn.create_unit) },
            .{ "config", @intFromEnum(BuiltinFn.config) },
        });

        return builtins.get(name);
    }

    const BuiltinParamNames = std.StaticStringMap([]const []const u8).initComptime(.{
        .{ "ode_solve", &.{ "func", "y0", "t_span", "dt" } },
        .{ "ode_solve_euler", &.{ "func", "y0", "t_span", "dt" } },
        .{ "bollinger", &.{ "series", "period", "mult" } },
        .{ "macd", &.{ "series", "fast", "slow", "signal" } },
        .{ "sma", &.{ "series", "period" } },
        .{ "ema", &.{ "series", "half_life" } },
        .{ "rsi", &.{ "series", "period" } },
        .{ "rolling_sum", &.{ "series", "window" } },
        .{ "rolling_mean", &.{ "series", "window" } },
        .{ "rolling_min", &.{ "series", "window" } },
        .{ "rolling_max", &.{ "series", "window" } },
        .{ "rolling_count", &.{ "series", "window" } },
        .{ "rolling_stddev", &.{ "series", "window" } },
        .{ "diff", &.{ "series", "n" } },
        .{ "pct_change", &.{ "series", "n" } },
        .{ "resample", &.{ "series", "interval", "kernel" } },
        .{ "head", &.{ "series", "n" } },
        .{ "tail", &.{ "series", "n" } },
        .{ "slice", &.{ "series", "start", "end" } },
        .{ "between", &.{ "series", "start", "end" } },
        .{ "since", &.{ "series", "duration" } },
        .{ "shift", &.{ "series", "n" } },
        .{ "fillna", &.{ "series", "value" } },
        .{ "clip", &.{ "series", "min", "max" } },
        .{ "write_csv", &.{ "path", "data", "options" } },
        .{ "read_csv", &.{ "path", "mapping", "options" } },
        .{ "conv", &.{ "value", "unit" } },
    });

    fn isNonNumericBuiltin(func: BuiltinFn) bool {
        return switch (func) {
            .det, .inv, .transpose, .norm, .zeros, .ones => true, // Matrix ops
            .series, .derivative, .integrate, .sma, .ema, .rsi, .twa, .sum, .mean, .count, .median, .std, .variance, .mad, .prod, .agg_range, .asofJoin, .resample, .align_, .last, .duration, .cumsum, .cummax, .cummin, .rolling_sum, .rolling_mean, .rolling_min, .rolling_max, .rolling_count, .rolling_stddev, .diff, .pct_change, .head, .tail, .slice, .between, .since, .shift, .dropna, .fillna, .clip, .bollinger, .macd, .gen_range, .linspace, .logspace, .size, .assert, .write_csv, .now, .ode_solve, .ode_solve_euler, .toLaTeX => true, // Time-Series/Stats/Indicators/Assert/IO/Generators
            .random, .randomInt, .pickRandom => true, // Random functions have side effects
            else => false,
        };
    }

    test "compile simple expression" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "2 + 3");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // "2 + 3" is now fully constant folded to "5"
        // Should have: push 5, halt
        try std.testing.expectEqual(@as(usize, 2), expr.code.len);
    }

    test "compile with precedence" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "2 + 3 * 4");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // "2 + 3 * 4" is now fully constant folded to "14"
        // Should have: push 14, halt
        try std.testing.expectEqual(@as(usize, 2), expr.code.len);
    }

    test "compile assignment and execute" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "x = 5");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // Should have: push 5, dup, store_var, halt
        try std.testing.expectEqual(@as(usize, 4), expr.code.len);

        // Execute and verify
        const VM = @import("../vm/vm.zig").VM;
        var config = Config.init();
        var vm = try VM.init(allocator, allocator, 16, null, &config);
        defer vm.deinit();

        const result = try vm.execute(&expr);
        try std.testing.expectEqual(@as(f64, 5), result.data.number);
        try std.testing.expectEqual(@as(f64, 5), vm.variables[0].data.number);
    }

    test "compile function call" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "sin(3.14)");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // Should have: push 3.14, call_builtin(sin, 1), halt
        try std.testing.expectEqual(@as(usize, 3), expr.code.len);
    }

    test "symbolic simplification" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "x * 1 + 0");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // "x * 1 + 0" should simplify to just "load x"
        // code: [load x, halt]
        try std.testing.expectEqual(@as(usize, 2), expr.code.len);
        try std.testing.expectEqual(Opcode.load_var, expr.code[0].opcode);
    }

    test "unit conversion compilation" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        // Use a variable 'x' to prevent full constant folding of result
        var compiler = try Compiler.init(allocator, "conv(x * cm, inch)");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // [load x, push cm, mul, push inch, call_builtin(conv, 2), halt]
        try std.testing.expectEqual(Opcode.call_builtin, expr.code[expr.code.len - 2].opcode);
    }

    test "compile compound unit literal" {
        const allocator = std.testing.allocator;

        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        // 10 [kg/kWh]

        var compiler = try Compiler.init(allocator, "10 [kg/kWh]");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // Should have: push 10, push kg, push kWh, div, mul, halt

        // But wait, unitLiteral returns subtree.

        // So it's: push 10, (sub-tree for kg/kWh), mul, halt

        // Check that it doesn't fail
        try std.testing.expect(expr.code.len > 0);
    }

    test "compile invalid assignment" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "5 = 10");
        compiler.registry = &registry;
        defer compiler.deinit();

        // Should error out
        try std.testing.expectError(error.CompileError, compiler.compile());
    }

    test "compile implicit multiplication" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "2x + (1+2)(3+4)");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // Should have nodes for mul in both cases
        try std.testing.expect(expr.code.len > 0);
    }

    test "compile ternary operator" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "x > 0 ? 1 : 0");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // [load x, push 0, gt, jump_if_false, push 1, jump, push 0, halt]
        try std.testing.expect(expr.code.len >= 7);
    }

    test "compile record literal" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "{a: 1, b: 2 + 3}");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // Should have Opcode.rec_create
        try std.testing.expect(expr.code.len > 0);
    }

    test "compile complex number literal" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        var compiler = try Compiler.init(allocator, "1 + 2i");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // Complex constant folded to push_const
        try std.testing.expectEqual(@as(usize, 2), expr.code.len);
        try std.testing.expectEqual(Opcode.push_const, expr.code[0].opcode);
    }

    test "decompose compound units" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        // "sm" should be parsed as "s * m"
        var compiler = try Compiler.init(allocator, "10sm");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        // Should have: push 10, push s, push m, mul, mul, halt (simplified)
        // or folded: push 10, push s*m, mul, halt

        // Because simplify() handles unit*unit mul, it might be folded into one unit constant.
        try std.testing.expect(expr.code.len > 0);
    }

    test "explicit unit syntax with decomposition" {
        const allocator = std.testing.allocator;
        var registry = try UnitRegistry.init(allocator);
        defer registry.deinit();

        // "22[sm]" -> 22 * (s * m)
        var compiler = try Compiler.init(allocator, "22[sm]");
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        try std.testing.expect(expr.code.len > 0);
    }
};
