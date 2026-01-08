//! Kahn topological sort — port of `src/ts/graph/topo.ts`.

const std = @import("std");
const schema = @import("schema.zig");

pub const GraphRefSource = struct {
    node_id: []const u8,
    port: []const u8,
};

pub const Topology = struct {
    /// Nodes in evaluation order.
    ordered: []schema.GraphNode,
    /// node_id → (port → source).
    incoming: std.StringHashMap(std.StringHashMap(GraphRefSource)),
    /// Unused on success (kept for API symmetry).
    cycle_nodes: []const u8 = &.{},

    pub fn deinit(self: *Topology, allocator: std.mem.Allocator) void {
        var it = self.incoming.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.incoming.deinit();
        allocator.free(self.ordered);
        if (self.cycle_nodes.len > 0) allocator.free(self.cycle_nodes);
        self.* = undefined;
    }
};

pub const TopoError = error{
    EmptyNodeId,
    DuplicateNode,
    EdgeSourceMissing,
    EdgeTargetMissing,
    EdgeSourceMustBeOut,
    MultipleSources,
    Cycle,
} || error{OutOfMemory};

/// Last cycle node list from a failed `topoSort` (owned). Call `takeLastCycleNodes`.
var last_cycle_nodes: ?[]const u8 = null;
var last_cycle_allocator: ?std.mem.Allocator = null;

/// Take ownership of the cycle node list from the last failed topoSort.
/// Returns empty slice if none. Caller frees with the same allocator used for topoSort.
pub fn takeLastCycleNodes() []const u8 {
    const s = last_cycle_nodes orelse return &.{};
    last_cycle_nodes = null;
    last_cycle_allocator = null;
    return s;
}

fn freeIncoming(incoming: *std.StringHashMap(std.StringHashMap(GraphRefSource))) void {
    var iit = incoming.iterator();
    while (iit.next()) |e| e.value_ptr.deinit();
    incoming.deinit();
}

/// Kahn topo-sort. On cycle, returns error.Cycle; call `takeLastCycleNodes()` for names.
pub fn topoSort(
    allocator: std.mem.Allocator,
    nodes: []const schema.GraphNode,
    edges: []const schema.GraphEdge,
) TopoError!Topology {
    var by_id = std.StringHashMap(schema.GraphNode).init(allocator);
    defer by_id.deinit();

    for (nodes) |node| {
        const nid = node.id();
        if (nid.len == 0) return error.EmptyNodeId;
        const gop = try by_id.getOrPut(nid);
        if (gop.found_existing) return error.DuplicateNode;
        gop.value_ptr.* = node;
    }

    var outgoing = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var oit = outgoing.iterator();
        while (oit.next()) |e| e.value_ptr.deinit(allocator);
        outgoing.deinit();
    }

    var indegree = std.StringHashMap(usize).init(allocator);
    defer indegree.deinit();

    var incoming = std.StringHashMap(std.StringHashMap(GraphRefSource)).init(allocator);
    // Ownership transferred to Topology on success; freed manually on error.

    for (nodes) |node| {
        const nid = node.id();
        try outgoing.put(nid, .empty);
        try indegree.put(nid, 0);
        try incoming.put(nid, std.StringHashMap(GraphRefSource).init(allocator));
    }

    for (edges) |edge| {
        const from = schema.parseGraphRef(edge.from) catch {
            freeIncoming(&incoming);
            return error.EdgeSourceMissing;
        };
        const to = schema.parseGraphRef(edge.to) catch {
            freeIncoming(&incoming);
            return error.EdgeTargetMissing;
        };
        if (!by_id.contains(from.node_id)) {
            freeIncoming(&incoming);
            return error.EdgeSourceMissing;
        }
        if (!by_id.contains(to.node_id)) {
            freeIncoming(&incoming);
            return error.EdgeTargetMissing;
        }
        if (!std.mem.eql(u8, from.port, "out")) {
            freeIncoming(&incoming);
            return error.EdgeSourceMustBeOut;
        }

        const target_inputs = incoming.getPtr(to.node_id).?;
        const gop = target_inputs.getOrPut(to.port) catch {
            freeIncoming(&incoming);
            return error.OutOfMemory;
        };
        if (gop.found_existing) {
            freeIncoming(&incoming);
            return error.MultipleSources;
        }
        gop.value_ptr.* = .{ .node_id = from.node_id, .port = from.port };

        outgoing.getPtr(from.node_id).?.append(allocator, to.node_id) catch {
            freeIncoming(&incoming);
            return error.OutOfMemory;
        };
        const deg = indegree.getPtr(to.node_id).?;
        deg.* += 1;
    }

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(allocator);
    for (nodes) |node| {
        const nid = node.id();
        if (indegree.get(nid).? == 0) {
            queue.append(allocator, nid) catch {
                freeIncoming(&incoming);
                return error.OutOfMemory;
            };
        }
    }

    var ordered: std.ArrayListUnmanaged(schema.GraphNode) = .empty;

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node_id = queue.items[head];
        ordered.append(allocator, by_id.get(node_id).?) catch {
            ordered.deinit(allocator);
            freeIncoming(&incoming);
            return error.OutOfMemory;
        };
        const outs = outgoing.get(node_id) orelse continue;
        for (outs.items) |next| {
            const deg = indegree.getPtr(next).?;
            deg.* -= 1;
            if (deg.* == 0) {
                queue.append(allocator, next) catch {
                    ordered.deinit(allocator);
                    freeIncoming(&incoming);
                    return error.OutOfMemory;
                };
            }
        }
    }

    if (ordered.items.len != nodes.len) {
        var cycle_buf: std.ArrayListUnmanaged(u8) = .empty;
        var first = true;
        for (nodes) |node| {
            const nid = node.id();
            if ((indegree.get(nid) orelse 0) > 0) {
                if (!first) cycle_buf.appendSlice(allocator, ", ") catch {};
                first = false;
                cycle_buf.appendSlice(allocator, nid) catch {};
            }
        }
        const cycle_nodes = cycle_buf.toOwnedSlice(allocator) catch &.{};
        ordered.deinit(allocator);
        freeIncoming(&incoming);

        if (last_cycle_nodes) |prev| {
            if (last_cycle_allocator) |a| a.free(prev);
        }
        last_cycle_nodes = if (cycle_nodes.len > 0) cycle_nodes else null;
        last_cycle_allocator = allocator;
        return error.Cycle;
    }

    const ordered_slice = ordered.toOwnedSlice(allocator) catch {
        ordered.deinit(allocator);
        freeIncoming(&incoming);
        return error.OutOfMemory;
    };

    return .{
        .ordered = ordered_slice,
        .incoming = incoming,
        .cycle_nodes = &.{},
    };
}

test "topoSort linear chain" {
    const allocator = std.testing.allocator;
    const nodes = [_]schema.GraphNode{
        .{ .input = .{ .id = "a", .name = "a", .kind = .number } },
        .{ .expr = .{
            .id = "b",
            .expr = "x + 1",
            .inputs = &.{"x"},
            .input_kinds = &.{.number},
            .params = &.{},
            .output_kind = .number,
        } },
    };
    const edges = [_]schema.GraphEdge{
        .{ .from = "a.out", .to = "b.x" },
    };
    var top = try topoSort(allocator, &nodes, &edges);
    defer top.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), top.ordered.len);
    try std.testing.expectEqualStrings("a", top.ordered[0].id());
    try std.testing.expectEqualStrings("b", top.ordered[1].id());
}

test "topoSort detects cycle" {
    const allocator = std.testing.allocator;
    const nodes = [_]schema.GraphNode{
        .{ .expr = .{
            .id = "a",
            .expr = "x + 1",
            .inputs = &.{"x"},
            .input_kinds = &.{.number},
            .params = &.{},
            .output_kind = .number,
        } },
        .{ .expr = .{
            .id = "b",
            .expr = "x * 2",
            .inputs = &.{"x"},
            .input_kinds = &.{.number},
            .params = &.{},
            .output_kind = .number,
        } },
    };
    const edges = [_]schema.GraphEdge{
        .{ .from = "a.out", .to = "b.x" },
        .{ .from = "b.out", .to = "a.x" },
    };
    const result = topoSort(allocator, &nodes, &edges);
    try std.testing.expectError(error.Cycle, result);
    const cycle = takeLastCycleNodes();
    defer allocator.free(cycle);
    try std.testing.expect(cycle.len > 0);
}
