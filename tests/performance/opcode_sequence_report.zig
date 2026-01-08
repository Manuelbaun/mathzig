const std = @import("std");
const mz = @import("mathzig");

const SequenceStats = struct {
    count: u64,
};

const Scenario = struct {
    name: []const u8,
    expr: []const u8,
    weight: u64,
};

const Entry = struct {
    key: u64,
    count: u64,
};

fn pairKey(a: mz.Opcode, b: mz.Opcode) u64 {
    const ai: u32 = @intFromEnum(a);
    const bi: u32 = @intFromEnum(b);
    return (@as(u64, ai) << 32) | @as(u64, bi);
}

fn keyA(key: u64) mz.Opcode {
    const ai: u32 = @truncate(key >> 32);
    return @enumFromInt(ai);
}

fn keyB(key: u64) mz.Opcode {
    const bi: u32 = @truncate(key & 0xFFFF_FFFF);
    return @enumFromInt(bi);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Keep this aligned with tests/performance/perf_runner.zig hot workloads.
    const scenarios = [_]Scenario{
        .{ .name = "zig_arithmetic_scalar_fast", .expr = "x * 0.5 + 2.0", .weight = 1_000_000 },
        .{ .name = "zig_arithmetic_batch_simd", .expr = "x * 0.5 + 2.0", .weight = 1_000_000 },
        .{ .name = "zig_complex_div_batch_simd", .expr = "(z + 2*i) / (z - 2*i)", .weight = 1_000_000 },
        .{ .name = "zig_complex_pow_batch_simd", .expr = "z ^ 2", .weight = 1_000_000 },
        .{ .name = "zig_vm_get_index_dynamic_key_vector", .expr = "v[idx]", .weight = 500_000 },
        .{ .name = "zig_vm_get_index_const_key_vector", .expr = "v[0]", .weight = 500_000 },
    };

    var pair_counts = std.AutoHashMap(u64, SequenceStats).init(allocator);
    defer pair_counts.deinit();

    for (scenarios) |sc| {
        const compiled = try ctx.compile(sc.expr);
        defer ctx.freeExpr(compiled);

        if (compiled.code.len < 2) continue;

        for (0..compiled.code.len - 1) |i| {
            const a = compiled.code[i].opcode;
            const b = compiled.code[i + 1].opcode;
            const key = pairKey(a, b);
            const gop = try pair_counts.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0 };
            gop.value_ptr.count += sc.weight;
        }
    }

    var entries = std.ArrayListUnmanaged(Entry){};
    defer entries.deinit(allocator);

    var it = pair_counts.iterator();
    while (it.next()) |kv| {
        try entries.append(allocator, .{
            .key = kv.key_ptr.*,
            .count = kv.value_ptr.count,
        });
    }

    std.sort.block(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    const top_n: usize = @min(5, entries.items.len);
    std.debug.print("# 0079.15 Top Opcode Sequences\n\n", .{});
    std.debug.print("Weighted by benchmark iteration counts from `tests/performance/perf_runner.zig`.\n\n", .{});
    std.debug.print("| Rank | Opcode Sequence | Weighted Count |\n", .{});
    std.debug.print("| ---: | :--- | ---: |\n", .{});

    for (entries.items[0..top_n], 0..) |e, i| {
        const a = keyA(e.key);
        const b = keyB(e.key);
        std.debug.print("| {d} | `{s} -> {s}` | {d} |\n", .{
            i + 1,
            @tagName(a),
            @tagName(b),
            e.count,
        });
    }

    std.debug.print("\n## Scenario Coverage\n\n", .{});
    for (scenarios) |sc| {
        std.debug.print("- `{s}`: `{s}` (weight {d})\n", .{ sc.name, sc.expr, sc.weight });
    }
}
