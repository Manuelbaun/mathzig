const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

fn nowNanos() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn mandelbrotIterations(cr: f64, ci: f64, max_iter: i32) i32 {
    var zr: f64 = 0;
    var zi: f64 = 0;
    var i: i32 = 0;
    while (i < max_iter) : (i += 1) {
        const zr2 = zr * zr;
        const zi2 = zi * zi;
        if (zr2 + zi2 > 4.0) return i;
        zi = 2.0 * zr * zi + ci;
        zr = zr2 - zi2 + cr;
    }
    return max_iter;
}

fn benchMandelbrot(width: usize, height: usize, max_iter: i32, repeats: usize) f64 {
    var checksum: f64 = 0;
    var r: usize = 0;
    while (r < repeats) : (r += 1) {
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const ci = (@as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height))) * 2.5 - 1.25;
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const cr = (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width))) * 3.5 - 2.0;
                checksum += @floatFromInt(mandelbrotIterations(cr, ci, max_iter));
            }
        }
    }
    return checksum;
}

const TreeNode = struct {
    key: i32,
    left: ?*TreeNode,
    right: ?*TreeNode,
};

fn treeInsert(root: ?*TreeNode, key: i32, allocator: std.mem.Allocator) !?*TreeNode {
    if (root) |n| {
        if (key < n.key) {
            n.left = try treeInsert(n.left, key, allocator);
        } else if (key > n.key) {
            n.right = try treeInsert(n.right, key, allocator);
        }
        return n;
    }
    const node = try allocator.create(TreeNode);
    node.* = .{ .key = key, .left = null, .right = null };
    return node;
}

fn treeSearch(root: ?*TreeNode, key: i32) bool {
    var current = root;
    while (current) |n| {
        if (key == n.key) return true;
        current = if (key < n.key) n.left else n.right;
    }
    return false;
}

fn treeFree(root: ?*TreeNode, allocator: std.mem.Allocator) void {
    if (root) |n| {
        treeFree(n.left, allocator);
        treeFree(n.right, allocator);
        allocator.destroy(n);
    }
}

fn lcgNext(state: *u32) u32 {
    state.* = state.* *% 1664525 +% 1013904223;
    return state.*;
}

fn benchBinaryTree(allocator: std.mem.Allocator, node_count: usize, lookups: usize) !f64 {
    var root: ?*TreeNode = null;
    var state: u32 = 0xC0FFEE;

    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const key = @as(i32, @intCast(lcgNext(&state) % @as(u32, @intCast(node_count * 4))));
        root = try treeInsert(root, key, allocator);
    }

    state = 0xBEEF;
    var checksum: f64 = 0;
    i = 0;
    while (i < lookups) : (i += 1) {
        const key = @as(i32, @intCast(lcgNext(&state) % @as(u32, @intCast(node_count * 4))));
        if (treeSearch(root, key)) checksum += 1;
    }

    treeFree(root, allocator);
    return checksum;
}

fn logResult(
    timestamp: []const u8,
    feature_id: []const u8,
    test_name: []const u8,
    iterations: usize,
    duration_ms: f64,
    checksum: f64,
) void {
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);
    std.debug.print("{s},{s},{s},{d},{d:.4},{d:.2},0,0,0,checksum={d:.6}\n", .{
        timestamp, feature_id, test_name, iterations, duration_ms, ops_per_sec, checksum,
    });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}) .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.next();

    const feature_id = args.next() orelse "baseline";

    var buf: [64]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(&buf, "{d}", .{c.time(null)});

    {
        const width: usize = 160;
        const height: usize = 160;
        const max_iter: i32 = 500;
        const pixels_per_pass = width * height;
        const target_iters: usize = 2 * 1000 * 1000;
        const repeats = target_iters / pixels_per_pass;
        const iterations = repeats * pixels_per_pass;

        const start_ns = nowNanos();
        const checksum = benchMandelbrot(width, height, max_iter, repeats);
        const duration_ms = @as(f64, @floatFromInt(nowNanos() - start_ns)) / 1_000_000.0;
        logResult(timestamp, feature_id, "ref_zig_mandelbrot", iterations, duration_ms, checksum);
    }

    {
        const node_count: usize = 400_000;
        const lookups: usize = 2_000_000;

        const start_ns = nowNanos();
        const checksum = try benchBinaryTree(allocator, node_count, lookups);
        const duration_ms = @as(f64, @floatFromInt(nowNanos() - start_ns)) / 1_000_000.0;
        logResult(timestamp, feature_id, "ref_zig_binarytree_search", lookups, duration_ms, checksum);
    }
}