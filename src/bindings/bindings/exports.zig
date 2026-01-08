///! C ABI exports for MathZig - enables FFI and WASM usage
///!
///! These functions provide a C-compatible interface to MathZig,
///! suitable for use from TypeScript via Bun FFI or WebAssembly.

const std = @import("std");
const builtin = @import("builtin");
const mathzig = @import("mathzig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;


const MathZig = mathzig.MathZig;
const CompiledExpr = mathzig.CompiledExpr;
const Value = mathzig.Value;
const Series = mathzig.timeseries.Series;
const SampleMode = mathzig.timeseries.SampleMode;
const Matrix = mathzig.Matrix;
const Record = mathzig.Record;

// =============================================================================
// Evaluation State
// =============================================================================

threadlocal var last_value: Value = Value.initUndefined();
threadlocal var last_tag: u8 = @intFromEnum(mathzig.ValueTag.undefined);
threadlocal var last_ptr: ?*anyopaque = null;
threadlocal var last_number: f64 = 0;

// =============================================================================
// Context Management
// =============================================================================

/// Create a new MathZig context
export fn mathzig_create() callconv(.c) ?*MathZig {
    const allocator = if (is_wasm) std.heap.page_allocator else std.heap.c_allocator;
    return MathZig.init(allocator) catch null;
}

/// Destroy a MathZig context
export fn mathzig_destroy(ctx: ?*MathZig) callconv(.c) void {
    if (ctx) |c| {
        // Release last value to avoid leaks on destroy
        last_value.release();
        last_value = Value.initUndefined();
        c.deinit();
    }
}

// =============================================================================
// Expression Compilation
// =============================================================================

/// Compile an expression string
export fn mathzig_compile(ctx: ?*MathZig, expr: [*:0]const u8) callconv(.c) ?*CompiledExpr {
    const c = ctx orelse return null;
    c.clearError();
    const slice = std.mem.span(expr);
    return c.compile(slice) catch |err| {
        c.setError(@errorName(err));
        return null;
    };
}

/// Free a compiled expression
export fn mathzig_free_expr(ctx: ?*MathZig, expr: ?*CompiledExpr) callconv(.c) void {
    const c = ctx orelse return;
    if (expr) |e| {
        c.freeExpr(e);
    }
}

export fn mathzig_expr_bytecode_size(expr: ?*const CompiledExpr) callconv(.c) usize {
    if (expr) |e| return e.code.len * @sizeOf(mathzig.Instruction);
    return 0;
}

export fn mathzig_expr_num_instructions(expr: ?*const CompiledExpr) callconv(.c) usize {
    if (expr) |e| return e.code.len;
    return 0;
}

export fn mathzig_expr_num_variables(_: ?*const CompiledExpr) callconv(.c) usize {
    return 0; 
}

export fn mathzig_expr_num_constants(expr: ?*const CompiledExpr) callconv(.c) usize {
    if (expr) |e| return e.constants.len;
    return 0;
}

export fn mathzig_expr_stack_size(expr: ?*const CompiledExpr) callconv(.c) usize {
    if (expr) |e| return e.max_stack;
    return 0;
}

// =============================================================================
// Evaluation
// =============================================================================

/// Evaluate a compiled expression.
export fn mathzig_evaluate(ctx: ?*MathZig, expr: ?*const CompiledExpr) callconv(.c) void {
    const c = ctx orelse return;
    c.clearError();
    const e = expr orelse return;

    const result = c.evaluate(e) catch |err| {
        c.setError(@errorName(err));
        last_value.release();
        last_value = Value.initError(0);
        last_tag = @intFromEnum(last_value.tag);
        last_ptr = null;
        last_number = std.math.nan(f64);
        return;
    };
    
    // Release old, store new
    last_value.release();
    last_value = result;
    last_tag = @intFromEnum(result.tag);
    last_ptr = last_value.getPointer();
    last_number = last_value.toNumber() orelse 0.0;
}

/// Evaluate an expression string directly.
export fn mathzig_eval(ctx: ?*MathZig, expr: [*:0]const u8) callconv(.c) void {
    const c = ctx orelse return;
    c.clearError();
    const slice = std.mem.span(expr);

    const result = c.eval(slice) catch |err| {
        c.setError(@errorName(err));
        last_value.release();
        last_value = Value.initError(0);
        last_tag = @intFromEnum(last_value.tag);
        last_ptr = null;
        last_number = std.math.nan(f64);
        return;
    };
    
    last_value.release();
    last_value = result;
    last_tag = @intFromEnum(result.tag);
    last_ptr = last_value.getPointer();
    last_number = last_value.toNumber() orelse 0.0;
}

/// Get the numeric value of the last evaluation
export fn mathzig_get_last_number() callconv(.c) f64 {
    return last_number;
}

/// Get the tag of the last evaluation result
export fn mathzig_get_last_tag() callconv(.c) u8 {
    return last_tag;
}

/// Get the pointer of the last evaluation result
export fn mathzig_get_last_ptr() callconv(.c) ?*anyopaque {
    return last_ptr;
}

/// Format the last evaluation result into a buffer
/// Returns the number of bytes written
export fn mathzig_format_last_value(ctx: ?*MathZig, buffer: [*]u8, len: usize) callconv(.c) usize {
    const c = ctx orelse return 0;
    if (len == 0) return 0;
    
    var fbs = std.io.fixedBufferStream(buffer[0..len]);
    c.formatValue(last_value, fbs.writer()) catch |err| {
        if (err == error.NoSpaceLeft) {
            // Buffer full, just return what we wrote
            return fbs.pos;
        }
        return 0;
    };
    // Ensure null termination if there is space
    if (fbs.pos < len) {
        buffer[fbs.pos] = 0;
    } else if (len > 0) {
        buffer[len - 1] = 0;
    }
    return fbs.pos;
}

/// FAST PATH: Evaluate with zero overhead - numeric expressions only
export fn mathzig_evaluate_fast(ctx: *MathZig, expr: *const CompiledExpr) callconv(.c) f64 {
    return ctx.vm.executeNumbersOnlyUnchecked(expr);
}

// =============================================================================
// Value Management & RefCounting
// =============================================================================

/// Retain a reference to a value
export fn mathzig_retain(val_ptr: ?*anyopaque, tag: u8) callconv(.c) void {
    if (val_ptr == null) return;
    const vtag = @as(mathzig.ValueTag, @enumFromInt(tag));
    switch (vtag) {
        .matrix => _ = @as(*Matrix, @ptrCast(@alignCast(val_ptr.?))).retain(),
        .series => _ = @as(*Series, @ptrCast(@alignCast(val_ptr.?))).retain(),
        .record => _ = @as(*Record, @ptrCast(@alignCast(val_ptr.?))).retain(),
        else => {},
    }
}

/// Release a reference to a value
export fn mathzig_release(val_ptr: ?*anyopaque, tag: u8) callconv(.c) void {
    if (val_ptr == null) return;
    const vtag = @as(mathzig.ValueTag, @enumFromInt(tag));
    switch (vtag) {
        .matrix => @as(*Matrix, @ptrCast(@alignCast(val_ptr.?))).release(),
        .series => @as(*Series, @ptrCast(@alignCast(val_ptr.?))).release(),
        .record => @as(*Record, @ptrCast(@alignCast(val_ptr.?))).release(),
        else => {},
    }
}

/// Convert a reference-type value to a number
export fn mathzig_value_to_number(val_ptr: ?*anyopaque, tag: u8) callconv(.c) f64 {
    if (val_ptr == null) return std.math.nan(f64);
    const vtag = @as(mathzig.ValueTag, @enumFromInt(tag));
    const value = switch (vtag) {
        .matrix => Value{ .tag = .matrix, .data = .{ .matrix = @ptrCast(@alignCast(val_ptr.?)) } },
        .series => Value{ .tag = .series, .data = .{ .series = @ptrCast(@alignCast(val_ptr.?)) } },
        .record => Value{ .tag = .record, .data = .{ .record = @ptrCast(@alignCast(val_ptr.?)) } },
        .boolean => return if (@as(*bool, @ptrCast(@alignCast(val_ptr.?))).*) 1.0 else 0.0,
        .unit => Value{ .tag = .unit, .data = .{ .unit = @as(*mathzig.UnitValue, @ptrCast(@alignCast(val_ptr.?))).* } },
        .number => return @as(*f64, @ptrCast(@alignCast(val_ptr.?))).*,
        else => return std.math.nan(f64),
    };
    return value.toNumber() orelse std.math.nan(f64);
}

// =============================================================================
// Record Management
// =============================================================================

/// Get number of fields in a record
export fn mathzig_record_len(record: ?*Record) callconv(.c) usize {
    const r = record orelse return 0;
    return r.len();
}

/// Get field value from record
export fn mathzig_record_get_field(record: ?*Record, key: [*:0]const u8) callconv(.c) ?*anyopaque {
    const r = record orelse return null;
    const slice = std.mem.span(key);
    if (r.fields.getPtr(slice)) |val_ptr| {
        val_ptr.retain(); // Retain for TypeScript ownership
        // Set thread-local variables for TypeScript binding
        last_value = val_ptr.*;
        last_tag = @intFromEnum(val_ptr.tag);
        last_ptr = val_ptr.getPointer();
        last_number = last_value.toNumber() orelse 0.0;
        return last_ptr;
    }
    // Set null value for missing field
    last_value = Value.initNull();
    last_tag = @intFromEnum(last_value.tag);
    last_ptr = null;
    last_number = 0.0;
    return null;
}

// =============================================================================
// Matrix Management
// =============================================================================

export fn mathzig_matrix_rows(m: ?*const Matrix) callconv(.c) u32 {
    return if (m) |mat| mat.rows else 0;
}

export fn mathzig_matrix_cols(m: ?*const Matrix) callconv(.c) u32 {
    return if (m) |mat| mat.cols else 0;
}

export fn mathzig_matrix_stride(m: ?*const Matrix) callconv(.c) u32 {
    return if (m) |mat| mat.stride else 0;
}

export fn mathzig_matrix_get_data(m: ?*const Matrix) callconv(.c) ?[*]const f64 {
    return if (m) |mat| mat.data.ptr else null;
}

// =============================================================================
// Variable Management
// =============================================================================

/// Set a numeric variable by name
export fn mathzig_set_variable(ctx: ?*MathZig, name: [*:0]const u8, value: f64) callconv(.c) bool {
    const c = ctx orelse return false;
    const slice = std.mem.span(name);
    c.setNumber(slice, value);
    return true;
}

/// Add a variable and return its index for fast access
export fn mathzig_add_variable_indexed(ctx: ?*MathZig, name: [*:0]const u8, value: f64) callconv(.c) i32 {
    const c = ctx orelse return -1;
    const slice = std.mem.span(name);
    return @intCast(c.addVariableIndexed(slice, value));
}

/// Set a variable by index (fast path, no string lookup)
export fn mathzig_set_by_index(ctx: ?*MathZig, index: i32, value: f64) callconv(.c) void {
    const c = ctx orelse return;
    if (index < 0) return;
    c.setVariableByIndexF64(@intCast(index), value);
}

/// FAST PATH: Set variable with zero overhead
export fn mathzig_set_by_index_fast(ctx: *MathZig, index: u8, value: f64) callconv(.c) void {
    ctx.vm.variables_f64[index] = value;
}

/// Get direct pointer to f64 variable storage
export fn mathzig_get_variables_ptr(ctx: ?*MathZig) callconv(.c) ?[*]f64 {
    const c = ctx orelse return null;
    return c.vm.variables_f64.ptr;
}

// =============================================================================
// Time-Series Management
// =============================================================================

/// Create a new series from arrays
export fn mathzig_create_series(
    ctx: ?*MathZig,
    timestamps: [*]const f64,
    values: [*]const f64,
    count: usize,
    sample_mode: usize,
) callconv(.c) ?*Series {
    const c = ctx orelse return null;
    const n = count;
    const mode = @as(SampleMode, @enumFromInt(@as(u8, @truncate(sample_mode))));

    const series = Series.init(c.allocator, n, mode, .{}) catch return null;
    @memcpy(series.timestamps[0..n], timestamps[0..n]);
    @memcpy(series.values[0..n], values[0..n]);
    series.validate() catch {
        series.release();
        return null;
    };
    return series;
}

/// Free a series
export fn mathzig_free_series(series: ?*Series) callconv(.c) void {
    if (series) |s| {
        s.release();
    }
}

/// Bind a series to a variable name
export fn mathzig_set_series(ctx: ?*MathZig, name: [*:0]const u8, series: ?*Series) callconv(.c) bool {
    const c = ctx orelse return false;
    const s = series orelse return false;
    const slice = std.mem.span(name);
    c.setVariable(slice, Value.initSeries(s));
    return true;
}

/// Get series metadata
export fn mathzig_series_len(series: ?*const Series) callconv(.c) usize {
    const s = series orelse return 0;
    return s.len;
}

export fn mathzig_series_duration(series: ?*const Series) callconv(.c) f64 {
    const s = series orelse return 0;
    if (s.len < 2) return 0;
    return s.max_ts - s.min_ts;
}

/// Get direct pointers to series data
export fn mathzig_series_get_timestamps_ptr(series: ?*const Series) callconv(.c) ?[*]const f64 {
    const s = series orelse return null;
    return s.timestamps.ptr;
}

export fn mathzig_series_get_values_ptr(series: ?*const Series) callconv(.c) ?[*]const f64 {
    const s = series orelse return null;
    return s.values.ptr;
}

// =============================================================================
// Batch Evaluation
// =============================================================================

/// Evaluate expression for multiple input values
export fn mathzig_evaluate_batch(
    ctx: ?*MathZig,
    expr: ?*const CompiledExpr,
    var_index: i32,
    inputs: [*]const f64,
    outputs: [*]f64,
    count: i32,
) callconv(.c) i32 {
    const c = ctx orelse return 0;
    const e = expr orelse return 0;
    if (var_index < 0 or count <= 0) return 0;

    const n: usize = @intCast(count);
    const idx: u24 = @intCast(var_index);

    // Use fast-path for number-only expressions
    if (e.is_number_only) {
        for (0..n) |i| {
            c.setVariableByIndexF64(idx, inputs[i]);
            outputs[i] = c.evaluateF64(e);
        }
        return count;
    }

    // Fallback to standard path
    var successful: i32 = 0;
    for (0..n) |i| {
        c.setVariableByIndex(idx, Value.initNumber(inputs[i]));
        const result = c.evaluate(e) catch {
            outputs[i] = std.math.nan(f64);
            continue;
        };
        outputs[i] = result.toNumber() orelse std.math.nan(f64);
        result.release(); // Release reference held by result variable
        successful += 1;
    }

    return successful;
}

/// FAST PATH: Batch evaluation with zero overhead
export fn mathzig_batch_eval_fast(
    ctx: *MathZig,
    expr: *const CompiledExpr,
    var_index: u8,
    inputs: [*]const f64,
    outputs: [*]f64,
    count: u32,
) callconv(.c) void {
    const vars = ctx.vm.variables_f64;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        vars[var_index] = inputs[i];
        outputs[i] = ctx.vm.executeNumbersOnlyUnchecked(expr);
    }
}

/// SIMD BATCH EVALUATION
export fn mathzig_batch_eval_simd(
    ctx: *MathZig,
    expr: *const CompiledExpr,
    var_index: u8,
    inputs: [*]const f64,
    outputs: [*]f64,
    count: u32,
) callconv(.c) void {
    ctx.vm.executeBatchSIMD(expr, var_index, inputs, outputs, count);
}

/// SIMD BATCH COMPLEX EVALUATION
export fn mathzig_batch_eval_complex_simd(
    ctx: *MathZig,
    expr: *const CompiledExpr,
    var_index: u8,
    inputs_re: [*]const f64,
    inputs_im: [*]const f64,
    outputs_re: [*]f64,
    outputs_im: [*]f64,
    count: u32,
) callconv(.c) void {
    ctx.vm.executeBatchComplexSIMD(expr, var_index, inputs_re, inputs_im, outputs_re, outputs_im, count);
}

/// PARALLEL BATCH EVALUATION
export fn mathzig_batch_eval_parallel(
    ctx: *MathZig,
    expr: *const CompiledExpr,
    var_index: u8,
    inputs: [*]const f64,
    outputs: [*]f64,
    count: u32,
) callconv(.c) void {
    ctx.vm.executeBatchSIMD(expr, var_index, inputs, outputs, count);
}

// =============================================================================
// Memory Management (for WASM)
// =============================================================================

/// Allocate memory (for WASM)
export fn wasm_malloc(size: usize) ?[*]u8 {
    const slice = std.heap.page_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

/// Free memory (for WASM)
export fn wasm_free(ptr: ?[*]u8, size: usize) void {
    if (ptr == null) return;
    const p = ptr.?;
    const slice = p[0..size];
    std.heap.page_allocator.free(slice);
}

/// Allocate aligned memory
export fn mathzig_alloc_aligned(alignment: usize, size: usize) ?[*]u8 {
    if (size == 0) return null;
    const allocator = if (is_wasm) std.heap.page_allocator else std.heap.c_allocator;
    return switch (alignment) {
        1 => (allocator.alloc(u8, size) catch return null).ptr,
        2 => (allocator.alignedAlloc(u8, .@"2", size) catch return null).ptr,
        4 => (allocator.alignedAlloc(u8, .@"4", size) catch return null).ptr,
        8 => (allocator.alignedAlloc(u8, .@"8", size) catch return null).ptr,
        16 => (allocator.alignedAlloc(u8, .@"16", size) catch return null).ptr,
        32 => (allocator.alignedAlloc(u8, .@"32", size) catch return null).ptr,
        64 => (allocator.alignedAlloc(u8, .@"64", size) catch return null).ptr,
        else => (allocator.alloc(u8, size) catch return null).ptr,
    };
}

/// Free memory
export fn mathzig_free(ptr: ?[*]u8) void {
    if (ptr == null) return;
    if (!is_wasm) {
        std.c.free(ptr);
    }
}

// =============================================================================
// Utility Functions
// =============================================================================

export fn mathzig_get_error(ctx: ?*MathZig) [*:0]const u8 {
    const c = ctx orelse return "Invalid context";
    return c.getError();
}

export fn mathzig_version_number() f64 { return 0.1; }
export fn mathzig_get_memory_used(ctx: ?*MathZig) usize { return ctx.?.getMemoryUsed(); }
export fn mathzig_get_memory_reserved(ctx: ?*MathZig) usize { return ctx.?.getMemoryReserved(); }
export fn mathzig_get_memory_peak(ctx: ?*MathZig) usize { return ctx.?.getMemoryPeak(); }
export fn mathzig_reset_memory(ctx: ?*MathZig) void { ctx.?.resetMemory(); }

// =============================================================================
// Optimized Polynomial Compilation
// =============================================================================

export fn mathzig_compile_polynomial(
    ctx: ?*MathZig,
    var_index: i32,
    coefficients: [*]const f64,
    count: u32,
) ?*CompiledExpr {
    const c = ctx orelse return null;
    if (var_index < 0 or count == 0 or count > 255) return null;

    const expr = c.allocator.create(CompiledExpr) catch return null;
    const code = c.allocator.alloc(mathzig.Instruction, 2) catch {
        c.allocator.destroy(expr); return null;
    };
    const constants = c.allocator.alloc(Value, count) catch {
        c.allocator.free(code); c.allocator.destroy(expr); return null;
    };
    const constants_f64 = c.allocator.alloc(f64, count) catch {
        c.allocator.free(constants); c.allocator.free(code); c.allocator.destroy(expr); return null;
    };

    for (0..count) |i| {
        constants[i] = Value.initNumber(coefficients[i]);
        constants_f64[i] = coefficients[i];
    }

    const operand: u24 = @as(u24, @intCast(var_index)) | (@as(u24, @intCast(count)) << 16);
    code[0] = mathzig.Instruction.initWithOperand(mathzig.Opcode.eval_poly, operand);
    code[1] = mathzig.Instruction.init(mathzig.Opcode.halt);

    expr.* = .{
        .code = code,
        .constants = constants,
        .constants_f64 = constants_f64,
        .max_stack = 1,
        .is_number_only = true,
        .allocator = c.allocator,
    };
    return expr;
}

// =============================================================================
// BLAS Kernel Operations
// =============================================================================

const kernels = @import("mathzig").matrix_kernels;

export fn mathzig_vec_add(a: [*]const f64, b: [*]const f64, c: [*]f64, len: u32) callconv(.c) void { kernels.vecAdd(a[0..len], b[0..len], c[0..len]); }
export fn mathzig_vec_sub(a: [*]const f64, b: [*]const f64, c: [*]f64, len: u32) callconv(.c) void { kernels.vecSub(a[0..len], b[0..len], c[0..len]); }
export fn mathzig_vec_dot(a: [*]const f64, b: [*]const f64, len: u32) callconv(.c) f64 { return kernels.vecDot(a[0..len], b[0..len]); }
export fn mathzig_vec_norm(a: [*]const f64, len: u32) callconv(.c) f64 { return kernels.vecNorm(a[0..len]); }
export fn mathzig_vec_scale(alpha: f64, a: [*]const f64, b: [*]f64, len: u32) callconv(.c) void { kernels.vecScale(alpha, a[0..len], b[0..len]); }
export fn mathzig_vec_scale_inplace(alpha: f64, a: [*]f64, len: u32) callconv(.c) void { kernels.vecScaleInplace(alpha, a[0..len]); }
export fn mathzig_vec_axpy(alpha: f64, x: [*]const f64, y: [*]f64, len: u32) callconv(.c) void { kernels.vecAxpy(alpha, x[0..len], y[0..len]); }
export fn mathzig_gemv(rows: u32, cols: u32, alpha: f64, A: [*]const f64, stride_a: u32, x: [*]const f64, beta: f64, y: [*]f64) callconv(.c) void {
    kernels.gemv(rows, cols, alpha, A[0..@as(usize, rows) * stride_a], stride_a, x[0..cols], beta, y[0..rows]);
}
export fn mathzig_gemv_simple(rows: u32, cols: u32, A: [*]const f64, stride_a: u32, x: [*]const f64, y: [*]f64) callconv(.c) void {
    kernels.gemvSimple(rows, cols, A[0..@as(usize, rows) * stride_a], stride_a, x[0..cols], y[0..rows]);
}
export fn mathzig_gemm(rows_a: u32, cols_a: u32, cols_b: u32, A: [*]const f64, stride_a: u32, B: [*]const f64, stride_b: u32, C: [*]f64, stride_c: u32) callconv(.c) void {
    kernels.gemm(rows_a, cols_a, cols_b, A[0..@as(usize, rows_a) * stride_a], stride_a, B[0..@as(usize, cols_a) * stride_b], stride_b, C[0..@as(usize, rows_a) * stride_c], stride_c);
}
export fn mathzig_gemm_parallel(ctx: ?*MathZig, rows_a: u32, cols_a: u32, cols_b: u32, A: [*]const f64, stride_a: u32, B: [*]const f64, stride_b: u32, C: [*]f64, stride_c: u32) callconv(.c) void {
    if (comptime is_wasm) { mathzig_gemm(rows_a, cols_a, cols_b, A, stride_a, B, stride_b, C, stride_c); return; }
    kernels.gemmParallel(&ctx.?.thread_pool, rows_a, cols_a, cols_b, A[0..@as(usize, rows_a) * stride_a], stride_a, B[0..@as(usize, cols_a) * stride_b], stride_b, C[0..@as(usize, rows_a) * stride_c], stride_c);
}
export fn mathzig_matrix_inverse(ctx: ?*MathZig, n: u32, A: [*]f64, stride_a: u32) callconv(.c) bool {
    return kernels.matrixInverse(n, A[0..@as(usize, n) * stride_a], stride_a, ctx.?.allocator) catch false;
}
export fn mathzig_determinant(ctx: ?*MathZig, n: u32, A: [*]const f64, stride_a: u32) callconv(.c) f64 {
    return kernels.determinant(n, A[0..@as(usize, n) * stride_a], stride_a, ctx.?.allocator) catch std.math.nan(f64);
}
export fn mathzig_matrix_sum(A: [*]const f64, len: u32) callconv(.c) f64 { return kernels.vecSum(A[0..len]); }
export fn mathzig_matrix_mean(A: [*]const f64, len: u32) callconv(.c) f64 { return kernels.vecMean(A[0..len]); }