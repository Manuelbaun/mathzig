const std = @import("std");

const Node = struct {
    key: i32,
    left: ?*Node,
    right: ?*Node,
};

fn insert(root: ?*Node, key: i32, allocator: std.mem.Allocator) !?*Node {
    if (root) |n| {
        if (key < n.key) {
            n.left = try insert(n.left, key, allocator);
        } else if (key > n.key) {
            n.right = try insert(n.right, key, allocator);
        }
        return n;
    }
    const node = try allocator.create(Node);
    node.* = .{ .key = key, .left = null, .right = null };
    return node;
}

fn search(root: ?*Node, key: i32) bool {
    var current = root;
    while (current) |n| {
        if (key == n.key) return true;
        current = if (key < n.key) n.left else n.right;
    }
    return false;
}

fn freeTree(root: ?*Node, allocator: std.mem.Allocator) void {
    if (root) |n| {
        freeTree(n.left, allocator);
        freeTree(n.right, allocator);
        allocator.destroy(n);
    }
}

fn lcgNext(state: *u32) u32 {
    state.* = state.* *% 1664525 +% 1013904223;
    return state.*;
}

pub fn benchBinaryTree(allocator: std.mem.Allocator, node_count: usize, lookups: usize) !f64 {
    var root: ?*Node = null;
    var state: u32 = 0xC0FFEE;

    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const key = @as(i32, @intCast(lcgNext(&state) % @as(u32, @intCast(node_count * 4))));
        root = try insert(root, key, allocator);
    }

    state = 0xBEEF;
    var checksum: f64 = 0;
    i = 0;
    while (i < lookups) : (i += 1) {
        const key = @as(i32, @intCast(lcgNext(&state) % @as(u32, @intCast(node_count * 4))));
        if (search(root, key)) checksum += 1;
    }

    freeTree(root, allocator);
    return checksum;
}