//! GraphDefinition / Node / Edge — mirror of `src/ts/graph/schema.ts`.
//!
//! Parses graph JSON via `std.json.Value` (dynamic) so polymorphic node shapes
//! (input | const | expr | wasm) and flexible edges/outputs forms are supported.

const std = @import("std");
const value_mod = @import("../core/value.zig");
const Value = value_mod.Value;
const Matrix = value_mod.Matrix;
const manifest_mod = @import("manifest.zig");
const abi = @import("../wasm/abi.zig");

pub const GraphNodeId = []const u8;
pub const GraphPortName = []const u8;
pub const GraphRef = []const u8;

/// Port kinds accepted by the graph schema (friendly names).
pub const PortKind = enum {
    number,
    boolean,
    matrix,
    complex,
    record,
    string,
    series,
    any,

    pub fn name(self: PortKind) []const u8 {
        return switch (self) {
            .number => "number",
            .boolean => "boolean",
            .matrix => "matrix",
            .complex => "complex",
            .record => "record",
            .string => "string",
            .series => "series",
            .any => "any",
        };
    }
};

pub fn normalizePortKind(kind: []const u8) !PortKind {
    if (std.mem.eql(u8, kind, "scalar") or std.mem.eql(u8, kind, "number")) return .number;
    if (std.mem.eql(u8, kind, "bool") or std.mem.eql(u8, kind, "boolean")) return .boolean;
    if (std.mem.eql(u8, kind, "matrix") or std.mem.eql(u8, kind, "matrix_ptr")) return .matrix;
    if (std.mem.eql(u8, kind, "complex") or std.mem.eql(u8, kind, "complex_ptr")) return .complex;
    if (std.mem.eql(u8, kind, "record") or std.mem.eql(u8, kind, "record_ptr")) return .record;
    if (std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "string_ptr")) return .string;
    if (std.mem.eql(u8, kind, "series") or std.mem.eql(u8, kind, "series_handle")) return .series;
    if (std.mem.eql(u8, kind, "any")) return .any;
    return error.UnknownPortKind;
}

/// WireKind → graph PortKind (shared with manifest-driven wasm nodes).
pub fn wireToPortKind(kind: abi.WireKind) PortKind {
    return switch (kind) {
        .number => .number,
        .boolean => .boolean,
        .matrix_ptr => .matrix,
        .complex_ptr => .complex,
        .record_ptr => .record,
        .string_ptr => .string,
        .series_handle => .series,
        .predicate_ptr => .any,
        .any => .any,
    };
}

/// True when producer → consumer kinds are compatible on an edge.
pub fn kindsCompatible(producer: PortKind, consumer: PortKind) bool {
    if (producer == consumer) return true;
    if (producer == .any or consumer == .any) return true;
    if ((producer == .number and consumer == .boolean) or
        (producer == .boolean and consumer == .number)) return true;
    return false;
}

pub const ParsedGraphRef = struct {
    node_id: GraphNodeId,
    port: GraphPortName,
};

pub fn parseGraphRef(ref: []const u8) !ParsedGraphRef {
    const dot = std.mem.indexOfScalar(u8, ref, '.') orelse return error.InvalidGraphRef;
    if (dot == 0 or dot == ref.len - 1) return error.InvalidGraphRef;
    if (std.mem.indexOfScalar(u8, ref[dot + 1 ..], '.') != null) return error.InvalidGraphRef;
    return .{
        .node_id = ref[0..dot],
        .port = ref[dot + 1 ..],
    };
}

pub const GraphEdge = struct {
    from: GraphRef,
    to: GraphRef,
};

pub const ParamEntry = struct {
    name: []const u8,
    value: f64,
};

pub const GraphNode = union(enum) {
    input: struct {
        id: GraphNodeId,
        name: []const u8, // runtime input key (defaults to id)
        kind: PortKind,
    },
    @"const": struct {
        id: GraphNodeId,
        value: Value,
        kind: PortKind,
    },
    expr: struct {
        id: GraphNodeId,
        expr: []const u8,
        inputs: []const GraphPortName,
        input_kinds: []const PortKind,
        params: []ParamEntry,
        output_kind: PortKind,
    },
    wasm: struct {
        id: GraphNodeId,
        /// Optional dual-path expression (v1 VM engine). When null, load fails
        /// with WasmPhase2Required unless tests skip wasm nodes.
        expr: ?[]const u8 = null,
        /// Path or opaque bytes marker (not executed in v1).
        wasm_path: ?[]const u8 = null,
        /// Inline manifest JSON object text when present; otherwise null.
        manifest_json: ?[]const u8 = null,
        params: []ParamEntry,
        output_kind: PortKind,
        inputs: []const GraphPortName = &.{},
        input_kinds: []const PortKind = &.{},
    },

    pub fn id(self: GraphNode) []const u8 {
        return switch (self) {
            .input => |n| n.id,
            .@"const" => |n| n.id,
            .expr => |n| n.id,
            .wasm => |n| n.id,
        };
    }

    pub fn outputKind(self: GraphNode) PortKind {
        return switch (self) {
            .input => |n| n.kind,
            .@"const" => |n| n.kind,
            .expr => |n| n.output_kind,
            .wasm => |n| n.output_kind,
        };
    }
};

pub const NormalizedGraphDefinition = struct {
    nodes: []GraphNode,
    edges: []GraphEdge,
    /// Output name → graph ref (`node.out`).
    outputs: []OutputEntry,
};

pub const OutputEntry = struct {
    name: []const u8,
    ref: GraphRef,
};

pub const SchemaError = error{
    UnknownPortKind,
    InvalidGraphRef,
    InvalidGraphJson,
    MissingNodes,
    MissingType,
    MissingExpr,
    InvalidConstValue,
    InvalidNumber,
    DuplicateNode,
    EmptyNodeId,
    /// Inline / sidecar node manifest is not a JSON object.
    ManifestNotObject,
    /// Manifest `abi` ≠ current ABI_VERSION.
    IncompatibleAbiVersion,
    /// Duplicate port names in manifest inputs/params.
    DuplicatePort,
    /// Manifest kind field is present but not a string.
    MalformedKind,
    /// Manifest shape failure (missing fields, wrong container types, …).
    InvalidManifest,
    /// Documented adversarial cap exceeded (task-14 / C3).
    LimitExceeded,
    /// Source / identifier longer than documented max.
    SourceTooLarge,
    IdentifierTooLong,
};

/// Parse a GraphDefinition JSON document into a normalized definition.
/// Untrusted entry: enforces `abi.MAX_SOURCE_BYTES` **before** JSON alloc.
/// All strings / slices are allocated from `arena` (caller owns the arena).
/// Const matrix Values are owned by the definition and must be released via
/// `deinitConstValues` when the definition is discarded (arena free alone is not enough).
pub fn parseGraphDefinition(arena: std.mem.Allocator, json_text: []const u8) (SchemaError || std.json.ParseError(std.json.Scanner) || error{OutOfMemory})!NormalizedGraphDefinition {
    if (json_text.len > abi.MAX_SOURCE_BYTES) return error.SourceTooLarge;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});
    return try normalizeFromJsonValue(arena, root);
}

pub fn parseGraphDefinitionValue(arena: std.mem.Allocator, root: std.json.Value) (SchemaError || error{OutOfMemory})!NormalizedGraphDefinition {
    return try normalizeFromJsonValue(arena, root);
}

/// Release owned Values inside const nodes (matrices/records/series). Strings
/// and node metadata live on the definition arena.
pub fn deinitConstValues(def: *const NormalizedGraphDefinition) void {
    for (def.nodes) |node| {
        switch (node) {
            .@"const" => |c| c.value.release(),
            else => {},
        }
    }
}

fn normalizeFromJsonValue(arena: std.mem.Allocator, root: std.json.Value) (SchemaError || error{OutOfMemory})!NormalizedGraphDefinition {
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidGraphJson,
    };

    const nodes_val = obj.get("nodes") orelse return error.MissingNodes;
    var nodes_list: std.ArrayListUnmanaged(GraphNode) = .empty;
    errdefer {
        for (nodes_list.items) |n| {
            if (n == .@"const") n.@"const".value.release();
        }
        nodes_list.deinit(arena);
    }

    // Pre-count for limit enforcement before full node parse allocs where possible.
    const node_count_hint: usize = switch (nodes_val) {
        .array => |arr| arr.items.len,
        .object => |m| m.count(),
        else => return error.InvalidGraphJson,
    };
    if (node_count_hint > abi.MAX_GRAPH_NODES) return error.LimitExceeded;

    switch (nodes_val) {
        .array => |arr| {
            for (arr.items) |item| {
                const nobj = switch (item) {
                    .object => |o| o,
                    else => return error.InvalidGraphJson,
                };
                const id_str = try requireString(nobj, "id");
                if (id_str.len == 0) return error.EmptyNodeId;
                if (id_str.len > abi.MAX_IDENTIFIER_LEN) return error.IdentifierTooLong;
                try nodes_list.append(arena, try parseNode(arena, id_str, nobj));
            }
        },
        .object => |nobj_map| {
            var it = nobj_map.iterator();
            while (it.next()) |entry| {
                const id_str = entry.key_ptr.*;
                if (id_str.len == 0) return error.EmptyNodeId;
                if (id_str.len > abi.MAX_IDENTIFIER_LEN) return error.IdentifierTooLong;
                const nobj = switch (entry.value_ptr.*) {
                    .object => |o| o,
                    else => return error.InvalidGraphJson,
                };
                try nodes_list.append(arena, try parseNode(arena, id_str, nobj));
            }
        },
        else => return error.InvalidGraphJson,
    }

    // Edges
    var edges_list: std.ArrayListUnmanaged(GraphEdge) = .empty;
    errdefer edges_list.deinit(arena);
    if (obj.get("edges")) |edges_val| {
        const edge_count_hint: usize = switch (edges_val) {
            .array => |arr| arr.items.len,
            .object => |m| m.count(),
            else => return error.InvalidGraphJson,
        };
        if (edge_count_hint > abi.MAX_GRAPH_EDGES) return error.LimitExceeded;
        switch (edges_val) {
            .array => |arr| {
                for (arr.items) |item| {
                    const eobj = switch (item) {
                        .object => |o| o,
                        else => return error.InvalidGraphJson,
                    };
                    const from = try requireString(eobj, "from");
                    const to = try requireString(eobj, "to");
                    try edges_list.append(arena, .{ .from = from, .to = to });
                }
            },
            .object => |emap| {
                var it = emap.iterator();
                while (it.next()) |entry| {
                    const from = entry.key_ptr.*;
                    const to = switch (entry.value_ptr.*) {
                        .string => |s| s,
                        else => return error.InvalidGraphJson,
                    };
                    try edges_list.append(arena, .{ .from = from, .to = to });
                }
            },
            else => return error.InvalidGraphJson,
        }
    }

    // Outputs
    var outputs_list: std.ArrayListUnmanaged(OutputEntry) = .empty;
    errdefer outputs_list.deinit(arena);
    if (obj.get("outputs")) |outs| {
        switch (outs) {
            .object => |omap| {
                var it = omap.iterator();
                while (it.next()) |entry| {
                    const ref = switch (entry.value_ptr.*) {
                        .string => |s| s,
                        else => return error.InvalidGraphJson,
                    };
                    try outputs_list.append(arena, .{ .name = entry.key_ptr.*, .ref = ref });
                }
            },
            .array => |arr| {
                for (arr.items) |item| {
                    const name = switch (item) {
                        .string => |s| s,
                        else => return error.InvalidGraphJson,
                    };
                    const ref = try std.fmt.allocPrint(arena, "{s}.out", .{name});
                    try outputs_list.append(arena, .{ .name = name, .ref = ref });
                }
            },
            else => return error.InvalidGraphJson,
        }
    }

    // Default: every node is an output named by its id.
    if (outputs_list.items.len == 0) {
        for (nodes_list.items) |node| {
            const nid = node.id();
            const ref = try std.fmt.allocPrint(arena, "{s}.out", .{nid});
            try outputs_list.append(arena, .{ .name = nid, .ref = ref });
        }
    }

    return .{
        .nodes = try nodes_list.toOwnedSlice(arena),
        .edges = try edges_list.toOwnedSlice(arena),
        .outputs = try outputs_list.toOwnedSlice(arena),
    };
}

fn parseNode(arena: std.mem.Allocator, id_str: []const u8, nobj: std.json.ObjectMap) (SchemaError || error{OutOfMemory})!GraphNode {
    const type_str = try requireString(nobj, "type");

    if (std.mem.eql(u8, type_str, "input")) {
        const name = if (nobj.get("name")) |v| try asString(v) else id_str;
        const kind: PortKind = if (nobj.get("kind")) |k|
            try normalizePortKind(try asString(k))
        else
            .number;
        return .{ .input = .{ .id = id_str, .name = name, .kind = kind } };
    }

    if (std.mem.eql(u8, type_str, "const")) {
        const raw = nobj.get("value") orelse return error.InvalidConstValue;
        const val = try jsonToValue(arena, raw);
        errdefer val.release();
        const kind: PortKind = if (nobj.get("kind")) |k|
            try normalizePortKind(try asString(k))
        else
            inferConstKind(val);
        return .{ .@"const" = .{ .id = id_str, .value = val, .kind = kind } };
    }

    if (std.mem.eql(u8, type_str, "expr")) {
        const expr_str = try requireString(nobj, "expr");
        const inputs = try parseStringArray(arena, nobj.get("inputs"));
        const input_kinds = try parseInputKinds(arena, nobj.get("inputKinds"), inputs.len);
        const params = try parseParams(arena, nobj.get("params"));
        const output_kind: PortKind = if (nobj.get("outputKind")) |k|
            try normalizePortKind(try asString(k))
        else
            .number;
        return .{ .expr = .{
            .id = id_str,
            .expr = expr_str,
            .inputs = inputs,
            .input_kinds = input_kinds,
            .params = params,
            .output_kind = output_kind,
        } };
    }

    if (std.mem.eql(u8, type_str, "wasm")) {
        // Optional dual-path expr for VM-native graph evaluator v1 (required to run;
        // without it load returns WasmPhase2Required). Path string is stored only —
        // v1 never loads .wasm bytes.
        const expr_opt: ?[]const u8 = if (nobj.get("expr")) |e| try asString(e) else null;
        const wasm_path: ?[]const u8 = if (nobj.get("wasm")) |w| blk: {
            break :blk switch (w) {
                .string => |s| s,
                else => null,
            };
        } else null;
        var params = try parseParams(arena, nobj.get("params"));
        var output_kind: PortKind = .number;
        var inputs: []const GraphPortName = &.{};
        var input_kinds: []const PortKind = &.{};
        var manifest_json: ?[]const u8 = null;

        if (nobj.get("manifest")) |man| {
            // Real parse into ONE shared NodeManifest — never store "{}" as a
            // validation no-op. Object is preferred; string is sidecar JSON text.
            const nm = switch (man) {
                .object => try parseManifestIntoSchema(arena, man),
                .string => |s| try parseManifestJsonIntoSchema(arena, s),
                else => return error.ManifestNotObject,
            };
            // Canonical JSON so runner re-parse sees real data.
            manifest_json = try manifest_mod.toJsonAlloc(arena, nm);

            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            var kinds: std.ArrayListUnmanaged(PortKind) = .empty;
            for (nm.inputs) |port| {
                try names.append(arena, port.name);
                try kinds.append(arena, wireToPortKind(port.kind));
            }
            inputs = try names.toOwnedSlice(arena);
            input_kinds = try kinds.toOwnedSlice(arena);
            output_kind = wireToPortKind(nm.output.kind);

            // Manifest param defaults; graph `params` override by name.
            if (nm.params.len > 0) {
                var merged: std.ArrayListUnmanaged(ParamEntry) = .empty;
                for (nm.params) |port| {
                    var found = false;
                    for (params) |p| {
                        if (std.mem.eql(u8, p.name, port.name)) {
                            try merged.append(arena, p);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        const def: f64 = port.default orelse 0;
                        try merged.append(arena, .{ .name = port.name, .value = def });
                    }
                }
                for (params) |p| {
                    var in_merged = false;
                    for (merged.items) |m| {
                        if (std.mem.eql(u8, m.name, p.name)) {
                            in_merged = true;
                            break;
                        }
                    }
                    if (!in_merged) try merged.append(arena, p);
                }
                params = try merged.toOwnedSlice(arena);
            }
        }

        // Explicit graph-level fields still override when no / after manifest.
        if (nobj.get("outputKind")) |k| {
            output_kind = try normalizePortKind(try asString(k));
        }
        if (nobj.get("inputs")) |ins| {
            inputs = try parseStringArray(arena, ins);
            input_kinds = try parseInputKinds(arena, nobj.get("inputKinds"), inputs.len);
        }

        return .{ .wasm = .{
            .id = id_str,
            .expr = expr_opt,
            .wasm_path = wasm_path,
            .manifest_json = manifest_json,
            .params = params,
            .output_kind = output_kind,
            .inputs = inputs,
            .input_kinds = input_kinds,
        } };
    }

    return error.MissingType;
}

fn parseStringArray(arena: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const v = val orelse return try arena.alloc([]const u8, 0);
    switch (v) {
        .array => |arr| {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr.items) |item| {
                try list.append(arena, try asString(item));
            }
            return try list.toOwnedSlice(arena);
        },
        else => return error.InvalidGraphJson,
    }
}

fn parseInputKinds(arena: std.mem.Allocator, val: ?std.json.Value, n: usize) ![]const PortKind {
    var kinds = try arena.alloc(PortKind, n);
    @memset(kinds, .number);
    const v = val orelse return kinds;
    switch (v) {
        .array => |arr| {
            var i: usize = 0;
            while (i < n and i < arr.items.len) : (i += 1) {
                kinds[i] = try normalizePortKind(try asString(arr.items[i]));
            }
        },
        else => return error.InvalidGraphJson,
    }
    return kinds;
}

fn parseParams(arena: std.mem.Allocator, val: ?std.json.Value) ![]ParamEntry {
    const v = val orelse return try arena.alloc(ParamEntry, 0);
    switch (v) {
        .object => |obj| {
            var list: std.ArrayListUnmanaged(ParamEntry) = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                try list.append(arena, .{
                    .name = entry.key_ptr.*,
                    .value = try jsonToF64(entry.value_ptr.*),
                });
            }
            return try list.toOwnedSlice(arena);
        },
        else => return error.InvalidGraphJson,
    }
}

fn mapManifestErr(err: anyerror) (SchemaError || error{OutOfMemory}) {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ManifestNotObject => error.ManifestNotObject,
        error.IncompatibleAbiVersion => error.IncompatibleAbiVersion,
        error.DuplicatePort => error.DuplicatePort,
        error.UnknownKind => error.UnknownPortKind,
        error.MalformedKind => error.MalformedKind,
        error.InvalidManifest => error.InvalidManifest,
        else => error.InvalidManifest,
    };
}

fn parseManifestIntoSchema(arena: std.mem.Allocator, root: std.json.Value) (SchemaError || error{OutOfMemory})!manifest_mod.NodeManifest {
    return manifest_mod.parseManifestValue(arena, root) catch |err| mapManifestErr(err);
}

fn parseManifestJsonIntoSchema(arena: std.mem.Allocator, json_text: []const u8) (SchemaError || error{OutOfMemory})!manifest_mod.NodeManifest {
    return manifest_mod.parseManifestJson(arena, json_text) catch |err| mapManifestErr(err);
}

fn requireString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.InvalidGraphJson;
    return asString(v);
}

fn asString(v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.InvalidGraphJson,
    };
}

pub fn jsonToF64(v: std.json.Value) !f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidNumber,
        .bool => |b| if (b) @as(f64, 1) else @as(f64, 0),
        else => error.InvalidNumber,
    };
}

/// Convert a JSON value to an owned MathZig Value (const nodes / CLI).
pub fn jsonToValue(allocator: std.mem.Allocator, v: std.json.Value) (SchemaError || error{OutOfMemory})!Value {
    switch (v) {
        .null => return Value.initNull(),
        .bool => |b| return Value.initBoolean(b),
        .integer => |i| return Value.initNumber(@floatFromInt(i)),
        .float => |f| return Value.initNumber(f),
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch return error.InvalidNumber;
            return Value.initNumber(f);
        },
        .string => |s| {
            // String values: allocate a simple owned buffer via Matrix-free path.
            // MathZig string type needs special construction — store as number NaN fallback
            // is wrong. Use Value string if available via series-free init.
            // For v1 const strings are rare; construct a minimal string Value.
            _ = s;
            return error.InvalidConstValue;
        },
        .array => return error.InvalidConstValue,
        .object => |obj| {
            // Matrix: {rows, cols, data}
            if (obj.get("rows") != null and obj.get("cols") != null and obj.get("data") != null) {
                const rows_f = try jsonToF64(obj.get("rows").?);
                const cols_f = try jsonToF64(obj.get("cols").?);
                const rows: u32 = @intFromFloat(rows_f);
                const cols: u32 = @intFromFloat(cols_f);
                const data_val = obj.get("data").?;
                if (data_val != .array) return error.InvalidConstValue;
                const m = try Matrix.init(allocator, rows, cols);
                errdefer m.release();
                const items = data_val.array.items;
                if (items.len != @as(usize, rows) * @as(usize, cols)) return error.InvalidConstValue;
                var i: usize = 0;
                while (i < items.len) : (i += 1) {
                    m.data[i] = try jsonToF64(items[i]);
                }
                return Value.initMatrix(m);
            }
            // Complex: {re, im}
            if (obj.get("re") != null and obj.get("im") != null) {
                const re = try jsonToF64(obj.get("re").?);
                const im = try jsonToF64(obj.get("im").?);
                return Value.initComplex(re, im);
            }
            return error.InvalidConstValue;
        },
    }
}

fn inferConstKind(val: Value) PortKind {
    return switch (val.tag) {
        .number => .number,
        .boolean => .boolean,
        .string => .string,
        .matrix => .matrix,
        .complex => .complex,
        .record => .record,
        .series => .series,
        else => .number,
    };
}

pub fn nodeInputKind(node: GraphNode, port: []const u8) ?PortKind {
    switch (node) {
        .input, .@"const" => return null,
        .expr => |e| {
            for (e.inputs, 0..) |name, i| {
                if (std.mem.eql(u8, name, port)) return e.input_kinds[i];
            }
            for (e.params) |p| {
                if (std.mem.eql(u8, p.name, port)) return .number;
            }
            return null;
        },
        .wasm => |w| {
            for (w.inputs, 0..) |name, i| {
                if (std.mem.eql(u8, name, port)) {
                    if (i < w.input_kinds.len) return w.input_kinds[i];
                    return .number;
                }
            }
            for (w.params) |p| {
                if (std.mem.eql(u8, p.name, port)) return .number;
            }
            return null;
        },
    }
}

test "parseGraphRef accepts node.port" {
    const r = try parseGraphRef("foo.out");
    try std.testing.expectEqualStrings("foo", r.node_id);
    try std.testing.expectEqualStrings("out", r.port);
}

test "normalizePortKind aliases" {
    try std.testing.expectEqual(PortKind.number, try normalizePortKind("scalar"));
    try std.testing.expectEqual(PortKind.matrix, try normalizePortKind("matrix_ptr"));
}

test "parse minimal scalar graph JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{
        \\  "nodes": [
        \\    {"id": "x", "type": "input"},
        \\    {"id": "g", "type": "expr", "expr": "x * 2", "inputs": ["x"]}
        \\  ],
        \\  "edges": [{"from": "x.out", "to": "g.x"}],
        \\  "outputs": {"value": "g.out"}
        \\}
    ;
    const def = try parseGraphDefinition(a, json);
    try std.testing.expectEqual(@as(usize, 2), def.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), def.edges.len);
    try std.testing.expectEqual(@as(usize, 1), def.outputs.len);
}

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
    const def = try parseGraphDefinition(a, json);
    try std.testing.expectEqual(@as(usize, 1), def.nodes.len);
    const w = def.nodes[0].wasm;
    try std.testing.expect(w.manifest_json != null);
    try std.testing.expect(!std.mem.eql(u8, w.manifest_json.?, "{}"));
    try std.testing.expectEqual(@as(usize, 1), w.inputs.len);
    try std.testing.expectEqualStrings("x", w.inputs[0]);
    try std.testing.expectEqual(PortKind.number, w.input_kinds[0]);
    try std.testing.expectEqual(PortKind.number, w.output_kind);
    try std.testing.expectEqual(@as(usize, 1), w.params.len);
    try std.testing.expectEqualStrings("k", w.params[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2), w.params[0].value, 0);

    // Round-trip: stored JSON re-parses to the same typed NodeManifest fields.
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

    const inputs = [_]manifest_mod.Port{.{ .name = "x", .kind = .number }};
    const params = [_]manifest_mod.Port{.{ .name = "k", .kind = .number, .default = 3 }};
    const original = manifest_mod.NodeManifest{
        .name = "gain",
        .inputs = &inputs,
        .params = &params,
        .output = .{ .kind = .number, .result_tag = "number" },
    };
    const sidecar = try manifest_mod.toJsonAlloc(a, original);
    const from_sidecar = try manifest_mod.parseManifestJson(a, sidecar);

    // Embed the same logical object as inline JSON (writeJson form).
    const graph_json = try std.fmt.allocPrint(a,
        \\{{"nodes":[{{"id":"g","type":"wasm","expr":"x*k","manifest":{s}}}],"edges":[],"outputs":{{"value":"g.out"}}}}
    , .{sidecar});
    const def = try parseGraphDefinition(a, graph_json);
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
    try std.testing.expectError(error.ManifestNotObject, parseGraphDefinition(arena.allocator(), json));
}

test "wasm bad abi rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":999,"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.IncompatibleAbiVersion, parseGraphDefinition(arena.allocator(), json));
}

test "wasm duplicate port rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":1,"inputs":[{"name":"x","kind":"number"},{"name":"x","kind":"number"}],"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.DuplicatePort, parseGraphDefinition(arena.allocator(), json));
}

test "wasm unknown kind rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":1,"inputs":[{"name":"x","kind":"nope"}],"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.UnknownPortKind, parseGraphDefinition(arena.allocator(), json));
}

test "wasm malformed kind rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"nodes":[{"id":"g","type":"wasm","expr":"1","manifest":{"abi":1,"inputs":[{"name":"x","kind":1}],"output":{"kind":"number"}}}],"edges":[],"outputs":{"value":"g.out"}}
    ;
    try std.testing.expectError(error.MalformedKind, parseGraphDefinition(arena.allocator(), json));
}
