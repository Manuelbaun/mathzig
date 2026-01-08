//! Fused graph-module manifest (`mathzig:graph` custom section + JSON sidecar).
//!
//! Describes multi-input / multi-param / multi-output value ports of a single
//! AOT-fused wasm module so hosts can introspect I/O without re-parsing the
//! graph. Wire kinds reuse `abi.WireKind` via `node_manifest` helpers — no
//! second kind enum.
//!
//! # Normative multi-value I/O contract (`abi: 1`)
//!
//! - **Inputs then params**: ordered graph inputs, then ordered params.
//!   Each port is `{ name, kind }` with short kind names from
//!   `node_manifest.kindShortName` (number, boolean, matrix, complex, record,
//!   string, series, predicate, any). Params may carry `default: number | null`.
//! - **Outputs**: always a **list of values** (names live in the manifest).
//!   `out_mode` selects how the module surfaces them at the wasm boundary:
//!   - `"table"` (preferred default): after `tick`, host reads an output table
//!     from linear memory (base = i32 ptr returned by tick, or fixed offset):
//!     ```text
//!     [u32 count]
//!     repeated count times:
//!       [u32 kind_tag]   // abi.WireKind discriminant
//!       [f64 wire]       // number payload or ptr/handle as f64 bits
//!     ```
//!   - `"named_exports"`: each output may name a wasm export (`"export": "out_u"`).
//! - **Entry**: preferred single host entry is `entry` (default `"tick"`).
//! - **Kind ↔ result_tag**: reuse `node_manifest.kindToResultTag` /
//!   `parseKindName` (number→number, matrix_ptr→matrix, …).
//!
//! # Validation surface
//!
//! - Typed `GraphManifest` / `validate`: rejects empty `outputs` only (kinds are
//!   already `abi.WireKind` at this layer).
//! - JSON/host boundary: `parseGraphManifestJson` rejects unknown kind strings
//!   (`UnknownKind`), bad `out_mode` (`InvalidOutMode`), empty outputs, and
//!   structural garbage (`InvalidManifest`).
//! - `emitCustomSection` always runs `validate` so empty-output sections never
//!   land in a `.wasm`.
//!
//! Fused modules use this section instead of `mathzig:node` (single-node).
//! `mathzig.abi` may still be emitted for primary-export compiler metadata.
//!
//! Unit tests live in `tests/zig/backends/wasm/graph_manifest_test.zig` (single
//! source of truth; this module is not a test root).

const std = @import("std");
const abi = @import("abi.zig");
const list_writer = @import("list_writer.zig");
const node_manifest = @import("node_manifest.zig");
const module_mod = @import("module.zig");

/// Custom-section name (distinct from `mathzig:node` and `mathzig.abi`).
pub const CUSTOM_SECTION_NAME = "mathzig:graph";

/// Graph-manifest ABI version (independent of node-manifest / mathzig.abi).
pub const GRAPH_ABI_VERSION: u32 = 1;

/// Re-export port type shared with single-node manifests.
pub const Port = node_manifest.Port;

/// Kind helpers (no parallel enum — reuse node_manifest / abi.WireKind).
pub const parseKindName = node_manifest.parseKindName;
pub const kindShortName = node_manifest.kindShortName;
pub const kindToResultTag = node_manifest.kindToResultTag;

/// How multi-output values are exposed on the wasm boundary.
pub const OutMode = enum {
    /// Output table in linear memory (preferred default).
    table,
    /// Named exports `out_<name>` / explicit `export` field (scalar shortcut).
    named_exports,

    pub fn jsonName(self: OutMode) []const u8 {
        return switch (self) {
            .table => "table",
            .named_exports => "named_exports",
        };
    }

    pub fn parse(name: []const u8) ?OutMode {
        if (std.mem.eql(u8, name, "table")) return .table;
        if (std.mem.eql(u8, name, "named_exports")) return .named_exports;
        return null;
    }
};

/// One output value port (multi-out list; names only in manifest for table mode).
pub const GraphOutputPort = struct {
    name: []const u8,
    kind: abi.WireKind,
    /// `mathzig.abi` result_tag style; optional when derivable from `kind`.
    result_tag: ?[]const u8 = null,
    /// Wasm export name when `out_mode == named_exports` (e.g. `"out_u"`).
    export_name: ?[]const u8 = null,
};

/// Declared wasm export used by the fused module (params = f64 arity).
pub const ExportEntry = struct {
    name: []const u8,
    params: u32,
};

pub const GraphManifest = struct {
    /// Manifest ABI version (start at 1; independent of node-manifest).
    abi_version: u32 = GRAPH_ABI_VERSION,
    /// Preferred single host entry export name.
    entry: []const u8 = "tick",
    inputs: []const Port = &.{},
    params: []const Port = &.{},
    outputs: []const GraphOutputPort = &.{},
    out_mode: OutMode = .table,
    exports: []const ExportEntry = &.{},
};

/// Errors from `validate` on an already-typed manifest.
pub const ValidateError = error{
    EmptyOutputs,
};

/// Errors from JSON / host-boundary parse (`parseGraphManifestJson`).
pub const ParseError = error{
    InvalidManifest,
    EmptyOutputs,
    UnknownKind,
    InvalidOutMode,
} || error{OutOfMemory};

/// Structural checks for a typed `GraphManifest`.
///
/// Kinds are already `abi.WireKind` here, so unknown-kind rejection happens in
/// `parseGraphManifestJson` (string → WireKind) — not in this function.
pub fn validate(manifest: GraphManifest) ValidateError!void {
    if (manifest.outputs.len == 0) return error.EmptyOutputs;
}

/// Parse a `mathzig:graph` JSON document into an arena-owned `GraphManifest`.
/// Port name / result_tag / entry / export name slices live in `arena`.
pub fn parseGraphManifestJson(arena: std.mem.Allocator, json_text: []const u8) ParseError!GraphManifest {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch return error.InvalidManifest;
    if (root != .object) return error.InvalidManifest;
    const obj = root.object;

    const abi_version: u32 = if (obj.get("abi")) |a| blk: {
        break :blk switch (a) {
            .integer => |i| @intCast(i),
            .float => |f| @intFromFloat(f),
            else => return error.InvalidManifest,
        };
    } else GRAPH_ABI_VERSION;

    const entry: []const u8 = if (obj.get("entry")) |e|
        switch (e) {
            .string => |s| s,
            else => return error.InvalidManifest,
        }
    else
        "tick";

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

    var outputs: std.ArrayListUnmanaged(GraphOutputPort) = .empty;
    if (obj.get("outputs")) |outs| {
        if (outs != .array) return error.InvalidManifest;
        for (outs.array.items) |item| {
            try outputs.append(arena, try parseOutput(item));
        }
    }

    const out_mode: OutMode = if (obj.get("out_mode")) |om| blk: {
        if (om != .string) return error.InvalidManifest;
        break :blk OutMode.parse(om.string) orelse return error.InvalidOutMode;
    } else .table;

    var exports_list: std.ArrayListUnmanaged(ExportEntry) = .empty;
    if (obj.get("exports")) |exs| {
        if (exs != .array) return error.InvalidManifest;
        for (exs.array.items) |item| {
            try exports_list.append(arena, try parseExport(item));
        }
    }

    const m = GraphManifest{
        .abi_version = abi_version,
        .entry = entry,
        .inputs = try inputs.toOwnedSlice(arena),
        .params = try params.toOwnedSlice(arena),
        .outputs = try outputs.toOwnedSlice(arena),
        .out_mode = out_mode,
        .exports = try exports_list.toOwnedSlice(arena),
    };
    try validate(m);
    return m;
}

fn parsePort(item: std.json.Value, allow_default: bool) ParseError!Port {
    if (item != .object) return error.InvalidManifest;
    const name = switch (item.object.get("name") orelse return error.InvalidManifest) {
        .string => |s| s,
        else => return error.InvalidManifest,
    };
    const kind_s = switch (item.object.get("kind") orelse return error.InvalidManifest) {
        .string => |s| s,
        else => return error.InvalidManifest,
    };
    const kind = parseKindName(kind_s) orelse return error.UnknownKind;
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

fn parseOutput(item: std.json.Value) ParseError!GraphOutputPort {
    if (item != .object) return error.InvalidManifest;
    const name = switch (item.object.get("name") orelse return error.InvalidManifest) {
        .string => |s| s,
        else => return error.InvalidManifest,
    };
    const kind_s = switch (item.object.get("kind") orelse return error.InvalidManifest) {
        .string => |s| s,
        else => return error.InvalidManifest,
    };
    const kind = parseKindName(kind_s) orelse return error.UnknownKind;
    var result_tag: ?[]const u8 = null;
    if (item.object.get("result_tag")) |t| {
        if (t != .string) return error.InvalidManifest;
        result_tag = t.string;
    }
    var export_name: ?[]const u8 = null;
    if (item.object.get("export")) |ex| {
        if (ex != .string) return error.InvalidManifest;
        export_name = ex.string;
    }
    return .{
        .name = name,
        .kind = kind,
        .result_tag = result_tag,
        .export_name = export_name,
    };
}

fn parseExport(item: std.json.Value) ParseError!ExportEntry {
    if (item != .object) return error.InvalidManifest;
    const name = switch (item.object.get("name") orelse return error.InvalidManifest) {
        .string => |s| s,
        else => return error.InvalidManifest,
    };
    const params: u32 = switch (item.object.get("params") orelse return error.InvalidManifest) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => return error.InvalidManifest,
    };
    return .{ .name = name, .params = params };
}

/// Serialize a graph manifest as compact JSON (custom section + sidecar).
/// Does not validate; call `validate` or use `emitCustomSection` for emit guards.
pub fn writeJson(manifest: GraphManifest, writer: anytype) !void {
    try writer.print("{{\"abi\":{d},\"entry\":\"", .{manifest.abi_version});
    try writeEscaped(writer, manifest.entry);
    try writer.writeAll("\",\"inputs\":[");
    for (manifest.inputs, 0..) |port, i| {
        if (i > 0) try writer.writeAll(",");
        try writePortJson(writer, port, false);
    }
    try writer.writeAll("],\"params\":[");
    for (manifest.params, 0..) |port, i| {
        if (i > 0) try writer.writeAll(",");
        try writePortJson(writer, port, true);
    }
    try writer.writeAll("],\"outputs\":[");
    for (manifest.outputs, 0..) |out, i| {
        if (i > 0) try writer.writeAll(",");
        try writeOutputJson(writer, out);
    }
    try writer.writeAll("],\"out_mode\":\"");
    try writer.writeAll(manifest.out_mode.jsonName());
    try writer.writeAll("\",\"exports\":[");
    for (manifest.exports, 0..) |ex, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":\"");
        try writeEscaped(writer, ex.name);
        try writer.print("\",\"params\":{d}}}", .{ex.params});
    }
    try writer.writeAll("]}");
}

fn writePortJson(writer: anytype, port: Port, include_default: bool) !void {
    try writer.writeAll("{\"name\":\"");
    try writeEscaped(writer, port.name);
    try writer.writeAll("\",\"kind\":\"");
    try writer.writeAll(kindShortName(port.kind));
    try writer.writeAll("\"");
    if (include_default) {
        if (port.default) |d| {
            try writer.print(",\"default\":{d}", .{d});
        } else {
            try writer.writeAll(",\"default\":null");
        }
    }
    try writer.writeAll("}");
}

fn writeOutputJson(writer: anytype, out: GraphOutputPort) !void {
    try writer.writeAll("{\"name\":\"");
    try writeEscaped(writer, out.name);
    try writer.writeAll("\",\"kind\":\"");
    try writer.writeAll(kindShortName(out.kind));
    try writer.writeAll("\",\"result_tag\":\"");
    const tag = out.result_tag orelse kindToResultTag(out.kind);
    try writeEscaped(writer, tag);
    try writer.writeAll("\"");
    if (out.export_name) |ex| {
        try writer.writeAll(",\"export\":\"");
        try writeEscaped(writer, ex);
        try writer.writeAll("\"");
    }
    try writer.writeAll("}");
}

fn writeEscaped(writer: anytype, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (ch < 0x20)
                try writer.print("\\u{x:0>4}", .{ch})
            else
                try writer.writeAll(&.{ch}),
        }
    }
}

/// Allocate JSON bytes for a manifest (caller frees). Does not validate.
pub fn toJsonAlloc(allocator: std.mem.Allocator, manifest: GraphManifest) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const w = list_writer.unmanagedByteWriter(&buf, allocator);
    try writeJson(manifest, w);
    return try buf.toOwnedSlice(allocator);
}

/// Append a `mathzig:graph` custom section to a WasmModule.
/// Runs `validate` first so empty-output manifests never land in `.wasm`.
pub fn emitCustomSection(module: anytype, allocator: std.mem.Allocator, manifest: GraphManifest) !void {
    try validate(manifest);
    const json = try toJsonAlloc(allocator, manifest);
    defer allocator.free(json);
    try module.addCustomSection(CUSTOM_SECTION_NAME, json);
}

/// Typed scan result (task-14 / C3): absent vs malformed_wasm vs present.
pub const SectionScan = module_mod.CustomSectionScan;

/// Scan wasm bytes for a `mathzig:graph` custom section (typed).
pub fn scanWasmGraphSectionResult(wasm_bytes: []const u8) SectionScan {
    return module_mod.scanCustomSectionResult(wasm_bytes, CUSTOM_SECTION_NAME);
}

/// Legacy: payload or null when absent **or** malformed.
pub fn scanWasmGraphSection(wasm_bytes: []const u8) ?[]const u8 {
    return switch (scanWasmGraphSectionResult(wasm_bytes)) {
        .present => |p| p,
        .absent, .malformed_wasm => null,
    };
}
