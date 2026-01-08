const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const Value = mathzig.Value;
const Generator = @import("generator.zig").Generator;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use a fixed seed for reproducibility if provided, otherwise timestamp
    var seed: u64 = undefined;
    var args = std.process.args();
    _ = args.skip(); // skip binary name
    if (args.next()) |seed_str| {
        seed = try std.fmt.parseInt(u64, seed_str, 10);
    } else {
        seed = @intCast(std.time.timestamp());
    }

    std.debug.print("Starting fuzzer with seed: {d}\n", .{seed});
    
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var gen = Generator.init(allocator, random);
    
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Setup common variables for fuzzing
    setupFuzzVariables(ctx, allocator) catch |err| {
        std.debug.print("Failed to setup variables: {any}\n", .{err});
        return;
    };

    const num_iterations = 1000;
    var i: usize = 0;
    while (i < num_iterations) : (i += 1) {
        if (i % 100 == 0) std.debug.print("Iteration {d}...\n", .{i});

        // Use a sub-arena for per-iteration generation strings
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        gen.allocator = arena.allocator();

        const expr_str = try gen.generateExpression(0);
        const assigned_expr = try std.fmt.allocPrint(arena.allocator(), "fuzz_res = {s}", .{expr_str});
        
        const result = ctx.eval(assigned_expr) catch |err| {
            // It's okay if it fails to parse or execute due to random types
            if (i % 100 == 0) std.debug.print("Iteration {d} failed gracefully: {any}\n", .{ i, err });
            continue;
        };

        result.release();
    }

    std.debug.print("Fuzzing completed successfully ({d} iterations).\n", .{num_iterations});
}

fn setupFuzzVariables(ctx: *MathZig, allocator: std.mem.Allocator) !void {
    ctx.setNumber("x", 10.5);
    ctx.setNumber("y", -2.0);
    ctx.setNumber("z", 0.0);
    
    // Setup a matrix
    const m = try mathzig.Matrix.init(allocator, 2, 2);
    m.set(0, 0, 1); m.set(0, 1, 2);
    m.set(1, 0, 3); m.set(1, 1, 4);
    ctx.setVariable("m", Value{ .tag = .matrix, .data = .{ .matrix = m } });

    // Setup a series
    const s = try mathzig.timeseries.Series.init(allocator, 5, .Linear, .{});
    for (0..5) |idx| {
        s.timestamps[idx] = @floatFromInt(idx);
        s.values[idx] = @floatFromInt(idx * 10);
    }
    ctx.setVariable("s", Value.initSeries(s));
}
