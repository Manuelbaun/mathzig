const std = @import("std");
const ast = @import("../core/ast.zig");
const Node = ast.Node;
const NodeType = ast.NodeType;
const Opcode = @import("../vm/bytecode.zig").Opcode;

pub fn nodeToLaTeX(node: *const Node, allocator: std.mem.Allocator) ![]const u8 {
    switch (node.type) {
        .number => {
            return try formatNumber(allocator, node.data.number);
        },
        .variable => {
            return try formatIdent(allocator, node.data.variable);
        },
        .boolean => {
            return try allocator.dupe(u8, if (node.data.boolean) "\\text{true}" else "\\text{false}");
        },
        .complex => {
            return try formatComplex(allocator, node.data.complex.re, node.data.complex.im);
        },
        .unit => {
            if (node.data.unit.name) |name| {
                const esc = try escapeText(allocator, name);
                defer allocator.free(esc);
                return try std.fmt.allocPrint(allocator, "\\text{{{s}}}", .{esc});
            } else {
                return try allocator.dupe(u8, "\\text{unit}");
            }
        },
        .binary_op => {
            const op = node.data.binary_op.op;
            const lhs = try nodeToLaTeX(node.data.binary_op.lhs, allocator);
            defer allocator.free(lhs);
            const rhs = try nodeToLaTeX(node.data.binary_op.rhs, allocator);
            defer allocator.free(rhs);

            // Wrap in parentheses if lower precedence
            const lhs_str = if (needsParentheses(node.data.binary_op.lhs, op, .left))
                try std.fmt.allocPrint(allocator, "\\left({s}\\right)", .{lhs})
            else
                try allocator.dupe(u8, lhs);
            defer allocator.free(lhs_str);

            const rhs_str = if (needsParentheses(node.data.binary_op.rhs, op, .right))
                try std.fmt.allocPrint(allocator, "\\left({s}\\right)", .{rhs})
            else
                try allocator.dupe(u8, rhs);
            defer allocator.free(rhs_str);

            return switch (op) {
                .add => try std.fmt.allocPrint(allocator, "{s} + {s}", .{ lhs_str, rhs_str }),
                .sub => try std.fmt.allocPrint(allocator, "{s} - {s}", .{ lhs_str, rhs_str }),
                .mul => try std.fmt.allocPrint(allocator, "{s} \\cdot {s}", .{ lhs_str, rhs_str }),
                // Use raw lhs/rhs for fractions (parens already in structure when needed)
                .div => try std.fmt.allocPrint(allocator, "\\frac{{{s}}}{{{s}}}", .{ lhs, rhs }),
                .pow => blk: {
                    // Base must be a single TeX atom so ^ attaches to the whole term
                    // (indexed bases, multi-token complex, parenthesized groups, etc.).
                    const base_needs_group = node.data.binary_op.lhs.type == .dynamic_access or
                        node.data.binary_op.lhs.type == .function_call or
                        node.data.binary_op.lhs.type == .member_access or
                        node.data.binary_op.lhs.type == .complex or
                        node.data.binary_op.lhs.type == .binary_op or
                        node.data.binary_op.lhs.type == .unary_op or
                        std.mem.indexOfScalar(u8, lhs_str, ' ') != null or
                        std.mem.startsWith(u8, lhs_str, "\\left");
                    const base = if (base_needs_group)
                        try std.fmt.allocPrint(allocator, "{{{s}}}", .{lhs_str})
                    else
                        try allocator.dupe(u8, lhs_str);
                    defer allocator.free(base);
                    break :blk try std.fmt.allocPrint(allocator, "{s}^{{{s}}}", .{ base, rhs });
                },
                .eq => try std.fmt.allocPrint(allocator, "{s} = {s}", .{ lhs_str, rhs_str }),
                .ne => try std.fmt.allocPrint(allocator, "{s} \\neq {s}", .{ lhs_str, rhs_str }),
                .lt => try std.fmt.allocPrint(allocator, "{s} < {s}", .{ lhs_str, rhs_str }),
                .le => try std.fmt.allocPrint(allocator, "{s} \\leq {s}", .{ lhs_str, rhs_str }),
                .gt => try std.fmt.allocPrint(allocator, "{s} > {s}", .{ lhs_str, rhs_str }),
                .ge => try std.fmt.allocPrint(allocator, "{s} \\geq {s}", .{ lhs_str, rhs_str }),
                .store_var => try std.fmt.allocPrint(allocator, "{s} = {s}", .{ lhs_str, rhs_str }),
                .unit_convert => try std.fmt.allocPrint(allocator, "{s} \\to {s}", .{ lhs_str, rhs_str }),
                else => try std.fmt.allocPrint(allocator, "{s} \\mathbin{{\\mathrm{{op}}}} {s}", .{ lhs_str, rhs_str }),
            };
        },
        .unary_op => {
            const expr = try nodeToLaTeX(node.data.unary_op.expr, allocator);
            defer allocator.free(expr);
            const expr_str = if (node.data.unary_op.expr.type == .binary_op)
                try std.fmt.allocPrint(allocator, "\\left({s}\\right)", .{expr})
            else
                try allocator.dupe(u8, expr);
            defer allocator.free(expr_str);

            return switch (node.data.unary_op.op) {
                .neg => try std.fmt.allocPrint(allocator, "-{s}", .{expr_str}),
                .not_ => try std.fmt.allocPrint(allocator, "\\neg {s}", .{expr_str}),
                else => try std.fmt.allocPrint(allocator, "\\mathrm{{op}}{s}", .{expr_str}),
            };
        },
        .function_call => {
            const name = node.data.function_call.name;

            if (std.mem.eql(u8, name, "sqrt") and node.data.function_call.args.len == 1) {
                const arg_latex = try nodeToLaTeX(node.data.function_call.args[0], allocator);
                defer allocator.free(arg_latex);
                return try std.fmt.allocPrint(allocator, "\\sqrt{{{s}}}", .{arg_latex});
            }

            if (std.mem.eql(u8, name, "abs") and node.data.function_call.args.len == 1) {
                const arg_latex = try nodeToLaTeX(node.data.function_call.args[0], allocator);
                defer allocator.free(arg_latex);
                return try std.fmt.allocPrint(allocator, "\\left|{s}\\right|", .{arg_latex});
            }

            var args_list = std.ArrayListUnmanaged(u8).empty;
            defer args_list.deinit(allocator);

            for (node.data.function_call.args, 0..) |arg, i| {
                if (i > 0) try args_list.appendSlice(allocator, ", ");
                const arg_latex = try nodeToLaTeX(arg, allocator);
                defer allocator.free(arg_latex);
                try args_list.appendSlice(allocator, arg_latex);
            }

            if (mathOpName(name)) |op| {
                return try std.fmt.allocPrint(allocator, "{s}\\left({s}\\right)", .{ op, args_list.items });
            }

            // User / domain functions: upright name; escape _ for KaTeX \text
            const esc = try escapeText(allocator, name);
            defer allocator.free(esc);
            return try std.fmt.allocPrint(allocator, "\\text{{{s}}}\\left({s}\\right)", .{ esc, args_list.items });
        },
        .function_def => {
            const name = node.data.function_def.name;
            var params = std.ArrayListUnmanaged(u8).empty;
            defer params.deinit(allocator);
            for (node.data.function_def.params, 0..) |p, i| {
                if (i > 0) try params.appendSlice(allocator, ", ");
                const p_tex = try formatIdent(allocator, p);
                defer allocator.free(p_tex);
                try params.appendSlice(allocator, p_tex);
            }
            const body = try nodeToLaTeX(node.data.function_def.body, allocator);
            defer allocator.free(body);
            const esc = try escapeText(allocator, name);
            defer allocator.free(esc);
            return try std.fmt.allocPrint(allocator, "\\text{{{s}}}\\left({s}\\right) = {s}", .{ esc, params.items, body });
        },
        .member_access => {
            const obj = try nodeToLaTeX(node.data.member_access.object, allocator);
            defer allocator.free(obj);
            const esc = try escapeText(allocator, node.data.member_access.field);
            defer allocator.free(esc);
            return try std.fmt.allocPrint(allocator, "{s}.\\text{{{s}}}", .{ obj, esc });
        },
        .dynamic_access => {
            // Math-style indexing: y_{1,0} instead of y[1, 0]
            const obj = try nodeToLaTeX(node.data.dynamic_access.object, allocator);
            defer allocator.free(obj);
            var keys = std.ArrayListUnmanaged(u8).empty;
            defer keys.deinit(allocator);
            for (node.data.dynamic_access.keys, 0..) |key, i| {
                if (i > 0) try keys.appendSlice(allocator, ",");
                const key_latex = try nodeToLaTeX(key, allocator);
                defer allocator.free(key_latex);
                try keys.appendSlice(allocator, key_latex);
            }
            return try std.fmt.allocPrint(allocator, "{s}_{{{s}}}", .{ obj, keys.items });
        },
        .string => {
            const esc = try escapeText(allocator, node.data.string);
            defer allocator.free(esc);
            return try std.fmt.allocPrint(allocator, "\\text{{{s}}}", .{esc});
        },
        .slice => {
            const start = if (node.data.slice.start) |s|
                try nodeToLaTeX(s, allocator)
            else
                try allocator.dupe(u8, "");
            defer allocator.free(start);
            const end = if (node.data.slice.end) |e|
                try nodeToLaTeX(e, allocator)
            else
                try allocator.dupe(u8, "");
            defer allocator.free(end);
            if (node.data.slice.step) |st| {
                const step = try nodeToLaTeX(st, allocator);
                defer allocator.free(step);
                return try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ start, end, step });
            }
            return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ start, end });
        },
        .matrix => {
            var buf = std.ArrayListUnmanaged(u8).empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, "\\begin{bmatrix} ");

            for (0..node.data.matrix.rows) |r| {
                if (r > 0) try buf.appendSlice(allocator, " \\\\ ");
                for (0..node.data.matrix.cols) |c| {
                    if (c > 0) try buf.appendSlice(allocator, " & ");
                    const el_latex = try nodeToLaTeX(node.data.matrix.elements[r * node.data.matrix.cols + c], allocator);
                    defer allocator.free(el_latex);
                    try buf.appendSlice(allocator, el_latex);
                }
            }
            try buf.appendSlice(allocator, " \\end{bmatrix}");
            return try buf.toOwnedSlice(allocator);
        },
        .ternary => {
            const cond = try nodeToLaTeX(node.data.ternary.cond, allocator);
            defer allocator.free(cond);
            const then_e = try nodeToLaTeX(node.data.ternary.then_expr, allocator);
            defer allocator.free(then_e);
            const else_e = try nodeToLaTeX(node.data.ternary.else_expr, allocator);
            defer allocator.free(else_e);
            return try std.fmt.allocPrint(allocator, "\\text{{if }} {s} \\text{{ then }} {s} \\text{{ else }} {s}", .{ cond, then_e, else_e });
        },
        .record_literal => {
            var buf = std.ArrayListUnmanaged(u8).empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, "\\{ ");
            for (node.data.record_literal.fields, 0..) |field, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const key_esc = try escapeText(allocator, field.key);
                defer allocator.free(key_esc);
                try buf.appendSlice(allocator, "\\text{");
                try buf.appendSlice(allocator, key_esc);
                try buf.appendSlice(allocator, "}: ");
                const val_latex = try nodeToLaTeX(field.value, allocator);
                defer allocator.free(val_latex);
                try buf.appendSlice(allocator, val_latex);
            }
            try buf.appendSlice(allocator, " \\}");
            return try buf.toOwnedSlice(allocator);
        },
        .sequence => {
            var buf = std.ArrayListUnmanaged(u8).empty;
            defer buf.deinit(allocator);
            for (node.data.sequence.exprs, 0..) |expr, i| {
                if (i > 0) try buf.appendSlice(allocator, "; ");
                const expr_latex = try nodeToLaTeX(expr, allocator);
                defer allocator.free(expr_latex);
                try buf.appendSlice(allocator, expr_latex);
            }
            return try buf.toOwnedSlice(allocator);
        },
        else => {
            return try std.fmt.allocPrint(allocator, "\\text{{unsupported:{any}}}", .{node.type});
        },
    }
}

/// Escape characters that break KaTeX inside `\text{...}` (especially `_`).
fn escapeText(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '_', '%', '#', '&', '$', '{', '}' => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Single-letter vars stay math italic. Physics-style suffixes (mu_v, r0_v)
/// become proper subscripts. Longer underscored names use upright \text so
/// indexing attaches cleanly: \text{result\_stage1}_{0,1}.
fn formatIdent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 1 and std.ascii.isAlphabetic(name[0])) {
        return try allocator.dupe(u8, name);
    }
    // Physics-style base + short suffix: mu_v → \mu_{\mathrm{v}}, r0_v → r0_{\mathrm{v}}
    if (std.mem.indexOfScalar(u8, name, '_')) |us| {
        const head = name[0..us];
        const tail = name[us + 1 ..];
        if (head.len > 0 and tail.len > 0 and tail.len <= 4 and
            std.mem.indexOfScalar(u8, tail, '_') == null)
        {
            if (greekLetter(head)) |g| {
                const tail_esc = try escapeText(allocator, tail);
                defer allocator.free(tail_esc);
                return try std.fmt.allocPrint(allocator, "{s}_{{\\mathrm{{{s}}}}}", .{ g, tail_esc });
            }
            if (head.len <= 3) {
                const tail_esc = try escapeText(allocator, tail);
                defer allocator.free(tail_esc);
                return try std.fmt.allocPrint(allocator, "{s}_{{\\mathrm{{{s}}}}}", .{ head, tail_esc });
            }
        }
    }
    const esc = try escapeText(allocator, name);
    defer allocator.free(esc);
    return try std.fmt.allocPrint(allocator, "\\text{{{s}}}", .{esc});
}

fn greekLetter(name: []const u8) ?[]const u8 {
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "alpha", "\\alpha" },
        .{ "beta", "\\beta" },
        .{ "gamma", "\\gamma" },
        .{ "delta", "\\delta" },
        .{ "epsilon", "\\epsilon" },
        .{ "theta", "\\theta" },
        .{ "lambda", "\\lambda" },
        .{ "mu", "\\mu" },
        .{ "nu", "\\nu" },
        .{ "pi", "\\pi" },
        .{ "rho", "\\rho" },
        .{ "sigma", "\\sigma" },
        .{ "tau", "\\tau" },
        .{ "phi", "\\phi" },
        .{ "omega", "\\omega" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p[0])) return p[1];
    }
    return null;
}

fn mathOpName(name: []const u8) ?[]const u8 {
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "sin", "\\sin" },
        .{ "cos", "\\cos" },
        .{ "tan", "\\tan" },
        .{ "asin", "\\arcsin" },
        .{ "acos", "\\arccos" },
        .{ "atan", "\\arctan" },
        .{ "sinh", "\\sinh" },
        .{ "cosh", "\\cosh" },
        .{ "tanh", "\\tanh" },
        .{ "exp", "\\exp" },
        .{ "log", "\\log" },
        .{ "ln", "\\ln" },
        .{ "max", "\\max" },
        .{ "min", "\\min" },
        .{ "det", "\\det" },
        .{ "gcd", "\\gcd" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p[0])) return p[1];
    }
    return null;
}

/// Format a float for KaTeX. Never emit bare `1.2e-3` — KaTeX reads `e` as a variable.
fn formatNumber(allocator: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return try allocator.dupe(u8, "\\text{NaN}");
    if (std.math.isInf(n)) {
        return try allocator.dupe(u8, if (n > 0) "\\infty" else "-\\infty");
    }
    if (n == 0) return try allocator.dupe(u8, "0");
    if (n == @floor(n) and @abs(n) < 1e15) {
        return try std.fmt.allocPrint(allocator, "{d:.0}", .{n});
    }

    var buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{d}", .{n}) catch {
        return try std.fmt.allocPrint(allocator, "{d}", .{n});
    };

    // Scientific notation → a \times 10^{b} so mantissa/exponent stay correct.
    if (std.mem.indexOfAny(u8, raw, "eE")) |eidx| {
        const mant = raw[0..eidx];
        var exp = raw[eidx + 1 ..];
        if (exp.len > 0 and exp[0] == '+') exp = exp[1..];
        return try std.fmt.allocPrint(allocator, "{s} \\times 10^{{{s}}}", .{ mant, exp });
    }
    return try allocator.dupe(u8, raw);
}

/// Complex literals as proper math atoms: i, 2i, 3 + 4i (not "0 + 1i").
fn formatComplex(allocator: std.mem.Allocator, re: f64, im: f64) ![]const u8 {
    const re0 = re == 0;
    const im0 = im == 0;
    if (re0 and im0) return try allocator.dupe(u8, "0");

    if (im0) return try formatNumber(allocator, re);

    if (re0) {
        if (im == 1) return try allocator.dupe(u8, "i");
        if (im == -1) return try allocator.dupe(u8, "-i");
        const im_s = try formatNumber(allocator, im);
        defer allocator.free(im_s);
        return try std.fmt.allocPrint(allocator, "{s}i", .{im_s});
    }

    const re_s = try formatNumber(allocator, re);
    defer allocator.free(re_s);
    const im_abs = @abs(im);
    if (im_abs == 1) {
        return if (im > 0)
            try std.fmt.allocPrint(allocator, "{s} + i", .{re_s})
        else
            try std.fmt.allocPrint(allocator, "{s} - i", .{re_s});
    }
    const im_s = try formatNumber(allocator, im_abs);
    defer allocator.free(im_s);
    return if (im > 0)
        try std.fmt.allocPrint(allocator, "{s} + {s}i", .{ re_s, im_s })
    else
        try std.fmt.allocPrint(allocator, "{s} - {s}i", .{ re_s, im_s });
}

fn isMultiTokenAtom(node: *const Node) bool {
    return switch (node.type) {
        .complex => node.data.complex.re != 0 and node.data.complex.im != 0,
        .ternary, .sequence, .record_literal => true,
        else => false,
    };
}

fn needsParentheses(node: *const Node, parent_op: Opcode, side: enum { left, right }) bool {
    // a + bi must not become "2 · a + bi" when multiplied — always group multi-token atoms.
    if (isMultiTokenAtom(node)) return true;

    if (node.type != .binary_op) return false;
    const child_op = node.data.binary_op.op;

    const p_prec = getPrecedence(parent_op);
    const c_prec = getPrecedence(child_op);

    if (c_prec < p_prec) return true;
    if (c_prec == p_prec) {
        // Handle associativity
        if (side == .right) {
            // Most ops are left-associative, so right side needs parens if same precedence
            // Except for power which is right-associative
            if (parent_op != .pow) return true;
        } else {
            // Left side needs parens for right-associative ops
            if (parent_op == .pow) return true;
        }
    }

    return false;
}

fn getPrecedence(op: Opcode) u8 {
    return switch (op) {
        .store_var => 1,
        .or_ => 2,
        .and_ => 3,
        .eq, .ne, .lt, .le, .gt, .ge => 4,
        .add, .sub => 5,
        .mul, .div => 6,
        .pow => 7,
        else => 0,
    };
}
