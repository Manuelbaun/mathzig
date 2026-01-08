//! task-14 / C3 — Zig-side adversarial hardening (S3 + S4).
//!
//! Runs under `zig build test` (debug / safety checks on by default for tests).

const std = @import("std");
const mathzig = @import("mathzig");
const abi = mathzig.wasm.abi;
const schema = mathzig.graph.schema;
const manifest_mod = mathzig.graph.manifest;
const module_mod = mathzig.wasm.module;

test "abi adversarial limits are documented positives" {
    try std.testing.expect(abi.MAX_SOURCE_BYTES > 0);
    try std.testing.expect(abi.MAX_GRAPH_NODES > 0);
    try std.testing.expect(abi.MAX_GRAPH_EDGES > 0);
    try std.testing.expect(abi.MAX_MATRIX_ELEMENTS > 0);
    try std.testing.expect(abi.MAX_RECORD_ENTRIES > 0);
    try std.testing.expect(abi.MAX_IDENTIFIER_LEN > 0);
}

test "S4 parseGraphDefinition rejects SourceTooLarge pre-json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const huge = try std.testing.allocator.alloc(u8, abi.MAX_SOURCE_BYTES + 8);
    defer std.testing.allocator.free(huge);
    @memset(huge, ' ');
    @memcpy(huge[0..2], "{}");
    try std.testing.expectError(error.SourceTooLarge, schema.parseGraphDefinition(arena.allocator(), huge));
}

test "S4 parseGraphDefinition at-limit small graph PASS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"a","type":"const","value":1}],"outputs":{"a":"a.out"}}
    ;
    const def = try schema.parseGraphDefinition(arena.allocator(), json);
    try std.testing.expectEqual(@as(usize, 1), def.nodes.len);
}

test "S4 parseGraphDefinition over-limit node count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "{\"nodes\":[");
    var i: usize = 0;
    const n = abi.MAX_GRAPH_NODES + 1;
    while (i < n) : (i += 1) {
        if (i > 0) try list.append(std.testing.allocator, ',');
        const piece = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"n{d}\",\"type\":\"input\"}}", .{i});
        defer std.testing.allocator.free(piece);
        try list.appendSlice(std.testing.allocator, piece);
    }
    try list.appendSlice(std.testing.allocator, "]}");
    try std.testing.expectError(error.LimitExceeded, schema.parseGraphDefinition(arena.allocator(), list.items));
}

test "S4 parseGraphDefinition IdentifierTooLong" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var id_buf: [abi.MAX_IDENTIFIER_LEN + 8]u8 = undefined;
    @memset(id_buf[0 .. abi.MAX_IDENTIFIER_LEN + 1], 'x');
    const id = id_buf[0 .. abi.MAX_IDENTIFIER_LEN + 1];
    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"nodes\":[{{\"id\":\"{s}\",\"type\":\"input\"}}]}}", .{id});
    defer std.testing.allocator.free(json);
    try std.testing.expectError(error.IdentifierTooLong, schema.parseGraphDefinition(arena.allocator(), json));
}

test "S3 scan distinguishes absent vs malformed_wasm" {
    const valid_absent = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const r1 = manifest_mod.scanWasmNodeSectionResult(&valid_absent);
    try std.testing.expect(r1 == .absent);

    const trunc = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00 };
    const r2 = manifest_mod.scanWasmNodeSectionResult(&trunc);
    try std.testing.expect(r2 == .malformed_wasm);

    const bad_magic = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const r3 = module_mod.scanCustomSectionResult(&bad_magic, "mathzig:node");
    try std.testing.expect(r3 == .malformed_wasm);
}

test "S3 scan present mathzig:node payload" {
    // Build: magic + version + custom section name "mathzig:node" payload "{}"
    const name = "mathzig:node";
    var payload_buf: [64]u8 = undefined;
    var p: usize = 0;
    // leb name len
    payload_buf[p] = @intCast(name.len);
    p += 1;
    @memcpy(payload_buf[p .. p + name.len], name);
    p += name.len;
    @memcpy(payload_buf[p .. p + 2], "{}");
    p += 2;
    const payload = payload_buf[0..p];

    var wasm_buf: [128]u8 = undefined;
    var w: usize = 0;
    const magic = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    @memcpy(wasm_buf[w .. w + 8], &magic);
    w += 8;
    wasm_buf[w] = 0; // custom section id
    w += 1;
    wasm_buf[w] = @intCast(payload.len); // leb size (fits in 1 byte)
    w += 1;
    @memcpy(wasm_buf[w .. w + payload.len], payload);
    w += payload.len;

    const scan = manifest_mod.scanWasmNodeSectionResult(wasm_buf[0..w]);
    try std.testing.expect(scan == .present);
    try std.testing.expectEqualStrings("{}", scan.present);
}

test "S3 parseManifest still rejects bad shapes (typed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ManifestNotObject, manifest_mod.parseManifestJson(arena.allocator(), "[]"));
    try std.testing.expectError(error.IncompatibleAbiVersion, manifest_mod.parseManifestJson(arena.allocator(),
        \\{"abi":999,"inputs":[],"params":[],"output":{"kind":"number"}}
    ));
    try std.testing.expectError(error.DuplicatePort, manifest_mod.parseManifestJson(arena.allocator(),
        \\{"abi":1,"inputs":[{"name":"x","kind":"number"},{"name":"x","kind":"number"}],"output":{"kind":"number"}}
    ));
}

test "S4 load-error shape codes align with SchemaError names" {
    try std.testing.expectEqualStrings("LimitExceeded", @errorName(error.LimitExceeded));
    try std.testing.expectEqualStrings("SourceTooLarge", @errorName(error.SourceTooLarge));
    try std.testing.expectEqualStrings("IdentifierTooLong", @errorName(error.IdentifierTooLong));
}
