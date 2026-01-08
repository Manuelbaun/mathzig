//! Emit Spec 03 fuse golden .wasm fixtures for Bun instantiate tests.
//!
//! Built via `zig build emit-fuse-goldens` (see build.zig).
//! Writes chain_table / chain_named / diamond_named / params_named under out dir.

const std = @import("std");
const mathzig = @import("mathzig");
const wasm = mathzig.wasm;
const gm = wasm.graph_manifest;

const ByteBuf = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    pub fn writeByte(self: *const ByteBuf, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }
    pub fn writeAll(self: *const ByteBuf, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

fn writeWasm(compiler: *wasm.compiler.WasmCompiler, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    errdefer buffer.deinit(allocator);
    const writer = ByteBuf{ .list = &buffer, .allocator = allocator };
    try compiler.writeTo(writer);
    return try buffer.toOwnedSlice(allocator);
}

fn resetPorts(ctx: *mathzig.MathZig, names: []const []const u8) !void {
    ctx.variables.clearAndFree();
    ctx.next_var_index = 0;
    for (names) |n| ctx.setNumber(n, 0);
    try ctx.initConstants();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next(); // exe
    const out_dir = args.next() orelse "tests/artifacts/fuse";

    std.Io.Dir.createDirPath(.cwd(), io, out_dir) catch {};

    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // ── chain ────────────────────────────────────────────────────────────
    {
        try resetPorts(ctx, &.{"x"});
        const e_mul = try ctx.compile("x * 2");
        defer ctx.freeExpr(e_mul);
        try resetPorts(ctx, &.{"y"});
        const e_add = try ctx.compile("y + 1");
        defer ctx.freeExpr(e_add);

        const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
        const nodes = [_]wasm.compiler.FuseNodeUnit{
            .{ .id = "mul", .expr = e_mul, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
            .{ .id = "add", .expr = e_add, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }} },
        };
        const outputs = [_]wasm.compiler.FuseOutput{
            .{ .name = "y", .kind = .number, .from_node = 1 },
        };

        {
            var c = wasm.compiler.WasmCompiler.init(allocator);
            defer c.deinit();
            try c.compileFusedTick(.{
                .inputs = &inputs,
                .nodes = &nodes,
                .outputs = &outputs,
                .out_mode = .table,
            }, .{});
            const bytes = try writeWasm(&c, allocator);
            defer allocator.free(bytes);
            const path = try std.fmt.allocPrint(allocator, "{s}/chain_table.wasm", .{out_dir});
            defer allocator.free(path);
            try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = bytes });
        }
        {
            var c = wasm.compiler.WasmCompiler.init(allocator);
            defer c.deinit();
            try c.compileFusedTick(.{
                .inputs = &inputs,
                .nodes = &nodes,
                .outputs = &outputs,
                .out_mode = .named_exports,
            }, .{});
            const bytes = try writeWasm(&c, allocator);
            defer allocator.free(bytes);
            const path = try std.fmt.allocPrint(allocator, "{s}/chain_named.wasm", .{out_dir});
            defer allocator.free(path);
            try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = bytes });
        }
        // Spec 04 T2: mid + end outputs from the same chain.
        {
            const outs2 = [_]wasm.compiler.FuseOutput{
                .{ .name = "mid", .kind = .number, .from_node = 0 },
                .{ .name = "end", .kind = .number, .from_node = 1 },
            };
            var c = wasm.compiler.WasmCompiler.init(allocator);
            defer c.deinit();
            try c.compileFusedTick(.{
                .inputs = &inputs,
                .nodes = &nodes,
                .outputs = &outs2,
                .out_mode = .named_exports,
            }, .{});
            const bytes = try writeWasm(&c, allocator);
            defer allocator.free(bytes);
            const path = try std.fmt.allocPrint(allocator, "{s}/chain_two_named.wasm", .{out_dir});
            defer allocator.free(path);
            try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = bytes });
        }
    }

    // ── diamond ──────────────────────────────────────────────────────────
    {
        try resetPorts(ctx, &.{"x"});
        const e_a = try ctx.compile("x * 2");
        defer ctx.freeExpr(e_a);
        try resetPorts(ctx, &.{"a"});
        const e_b = try ctx.compile("a + 1");
        defer ctx.freeExpr(e_b);
        try resetPorts(ctx, &.{"a"});
        const e_c = try ctx.compile("a * 3");
        defer ctx.freeExpr(e_c);

        const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
        const nodes = [_]wasm.compiler.FuseNodeUnit{
            .{ .id = "A", .expr = e_a, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .graph_input = 0 }} },
            .{ .id = "B", .expr = e_b, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }} },
            .{ .id = "C", .expr = e_c, .arg_sources = &[_]wasm.compiler.FuseArgSource{.{ .node_result = 0 }} },
        };
        const outputs = [_]wasm.compiler.FuseOutput{
            .{ .name = "u", .kind = .number, .from_node = 1 },
            .{ .name = "v", .kind = .number, .from_node = 2 },
        };

        var c = wasm.compiler.WasmCompiler.init(allocator);
        defer c.deinit();
        try c.compileFusedTick(.{
            .inputs = &inputs,
            .nodes = &nodes,
            .outputs = &outputs,
            .out_mode = .named_exports,
        }, .{});
        const bytes = try writeWasm(&c, allocator);
        defer allocator.free(bytes);
        const path = try std.fmt.allocPrint(allocator, "{s}/diamond_named.wasm", .{out_dir});
        defer allocator.free(path);
        try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = bytes });
    }

    // ── params ───────────────────────────────────────────────────────────
    {
        try resetPorts(ctx, &.{ "x", "k" });
        const e = try ctx.compile("x * k");
        defer ctx.freeExpr(e);

        const inputs = [_]gm.Port{.{ .name = "x", .kind = .number }};
        const params = [_]gm.Port{.{ .name = "gain.k", .kind = .number, .default = 1.0 }};
        const nodes = [_]wasm.compiler.FuseNodeUnit{
            .{
                .id = "gain",
                .expr = e,
                .arg_sources = &[_]wasm.compiler.FuseArgSource{
                    .{ .graph_input = 0 },
                    .{ .graph_param = 0 },
                },
            },
        };
        const outputs = [_]wasm.compiler.FuseOutput{
            .{ .name = "y", .kind = .number, .from_node = 0 },
        };

        var c = wasm.compiler.WasmCompiler.init(allocator);
        defer c.deinit();
        try c.compileFusedTick(.{
            .inputs = &inputs,
            .params = &params,
            .nodes = &nodes,
            .outputs = &outputs,
            .out_mode = .named_exports,
        }, .{});
        const bytes = try writeWasm(&c, allocator);
        defer allocator.free(bytes);
        const path = try std.fmt.allocPrint(allocator, "{s}/params_named.wasm", .{out_dir});
        defer allocator.free(path);
        try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = bytes });
    }

    std.debug.print("Wrote fuse goldens to {s}/\n", .{out_dir});
}
