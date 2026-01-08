const std = @import("std");
const builtin = @import("builtin");
const api_def = @import("api_definition");
const mathzig = @import("mathzig");
const Allocator = std.mem.Allocator;
const Value = mathzig.Value;
const Matrix = mathzig.Matrix;
const CompiledExpr = mathzig.CompiledExpr;
const MathZig = mathzig.MathZig;
const Series = mathzig.timeseries.Series;

const is_wasm = builtin.cpu.arch.isWasm();
const is_freestanding = builtin.os.tag == .freestanding;

// State Container to handle ThreadLocal vs Global
const State = struct {
    var last_value_global: Value align(16) = Value.initUndefined();
    threadlocal var last_value_tls: Value align(16) = Value.initUndefined();
    var last_tag_global: u8 = @intFromEnum(mathzig.ValueTag.undefined);
    threadlocal var last_tag_tls: u8 = @intFromEnum(mathzig.ValueTag.undefined);
    var last_ptr_global: ?*anyopaque = null;
    threadlocal var last_ptr_tls: ?*anyopaque = null;
    var last_number_global: f64 = 0;
    threadlocal var last_number_tls: f64 = 0;

    fn getLastValue() *Value { return if (is_wasm or is_freestanding) &last_value_global else &last_value_tls; }
    fn getLastTag() *u8 { return if (is_wasm or is_freestanding) &last_tag_global else &last_tag_tls; }
    fn getLastPtr() *?*anyopaque { return if (is_wasm or is_freestanding) &last_ptr_global else &last_ptr_tls; }
    fn getLastNumber() *f64 { return if (is_wasm or is_freestanding) &last_number_global else &last_number_tls; }
};

// Allocator handling
fn getAllocator() Allocator {
    if (is_wasm or is_freestanding) {
        return std.heap.page_allocator;
    }
    return std.heap.c_allocator;
}

// Core Globals
export fn mathzig_create() callconv(.c) ?*anyopaque {
    return MathZig.init(getAllocator()) catch null;
}

export fn mathzig_destroy(ctx: ?*anyopaque) callconv(.c) void {
    if (ctx) |c| {
        const ptr: *MathZig = @ptrCast(@alignCast(c));
        ptr.deinit();
    }
}

export fn mathzig_get_last_number() callconv(.c) f64 { return State.getLastNumber().*; }
export fn mathzig_get_last_tag() callconv(.c) u8 { return State.getLastTag().*; }
export fn mathzig_get_last_ptr() callconv(.c) ?*anyopaque { return State.getLastPtr().*; }
export fn mathzig_format_last_value(ctx: ?*anyopaque, buffer: [*]u8, len: usize) callconv(.c) usize {
    const c = ctx orelse return 0;
    if (len == 0) return 0;
    var out = std.Io.Writer.fixed(buffer[0..len]);
    @as(*MathZig, @ptrCast(@alignCast(c))).formatValue(State.getLastValue().*, &out) catch |err| {
        if (err == error.WriteFailed) {
            return out.end;
        }
        return 0;
    };
    if (out.end < len) {
        buffer[out.end] = 0;
    } else if (len > 0) {
        buffer[len - 1] = 0;
    }
    return out.end;
}
export fn mathzig_version_number() callconv(.c) f64 { return 0.1; }

// WASM Memory Helpers
export fn wasm_malloc(size: usize) callconv(.c) ?*anyopaque {
    const total_size = size + @sizeOf(usize);
    const ptr = getAllocator().alloc(u8, total_size) catch return null;
    @as(*usize, @ptrCast(@alignCast(ptr.ptr))).* = total_size;
    return @ptrCast(ptr.ptr + @sizeOf(usize));
}

export fn wasm_free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const header_ptr = @as([*]u8, @ptrCast(p)) - @sizeOf(usize);
        const total_size = @as(*usize, @ptrCast(@alignCast(header_ptr))).*;
        getAllocator().free(header_ptr[0..total_size]);
    }
}

// MathZig
export fn mathzig_compile(self: ?*anyopaque, expr: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (self == null) return null;
    if (expr == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "compile").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "compile").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), std.mem.span(expr.?)) catch null;
    return @ptrCast(@constCast(result_raw));
}

export fn mathzig_free_expr(self: ?*anyopaque, expr: ?*anyopaque) callconv(.c) void {
    if (self == null) return;
    if (expr == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "freeExpr").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "freeExpr").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "freeExpr").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)));
}

export fn mathzig_eval(self: ?*anyopaque, expr: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (self == null) return @ptrCast(Value.initError(1).getPointer());
    if (expr == null) return @ptrCast(Value.initError(1).getPointer());
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "eval").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "eval").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), std.mem.span(expr.?)) catch Value.initError(0);
    State.getLastValue().release();
    State.getLastValue().* = result_raw;
    State.getLastTag().* = @intFromEnum(State.getLastValue().tag);
    State.getLastPtr().* = State.getLastValue().getPointer();
    State.getLastNumber().* = State.getLastValue().toNumber() orelse 0.0;
    return @ptrCast(State.getLastPtr().*);
}

export fn mathzig_set_variable(self: ?*anyopaque, name: ?[*:0]const u8, val: f64) callconv(.c) void {
    if (self == null) return;
    if (name == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setVariable").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setVariable").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), std.mem.span(name.?), val);
}

export fn mathzig_add_variable_indexed(self: ?*anyopaque, name: ?[*:0]const u8, initial_val: f64) callconv(.c) u32 {
    if (self == null) return 0;
    if (name == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "addVariableIndexed").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "addVariableIndexed").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), std.mem.span(name.?), initial_val);
    return result_raw;
}

export fn mathzig_set_by_index(self: ?*anyopaque, index: i32, val: f64) callconv(.c) void {
    if (self == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setByIndex").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setByIndex").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), @intCast(index), val);
}

export fn mathzig_set_by_index_fast(self: ?*anyopaque, index: i32, val: f64) callconv(.c) void {
    if (self == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setByIndexFast").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setByIndexFast").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), @intCast(index), val);
}

export fn mathzig_get_variables_ptr(self: ?*anyopaque) callconv(.c) ?[*]f64 {
    if (self == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getVariablesPtr").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getVariablesPtr").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_to_latex(self: ?*anyopaque, expr: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (self == null) return null;
    if (expr == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "toLaTeX").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "toLaTeX").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), @alignCast(expr.?));
    return result_raw;
}

export fn mathzig_get_error(self: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    if (self == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getError").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getError").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_get_memory_used(self: ?*anyopaque) callconv(.c) usize {
    if (self == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getMemoryUsed").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getMemoryUsed").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_get_memory_reserved(self: ?*anyopaque) callconv(.c) usize {
    if (self == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getMemoryReserved").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getMemoryReserved").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_get_memory_peak(self: ?*anyopaque) callconv(.c) usize {
    if (self == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getMemoryPeak").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getMemoryPeak").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_reset_memory(self: ?*anyopaque) callconv(.c) void {
    if (self == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "resetMemory").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "resetMemory").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
}

export fn mathzig_version(self: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    if (self == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "version").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "version").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_get_functions(self: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    if (self == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getFunctions").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getFunctions").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_create_series(ctx: ?*anyopaque, timestamps: ?[*]const f64, values: ?[*]const f64, count: usize, sample_mode: usize) callconv(.c) ?*anyopaque {
    if (ctx == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "createSeries").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "createSeries").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), timestamps, values, @intCast(count), @intCast(sample_mode));
    return @ptrCast(@constCast(result_raw));
}

export fn mathzig_compile_polynomial(ctx: ?*anyopaque, var_index: i32, coefficients: ?[*]const f64, count: u32) callconv(.c) ?*anyopaque {
    if (ctx == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "compilePolynomial").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "compilePolynomial").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), @intCast(var_index), coefficients, @intCast(count));
    return @ptrCast(@constCast(result_raw));
}

export fn mathzig_set_series(ctx: ?*anyopaque, name: ?[*:0]const u8, series: ?*anyopaque) callconv(.c) bool {
    if (ctx == null) return false;
    if (name == null) return false;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setSeries").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setSeries").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), std.mem.span(name.?), series);
    return result_raw;
}

export fn mathzig_set_debug(ctx: ?*anyopaque, debug: bool) callconv(.c) void {
    if (ctx == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setDebug").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "setDebug").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), debug);
}

export fn mathzig_write_csv(ctx: ?*anyopaque, var_name: ?[*:0]const u8, path: ?[*:0]const u8) callconv(.c) bool {
    if (ctx == null) return false;
    if (var_name == null) return false;
    if (path == null) return false;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "writeCsv").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "writeCsv").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), std.mem.span(var_name.?), std.mem.span(path.?));
    return result_raw;
}

export fn mathzig_get_last_error_offset(ctx: ?*anyopaque) callconv(.c) u32 {
    if (ctx == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getLastErrorOffset").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "MathZig").methods, "getLastErrorOffset").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)));
    return result_raw;
}

export fn mathzig_record_new(ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "recordNew").fn_ptr(ctx);
    return @ptrCast(@constCast(result_raw));
}

export fn mathzig_record_set_wire(ctx: ?*anyopaque, rec: ?*anyopaque, key: ?[*:0]const u8, wire: f64, kind: u8) callconv(.c) bool {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "recordSetWire").fn_ptr(ctx, rec, key, wire, @intCast(kind));
    return result_raw;
}

export fn mathzig_call_builtin(ctx: ?*anyopaque, builtin_id: i32, argc: i32, args_ptr: ?[*]const f64, kinds_ptr: ?[*]const u8, pred_ptr: ?[*]const u8) callconv(.c) f64 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "MathZig").methods, "callBuiltinWire").fn_ptr(ctx, @intCast(builtin_id), @intCast(argc), args_ptr, kinds_ptr, pred_ptr);
    return result_raw;
}

// CompiledExpr
export fn mathzig_evaluate(ctx: ?*anyopaque, expr: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (ctx == null) return @ptrCast(Value.initError(1).getPointer());
    if (expr == null) return @ptrCast(Value.initError(1).getPointer());
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluate").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluate").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluate").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?))) catch Value.initError(0);
    State.getLastValue().release();
    State.getLastValue().* = result_raw;
    State.getLastTag().* = @intFromEnum(State.getLastValue().tag);
    State.getLastPtr().* = State.getLastValue().getPointer();
    State.getLastNumber().* = State.getLastValue().toNumber() orelse 0.0;
    return @ptrCast(State.getLastPtr().*);
}

export fn mathzig_evaluate_fast(ctx: ?*anyopaque, expr: ?*anyopaque) callconv(.c) f64 {
    if (ctx == null) return std.math.nan(f64);
    if (expr == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateFast").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateFast").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateFast").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)));
    return result_raw;
}

export fn mathzig_expr_bytecode_size(expr: ?*anyopaque) callconv(.c) usize {
    if (expr == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getBytecodeSize").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getBytecodeSize").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)));
    return result_raw;
}

export fn mathzig_expr_num_instructions(expr: ?*anyopaque) callconv(.c) usize {
    if (expr == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getNumInstructions").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getNumInstructions").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)));
    return result_raw;
}

export fn mathzig_expr_num_variables(expr: ?*anyopaque) callconv(.c) usize {
    if (expr == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getNumVariables").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getNumVariables").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)));
    return result_raw;
}

export fn mathzig_expr_num_constants(expr: ?*anyopaque) callconv(.c) usize {
    if (expr == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getNumConstants").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getNumConstants").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)));
    return result_raw;
}

export fn mathzig_expr_stack_size(expr: ?*anyopaque) callconv(.c) usize {
    if (expr == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getStackSize").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "getStackSize").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)));
    return result_raw;
}

export fn mathzig_evaluate_batch(ctx: ?*anyopaque, expr: ?*anyopaque, var_index: i32, inputs: ?[*]const f64, outputs: ?[*]f64, count: i32) callconv(.c) i32 {
    if (ctx == null) return 0;
    if (expr == null) return 0;
    if (inputs == null) return 0;
    if (outputs == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatch").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatch").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatch").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)), @intCast(var_index), @alignCast(inputs.?), @alignCast(outputs.?), @intCast(count));
    return result_raw;
}

export fn mathzig_batch_eval_simd(ctx: ?*anyopaque, expr: ?*anyopaque, var_index: u8, inputs: ?[*]const f64, outputs: ?[*]f64, count: u32) callconv(.c) void {
    if (ctx == null) return;
    if (expr == null) return;
    if (inputs == null) return;
    if (outputs == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchSIMD").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchSIMD").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchSIMD").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)), @intCast(var_index), @alignCast(inputs.?), @alignCast(outputs.?), @intCast(count));
}

export fn mathzig_batch_eval_parallel(ctx: ?*anyopaque, expr: ?*anyopaque, var_index: u8, inputs: ?[*]const f64, outputs: ?[*]f64, count: u32) callconv(.c) void {
    if (ctx == null) return;
    if (expr == null) return;
    if (inputs == null) return;
    if (outputs == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchParallel").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchParallel").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchParallel").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)), @intCast(var_index), @alignCast(inputs.?), @alignCast(outputs.?), @intCast(count));
}

export fn mathzig_batch_eval_complex_simd(ctx: ?*anyopaque, expr: ?*anyopaque, var_index: u8, re_in: ?[*]const f64, im_in: ?[*]const f64, re_out: ?[*]f64, im_out: ?[*]f64, count: u32) callconv(.c) void {
    if (ctx == null) return;
    if (expr == null) return;
    if (re_in == null) return;
    if (im_in == null) return;
    if (re_out == null) return;
    if (im_out == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchComplexSIMD").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchComplexSIMD").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "CompiledExpr").methods, "evaluateBatchComplexSIMD").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(expr.?)), @intCast(var_index), @alignCast(re_in.?), @alignCast(im_in.?), @alignCast(re_out.?), @alignCast(im_out.?), @intCast(count));
}

// Value
export fn mathzig_retain(ptr: ?*anyopaque, tag: u8) callconv(.c) void {
    _ = @field(@field(api_def.ExportConfig.classes, "Value").methods, "retain").fn_ptr(ptr, @intCast(tag));
}

export fn mathzig_release(ptr: ?*anyopaque, tag: u8) callconv(.c) void {
    _ = @field(@field(api_def.ExportConfig.classes, "Value").methods, "release").fn_ptr(ptr, @intCast(tag));
}

export fn mathzig_value_to_number(ptr: ?*anyopaque, tag: u8) callconv(.c) f64 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Value").methods, "toNumber").fn_ptr(ptr, @intCast(tag));
    return result_raw;
}

export fn mathzig_value_real(ptr: ?*anyopaque) callconv(.c) f64 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Value").methods, "real").fn_ptr(ptr);
    return result_raw;
}

export fn mathzig_value_imag(ptr: ?*anyopaque) callconv(.c) f64 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Value").methods, "imag").fn_ptr(ptr);
    return result_raw;
}

// Record
export fn mathzig_record_len(self: ?*anyopaque) callconv(.c) usize {
    if (self == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Record").methods, "len").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Record").methods, "len").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_record_get_field(self: ?*anyopaque, key: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (self == null) return @ptrCast(Value.initError(1).getPointer());
    if (key == null) return @ptrCast(Value.initError(1).getPointer());
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Record").methods, "getField").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Record").methods, "getField").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)), @alignCast(key.?));
    State.getLastValue().release();
    State.getLastValue().* = result_raw;
    State.getLastTag().* = @intFromEnum(State.getLastValue().tag);
    State.getLastPtr().* = State.getLastValue().getPointer();
    State.getLastNumber().* = State.getLastValue().toNumber() orelse 0.0;
    return @ptrCast(State.getLastPtr().*);
}

export fn mathzig_record_key_at(self: ?*anyopaque, index: u32) callconv(.c) ?[*:0]const u8 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Record").methods, "keyAt").fn_ptr(self, @intCast(index));
    return result_raw;
}

export fn mathzig_record_value_wire_at(self: ?*anyopaque, index: u32) callconv(.c) f64 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Record").methods, "valueWireAt").fn_ptr(self, @intCast(index));
    return result_raw;
}

export fn mathzig_record_value_kind_at(self: ?*anyopaque, index: u32) callconv(.c) u8 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Record").methods, "valueKindAt").fn_ptr(self, @intCast(index));
    return result_raw;
}

// Series
export fn mathzig_series_len(self: ?*anyopaque) callconv(.c) usize {
    if (self == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Series").methods, "len").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Series").methods, "len").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_series_duration(self: ?*anyopaque) callconv(.c) f64 {
    if (self == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Series").methods, "duration").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Series").methods, "duration").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_series_get_timestamps_ptr(self: ?*anyopaque) callconv(.c) ?[*]const f64 {
    if (self == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Series").methods, "getTimestampsPtr").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Series").methods, "getTimestampsPtr").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_series_get_values_ptr(self: ?*anyopaque) callconv(.c) ?[*]const f64 {
    if (self == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Series").methods, "getValuesPtr").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Series").methods, "getValuesPtr").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
    return result_raw;
}

export fn mathzig_free_series(self: ?*anyopaque) callconv(.c) void {
    if (self == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Series").methods, "free").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Series").methods, "free").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(self.?)));
}

// Globals
export fn mathzig_alloc_aligned(alignment: usize, size: usize) callconv(.c) ?[*]u8 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Globals").methods, "allocAligned").fn_ptr(@intCast(alignment), @intCast(size));
    return result_raw;
}

export fn mathzig_free(ptr: ?[*]u8) callconv(.c) void {
    _ = @field(@field(api_def.ExportConfig.classes, "Globals").methods, "free").fn_ptr(ptr);
}

export fn mathzig_last_wire_kind() callconv(.c) u8 {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Globals").methods, "lastWireKind").fn_ptr();
    return result_raw;
}

export fn mathzig_builtin_id(name: ?[*:0]const u8) callconv(.c) i32 {
    if (name == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Globals").methods, "builtinId").fn_ptr(@alignCast(name.?));
    return result_raw;
}

export fn mathzig_matrix_from_data(rows: u32, cols: u32, data: ?[*]const f64) callconv(.c) ?*anyopaque {
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Globals").methods, "matrixFromData").fn_ptr(@intCast(rows), @intCast(cols), data);
    return @ptrCast(@constCast(result_raw));
}

// Matrix
export fn mathzig_matrix_rows(m: ?*anyopaque) callconv(.c) u32 {
    if (m == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "rows").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Matrix").methods, "rows").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(m.?)));
    return result_raw;
}

export fn mathzig_matrix_cols(m: ?*anyopaque) callconv(.c) u32 {
    if (m == null) return 0;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "cols").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Matrix").methods, "cols").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(m.?)));
    return result_raw;
}

export fn mathzig_matrix_get_data(m: ?*anyopaque) callconv(.c) ?[*]const f64 {
    if (m == null) return null;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "getData").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Matrix").methods, "getData").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(m.?)));
    return result_raw;
}

export fn mathzig_gemm(rows_a: u32, cols_a: u32, cols_b: u32, A: ?[*]const f64, stride_a: u32, B: ?[*]const f64, stride_b: u32, C: ?[*]f64, stride_c: u32) callconv(.c) void {
    if (A == null) return;
    if (B == null) return;
    if (C == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "multiply").fn_ptr(@intCast(rows_a), @intCast(cols_a), @intCast(cols_b), @alignCast(A.?[0..rows_a * stride_a]), @intCast(stride_a), @alignCast(B.?[0..cols_a * stride_b]), @intCast(stride_b), @alignCast(C.?[0..rows_a * stride_c]), @intCast(stride_c));
}

export fn mathzig_gemm_parallel(ctx: ?*anyopaque, rows_a: u32, cols_a: u32, cols_b: u32, A: ?[*]const f64, stride_a: u32, B: ?[*]const f64, stride_b: u32, C: ?[*]f64, stride_c: u32) callconv(.c) void {
    if (ctx == null) return;
    if (A == null) return;
    if (B == null) return;
    if (C == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "multiplyParallel").fn_ptr(if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, "Matrix").methods, "multiplyParallel").fn_ptr)).@"fn".params[0].type.? == void) {} else @ptrCast(@alignCast(ctx.?)), @intCast(rows_a), @intCast(cols_a), @intCast(cols_b), @alignCast(A.?[0..rows_a * stride_a]), @intCast(stride_a), @alignCast(B.?[0..cols_a * stride_b]), @intCast(stride_b), @alignCast(C.?[0..rows_a * stride_c]), @intCast(stride_c));
}

export fn mathzig_matrix_inverse(n: u32, A: ?[*]f64, stride_a: u32, allocator: ?*anyopaque) callconv(.c) bool {
    _ = allocator;
    if (A == null) return false;
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "inverse").fn_ptr(@intCast(n), @alignCast(A.?[0..n * stride_a]), @intCast(stride_a), getAllocator()) catch false;
    return result_raw;
}

export fn mathzig_determinant(n: u32, A: ?[*]const f64, stride_a: u32, allocator: ?*anyopaque) callconv(.c) f64 {
    _ = allocator;
    if (A == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "determinant").fn_ptr(@intCast(n), @alignCast(A.?[0..n * stride_a]), @intCast(stride_a), getAllocator()) catch std.math.nan(f64);
    return result_raw;
}

export fn mathzig_gemv(rows: u32, cols: u32, alpha: f64, A: ?[*]const f64, stride_a: u32, x: ?[*]const f64, beta: f64, y: ?[*]f64) callconv(.c) void {
    if (A == null) return;
    if (x == null) return;
    if (y == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "gemv").fn_ptr(@intCast(rows), @intCast(cols), alpha, @alignCast(A.?[0..rows * stride_a]), @intCast(stride_a), @alignCast(x.?[0..cols]), beta, @alignCast(y.?[0..rows]));
}

export fn mathzig_gemv_simple(rows: u32, cols: u32, A: ?[*]const f64, stride_a: u32, x: ?[*]const f64, y: ?[*]f64) callconv(.c) void {
    if (A == null) return;
    if (x == null) return;
    if (y == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "gemvSimple").fn_ptr(@intCast(rows), @intCast(cols), @alignCast(A.?[0..rows * stride_a]), @intCast(stride_a), @alignCast(x.?[0..cols]), @alignCast(y.?[0..rows]));
}

export fn mathzig_matrix_sum(rows: u32, cols: u32, data: ?[*]const f64) callconv(.c) f64 {
    if (data == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "sum").fn_ptr(@intCast(rows), @intCast(cols), @alignCast(data.?));
    return result_raw;
}

export fn mathzig_matrix_mean(rows: u32, cols: u32, data: ?[*]const f64) callconv(.c) f64 {
    if (data == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Matrix").methods, "mean").fn_ptr(@intCast(rows), @intCast(cols), @alignCast(data.?));
    return result_raw;
}

// Vector
export fn mathzig_vec_add(a: ?[*]const f64, b: ?[*]const f64, c: ?[*]f64, len: u32) callconv(.c) void {
    if (a == null) return;
    if (b == null) return;
    if (c == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "add").fn_ptr(@alignCast(a.?[0..len]), @alignCast(b.?[0..len]), @alignCast(c.?[0..len]));
}

export fn mathzig_vec_sub(a: ?[*]const f64, b: ?[*]const f64, c: ?[*]f64, len: u32) callconv(.c) void {
    if (a == null) return;
    if (b == null) return;
    if (c == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "sub").fn_ptr(@alignCast(a.?[0..len]), @alignCast(b.?[0..len]), @alignCast(c.?[0..len]));
}

export fn mathzig_vec_dot(a: ?[*]const f64, b: ?[*]const f64, len: u32) callconv(.c) f64 {
    if (a == null) return std.math.nan(f64);
    if (b == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "dot").fn_ptr(@alignCast(a.?[0..len]), @alignCast(b.?[0..len]));
    return result_raw;
}

export fn mathzig_vec_norm(a: ?[*]const f64, len: u32) callconv(.c) f64 {
    if (a == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "norm").fn_ptr(@alignCast(a.?[0..len]));
    return result_raw;
}

export fn mathzig_vec_scale(alpha: f64, a: ?[*]const f64, b: ?[*]f64, len: u32) callconv(.c) void {
    if (a == null) return;
    if (b == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "scale").fn_ptr(alpha, @alignCast(a.?[0..len]), @alignCast(b.?[0..len]));
}

export fn mathzig_vec_scale_inplace(alpha: f64, a: ?[*]f64, len: u32) callconv(.c) void {
    if (a == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "scaleInplace").fn_ptr(alpha, @alignCast(a.?[0..len]));
}

export fn mathzig_vec_axpy(alpha: f64, x: ?[*]const f64, y: ?[*]f64, len: u32) callconv(.c) void {
    if (x == null) return;
    if (y == null) return;
    _ = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "axpy").fn_ptr(alpha, @alignCast(x.?[0..len]), @alignCast(y.?[0..len]));
}

export fn mathzig_vec_sum(a: ?[*]const f64, len: u32) callconv(.c) f64 {
    if (a == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "sum").fn_ptr(@alignCast(a.?[0..len]));
    return result_raw;
}

export fn mathzig_vec_mean(a: ?[*]const f64, len: u32) callconv(.c) f64 {
    if (a == null) return std.math.nan(f64);
    const result_raw = @field(@field(api_def.ExportConfig.classes, "Vector").methods, "mean").fn_ptr(@alignCast(a.?[0..len]));
    return result_raw;
}

