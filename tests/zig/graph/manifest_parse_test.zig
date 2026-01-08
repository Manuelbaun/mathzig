//! task-18 / D4 — manifest parse table tests + inline/sidecar round-trip.
//!
//! Covers typed rejections (non-object, ABI, duplicate ports, kinds) and proves
//! schema no longer stores the empty-marker `"{}"` for inline manifests.

const std = @import("std");
const mathzig = @import("mathzig");
const schema = mathzig.graph.schema;
const manifest_mod = mathzig.graph.manifest;
const abi = mathzig.wasm.abi;
const NodeManifest = manifest_mod.NodeManifest;
const Port = manifest_mod.Port;

const gain_json =
    \\{"abi":1,"name":"gain","inputs":[{"name":"x","kind":"number"}],"params":[{"name":"k","kind":"number","default":2}],"output":{"name":"out","kind":"number","result_tag":"number"}}
;

// ---------------------------------------------------------------------------
// Shared parser table
// ---------------------------------------------------------------------------

test "parseManifestJson gain node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try manifest_mod.parseManifestJson(arena.allocator(), gain_json);
    try std.testing.expectEqualStrings("gain", m.name);
    try std.testing.expectEqual(@as(u32, 1), m.abi_version);
    try std.testing.expectEqual(@as(usize, 1), m.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), m.params.len);
    try std.testing.expect(m.params[0].default != null);
    try std.testing.expectApproxEqAbs(@as(f64, 2), m.params[0].default.?, 0);
}

test "parseManifestJson rejects non-object root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ManifestNotObject, manifest_mod.parseManifestJson(arena.allocator(), "[]"));
    try std.testing.expectError(error.ManifestNotObject, manifest_mod.parseManifestJson(arena.allocator(), "\"x\""));
    try std.testing.expectError(error.ManifestNotObject, manifest_mod.parseManifestJson(arena.allocator(), "1"));
}

test "parseManifestJson rejects incompatible abi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":999,"name":"gain","inputs":[],"params":[],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.IncompatibleAbiVersion, manifest_mod.parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects duplicate input port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":"number"},{"name":"x","kind":"number"}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.DuplicatePort, manifest_mod.parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects duplicate param port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"params":[{"name":"k","kind":"number"},{"name":"k","kind":"number","default":1}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.DuplicatePort, manifest_mod.parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects input name equals param name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":"number"}],"params":[{"name":"x","kind":"number","default":1}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.DuplicatePort, manifest_mod.parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects unknown kind string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":"nope"}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.UnknownKind, manifest_mod.parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects non-string kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":1}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.MalformedKind, manifest_mod.parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson missing abi defaults to ABI_VERSION" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"name":"n","inputs":[],"params":[],"output":{"kind":"number"}}
    ;
    const m = try manifest_mod.parseManifestJson(arena.allocator(), json);
    try std.testing.expectEqual(abi.ABI_VERSION, m.abi_version);
}

test "writeJson sidecar round-trips through parseManifestJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inputs = [_]Port{
        .{ .name = "x", .kind = .number },
        .{ .name = "y", .kind = .matrix_ptr },
    };
    const params = [_]Port{
        .{ .name = "k", .kind = .number, .default = 2.5 },
    };
    const original = NodeManifest{
        .abi_version = abi.ABI_VERSION,
        .name = "gain",
        .inputs = &inputs,
        .params = &params,
        .output = .{ .name = "out", .kind = .number, .result_tag = "number" },
    };
    const sidecar = try manifest_mod.toJsonAlloc(a, original);
    const parsed = try manifest_mod.parseManifestJson(a, sidecar);

    try std.testing.expectEqual(original.abi_version, parsed.abi_version);
    try std.testing.expectEqualStrings(original.name, parsed.name);
    try std.testing.expectEqual(original.inputs.len, parsed.inputs.len);
    try std.testing.expectEqual(original.params.len, parsed.params.len);
    try std.testing.expectEqualStrings("x", parsed.inputs[0].name);
    try std.testing.expectEqual(abi.WireKind.number, parsed.inputs[0].kind);
    try std.testing.expectEqualStrings("y", parsed.inputs[1].name);
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, parsed.inputs[1].kind);
    try std.testing.expectEqualStrings("k", parsed.params[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), parsed.params[0].default.?, 0);
    try std.testing.expectEqual(abi.WireKind.number, parsed.output.kind);
    try std.testing.expectEqualStrings("number", parsed.output.result_tag.?);
}

test "parseManifestValue matches parseManifestJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const from_text = try manifest_mod.parseManifestJson(a, gain_json);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, gain_json, .{});
    const from_value = try manifest_mod.parseManifestValue(a, root);
    try std.testing.expectEqualStrings(from_text.name, from_value.name);
    try std.testing.expectEqual(from_text.abi_version, from_value.abi_version);
    try std.testing.expectEqual(from_text.inputs.len, from_value.inputs.len);
    try std.testing.expectEqual(from_text.params.len, from_value.params.len);
    try std.testing.expectEqual(from_text.inputs[0].kind, from_value.inputs[0].kind);
    try std.testing.expectApproxEqAbs(from_text.params[0].default.?, from_value.params[0].default.?, 0);
}

// ---------------------------------------------------------------------------
// Schema integration: no "{}" swallow; rejections; inline ≡ sidecar
// ---------------------------------------------------------------------------

test "wasm inline manifest stores canonical JSON not empty marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{
        \\  "nodes": [
        \\    {
        \\      "id": "g",
        \\      "type": "wasm",
        \\      "expr": "x * k",
        \\      "manifest": {
        \\        "abi": 1,
        \\        "name": "gain",
        \\        "inputs": [{"name": "x", "kind": "number"}],
        \\        "params": [{"name": "k", "kind": "number", "default": 2}],
        \\        "output": {"name": "out", "kind": "number", "result_tag": "number"}
        \\      }
        \\    }
        \\  ],
        \\  "edges": [],
        \\  "outputs": {"value": "g.out"}
        \\}
    ;
    const def = try schema.parseGraphDefinition(a, json);
    try std.testing.expectEqual(@as(usize, 1), def.nodes.len);
    const w = def.nodes[0].wasm;
    try std.testing.expect(w.manifest_json != null);
    try std.testing.expect(!std.mem.eql(u8, w.manifest_json.?, "{}"));
    try std.testing.expectEqual(@as(usize, 1), w.inputs.len);
    try std.testing.expectEqualStrings("x", w.inputs[0]);
    try std.testing.expectEqual(schema.PortKind.number, w.input_kinds[0]);
    try std.testing.expectEqual(schema.PortKind.number, w.output_kind);
    try std.testing.expectEqual(@as(usize, 1), w.params.len);
    try std.testing.expectEqualStrings("k", w.params[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2), w.params[0].value, 0);

    const re = try manifest_mod.parseManifestJson(a, w.manifest_json.?);
    try std.testing.expectEqualStrings("gain", re.name);
    try std.testing.expectEqual(@as(u32, 1), re.abi_version);
    try std.testing.expectEqual(@as(usize, 1), re.inputs.len);
    try std.testing.expectEqualStrings("x", re.inputs[0].name);
    try std.testing.expectEqual(abi.WireKind.number, re.inputs[0].kind);
    try std.testing.expectEqual(@as(usize, 1), re.params.len);
    try std.testing.expectApproxEqAbs(@as(f64, 2), re.params[0].default.?, 0);
}

test "wasm inline manifest equals sidecar parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inputs = [_]Port{.{ .name = "x", .kind = .number }};
    const params = [_]Port{.{ .name = "k", .kind = .number, .default = 3 }};
    const original = NodeManifest{
        .name = "gain",
        .inputs = &inputs,
        .params = &params,
        .output = .{ .kind = .number, .result_tag = "number" },
    };
    const sidecar = try manifest_mod.toJsonAlloc(a, original);
    const from_sidecar = try manifest_mod.parseManifestJson(a, sidecar);

    const graph_json = try std.fmt.allocPrint(a,
        \\{{"nodes":[{{"id":"g","type":"wasm","expr":"x*k","manifest":{s}}}],"edges":[],"outputs":{{"value":"g.out"}}}}
    , .{sidecar});
    const def = try schema.parseGraphDefinition(a, graph_json);
    const stored = def.nodes[0].wasm.manifest_json.?;
    const from_inline = try manifest_mod.parseManifestJson(a, stored);

    try std.testing.expectEqualStrings(from_sidecar.name, from_inline.name);
    try std.testing.expectEqual(from_sidecar.abi_version, from_inline.abi_version);
    try std.testing.expectEqual(from_sidecar.inputs.len, from_inline.inputs.len);
    try std.testing.expectEqual(from_sidecar.params.len, from_inline.params.len);
    try std.testing.expectEqual(from_sidecar.inputs[0].kind, from_inline.inputs[0].kind);
    try std.testing.expectApproxEqAbs(from_sidecar.params[0].default.?, from_inline.params[0].default.?, 0);
    try std.testing.expectEqual(from_sidecar.output.kind, from_inline.output.kind);
}

test "wasm non-object manifest rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":[]}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.ManifestNotObject, schema.parseGraphDefinition(arena.allocator(), json));
}

test "wasm bad abi rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":999,"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.IncompatibleAbiVersion, schema.parseGraphDefinition(arena.allocator(), json));
}

test "wasm duplicate port rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":1,"inputs":[{"name":"x","kind":"number"},{"name":"x","kind":"number"}],"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.DuplicatePort, schema.parseGraphDefinition(arena.allocator(), json));
}

test "wasm unknown kind rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":1,"inputs":[{"name":"x","kind":"nope"}],"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.UnknownPortKind, schema.parseGraphDefinition(arena.allocator(), json));
}

test "wasm malformed kind rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":1,"inputs":[{"name":"x","kind":1}],"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.MalformedKind, schema.parseGraphDefinition(arena.allocator(), json));
}
