const std = @import("std");
const mathzig = @import("mathzig");
const version = mathzig.version;
const matrix_kernels = mathzig.matrix_kernels;

// This file defines the Public API Surface of MathZig.
// It is read by the `tools/bindings/abi_inspector.zig` to generate:
// 1. generated/exports.zig (The C ABI)
// 2. generated/api.json (The Schema)
// 3. generated/classes.ts (The TypeScript SDK)

pub const ExportConfig = .{
    .classes = .{
        .MathZig = .{
            .description = "The main MathZig evaluation context",
            .methods = .{
                .compile = .{
                    .fn_ptr = mathzig.MathZig.compile,
                    .export_name = "mathzig_compile",
                    .description = "Compiles an expression string",
                    .args = .{ .self = "this", .expr = "string" },
                },
                .freeExpr = .{
                    .fn_ptr = mathzig.MathZig.freeExpr,
                    .export_name = "mathzig_free_expr",
                    .description = "Frees a compiled expression",
                    .args = .{ .self = "this", .expr = "other" },
                },
                .eval = .{
                    .fn_ptr = mathzig.MathZig.eval,
                    .export_name = "mathzig_eval",
                    .description = "Evaluates an expression string directly",
                    .args = .{ .self = "this", .expr = "string" },
                },
                .setVariable = .{
                    .fn_ptr = mathzig.MathZig.setNumber,
                    .export_name = "mathzig_set_variable",
                    .description = "Sets a numeric variable",
                    .args = .{ .self = "this", .name = "string", .val = "f64" },
                },
                .addVariableIndexed = .{
                    .fn_ptr = mathzig.MathZig.addVariableIndexed,
                    .export_name = "mathzig_add_variable_indexed",
                    .description = "Adds a variable and returns its index",
                    .args = .{ .self = "this", .name = "string", .initial_val = "f64" },
                },
                .setByIndex = .{
                    .fn_ptr = struct {
                        fn call(self: *mathzig.MathZig, index: i32, val: f64) void {
                            if (index < 0) {
                                self.setError("Variable index cannot be negative");
                                return;
                            }
                            if (index >= 256) {
                                self.setError("Variable index exceeds maximum allowed (255)");
                                return;
                            }
                            self.setVariableByIndexF64(@intCast(index), val);
                        }
                    }.call,
                    .export_name = "mathzig_set_by_index",
                    .description = "Sets a variable value by index",
                    .args = .{ .self = "this", .index = "i32", .val = "f64" },
                },
                .setByIndexFast = .{
                    .fn_ptr = struct {
                        fn call(self: *mathzig.MathZig, index: i32, val: f64) void {
                            if (index < 0 or index >= self.vm.variables_f64.len) {
                                self.setError("Variable index out of bounds for fast path");
                                return;
                            }
                            self.vm.variables_f64[@intCast(index)] = val;
                        }
                    }.call,
                    .export_name = "mathzig_set_by_index_fast",
                    .args = .{ .self = "this", .index = "i32", .val = "f64" },
                },
                .getVariablesPtr = .{
                    .fn_ptr = struct {
                        fn call(self: *mathzig.MathZig) [*]f64 {
                            return self.vm.variables_f64.ptr;
                        }
                    }.call,
                    .export_name = "mathzig_get_variables_ptr",
                    .args = .{ .self = "this" },
                },
                .toLaTeX = .{
                    .fn_ptr = struct {
                        fn call(self: *mathzig.MathZig, source: [*:0]const u8) ?[*:0]const u8 {
                            const input = std.mem.span(source);
                            const latex_str = self.toLaTeX(input, self.arena.getAllocator()) catch |err| {
                                self.setError(@errorName(err));
                                return null;
                            };
                            // Duplicate to null-terminated string in arena for safety
                            const sentinel_slice = self.arena.getAllocator().dupeZ(u8, latex_str) catch return null;
                            return sentinel_slice.ptr;
                        }
                    }.call,
                    .export_name = "mathzig_to_latex",
                    .description = "Generates LaTeX from an expression string",
                    .args = .{ .self = "this", .expr = "string" },
                },
                .getError = .{
                    .fn_ptr = mathzig.MathZig.getError,
                    .export_name = "mathzig_get_error",
                    .description = "Returns the last error message",
                    .args = .{ .self = "this" },
                },
                .getMemoryUsed = .{
                    .fn_ptr = mathzig.MathZig.getMemoryUsed,
                    .export_name = "mathzig_get_memory_used",
                    .args = .{ .self = "this" },
                },
                .getMemoryReserved = .{
                    .fn_ptr = mathzig.MathZig.getMemoryReserved,
                    .export_name = "mathzig_get_memory_reserved",
                    .args = .{ .self = "this" },
                },
                .getMemoryPeak = .{
                    .fn_ptr = mathzig.MathZig.getMemoryPeak,
                    .export_name = "mathzig_get_memory_peak",
                    .args = .{ .self = "this" },
                },
                .resetMemory = .{
                    .fn_ptr = mathzig.MathZig.resetMemory,
                    .export_name = "mathzig_reset_memory",
                    .args = .{ .self = "this" },
                },
                .version = .{
                    .fn_ptr = struct {
                        fn get(self: *mathzig.MathZig) [*:0]const u8 {
                            _ = self;
                            return version.cString();
                        }
                    }.get,
                    .export_name = "mathzig_version",
                    .args = .{ .self = "this" },
                },
                .getFunctions = .{
                    .fn_ptr = struct {
                        fn call(self: *mathzig.MathZig) [*:0]const u8 {
                            const json = self.getFunctions() catch return "[]";
                            // The string is allocated in the arena, so it lives as long as the context (or until reset)
                            // We need to ensure it's null-terminated for C
                            // std.json.stringifyAlloc doesn't guarantee sentinel
                            const sentinel_slice = self.arena.getAllocator().dupeZ(u8, json) catch return "[]";
                            return sentinel_slice.ptr;
                        }
                    }.call,
                    .export_name = "mathzig_get_functions",
                    .description = "Returns a JSON array of defined user function names",
                    .args = .{ .self = "this" },
                },
                .createSeries = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, timestamps: ?[*]const f64, values: ?[*]const f64, count: usize, sample_mode: usize) ?*mathzig.timeseries.Series {
                            // Empty series (count==0) are valid (e.g. head(s,0), dropna of all-NaN).
                            // Pointers may be null only when count is 0; bun:ffi cannot form
                            // empty ArrayBufferViews so hosts may pass a dummy pointer + 0.
                            if (count > 0 and (timestamps == null or values == null)) {
                                ctx.setError("Invalid series data: null pointer with non-zero count");
                                return null;
                            }
                            const mode = @as(mathzig.timeseries.SampleMode, @enumFromInt(@as(u8, @truncate(sample_mode))));
                            const series = mathzig.timeseries.Series.init(ctx.allocator, count, mode, .{}) catch |err| {
                                ctx.setError(@errorName(err));
                                return null;
                            };
                            if (count > 0) {
                                @memcpy(series.timestamps[0..count], timestamps.?[0..count]);
                                @memcpy(series.values[0..count], values.?[0..count]);
                            }
                            // Set metadata before validation
                            series.len = count;
                            series.validate() catch |err| {
                                ctx.setError(@errorName(err));
                                series.release();
                                return null;
                            };
                            return series;
                        }
                    }.call,
                    .export_name = "mathzig_create_series",
                    .args = .{ .ctx = "this", .timestamps = "[*]const f64", .values = "[*]const f64", .count = "usize", .sample_mode = "usize" },
                },
                .compilePolynomial = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, var_index: i32, coefficients: ?[*]const f64, count: u32) ?*mathzig.CompiledExpr {
                            if (var_index < 0) {
                                ctx.setError("Variable index cannot be negative");
                                return null;
                            }
                            if (coefficients == null or count == 0 or count > 255) {
                                ctx.setError("Invalid coefficients: null pointer or invalid count (1-255)");
                                return null;
                            }
                            const expr = ctx.allocator.create(mathzig.CompiledExpr) catch return null;
                            const code = ctx.allocator.alloc(mathzig.Instruction, 2) catch {
                                ctx.allocator.destroy(expr);
                                return null;
                            };
                            const constants = ctx.allocator.alloc(mathzig.Value, count) catch {
                                ctx.allocator.free(code);
                                ctx.allocator.destroy(expr);
                                return null;
                            };
                            const constants_f64 = ctx.allocator.alloc(f64, count) catch {
                                ctx.allocator.free(constants);
                                ctx.allocator.free(code);
                                ctx.allocator.destroy(expr);
                                return null;
                            };
                            for (0..count) |i| {
                                constants[i] = mathzig.Value.initNumber(coefficients.?[i]);
                                constants_f64[i] = coefficients.?[i];
                            }
                            const operand: u24 = @as(u24, @intCast(var_index)) | (@as(u24, @intCast(count & 0xFF)) << 16);
                            code[0] = mathzig.Instruction.initWithOperand(mathzig.Opcode.eval_poly, operand);
                            code[1] = mathzig.Instruction.init(mathzig.Opcode.halt);
                            expr.* = .{
                                .code = code,
                                .constants = constants,
                                .constants_f64 = constants_f64,
                                .source_offsets = &.{},
                                .max_stack = 1,
                                .is_number_only = true,
                                .allocator = ctx.allocator,
                            };
                            return expr;
                        }
                    }.call,
                    .export_name = "mathzig_compile_polynomial",
                    .args = .{ .ctx = "this", .var_index = "i32", .coefficients = "[*]const f64", .count = "u32" },
                },
                .setSeries = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, name: []const u8, series_ptr: ?*anyopaque) bool {
                            if (series_ptr == null) {
                                ctx.setError("Series pointer cannot be null");
                                return false;
                            }
                            if (name.len == 0) {
                                ctx.setError("Variable name cannot be empty");
                                return false;
                            }
                            const series: *mathzig.timeseries.Series = @ptrCast(@alignCast(series_ptr.?));
                            ctx.setVariable(name, mathzig.Value.initSeries(series));
                            return true;
                        }
                    }.call,
                    .export_name = "mathzig_set_series",
                    .args = .{ .ctx = "this", .name = "string", .series = "[*]u8" },
                },
                .setDebug = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, debug: bool) void {
                            ctx.vm.setDebug(debug);
                        }
                    }.call,
                    .export_name = "mathzig_set_debug",
                    .args = .{ .ctx = "this", .debug = "bool" },
                },
                .writeCsv = .{
                    .fn_ptr = mathzig.MathZig.writeCsvVar,
                    .export_name = "mathzig_write_csv",
                    .args = .{ .ctx = "this", .var_name = "string", .path = "string" },
                },
                .getLastErrorOffset = .{
                    .fn_ptr = mathzig.MathZig.getLastErrorOffset,
                    .export_name = "mathzig_get_last_error_offset",
                    .args = .{ .ctx = "this" },
                },
                .recordNew = .{
                    .fn_ptr = mathzig.recordNewExport,
                    .export_name = "mathzig_record_new",
                    .description = "Creates an empty engine record owned by this context's arena",
                    .args = .{ .ctx = "this" },
                },
                .recordSetWire = .{
                    .fn_ptr = mathzig.recordSetWireExport,
                    .export_name = "mathzig_record_set_wire",
                    .description = "Sets one record field from a wire f64 + kind byte",
                    .args = .{
                        .ctx = "this",
                        .rec = "?*anyopaque",
                        .key = "string",
                        .wire = "f64",
                        .kind = "u8",
                    },
                },
                .callBuiltinWire = .{
                    .fn_ptr = mathzig.callBuiltinWireExport,
                    .export_name = "mathzig_call_builtin",
                    .description = "Delegates an AOT wire-format builtin call through the VM",
                    .args = .{
                        .ctx = "this",
                        .builtin_id = "i32",
                        .argc = "i32",
                        .args_ptr = "[*]const f64",
                        .kinds_ptr = "?[*]const u8",
                        .pred_ptr = "?[*]const u8",
                    },
                },
            },
        },
        .CompiledExpr = .{
            .description = "A compiled mathematical expression",
            .methods = .{
                .evaluate = .{
                    .fn_ptr = mathzig.MathZig.evaluate,
                    .export_name = "mathzig_evaluate",
                    .description = "Evaluates the expression",
                    .args = .{ .ctx = "context", .expr = "this" },
                },
                .evaluateFast = .{
                    .fn_ptr = mathzig.MathZig.evaluateF64,
                    .export_name = "mathzig_evaluate_fast",
                    .description = "Evaluates as f64 with minimal overhead",
                    .args = .{ .ctx = "context", .expr = "this" },
                },
                .getBytecodeSize = .{
                    .fn_ptr = struct {
                        fn get(expr: *const mathzig.CompiledExpr) usize {
                            return expr.code.len * @sizeOf(mathzig.Instruction);
                        }
                    }.get,
                    .export_name = "mathzig_expr_bytecode_size",
                    .args = .{ .expr = "this" },
                },
                .getNumInstructions = .{
                    .fn_ptr = struct {
                        fn get(expr: *const mathzig.CompiledExpr) usize {
                            return expr.code.len;
                        }
                    }.get,
                    .export_name = "mathzig_expr_num_instructions",
                    .args = .{ .expr = "this" },
                },
                .getNumVariables = .{
                    .fn_ptr = struct {
                        fn get(expr: *const mathzig.CompiledExpr) usize {
                            _ = expr;
                            return 0;
                        }
                    }.get,
                    .export_name = "mathzig_expr_num_variables",
                    .args = .{ .expr = "this" },
                },
                .getNumConstants = .{
                    .fn_ptr = struct {
                        fn get(expr: *const mathzig.CompiledExpr) usize {
                            return expr.constants.len;
                        }
                    }.get,
                    .export_name = "mathzig_expr_num_constants",
                    .args = .{ .expr = "this" },
                },
                .getStackSize = .{
                    .fn_ptr = struct {
                        fn get(expr: *const mathzig.CompiledExpr) usize {
                            return expr.max_stack;
                        }
                    }.get,
                    .export_name = "mathzig_expr_stack_size",
                    .args = .{ .expr = "this" },
                },
                .evaluateBatch = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, expr: *const mathzig.CompiledExpr, var_index: i32, inputs: [*]const f64, outputs: [*]f64, count: i32) i32 {
                            if (var_index < 0) {
                                ctx.setError("Variable index cannot be negative");
                                return 0;
                            }
                            if (count <= 0) {
                                ctx.setError("Batch count must be positive");
                                return 0;
                            }
                            const n: usize = @intCast(count);
                            const idx: u24 = @intCast(var_index);
                            if (expr.is_number_only) {
                                for (0..n) |i| {
                                    ctx.setVariableByIndexF64(idx, inputs[i]);
                                    outputs[i] = ctx.evaluateF64(expr);
                                }
                                return count;
                            }
                            var successful: i32 = 0;
                            for (0..n) |i| {
                                ctx.setVariableByIndex(idx, mathzig.Value.initNumber(inputs[i]));
                                const result = ctx.evaluate(expr) catch {
                                    outputs[i] = std.math.nan(f64);
                                    continue;
                                };
                                outputs[i] = result.toNumber() orelse std.math.nan(f64);
                                result.release();
                                successful += 1;
                            }
                            return successful;
                        }
                    }.call,
                    .export_name = "mathzig_evaluate_batch",
                    .args = .{ .ctx = "context", .expr = "this", .var_index = "i32", .inputs = "[*]const f64", .outputs = "[*]f64", .count = "i32" },
                },
                .evaluateBatchSIMD = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, expr: *const mathzig.CompiledExpr, var_index: u8, inputs: [*]const f64, outputs: [*]f64, count: u32) void {
                            if (expr.is_number_only) {
                                ctx.vm.executeBatchSIMD(expr, var_index, inputs[0..count], outputs[0..count], count);
                            } else {
                                // Fallback to scalar evaluation for non-number-only expressions
                                for (0..count) |i| {
                                    ctx.setVariableByIndexF64(var_index, inputs[i]);
                                    outputs[i] = ctx.evaluateF64(expr);
                                }
                            }
                        }
                    }.call,
                    .export_name = "mathzig_batch_eval_simd",
                    .args = .{ .ctx = "context", .expr = "this", .var_index = "u8", .inputs = "[*]const f64", .outputs = "[*]f64", .count = "u32" },
                },
                .evaluateBatchParallel = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, expr: *const mathzig.CompiledExpr, var_index: u8, inputs: [*]const f64, outputs: [*]f64, count: u32) void {
                            if (expr.is_number_only) {
                                ctx.vm.executeBatchSIMD(expr, var_index, inputs[0..count], outputs[0..count], count);
                            } else {
                                // Fallback to scalar evaluation for non-number-only expressions
                                for (0..count) |i| {
                                    ctx.setVariableByIndexF64(var_index, inputs[i]);
                                    outputs[i] = ctx.evaluateF64(expr);
                                }
                            }
                        }
                    }.call,
                    .export_name = "mathzig_batch_eval_parallel",
                    .args = .{ .ctx = "context", .expr = "this", .var_index = "u8", .inputs = "[*]const f64", .outputs = "[*]f64", .count = "u32" },
                },
                .evaluateBatchComplexSIMD = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, expr: *const mathzig.CompiledExpr, var_index: u8, re_in: [*]const f64, im_in: [*]const f64, re_out: [*]f64, im_out: [*]f64, count: u32) void {
                            ctx.vm.executeBatchComplexSIMD(expr, var_index, re_in[0..count], im_in[0..count], re_out[0..count], im_out[0..count], count);
                        }
                    }.call,
                    .export_name = "mathzig_batch_eval_complex_simd",
                    .args = .{ .ctx = "context", .expr = "this", .var_index = "u8", .re_in = "[*]const f64", .im_in = "[*]const f64", .re_out = "[*]f64", .im_out = "[*]f64", .count = "u32" },
                },
            },
        },
        .Value = .{
            .description = "A dynamically typed MathZig value",
            .methods = .{
                .retain = .{
                    .fn_ptr = struct {
                        fn call(ptr: ?*anyopaque, tag: u8) void {
                            if (ptr == null) return;
                            const vtag = @as(mathzig.ValueTag, @enumFromInt(tag));
                            switch (vtag) {
                                .matrix => _ = @as(*mathzig.Matrix, @ptrCast(@alignCast(ptr.?))).retain(),
                                .series => _ = @as(*mathzig.timeseries.Series, @ptrCast(@alignCast(ptr.?))).retain(),
                                .record => _ = @as(*mathzig.Record, @ptrCast(@alignCast(ptr.?))).retain(),
                                else => {},
                            }
                        }
                    }.call,
                    .export_name = "mathzig_retain",
                    .args = .{ .ptr = "this", .tag = "u8" },
                },
                .release = .{
                    .fn_ptr = struct {
                        fn call(ptr: ?*anyopaque, tag: u8) void {
                            if (ptr == null) return;
                            const vtag = @as(mathzig.ValueTag, @enumFromInt(tag));
                            switch (vtag) {
                                .matrix => @as(*mathzig.Matrix, @ptrCast(@alignCast(ptr.?))).release(),
                                .series => @as(*mathzig.timeseries.Series, @ptrCast(@alignCast(ptr.?))).release(),
                                .record => @as(*mathzig.Record, @ptrCast(@alignCast(ptr.?))).release(),
                                else => {},
                            }
                        }
                    }.call,
                    .export_name = "mathzig_release",
                    .args = .{ .ptr = "this", .tag = "u8" },
                },
                .toNumber = .{
                    .fn_ptr = struct {
                        fn call(ptr: ?*anyopaque, tag: u8) f64 {
                            if (ptr == null) return std.math.nan(f64);
                            const vtag = @as(mathzig.ValueTag, @enumFromInt(tag));
                            const value = switch (vtag) {
                                .matrix => mathzig.Value{ .tag = .matrix, .data = .{ .matrix = @ptrCast(@alignCast(ptr.?)) } },
                                .series => mathzig.Value{ .tag = .series, .data = .{ .series = @ptrCast(@alignCast(ptr.?)) } },
                                .record => mathzig.Value{ .tag = .record, .data = .{ .record = @ptrCast(@alignCast(ptr.?)) } },
                                .boolean => return if (@as(*bool, @ptrCast(@alignCast(ptr.?))).*) 1.0 else 0.0,
                                .unit => mathzig.Value{ .tag = .unit, .data = .{ .unit = @as(*mathzig.UnitValue, @ptrCast(@alignCast(ptr.?))).* } },
                                .number => return @as(*f64, @ptrCast(@alignCast(ptr.?))).*,
                                else => return std.math.nan(f64),
                            };
                            return value.toNumber() orelse std.math.nan(f64);
                        }
                    }.call,
                    .export_name = "mathzig_value_to_number",
                    .args = .{ .ptr = "this", .tag = "u8" },
                },
                .real = .{
                    .fn_ptr = struct {
                        fn call(ptr: ?*anyopaque) f64 {
                            if (ptr == null) return std.math.nan(f64);
                            return @as(*mathzig.Complex, @ptrCast(@alignCast(ptr.?))).re;
                        }
                    }.call,
                    .export_name = "mathzig_value_real",
                    .args = .{ .ptr = "this" },
                },
                .imag = .{
                    .fn_ptr = struct {
                        fn call(ptr: ?*anyopaque) f64 {
                            if (ptr == null) return std.math.nan(f64);
                            return @as(*mathzig.Complex, @ptrCast(@alignCast(ptr.?))).im;
                        }
                    }.call,
                    .export_name = "mathzig_value_imag",
                    .args = .{ .ptr = "this" },
                },
            },
        },
        .Record = .{
            .description = "A set of named fields",
            .methods = .{
                .len = .{
                    .fn_ptr = mathzig.Record.len,
                    .export_name = "mathzig_record_len",
                    .args = .{ .self = "this" },
                },
                .getField = .{
                    .fn_ptr = struct {
                        fn call(record: *mathzig.Record, key_ptr: [*:0]const u8) mathzig.Value {
                            if (record.magic != 0xDEADC0DE) {
                                return mathzig.Value.initNull();
                            }
                            _ = record.retain();
                            defer {
                                record.release();
                            }
                            const key = std.mem.span(key_ptr);
                            if (record.fields.getPtr(key)) |val_ptr| {
                                val_ptr.retain();
                                return val_ptr.*;
                            }
                            return mathzig.Value.initNull();
                        }
                    }.call,
                    .export_name = "mathzig_record_get_field",
                    .args = .{ .self = "this", .key = "string" },
                },
                .keyAt = .{
                    .fn_ptr = mathzig.recordKeyAtExport,
                    .export_name = "mathzig_record_key_at",
                    .description = "NUL-terminated key of the i-th field (staging buffer, valid until next call)",
                    .args = .{ .self = "this", .index = "u32" },
                },
                .valueWireAt = .{
                    .fn_ptr = mathzig.recordValueWireAtExport,
                    .export_name = "mathzig_record_value_wire_at",
                    .description = "Wire (f64) of the i-th field's value",
                    .args = .{ .self = "this", .index = "u32" },
                },
                .valueKindAt = .{
                    .fn_ptr = mathzig.recordValueKindAtExport,
                    .export_name = "mathzig_record_value_kind_at",
                    .description = "Kind byte of the i-th field's value (0=number..5=record, 255=missing)",
                    .args = .{ .self = "this", .index = "u32" },
                },
            },
        },
        .Series = .{
            .description = "A time-series of floating point values",
            .methods = .{
                .len = .{
                    .fn_ptr = struct {
                        fn get(s: *const mathzig.timeseries.Series) usize {
                            return s.len;
                        }
                    }.get,
                    .export_name = "mathzig_series_len",
                    .args = .{ .self = "this" },
                },
                .duration = .{
                    .fn_ptr = struct {
                        fn get(s: *const mathzig.timeseries.Series) f64 {
                            if (s.len < 2) return 0;
                            return s.max_ts - s.min_ts;
                        }
                    }.get,
                    .export_name = "mathzig_series_duration",
                    .args = .{ .self = "this" },
                },
                .getTimestampsPtr = .{
                    .fn_ptr = struct {
                        fn get(s: *const mathzig.timeseries.Series) [*]const f64 {
                            return s.timestamps.ptr;
                        }
                    }.get,
                    .export_name = "mathzig_series_get_timestamps_ptr",
                    .args = .{ .self = "this" },
                },
                .getValuesPtr = .{
                    .fn_ptr = struct {
                        fn get(s: *const mathzig.timeseries.Series) [*]const f64 {
                            return s.values.ptr;
                        }
                    }.get,
                    .export_name = "mathzig_series_get_values_ptr",
                    .args = .{ .self = "this" },
                },
                .free = .{
                    .fn_ptr = struct {
                        fn call(s: *mathzig.timeseries.Series) void {
                            s.release();
                        }
                    }.call,
                    .export_name = "mathzig_free_series",
                    .args = .{ .self = "this" },
                },
            },
        },
        .Globals = .{
            .description = "Global library functions",
            .methods = .{
                .allocAligned = .{
                    .fn_ptr = struct {
                        fn call(alignment: usize, size: usize) ?[*]u8 {
                            if (size == 0) return null;
                            const builtin = @import("builtin");
                            const is_wasm = builtin.cpu.arch.isWasm();
                            const is_freestanding = builtin.os.tag == .freestanding;
                            
                            const alloc = if (is_wasm or is_freestanding) std.heap.wasm_allocator else std.heap.c_allocator;
                            
                            const ptr_val = switch (alignment) {
                                1 => (alloc.alloc(u8, size) catch return null).ptr,
                                2 => (alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(2), size) catch return null).ptr,
                                4 => (alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4), size) catch return null).ptr,
                                8 => (alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(8), size) catch return null).ptr,
                                16 => (alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(16), size) catch return null).ptr,
                                32 => (alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(32), size) catch return null).ptr,
                                64 => (alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(64), size) catch return null).ptr,
                                else => (alloc.alloc(u8, size) catch return null).ptr,
                            };
                            return ptr_val;
                        }
                    }.call,
                    .export_name = "mathzig_alloc_aligned",
                    .args = .{ .alignment = "usize", .size = "usize" },
                },
                .free = .{
                    .fn_ptr = struct {
                        fn call(ptr_val: ?[*]u8) void {
                            if (ptr_val == null) return;
                            const builtin = @import("builtin");
                            const is_wasm = builtin.cpu.arch.isWasm();
                            const is_freestanding = builtin.os.tag == .freestanding;
                            
                            if (is_wasm or is_freestanding) {
                                // wasm_allocator doesn't support free, but we can't easily free without size here anyway.
                                // In a real system, we'd use a better allocator.
                                return;
                            } else {
                                @import("std").c.free(ptr_val);
                            }
                        }
                    }.call,
                    .export_name = "mathzig_free",
                    .args = .{ .ptr = "[*]u8" },
                },
                .getLastNumber = .{
                    .fn_ptr = struct {
                        fn get() f64 {
                            return 0;
                        }
                    }.get,
                    .export_name = "mathzig_get_last_number",
                    .args = .{},
                },
                .getLastTag = .{
                    .fn_ptr = struct {
                        fn get() u8 {
                            return 0;
                        }
                    }.get,
                    .export_name = "mathzig_get_last_tag",
                    .args = .{},
                },
                .getLastPtr = .{
                    .fn_ptr = struct {
                        fn get() ?*anyopaque {
                            return null;
                        }
                    }.get,
                    .export_name = "mathzig_get_last_ptr",
                    .args = .{},
                },
                .formatLastValue = .{
                    .fn_ptr = struct {
                        fn call(ctx: *mathzig.MathZig, buffer: [*]u8, len: usize) usize {
                            _ = ctx;
                            _ = buffer;
                            _ = len;
                            return 0;
                        }
                    }.call,
                    .export_name = "mathzig_format_last_value",
                    .description = "Formats the last evaluation result into a buffer",
                    .args = .{ .ctx = "this", .buffer = "[*]u8", .len = "usize" },
                },
                .version = .{
                    .fn_ptr = struct {
                        fn get() f64 {
                            return version.versionNumber();
                        }
                    }.get,
                    .export_name = "mathzig_version_number",
                    .args = .{},
                },
                .lastWireKind = .{
                    .fn_ptr = mathzig.lastWireKindExport,
                    .export_name = "mathzig_last_wire_kind",
                    .description = "Kind of the last delegated builtin result (0=number,1=matrix,2=series,3=complex,4=string,5=record,255=none)",
                    .args = .{},
                },
                .builtinId = .{
                    .fn_ptr = struct {
                        fn call(name: [*:0]const u8) i32 {
                            const span = std.mem.span(name);
                            inline for (std.meta.fields(mathzig.BuiltinFn)) |field| {
                                if (std.mem.eql(u8, span, field.name)) {
                                    return @intCast(@intFromEnum(@field(mathzig.BuiltinFn, field.name)));
                                }
                            }
                            return -1;
                        }
                    }.call,
                    .export_name = "mathzig_builtin_id",
                    .description = "Resolves a builtin name to its BuiltinFn discriminant",
                    .args = .{ .name = "string" },
                },
                .matrixFromData = .{
                    .fn_ptr = struct {
                        fn call(rows: u32, cols: u32, data: ?[*]const f64) ?*anyopaque {
                            const count: usize = @as(usize, rows) * @as(usize, cols);
                            // Empty matrices (0×N / N×0 / 0×0) are valid. Hosts may pass a
                            // dummy non-null pointer when count==0 because bun:ffi cannot
                            // form empty ArrayBufferViews.
                            if (count > 0 and data == null) return null;
                            const builtin = @import("builtin");
                            const alloc = if (builtin.cpu.arch.isWasm() or builtin.os.tag == .freestanding)
                                std.heap.wasm_allocator
                            else
                                std.heap.c_allocator;
                            const m = mathzig.Matrix.init(alloc, rows, cols) catch return null;
                            if (count > 0) {
                                @memcpy(m.data[0..count], data.?[0..count]);
                            }
                            return m;
                        }
                    }.call,
                    .export_name = "mathzig_matrix_from_data",
                    .description = "Creates an engine matrix from a row-major f64 buffer",
                    .args = .{ .rows = "u32", .cols = "u32", .data = "[*]const f64" },
                },
            },
        },
        .Matrix = .{
            .description = "A high-performance dense matrix",
            .methods = .{
                .rows = .{
                    .fn_ptr = struct {
                        fn call(m: *const mathzig.Matrix) u32 {
                            return m.rows;
                        }
                    }.call,
                    .export_name = "mathzig_matrix_rows",
                    .args = .{ .m = "this" },
                },
                .cols = .{
                    .fn_ptr = struct {
                        fn call(m: *const mathzig.Matrix) u32 {
                            return m.cols;
                        }
                    }.call,
                    .export_name = "mathzig_matrix_cols",
                    .args = .{ .m = "this" },
                },
                .getData = .{
                    .fn_ptr = struct {
                        fn call(m: *const mathzig.Matrix) [*]const f64 {
                            return m.data.ptr;
                        }
                    }.call,
                    .export_name = "mathzig_matrix_get_data",
                    .args = .{ .m = "this" },
                },
                .multiply = .{
                    .fn_ptr = matrix_kernels.gemm,
                    .export_name = "mathzig_gemm",
                    .description = "Computes C = A * B",
                    .args = .{
                        .rows_a = "this.rows",
                        .cols_a = "this.cols",
                        .cols_b = "other.cols",
                        .A = .{ .binding = "this.data", .len = "rows_a * stride_a" },
                        .stride_a = "this.stride",
                        .B = .{ .binding = "other.data", .len = "cols_a * stride_b" },
                        .stride_b = "other.stride",
                        .C = .{ .binding = "out.data", .len = "rows_a * stride_c" },
                        .stride_c = "out.stride",
                    },
                },
                .multiplyParallel = .{
                    .fn_ptr = matrix_kernels.gemmParallel,
                    .export_name = "mathzig_gemm_parallel",
                    .args = .{
                        .ctx = "context",
                        .rows_a = "this.rows",
                        .cols_a = "this.cols",
                        .cols_b = "other.cols",
                        .A = .{ .binding = "this.data", .len = "rows_a * stride_a" },
                        .stride_a = "this.stride",
                        .B = .{ .binding = "other.data", .len = "cols_a * stride_b" },
                        .stride_b = "other.stride",
                        .C = .{ .binding = "out.data", .len = "rows_a * stride_c" },
                        .stride_c = "out.stride",
                    },
                },
                .inverse = .{
                    .fn_ptr = matrix_kernels.matrixInverse,
                    .export_name = "mathzig_matrix_inverse",
                    .description = "Computes the inverse of the matrix in-place",
                    .args = .{
                        .n = "this.rows",
                        .A = .{ .binding = "this.data", .len = "n * stride_a" },
                        .stride_a = "this.stride",
                        .allocator = "context.allocator",
                    },
                },
                .determinant = .{
                    .fn_ptr = matrix_kernels.determinant,
                    .export_name = "mathzig_determinant",
                    .description = "Computes the determinant of the matrix",
                    .args = .{
                        .n = "this.rows",
                        .A = .{ .binding = "this.data", .len = "n * stride_a" },
                        .stride_a = "this.stride",
                        .allocator = "context.allocator",
                    },
                },
                .gemv = .{
                    .fn_ptr = matrix_kernels.gemv,
                    .export_name = "mathzig_gemv",
                    .args = .{
                        .rows = "this.rows",
                        .cols = "this.cols",
                        .alpha = "f64",
                        .A = .{ .binding = "this.data", .len = "rows * stride_a" },
                        .stride_a = "u32",
                        .x = .{ .binding = "[*]const f64", .len = "cols" },
                        .beta = "f64",
                        .y = .{ .binding = "[*]f64", .len = "rows" },
                    },
                },
                .gemvSimple = .{
                    .fn_ptr = matrix_kernels.gemvSimple,
                    .export_name = "mathzig_gemv_simple",
                    .args = .{
                        .rows = "this.rows",
                        .cols = "this.cols",
                        .A = .{ .binding = "this.data", .len = "rows * stride_a" },
                        .stride_a = "u32",
                        .x = .{ .binding = "[*]const f64", .len = "cols" },
                        .y = .{ .binding = "[*]f64", .len = "rows" },
                    },
                },
                .sum = .{
                    .fn_ptr = struct {
                        fn call(rows: u32, cols: u32, data: [*]const f64) f64 {
                            return mathzig.matrix_kernels.vecSum(data[0 .. rows * cols]);
                        }
                    }.call,
                    .export_name = "mathzig_matrix_sum",
                    .args = .{ .rows = "this.rows", .cols = "this.cols", .data = "this.data" },
                },
                .mean = .{
                    .fn_ptr = struct {
                        fn call(rows: u32, cols: u32, data: [*]const f64) f64 {
                            if (rows == 0 or cols == 0) return std.math.nan(f64);
                            return mathzig.matrix_kernels.vecMean(data[0 .. rows * cols]);
                        }
                    }.call,
                    .export_name = "mathzig_matrix_mean",
                    .args = .{ .rows = "this.rows", .cols = "this.cols", .data = "this.data" },
                },
            },
            .properties = .{
                .rows = "u32",
                .cols = "u32",
            },
        },
        .Vector = .{
            .description = "A 1D floating point vector",
            .methods = .{
                .add = .{
                    .fn_ptr = matrix_kernels.vecAdd,
                    .export_name = "mathzig_vec_add",
                    .args = .{
                        .a = .{ .binding = "this.data", .len = "len" },
                        .b = .{ .binding = "other.data", .len = "len" },
                        .c = .{ .binding = "out.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .sub = .{
                    .fn_ptr = matrix_kernels.vecSub,
                    .export_name = "mathzig_vec_sub",
                    .args = .{
                        .a = .{ .binding = "this.data", .len = "len" },
                        .b = .{ .binding = "other.data", .len = "len" },
                        .c = .{ .binding = "out.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .dot = .{
                    .fn_ptr = matrix_kernels.vecDot,
                    .export_name = "mathzig_vec_dot",
                    .args = .{
                        .a = .{ .binding = "this.data", .len = "len" },
                        .b = .{ .binding = "other.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .norm = .{
                    .fn_ptr = matrix_kernels.vecNorm,
                    .export_name = "mathzig_vec_norm",
                    .args = .{
                        .a = .{ .binding = "this.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .scale = .{
                    .fn_ptr = matrix_kernels.vecScale,
                    .export_name = "mathzig_vec_scale",
                    .args = .{
                        .alpha = "f64",
                        .a = .{ .binding = "this.data", .len = "len" },
                        .b = .{ .binding = "out.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .scaleInplace = .{
                    .fn_ptr = matrix_kernels.vecScaleInplace,
                    .export_name = "mathzig_vec_scale_inplace",
                    .args = .{
                        .alpha = "f64",
                        .a = .{ .binding = "this.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .axpy = .{
                    .fn_ptr = matrix_kernels.vecAxpy,
                    .export_name = "mathzig_vec_axpy",
                    .args = .{
                        .alpha = "f64",
                        .x = .{ .binding = "this.data", .len = "len" },
                        .y = .{ .binding = "other.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .sum = .{
                    .fn_ptr = matrix_kernels.vecSum,
                    .export_name = "mathzig_vec_sum",
                    .args = .{
                        .a = .{ .binding = "this.data", .len = "len" },
                        .len = "this.len",
                    },
                },
                .mean = .{
                    .fn_ptr = matrix_kernels.vecMean,
                    .export_name = "mathzig_vec_mean",
                    .args = .{
                        .a = .{ .binding = "this.data", .len = "len" },
                        .len = "this.len",
                    },
                },
            },
            .properties = .{
                .len = "u32",
            },
        },
    },
};
