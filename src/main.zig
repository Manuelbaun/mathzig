///! MathZig REPL - Interactive math expression evaluator
const std = @import("std");
const builtin = @import("builtin");
const mathzig = @import("mathzig");
const diagnostics = @import("core/diagnostics.zig");

const MathZig = mathzig.MathZig;
const Value = mathzig.Value;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Reset variables to ensure x, y, z get indices 0, 1, 2
    // Initialize them to 0 so they're recognized as valid number variables
    ctx.variables.clearAndFree();
    ctx.next_var_index = 0;
    ctx.setNumber("x", 0);
    ctx.setNumber("y", 0);
    ctx.setNumber("z", 0);

    // Re-initialize constants after our parameters
    try ctx.initConstants();

    // Check for command line arguments (exec mode)
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    // Skip executable name
    _ = args.next();

    if (args.next()) |first_arg| {
        // Handle 'graph' subcommand (VM-native graph evaluator v1)
        if (std.mem.eql(u8, first_arg, "graph")) {
            try runGraphCommand(io, allocator, ctx, &args);
            return;
        }

        // Handle 'compile-graph' subcommand (Spec 05 fused multi-root AOT)
        if (std.mem.eql(u8, first_arg, "compile-graph")) {
            try runCompileGraphCommand(io, allocator, ctx, &args);
            return;
        }

        // Handle 'compile' subcommand
        if (std.mem.eql(u8, first_arg, "compile")) {
            const node_manifest = mathzig.wasm.node_manifest;
            const abi = mathzig.wasm.abi;

            var input_path: ?[]const u8 = null;
            var output_path: ?[]const u8 = null;
            var func_name: []const u8 = "eval";
            var expression: ?[]const u8 = null;
            var num_params: usize = 0;
            var standalone = false;
            var verbose = false;
            var node_mode = false;
            var out_kind: ?abi.WireKind = null;
            var node_inputs = std.ArrayListUnmanaged(PortDecl).empty;
            defer node_inputs.deinit(allocator);
            var node_params = std.ArrayListUnmanaged(PortDecl).empty;
            defer node_params.deinit(allocator);

            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
                    input_path = args.next();
                } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                    output_path = args.next();
                } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--func")) {
                    if (args.next()) |name| func_name = name;
                } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--params")) {
                    if (args.next()) |val| {
                        num_params = std.fmt.parseInt(usize, val, 10) catch 0;
                    }
                } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--standalone")) {
                    standalone = true;
                } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                    verbose = true;
                } else if (std.mem.eql(u8, arg, "--node")) {
                    node_mode = true;
                } else if (std.mem.eql(u8, arg, "--in")) {
                    const spec = args.next() orelse {
                        std.debug.print("Error: --in requires <name>:<kind>\n", .{});
                        std.process.exit(1);
                    };
                    const port = parsePortSpec(spec, false) catch |err| {
                        std.debug.print("Error parsing --in '{s}': {s}\n", .{ spec, @errorName(err) });
                        std.process.exit(1);
                    };
                    try node_inputs.append(allocator, port);
                } else if (std.mem.eql(u8, arg, "--param")) {
                    const spec = args.next() orelse {
                        std.debug.print("Error: --param requires <name>:<kind>[=default]\n", .{});
                        std.process.exit(1);
                    };
                    const port = parsePortSpec(spec, true) catch |err| {
                        std.debug.print("Error parsing --param '{s}': {s}\n", .{ spec, @errorName(err) });
                        std.process.exit(1);
                    };
                    try node_params.append(allocator, port);
                } else if (std.mem.eql(u8, arg, "--out")) {
                    const kind_name = args.next() orelse {
                        std.debug.print("Error: --out requires <kind>\n", .{});
                        std.process.exit(1);
                    };
                    out_kind = node_manifest.parseKindName(kind_name) orelse {
                        std.debug.print("Error: unknown output kind '{s}'\n", .{kind_name});
                        std.process.exit(1);
                    };
                } else {
                    if (expression == null) expression = arg;
                }
            }

            if (output_path == null) {
                std.debug.print(
                    \\Usage: mathzig compile [-i <input.mz> | <expression>] -o <output.wasm>
                    \\         [-f <func_name>] [-p <num_params>] [-s|--standalone] [-v]
                    \\         [--node --in <name>:<kind> ... --param <name>:<kind>[=default] ... --out <kind>]
                    \\
                , .{});
                std.process.exit(1);
            }

            if (node_mode) {
                if (out_kind == null) {
                    std.debug.print("Error: --node requires --out <kind>\n", .{});
                    std.process.exit(1);
                }
                // Node modules use declared ports as ordered eval params
                // (inputs first, then trailing config params).
                num_params = node_inputs.items.len + node_params.items.len;

                // Rebuild the variable table so declared ports map to param
                // indices 0..N-1 in declaration order.
                ctx.variables.clearAndFree();
                ctx.next_var_index = 0;
                for (node_inputs.items) |port| {
                    ctx.setNumber(port.name, 0);
                }
                for (node_params.items) |port| {
                    ctx.setNumber(port.name, port.default orelse 0);
                }
                try ctx.initConstants();
            }

            var source: []const u8 = undefined;
            var source_is_alloced = false;
            defer if (source_is_alloced) allocator.free(source);

            if (input_path) |path| {
                source = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| {
                    std.debug.print("Error reading input file: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                };
                source_is_alloced = true;
            } else if (expression) |expr| {
                source = expr;
                source_is_alloced = false;
            } else {
                std.debug.print("Error: No input file or expression provided.\n", .{});
                std.process.exit(1);
            }

            const expr = ctx.compile(source) catch |err| {
                std.debug.print("Failed Source: {s}\n", .{source});
                std.debug.print("Compilation Error: {s}\n", .{ctx.lastError()});
                if (ctx.last_error_len == 0) std.debug.print("System Error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer ctx.freeExpr(expr);

            if (node_mode) {
                // Validate declared ports against variables used by the expression.
                // load_var / fused load_var_index* operands are variable indices.
                var used = std.AutoHashMap(u8, void).init(allocator);
                defer used.deinit();
                for (expr.code) |inst| {
                    switch (inst.opcode) {
                        .load_var, .store_var => try used.put(@intCast(inst.operand), {}),
                        .load_var_index_0, .load_var_index_1, .load_var_index_2, .load_var_index_3, .load_var_index_const => {
                            try used.put(@intCast(inst.operand & 0x0FFF), {});
                        },
                        .load_mul, .load_sub => {
                            // operand = var_a (12) | var_b (12)
                            try used.put(@intCast(inst.operand & 0x0FFF), {});
                            try used.put(@intCast((inst.operand >> 12) & 0x0FFF), {});
                        },
                        .fma_var_const_const => {
                            try used.put(@intCast(inst.operand & 0x0FFF), {});
                        },
                        else => {},
                    }
                }

                // Build the set of allowed names: declared ports + nothing else
                // for free vars. Constants (pi, e, …) are registered by
                // initConstants and are allowed when used.
                var allowed = std.StringHashMap(void).init(allocator);
                defer allowed.deinit();
                for (node_inputs.items) |port| try allowed.put(port.name, {});
                for (node_params.items) |port| try allowed.put(port.name, {});

                // Any used variable whose name is not a declared port and not a
                // pre-existing constant is an undeclared port.
                var vit = ctx.variables.iterator();
                while (vit.next()) |entry| {
                    const name = entry.key_ptr.*;
                    const idx: u8 = @intCast(entry.value_ptr.*);
                    if (!used.contains(idx)) continue;
                    if (allowed.contains(name)) continue;
                    // Constants land at indices ≥ num_params and were present
                    // after initConstants — treat non-port used names as errors
                    // only when they were introduced as free variables (i.e.
                    // not known constants). Heuristic: names that are declared
                    // ports or standard constants are fine; anything else used
                    // is an error.
                    if (idx >= num_params and isBuiltinConstantName(name)) continue;
                    std.debug.print("Error: expression uses undeclared port '{s}'\n", .{name});
                    std.process.exit(1);
                }

                // Every declared input must appear (params may be unused defaults).
                for (node_inputs.items) |port| {
                    const vi = ctx.variables.get(port.name) orelse {
                        std.debug.print("Error: declared input '{s}' is not a variable\n", .{port.name});
                        std.process.exit(1);
                    };
                    if (!used.contains(@intCast(vi))) {
                        std.debug.print("Error: declared input '{s}' is not used by the expression\n", .{port.name});
                        std.process.exit(1);
                    }
                }
            }

            var compiler = mathzig.wasm.compiler.WasmCompiler.init(allocator);
            defer compiler.deinit();

            // Find variables that are assigned to (store_var) - these can't be globals
            var assigned_vars = std.AutoHashMap(u8, void).init(allocator);
            defer assigned_vars.deinit();
            for (expr.code) |inst| {
                if (inst.opcode == .store_var) {
                    try assigned_vars.put(@intCast(inst.operand), {});
                }
            }

            // Populate globals from context (excluding parameters and assigned variables)
            var v_it = ctx.variables.iterator();
            while (v_it.next()) |entry| {
                const v_idx = entry.value_ptr.*;
                if (v_idx >= num_params and !assigned_vars.contains(@intCast(v_idx))) {
                    const val = ctx.vm.variables[v_idx];
                    if (val.tag == .number) {
                        try compiler.globals.put(@intCast(v_idx), val.data.number);
                    }
                }
            }

            // Seed param ValueTags from declared node ports so e.g.
            // `--in x:matrix` types x as matrix even for `x * alpha`.
            var param_tag_buf: []mathzig.ValueTag = &.{};
            defer if (param_tag_buf.len > 0) allocator.free(param_tag_buf);
            if (node_mode and num_params > 0) {
                param_tag_buf = try allocator.alloc(mathzig.ValueTag, num_params);
                var ti: usize = 0;
                for (node_inputs.items) |p| {
                    param_tag_buf[ti] = wireKindToValueTag(p.kind);
                    ti += 1;
                }
                for (node_params.items) |p| {
                    param_tag_buf[ti] = wireKindToValueTag(p.kind);
                    ti += 1;
                }
            }

            compiler.compile(expr, .{
                .function_name = func_name,
                .num_params = num_params,
                .standalone = standalone,
                .verbose = verbose,
                .force_heap = node_mode,
                // Node modules always take N params; batch export is for 1-param
                // numeric roots only and is not meaningful under --node.
                .export_batch = !node_mode,
                .param_tags = if (param_tag_buf.len > 0) param_tag_buf else null,
            }) catch |err| {
                if (err == error.StandaloneUnsupportedImport) {
                    if (compiler.standalone_error_msg) |msg| {
                        std.debug.print("WASM Backend Error: {s}\n", .{msg});
                    } else {
                        std.debug.print("WASM Backend Error: standalone build needs unsupported host import.\n", .{});
                    }
                    std.process.exit(1);
                }
                std.debug.print("WASM Backend Error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };

            if (node_mode) {
                // Build port slices for the manifest (owned names are CLI argv
                // pointers; they outlive this scope for the write).
                var in_ports = try allocator.alloc(node_manifest.Port, node_inputs.items.len);
                defer allocator.free(in_ports);
                for (node_inputs.items, 0..) |p, i| {
                    in_ports[i] = .{ .name = p.name, .kind = p.kind };
                }
                var param_ports = try allocator.alloc(node_manifest.Port, node_params.items.len);
                defer allocator.free(param_ports);
                for (node_params.items, 0..) |p, i| {
                    param_ports[i] = .{ .name = p.name, .kind = p.kind, .default = p.default };
                }
                const result_tag = node_manifest.kindToResultTag(out_kind.?);
                // Prefer the compiler's statically-inferred result tag when it
                // matches a concrete non-any kind; otherwise trust --out.
                const inferred = @tagName(compiler.result_tag);
                const use_inferred = !std.mem.eql(u8, result_tag, "number") or
                    std.mem.eql(u8, inferred, "number") or
                    std.mem.eql(u8, inferred, "boolean") or
                    std.mem.eql(u8, inferred, "unit");
                const tag_for_manifest: []const u8 = if (use_inferred and
                    (std.mem.eql(u8, inferred, result_tag) or
                        (std.mem.eql(u8, result_tag, "number") and
                            (std.mem.eql(u8, inferred, "number") or std.mem.eql(u8, inferred, "unit")))))
                    inferred
                else
                    result_tag;

                const nm = node_manifest.NodeManifest{
                    .name = func_name,
                    .inputs = in_ports,
                    .params = param_ports,
                    .output = .{
                        .name = "out",
                        .kind = out_kind.?,
                        .result_tag = tag_for_manifest,
                    },
                };
                try node_manifest.emitCustomSection(&compiler.module, allocator, nm);

                // JSON sidecar next to the .wasm (foo.wasm → foo.node.json).
                const sidecar = try sidecarPath(allocator, output_path.?);
                defer allocator.free(sidecar);
                const json = try node_manifest.toJsonAlloc(allocator, nm);
                defer allocator.free(json);
                try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = sidecar, .data = json });
            }

            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try compiler.writeTo(&aw.writer);
            try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = output_path.?, .data = aw.written() });

            std.debug.print("Compiled to {s} ({d} bytes)\n", .{ output_path.?, aw.written().len });
            return;
        }

        // Default: Execute expression
        const expr = ctx.compile(first_arg) catch |err| {
            std.debug.print("Error compiling: {s}\n", .{ctx.lastError()});
            if (ctx.last_error_len == 0) std.debug.print("System Error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer ctx.freeExpr(expr);

        const result = ctx.evaluate(expr) catch |err| {
            std.debug.print("Error evaluating: {s}\n", .{ctx.lastError()});
            if (ctx.last_error_len == 0) std.debug.print("System Error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer result.release();

        var format_buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&format_buf);
        try ctx.formatValue(result, &writer);
        std.debug.print("{s}\n", .{writer.buffered()});
        return;
    }

    // Interactive REPL
    std.debug.print("MathZig REPL (Zig {s})\n", .{builtin.zig_version_string});
    std.debug.print("Type 'exit' to quit.\n", .{});

    var line_buf: [4096]u8 = undefined;
    const stdin = std.Io.File.stdin();
    while (true) {
        std.debug.print("> ", .{});
        const amt = std.Io.File.readStreaming(stdin, io, &.{&line_buf}) catch break;
        if (amt == 0) break;
        const line = std.mem.trim(u8, line_buf[0..amt], " \r\n\t");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) break;

        const expr = ctx.compile(line) catch |err| {
            const last_err = ctx.lastError();
            if (last_err.len > 0) {
                std.debug.print("Error compiling: {s}\n", .{last_err});
            } else {
                std.debug.print("System Error compiling: {s}\n", .{@errorName(err)});
            }
            continue;
        };
        defer ctx.freeExpr(expr);

        const result = ctx.evaluate(expr) catch |err| {
            const last_err = ctx.lastError();
            if (last_err.len > 0) {
                std.debug.print("Error evaluating: {s}\n", .{last_err});
            } else {
                std.debug.print("System Error evaluating: {s}\n", .{@errorName(err)});
            }
            continue;
        };
        defer result.release();

        var format_buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&format_buf);
        try ctx.formatValue(result, &writer);
        std.debug.print("{s}\n", .{writer.buffered()});
    }
}

/// `mathzig compile-graph -i graph.json -o out.wasm [-v] [--standalone] [--out-mode table|named_exports]`
///
/// Lowers the graph (Zig FusePlan), compiles a single fused wasm module, and
/// writes `out.wasm` plus a `out.graph.json` sidecar (mirrors `mathzig:graph`).
fn runCompileGraphCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    ctx: *MathZig,
    args: *std.process.Args.Iterator,
) !void {
    const graph_schema = mathzig.graph.schema;
    const fuse = mathzig.graph.fuse;
    const graph_manifest = mathzig.wasm.graph_manifest;
    const wasm_compiler = mathzig.wasm.compiler;

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var standalone = false;
    var verbose = false;
    var out_mode: graph_manifest.OutMode = .table;
    var export_node_helpers = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            input_path = args.next();
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--standalone")) {
            standalone = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--out-mode")) {
            const mode_name = args.next() orelse {
                std.debug.print("Error: --out-mode requires table|named_exports\n", .{});
                std.process.exit(1);
            };
            out_mode = graph_manifest.OutMode.parse(mode_name) orelse {
                std.debug.print("Error: unknown out-mode '{s}' (expected table|named_exports)\n", .{mode_name});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--export-node-helpers")) {
            export_node_helpers = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printCompileGraphUsage();
            return;
        } else {
            std.debug.print("Error: unexpected argument '{s}'\n", .{arg});
            printCompileGraphUsage();
            std.process.exit(1);
        }
    }

    if (input_path == null or output_path == null) {
        printCompileGraphUsage();
        std.process.exit(1);
    }

    const path = input_path.?;
    const out_wasm = output_path.?;

    const json_text = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("Error reading graph file '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(json_text);

    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const def = graph_schema.parseGraphDefinition(arena, json_text) catch |err| {
        std.debug.print("Error: invalid graph JSON ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer graph_schema.deinitConstValues(&def);

    const plan = fuse.lowerGraphToFusePlan(arena, allocator, def) catch |err| {
        const detail = fuse.lastError();
        if (detail.len > 0) {
            std.debug.print("Error: {s}\n", .{detail});
        } else {
            std.debug.print("Error lowering graph: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    if (plan.nodes.len == 0) {
        std.debug.print("Error: fuse plan has no compute nodes\n", .{});
        std.process.exit(1);
    }

    // Build index maps: input source node id → graph_input index;
    // const id → const index; expr node id → node_result index.
    var input_index = std.StringHashMap(u32).init(allocator);
    defer input_index.deinit();
    for (plan.inputs, 0..) |inp, i| {
        try input_index.put(inp.source_node_id, @intCast(i));
    }
    var const_index = std.StringHashMap(u32).init(allocator);
    defer const_index.deinit();
    for (plan.consts, 0..) |c, i| {
        try const_index.put(c.id, @intCast(i));
    }
    var node_index = std.StringHashMap(u32).init(allocator);
    defer node_index.deinit();
    for (plan.nodes, 0..) |n, i| {
        try node_index.put(n.id, @intCast(i));
    }

    // Stage B requires every output to be produced by a compute (expr) node.
    for (plan.outputs) |o| {
        if (!node_index.contains(o.from_node_id)) {
            std.debug.print(
                "Error: output '{s}' from '{s}' is not a compute node (fuse v1 requires expr producers)\n",
                .{ o.name, o.from_node_id },
            );
            std.process.exit(1);
        }
    }

    // Compile each node expr with real port names as variables (inputs then params).
    // Track `filled` so cleanup only frees initialized slots on mid-loop error returns.
    var filled: usize = 0;
    const compiled = try allocator.alloc(*mathzig.CompiledExpr, plan.nodes.len);
    const arg_source_bufs = try allocator.alloc([]wasm_compiler.FuseArgSource, plan.nodes.len);
    defer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            ctx.freeExpr(compiled[i]);
            allocator.free(arg_source_bufs[i]);
        }
        allocator.free(compiled);
        allocator.free(arg_source_bufs);
    }

    for (plan.nodes, 0..) |node, ni| {
        // Rebuild variable table so declared ports map to param indices 0..N-1.
        ctx.variables.clearAndFree();
        ctx.next_var_index = 0;
        for (node.inputs) |port| {
            ctx.setNumber(port, 0);
        }
        for (node.param_names) |pname| {
            ctx.setNumber(pname, 0);
        }
        try ctx.initConstants();

        const num_params = node.inputs.len + node.param_names.len;

        const expr = ctx.compile(node.expr) catch {
            std.debug.print("Error compiling node '{s}': {s}\n", .{ node.id, ctx.lastError() });
            std.process.exit(1);
        };

        // Validate free vars (same gate as `mathzig compile --node`).
        validateFuseNodePorts(allocator, ctx, expr, node, num_params) catch |err| {
            ctx.freeExpr(expr);
            if (err == error.OutOfMemory) return err;
            // validateFuseNodePorts prints and returns a sentinel for hard errors
            std.process.exit(1);
        };

        const n_args = num_params;
        var sources = try allocator.alloc(wasm_compiler.FuseArgSource, n_args);
        errdefer allocator.free(sources);

        for (node.inputs, 0..) |_, ii| {
            const producer = node.input_ports[ii];
            if (input_index.get(producer)) |gi| {
                sources[ii] = .{ .graph_input = gi };
            } else if (node_index.get(producer)) |ri| {
                sources[ii] = .{ .node_result = ri };
            } else if (const_index.get(producer)) |ci| {
                const c = plan.consts[ci];
                // Const args are baked as f64 immediates. Non-scalar consts cannot
                // be materialised that way — use an expr producer (or multi-module).
                if (c.kind != .number and c.kind != .boolean) {
                    std.debug.print(
                        "Error: const node '{s}' kind '{s}' cannot be fused as an immediate " ++
                            "(use an expr node that builds the value, or multi-module GraphRunner)\n",
                        .{ c.id, c.kind.name() },
                    );
                    std.process.exit(1);
                }
                const num: f64 = switch (c.value.tag) {
                    .number => c.value.data.number,
                    .boolean => if (c.value.data.boolean) @as(f64, 1) else @as(f64, 0),
                    else => {
                        std.debug.print(
                            "Error: const node '{s}' value tag is not number/boolean " ++
                                "(fused immediates are scalar only)\n",
                            .{c.id},
                        );
                        std.process.exit(1);
                    },
                };
                sources[ii] = .{ .const_value = num };
            } else {
                std.debug.print(
                    "Error: cannot resolve producer '{s}' for node '{s}' input\n",
                    .{ producer, node.id },
                );
                std.process.exit(1);
            }
        }

        // Params: flat order in plan.params is topo then Object.keys — match by node_id + param.
        for (node.param_names, 0..) |pname, pi| {
            var found: ?u32 = null;
            for (plan.params, 0..) |p, pidx| {
                if (std.mem.eql(u8, p.node_id, node.id) and std.mem.eql(u8, p.param, pname)) {
                    found = @intCast(pidx);
                    break;
                }
            }
            if (found) |pidx| {
                sources[node.inputs.len + pi] = .{ .graph_param = pidx };
            } else {
                std.debug.print(
                    "Error: param '{s}.{s}' missing from fuse plan\n",
                    .{ node.id, pname },
                );
                std.process.exit(1);
            }
        }

        compiled[ni] = expr;
        arg_source_bufs[ni] = sources;
        filled = ni + 1;
    }

    // Manifest ports (arena-owned names already stable).
    var in_ports = try arena.alloc(graph_manifest.Port, plan.inputs.len);
    for (plan.inputs, 0..) |inp, i| {
        in_ports[i] = .{
            .name = inp.name,
            .kind = portKindToWire(inp.kind),
        };
    }
    var param_ports = try arena.alloc(graph_manifest.Port, plan.params.len);
    for (plan.params, 0..) |p, i| {
        param_ports[i] = .{
            .name = p.name,
            .kind = .number,
            .default = p.default,
        };
    }

    var fuse_nodes = try arena.alloc(wasm_compiler.FuseNodeUnit, plan.nodes.len);
    for (plan.nodes, 0..) |node, i| {
        // Seed AOT param tags from declared inputKinds + number for params (Spec 07).
        const n_args = node.inputs.len + node.param_names.len;
        const arg_kinds = try arena.alloc(mathzig.wasm.abi.WireKind, n_args);
        for (node.input_kinds, 0..) |ik, ii| {
            arg_kinds[ii] = portKindToWire(ik);
        }
        for (0..node.param_names.len) |pi| {
            arg_kinds[node.inputs.len + pi] = .number;
        }
        fuse_nodes[i] = .{
            .id = node.id,
            .expr = compiled[i],
            .arg_sources = arg_source_bufs[i],
            .arg_kinds = arg_kinds,
            .output_kind = portKindToWire(node.output_kind),
        };
    }

    var fuse_outputs = try arena.alloc(wasm_compiler.FuseOutput, plan.outputs.len);
    for (plan.outputs, 0..) |o, i| {
        // Pre-checked: every output maps to a compute node.
        const from = node_index.get(o.from_node_id).?;
        fuse_outputs[i] = .{
            .name = o.name,
            .kind = portKindToWire(o.kind),
            .from_node = from,
        };
    }

    var compiler = wasm_compiler.WasmCompiler.init(allocator);
    defer compiler.deinit();

    // Seed globals from constants (same pattern as single-expr compile).
    // Per-node param offsets differ; fused tick passes all args explicitly so
    // free globals beyond per-node arity are not used as tick params.

    const fuse_plan = wasm_compiler.FuseCompilePlan{
        .inputs = in_ports,
        .params = param_ports,
        .nodes = fuse_nodes,
        .outputs = fuse_outputs,
        .out_mode = out_mode,
        .export_node_helpers = export_node_helpers,
        .entry_name = "tick",
    };

    compiler.compileFusedTick(fuse_plan, .{
        .standalone = standalone,
        .verbose = verbose,
        .emit_abi = true,
    }) catch |err| {
        if (err == error.StandaloneUnsupportedImport) {
            if (compiler.standalone_error_msg) |msg| {
                std.debug.print("Error: --standalone: {s}\n", .{msg});
            } else {
                std.debug.print("Error: --standalone build needs unsupported host import\n", .{});
            }
            std.process.exit(1);
        }
        if (err == error.NonScalarFuse) {
            std.debug.print(
                "Error: fuse rejects kind 'any' and non-number params " ++
                    "(use concrete matrix/complex/record/series/string kinds on ports; " ++
                    "params must stay number/boolean)\n",
                .{},
            );
            std.process.exit(1);
        }
        std.debug.print("WASM fuse compile error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try compiler.writeTo(&aw.writer);
    const wasm_bytes = aw.written();

    // Sidecar must match the mathzig:graph section exactly — missing section is a hard error.
    const section_json = graph_manifest.scanWasmGraphSection(wasm_bytes) orelse {
        std.debug.print(
            "Error: fused module missing mathzig:graph custom section (refusing to write artifact)\n",
            .{},
        );
        std.process.exit(1);
    };

    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = out_wasm, .data = wasm_bytes });

    const sidecar = try graphSidecarPath(allocator, out_wasm);
    defer allocator.free(sidecar);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = sidecar, .data = section_json });

    if (verbose) {
        std.debug.print(
            "compile-graph: {d} node(s), {d} input(s), {d} param(s), {d} output(s), out_mode={s}\n",
            .{ plan.nodes.len, plan.inputs.len, plan.params.len, plan.outputs.len, out_mode.jsonName() },
        );
    }
    std.debug.print("Compiled fused graph to {s} ({d} bytes)\n", .{ out_wasm, wasm_bytes.len });
    std.debug.print("Wrote graph sidecar {s}\n", .{sidecar});
}

/// Validate that a fused node expression only uses declared inputs/params
/// (plus builtin constants and locals assigned in the same expression).
///
/// Important: `store_var` defines a local (e.g. `mu = 3.98e14`) and must **not**
/// be treated as a free/undeclared port. Only **loads** of non-param, non-assigned
/// variables are free vars.
fn validateFuseNodePorts(
    allocator: std.mem.Allocator,
    ctx: *MathZig,
    expr: *const mathzig.CompiledExpr,
    node: mathzig.graph.fuse.FusePlanNode,
    num_params: usize,
) !void {
    var assigned = std.AutoHashMap(u8, void).init(allocator);
    defer assigned.deinit();
    var loaded = std.AutoHashMap(u8, void).init(allocator);
    defer loaded.deinit();

    // Process in program order so locals are defined before use.
    for (expr.code) |inst| {
        switch (inst.opcode) {
            .store_var => {
                try assigned.put(@intCast(inst.operand), {});
            },
            .load_var => {
                const idx: u8 = @intCast(inst.operand);
                try loaded.put(idx, {});
                if (idx < num_params) continue; // boundary input/param
                if (assigned.contains(idx)) continue; // local assigned earlier
                // Free local — resolve name for error / builtin allowlist.
                const name = varNameForIndex(ctx, idx) orelse continue;
                if (isBuiltinConstantName(name)) continue;
                std.debug.print(
                    "Error: node '{s}' expression uses undeclared port '{s}'\n",
                    .{ node.id, name },
                );
                return error.UndeclaredPort;
            },
            .load_var_index_0, .load_var_index_1, .load_var_index_2, .load_var_index_3, .load_var_index_const => {
                const idx: u8 = @intCast(inst.operand & 0x0FFF);
                try loaded.put(idx, {});
                if (idx < num_params) continue;
                if (assigned.contains(idx)) continue;
                const name = varNameForIndex(ctx, idx) orelse continue;
                if (isBuiltinConstantName(name)) continue;
                std.debug.print(
                    "Error: node '{s}' expression uses undeclared port '{s}'\n",
                    .{ node.id, name },
                );
                return error.UndeclaredPort;
            },
            .load_mul, .load_sub => {
                const a: u8 = @intCast(inst.operand & 0x0FFF);
                const b: u8 = @intCast((inst.operand >> 12) & 0x0FFF);
                for ([_]u8{ a, b }) |idx| {
                    try loaded.put(idx, {});
                    if (idx < num_params) continue;
                    if (assigned.contains(idx)) continue;
                    const name = varNameForIndex(ctx, idx) orelse continue;
                    if (isBuiltinConstantName(name)) continue;
                    std.debug.print(
                        "Error: node '{s}' expression uses undeclared port '{s}'\n",
                        .{ node.id, name },
                    );
                    return error.UndeclaredPort;
                }
            },
            .fma_var_const_const => {
                const idx: u8 = @intCast(inst.operand & 0x0FFF);
                try loaded.put(idx, {});
                if (idx < num_params) continue;
                if (assigned.contains(idx)) continue;
                const name = varNameForIndex(ctx, idx) orelse continue;
                if (isBuiltinConstantName(name)) continue;
                std.debug.print(
                    "Error: node '{s}' expression uses undeclared port '{s}'\n",
                    .{ node.id, name },
                );
                return error.UndeclaredPort;
            },
            else => {},
        }
    }

    // Every declared input must appear (params may be unused defaults).
    for (node.inputs) |port| {
        const vi = ctx.variables.get(port) orelse {
            std.debug.print(
                "Error: node '{s}' declared input '{s}' is not a variable\n",
                .{ node.id, port },
            );
            return error.MissingDeclaredInput;
        };
        if (!loaded.contains(@intCast(vi))) {
            std.debug.print(
                "Error: node '{s}' declared input '{s}' is not used by the expression\n",
                .{ node.id, port },
            );
            return error.UnusedDeclaredInput;
        }
    }
}

fn varNameForIndex(ctx: *MathZig, idx: u8) ?[]const u8 {
    var vit = ctx.variables.iterator();
    while (vit.next()) |entry| {
        if (entry.value_ptr.* == idx) return entry.key_ptr.*;
    }
    return null;
}

fn printCompileGraphUsage() void {
    std.debug.print(
        \\Usage: mathzig compile-graph -i <graph.json> -o <out.wasm>
        \\         [-v|--verbose] [-s|--standalone]
        \\         [--out-mode table|named_exports] [--export-node-helpers]
        \\
        \\Fuses a GraphDefinition into one wasm module with multi input/output
        \\values (mathzig:graph). Writes out.wasm and out.graph.json sidecar.
        \\
        \\Options:
        \\  -i, --input     Graph JSON path (required)
        \\  -o, --output    Output .wasm path (required)
        \\  -v, --verbose   Print fuse plan summary
        \\  -s, --standalone  Hard-error if any env import would be required
        \\  --out-mode      table (default) or named_exports
        \\  --export-node-helpers  Also export n_<id> per compute node
        \\
        \\v1: expr graphs with multi values (number/boolean/matrix/complex/
        \\record/series/string); no opaque wasm nodes; reject kind any;
        \\params stay number/boolean. Non-scalar const immediates unsupported
        \\(use expr producers). --standalone hard-errors on host-only builtins.
        \\
    , .{});
}

/// `out.wasm` → `out.graph.json` (same directory).
fn graphSidecarPath(allocator: std.mem.Allocator, wasm_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, wasm_path, ".wasm")) {
        const stem = wasm_path[0 .. wasm_path.len - ".wasm".len];
        return std.fmt.allocPrint(allocator, "{s}.graph.json", .{stem});
    }
    return std.fmt.allocPrint(allocator, "{s}.graph.json", .{wasm_path});
}

fn portKindToWire(kind: mathzig.graph.PortKind) mathzig.wasm.abi.WireKind {
    return switch (kind) {
        .number => .number,
        .boolean => .boolean,
        .matrix => .matrix_ptr,
        .complex => .complex_ptr,
        .record => .record_ptr,
        .string => .string_ptr,
        .series => .series_handle,
        .any => .any,
    };
}

/// `mathzig graph run` — VM-native graph evaluator v1 (in-process MathZig VM;
/// never loads .wasm bytes; wasm-only nodes → WasmPhase2Required).
///
/// `mathzig graph run <graph.json> [--set name=number ...] [--param node:name=number ...]`
fn runGraphCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    ctx: *MathZig,
    args: *std.process.Args.Iterator,
) !void {
    const sub = args.next() orelse {
        std.debug.print(
            \\Usage: mathzig graph run <graph.json> [--set name=number ...] [--param node:name=number ...]
            \\
            \\VM-native graph evaluator v1 — loads graph JSON, topo-sorts, evaluates
            \\expr/const/input (and dual-path expr on type:wasm) via in-process MathZig VM.
            \\Does not load or execute .wasm bytes.
            \\
        , .{});
        std.process.exit(1);
    };
    if (!std.mem.eql(u8, sub, "run")) {
        std.debug.print("Error: unknown graph subcommand '{s}' (expected 'run')\n", .{sub});
        std.process.exit(1);
    }

    var graph_path: ?[]const u8 = null;
    var sets: std.ArrayListUnmanaged(struct { []const u8, f64 }) = .empty;
    defer sets.deinit(allocator);
    var params: std.ArrayListUnmanaged(struct { []const u8, []const u8, f64 }) = .empty;
    defer params.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--set")) {
            const spec = args.next() orelse {
                std.debug.print("Error: --set requires name=number\n", .{});
                std.process.exit(1);
            };
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                std.debug.print("Error: --set expects name=number, got '{s}'\n", .{spec});
                std.process.exit(1);
            };
            const name = spec[0..eq];
            const num = std.fmt.parseFloat(f64, spec[eq + 1 ..]) catch {
                std.debug.print("Error: invalid number in --set '{s}'\n", .{spec});
                std.process.exit(1);
            };
            try sets.append(allocator, .{ name, num });
        } else if (std.mem.eql(u8, arg, "--param")) {
            const spec = args.next() orelse {
                std.debug.print("Error: --param requires node:name=number\n", .{});
                std.process.exit(1);
            };
            const colon = std.mem.indexOfScalar(u8, spec, ':') orelse {
                std.debug.print("Error: --param expects node:name=number, got '{s}'\n", .{spec});
                std.process.exit(1);
            };
            const eq = std.mem.indexOfScalar(u8, spec[colon + 1 ..], '=') orelse {
                std.debug.print("Error: --param expects node:name=number, got '{s}'\n", .{spec});
                std.process.exit(1);
            };
            const node_id = spec[0..colon];
            const pname = spec[colon + 1 .. colon + 1 + eq];
            const num = std.fmt.parseFloat(f64, spec[colon + 1 + eq + 1 ..]) catch {
                std.debug.print("Error: invalid number in --param '{s}'\n", .{spec});
                std.process.exit(1);
            };
            try params.append(allocator, .{ node_id, pname, num });
        } else if (graph_path == null) {
            graph_path = arg;
        } else {
            std.debug.print("Error: unexpected argument '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    const path = graph_path orelse {
        std.debug.print(
            \\Usage: mathzig graph run <graph.json> [--set name=number ...] [--param node:name=number ...]
            \\
            \\VM-native graph evaluator v1 — loads graph JSON, topo-sorts, evaluates
            \\expr/const/input (and dual-path expr on type:wasm) via in-process MathZig VM.
            \\Does not load or execute .wasm bytes.
            \\
        , .{});
        std.process.exit(1);
    };

    const json_text = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("Error reading graph file '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(json_text);

    // Reuse the process MathZig context so CLI and graph share one VM.
    var runner = mathzig.graph.GraphRunner.loadWithContext(allocator, json_text, ctx, false) catch |err| {
        if (err == error.Cycle) {
            const msg = mathzig.graph.runner.lastCycleError();
            if (msg.len > 0) {
                std.debug.print("Error: {s}\n", .{msg});
            } else {
                std.debug.print("Error: graph contains a cycle\n", .{});
            }
        } else if (err == error.WasmPhase2Required) {
            std.debug.print("Error: wasm-only nodes need interpreter phase-2 (provide dual-path expr or use expr nodes)\n", .{});
        } else {
            std.debug.print("Error loading graph: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    defer runner.dispose();

    for (params.items) |p| {
        runner.setParam(p[0], p[1], p[2]) catch |err| {
            const detail = runner.lastError();
            if (detail.len > 0) {
                std.debug.print("Error setParam: {s}\n", .{detail});
            } else {
                std.debug.print("Error setParam: {s}\n", .{@errorName(err)});
            }
            std.process.exit(1);
        };
    }

    var outs = runner.runScalars(sets.items) catch |err| {
        const detail = runner.lastError();
        if (detail.len > 0) {
            std.debug.print("Error running graph: {s}\n", .{detail});
        } else {
            std.debug.print("Error running graph: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    defer mathzig.graph.GraphRunner.releaseOutputs(&outs);

    // Print outputs as simple JSON object.
    std.debug.print("{{", .{});
    var first = true;
    var it = outs.iterator();
    while (it.next()) |entry| {
        if (!first) std.debug.print(",", .{});
        first = false;
        std.debug.print("\"{s}\":", .{entry.key_ptr.*});
        printGraphValueJson(ctx, entry.value_ptr.*);
    }
    std.debug.print("}}\n", .{});
}

fn printGraphValueJson(ctx: *MathZig, value: Value) void {
    switch (value.tag) {
        .number => std.debug.print("{d}", .{value.data.number}),
        .boolean => std.debug.print("{s}", .{if (value.data.boolean) "true" else "false"}),
        .complex => std.debug.print("{{\"re\":{d},\"im\":{d}}}", .{ value.data.complex.re, value.data.complex.im }),
        .matrix => {
            const m = value.data.matrix;
            std.debug.print("{{\"rows\":{d},\"cols\":{d},\"data\":[", .{ m.rows, m.cols });
            const n = @as(usize, m.rows) * @as(usize, m.cols);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (i > 0) std.debug.print(",", .{});
                const r: u32 = @intCast(i / m.cols);
                const c: u32 = @intCast(i % m.cols);
                std.debug.print("{d}", .{m.get(r, c)});
            }
            std.debug.print("]}}", .{});
        },
        else => {
            var format_buf: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&format_buf);
            ctx.formatValue(value, &writer) catch {
                std.debug.print("null", .{});
                return;
            };
            // Escape as JSON string
            std.debug.print("\"", .{});
            for (writer.buffered()) |ch| {
                switch (ch) {
                    '"' => std.debug.print("\\\"", .{}),
                    '\\' => std.debug.print("\\\\", .{}),
                    else => std.debug.print("{c}", .{ch}),
                }
            }
            std.debug.print("\"", .{});
        },
    }
}

const PortDecl = struct {
    name: []const u8,
    kind: mathzig.wasm.abi.WireKind,
    default: ?f64 = null,
};

/// Parse `--in name:kind` or `--param name:kind[=default]`.
fn parsePortSpec(spec: []const u8, allow_default: bool) !PortDecl {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.MissingKind;
    if (colon == 0) return error.EmptyName;
    const name = spec[0..colon];
    const rest = spec[colon + 1 ..];
    if (rest.len == 0) return error.MissingKind;

    var kind_part = rest;
    var default: ?f64 = null;
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
        if (!allow_default) return error.UnexpectedDefault;
        kind_part = rest[0..eq];
        const def_str = rest[eq + 1 ..];
        if (def_str.len == 0) return error.MissingDefault;
        default = std.fmt.parseFloat(f64, def_str) catch return error.BadDefault;
    }
    if (kind_part.len == 0) return error.MissingKind;
    const kind = mathzig.wasm.node_manifest.parseKindName(kind_part) orelse return error.UnknownKind;
    return .{ .name = name, .kind = kind, .default = default };
}

/// `out.wasm` → `out.node.json` (same directory).
fn sidecarPath(allocator: std.mem.Allocator, wasm_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, wasm_path, ".wasm")) {
        const stem = wasm_path[0 .. wasm_path.len - ".wasm".len];
        return std.fmt.allocPrint(allocator, "{s}.node.json", .{stem});
    }
    return std.fmt.allocPrint(allocator, "{s}.node.json", .{wasm_path});
}

/// Names installed by `initConstants` that may appear free in node expressions.
fn isBuiltinConstantName(name: []const u8) bool {
    const constants = [_][]const u8{
        "pi", "e", "tau", "phi", "inf", "nan", "true", "false",
        "i", "j",
    };
    for (constants) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

fn wireKindToValueTag(kind: mathzig.wasm.abi.WireKind) mathzig.ValueTag {
    return switch (kind) {
        .number => .number,
        .boolean => .boolean,
        .matrix_ptr => .matrix,
        .complex_ptr => .complex,
        .record_ptr => .record,
        .string_ptr => .string,
        .series_handle => .series,
        .predicate_ptr => .predicate,
        .any => .number,
    };
}
