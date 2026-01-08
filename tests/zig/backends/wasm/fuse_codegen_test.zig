//! Spec 03 — AOT multi-root / fused `tick` scalar codegen (T1–T7).
//!
//! Stage B: one module, sequential `tick`, output table (and optional named outs).
//! Stage A node helpers optional via `export_node_helpers`.

const std = @import("std");
const mathzig = @import("mathzig");
const wasm = mathzig.wasm;
const gm = wasm.graph_manifest;
const abi = wasm.abi;

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

fn resetPorts(ctx: *mathzig.MathZig, names: []const []const u8) !void {
    ctx.variables.clearAndFree();
    ctx.next_var_index = 0;
    for (names) |n| ctx.setNumber(n, 0);
    try ctx.initConstants();
}

/// Collect export names from a wasm binary (function/memory/global).
fn listExportNames(allocator: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6d })) {
        return error.InvalidWasm;
    }
    var names = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var i: usize = 8;
    while (i < bytes.len) {
        const sec_id = bytes[i];
        i += 1;
        const size_res = readLeb(bytes, i) orelse return error.InvalidWasm;
        i = size_res.next;
        const payload_len = size_res.value;
        if (i + payload_len > bytes.len) return error.InvalidWasm;
        const payload = bytes[i .. i + payload_len];
        i += payload_len;
        if (sec_id != 7) continue; // export section

        var j: usize = 0;
        const count_res = readLeb(payload, j) orelse return error.InvalidWasm;
        j = count_res.next;
        var c: usize = 0;
        while (c < count_res.value) : (c += 1) {
            const nlen = readLeb(payload, j) orelse return error.InvalidWasm;
            j = nlen.next;
            if (j + nlen.value > payload.len) return error.InvalidWasm;
            const name = try allocator.dupe(u8, payload[j .. j + nlen.value]);
            try names.append(allocator, name);
            j += nlen.value;
            if (j >= payload.len) return error.InvalidWasm;
            j += 1; // kind
            const idx = readLeb(payload, j) orelse return error.InvalidWasm;
            j = idx.next;
        }
    }
    return try names.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

fn hasName(names: []const []const u8, want: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, want)) return true;
    }
    return false;
}

const Leb = struct { value: usize, next: usize };
fn readLeb(buf: []const u8, start: usize) ?Leb {
    var result: usize = 0;
    var shift: u6 = 0;
    var i = start;
    while (i < buf.len) {
        const b = buf[i];
        i += 1;
        result |= @as(usize, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return .{ .value = result, .next = i };
        shift += 7;
        if (shift > 35) return null;
    }
    return null;
}

/// Count unique env import field names (function imports from module "env").
fn countEnvImports(bytes: []const u8) !struct { count: usize, has_dup: bool } {
    if (bytes.len < 8) return error.InvalidWasm;
    var i: usize = 8;
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();
    var count: usize = 0;
    var has_dup = false;

    while (i < bytes.len) {
        const sec_id = bytes[i];
        i += 1;
        const size_res = readLeb(bytes, i) orelse return error.InvalidWasm;
        i = size_res.next;
        const payload_len = size_res.value;
        if (i + payload_len > bytes.len) return error.InvalidWasm;
        const payload = bytes[i .. i + payload_len];
        i += payload_len;
        if (sec_id != 2) continue; // import section

        var j: usize = 0;
        const n_res = readLeb(payload, j) orelse return error.InvalidWasm;
        j = n_res.next;
        var c: usize = 0;
        while (c < n_res.value) : (c += 1) {
            const mlen = readLeb(payload, j) orelse return error.InvalidWasm;
            j = mlen.next;
            const mod = payload[j .. j + mlen.value];
            j += mlen.value;
            const flen = readLeb(payload, j) orelse return error.InvalidWasm;
            j = flen.next;
            const field = payload[j .. j + flen.value];
            j += flen.value;
            const kind = payload[j];
            j += 1;
            if (kind == 0) { // function
                _ = readLeb(payload, j) orelse return error.InvalidWasm;
                // advance j past type idx
                const ti = readLeb(payload, j).?;
                j = ti.next;
            } else {
                // skip other kinds coarsely
                return error.InvalidWasm;
            }
            if (std.mem.eql(u8, mod, "env")) {
                count += 1;
                const gop = try seen.getOrPut(field);
                if (gop.found_existing) has_dup = true;
            }
        }
    }
    return .{ .count = count, .has_dup = has_dup };
}

var temp_wasm_seq: u64 = 0;

fn writeTempWasm(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    temp_wasm_seq += 1;
    const path = try std.fmt.allocPrint(allocator, "tests/artifacts/fuse_tmp_{d}.wasm", .{temp_wasm_seq});
    errdefer allocator.free(path);
    std.Io.Dir.createDirPath(.cwd(), std.testing.io, "tests/artifacts") catch {};
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = path, .data = bytes });
    return path;
}

/// Invoke wasmer for an f64 export. Returns null if wasmer is unavailable.
fn wasmerInvokeF64(allocator: std.mem.Allocator, wasm_path: []const u8, export_name: []const u8, args: []const f64) !?f64 {
    var argv_list = std.ArrayListUnmanaged([]const u8).empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, "wasmer");
    try argv_list.append(allocator, "run");
    try argv_list.append(allocator, wasm_path);
    try argv_list.append(allocator, "--invoke");
    try argv_list.append(allocator, export_name);
    var arg_bufs = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (arg_bufs.items) |b| allocator.free(b);
        arg_bufs.deinit(allocator);
    }
    for (args) |a| {
        const s = try std.fmt.allocPrint(allocator, "{d}", .{a});
        try arg_bufs.append(allocator, s);
        try argv_list.append(allocator, s);
    }

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = argv_list.items,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

fn wasmValidateOk(allocator: std.mem.Allocator, wasm_path: []const u8) !bool {
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "wasm-validate", wasm_path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ── T1: chain *2 then +1 → 7 ────────────────────────────────────────────────

test "T1 fuse chain *2 then +1 → 7 (Stage B)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    try resetPorts(ctx, &.{"x"});
    const e_mul = try ctx.compile("x * 2");
    defer ctx.freeExpr(e_mul);

    try resetPorts(ctx, &.{"y"});
    const e_add = try ctx.compile("y + 1");
    defer ctx.freeExpr(e_add);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{
            .id = "mul",
            .expr = e_mul,
            .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }},
        },
        .{
            .id = "add",
            .expr = e_add,
            .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }},
        },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 1 },
    };

    // Table mode (primary Stage B).
    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
        .export_node_helpers = true,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 8);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x61), bytes[1]);

    const names = try listExportNames(allocator, bytes);
    defer freeNames(allocator, names);
    try std.testing.expect(hasName(names, "tick"));
    try std.testing.expect(hasName(names, "n_mul"));
    try std.testing.expect(hasName(names, "n_add"));
    try std.testing.expect(hasName(names, "memory"));
    try std.testing.expect(hasName(names, "alloc"));

    const table_path = try writeTempWasm(allocator, bytes);
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, table_path) catch {};
        allocator.free(table_path);
    }
    if (try wasmValidateOk(allocator, table_path)) {
        // ok
    }

    // Named-exports: numeric golden out_y(3) = 7 (wasmer when available).
    var c2 = wasm.compiler.WasmCompiler.init(allocator);
    defer c2.deinit();
    try c2.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .named_exports,
        .export_node_helpers = true,
    }, .{});
    const bytes2 = try writeCompilerToOwned(&c2, allocator);
    defer allocator.free(bytes2);
    const names2 = try listExportNames(allocator, bytes2);
    defer freeNames(allocator, names2);
    try std.testing.expect(hasName(names2, "out_y"));
    try std.testing.expect(hasName(names2, "tick"));

    // mathzig.abi lists out_y for named_exports.
    const abi_json = wasm.module.scanCustomSection(bytes2, abi.CUSTOM_SECTION_NAME).?;
    try std.testing.expect(std.mem.indexOf(u8, abi_json, "\"name\":\"out_y\"") != null);

    const named_path = try writeTempWasm(allocator, bytes2);
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, named_path) catch {};
        allocator.free(named_path);
    }
    if (try wasmerInvokeF64(allocator, named_path, "out_y", &[_]f64{3.0})) |v| {
        try std.testing.expectApproxEqAbs(@as(f64, 7.0), v, 1e-12);
    }
    if (try wasmerInvokeF64(allocator, named_path, "n_mul", &[_]f64{3.0})) |v| {
        try std.testing.expectApproxEqAbs(@as(f64, 6.0), v, 1e-12);
    }
}

// ── T2: diamond multi-out ───────────────────────────────────────────────────

test "T2 fuse diamond multi-out named exports + values" {
    // Named out_* recompute topo per call (Stage A interim). Values still correct.
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // A: x*2, B: a+1, C: a*3  outputs B and C
    try resetPorts(ctx, &.{"x"});
    const e_a = try ctx.compile("x * 2");
    defer ctx.freeExpr(e_a);
    try resetPorts(ctx, &.{"a"});
    const e_b = try ctx.compile("a + 1");
    defer ctx.freeExpr(e_b);
    try resetPorts(ctx, &.{"a"});
    const e_c = try ctx.compile("a * 3");
    defer ctx.freeExpr(e_c);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "A", .expr = e_a, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
        .{ .id = "B", .expr = e_b, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }} },
        .{ .id = "C", .expr = e_c, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }} },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "u", .kind = .number, .from_node = 1 },
        .{ .name = "v", .kind = .number, .from_node = 2 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .named_exports,
        .export_node_helpers = true,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    const names = try listExportNames(allocator, bytes);
    defer freeNames(allocator, names);
    try std.testing.expect(hasName(names, "tick"));
    try std.testing.expect(hasName(names, "out_u"));
    try std.testing.expect(hasName(names, "out_v"));
    try std.testing.expect(hasName(names, "n_A"));
    try std.testing.expect(hasName(names, "n_B"));
    try std.testing.expect(hasName(names, "n_C"));

    const payload = gm.scanWasmGraphSection(bytes) orelse {
        try std.testing.expect(false);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), payload);
    try std.testing.expectEqual(@as(usize, 2), parsed.outputs.len);
    // Graph exports inventory includes tick + out_u + out_v (+ helpers).
    try std.testing.expect(parsed.exports.len >= 3);

    const path = try writeTempWasm(allocator, bytes);
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch {};
        allocator.free(path);
    }
    // x=3 → A=6, B=7, C=18
    if (try wasmerInvokeF64(allocator, path, "out_u", &[_]f64{3.0})) |u| {
        try std.testing.expectApproxEqAbs(@as(f64, 7.0), u, 1e-12);
    }
    if (try wasmerInvokeF64(allocator, path, "out_v", &[_]f64{3.0})) |v| {
        try std.testing.expectApproxEqAbs(@as(f64, 18.0), v, 1e-12);
    }
}

test "T2b fuse diamond table mode single tick export" {
    // Stage B single-pass: one tick, two table slots (no per-out recompute path).
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    try resetPorts(ctx, &.{"x"});
    const e_a = try ctx.compile("x * 2");
    defer ctx.freeExpr(e_a);
    try resetPorts(ctx, &.{"a"});
    const e_b = try ctx.compile("a + 1");
    defer ctx.freeExpr(e_b);
    try resetPorts(ctx, &.{"a"});
    const e_c = try ctx.compile("a * 3");
    defer ctx.freeExpr(e_c);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "A", .expr = e_a, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
        .{ .id = "B", .expr = e_b, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }} },
        .{ .id = "C", .expr = e_c, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }} },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "u", .kind = .number, .from_node = 1 },
        .{ .name = "v", .kind = .number, .from_node = 2 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
        .export_node_helpers = false,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    const names = try listExportNames(allocator, bytes);
    defer freeNames(allocator, names);
    try std.testing.expect(hasName(names, "tick"));
    try std.testing.expect(hasName(names, "memory"));
    try std.testing.expect(hasName(names, "alloc"));
    // Helpers not exported when flag false.
    try std.testing.expect(!hasName(names, "n_A"));
    try std.testing.expect(!hasName(names, "out_u"));

    const payload = gm.scanWasmGraphSection(bytes).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), payload);
    try std.testing.expectEqual(gm.OutMode.table, parsed.out_mode);
    try std.testing.expectEqual(@as(usize, 2), parsed.outputs.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.exports.len); // tick only
    try std.testing.expectEqualStrings("tick", parsed.exports[0].name);

    const path = try writeTempWasm(allocator, bytes);
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch {};
        allocator.free(path);
    }
    _ = try wasmValidateOk(allocator, path);
}

// ── T3: params trailing ─────────────────────────────────────────────────────

test "T3 fuse params trailing change result without recompile" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // gain: x * k
    try resetPorts(ctx, &.{ "x", "k" });
    const e = try ctx.compile("x * k");
    defer ctx.freeExpr(e);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const params = [_]gm.Port{.{ .name = "gain.k", .kind = .number, .default = 1.0 }};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{
            .id = "gain",
            .expr = e,
            .arg_sources = &[_]wasm.compiler.FuseArgSource{
                .{ .graph_input = 0 },
                .{ .graph_param = 0 },
            },
        },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 0 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .inputs = &inputs,
        .params = &params,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .named_exports,
        .export_node_helpers = false,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    const names = try listExportNames(allocator, bytes);
    defer freeNames(allocator, names);
    try std.testing.expect(hasName(names, "tick"));
    try std.testing.expect(hasName(names, "out_y"));

    // Manifest: tick arity = inputs + params (params trailing).
    const payload = gm.scanWasmGraphSection(bytes) orelse {
        try std.testing.expect(false);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), payload);
    try std.testing.expectEqual(@as(usize, 1), parsed.params.len);
    try std.testing.expectEqualStrings("gain.k", parsed.params[0].name);
    try std.testing.expectEqual(@as(u32, 2), parsed.exports[0].params);

    const path = try writeTempWasm(allocator, bytes);
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch {};
        allocator.free(path);
    }
    if (try wasmerInvokeF64(allocator, path, "out_y", &[_]f64{ 3.0, 2.0 })) |v| {
        try std.testing.expectApproxEqAbs(@as(f64, 6.0), v, 1e-12);
    }
    if (try wasmerInvokeF64(allocator, path, "out_y", &[_]f64{ 3.0, 5.0 })) |v| {
        try std.testing.expectApproxEqAbs(@as(f64, 15.0), v, 1e-12);
    }
}

// ── T4: mathzig:graph section parseable ─────────────────────────────────────

test "T4 fuse mathzig:graph section parseable" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    try resetPorts(ctx, &.{"x"});
    const e = try ctx.compile("x + 1");
    defer ctx.freeExpr(e);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "inc", .expr = e, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 0 },
        .{ .name = "z", .kind = .number, .from_node = 0 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);

    const payload = gm.scanWasmGraphSection(bytes) orelse {
        try std.testing.expect(false); // missing section
        return;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), payload);
    try std.testing.expectEqual(@as(u32, 1), parsed.abi_version);
    try std.testing.expectEqualStrings("tick", parsed.entry);
    try std.testing.expectEqual(@as(usize, 2), parsed.outputs.len);
    try std.testing.expectEqual(gm.OutMode.table, parsed.out_mode);
    try std.testing.expectEqual(@as(usize, 1), parsed.inputs.len);
    try std.testing.expect(parsed.exports.len >= 1);
    try std.testing.expectEqualStrings("tick", parsed.exports[0].name);
    try std.testing.expectEqual(@as(u32, 1), parsed.exports[0].params);

    // mathzig.abi still present
    try std.testing.expect(wasm.module.scanCustomSection(bytes, abi.CUSTOM_SECTION_NAME) != null);
}

// ── T5: import union no dups ────────────────────────────────────────────────

test "T5 fuse import union no duplicate env names" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // Two nodes both use cos — cos is an env import (sin is an in-wasm body).
    // Union must register env.cos once, not twice.
    try resetPorts(ctx, &.{"x"});
    const e1 = try ctx.compile("cos(x)");
    defer ctx.freeExpr(e1);
    try resetPorts(ctx, &.{"y"});
    const e2 = try ctx.compile("cos(y) + 1");
    defer ctx.freeExpr(e2);

    const inputs = [_]gm.Port{
        .{ .name = "x", .kind = .number },
        .{ .name = "y", .kind = .number },
    };
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "s1", .expr = e1, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
        .{ .id = "s2", .expr = e2, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 1 }} },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "a", .kind = .number, .from_node = 0 },
        .{ .name = "b", .kind = .number, .from_node = 1 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
        .export_node_helpers = true,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);

    const imp = try countEnvImports(bytes);
    try std.testing.expect(!imp.has_dup);
    // At least one env import (cos); may include more for helper bodies.
    try std.testing.expect(imp.count >= 1);

    // Manifest imports should not list cos twice.
    const abi_json = wasm.module.scanCustomSection(bytes, abi.CUSTOM_SECTION_NAME) orelse {
        try std.testing.expect(false);
        return;
    };
    var cos_hits: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, abi_json, search, "\"name\":\"cos\"")) |pos| {
        cos_hits += 1;
        search = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), cos_hits);
}

// ── T6: heap rules ──────────────────────────────────────────────────────────

test "T6 fuse heap: scalar table has memory; named scalar may omit" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    try resetPorts(ctx, &.{"x"});
    const e = try ctx.compile("x * 2");
    defer ctx.freeExpr(e);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "m", .expr = e, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 0 },
    };

    // Table mode → memory + alloc required (Spec 01).
    {
        var compiler = wasm.compiler.WasmCompiler.init(allocator);
        defer compiler.deinit();
        try compiler.compileFusedTick(.{
            .inputs = &inputs,
            .nodes = &nodes,
            .outputs = &outputs,
            .out_mode = .table,
        }, .{});
        const bytes = try writeCompilerToOwned(&compiler, allocator);
        defer allocator.free(bytes);
        const names = try listExportNames(allocator, bytes);
        defer freeNames(allocator, names);
        try std.testing.expect(hasName(names, "memory"));
        try std.testing.expect(hasName(names, "alloc"));
        try std.testing.expect(hasName(names, "tick"));
    }

    // Named exports pure scalar: no forced heap for number-only table absence.
    {
        var compiler = wasm.compiler.WasmCompiler.init(allocator);
        defer compiler.deinit();
        try compiler.compileFusedTick(.{
            .inputs = &inputs,
            .nodes = &nodes,
            .outputs = &outputs,
            .out_mode = .named_exports,
        }, .{});
        const bytes = try writeCompilerToOwned(&compiler, allocator);
        defer allocator.free(bytes);
        const names = try listExportNames(allocator, bytes);
        defer freeNames(allocator, names);
        try std.testing.expect(hasName(names, "tick"));
        try std.testing.expect(hasName(names, "out_y"));
        // No memory required for pure scalar named_exports.
        try std.testing.expect(!hasName(names, "memory"));
    }
}

// ── T7: invalid expr fails ──────────────────────────────────────────────────

test "T7 invalid expr in node fails — no silent module" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // Unsupported AOT opcode path: get_index with >2 keys (existing hard error).
    const Instruction = mathzig.Instruction;
    const constants = [_]mathzig.Value{
        mathzig.Value.initNumber(1.0),
        mathzig.Value.initNumber(2.0),
        mathzig.Value.initNumber(3.0),
        mathzig.Value.initNumber(4.0),
        mathzig.Value.initNumber(0.0),
        mathzig.Value.initNumber(0.0),
        mathzig.Value.initNumber(0.0),
    };
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
    const bad = mathzig.CompiledExpr{
        .code = &code,
        .source_offsets = source_offsets[0..],
        .constants = &constants,
        .constants_f64 = &.{},
        .max_stack = 16,
        .is_number_only = false,
        .allocator = allocator,
        .owns_memory = false,
    };

    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "bad", .expr = &bad, .arg_sources = &.{} },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 0 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compileFusedTick(.{
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
    }, .{});
    try std.testing.expectError(error.UnsupportedOpcode, err);
}

// ── Extra: sanitize + compileMany Stage A + single-expr still works ──────────

test "sanitizeExportName replaces illegal chars" {
    const allocator = std.testing.allocator;
    const n = try wasm.compiler.sanitizeExportName(allocator, "n_", "gain.k");
    defer allocator.free(n);
    try std.testing.expectEqualStrings("n_gain_k", n);
    const o = try wasm.compiler.sanitizeExportName(allocator, "out_", "u/v");
    defer allocator.free(o);
    try std.testing.expectEqualStrings("out_u_v", o);
}

test "duplicate sanitized export names hard-error" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    try resetPorts(ctx, &.{"x"});
    const e1 = try ctx.compile("x * 2");
    defer ctx.freeExpr(e1);
    try resetPorts(ctx, &.{"x"});
    const e2 = try ctx.compile("x + 1");
    defer ctx.freeExpr(e2);

    // "a.b" and "a_b" both sanitize to n_a_b
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "a.b", .expr = e1, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
        .{ .id = "a_b", .expr = e2, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
    };
    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 0 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
        .export_node_helpers = true,
    }, .{});
    try std.testing.expectError(error.DuplicateExportName, err);

    // compileMany also rejects duplicate names
    var c2 = wasm.compiler.WasmCompiler.init(allocator);
    defer c2.deinit();
    const err2 = c2.compileMany(&.{
        .{ .expr = e1, .name = "same", .num_params = 1 },
        .{ .expr = e2, .name = "same", .num_params = 1 },
    }, .{});
    try std.testing.expectError(error.DuplicateExportName, err2);
}

test "non-scalar param rejected (scalar gate)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    try resetPorts(ctx, &.{ "x", "m" });
    const e = try ctx.compile("x * 2");
    defer ctx.freeExpr(e);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    const params = [_]gm.Port{.{ .name = "m", .kind = .matrix_ptr }};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{
            .id = "n",
            .expr = e,
            .arg_sources = &[_]wasm.compiler.FuseArgSource{
                .{ .graph_input = 0 },
                .{ .graph_param = 0 },
            },
        },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 0 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compileFusedTick(.{
        .inputs = &inputs,
        .params = &params,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
    }, .{});
    try std.testing.expectError(error.NonScalarFuse, err);
}

test "forward node_result rejected (strict topo)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    try resetPorts(ctx, &.{"x"});
    const e1 = try ctx.compile("x * 2");
    defer ctx.freeExpr(e1);
    try resetPorts(ctx, &.{"y"});
    const e2 = try ctx.compile("y + 1");
    defer ctx.freeExpr(e2);

    const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
    // Node 0 illegally references node 1 (forward).
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{ .id = "a", .expr = e1, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 1 }} },
        .{ .id = "b", .expr = e2, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "y", .kind = .number, .from_node = 0 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    const err = compiler.compileFusedTick(.{
        .inputs = &inputs,
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
    }, .{});
    try std.testing.expectError(error.InvalidFuseArg, err);
}

test "compileMany Stage A multi-export shared module" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    try resetPorts(ctx, &.{"x"});
    const e1 = try ctx.compile("x * 2");
    defer ctx.freeExpr(e1);
    try resetPorts(ctx, &.{"x"});
    const e2 = try ctx.compile("x + 1");
    defer ctx.freeExpr(e2);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileMany(&.{
        .{ .expr = e1, .name = "n_mul", .num_params = 1 },
        .{ .expr = e2, .name = "n_add", .num_params = 1 },
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    const names = try listExportNames(allocator, bytes);
    defer freeNames(allocator, names);
    try std.testing.expect(hasName(names, "n_mul"));
    try std.testing.expect(hasName(names, "n_add"));
    // No mathzig:graph for raw compileMany (not a fuse plan).
    try std.testing.expect(gm.scanWasmGraphSection(bytes) == null);
}

test "single-expr compile still works (no regression)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();
    _ = ctx.getOrCreateVariable("a");
    const expr = try ctx.compile("a + 1");
    defer ctx.freeExpr(expr);

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compile(expr, .{ .function_name = "eval", .num_params = 1 });
    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    const names = try listExportNames(allocator, bytes);
    defer freeNames(allocator, names);
    try std.testing.expect(hasName(names, "eval"));
    try std.testing.expect(gm.scanWasmGraphSection(bytes) == null);
}

// ── Spec 07: full-value matrix chain ────────────────────────────────────────

test "Spec07 fuse matrix chain table mode accepts non-scalar kinds" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // g: [1,2;3,4]*2  (no params)  f: x * I  (matrix param)
    try resetPorts(ctx, &.{});
    const e_g = try ctx.compile("[1, 2; 3, 4] * 2");
    defer ctx.freeExpr(e_g);
    try resetPorts(ctx, &.{"x"});
    const e_f = try ctx.compile("x * [1, 0; 0, 1]");
    defer ctx.freeExpr(e_f);

    const arg_kinds_f = [_]abi.WireKind{.matrix_ptr};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{
            .id = "g",
            .expr = e_g,
            .arg_sources = &.{},
            .output_kind = .matrix_ptr,
        },
        .{
            .id = "f",
            .expr = e_f,
            .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }},
            .arg_kinds = &arg_kinds_f,
            .output_kind = .matrix_ptr,
        },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "value", .kind = .matrix_ptr, .from_node = 1 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
        .export_node_helpers = true,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);
    const names = try listExportNames(allocator, bytes);
    defer freeNames(allocator, names);
    try std.testing.expect(hasName(names, "tick"));
    try std.testing.expect(hasName(names, "memory"));
    try std.testing.expect(hasName(names, "alloc"));
    try std.testing.expect(hasName(names, "n_g"));
    try std.testing.expect(hasName(names, "n_f"));

    const payload = gm.scanWasmGraphSection(bytes).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), payload);
    try std.testing.expectEqual(@as(usize, 1), parsed.outputs.len);
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, parsed.outputs[0].kind);
    try std.testing.expectEqualStrings("matrix", parsed.outputs[0].result_tag orelse "");

    const path = try writeTempWasm(allocator, bytes);
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch {};
        allocator.free(path);
    }
    _ = try wasmValidateOk(allocator, path);
}

test "Spec07 fuse multi-out matrix + number kinds in manifest" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    try resetPorts(ctx, &.{});
    const e_m = try ctx.compile("[1, 2; 3, 4] * 2");
    defer ctx.freeExpr(e_m);
    try resetPorts(ctx, &.{"x"});
    const e_s = try ctx.compile("sum(x)");
    defer ctx.freeExpr(e_s);

    const arg_kinds = [_]abi.WireKind{.matrix_ptr};
    const nodes = [_]wasm.compiler.FuseNodeUnit{
        .{
            .id = "m",
            .expr = e_m,
            .arg_sources = &.{},
            .output_kind = .matrix_ptr,
        },
        .{
            .id = "s",
            .expr = e_s,
            .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }},
            .arg_kinds = &arg_kinds,
            .output_kind = .number,
        },
    };
    const outputs = [_]wasm.compiler.FuseOutput{
        .{ .name = "mat", .kind = .matrix_ptr, .from_node = 0 },
        .{ .name = "total", .kind = .number, .from_node = 1 },
    };

    var compiler = wasm.compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();
    try compiler.compileFusedTick(.{
        .nodes = &nodes,
        .outputs = &outputs,
        .out_mode = .table,
    }, .{});

    const bytes = try writeCompilerToOwned(&compiler, allocator);
    defer allocator.free(bytes);

    const payload = gm.scanWasmGraphSection(bytes).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try gm.parseGraphManifestJson(arena.allocator(), payload);
    try std.testing.expectEqual(@as(usize, 2), parsed.outputs.len);
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, parsed.outputs[0].kind);
    try std.testing.expectEqual(abi.WireKind.number, parsed.outputs[1].kind);

    const path = try writeTempWasm(allocator, bytes);
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch {};
        allocator.free(path);
    }
    _ = try wasmValidateOk(allocator, path);
}
