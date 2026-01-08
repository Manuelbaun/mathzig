const std = @import("std");
const mathzig = @import("mathzig");
const wasm = mathzig.wasm;

/// Zig 0.16: ArrayListUnmanaged has no .writer(); mirror wasm list_writer.
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

test "Compile simple expression to WASM" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.getOrCreateVariable("a");
    _ = ctx.getOrCreateVariable("b");

    const expr = try ctx.compile("a + b * 2.5");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();

    try compiler.compile(expr, .{ .function_name = "calc" });

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
    // WASM magic
    try std.testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x61), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x73), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x6D), bytes[3]);
}

test "Compile expression with builtin to WASM" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.getOrCreateVariable("a");

    const expr = try ctx.compile("sin(a) + 1.0");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();

    try compiler.compile(expr, .{ .function_name = "calc_sin" });

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

test "get_index with >2 keys is a hard compile error (not silent NaN)" {
    const allocator = std.testing.allocator;
    const Instruction = mathzig.Instruction;
    const CompiledExpr = mathzig.CompiledExpr;

    const constants = [_]mathzig.Value{
        mathzig.Value.initNumber(1.0),
        mathzig.Value.initNumber(2.0),
        mathzig.Value.initNumber(3.0),
        mathzig.Value.initNumber(4.0),
        mathzig.Value.initNumber(0.0),
        mathzig.Value.initNumber(0.0),
        mathzig.Value.initNumber(0.0),
    };
    // 2x2 matrix then get_index with 3 keys — must fail at compile time.
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

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(error.UnsupportedOpcode, compiler.compile(&expr, .{ .function_name = "bad_index" }));
}

test "standalone: scalar Tier-1 compiles with empty import surface" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("sin(1) + cos(1) + exp(1) + log(2) + tan(0.5) + atan(1) + (2^3) + (5 % 2)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .standalone = true });

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
    // No env imports: import section name "env" should be absent for pure scalar.
    // (custom section may mention tiers, but the import section itself is empty.)
    try std.testing.expect(compiler.module.import_count == 0);
}

test "standalone: unresolved builtin hard-errors with named builtin + tier" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // bollinger remains Tier 4 advanced / not implemented in standalone.
    const expr = try ctx.compile("bollinger(series([1,2,3], [1,2,3]), 2)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compile(expr, .{ .function_name = "eval", .standalone = true });
    try std.testing.expectError(error.StandaloneUnsupportedImport, err);
    try std.testing.expect(compiler.standalone_error_msg != null);
    const msg = compiler.standalone_error_msg.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "bollinger") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "tier=") != null);
}

test "standalone: matrix Tier-2 transpose/det compile without env imports" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("det([1, 2; 3, 4]) + transpose([1, 2; 3, 4])[0, 1]");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .standalone = true });
    try std.testing.expect(compiler.module.import_count == 0);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

test "RequiredRuntimeSet: firstUnresolved names tier" {
    const abi = wasm.abi;
    // ODE is Tier 3 implemented — no unresolved.
    var set_ok = abi.RequiredRuntimeSet{};
    set_ok.addBuiltin(.ode_solve, 4, false);
    try std.testing.expect(set_ok.firstUnresolvedStandalone() == null);

    // Advanced series indicator still unresolved.
    var set = abi.RequiredRuntimeSet{};
    set.addBuiltin(.bollinger, 2, false);
    const u = set.firstUnresolvedStandalone().?;
    try std.testing.expectEqual(mathzig.BuiltinFn.bollinger, u.builtin);
    try std.testing.expectEqual(abi.StandaloneTier.series, u.tier);

    var buf: [160]u8 = undefined;
    const msg = set.formatUnresolved(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "bollinger") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "series") != null);
}

test "ABI: every builtin has a signature; manifest custom section is emitted" {
    // Totality: the switch in abi.signature has no else branch, so this
    // compiles only when every BuiltinFn member is categorized.
    const abi = wasm.abi;
    try std.testing.expectEqual(abi.WireKind.number, abi.signature(.det).ret);
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, abi.signature(.transpose).ret);
    try std.testing.expect(abi.signature(.mean).where_capable);
    try std.testing.expect(abi.signature(.ode_solve).args.len == 4);

    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    _ = ctx.getOrCreateVariable("x");

    const expr = try ctx.compile("sin(x) + atan(x) * 2");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .num_params = 1 });

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);

    // The mathzig.abi custom section (JSON manifest) must be present and
    // carry the statically-inferred result tag plus the atan env import
    // (sin is an internally generated body, not an import).
    try std.testing.expect(std.mem.indexOf(u8, bytes, abi.CUSTOM_SECTION_NAME) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result_tag\":\"number\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"name\":\"atan\"") != null);
}

test "units AOT: static conv fold compiles and emits series_repr" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // Static unit conversion must compile (fold conversion factor; no runtime unit strip).
    const expr = try ctx.compile("conv(5 * cm, in)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval" });

    try std.testing.expectEqual(mathzig.ValueTag.number, compiler.result_tag);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mathzig.abi") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"series_repr\":\"host_handle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result_tag\":\"number\"") != null);
}

test "units AOT: unit sum result_unit annotation round-trip in custom section" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("(2 * m) + (50 * cm)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval" });

    // Result is a length unit with SI magnitude; annotation carries dimensions.
    try std.testing.expectEqual(mathzig.ValueTag.unit, compiler.result_tag);
    try std.testing.expect(compiler.result_unit != null);
    try std.testing.expectEqual(@as(i8, 1), compiler.result_unit.?.dims.l);
    try std.testing.expectEqual(@as(i8, 0), compiler.result_unit.?.dims.m);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result_tag\":\"unit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result_unit\"") != null);
    // length exponent present in dims
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"l\":1") != null);
}

test "units AOT: dimension mismatch is a compile error (no silent strip)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // Adding meters to kilograms must fail at AOT compile time.
    const expr = try ctx.compile("(1 * m) + (1 * kg)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compile(expr, .{ .function_name = "eval" });
    try std.testing.expectError(error.UnitDimensionMismatch, err);
}

test "units AOT: conv dimension mismatch is a compile error" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("conv(5 * cm, kg)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compile(expr, .{ .function_name = "eval" });
    try std.testing.expectError(error.UnitDimensionMismatch, err);
}

test "ABI series layout: single definition offsets" {
    const abi = wasm.abi;
    try std.testing.expectEqual(@as(u32, 8), abi.SeriesLayout.header_bytes);
    try std.testing.expectEqual(@as(u32, 8 + 16), abi.SeriesLayout.totalBytes(1));
    try std.testing.expectEqual(@as(u32, 8 + 3 * 8), abi.SeriesLayout.valuesOffset(3));
    try std.testing.expectEqual(@as(u32, 8 + 3 * 16), abi.SeriesLayout.totalBytes(3));
    try std.testing.expectEqualStrings("host_handle", abi.SeriesRepresentation.host_handle.jsonName());
    try std.testing.expectEqualStrings("linear_memory", abi.SeriesRepresentation.linear_memory.jsonName());
}

test "standalone Tier-3: scalar ODE compiles without env imports" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("simple_deriv(t, y) = -0.5 * y; ode_solve_euler(\"simple_deriv\", [1], [0, 2], 0.1)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .standalone = true });
    try std.testing.expect(compiler.module.import_count == 0);
    try std.testing.expect(wasm.abi.standaloneImplemented(.ode_solve_euler));

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

test "standalone Tier-3: multi-dim ODE RK4 compiles without env imports" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("simple3d(t, y) = [y[1]; y[2]; y[0]]; ode_solve(\"simple3d\", [1; 2; 3], [0, 1], 0.1)");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .standalone = true });
    try std.testing.expect(compiler.module.import_count == 0);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

test "standalone Tier-4: series core compiles with linear_memory series_repr" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("mean(series([1, 2, 3], [10, 20, 30])) + last(cumsum(series([0, 1], [1, 2])))");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .standalone = true });
    try std.testing.expect(compiler.module.import_count == 0);
    try std.testing.expect(compiler.series_repr == wasm.abi.SeriesRepresentation.linear_memory);

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"series_repr\":\"linear_memory\"") != null);
}


