//! Parse `mathzig:node` JSON manifests (and optionally scan wasm custom sections).
//!
//! Shares the typed `NodeManifest` with `src/wasm/node_manifest.zig`. Native
//! schema + runner validation go through this single parser — no `"{}"` swallow.

const std = @import("std");
const node_manifest = @import("../wasm/node_manifest.zig");
const abi = @import("../wasm/abi.zig");
const wasm_module = @import("../wasm/module.zig");

pub const Port = node_manifest.Port;
pub const OutputPort = node_manifest.OutputPort;
pub const NodeManifest = node_manifest.NodeManifest;
pub const CUSTOM_SECTION_NAME = node_manifest.CUSTOM_SECTION_NAME;
pub const toJsonAlloc = node_manifest.toJsonAlloc;
pub const writeJson = node_manifest.writeJson;
pub const parseKindName = node_manifest.parseKindName;
pub const kindShortName = node_manifest.kindShortName;
pub const kindToResultTag = node_manifest.kindToResultTag;

/// Typed rejection classes for manifest parse failures (field-class names).
pub const ManifestError = error{
    /// Root value is not a JSON object (or graph `manifest` key is non-object).
    ManifestNotObject,
    /// `abi` present and ≠ `abi.ABI_VERSION`.
    IncompatibleAbiVersion,
    /// Duplicate port `name` within inputs, within params, or across both.
    DuplicatePort,
    /// Kind string not in the kind table.
    UnknownKind,
    /// Kind present but not a string (or other kind-field malformation).
    MalformedKind,
    /// Catch-all for uncategorized shape failures (missing required fields, etc.).
    InvalidManifest,
} || error{OutOfMemory};

/// Parse a `mathzig:node` JSON document into an owned NodeManifest.
/// Port name / result_tag slices live in `arena`. Port arrays are arena-owned.
pub fn parseManifestJson(arena: std.mem.Allocator, json_text: []const u8) ManifestError!NodeManifest {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch return error.InvalidManifest;
    return parseManifestValue(arena, root);
}

/// Parse an already-decoded JSON Value into a NodeManifest (schema inline path).
pub fn parseManifestValue(arena: std.mem.Allocator, root: std.json.Value) ManifestError!NodeManifest {
    if (root != .object) return error.ManifestNotObject;
    const obj = root.object;

    const name: []const u8 = if (obj.get("name")) |n|
        switch (n) {
            .string => |s| s,
            else => "eval",
        }
    else
        "eval";

    const abi_version: u32 = if (obj.get("abi")) |a| try parseAbiVersion(a) else abi.ABI_VERSION;

    var inputs: std.ArrayListUnmanaged(Port) = .empty;
    if (obj.get("inputs")) |ins| {
        if (ins != .array) return error.InvalidManifest;
        for (ins.array.items) |item| {
            try inputs.append(arena, try parsePort(item, false));
        }
    }

    var params: std.ArrayListUnmanaged(Port) = .empty;
    if (obj.get("params")) |par| {
        if (par != .array) return error.InvalidManifest;
        for (par.array.items) |item| {
            try params.append(arena, try parsePort(item, true));
        }
    }

    var output = OutputPort{ .kind = .number };
    if (obj.get("output")) |out| {
        if (out != .object) return error.InvalidManifest;
        if (out.object.get("name")) |n| {
            if (n == .string) output.name = n.string;
        }
        if (out.object.get("kind")) |k| {
            output.kind = try parseKindField(k);
        } else if (out.object.get("result_tag")) |k| {
            output.kind = try parseKindField(k);
        }
        if (out.object.get("result_tag")) |t| {
            if (t == .string) output.result_tag = t.string;
        }
    }

    const inputs_slice = try inputs.toOwnedSlice(arena);
    const params_slice = try params.toOwnedSlice(arena);
    try rejectDuplicatePorts(inputs_slice, params_slice);

    return .{
        .abi_version = abi_version,
        .name = name,
        .inputs = inputs_slice,
        .params = params_slice,
        .output = output,
    };
}

fn parseAbiVersion(a: std.json.Value) ManifestError!u32 {
    const v: u32 = switch (a) {
        .integer => |i| blk: {
            if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidManifest;
            break :blk @intCast(i);
        },
        .float => |f| blk: {
            if (!std.math.isFinite(f) or f < 0 or f > @as(f64, @floatFromInt(std.math.maxInt(u32))))
                return error.InvalidManifest;
            const as_int: u32 = @intFromFloat(f);
            if (@as(f64, @floatFromInt(as_int)) != f) return error.InvalidManifest;
            break :blk as_int;
        },
        .number_string => |s| blk: {
            const i = std.fmt.parseInt(u32, s, 10) catch return error.InvalidManifest;
            break :blk i;
        },
        else => return error.InvalidManifest,
    };
    if (v != abi.ABI_VERSION) return error.IncompatibleAbiVersion;
    return v;
}

fn parseKindField(k: std.json.Value) ManifestError!abi.WireKind {
    const kind_s = switch (k) {
        .string => |s| s,
        else => return error.MalformedKind,
    };
    return node_manifest.parseKindName(kind_s) orelse error.UnknownKind;
}

fn parsePort(item: std.json.Value, allow_default: bool) ManifestError!Port {
    if (item != .object) return error.InvalidManifest;
    const name = switch (item.object.get("name") orelse return error.InvalidManifest) {
        .string => |s| s,
        else => return error.InvalidManifest,
    };
    const kind_val = item.object.get("kind") orelse return error.InvalidManifest;
    const kind = try parseKindField(kind_val);
    var default: ?f64 = null;
    if (allow_default) {
        if (item.object.get("default")) |d| {
            default = switch (d) {
                .null => null,
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidManifest,
                else => return error.InvalidManifest,
            };
        }
    }
    return .{ .name = name, .kind = kind, .default = default };
}

/// Reject duplicate names within inputs, within params, and across inputs∪params.
fn rejectDuplicatePorts(inputs: []const Port, params: []const Port) ManifestError!void {
    for (inputs, 0..) |p, i| {
        for (inputs[i + 1 ..]) |q| {
            if (std.mem.eql(u8, p.name, q.name)) return error.DuplicatePort;
        }
    }
    for (params, 0..) |p, i| {
        for (params[i + 1 ..]) |q| {
            if (std.mem.eql(u8, p.name, q.name)) return error.DuplicatePort;
        }
    }
    for (inputs) |ip| {
        for (params) |pp| {
            if (std.mem.eql(u8, ip.name, pp.name)) return error.DuplicatePort;
        }
    }
}

/// Typed custom-section scan result (task-14 / C3). Distinct from parse errors.
pub const SectionScan = wasm_module.CustomSectionScan;

/// Scan wasm bytes for a `mathzig:node` custom section.
/// Distinguishes **absent** vs **malformed_wasm** vs **present** (JSON payload
/// slice into `wasm_bytes`). Never collapses malformed into absent.
pub fn scanWasmNodeSectionResult(wasm_bytes: []const u8) SectionScan {
    return wasm_module.scanCustomSectionResult(wasm_bytes, CUSTOM_SECTION_NAME);
}

/// Legacy: payload or null when absent **or** malformed. Prefer
/// `scanWasmNodeSectionResult` when the distinction matters.
pub fn scanWasmNodeSection(wasm_bytes: []const u8) ?[]const u8 {
    return switch (scanWasmNodeSectionResult(wasm_bytes)) {
        .present => |p| p,
        .absent, .malformed_wasm => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const gain_json =
    \\{"abi":1,"name":"gain","inputs":[{"name":"x","kind":"number"}],"params":[{"name":"k","kind":"number","default":2}],"output":{"name":"out","kind":"number","result_tag":"number"}}
;

test "parseManifestJson gain node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parseManifestJson(arena.allocator(), gain_json);
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
    try std.testing.expectError(error.ManifestNotObject, parseManifestJson(arena.allocator(), "[]"));
    try std.testing.expectError(error.ManifestNotObject, parseManifestJson(arena.allocator(), "\"x\""));
    try std.testing.expectError(error.ManifestNotObject, parseManifestJson(arena.allocator(), "1"));
}

test "parseManifestJson rejects incompatible abi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":999,"name":"gain","inputs":[],"params":[],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.IncompatibleAbiVersion, parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects duplicate input port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":"number"},{"name":"x","kind":"number"}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.DuplicatePort, parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects duplicate param port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"params":[{"name":"k","kind":"number"},{"name":"k","kind":"number","default":1}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.DuplicatePort, parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects input name equals param name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":"number"}],"params":[{"name":"x","kind":"number","default":1}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.DuplicatePort, parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects unknown kind string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":"nope"}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.UnknownKind, parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson rejects non-string kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"abi":1,"inputs":[{"name":"x","kind":1}],"output":{"kind":"number"}}
    ;
    try std.testing.expectError(error.MalformedKind, parseManifestJson(arena.allocator(), json));
}

test "parseManifestJson missing abi defaults to ABI_VERSION" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"name":"n","inputs":[],"params":[],"output":{"kind":"number"}}
    ;
    const m = try parseManifestJson(arena.allocator(), json);
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
    const sidecar = try toJsonAlloc(a, original);
    const parsed = try parseManifestJson(a, sidecar);

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
    const from_text = try parseManifestJson(a, gain_json);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, gain_json, .{});
    const from_value = try parseManifestValue(a, root);
    try std.testing.expectEqualStrings(from_text.name, from_value.name);
    try std.testing.expectEqual(from_text.abi_version, from_value.abi_version);
    try std.testing.expectEqual(from_text.inputs.len, from_value.inputs.len);
    try std.testing.expectEqual(from_text.params.len, from_value.params.len);
    try std.testing.expectEqual(from_text.inputs[0].kind, from_value.inputs[0].kind);
    try std.testing.expectApproxEqAbs(from_text.params[0].default.?, from_value.params[0].default.?, 0);
}
