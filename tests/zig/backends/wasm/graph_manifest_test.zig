//! Spec 01 — graph_manifest write / parse / emit / scan (single source of truth).
//! Embedded tests were intentionally not left in `src/wasm/graph_manifest.zig`
//! (that module is not a test root under the nested `wasm.*` package layout).

const std = @import("std");
const mathzig = @import("mathzig");
const gm = mathzig.wasm.graph_manifest;
const module_mod = mathzig.wasm.module;
const abi = mathzig.wasm.abi;

test "writeJson ↔ parse equality for fixture (T1)" {
    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const params = [_]gm.Port{.{ .name = "gain.k", .kind = .number, .default = 1.0 }};
    const outputs = [_]gm.GraphOutputPort{
        .{ .name = "u", .kind = .number, .result_tag = "number" },
        .{ .name = "v", .kind = .number, .result_tag = "number" },
    };
    const exports_ = [_]gm.ExportEntry{.{ .name = "tick", .params = 2 }};
    const m = gm.GraphManifest{
        .entry = "tick",
        .inputs = &inputs,
        .params = &params,
        .outputs = &outputs,
        .out_mode = .table,
        .exports = &exports_,
    };

    const json = try gm.toJsonAlloc(std.testing.allocator, m);
    defer std.testing.allocator.free(json);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), json);

    try std.testing.expectEqual(@as(u32, 1), parsed.abi_version);
    try std.testing.expectEqualStrings("tick", parsed.entry);
    try std.testing.expectEqual(@as(usize, 1), parsed.inputs.len);
    try std.testing.expectEqualStrings("x", parsed.inputs[0].name);
    try std.testing.expectEqual(abi.WireKind.number, parsed.inputs[0].kind);
    try std.testing.expectEqual(@as(usize, 1), parsed.params.len);
    try std.testing.expectEqualStrings("gain.k", parsed.params[0].name);
    try std.testing.expect(parsed.params[0].default != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), parsed.params[0].default.?, 0);
    try std.testing.expectEqual(@as(usize, 2), parsed.outputs.len);
    try std.testing.expectEqualStrings("u", parsed.outputs[0].name);
    try std.testing.expectEqualStrings("v", parsed.outputs[1].name);
    try std.testing.expectEqual(gm.OutMode.table, parsed.out_mode);
    try std.testing.expectEqual(@as(usize, 1), parsed.exports.len);
    try std.testing.expectEqualStrings("tick", parsed.exports[0].name);
    try std.testing.expectEqual(@as(u32, 2), parsed.exports[0].params);
}

test "writeJson named_exports includes export field" {
    const outputs = [_]gm.GraphOutputPort{
        .{ .name = "u", .kind = .number, .export_name = "out_u" },
        .{ .name = "v", .kind = .matrix_ptr, .export_name = "out_v" },
    };
    const m = gm.GraphManifest{
        .outputs = &outputs,
        .out_mode = .named_exports,
        .exports = &[_]gm.ExportEntry{.{ .name = "out_u", .params = 0 }},
    };
    const json = try gm.toJsonAlloc(std.testing.allocator, m);
    defer std.testing.allocator.free(json);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), json);
    try std.testing.expectEqual(gm.OutMode.named_exports, parsed.out_mode);
    try std.testing.expectEqualStrings("out_u", parsed.outputs[0].export_name.?);
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, parsed.outputs[1].kind);
    try std.testing.expectEqualStrings("matrix", gm.kindToResultTag(parsed.outputs[1].kind));
}

test "emitCustomSection scan round-trip (T2)" {
    var mod = module_mod.WasmModule.init(std.testing.allocator);
    defer mod.deinit();

    const outputs = [_]gm.GraphOutputPort{
        .{ .name = "y", .kind = .number, .result_tag = "number" },
    };
    const m = gm.GraphManifest{
        .outputs = &outputs,
        .out_mode = .table,
        .exports = &[_]gm.ExportEntry{.{ .name = "tick", .params = 0 }},
    };
    try gm.emitCustomSection(&mod, std.testing.allocator, m);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try mod.writeTo(&out.writer);

    const payload = gm.scanWasmGraphSection(out.written()) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings(gm.CUSTOM_SECTION_NAME, "mathzig:graph");
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"out_mode\":\"table\"") != null);

    // Shared scanner: same payload via module.scanCustomSection
    const via_shared = module_mod.scanCustomSection(out.written(), gm.CUSTOM_SECTION_NAME);
    try std.testing.expect(via_shared != null);
    try std.testing.expectEqualStrings(payload, via_shared.?);
}

test "scanWasmGraphSection returns null when absent" {
    const bare = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expect(gm.scanWasmGraphSection(&bare) == null);
    try std.testing.expect(module_mod.scanCustomSection(&bare, "mathzig:node") == null);
}

test "validate rejects empty outputs; emit refuses empty (T5)" {
    try std.testing.expectError(error.EmptyOutputs, gm.validate(.{}));

    var mod = module_mod.WasmModule.init(std.testing.allocator);
    defer mod.deinit();
    try std.testing.expectError(error.EmptyOutputs, gm.emitCustomSection(&mod, std.testing.allocator, .{}));
}

test "parse rejects unknown kind and invalid out_mode (T5)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(
        error.UnknownKind,
        gm.parseGraphManifestJson(a,
            \\{"outputs":[{"name":"y","kind":"not_a_kind"}]}
        ),
    );
    try std.testing.expectError(
        error.InvalidOutMode,
        gm.parseGraphManifestJson(a,
            \\{"outputs":[{"name":"y","kind":"number"}],"out_mode":"magic"}
        ),
    );
    try std.testing.expectError(
        error.EmptyOutputs,
        gm.parseGraphManifestJson(a,
            \\{"outputs":[]}
        ),
    );
}

test "graph_manifest reuses WireKind short names" {
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, gm.parseKindName("matrix").?);
    try std.testing.expectEqualStrings("matrix", gm.kindShortName(.matrix_ptr));
    try std.testing.expectEqualStrings("matrix", gm.kindToResultTag(.matrix_ptr));
    try std.testing.expectEqual(gm.GRAPH_ABI_VERSION, @as(u32, 1));
}
