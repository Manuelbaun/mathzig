//! VM-native graph evaluator v1 goldens (task-11 Part 2).
//!
//! Component never loads .wasm bytes; evaluates via in-process MathZig VM.
//!
//! 1. Scalar: double-then-add vs composed zig_vm eval
//! 2. Matrix: elementwise scale then identity matmul vs composed expr
//! 3. Determinism: two consecutive runs identical
//! 4. Cycle load error
//! 5. setParam changes next tick

const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const Value = mathzig.Value;
const ValueTag = mathzig.ValueTag;
const GraphRunner = mathzig.graph.GraphRunner;
const value_transfer = mathzig.graph.value_transfer;

fn zigVmEvalNumber(allocator: std.mem.Allocator, expr: []const u8, x: ?f64) !f64 {
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();
    if (x) |v| ctx.setNumber("x", v);
    const result = try ctx.eval(expr);
    defer result.release();
    return result.toNumber().?;
}

fn zigVmEvalMatrix(allocator: std.mem.Allocator, expr: []const u8) !struct { rows: u32, cols: u32, data: [4]f64 } {
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();
    const result = try ctx.eval(expr);
    defer result.release();
    try std.testing.expectEqual(ValueTag.matrix, result.tag);
    const m = result.data.matrix;
    try std.testing.expectEqual(@as(u32, 2), m.rows);
    try std.testing.expectEqual(@as(u32, 2), m.cols);
    return .{
        .rows = m.rows,
        .cols = m.cols,
        .data = .{ m.get(0, 0), m.get(0, 1), m.get(1, 0), m.get(1, 1) },
    };
}

test "native runner scalar golden: double then add == zig_vm" {
    const allocator = std.testing.allocator;
    const x_val: f64 = 7;
    const composed = "(x * 2) + 1";
    const baseline = try zigVmEvalNumber(allocator, composed, x_val);

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "x", "type": "input"},
        \\    {"id": "g", "type": "expr", "expr": "x * 2", "inputs": ["x"]},
        \\    {"id": "f", "type": "expr", "expr": "x + 1", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "x.out", "to": "g.x"},
        \\    {"from": "g.out", "to": "f.x"}
        \\  ],
        \\  "outputs": {"value": "f.out"}
        \\}
    ;
    var runner = try GraphRunner.load(allocator, json);
    defer runner.dispose();

    var outs = try runner.runScalars(&.{.{ "x", x_val }});
    defer GraphRunner.releaseOutputs(&outs);
    const v = outs.get("value").?.toNumber().?;
    try std.testing.expectApproxEqAbs(baseline, v, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15), v, 1e-12);
}

test "native runner matrix golden: scale then identity matmul == zig_vm" {
    const allocator = std.testing.allocator;
    const composed = "([1, 2; 3, 4] * 2) * [1, 0; 0, 1]";
    const baseline = try zigVmEvalMatrix(allocator, composed);

    const json =
        \\{
        \\  "nodes": [
        \\    {
        \\      "id": "g",
        \\      "type": "expr",
        \\      "expr": "[1, 2; 3, 4] * 2",
        \\      "outputKind": "matrix"
        \\    },
        \\    {
        \\      "id": "f",
        \\      "type": "expr",
        \\      "expr": "x * [1, 0; 0, 1]",
        \\      "inputs": ["x"],
        \\      "inputKinds": ["matrix"],
        \\      "outputKind": "matrix"
        \\    }
        \\  ],
        \\  "edges": [{"from": "g.out", "to": "f.x"}],
        \\  "outputs": {"value": "f.out"}
        \\}
    ;
    var runner = try GraphRunner.load(allocator, json);
    defer runner.dispose();

    var outs = try runner.runScalars(&.{});
    defer GraphRunner.releaseOutputs(&outs);
    const v = outs.get("value").?;
    try std.testing.expectEqual(ValueTag.matrix, v.tag);
    const m = v.data.matrix;
    try std.testing.expectEqual(baseline.rows, m.rows);
    try std.testing.expectEqual(baseline.cols, m.cols);
    try std.testing.expectApproxEqAbs(baseline.data[0], m.get(0, 0), 1e-12);
    try std.testing.expectApproxEqAbs(baseline.data[1], m.get(0, 1), 1e-12);
    try std.testing.expectApproxEqAbs(baseline.data[2], m.get(1, 0), 1e-12);
    try std.testing.expectApproxEqAbs(baseline.data[3], m.get(1, 1), 1e-12);
    // Explicit expected [2,4;6,8]
    try std.testing.expectApproxEqAbs(@as(f64, 2), m.get(0, 0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), m.get(0, 1), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6), m.get(1, 0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8), m.get(1, 1), 1e-12);
}

test "native runner determinism: two consecutive pure runs identical" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "x", "type": "input"},
        \\    {"id": "g", "type": "expr", "expr": "x * 2", "inputs": ["x"]},
        \\    {"id": "f", "type": "expr", "expr": "x + 1", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "x.out", "to": "g.x"},
        \\    {"from": "g.out", "to": "f.x"}
        \\  ],
        \\  "outputs": {"value": "f.out"}
        \\}
    ;
    var runner = try GraphRunner.load(allocator, json);
    defer runner.dispose();

    var a = try runner.runScalars(&.{.{ "x", 7 }});
    defer GraphRunner.releaseOutputs(&a);
    var b = try runner.runScalars(&.{.{ "x", 7 }});
    defer GraphRunner.releaseOutputs(&b);

    try std.testing.expect(value_transfer.valuesEqual(a.get("value").?, b.get("value").?, 1e-12));
}

test "native runner cycle load error names nodes" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "a", "type": "expr", "expr": "x + 1", "inputs": ["x"]},
        \\    {"id": "b", "type": "expr", "expr": "x * 2", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "a.out", "to": "b.x"},
        \\    {"from": "b.out", "to": "a.x"}
        \\  ],
        \\  "outputs": {"value": "b.out"}
        \\}
    ;
    const result = GraphRunner.load(allocator, json);
    try std.testing.expectError(error.Cycle, result);
    const msg = mathzig.graph.runner.lastCycleError();
    try std.testing.expect(msg.len > 0);
    // Should mention at least one of the cycle nodes
    const has_a = std.mem.indexOf(u8, msg, "a") != null;
    const has_b = std.mem.indexOf(u8, msg, "b") != null;
    try std.testing.expect(has_a or has_b);
}

test "native runner setParam changes next tick" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "signal", "type": "input"},
        \\    {"id": "leftGain", "type": "expr", "expr": "x * y", "inputs": ["x"], "params": {"y": 2}},
        \\    {"id": "rightGain", "type": "expr", "expr": "x * y", "inputs": ["x"], "params": {"y": 5}}
        \\  ],
        \\  "edges": [
        \\    {"from": "signal.out", "to": "leftGain.x"},
        \\    {"from": "signal.out", "to": "rightGain.x"}
        \\  ],
        \\  "outputs": {
        \\    "left": "leftGain.out",
        \\    "right": "rightGain.out"
        \\  }
        \\}
    ;
    var runner = try GraphRunner.load(allocator, json);
    defer runner.dispose();

    {
        var outs = try runner.runScalars(&.{.{ "signal", 3 }});
        defer GraphRunner.releaseOutputs(&outs);
        try std.testing.expectApproxEqAbs(@as(f64, 6), outs.get("left").?.toNumber().?, 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 15), outs.get("right").?.toNumber().?, 1e-12);
    }

    try runner.setParam("leftGain", "y", 4);

    {
        var outs = try runner.runScalars(&.{.{ "signal", 3 }});
        defer GraphRunner.releaseOutputs(&outs);
        try std.testing.expectApproxEqAbs(@as(f64, 12), outs.get("left").?.toNumber().?, 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 15), outs.get("right").?.toNumber().?, 1e-12);
    }
}

test "native runner multi-node scalar chain" {
    const allocator = std.testing.allocator;
    // ((x*2 + y) - 1.25) / x  with x=3, y=4 → (6+4-1.25)/3 = 8.75/3
    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "x", "type": "input"},
        \\    {"id": "y", "type": "input"},
        \\    {"id": "bias", "type": "const", "value": 1.25},
        \\    {"id": "doubleX", "type": "expr", "expr": "x * 2", "inputs": ["x"]},
        \\    {"id": "sum", "type": "expr", "expr": "x + y", "inputs": ["x", "y"]},
        \\    {"id": "result", "type": "expr", "expr": "(x - y) / z", "inputs": ["x", "y", "z"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "x.out", "to": "doubleX.x"},
        \\    {"from": "doubleX.out", "to": "sum.x"},
        \\    {"from": "y.out", "to": "sum.y"},
        \\    {"from": "sum.out", "to": "result.x"},
        \\    {"from": "bias.out", "to": "result.y"},
        \\    {"from": "x.out", "to": "result.z"}
        \\  ],
        \\  "outputs": {"value": "result.out"}
        \\}
    ;
    var runner = try GraphRunner.load(allocator, json);
    defer runner.dispose();

    var outs = try runner.runScalars(&.{ .{ "x", 3 }, .{ "y", 4 } });
    defer GraphRunner.releaseOutputs(&outs);
    const expected = ((3.0 * 2.0 + 4.0) - 1.25) / 3.0;
    try std.testing.expectApproxEqAbs(expected, outs.get("value").?.toNumber().?, 1e-12);
}
