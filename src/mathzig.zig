///! MathZig - A pure Zig math expression evaluator with unit support
const std = @import("std");
const builtin = @import("builtin");

// Re-export core types
pub const Value = @import("core/value.zig").Value;
pub const ValueTag = @import("core/value.zig").ValueTag;
pub const Complex = @import("core/value.zig").Complex;
pub const Matrix = @import("core/value.zig").Matrix;
pub const Record = @import("core/value.zig").Record;
pub const UnitValue = @import("core/value.zig").UnitValue;
pub const ast = @import("core/ast.zig");
pub const version = @import("version.zig");
pub const Unit = @import("units/unit_registry.zig").Unit;
pub const Dimensions = @import("units/unit_registry.zig").Dimensions;
pub const units = @import("units/unit_registry.zig");

// Re-export VM types
pub const vm = @import("vm/vm.zig");
pub const CompiledExpr = @import("vm/bytecode.zig").CompiledExpr;
pub const BytecodeBuilder = @import("vm/bytecode.zig").BytecodeBuilder;
pub const UserFunction = @import("vm/bytecode.zig").UserFunction;
pub const Instruction = @import("vm/bytecode.zig").Instruction;
pub const Opcode = @import("vm/bytecode.zig").Opcode;
pub const BuiltinFn = @import("vm/bytecode.zig").BuiltinFn;
pub const isFastPathBuiltin = @import("vm/bytecode.zig").isFastPathBuiltin;
pub const VM = @import("vm/vm.zig").VM;

// Re-export parser types
pub const parser = @import("parser/compiler.zig");
pub const Compiler = @import("parser/compiler.zig").Compiler;
pub const Tokenizer = @import("parser/tokenizer.zig").Tokenizer;

// Re-export config types
pub const config_mod = @import("core/config.zig");
pub const Config = config_mod.Config;
pub const AngleMode = config_mod.AngleMode;

// Re-export memory types
pub const ChunkArena = @import("memory/chunk_arena.zig").ChunkArena;
pub const CompilerCache = @import("memory/compiler_cache.zig").CompilerCache;
/// Process-wide live Matrix/Series/Record counters (task-16 debugStats).
pub const live_handles = @import("memory/live_handles.zig");
pub const threading = @import("core/threading.zig");

// Re-export Time-Series types
pub const timeseries = struct {
    pub const Series = @import("timeseries/series.zig").Series;
    pub const SeriesView = @import("timeseries/series.zig").SeriesView;
    pub const SampleMode = @import("timeseries/series.zig").SampleMode;
    pub const derivative = @import("timeseries/calculus.zig").derivative;
    pub const integrate = @import("timeseries/calculus.zig").integrate;
    pub const diff = @import("timeseries/calculus.zig").diff;
    pub const Predicate = @import("timeseries/predicates.zig").Predicate;
    pub const PredicateOp = @import("timeseries/predicates.zig").PredicateOp;
    pub const Field = @import("timeseries/predicates.zig").Field;
    pub const sum = @import("timeseries/aggregations.zig").sum;
    pub const mean = @import("timeseries/aggregations.zig").mean;
    pub const twa = @import("timeseries/aggregations.zig").twa;
    pub const min = @import("timeseries/aggregations.zig").min;
    pub const max = @import("timeseries/aggregations.zig").max;
    pub const count = @import("timeseries/aggregations.zig").count;
    pub const cumsum = @import("timeseries/aggregations.zig").cumsum;
    pub const ema = @import("timeseries/indicators.zig").ema;
    pub const sma = @import("timeseries/indicators.zig").sma;
    pub const rsi = @import("timeseries/indicators.zig").rsi;
    pub const resample = @import("timeseries/resampling.zig").resample;
    pub const AggKernel = @import("timeseries/resampling.zig").AggKernel;
    pub const asofJoin = @import("timeseries/joins.zig").asofJoin;
    pub const alignUnion = @import("timeseries/alignment.zig").alignUnion;
};

// Re-export BLAS kernels
pub const matrix_kernels = @import("functions/matrix_kernels.zig");
pub const ode = @import("functions/ode.zig");

// Re-export WASM backend
pub const wasm = struct {
    pub const types = @import("wasm/types.zig");
    pub const leb = @import("wasm/leb128.zig");
    pub const module = @import("wasm/module.zig");
    pub const compiler = @import("wasm/compiler.zig");
    pub const abi = @import("wasm/abi.zig");
    pub const node_manifest = @import("wasm/node_manifest.zig");
    pub const graph_manifest = @import("wasm/graph_manifest.zig");
    /// Pure-Zig poly references + wasm body generators (task-19 P3 tier-1 sweeps).
    pub const math_lib = @import("wasm/math_lib.zig");
};

// VM-native graph evaluator v1 — see src/graph/root.zig (never loads .wasm bytes)
pub const graph = @import("graph/root.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// MathZig context
pub const MathZig = struct {
    allocator: std.mem.Allocator,
    arena: ChunkArena,
    compiler_cache: CompilerCache,
    unit_registry: @import("units/unit_registry.zig").UnitRegistry,
    vm: VM,
    config: @import("core/config.zig").Config,
    variables: std.StringHashMap(u24),
    functions: std.StringHashMap(u32),
    next_var_index: u24,
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,
    thread_pool: threading.Pool,

    const Self = @This();
    const MAX_VARIABLES = 256;
    const LengthPowerDisplay = struct { scaled_value: f64, prefix: []const u8, exp: i8 };

    pub fn init(alloc: std.mem.Allocator) !*Self {
        const self_ptr = try alloc.create(Self);

        self_ptr.allocator = alloc;
        self_ptr.arena = try ChunkArena.init(alloc);
        self_ptr.compiler_cache = CompilerCache.init();
        self_ptr.unit_registry = try @import("units/unit_registry.zig").UnitRegistry.init(alloc);
        self_ptr.config = @import("core/config.zig").Config.init();
        self_ptr.variables = std.StringHashMap(u24).init(alloc);
        self_ptr.functions = std.StringHashMap(u32).init(alloc);
        self_ptr.next_var_index = 0;
        self_ptr.last_error_len = 0;
        @memset(self_ptr.last_error[0..], 0);

        if (comptime !threading.is_wasm) {
            try self_ptr.thread_pool.init(.{
                .allocator = alloc,
                .n_jobs = threading.getCpuCount(),
            });
            self_ptr.vm = try VM.init(alloc, self_ptr.arena.getAllocator(), MAX_VARIABLES, &self_ptr.thread_pool, &self_ptr.config);
        } else {
            self_ptr.vm = try VM.init(alloc, self_ptr.arena.getAllocator(), MAX_VARIABLES, {}, &self_ptr.config);
        }
        self_ptr.vm.unit_registry = &self_ptr.unit_registry;

        // Ensure common parameters get consistent low indices
        _ = self_ptr.addVariableIndexed("x", 0);
        _ = self_ptr.addVariableIndexed("y", 0);
        _ = self_ptr.addVariableIndexed("z", 0);

        try self_ptr.initConstants();

        return self_ptr;
    }

    pub fn initConstants(self_ptr: *Self) !void {
        _ = self_ptr.addVariableIndexed("pi", std.math.pi);
        _ = self_ptr.addVariableIndexed("tau", std.math.tau);
        _ = self_ptr.addVariableIndexed("e", std.math.e);
        _ = self_ptr.addVariableIndexed("phi", 1.61803398874989484820);
        _ = self_ptr.addVariableIndexed("SQRT2", std.math.sqrt2);
        _ = self_ptr.addVariableIndexed("LN2", std.math.ln2);
        _ = self_ptr.addVariableIndexed("LN10", std.math.ln10);
        _ = self_ptr.addVariableIndexed("inf", std.math.inf(f64));
        _ = self_ptr.addVariableIndexed("Infinity", std.math.inf(f64));
        _ = self_ptr.addVariableIndexed("nan", std.math.nan(f64));
        _ = self_ptr.addVariableIndexed("NaN", std.math.nan(f64));

        // Physical constants (SI units)
        _ = self_ptr.addVariableIndexed("speedOfLight", 299792458.0); // m/s
        _ = self_ptr.addVariableIndexed("planckConstant", 6.62607015e-34); // J·s
        _ = self_ptr.addVariableIndexed("gravitationalConstant", 6.67430e-11); // m³/(kg·s²)
    }

    pub fn deinit(self: *Self) void {
        if (comptime !is_wasm) {
            self.thread_pool.deinit();
        }
        // Only free things that used the top-level allocator
        // Arena handles its own chunks
        self.unit_registry.deinit();
        self.vm.deinit();
        self.variables.deinit();
        self.functions.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn compile(self: *Self, source: []const u8) !*CompiledExpr {
        var compiler = try Compiler.initWithConfig(self.allocator, source, &self.config);
        defer compiler.deinit();
        compiler.registry = &self.unit_registry;
        compiler.variable_tags = self.vm.variables_tags;
        compiler.variable_values = self.vm.variables;
        compiler.metadata_allocator = self.arena.getAllocator();

        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            compiler.variables.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        compiler.next_var_index = self.next_var_index;

        var func_iter = self.functions.iterator();
        while (func_iter.next()) |entry| {
            compiler.user_functions.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        compiler.next_user_func_id = @intCast(self.vm.user_functions.items.len);

        const compiled = compiler.compile() catch |err| {
            if (compiler.error_msg) |msg| {
                self.setError(msg);
            } else {
                self.setError(@errorName(err));
            }
            self.vm.last_error_offset = compiler.error_offset;
            return err;
        };

        const expr = try self.allocator.create(CompiledExpr);
        expr.* = compiled;

        var comp_iter = compiler.variables.iterator();
        while (comp_iter.next()) |entry| {
            if (!self.variables.contains(entry.key_ptr.*)) {
                const duped_key = self.arena.dupeStr(entry.key_ptr.*);
                self.variables.put(duped_key, entry.value_ptr.*) catch {};
            }
        }
        self.next_var_index = compiler.next_var_index;

        var comp_func_iter = compiler.user_functions.iterator();
        while (comp_func_iter.next()) |entry| {
            // Overwrite on redefinition: the name must follow its newest table id.
            if (self.functions.getPtr(entry.key_ptr.*)) |existing| {
                existing.* = entry.value_ptr.*;
            } else {
                const duped_key = self.arena.dupeStr(entry.key_ptr.*);
                self.functions.put(duped_key, entry.value_ptr.*) catch {};
            }
        }

        return expr;
    }

    pub fn toLaTeX(self: *Self, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var compiler = try Compiler.initWithConfig(self.allocator, source, &self.config);
        defer compiler.deinit();
        compiler.registry = &self.unit_registry;
        return try compiler.toLaTeX(allocator);
    }

    pub fn compileInPlace(self: *Self, source: []const u8) !CompiledExpr {
        self.compiler_cache.reset();
        const allocator = self.compiler_cache.getAllocator();

        var compiler = try Compiler.initWithConfig(allocator, source, &self.config);
        compiler.registry = &self.unit_registry;
        compiler.variable_tags = self.vm.variables_tags;
        compiler.metadata_allocator = self.arena.getAllocator(); // Use session arena

        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            compiler.variables.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        compiler.next_var_index = self.next_var_index;

        var func_iter = self.functions.iterator();
        while (func_iter.next()) |entry| {
            compiler.user_functions.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        compiler.next_user_func_id = @intCast(self.vm.user_functions.items.len);

        var expr = compiler.compile() catch |err| {
            if (compiler.error_msg) |msg| {
                self.setError(msg);
            } else {
                self.setError(@errorName(err));
            }
            self.vm.last_error_offset = compiler.error_offset;
            compiler.deinit();
            return err;
        };
        expr.owns_memory = false;

        var comp_iter = compiler.variables.iterator();
        while (comp_iter.next()) |entry| {
            if (!self.variables.contains(entry.key_ptr.*)) {
                const duped_key = self.arena.dupeStr(entry.key_ptr.*);
                self.variables.put(duped_key, entry.value_ptr.*) catch {};
            }
        }
        self.next_var_index = compiler.next_var_index;

        var comp_func_iter = compiler.user_functions.iterator();
        while (comp_func_iter.next()) |entry| {
            // Overwrite on redefinition: the name must follow its newest table id.
            if (self.functions.getPtr(entry.key_ptr.*)) |existing| {
                existing.* = entry.value_ptr.*;
            } else {
                const duped_key = self.arena.dupeStr(entry.key_ptr.*);
                self.functions.put(duped_key, entry.value_ptr.*) catch {};
            }
        }

        compiler.deinit();
        return expr;
    }

    pub fn freeExpr(self: *Self, expr: *CompiledExpr) void {
        expr.deinit();
        self.allocator.destroy(expr);
    }

    fn canExecuteNumbersOnly(self: *Self, expr: *const CompiledExpr) bool {
        _ = self;
        _ = expr;
        return true;
    }

    pub fn evaluate(self: *Self, expr: *const CompiledExpr) !Value {
        self.clearError();
        const fast_path = expr.is_number_only and self.canExecuteNumbersOnly(expr);
        if (fast_path) {
            if (self.vm.executeNumbersOnly(expr)) |res| {
                return Value.initNumber(res);
            }
        }
        if (expr.fast_path_ok) {
            if (self.vm.executeNumbersFast(expr)) |res| {
                return Value.initNumber(res);
            }
        }
        const result = self.vm.execute(expr) catch |err| {
            if (self.last_error_len == 0) {
                switch (err) {
                    error.TypeError => self.setError("Type error: operation requires compatible types"),
                    error.NotEnoughArgs => self.setError("Not enough arguments for function"),
                    error.TooManyArgs => self.setError("Too many arguments for function"),
                    error.MismatchedDimensions => self.setError("Matrix dimension mismatch"),
                    error.SingularMatrix => self.setError("Cannot invert singular matrix"),
                    error.RuntimeError => self.setError("Runtime error during computation"),
                    error.UnimplementedOpcode => self.setError("Unimplemented operation"),
                    error.OutOfMemory => self.setError("Out of memory"),
                    error.UnknownFunction => self.setError("Unknown function"),
                    error.UnsortedTimestamps => self.setError("Series timestamps must be sorted"),
                    error.EmptySeries => self.setError("Series is empty"),
                    error.NaNTimestamp => self.setError("Series contains NaN timestamps"),
                    error.MismatchedLengths => self.setError("Series lengths do not match"),
                    error.InvalidValue => self.setError("Invalid value in computation"),
                    error.InsufficientData => self.setError("Not enough data for operation"),
                    error.InvalidArgument => self.setError("Invalid argument: check function periods or parameters"),
                    error.AssertionFailed => self.setError("Assertion failed"),
                    error.InvalidStep => self.setError("Invalid time step size: must be positive"),
                    error.ResultTooLarge => self.setError("ODE result exceeds maximum allowed steps"),
                    error.MatrixUnitElementUnsupported => self.setError("Matrix unit element unsupported: unit-bearing matrix literals are not supported (use [1,2]*m for homogeneous scale)"),
                    else => self.setError(@errorName(err)),
                }
            }
            return err;
        };
        return result;
    }

    pub fn evaluateF64(self: *Self, expr: *const CompiledExpr) f64 {
        // Fast path only valid for number-only expressions with populated constants
        if (expr.is_number_only and self.canExecuteNumbersOnly(expr)) {
            if (self.vm.executeNumbersOnly(expr)) |res| {
                return res;
            }
        }
        if (expr.fast_path_ok) {
            if (self.vm.executeNumbersFast(expr)) |res| {
                return res;
            }
        }
        // Fallback to regular execution for non-number-only expressions
        const result = self.vm.execute(expr) catch return std.math.nan(f64);
        return result.toNumber() orelse std.math.nan(f64);
    }

    pub fn loadScript(self: *Self, path: []const u8) !void {
        try self.loadScriptWithOptions(path, .{ .show_results = true });
    }

    pub const ScriptOptions = struct {
        show_results: bool = true,
        show_line_numbers: bool = true,
        use_colors: bool = true,
        align_width: usize = 80, // Column where results start
    };

    // ANSI color codes
    const ANSI_RESET = "\x1b[0m";
    const ANSI_GREEN = "\x1b[32m";
    const ANSI_RED = "\x1b[31m";
    const ANSI_DIM = "\x1b[2m";

    pub fn loadScriptWithOptions(self: *Self, path: []const u8, options: ScriptOptions) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var line_num: usize = 1;
        while (line_iter.next()) |line| : (line_num += 1) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Build the line prefix
            var prefix_len: usize = 0;
            if (options.show_line_numbers) {
                // Calculate prefix length: "[Line XXX] "
                var num_digits: usize = 1;
                var n = line_num;
                while (n >= 10) : (n /= 10) num_digits += 1;
                prefix_len = 7 + num_digits + 2; // "[Line " + digits + "] "
                threading.debugPrint("[Line {d}] {s}", .{ line_num, trimmed });
            } else {
                threading.debugPrint("{s}", .{trimmed});
            }

            const res = try self.eval(trimmed);
            defer res.release();

            if (options.show_results) {
                // Calculate padding for alignment
                const current_len = prefix_len + trimmed.len;
                const padding = if (current_len < options.align_width)
                    options.align_width - current_len
                else
                    1;

                // Print padding spaces
                var i: usize = 0;
                while (i < padding) : (i += 1) threading.debugPrint(" ", .{});

                // Print arrow with dim color
                if (options.use_colors) threading.debugPrint("{s}", .{ANSI_DIM});
                threading.debugPrint("=> ", .{});
                if (options.use_colors) threading.debugPrint("{s}", .{ANSI_RESET});

                // Print result with color based on success/error
                const is_error = res.tag == .err;
                if (options.use_colors) {
                    if (is_error) {
                        threading.debugPrint("{s}", .{ANSI_RED});
                    } else {
                        threading.debugPrint("{s}", .{ANSI_GREEN});
                    }
                }
                self.printValue(res);
                if (options.use_colors) threading.debugPrint("{s}", .{ANSI_RESET});
            }
            threading.debugPrint("\n", .{});
        }
    }

    /// Format a value to a writer
    fn tryLengthPowerDisplay(u: UnitValue) ?LengthPowerDisplay {
        if (u.info.dimensions.l <= 0) return null;
        if (u.info.dimensions.m != 0 or u.info.dimensions.t != 0 or u.info.dimensions.i != 0 or u.info.dimensions.k != 0 or u.info.dimensions.n != 0 or u.info.dimensions.j != 0) {
            return null;
        }

        const exp: i8 = u.info.dimensions.l;
        const prefixes = [_]struct { name: []const u8, scale: f64 }{
            .{ .name = "", .scale = 1.0 },
            .{ .name = "k", .scale = 1e3 },
            .{ .name = "M", .scale = 1e6 },
            .{ .name = "G", .scale = 1e9 },
            .{ .name = "c", .scale = 1e-2 },
            .{ .name = "m", .scale = 1e-3 },
            .{ .name = "u", .scale = 1e-6 },
            .{ .name = "n", .scale = 1e-9 },
        };

        const abs_val = @abs(u.value);
        if (abs_val == 0) return LengthPowerDisplay{ .scaled_value = 0, .prefix = "", .exp = exp };

        var best = LengthPowerDisplay{ .scaled_value = u.value, .prefix = "", .exp = exp };
        var best_score = std.math.inf(f64);

        for (prefixes) |p| {
            const denom = std.math.pow(f64, p.scale, @as(f64, @floatFromInt(exp)));
            if (denom == 0) continue;
            const scaled = u.value / denom;
            const abs_scaled = @abs(scaled);
            if (abs_scaled == 0) continue;

            var score = @abs(@log10(abs_scaled));
            if (abs_scaled >= 1 and abs_scaled < 1000) score -= 10;
            if (score < best_score) {
                best_score = score;
                best = LengthPowerDisplay{ .scaled_value = scaled, .prefix = p.name, .exp = exp };
            }
        }

        return best;
    }

    pub fn formatValue(self: *Self, value: Value, writer: anytype) !void {
        switch (value.tag) {
            .number => {
                const num = value.data.number;
                if (@abs(num - @round(num)) < 1e-10 and @abs(num) < 1e15) {
                    try writer.print("{d}", .{@as(i64, @intFromFloat(num))});
                } else {
                    try writer.print("{d:.6}", .{num});
                }
            },
            .complex => {
                const c = value.data.complex;
                if (c.im >= 0) {
                    try writer.print("{d:.4} + {d:.4}i", .{ c.re, c.im });
                } else {
                    try writer.print("{d:.4} - {d:.4}i", .{ c.re, -c.im });
                }
            },
            .boolean => {
                try writer.print("{s}", .{if (value.data.boolean) "true" else "false"});
            },
            .matrix => {
                const m = value.data.matrix;
                if (m.rows <= 4 and m.cols <= 4) {
                    // Small matrix: print contents
                    try writer.print("[", .{});
                    for (0..m.rows) |r| {
                        if (r > 0) try writer.print("; ", .{});
                        for (0..m.cols) |c| {
                            if (c > 0) try writer.print(", ", .{});
                            const v = m.get(@intCast(r), @intCast(c));
                            if (@abs(v - @round(v)) < 1e-10 and @abs(v) < 1e10) {
                                try writer.print("{d}", .{@as(i64, @intFromFloat(v))});
                            } else {
                                try writer.print("{d:.4}", .{v});
                            }
                        }
                    }
                    try writer.print("]", .{});
                } else {
                    try writer.print("<Matrix {d}x{d}>", .{ m.rows, m.cols });
                }
            },
            .series => {
                const s = value.data.series;
                if (s.len <= 5) {
                    try writer.print("Series[", .{});
                    for (0..s.len) |i| {
                        if (i > 0) try writer.print(", ", .{});
                        if (s.validity[i] == 0 or std.math.isNan(s.values[i])) {
                            try writer.print("nan", .{});
                        } else {
                            try writer.print("{d:.4}", .{s.values[i]});
                        }
                    }
                    try writer.print("]", .{});
                } else if (s.len <= 10) {
                    try writer.print("Series[", .{});
                    for (0..3) |i| {
                        if (i > 0) try writer.print(", ", .{});
                        if (s.validity[i] == 0 or std.math.isNan(s.values[i])) {
                            try writer.print("nan", .{});
                        } else {
                            try writer.print("{d:.4}", .{s.values[i]});
                        }
                    }
                    try writer.print(", ..., ", .{});
                    if (s.validity[s.len - 1] == 0 or std.math.isNan(s.values[s.len - 1])) {
                        try writer.print("nan", .{});
                    } else {
                        try writer.print("{d:.4}", .{s.values[s.len - 1]});
                    }
                    try writer.print("] (len={d})", .{s.len});
                } else {
                    try writer.print("<Series len={d}, range=[{d:.2}..{d:.2}]>", .{ s.len, s.min_ts, s.max_ts });
                }
            },
            .record => {
                const rec = value.data.record;
                try writer.print("{{", .{});
                var first = true;
                var it = rec.fields.iterator();
                while (it.next()) |entry| {
                    if (!first) try writer.print(", ", .{});
                    first = false;
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try self.formatValue(entry.value_ptr.*, writer);
                }
                try writer.print("}}", .{});
            },
            .unit => {
                const u = value.data.unit;
                const display_val = (u.value - u.info.offset) / u.info.scale;
                if (u.info.name) |name| {
                    try writer.print("{d:.4} {s}", .{ display_val, name });
                } else if (self.unit_registry.findBestUnit(u.info.dimensions)) |best_name| {
                    const unit = self.unit_registry.units.get(best_name).?;
                    const scaled_val = (u.value - unit.offset) / unit.scale;
                    try writer.print("{d:.4} {s}", .{ scaled_val, best_name });
                } else if (tryLengthPowerDisplay(u)) |pretty| {
                    if (pretty.exp == 1) {
                        try writer.print("{d:.4} {s}m", .{ pretty.scaled_value, pretty.prefix });
                    } else {
                        try writer.print("{d:.4} {s}m^{d}", .{ pretty.scaled_value, pretty.prefix, pretty.exp });
                    }
                } else {
                    const dim_str = u.info.dimensions.format(self.allocator) catch "[unit]";
                    defer if (!std.mem.eql(u8, dim_str, "[unit]")) self.allocator.free(dim_str);
                    try writer.print("{d:.4} {s}", .{ u.value, dim_str });
                }
            },
            .string => {
                const s = value.data.string.toSlice();
                try writer.print("\"{s}\"", .{s});
            },
            .undefined => try writer.print("undefined", .{}),
            .null_val => try writer.print("null", .{}),
            .err => try writer.print("<error:{d}>", .{value.data.err}),
            .function => try writer.print("<function>", .{}),
            .predicate => try writer.print("<predicate>", .{}),
            .array => try writer.print("<array>", .{}),
            .slice => try writer.print("<slice>", .{}),
        }
    }

    /// Print a value to stderr for debugging/REPL output
    pub fn printValue(self: *Self, value: Value) void {
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();
        self.formatValue(value, &aw.writer) catch return;
        threading.debugPrint("{s}", .{aw.written()});
    }

    pub fn getOrCreateVariable(self: *Self, name: []const u8) u24 {
        if (self.variables.get(name)) |index| {
            return index;
        }
        const index = self.next_var_index;
        const duped_name = self.arena.dupeStr(name);
        self.variables.put(duped_name, index) catch {};
        self.next_var_index += 1;
        return index;
    }

    pub fn getFunctions(self: *Self) ![]const u8 {
        var names = std.ArrayListUnmanaged([]const u8).empty;
        defer names.deinit(self.allocator);

        var iter = self.functions.iterator();
        while (iter.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }

        var json_buf = std.ArrayListUnmanaged(u8).empty;
        // We use arena allocator for the result so it persists
        const allocator = self.arena.getAllocator();

        try json_buf.append(allocator, '[');
        for (names.items, 0..) |name, i| {
            if (i > 0) try json_buf.append(allocator, ',');
            try json_buf.append(allocator, '"');
            try json_buf.appendSlice(allocator, name);
            try json_buf.append(allocator, '"');
        }
        try json_buf.append(allocator, ']');

        return try json_buf.toOwnedSlice(allocator);
    }

    pub fn createSeries(self: *Self, len: usize, mode: timeseries.SampleMode) !*timeseries.Series {
        const s = try timeseries.Series.init(self.allocator, len, mode, .{});
        self.vm.trackSeries(s);
        return s;
    }

    pub fn setVariable(self: *Self, name: []const u8, value: Value) void {
        const idx = self.getOrCreateVariable(name);
        value.retain();
        const old_val = self.vm.variables[idx];
        old_val.release();
        self.vm.variables[idx] = value;
        self.vm.variables_tags[idx] = value.tag;
        self.vm.variables_f64[idx] = value.toNumber() orelse 0;
    }

    pub fn setNumber(self: *Self, name: []const u8, value: f64) void {
        const idx = self.getOrCreateVariable(name);
        const new_val = Value.initNumber(value);
        const old_val = self.vm.variables[idx];
        old_val.release();
        self.vm.variables[idx] = new_val;
        self.vm.variables_tags[idx] = .number;
        self.vm.variables_f64[idx] = value;
    }

    pub fn setVariableByIndex(self: *Self, index: u24, value: Value) void {
        value.retain();
        const old_val = self.vm.variables[index];
        old_val.release();
        self.vm.variables[index] = value;
        self.vm.variables_tags[index] = value.tag;
        self.vm.variables_f64[index] = value.toNumber() orelse 0;
    }

    pub fn setVariableByIndexF64(self: *Self, index: u24, value: f64) void {
        const new_val = Value.initNumber(value);
        const old_val = self.vm.variables[index];
        old_val.release();
        self.vm.variables[index] = new_val;
        self.vm.variables_tags[index] = .number;
        self.vm.variables_f64[index] = value;
    }

    pub fn addVariableIndexed(self: *Self, name: []const u8, initial_val: f64) u24 {
        const idx = self.getOrCreateVariable(name);
        self.vm.variables_f64[idx] = initial_val;
        const old_val = self.vm.variables[idx];
        old_val.release();
        self.vm.variables[idx] = Value.initNumber(initial_val);
        self.vm.variables_tags[idx] = .number;
        return idx;
    }

    pub fn eval(self: *Self, source: []const u8) !Value {
        const expr = try self.compileInPlace(source);
        return try self.evaluate(&expr);
    }

    pub fn lastError(self: *Self) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn setError(self: *Self, message: []const u8) void {
        const len = @min(message.len, self.last_error.len - 1);
        @memcpy(self.last_error[0..len], message[0..len]);
        self.last_error[len] = 0;
        self.last_error_len = len;
    }

    pub fn clearError(self: *Self) void {
        self.last_error_len = 0;
        self.last_error[0] = 0;
    }

    pub fn getError(self: *Self) [*:0]const u8 {
        if (self.last_error_len == 0) return "No error";
        return @ptrCast(&self.last_error);
    }

    pub fn getMemoryUsed(self: *Self) usize {
        return self.arena.allocated_bytes;
    }

    pub fn getMemoryReserved(self: *Self) usize {
        return self.arena.totalReserved();
    }

    pub fn getMemoryPeak(self: *Self) usize {
        return self.arena.peak_bytes;
    }

    pub fn resetMemory(self: *Self) void {
        self.arena.reset();
    }

    /// Write a variable to CSV file
    pub fn writeCsvVar(self: *Self, var_name: []const u8, path: []const u8) bool {
        if (comptime threading.is_wasm) {
            self.setError("CSV export not supported in WASM");
            return false;
        }
        const var_idx = self.variables.get(var_name) orelse {
            self.setError("Variable not found");
            return false;
        };
        const val = self.vm.variables[var_idx];

        const csv = @import("io/csv.zig");
        csv.writeCsv(path, val, .{}) catch |err| {
            self.setError(@errorName(err));
            return false;
        };
        return true;
    }

    /// Get the source offset of the last error
    pub fn getLastErrorOffset(self: *Self) u32 {
        return self.vm.getLastErrorOffset();
    }
};

test "MathZig unit conversion" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const result = try ctx.eval("conv(5 * cm, in)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.9685), result.toNumber().?, 0.0001);
}

test "MathZig matrix arithmetic" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const result = try ctx.eval("[1, 2; 3, 4] * 2 + 10");
    try std.testing.expectEqual(ValueTag.matrix, result.tag);
    const m = result.data.matrix;
    defer m.deinit();

    try std.testing.expectEqual(@as(f64, 12), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 14), m.get(0, 1));
    try std.testing.expectEqual(@as(f64, 16), m.get(1, 0));
    try std.testing.expectEqual(@as(f64, 18), m.get(1, 1));
}

const aot_wire = @import("aot_wire.zig");

/// C ABI export: delegate one AOT wire-format builtin call through the VM.
pub fn callBuiltinWireExport(
    ctx: ?*anyopaque,
    builtin_id: i32,
    argc: i32,
    args_ptr: ?[*]const f64,
    kinds_ptr: ?[*]const u8,
    pred_ptr: ?[*]const u8,
) callconv(.c) f64 {
    const c = ctx orelse return std.math.nan(f64);
    const mz: *MathZig = @ptrCast(@alignCast(c));

    if (builtin_id < 0 or argc < 0) return std.math.nan(f64);
    if (argc > 0 and args_ptr == null) return std.math.nan(f64);

    aot_wire.clearLastWireResult();

    const func: BuiltinFn = @enumFromInt(@as(u16, @truncate(@as(u32, @intCast(builtin_id)))));
    const args = if (args_ptr) |p| p[0..@intCast(argc)] else @as([]const f64, &.{});

    var pred_cache = std.AutoHashMap(usize, *timeseries.Predicate).init(mz.arena.getAllocator());
    defer pred_cache.deinit();

    const predicate: ?*const timeseries.Predicate = if (pred_ptr) |pp|
        aot_wire.decodePredicateTree(mz.arena.getAllocator(), pp, 0, &pred_cache) catch null
    else
        null;

    return aot_wire.callBuiltinWire(
        &mz.vm,
        mz.allocator,
        mz.arena.getAllocator(),
        func,
        @intCast(argc),
        args,
        kinds_ptr,
        predicate,
    ) catch std.math.nan(f64);
}

/// C ABI export: kind of the last delegated call's result (see aot_wire).
pub fn lastWireKindExport() callconv(.c) u8 {
    return aot_wire.lastWireResultKind();
}

/// C ABI exports: field-by-field record crossing (see aot_wire).
pub fn recordKeyAtExport(rec: ?*anyopaque, index: u32) callconv(.c) ?[*:0]const u8 {
    const r: *Record = @ptrCast(@alignCast(rec orelse return null));
    return aot_wire.recordKeyAt(r, index);
}

pub fn recordValueWireAtExport(rec: ?*anyopaque, index: u32) callconv(.c) f64 {
    const r: *Record = @ptrCast(@alignCast(rec orelse return std.math.nan(f64)));
    return aot_wire.recordValueWireAt(r, index);
}

pub fn recordValueKindAtExport(rec: ?*anyopaque, index: u32) callconv(.c) u8 {
    const r: *Record = @ptrCast(@alignCast(rec orelse return 255));
    return aot_wire.recordValueKindAt(r, index);
}

/// C ABI export: create an empty engine record owned by this context's arena
/// (lives until the context is destroyed; no host-side free needed).
pub fn recordNewExport(ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
    const c = ctx orelse return null;
    const mz: *MathZig = @ptrCast(@alignCast(c));
    const arena = mz.arena.getAllocator();
    const rec = Record.init(arena, arena) catch return null;
    return rec;
}

/// C ABI export: set one field on a host-built record from a wire + kind byte.
pub fn recordSetWireExport(
    ctx: ?*anyopaque,
    rec: ?*anyopaque,
    key: ?[*:0]const u8,
    wire: f64,
    kind: u8,
) callconv(.c) bool {
    const c = ctx orelse return false;
    const mz: *MathZig = @ptrCast(@alignCast(c));
    const r: *Record = @ptrCast(@alignCast(rec orelse return false));
    const k = key orelse return false;
    aot_wire.recordSetFromWire(
        r,
        mz.arena.getAllocator(),
        std.mem.span(k),
        wire,
        @enumFromInt(kind),
    ) catch return false;
    return true;
}
