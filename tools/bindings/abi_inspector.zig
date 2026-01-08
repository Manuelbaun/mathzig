const std = @import("std");
const api = @import("api_definition");
const mathzig = @import("mathzig");
const abi = mathzig.wasm.abi;
const BuiltinFn = mathzig.BuiltinFn;

// ABI Inspector
// This tool introspects the `ExportConfig` in `src/api_definition.zig`
// and generates a JSON schema and Zig C-ABI exports.

fn cleanTypeName(allocator: std.mem.Allocator, T: type, for_export: bool) ![]const u8 {
    const info = @typeInfo(T);
    switch (info) {
        .error_union => |eu| {
            return cleanTypeName(allocator, eu.payload, for_export);
        },
        .pointer => |ptr_info| {
            if (for_export) {
                // Strings
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return "?[*:0]const u8";
                }
                // Slices & Many Pointers
                if (ptr_info.size == .slice or ptr_info.size == .many) {
                    const child_name = try cleanTypeName(allocator, ptr_info.child, for_export);
                    const sentinel = if (ptr_info.sentinel_ptr) |s| try std.fmt.allocPrint(allocator, ":{d}", .{@as(*const u8, @ptrCast(s)).*}) else "";
                    if (ptr_info.is_const) return try std.fmt.allocPrint(allocator, "?[*{s}]const {s}", .{ sentinel, child_name });
                    return try std.fmt.allocPrint(allocator, "?[*{s}]{s}", .{ sentinel, child_name });
                }
                // Handles: Map single pointers to opaque handles for C compatibility
                if (ptr_info.size == .one) {
                    return "?*anyopaque";
                }
            }

            const child_name = try cleanTypeName(allocator, ptr_info.child, for_export);
            if (ptr_info.size == .slice) {
                const sentinel = if (ptr_info.sentinel_ptr) |s| try std.fmt.allocPrint(allocator, ":{d}", .{@as(*const u8, @ptrCast(s)).*}) else "";
                if (ptr_info.is_const) return try std.fmt.allocPrint(allocator, "[{s}]const {s}", .{ sentinel, child_name });
                return try std.fmt.allocPrint(allocator, "[{s}]{s}", .{ sentinel, child_name });
            }
            if (ptr_info.size == .one) {
                return try std.fmt.allocPrint(allocator, "*{s}", .{child_name});
            }
            const sentinel = if (ptr_info.sentinel_ptr) |s| try std.fmt.allocPrint(allocator, ":{d}", .{@as(*const u8, @ptrCast(s)).*}) else "";
            return try std.fmt.allocPrint(allocator, "[*{s}]{s}", .{ sentinel, child_name });
        },
        else => {
            const full_name = @typeName(T);
            if (for_export) {
                if (std.mem.eql(u8, full_name, "mem.Allocator")) return "?*anyopaque";
                if (std.mem.indexOf(u8, full_name, "Pool") != null) return "?*anyopaque";
                if (std.mem.eql(u8, full_name, "core.value.Value") or std.mem.eql(u8, full_name, "Value")) {
                    return "?*anyopaque";
                }
                if (std.mem.indexOf(u8, full_name, "Series") != null) return "?*anyopaque";
                if (std.mem.indexOf(u8, full_name, "MathZig") != null) return "?*anyopaque";
                if (std.mem.indexOf(u8, full_name, "CompiledExpr") != null) return "?*anyopaque";
                if (std.mem.indexOf(u8, full_name, "Record") != null) return "?*anyopaque";

                // Handle specific bit-width integers
                if (T == u24) return "u32";
                if (T == i24) return "i32";
            }
            if (std.mem.lastIndexOfScalar(u8, full_name, '.')) |idx| {
                return full_name[idx + 1 ..];
            }
            return try std.fmt.allocPrint(allocator, "{s}", .{full_name});
        },
    }
}

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(5000);
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // skip executable name

    const first = arg_iter.next() orelse {
        std.debug.print("Usage: abi_inspector <output_path> [--exports] | abi_inspector --aot-abi <output_path>\n", .{});
        return error.InvalidArgs;
    };

    if (std.mem.eql(u8, first, "--aot-abi")) {
        const out_path = arg_iter.next() orelse return error.InvalidArgs;
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try mathzig.wasm.abi.writeAotAbiJson(&out.writer);
        try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = out_path, .data = out.written() });
        return;
    }

    const out_path = first;
    const second = arg_iter.next();
    const gen_exports = if (second) |s| std.mem.eql(u8, s, "--exports") else false;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    const config = api.ExportConfig;
    const classes = config.classes;
    const Value = mathzig.Value;
    const Allocator = std.mem.Allocator;

    if (gen_exports) {
        try writer.writeAll("const std = @import(\"std\");\n");
        try writer.writeAll("const builtin = @import(\"builtin\");\n");
        try writer.writeAll("const api_def = @import(\"api_definition\");\n");
        try writer.writeAll("const mathzig = @import(\"mathzig\");\n");
        try writer.writeAll("const Allocator = std.mem.Allocator;\n");
        try writer.writeAll("const Value = mathzig.Value;\n");
        try writer.writeAll("const Matrix = mathzig.Matrix;\n");
        try writer.writeAll("const CompiledExpr = mathzig.CompiledExpr;\n");
        try writer.writeAll("const MathZig = mathzig.MathZig;\n");
        try writer.writeAll("const Series = mathzig.timeseries.Series;\n\n");

        try writer.writeAll("const is_wasm = builtin.cpu.arch.isWasm();\n");
        try writer.writeAll("const is_freestanding = builtin.os.tag == .freestanding;\n\n");

        try writer.writeAll("// State Container to handle ThreadLocal vs Global\n");
        try writer.writeAll("const State = struct {\n");
        try writer.writeAll("    var last_value_global: Value align(16) = Value.initUndefined();\n");
        try writer.writeAll("    threadlocal var last_value_tls: Value align(16) = Value.initUndefined();\n");
        try writer.writeAll("    var last_tag_global: u8 = @intFromEnum(mathzig.ValueTag.undefined);\n");
        try writer.writeAll("    threadlocal var last_tag_tls: u8 = @intFromEnum(mathzig.ValueTag.undefined);\n");
        try writer.writeAll("    var last_ptr_global: ?*anyopaque = null;\n");
        try writer.writeAll("    threadlocal var last_ptr_tls: ?*anyopaque = null;\n");
        try writer.writeAll("    var last_number_global: f64 = 0;\n");
        try writer.writeAll("    threadlocal var last_number_tls: f64 = 0;\n\n");
        try writer.writeAll("    fn getLastValue() *Value { return if (is_wasm or is_freestanding) &last_value_global else &last_value_tls; }\n");
        try writer.writeAll("    fn getLastTag() *u8 { return if (is_wasm or is_freestanding) &last_tag_global else &last_tag_tls; }\n");
        try writer.writeAll("    fn getLastPtr() *?*anyopaque { return if (is_wasm or is_freestanding) &last_ptr_global else &last_ptr_tls; }\n");
        try writer.writeAll("    fn getLastNumber() *f64 { return if (is_wasm or is_freestanding) &last_number_global else &last_number_tls; }\n");
        try writer.writeAll("};\n\n");

        try writer.writeAll("// Allocator handling\n");
        try writer.writeAll("fn getAllocator() Allocator {\n");
        try writer.writeAll("    if (is_wasm or is_freestanding) {\n");
        try writer.writeAll("        return std.heap.page_allocator;\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    return std.heap.c_allocator;\n");
        try writer.writeAll("}\n\n");

        try writer.writeAll("// Core Globals\n");
        try writer.writeAll("export fn mathzig_create() callconv(.c) ?*anyopaque {\n");
        try writer.writeAll("    return MathZig.init(getAllocator()) catch null;\n");
        try writer.writeAll("}\n\n");
        try writer.writeAll("export fn mathzig_destroy(ctx: ?*anyopaque) callconv(.c) void {\n");
        try writer.writeAll("    if (ctx) |c| {\n");
        try writer.writeAll("        const ptr: *MathZig = @ptrCast(@alignCast(c));\n");
        try writer.writeAll("        ptr.deinit();\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("}\n\n");
        try writer.writeAll("export fn mathzig_get_last_number() callconv(.c) f64 { return State.getLastNumber().*; }\n");
        try writer.writeAll("export fn mathzig_get_last_tag() callconv(.c) u8 { return State.getLastTag().*; }\n");
        try writer.writeAll("export fn mathzig_get_last_ptr() callconv(.c) ?*anyopaque { return State.getLastPtr().*; }\n");
        try writer.writeAll("export fn mathzig_format_last_value(ctx: ?*anyopaque, buffer: [*]u8, len: usize) callconv(.c) usize {\n");
        try writer.writeAll("    const c = ctx orelse return 0;\n");
        try writer.writeAll("    if (len == 0) return 0;\n");
        try writer.writeAll("    var out = std.Io.Writer.fixed(buffer[0..len]);\n");
        try writer.writeAll("    @as(*MathZig, @ptrCast(@alignCast(c))).formatValue(State.getLastValue().*, &out) catch |err| {\n");
        try writer.writeAll("        if (err == error.WriteFailed) {\n");
        try writer.writeAll("            return out.end;\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("        return 0;\n");
        try writer.writeAll("    };\n");
        try writer.writeAll("    if (out.end < len) {\n");
        try writer.writeAll("        buffer[out.end] = 0;\n");
        try writer.writeAll("    } else if (len > 0) {\n");
        try writer.writeAll("        buffer[len - 1] = 0;\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    return out.end;\n");
        try writer.writeAll("}\n");
        try writer.writeAll("export fn mathzig_version_number() callconv(.c) f64 { return 0.1; }\n\n");

        try writer.writeAll("// WASM Memory Helpers\n");
        try writer.writeAll("export fn wasm_malloc(size: usize) callconv(.c) ?*anyopaque {\n");
        try writer.writeAll("    const total_size = size + @sizeOf(usize);\n");
        try writer.writeAll("    const ptr = getAllocator().alloc(u8, total_size) catch return null;\n");
        try writer.writeAll("    @as(*usize, @ptrCast(@alignCast(ptr.ptr))).* = total_size;\n");
        try writer.writeAll("    return @ptrCast(ptr.ptr + @sizeOf(usize));\n");
        try writer.writeAll("}\n\n");
        try writer.writeAll("export fn wasm_free(ptr: ?*anyopaque) callconv(.c) void {\n");
        try writer.writeAll("    if (ptr) |p| {\n");
        try writer.writeAll("        const header_ptr = @as([*]u8, @ptrCast(p)) - @sizeOf(usize);\n");
        try writer.writeAll("        const total_size = @as(*usize, @ptrCast(@alignCast(header_ptr))).*;\n");
        try writer.writeAll("        getAllocator().free(header_ptr[0..total_size]);\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("}\n\n");
    } else {
        try writer.writeAll("{\n  \"classes\": {\n");
    }

    var first_class = true;
    inline for (@typeInfo(@TypeOf(classes)).@"struct".fields) |field| {
        if (!gen_exports) {
            if (!first_class) try writer.writeAll(",\n");
            first_class = false;
        }

        const class_name = field.name;
        const class_def = @field(classes, class_name);

        if (gen_exports) {
            try writer.print("// {s}\n", .{class_name});
        } else {
            try writer.print("    \"{s}\": ", .{class_name});
            try writer.writeAll("{\n");
            try writer.writeAll("      \"description\": ");
            try std.json.Stringify.value(class_def.description, .{}, writer);
            try writer.writeAll(",\n");
            try writer.writeAll("      \"methods\": [\n");
        }

        const methods = class_def.methods;
        var first_method = true;
        inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |m_field| {
            const method_name = m_field.name;
            const method_def = @field(methods, method_name);
            const fn_ptr = method_def.fn_ptr;
            const type_info = @typeInfo(@TypeOf(fn_ptr)).@"fn";

            if (gen_exports) {
                const is_manual = comptime (if (@hasField(@TypeOf(method_def), "export_name"))
                    (std.mem.eql(u8, method_def.export_name, "mathzig_get_last_number") or
                        std.mem.eql(u8, method_def.export_name, "mathzig_get_last_tag") or
                        std.mem.eql(u8, method_def.export_name, "mathzig_get_last_ptr") or
                        std.mem.eql(u8, method_def.export_name, "mathzig_format_last_value") or
                        std.mem.eql(u8, method_def.export_name, "mathzig_version_number"))
                else
                    false);

                if (!is_manual and @hasField(@TypeOf(method_def), "export_name") and method_def.export_name.len > 0) {
                    const ret_type_name = try cleanTypeName(allocator, type_info.return_type.?, true);

                    try writer.print("export fn {s}(", .{method_def.export_name});
                    const mapping_info_params = @typeInfo(@TypeOf(method_def.args)).@"struct";
                    inline for (mapping_info_params.fields, 0..) |arg_field, i| {
                        if (i > 0) try writer.writeAll(", ");
                        const arg_name = arg_field.name;
                        const arg_val = @field(method_def.args, arg_name);

                        var arg_type_name: []const u8 = undefined;
                        if (i < type_info.params.len) {
                            arg_type_name = try cleanTypeName(allocator, type_info.params[i].type.?, true);
                        } else {
                            // Extra parameter from ExportConfig (like 'len')
                            const val_str = if (@typeInfo(@TypeOf(arg_val)) == .pointer)
                                @as([]const u8, arg_val)
                            else if (@typeInfo(@TypeOf(arg_val)) == .@"struct" and @hasField(@TypeOf(arg_val), "binding"))
                                arg_val.binding
                            else
                                "u32";
                            if (std.mem.eql(u8, val_str, "string")) {
                                arg_type_name = "[*:0]const u8";
                            } else if (std.mem.eql(u8, val_str, "this") or std.mem.eql(u8, val_str, "context") or std.mem.eql(u8, val_str, "other")) {
                                arg_type_name = "?*anyopaque";
                            } else if (std.mem.indexOf(u8, val_str, ".") != null) {
                                if (std.mem.endsWith(u8, val_str, ".len") or std.mem.endsWith(u8, val_str, ".rows") or std.mem.endsWith(u8, val_str, ".cols") or std.mem.endsWith(u8, val_str, ".stride")) {
                                    arg_type_name = "u32";
                                } else if (std.mem.endsWith(u8, val_str, ".data")) {
                                    arg_type_name = "[*]f64";
                                } else {
                                    arg_type_name = "?*anyopaque";
                                }
                            } else {
                                arg_type_name = val_str;
                            }
                        }
                        try writer.print("{s}: {s}", .{ arg_name, arg_type_name });
                    }
                    try writer.writeAll(") callconv(.c) ");
                    try writer.writeAll(ret_type_name);
                    try writer.writeAll(" {\n");

                    // Silence unused
                    inline for (type_info.params, 0..) |param, i| {
                        const mapping_info_unused = @typeInfo(@TypeOf(method_def.args)).@"struct";
                        if (i >= mapping_info_unused.fields.len) continue;
                        const arg_name = mapping_info_unused.fields[i].name;
                        const arg_val = @field(method_def.args, arg_name);
                        const is_struct_arg_unused = @typeInfo(@TypeOf(arg_val)) == .@"struct";
                        const binding_unused = if (is_struct_arg_unused and @hasField(@TypeOf(arg_val), "binding")) arg_val.binding else if (@TypeOf(arg_val) == []const u8) arg_val else "";
                        if (std.mem.eql(u8, binding_unused, "context.allocator") or param.type.? == Allocator or std.mem.eql(u8, arg_name, "allocator")) {
                            try writer.print("    _ = {s};\n", .{arg_name});
                        }
                    }

                    const ret_type = type_info.return_type.?;
                    const is_error_union = @typeInfo(ret_type) == .error_union;
                    const success_type = if (is_error_union) @typeInfo(ret_type).error_union.payload else ret_type;
                    const is_value_ret = success_type == Value;
                    const is_void_ret = success_type == void;

                    // Null checks for pointers
                    inline for (type_info.params, 0..) |param, i| {
                        const p_info = @typeInfo(param.type.?);
                        if (p_info == .pointer) {
                            const arg_name = mapping_info_params.fields[i].name;
                            if (is_void_ret) {
                                try writer.print("    if ({s} == null) return;\n", .{arg_name});
                            } else if (success_type == bool) {
                                try writer.print("    if ({s} == null) return false;\n", .{arg_name});
                            } else if (success_type == f64) {
                                try writer.print("    if ({s} == null) return std.math.nan(f64);\n", .{arg_name});
                            } else if (is_value_ret) {
                                try writer.print("    if ({s} == null) return @ptrCast(Value.initError(1).getPointer());\n", .{arg_name});
                            } else if (@typeInfo(success_type) == .int) {
                                try writer.print("    if ({s} == null) return 0;\n", .{arg_name});
                            } else {
                                try writer.print("    if ({s} == null) return null;\n", .{arg_name});
                            }
                        }
                    }

                    if (is_value_ret) {
                        try writer.writeAll("    const result_raw = ");
                    } else if (!is_void_ret) {
                        try writer.writeAll("    const result_raw = ");
                    } else {
                        try writer.writeAll("    _ = ");
                    }

                    try writer.print("@field(@field(api_def.ExportConfig.classes, \"{s}\").methods, \"{s}\").fn_ptr(", .{
                        class_name,
                        method_name,
                    });

                    inline for (type_info.params, 0..) |param, i| {
                        if (i > 0) try writer.writeAll(", ");
                        const mapping_info_call = @typeInfo(@TypeOf(method_def.args)).@"struct";
                        const arg_name = if (i < mapping_info_call.fields.len) mapping_info_call.fields[i].name else try std.fmt.allocPrint(allocator, "arg{d}", .{i});
                        const arg_val = if (i < mapping_info_call.fields.len) @field(method_def.args, arg_name) else "unknown";

                        const p_info = @typeInfo(param.type.?);
                        const is_pool = std.mem.indexOf(u8, @typeName(param.type.?), "Pool") != null;

                        if (param.type.? == void) {
                            try writer.writeAll("{}");
                        } else if (is_pool) {
                            try writer.print("if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, \"{s}\").methods, \"{s}\").fn_ptr)).@\"fn\".params[0].type.? == void) {{}} else @ptrCast(@alignCast({s}.?))", .{ class_name, method_name, arg_name });
                        } else if (p_info == .pointer) {
                            if (p_info.pointer.size == .slice and p_info.pointer.child == u8) {
                                try writer.print("std.mem.span({s}.?)", .{arg_name});
                            } else if (p_info.pointer.size == .slice) {
                                var len_val: []const u8 = "0";
                                const T_arg = @TypeOf(arg_val);
                                if (comptime @typeInfo(T_arg) == .@"struct" and @hasField(T_arg, "len")) {
                                    len_val = arg_val.len;
                                    if (std.mem.indexOf(u8, len_val, ".")) |dot_idx| {
                                        len_val = len_val[dot_idx + 1 ..];
                                    }
                                } else if (T_arg == []const u8 or (comptime @typeInfo(T_arg) == .pointer and @typeInfo(T_arg).pointer.size == .one and @typeInfo(@typeInfo(T_arg).pointer.child) == .array)) {
                                    const val_str: []const u8 = arg_val;
                                    if (std.mem.indexOf(u8, val_str, ".")) |dot_idx| {
                                        len_val = val_str[dot_idx + 1 ..];
                                    } else {
                                        len_val = val_str;
                                    }
                                }
                                try writer.print("@alignCast({s}.?[0..{s}])", .{ arg_name, len_val });
                            } else if (p_info.pointer.size == .one) {
                                // Special case for multiplyParallel first arg which is void in WASM but pointer elsewhere
                                try writer.print("if (comptime @typeInfo(@TypeOf(@field(@field(api_def.ExportConfig.classes, \"{s}\").methods, \"{s}\").fn_ptr)).@\"fn\".params[0].type.? == void) {{}} else @ptrCast(@alignCast({s}.?))", .{ class_name, method_name, arg_name });
                            } else {
                                try writer.print("@alignCast({s}.?)", .{arg_name});
                            }
                        } else if (param.type.? == Allocator) {
                            try writer.writeAll("getAllocator()");
                        } else {
                            if (@typeInfo(param.type.?) == .int) {
                                try writer.print("@intCast({s})", .{arg_name});
                            } else {
                                try writer.writeAll(arg_name);
                            }
                        }
                    }
                    try writer.writeAll(")");

                    if (is_error_union) {
                        if (is_value_ret) {
                            try writer.writeAll(" catch Value.initError(0)");
                        } else if (success_type == bool) {
                            try writer.writeAll(" catch false");
                        } else if (success_type == f64) {
                            try writer.writeAll(" catch std.math.nan(f64)");
                        } else if (is_void_ret) {
                            try writer.writeAll(" catch {}\n");
                        } else {
                            try writer.writeAll(" catch null");
                        }
                    }
                    try writer.writeAll(";\n");

                    if (is_value_ret) {
                        try writer.writeAll("    State.getLastValue().release();\n");
                        try writer.writeAll("    State.getLastValue().* = result_raw;\n");
                        try writer.writeAll("    State.getLastTag().* = @intFromEnum(State.getLastValue().tag);\n");
                        try writer.writeAll("    State.getLastPtr().* = State.getLastValue().getPointer();\n");
                        try writer.writeAll("    State.getLastNumber().* = State.getLastValue().toNumber() orelse 0.0;\n");
                        try writer.writeAll("    return @ptrCast(State.getLastPtr().*);\n");
                    } else if (!is_void_ret) {
                        const is_ptr = std.mem.startsWith(u8, ret_type_name, "?*") or std.mem.startsWith(u8, ret_type_name, "[*]");
                        if (is_ptr) {
                            try writer.print("    return @ptrCast(@constCast(result_raw));\n", .{});
                        } else {
                            try writer.writeAll("    return result_raw;\n");
                        }
                    }
                    try writer.writeAll("}\n\n");
                }
            } else {
                if (!first_method) try writer.writeAll(",\n");
                first_method = false;

                try writer.writeAll("        {\n");
                try writer.print("          \"name\": \"{s}\",\n", .{method_name});
                try writer.writeAll("          \"export_name\": ");
                try std.json.Stringify.value(if (@hasField(@TypeOf(method_def), "export_name")) method_def.export_name else "", .{}, writer);
                try writer.writeAll(",\n");
                try writer.writeAll("          \"description\": ");
                try std.json.Stringify.value(if (@hasField(@TypeOf(method_def), "description")) method_def.description else "", .{}, writer);
                try writer.writeAll(",\n");
                try writer.writeAll("          \"args\": [\n");
                var first_arg = true;
                const mapping_info_json = @typeInfo(@TypeOf(method_def.args)).@"struct";
                inline for (mapping_info_json.fields, 0..) |arg_field, i| {
                    if (!first_arg) try writer.writeAll(",\n");
                    first_arg = false;
                    const arg_name = arg_field.name;
                    const arg_val = @field(method_def.args, arg_name);

                    var arg_type_name: []const u8 = undefined;
                    if (i < type_info.params.len) {
                        arg_type_name = try cleanTypeName(allocator, type_info.params[i].type.?, false);
                    } else {
                        // Extra param
                        if (@TypeOf(arg_val) == []const u8) {
                            arg_type_name = arg_val;
                        } else if (@typeInfo(@TypeOf(arg_val)) == .@"struct" and @hasField(@TypeOf(arg_val), "binding")) {
                            arg_type_name = arg_val.binding;
                        } else {
                            arg_type_name = "u32";
                        }
                    }

                    const is_struct_arg_json = @typeInfo(@TypeOf(arg_val)) == .@"struct";
                    const binding_val = if (is_struct_arg_json and @hasField(@TypeOf(arg_val), "binding")) arg_val.binding else arg_val;

                    try writer.writeAll("            { \"name\": ");
                    try std.json.Stringify.value(arg_name, .{}, writer);
                    try writer.writeAll(", \"type\": ");
                    try std.json.Stringify.value(arg_type_name, .{}, writer);
                    try writer.writeAll(", \"ffi_type\": ");
                    if (i < type_info.params.len) {
                        const ffi_type = try cleanTypeName(allocator, type_info.params[i].type.?, true);
                        try std.json.Stringify.value(ffi_type, .{}, writer);
                    } else {
                        try std.json.Stringify.value(arg_type_name, .{}, writer);
                    }
                    try writer.writeAll(", \"binding\": ");
                    try std.json.Stringify.value(binding_val, .{}, writer);
                    try writer.writeAll(" }");
                }
                try writer.writeAll("\n          ],\n");
                const ret_type_name = try cleanTypeName(allocator, type_info.return_type.?, false);
                try writer.writeAll("          \"return_type\": ");
                try std.json.Stringify.value(ret_type_name, .{}, writer);
                try writer.writeAll(", \"ffi_return_type\": ");
                const ffi_ret_type = try cleanTypeName(allocator, type_info.return_type.?, true);
                try std.json.Stringify.value(ffi_ret_type, .{}, writer);
                try writer.writeAll("\n        }");
            }
        }
        if (!gen_exports) {
            try writer.writeAll("\n      ]\n");
            try writer.writeAll("    }");
        }
    }

    if (!gen_exports) {
        try writer.writeAll("\n  }\n}\n");
    }

    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = out_path, .data = out.written() });
}
