const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;

test "latex generator - basic arithmetic" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const latex = try ctx.toLaTeX("1 + 2 * 3 / 4", allocator);
    defer allocator.free(latex);
    // AST groups (2*3)/4
    try std.testing.expectEqualStrings("1 + \\frac{2 \\cdot 3}{4}", latex);
}

test "latex generator - power and root" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const latex1 = try ctx.toLaTeX("x^2", allocator);
    defer allocator.free(latex1);
    try std.testing.expectEqualStrings("x^{2}", latex1);

    const latex2 = try ctx.toLaTeX("sqrt(x)", allocator);
    defer allocator.free(latex2);
    try std.testing.expectEqualStrings("\\sqrt{x}", latex2);
}

test "latex generator - matrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const latex = try ctx.toLaTeX("[1, 2; 3, 4]", allocator);
    defer allocator.free(latex);
    try std.testing.expectEqualStrings("\\begin{bmatrix} 1 & 2 \\\\ 3 & 4 \\end{bmatrix}", latex);
}

test "latex generator - complex and units" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const latex1 = try ctx.toLaTeX("1 + 2i", allocator);
    defer allocator.free(latex1);
    // "1 + 2i" is parsed as 1 + (2 * complex(0,1)); complex atom is now "i"
    try std.testing.expectEqualStrings("1 + 2 \\cdot i", latex1);

    const latex2 = try ctx.toLaTeX("10 [m/s]", allocator);
    defer allocator.free(latex2);
    try std.testing.expectEqualStrings("10 \\cdot \\text{unit}", latex2);
}

test "latex generator - function_def and indexing" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const latex1 = try ctx.toLaTeX("f(x) = x^2 + 1", allocator);
    defer allocator.free(latex1);
    try std.testing.expectEqualStrings("\\text{f}\\left(x\\right) = x^{2} + 1", latex1);

    const latex2 = try ctx.toLaTeX("density_v(r) = 1.2 * exp(r)", allocator);
    defer allocator.free(latex2);
    // Underscores inside \text must be escaped for KaTeX
    try std.testing.expectEqualStrings("\\text{density\\_v}\\left(r\\right) = 1.2 \\cdot \\exp\\left(r\\right)", latex2);

    const latex3 = try ctx.toLaTeX("y[1, 0]", allocator);
    defer allocator.free(latex3);
    try std.testing.expectEqualStrings("y_{1,0}", latex3);

    const latex4 = try ctx.toLaTeX("y[0, 0]^2", allocator);
    defer allocator.free(latex4);
    try std.testing.expectEqualStrings("{y_{0,0}}^{2}", latex4);

    const latex5 = try ctx.toLaTeX("sin(max(0, y[4, 0]))", allocator);
    defer allocator.free(latex5);
    try std.testing.expectEqualStrings("\\sin\\left(\\max\\left(0, y_{4,0}\\right)\\right)", latex5);

    const latex6 = try ctx.toLaTeX("mu_v", allocator);
    defer allocator.free(latex6);
    try std.testing.expectEqualStrings("\\mu_{\\mathrm{v}}", latex6);
}

test "latex generator - matrix of dynamic_access" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const latex = try ctx.toLaTeX("x1 = [result_stage1[0, 1]; result_stage1[0, 2]; conv(m2 + m3 + mp, kg)]", allocator);
    defer allocator.free(latex);
    try std.testing.expect(std.mem.indexOf(u8, latex, "unsupported") == null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\text{result\\_stage1}_{0,1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\begin{bmatrix}") != null);
}

test "latex generator - rocket-style function body" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const src =
        \\rocket_deriv_inter(t, y) = [y[1, 0] * sin(max(0, y[4, 0])); -mu_v / y[0, 0]^2 * sin(max(0, y[4, 0])) - drag_v(y[0, 0], y[1, 0]) / y[2, 0]; 0; y[1, 0]/y[0, 0] * cos(y[4, 0]); (y[1, 0]/y[0, 0] - mu_v / (y[0, 0]^2 * y[1, 0])) * cos(y[4, 0])]
    ;
    const latex = try ctx.toLaTeX(src, allocator);
    defer allocator.free(latex);

    try std.testing.expect(std.mem.indexOf(u8, latex, "unsupported") == null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "y[") == null); // no bracket indexing
    try std.testing.expect(std.mem.indexOf(u8, latex, "y_{1,0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\sin") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\cos") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\max") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\mu_{\\mathrm{v}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\begin{bmatrix}") != null);
}
