//! Spec 02/05 — Zig fuse lowerer (mirror of TS fuse.ts).
//!
//! Source: `src/graph/fuse.zig` (not a test root under nested graph package).

const std = @import("std");
const mathzig = @import("mathzig");
const schema = mathzig.graph.schema;
const fuse = mathzig.graph.fuse;

test "fuse T1: linear chain topo + one output" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "a", "type": "expr", "expr": "x * 2", "inputs": ["x"]},
        \\    {"id": "b", "type": "expr", "expr": "x + 1", "inputs": ["x"]},
        \\    {"id": "c", "type": "expr", "expr": "x / 2", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "a.x"},
        \\    {"from": "a.out", "to": "b.x"},
        \\    {"from": "b.out", "to": "c.x"}
        \\  ],
        \\  "outputs": {"value": "c.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const plan = try fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectEqual(@as(usize, 3), plan.nodes.len);
    try std.testing.expectEqualStrings("a", plan.nodes[0].id);
    try std.testing.expectEqualStrings("b", plan.nodes[1].id);
    try std.testing.expectEqualStrings("c", plan.nodes[2].id);
    try std.testing.expectEqual(@as(usize, 1), plan.outputs.len);
    try std.testing.expectEqualStrings("value", plan.outputs[0].name);
    try std.testing.expectEqualStrings("c", plan.outputs[0].from_node_id);
    try std.testing.expectEqual(@as(usize, 1), plan.inputs.len);
    try std.testing.expectEqualStrings("in", plan.nodes[0].input_ports[0]);
    try std.testing.expectEqualStrings("a", plan.nodes[1].input_ports[0]);
    try std.testing.expectEqualStrings("b", plan.nodes[2].input_ports[0]);
}

test "fuse T2: diamond shares intermediate once" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "A", "type": "expr", "expr": "x * 2", "inputs": ["x"]},
        \\    {"id": "B", "type": "expr", "expr": "x + 1", "inputs": ["x"]},
        \\    {"id": "C", "type": "expr", "expr": "x - 1", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "A.x"},
        \\    {"from": "A.out", "to": "B.x"},
        \\    {"from": "A.out", "to": "C.x"}
        \\  ],
        \\  "outputs": {"left": "B.out", "right": "C.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const plan = try fuse.lowerGraphToFusePlan(arena, allocator, def);
    var a_count: usize = 0;
    for (plan.nodes) |n| {
        if (std.mem.eql(u8, n.id, "A")) a_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), a_count);
    try std.testing.expectEqual(@as(usize, 3), plan.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), plan.outputs.len);
}

test "fuse T3: unused expr dropped" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "used", "type": "expr", "expr": "x + 1", "inputs": ["x"]},
        \\    {"id": "dead", "type": "expr", "expr": "x * 99", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "used.x"},
        \\    {"from": "in.out", "to": "dead.x"}
        \\  ],
        \\  "outputs": {"y": "used.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const plan = try fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectEqual(@as(usize, 1), plan.nodes.len);
    try std.testing.expectEqualStrings("used", plan.nodes[0].id);
}

test "fuse T6: wasm node rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "w", "type": "wasm", "wasm": "x.wasm"}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "w.x"}
        \\  ],
        \\  "outputs": {"y": "w.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.WasmUnsupported, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.wasm_unsupported) != null);
}

test "fuse T8: cycle rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "a", "type": "expr", "expr": "x + 1", "inputs": ["x"]},
        \\    {"id": "b", "type": "expr", "expr": "x + 1", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "a.out", "to": "b.x"},
        \\    {"from": "b.out", "to": "a.x"}
        \\  ],
        \\  "outputs": {"y": "a.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.Cycle, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.cycle) != null);
}

test "fuse params flatten nodeId.param" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "x", "type": "input"},
        \\    {"id": "gain", "type": "expr", "expr": "x * k", "inputs": ["x"], "params": {"k": 1}}
        \\  ],
        \\  "edges": [{"from": "x.out", "to": "gain.x"}],
        \\  "outputs": {"y": "gain.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const plan = try fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectEqual(@as(usize, 1), plan.params.len);
    try std.testing.expectEqualStrings("gain.k", plan.params[0].name);
    try std.testing.expectEqual(@as(f64, 1), plan.params[0].default);
}

test "fuse T4: multi outputs preserve names" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "a", "type": "expr", "expr": "x * 2", "inputs": ["x"]},
        \\    {"id": "b", "type": "expr", "expr": "x + 3", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "a.x"},
        \\    {"from": "in.out", "to": "b.x"}
        \\  ],
        \\  "outputs": {"u": "a.out", "v": "b.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const plan = try fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectEqual(@as(usize, 2), plan.outputs.len);
    var saw_u = false;
    var saw_v = false;
    for (plan.outputs) |o| {
        if (std.mem.eql(u8, o.name, "u")) {
            saw_u = true;
            try std.testing.expectEqualStrings("a", o.from_node_id);
        } else if (std.mem.eql(u8, o.name, "v")) {
            saw_v = true;
            try std.testing.expectEqualStrings("b", o.from_node_id);
        }
    }
    try std.testing.expect(saw_u and saw_v);
}

test "fuse T5: multi-param flatten order left then right" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "left", "type": "expr", "expr": "x * k", "inputs": ["x"], "params": {"k": 2}},
        \\    {"id": "right", "type": "expr", "expr": "x * k", "inputs": ["x"], "params": {"k": 5}}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "left.x"},
        \\    {"from": "in.out", "to": "right.x"}
        \\  ],
        \\  "outputs": {"l": "left.out", "r": "right.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const plan = try fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectEqual(@as(usize, 2), plan.params.len);
    try std.testing.expectEqualStrings("left.k", plan.params[0].name);
    try std.testing.expectEqualStrings("right.k", plan.params[1].name);
    try std.testing.expectEqual(@as(f64, 2), plan.params[0].default);
    try std.testing.expectEqual(@as(f64, 5), plan.params[1].default);
}

test "fuse T7: missing edge for required input" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "sum", "type": "expr", "expr": "x + y", "inputs": ["x", "y"]}
        \\  ],
        \\  "edges": [{"from": "in.out", "to": "sum.x"}],
        \\  "outputs": {"value": "sum.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.MissingInputEdge, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.missing_input_edge) != null);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), "y") != null);
}

test "fuse undeclared input port rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "n", "type": "expr", "expr": "x", "inputs": ["x"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "n.x"},
        \\    {"from": "in.out", "to": "n.extra"}
        \\  ],
        \\  "outputs": {"value": "n.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.UndeclaredPort, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.undeclared_port) != null);
}

test "fuse input+param name collision rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "n", "type": "expr", "expr": "x * 2", "inputs": ["x"], "params": {"x": 1}}
        \\  ],
        \\  "edges": [{"from": "in.out", "to": "n.x"}],
        \\  "outputs": {"value": "n.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.InputParamCollision, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.input_param_collision) != null);
}

test "fuse non-finite param rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Build def manually — JSON numbers cannot express NaN.
    const inputs_arr = try arena.alloc([]const u8, 1);
    inputs_arr[0] = "x";
    const input_kinds = try arena.alloc(schema.PortKind, 1);
    input_kinds[0] = .number;
    const params = try arena.alloc(schema.ParamEntry, 1);
    params[0] = .{ .name = "k", .value = std.math.nan(f64) };

    const nodes = try arena.alloc(schema.GraphNode, 2);
    nodes[0] = .{ .input = .{ .id = "in", .name = "in", .kind = .number } };
    nodes[1] = .{ .expr = .{
        .id = "n",
        .expr = "x * k",
        .inputs = inputs_arr,
        .input_kinds = input_kinds,
        .params = params,
        .output_kind = .number,
    } };
    const edges = try arena.alloc(schema.GraphEdge, 1);
    edges[0] = .{ .from = "in.out", .to = "n.x" };
    const outputs = try arena.alloc(schema.OutputEntry, 1);
    outputs[0] = .{ .name = "value", .ref = "n.out" };

    const def = schema.NormalizedGraphDefinition{
        .nodes = nodes,
        .edges = edges,
        .outputs = outputs,
    };
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.NonFiniteParam, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.non_finite_param) != null);
}

test "fuse duplicate host-facing input names rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "a", "type": "input", "name": "signal"},
        \\    {"id": "b", "type": "input", "name": "signal"},
        \\    {"id": "sum", "type": "expr", "expr": "x + y", "inputs": ["x", "y"]}
        \\  ],
        \\  "edges": [
        \\    {"from": "a.out", "to": "sum.x"},
        \\    {"from": "b.out", "to": "sum.y"}
        \\  ],
        \\  "outputs": {"value": "sum.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.DuplicateInputName, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.duplicate_input_name) != null);
}

test "fuse kind mismatch rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "m", "type": "input", "kind": "matrix"},
        \\    {"id": "n", "type": "expr", "expr": "x", "inputs": ["x"], "inputKinds": ["number"]}
        \\  ],
        \\  "edges": [{"from": "m.out", "to": "n.x"}],
        \\  "outputs": {"value": "n.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectError(error.KindMismatch, result);
    try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.kind_mismatch) != null);
}

test "fuse invalid and non-out output refs rejected" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    {
        const json =
            \\{
            \\  "nodes": [{"id": "a", "type": "expr", "expr": "1", "inputs": []}],
            \\  "edges": [],
            \\  "outputs": {"value": "ghost.out"}
            \\}
        ;
        const def = try schema.parseGraphDefinition(arena, json);
        const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
        try std.testing.expectError(error.MissingOutputNode, result);
        try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.missing_output_node) != null);
    }
    {
        const json =
            \\{
            \\  "nodes": [
            \\    {"id": "in", "type": "input"},
            \\    {"id": "a", "type": "expr", "expr": "x", "inputs": ["x"]}
            \\  ],
            \\  "edges": [{"from": "in.out", "to": "a.x"}],
            \\  "outputs": {"value": "a.x"}
            \\}
        ;
        const def = try schema.parseGraphDefinition(arena, json);
        const result = fuse.lowerGraphToFusePlan(arena, allocator, def);
        try std.testing.expectError(error.OutputNotOut, result);
        try std.testing.expect(std.mem.indexOf(u8, fuse.lastError(), fuse.ERR.output_not_out) != null);
    }
}

test "fuse drops unreachable wasm; keeps reachable const" {
    const allocator = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "in", "type": "input"},
        \\    {"id": "unusedIn", "type": "input"},
        \\    {"id": "bias", "type": "const", "value": 1.25},
        \\    {"id": "deadConst", "type": "const", "value": 99},
        \\    {"id": "used", "type": "expr", "expr": "x + y", "inputs": ["x", "y"]},
        \\    {"id": "deadWasm", "type": "wasm", "wasm": "x.wasm"}
        \\  ],
        \\  "edges": [
        \\    {"from": "in.out", "to": "used.x"},
        \\    {"from": "bias.out", "to": "used.y"},
        \\    {"from": "in.out", "to": "deadWasm.x"}
        \\  ],
        \\  "outputs": {"value": "used.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(arena, json);
    const plan = try fuse.lowerGraphToFusePlan(arena, allocator, def);
    try std.testing.expectEqual(@as(usize, 1), plan.inputs.len);
    try std.testing.expectEqualStrings("in", plan.inputs[0].source_node_id);
    try std.testing.expectEqual(@as(usize, 1), plan.consts.len);
    try std.testing.expectEqualStrings("bias", plan.consts[0].id);
    try std.testing.expectEqual(@as(usize, 1), plan.nodes.len);
    try std.testing.expectEqualStrings("used", plan.nodes[0].id);
}
