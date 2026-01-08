//! task-15: unit_runtime custom-section field is emit-accurate.
//! Modes: none | static | host_dynamic.
//! Negative: fully static-folded unit op must NOT be tagged host_dynamic.

const std = @import("std");
const mathzig = @import("mathzig");
const wasm = mathzig.wasm;

const ByteBuf = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    pub fn writeByte(self: *const ByteBuf, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }
    pub fn writeAll(self: *const ByteBuf, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

fn writeCompilerToOwned(compiler: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);
    const writer = ByteBuf{ .list = &buffer, .allocator = allocator };
    try compiler.writeTo(writer);
    return try buffer.toOwnedSlice(allocator);
}

test "unit_runtime none for pure scalar" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    const expr = try ctx.compile("1 + 2");
    defer ctx.freeExpr(expr);
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval" });
    try std.testing.expectEqual(wasm.compiler.UnitRuntimeMode.none, compiler.unit_runtime);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"unit_runtime\":\"none\"") != null);
}

test "unit_runtime static for AOT-folded unit conversion (not host_dynamic)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    _ = ctx.getOrCreateVariable("x");
    // Runtime magnitude + static unit targets: AOT folds conversion factor and
    // does not emit env.conv. (Fully-const conv(5*cm,in) may constant-fold in
    // the VM frontend to a bare number before AOT — that is unit_runtime none.)
    // Negative requirement: must NOT be host_dynamic.
    const expr = try ctx.compile("conv(x * cm, in)");
    defer ctx.freeExpr(expr);
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .num_params = 1 });
    try std.testing.expectEqual(wasm.compiler.UnitRuntimeMode.static, compiler.unit_runtime);
    try std.testing.expect(!compiler.emitted_dynamic_unit_op);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"unit_runtime\":\"static\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"unit_runtime\":\"host_dynamic\"") == null);
}

test "unit_runtime static for unit sum with result_unit annotation" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    const expr = try ctx.compile("(2 * m) + (50 * cm)");
    defer ctx.freeExpr(expr);
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval" });
    try std.testing.expectEqual(wasm.compiler.UnitRuntimeMode.static, compiler.unit_runtime);
    try std.testing.expect(compiler.result_unit != null);
    try std.testing.expectEqual(@as(i8, 1), compiler.result_unit.?.dims.l);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"unit_runtime\":\"static\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result_unit\"") != null);
}

test "unit_runtime host_dynamic when non-folded conv is emitted" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    _ = ctx.getOrCreateVariable("x");
    // Bare number source + static target unit: cannot fold (no source unit meta)
    // → emits env.conv → host_dynamic.
    const expr = try ctx.compile("conv(x, m)");
    defer ctx.freeExpr(expr);
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .num_params = 1 });
    try std.testing.expectEqual(wasm.compiler.UnitRuntimeMode.host_dynamic, compiler.unit_runtime);
    try std.testing.expect(compiler.emitted_dynamic_unit_op);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"unit_runtime\":\"host_dynamic\"") != null);
}

test "AOT rejects unit-bearing mat_create before allocation" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    const expr = try ctx.compile("[1m, 2m]");
    defer ctx.freeExpr(expr);
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compile(expr, .{ .function_name = "eval" });
    try std.testing.expectError(error.MatrixUnitElementUnsupported, err);
}

test "AOT rejects unit-bearing mat_create_3 (fused 3x1) before allocation" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    const expr = try ctx.compile("[1m; 2m; 3m]");
    defer ctx.freeExpr(expr);
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compile(expr, .{ .function_name = "eval" });
    try std.testing.expectError(error.MatrixUnitElementUnsupported, err);
}

test "AOT accepts homogeneous matrix times unit" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    const expr = try ctx.compile("conv([1, 2] * m, cm)");
    defer ctx.freeExpr(expr);
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval" });
    try std.testing.expectEqual(mathzig.ValueTag.matrix, compiler.result_tag);
}
