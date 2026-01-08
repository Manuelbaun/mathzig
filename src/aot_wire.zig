//! Wire-format builtin delegation for the AOT host env (task A1).

const std = @import("std");
const abi = @import("wasm/abi.zig");
const BuiltinFn = @import("vm/bytecode.zig").BuiltinFn;
const Value = @import("core/value.zig").Value;
const VM = @import("vm/vm.zig").VM;
const Predicate = @import("timeseries/predicates.zig").Predicate;
const PredicateOp = @import("timeseries/predicates.zig").PredicateOp;
const Field = @import("timeseries/predicates.zig").Field;
const Matrix = @import("core/value.zig").Matrix;
const Series = @import("timeseries/series.zig").Series;
const StringHandle = @import("core/value.zig").StringHandle;
const Record = @import("core/value.zig").Record;

const WireKind = abi.WireKind;

fn wireKindAt(sig: abi.Signature, index: usize) WireKind {
    if (sig.args.len == 0) return .number;
    if (index < sig.args.len) return sig.args[index];
    return sig.args[sig.args.len - 1];
}

/// Per-arg resolved kind byte supplied by the TS host alongside the f64 args.
/// The host resolves handle-store entries to engine pointers before the call,
/// so it is the only side that can disambiguate an `any` wire (scalar vs
/// pointer) — a bare f64 like 4.0 must never be dereferenced.
pub const WireArgKind = enum(u8) {
    number = 0,
    matrix = 1,
    series = 2,
    complex = 3,
    string = 4,
    record = 5,
    _,
};

/// The host resolves pointer args before the call and encodes failure as 0
/// or NaN; either would trap `@ptrFromInt` on a non-optional pointer.
fn ptrFromWire(comptime T: type, wire: f64) !T {
    if (!std.math.isFinite(wire) or wire < 1) return error.TypeError;
    // Reject wires beyond the address space before @intFromFloat (UB past
    // maxInt(usize)); real pointers stay far below 2^63.
    if (wire >= 9007199254740992.0 * 1024.0) return error.TypeError; // 2^63
    return @ptrFromInt(@as(usize, @intFromFloat(wire)));
}

fn valueFromWire(arena_alloc: std.mem.Allocator, kind: WireKind, resolved: WireArgKind, wire: f64) !Value {
    // The signature's WireKind says what the builtin *expects*; only the
    // host's resolved kind says what the f64 actually *is*. A wire the host
    // could not resolve to an engine pointer (resolved == .number) must never
    // be dereferenced — it may be a raw wasm offset or a plain scalar.
    return switch (kind) {
        .number => Value.initNumber(wire),
        .boolean => Value.initBoolean(wire != 0),
        .matrix_ptr, .series_handle, .record_ptr, .any => switch (resolved) {
            .matrix => Value.initMatrix(try ptrFromWire(*Matrix, wire)),
            .series => Value.initSeries(try ptrFromWire(*Series, wire)),
            .record => Value.initRecord(try ptrFromWire(*Record, wire)),
            .string => blk: {
                const p = try ptrFromWire([*:0]const u8, wire);
                const copy = try arena_alloc.dupe(u8, std.mem.span(p));
                break :blk Value{ .tag = .string, .data = .{ .string = StringHandle.fromSlice(copy) } };
            },
            .complex => blk: {
                const p = try ptrFromWire(*const [2]f64, wire);
                break :blk Value.initComplex(p[0], p[1]);
            },
            else => if (kind == .any) Value.initNumber(wire) else error.TypeError,
        },
        .complex_ptr => blk: {
            if (resolved != .complex) return error.TypeError;
            const p = try ptrFromWire(*const [2]f64, wire);
            break :blk Value.initComplex(p[0], p[1]);
        },
        .string_ptr => blk: {
            if (resolved != .string) return error.TypeError;
            const p = try ptrFromWire([*:0]const u8, wire);
            const span = std.mem.span(p);
            const copy = try arena_alloc.dupe(u8, span);
            break :blk Value{ .tag = .string, .data = .{ .string = StringHandle.fromSlice(copy) } };
        },
        .predicate_ptr => return error.TypeError,
    };
}

/// Complex results are stored inline in Value (no stable pointer), so they
/// are staged here; valid until the next delegated call, like the result stash.
var complex_result_buf: [2]f64 = .{ 0, 0 };

fn wireFromValue(val: Value) f64 {
    return switch (val.tag) {
        .number => val.data.number,
        .boolean => if (val.data.boolean) 1 else 0,
        .complex => blk: {
            complex_result_buf = .{ val.data.complex.re, val.data.complex.im };
            break :blk @floatFromInt(@intFromPtr(&complex_result_buf));
        },
        // Unit quantities cross the AOT boundary as SI-normalized magnitudes;
        // hosts re-attach dimensions from the mathzig.abi `result_unit` annotation
        // (static path) or reconstruct via the delegated engine (dynamic path).
        .unit => val.data.unit.value,
        .matrix => @floatFromInt(@intFromPtr(val.data.matrix)),
        .series => @floatFromInt(@intFromPtr(val.data.series)),
        .record => @floatFromInt(@intFromPtr(val.data.record)),
        .string => @floatFromInt(@intFromPtr(val.data.string.ptr)),
        .predicate => @floatFromInt(@intFromPtr(val.data.predicate)),
        else => std.math.nan(f64),
    };
}

/// Decode a predicate tree from a contiguous buffer. `left`/`right` fields are
/// byte offsets from `base` (AOT host copy format), not absolute pointers.
pub fn decodePredicateTree(
    allocator: std.mem.Allocator,
    base: [*]const u8,
    node_offset: usize,
    cache: *std.AutoHashMap(usize, *Predicate),
) !*const Predicate {
    const root = base + node_offset;
    const root_addr = @intFromPtr(root);
    if (cache.get(root_addr)) |cached| return cached;

    const dv = std.mem.bytesAsValue([24]u8, root[0..24]);
    const op_raw: u32 = @bitCast(dv[0..4].*);
    const field_raw: u32 = @bitCast(dv[4..8].*);
    const constant: f64 = @bitCast(dv[8..16].*);
    const left_raw: i32 = @bitCast(dv[16..20].*);
    const right_raw: i32 = @bitCast(dv[20..24].*);

    const node = try allocator.create(Predicate);
    node.* = .{
        .op = @enumFromInt(@as(u8, @truncate(op_raw))),
        .field = @enumFromInt(@as(u8, @truncate(field_raw))),
        .constant = constant,
        .left = null,
        .right = null,
    };
    try cache.put(root_addr, node);

    if (left_raw >= 0) {
        node.left = try decodePredicateTree(allocator, base, @as(usize, @intCast(left_raw)), cache);
    }
    if (right_raw >= 0) {
        node.right = try decodePredicateTree(allocator, base, @as(usize, @intCast(right_raw)), cache);
    }
    return node;
}

pub fn callBuiltinWire(
    vm: *VM,
    allocator: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    func: BuiltinFn,
    argc: u8,
    args: []const f64,
    arg_kinds: ?[*]const u8,
    predicate: ?*const Predicate,
) !f64 {
    const sig = abi.signature(func);
    if (!sig.importable) return error.UnsupportedBuiltin;

    var values = std.ArrayListUnmanaged(Value).empty;
    defer values.deinit(allocator);
    try values.ensureTotalCapacity(allocator, argc);

    for (0..argc) |i| {
        const kind = wireKindAt(sig, i);
        const resolved: WireArgKind = if (arg_kinds) |ks| @enumFromInt(ks[i]) else .number;
        try values.append(allocator, try valueFromWire(arena_alloc, kind, resolved, args[i]));
    }

    const saved_sp = vm.sp;
    errdefer vm.sp = saved_sp;

    for (values.items) |v| {
        v.retain();
        try vm.push(v);
    }

    try vm.callBuiltin(func, argc, predicate);

    const result = try vm.pop();
    // The host copies pointer results (matrix data, series buffers) via
    // follow-up FFI calls after this returns, so the result must outlive this
    // call. Keep it alive until the next delegated call, mirroring the
    // engine's last-value convention. Retain so freeIntermediates (which
    // releases the VM's tracked creation ref) cannot free under the stash.
    result.retain();
    last_wire_result = result;

    return wireFromValue(result);
}

var last_wire_result: ?Value = null;

/// Drop the stashed result of the previous delegated call. Called on entry so
/// that an errored call leaves no stale result behind.
pub fn clearLastWireResult() void {
    if (last_wire_result) |prev| prev.release();
    last_wire_result = null;
}

fn kindByteFromTag(tag: anytype) u8 {
    return switch (tag) {
        // Units wire as SI magnitude numbers (host re-attaches via annotation).
        .number, .boolean, .unit => 0,
        .matrix => 1,
        .series => 2,
        .complex => 3,
        .string => 4,
        .record => 5,
        // Legitimate non-error empty results — distinct from 255 (= the call
        // errored) so the host doesn't turn them into throws.
        .undefined, .null_val => 6,
        else => 255,
    };
}

/// Actual kind of the last delegated call's result, so the host never has to
/// guess from the signature whether the returned f64 is a pointer.
pub fn lastWireResultKind() u8 {
    const result = last_wire_result orelse return 255;
    return kindByteFromTag(result.tag);
}

// ---------------------------------------------------------------------------
// Record enumeration/construction for the host env. The host cannot walk the
// engine's StringHashMap, so records cross the boundary field-by-field.
// ---------------------------------------------------------------------------

/// Staging buffer for NUL-terminated key returns (map keys are plain slices).
/// Valid until the next recordKeyAt call.
var key_out_buf: [256]u8 = undefined;

fn recordEntryAt(rec: *Record, index: u32) ?std.StringHashMap(Value).Entry {
    var it = rec.fields.iterator();
    var i: u32 = 0;
    while (it.next()) |entry| : (i += 1) {
        if (i == index) return entry;
    }
    return null;
}

pub fn recordKeyAt(rec: *Record, index: u32) ?[*:0]const u8 {
    const entry = recordEntryAt(rec, index) orelse return null;
    const key = entry.key_ptr.*;
    if (key.len >= key_out_buf.len) return null;
    @memcpy(key_out_buf[0..key.len], key);
    key_out_buf[key.len] = 0;
    return @ptrCast(&key_out_buf);
}

pub fn recordValueWireAt(rec: *Record, index: u32) f64 {
    const entry = recordEntryAt(rec, index) orelse return std.math.nan(f64);
    return wireFromValue(entry.value_ptr.*);
}

pub fn recordValueKindAt(rec: *Record, index: u32) u8 {
    const entry = recordEntryAt(rec, index) orelse return 255;
    return kindByteFromTag(entry.value_ptr.tag);
}

/// Build an engine Value for a record field from a host-supplied wire + kind.
/// String wires point at NUL-terminated bytes in native memory (host copy).
pub fn recordSetFromWire(
    rec: *Record,
    arena_alloc: std.mem.Allocator,
    key: []const u8,
    wire: f64,
    kind: WireArgKind,
) !void {
    const value: Value = switch (kind) {
        .number => Value.initNumber(wire),
        .matrix => Value.initMatrix(try ptrFromWire(*Matrix, wire)),
        .series => Value.initSeries(try ptrFromWire(*Series, wire)),
        .record => Value.initRecord(try ptrFromWire(*Record, wire)),
        .string => blk: {
            const p = try ptrFromWire([*:0]const u8, wire);
            const copy = try arena_alloc.dupe(u8, std.mem.span(p));
            break :blk Value{ .tag = .string, .data = .{ .string = StringHandle.fromSlice(copy) } };
        },
        else => return error.TypeError,
    };
    try rec.set(key, value);
}

test "decode simple predicate" {
    var buf: [24]u8 = undefined;
    @memset(&buf, 0);
    @as(*u32, @ptrCast(&buf[0])).* = @intFromEnum(PredicateOp.gt);
    @as(*u32, @ptrCast(&buf[4])).* = @intFromEnum(Field.value);
    @as(*f64, @ptrCast(&buf[8])).* = 0;
    @as(*i32, @ptrCast(&buf[16])).* = -1;
    @as(*i32, @ptrCast(&buf[20])).* = -1;

    var cache = std.AutoHashMap(usize, *Predicate).init(std.testing.allocator);
    defer cache.deinit();
    const pred = try decodePredicateTree(std.testing.allocator, &buf, 0, &cache);
    try std.testing.expectEqual(PredicateOp.gt, pred.op);
    try std.testing.expectEqual(Field.value, pred.field);
}