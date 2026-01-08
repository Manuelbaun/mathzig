//! Node-graph manifest (`mathzig:node` custom section + JSON sidecar).
//!
//! Describes the ports of a single AOT-compiled wasm node so graph loaders can
//! type-check edges without re-parsing the expression. Wire kinds reuse
//! `abi.WireKind` — no second kind enum.

const std = @import("std");
const abi = @import("abi.zig");
const list_writer = @import("list_writer.zig");

/// Custom-section name (distinct from the ABI section `mathzig.abi`).
pub const CUSTOM_SECTION_NAME = "mathzig:node";

/// One input or param port.
pub const Port = struct {
    name: []const u8,
    kind: abi.WireKind,
    /// Only meaningful for params; null for inputs.
    default: ?f64 = null,
};

/// Output port (single result for v1).
pub const OutputPort = struct {
    name: []const u8 = "out",
    kind: abi.WireKind,
    /// `mathzig.abi` result_tag style (number/matrix/complex/…); optional when
    /// it can be derived from `kind`.
    result_tag: ?[]const u8 = null,
};

pub const NodeManifest = struct {
    /// ABI version (mirrors abi.ABI_VERSION).
    abi_version: u32 = abi.ABI_VERSION,
    /// Node / function name (usually the exported eval name).
    name: []const u8 = "eval",
    inputs: []const Port = &.{},
    params: []const Port = &.{},
    output: OutputPort,
};

/// Friendly CLI / graph-schema names → WireKind.
pub fn parseKindName(name: []const u8) ?abi.WireKind {
    if (std.mem.eql(u8, name, "scalar") or std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "boolean") or std.mem.eql(u8, name, "bool")) return .boolean;
    if (std.mem.eql(u8, name, "matrix") or std.mem.eql(u8, name, "matrix_ptr")) return .matrix_ptr;
    if (std.mem.eql(u8, name, "complex") or std.mem.eql(u8, name, "complex_ptr")) return .complex_ptr;
    if (std.mem.eql(u8, name, "record") or std.mem.eql(u8, name, "record_ptr")) return .record_ptr;
    if (std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "string_ptr")) return .string_ptr;
    if (std.mem.eql(u8, name, "series") or std.mem.eql(u8, name, "series_handle")) return .series_handle;
    if (std.mem.eql(u8, name, "predicate") or std.mem.eql(u8, name, "predicate_ptr")) return .predicate_ptr;
    if (std.mem.eql(u8, name, "any")) return .any;
    return null;
}

/// WireKind → short graph/CLI kind name (preferred over raw wire names).
pub fn kindShortName(kind: abi.WireKind) []const u8 {
    return switch (kind) {
        .number => "number",
        .boolean => "boolean",
        .matrix_ptr => "matrix",
        .complex_ptr => "complex",
        .record_ptr => "record",
        .string_ptr => "string",
        .series_handle => "series",
        .predicate_ptr => "predicate",
        .any => "any",
    };
}

/// WireKind → result_tag string used in `mathzig.abi`.
pub fn kindToResultTag(kind: abi.WireKind) []const u8 {
    return switch (kind) {
        .number => "number",
        .boolean => "boolean",
        .matrix_ptr => "matrix",
        .complex_ptr => "complex",
        .record_ptr => "record",
        .string_ptr => "string",
        .series_handle => "series",
        .predicate_ptr => "predicate",
        .any => "number",
    };
}

/// Serialize a node manifest as compact JSON (custom section + sidecar).
pub fn writeJson(manifest: NodeManifest, writer: anytype) !void {
    try writer.print("{{\"abi\":{d},\"name\":\"", .{manifest.abi_version});
    try writeEscaped(writer, manifest.name);
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
    try writer.writeAll("],\"output\":{");
    try writer.writeAll("\"name\":\"");
    try writeEscaped(writer, manifest.output.name);
    try writer.writeAll("\",\"kind\":\"");
    try writer.writeAll(kindShortName(manifest.output.kind));
    try writer.writeAll("\",\"result_tag\":\"");
    const tag = manifest.output.result_tag orelse kindToResultTag(manifest.output.kind);
    try writeEscaped(writer, tag);
    try writer.writeAll("\"}}");
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

/// Allocate JSON bytes for a manifest (caller frees).
pub fn toJsonAlloc(allocator: std.mem.Allocator, manifest: NodeManifest) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const w = list_writer.unmanagedByteWriter(&buf, allocator);
    try writeJson(manifest, w);
    return try buf.toOwnedSlice(allocator);
}

/// Append a `mathzig:node` custom section to a WasmModule.
pub fn emitCustomSection(module: anytype, allocator: std.mem.Allocator, manifest: NodeManifest) !void {
    const json = try toJsonAlloc(allocator, manifest);
    defer allocator.free(json);
    try module.addCustomSection(CUSTOM_SECTION_NAME, json);
}

test "parseKindName accepts friendly and wire names" {
    try std.testing.expectEqual(abi.WireKind.number, parseKindName("scalar").?);
    try std.testing.expectEqual(abi.WireKind.number, parseKindName("number").?);
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, parseKindName("matrix").?);
    try std.testing.expectEqual(abi.WireKind.matrix_ptr, parseKindName("matrix_ptr").?);
    try std.testing.expectEqual(abi.WireKind.complex_ptr, parseKindName("complex").?);
    try std.testing.expectEqual(abi.WireKind.series_handle, parseKindName("series").?);
    try std.testing.expect(parseKindName("nope") == null);
}

test "writeJson round-trips structure" {
    const inputs = [_]Port{
        .{ .name = "x", .kind = .matrix_ptr },
        .{ .name = "y", .kind = .number },
    };
    const params = [_]Port{
        .{ .name = "alpha", .kind = .number, .default = 0.1 },
    };
    const m = NodeManifest{
        .name = "gain",
        .inputs = &inputs,
        .params = &params,
        .output = .{ .kind = .matrix_ptr, .result_tag = "matrix" },
    };
    const json = try toJsonAlloc(std.testing.allocator, m);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"gain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"matrix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"default\":0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"result_tag\":\"matrix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"abi\":1") != null);
}
