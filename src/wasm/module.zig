const std = @import("std");
const list_writer = @import("list_writer.zig");
const types = @import("types.zig");
const leb = @import("leb128.zig");

pub const WasmModule = struct {
    allocator: std.mem.Allocator,
    
    // Section buffers (holding payload only)
    type_data: std.ArrayListUnmanaged(u8),
    import_data: std.ArrayListUnmanaged(u8),
    func_data: std.ArrayListUnmanaged(u8),
    memory_data: std.ArrayListUnmanaged(u8),
    global_data: std.ArrayListUnmanaged(u8),
    export_data: std.ArrayListUnmanaged(u8),
    code_data: std.ArrayListUnmanaged(u8),
    data_data: std.ArrayListUnmanaged(u8),
    /// Fully-encoded custom sections (section id + size + payload each),
    /// emitted verbatim after all standard sections.
    custom_data: std.ArrayListUnmanaged(u8),
    
    // Counts for vector headers
    type_count: usize = 0,
    import_count: usize = 0,
    func_count: usize = 0,
    memory_count: usize = 0,
    global_count: usize = 0,
    export_count: usize = 0,
    code_count: usize = 0,
    data_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) WasmModule {
        return WasmModule{
            .allocator = allocator,
            .type_data = .empty,
            .import_data = .empty,
            .func_data = .empty,
            .memory_data = .empty,
            .global_data = .empty,
            .export_data = .empty,
            .code_data = .empty,
            .data_data = .empty,
            .custom_data = .empty,
        };
    }

    pub fn deinit(self: *WasmModule) void {
        self.type_data.deinit(self.allocator);
        self.import_data.deinit(self.allocator);
        self.func_data.deinit(self.allocator);
        self.memory_data.deinit(self.allocator);
        self.global_data.deinit(self.allocator);
        self.export_data.deinit(self.allocator);
        self.code_data.deinit(self.allocator);
        self.data_data.deinit(self.allocator);
        self.custom_data.deinit(self.allocator);
    }
    
    /// Adds a function type signature to the Type section.
    /// Returns the type index.
    pub fn addType(self: *WasmModule, params: []const types.ValType, results: []const types.ValType) !u32 {
        const writer = list_writer.unmanagedByteWriter(&self.type_data, self.allocator);
        try writer.writeByte(0x60); // func type
        
        _ = try leb.encodeUnsigned(writer, params.len);
        for (params) |p| {
            try writer.writeByte(@intFromEnum(p));
        }
        
        _ = try leb.encodeUnsigned(writer, results.len);
        for (results) |r| {
            try writer.writeByte(@intFromEnum(r));
        }
        
        const index = @as(u32, @intCast(self.type_count));
        self.type_count += 1;
        return index;
    }
    
    /// Adds an import.
    /// Returns the function index (assuming it's a function import).
    /// Note: Function imports occupy the first N indices in the function index space.
    pub fn addImport(self: *WasmModule, module_name: []const u8, field_name: []const u8, kind: types.ExternalKind, type_index: u32) !u32 {
        // Imported functions occupy the FIRST indices of the function index
        // space, and callers embed returned indices into code/exports
        // immediately. An import added after any defined function would
        // silently shift every already-recorded index (miscompilation).
        std.debug.assert(self.func_count == 0);
        const writer = list_writer.unmanagedByteWriter(&self.import_data, self.allocator);
        
        _ = try leb.encodeUnsigned(writer, module_name.len);
        try writer.writeAll(module_name);
        
        _ = try leb.encodeUnsigned(writer, field_name.len);
        try writer.writeAll(field_name);
        
        try writer.writeByte(@intFromEnum(kind));
        
        // For function imports, we write the type index
        if (kind == .function) {
            _ = try leb.encodeUnsigned(writer, type_index);
        } else {
            // TODO: Handle other import types (Global, Memory, Table)
            return error.UnimplementedImportType;
        }
        
        const index = @as(u32, @intCast(self.import_count));
        self.import_count += 1;
        return index;
    }

    /// Adds a function definition.
    /// Returns the function index.
    /// Note: Implementation requires adding code body separately via addCode.
    pub fn addFunction(self: *WasmModule, type_index: u32) !u32 {
        const writer = list_writer.unmanagedByteWriter(&self.func_data, self.allocator);
        _ = try leb.encodeUnsigned(writer, type_index);
        
        // Function index = import_count + func_count
        const index = @as(u32, @intCast(self.import_count + self.func_count));
        self.func_count += 1;
        return index;
    }

    /// Adds memory to the module.
    pub fn addMemory(self: *WasmModule, initial_pages: u32, maximum_pages: ?u32) !u32 {
        const writer = list_writer.unmanagedByteWriter(&self.memory_data, self.allocator);
        if (maximum_pages) |max| {
            try writer.writeByte(0x01); // limits: flags=1 (min and max)
            _ = try leb.encodeUnsigned(writer, initial_pages);
            _ = try leb.encodeUnsigned(writer, max);
        } else {
            try writer.writeByte(0x00); // limits: flags=0 (min only)
            _ = try leb.encodeUnsigned(writer, initial_pages);
        }
        
        const index = @as(u32, @intCast(self.memory_count));
        self.memory_count += 1;
        return index;
    }

    /// Adds a global variable.
    pub fn addGlobal(self: *WasmModule, val_type: types.ValType, mutable: bool, init_op: types.Op, init_val: anytype) !u32 {
        const writer = list_writer.unmanagedByteWriter(&self.global_data, self.allocator);
        try writer.writeByte(@intFromEnum(val_type));
        try writer.writeByte(if (mutable) 0x01 else 0x00);
        
        try writer.writeByte(@intFromEnum(init_op));
        switch (init_op) {
            .i32_const => _ = try leb.encodeSigned(writer, @as(i32, @intCast(init_val))),
            .i64_const => _ = try leb.encodeSigned(writer, @as(i64, @intCast(init_val))),
            .f32_const => {
                const f: f32 = switch (@typeInfo(@TypeOf(init_val))) {
                    .int, .comptime_int => @floatFromInt(init_val),
                    .float, .comptime_float => @floatCast(init_val),
                    else => return error.InvalidGlobalInitType,
                };
                try writer.writeAll(std.mem.asBytes(&f));
            },
            .f64_const => {
                const f: f64 = switch (@typeInfo(@TypeOf(init_val))) {
                    .int, .comptime_int => @floatFromInt(init_val),
                    .float, .comptime_float => @floatCast(init_val),
                    else => return error.InvalidGlobalInitType,
                };
                try writer.writeAll(std.mem.asBytes(&f));
            },
            else => return error.UnsupportedGlobalInitOp,
        }
        try writer.writeByte(@intFromEnum(types.Op.end));
        
        const index = @as(u32, @intCast(self.global_count));
        self.global_count += 1;
        return index;
    }
    
    /// Adds an export.
    pub fn addExport(self: *WasmModule, name: []const u8, kind: types.ExternalKind, index: u32) !void {
        const writer = list_writer.unmanagedByteWriter(&self.export_data, self.allocator);
        _ = try leb.encodeUnsigned(writer, name.len);
        try writer.writeAll(name);
        try writer.writeByte(@intFromEnum(kind));
        _ = try leb.encodeUnsigned(writer, index);
        
        self.export_count += 1;
    }
    
    /// Adds a code body (function implementation).
    /// `locals` maps types to counts (e.g. { .i32 = 1, .f64 = 2 }).
    /// `body` contains the raw bytecode instructions.
    pub fn addCode(self: *WasmModule, body: []const u8, locals: []const types.ValType) !void {
        const writer = list_writer.unmanagedByteWriter(&self.code_data, self.allocator);
        
        // We need to calculate the size of the function body (locals + code + end) first
        var func_buf = std.ArrayListUnmanaged(u8).empty; // keep managed for temp buffer convenience
        defer func_buf.deinit(self.allocator);
        const func_writer = list_writer.unmanagedByteWriter(&func_buf, self.allocator);
        
        const LocalEntry = struct { count: u32, type: types.ValType };
        var compressed_locals = std.ArrayListUnmanaged(LocalEntry).empty;
        defer compressed_locals.deinit(self.allocator);
        
        for (locals) |l| {
            if (compressed_locals.items.len > 0) {
                var last = &compressed_locals.items[compressed_locals.items.len - 1];
                if (last.type == l) {
                    last.count += 1;
                    continue;
                }
            }
            try compressed_locals.append(self.allocator, .{ .count = 1, .type = l });
        }
        
        _ = try leb.encodeUnsigned(func_writer, compressed_locals.items.len);
        for (compressed_locals.items) |entry| {
            _ = try leb.encodeUnsigned(func_writer, entry.count);
            try func_writer.writeByte(@intFromEnum(entry.type));
        }
        
        try func_writer.writeAll(body);
        try func_writer.writeByte(@intFromEnum(types.Op.end));
        
        // Now write the total size + the body to the code section
        _ = try leb.encodeUnsigned(writer, func_buf.items.len);
        try writer.writeAll(func_buf.items);
        
        self.code_count += 1;
    }
    
    /// Adds a data segment to the module.
    /// `memory_index` is usually 0.
    pub fn addData(self: *WasmModule, offset: i32, bytes: []const u8) !u32 {
        const writer = list_writer.unmanagedByteWriter(&self.data_data, self.allocator);
        try writer.writeByte(0x00); // active data segment
        
        // Init expression: i32.const <offset> end
        try writer.writeByte(@intFromEnum(types.Op.i32_const));
        _ = try leb.encodeSigned(writer, offset);
        try writer.writeByte(@intFromEnum(types.Op.end));
        
        _ = try leb.encodeUnsigned(writer, bytes.len);
        try writer.writeAll(bytes);
        
        const index = @as(u32, @intCast(self.data_count));
        self.data_count += 1;
        return index;
    }
    
    /// Appends a custom section (id 0): payload = name vector + content bytes.
    /// Custom sections may appear anywhere; we emit them after all standard
    /// sections in writeTo.
    pub fn addCustomSection(self: *WasmModule, name: []const u8, content: []const u8) !void {
        var payload = std.ArrayListUnmanaged(u8).empty;
        defer payload.deinit(self.allocator);
        const pw = list_writer.unmanagedByteWriter(&payload, self.allocator);
        _ = try leb.encodeUnsigned(pw, name.len);
        try pw.writeAll(name);
        try pw.writeAll(content);

        const writer = list_writer.unmanagedByteWriter(&self.custom_data, self.allocator);
        try writer.writeByte(@intFromEnum(types.SectionId.custom));
        _ = try leb.encodeUnsigned(writer, payload.items.len);
        try writer.writeAll(payload.items);
    }

    /// Writes the complete WASM binary to the given writer.
    pub fn writeTo(self: *WasmModule, writer: anytype) !void {
        // Magic
        try writer.writeAll(&[_]u8{ 0x00, 0x61, 0x73, 0x6D });
        // Version
        try writer.writeAll(&[_]u8{ 0x01, 0x00, 0x00, 0x00 });
        
        // Write Sections in Order
        if (self.type_count > 0) {
            try self.writeSection(writer, types.SectionId.type, self.type_data.items, self.type_count);
        }
        if (self.import_count > 0) {
            try self.writeSection(writer, types.SectionId.import, self.import_data.items, self.import_count);
        }
        if (self.func_count > 0) {
            try self.writeSection(writer, types.SectionId.function, self.func_data.items, self.func_count);
        }
        // Table section (4) - skipped
        if (self.memory_count > 0) {
            try self.writeSection(writer, types.SectionId.memory, self.memory_data.items, self.memory_count);
        }
        if (self.global_count > 0) {
            try self.writeSection(writer, types.SectionId.global, self.global_data.items, self.global_count);
        }
        if (self.export_count > 0) {
            try self.writeSection(writer, types.SectionId.@"export", self.export_data.items, self.export_count);
        }
        if (self.code_count > 0) {
            try self.writeSection(writer, types.SectionId.code, self.code_data.items, self.code_count);
        }
        if (self.data_count > 0) {
            try self.writeSection(writer, types.SectionId.data, self.data_data.items, self.data_count);
        }
        if (self.custom_data.items.len > 0) {
            try writer.writeAll(self.custom_data.items);
        }
    }
    
    fn writeSection(self: *WasmModule, writer: anytype, id: types.SectionId, data: []const u8, count: usize) !void {
        _ = self;
        try writer.writeByte(@intFromEnum(id));
        
        // Section size = LEB128(count) size + payload size
        // But the "count" is part of the payload in the vector encoding.
        // Vector = LEB128(count) + elements.
        // So we need to compute size of LEB128(count) + data.len.
        
        var count_buf: [10]u8 = undefined;
        const count_len = try leb.encodeUnsignedFixed(&count_buf, count);
        
        const total_size = count_len + data.len;
        _ = try leb.encodeUnsigned(writer, total_size);
        
        try writer.writeAll(count_buf[0..count_len]);
        try writer.writeAll(data);
    }
};

/// Result of scanning wasm bytes for a named custom section (task-14 / C3).
/// Distinguishes **absent** section from **malformed** module bytes so callers
/// never conflate the two as a single null.
pub const CustomSectionScan = union(enum) {
    /// Valid wasm module magic/version and section walk completed; named section not present.
    absent,
    /// Bytes are not a well-formed wasm module (bad magic, truncated section, bad LEB, …).
    malformed_wasm,
    /// Named custom section payload (slice into the input buffer, after the name field).
    present: []const u8,
};

/// Scan wasm bytes for a named custom section (section id 0).
/// Shared by `mathzig:node` and `mathzig:graph` scanners.
/// Prefer this over the legacy null-collapsing helper when malformed-vs-absent matters.
pub fn scanCustomSectionResult(wasm_bytes: []const u8, section_name: []const u8) CustomSectionScan {
    if (wasm_bytes.len < 8) return .malformed_wasm;
    if (!std.mem.eql(u8, wasm_bytes[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6d })) return .malformed_wasm;
    var i: usize = 8;
    while (i < wasm_bytes.len) {
        const sec_id = wasm_bytes[i];
        i += 1;
        const size_res = readLeb128Usize(wasm_bytes, i) orelse return .malformed_wasm;
        i = size_res.next;
        const payload_len = size_res.value;
        if (i + payload_len > wasm_bytes.len) return .malformed_wasm;
        const payload = wasm_bytes[i .. i + payload_len];
        i += payload_len;
        if (sec_id != 0) continue; // custom section only
        const name_res = readLeb128Usize(payload, 0) orelse return .malformed_wasm;
        const name_len = name_res.value;
        if (name_res.next + name_len > payload.len) return .malformed_wasm;
        const name = payload[name_res.next .. name_res.next + name_len];
        if (!std.mem.eql(u8, name, section_name)) continue;
        return .{ .present = payload[name_res.next + name_len ..] };
    }
    return .absent;
}

/// Legacy helper: returns payload or null for both absent and malformed.
/// Prefer `scanCustomSectionResult` for new call sites (task-14 C3).
pub fn scanCustomSection(wasm_bytes: []const u8, section_name: []const u8) ?[]const u8 {
    return switch (scanCustomSectionResult(wasm_bytes, section_name)) {
        .present => |p| p,
        .absent, .malformed_wasm => null,
    };
}

const LebUsize = struct { value: usize, next: usize };

fn readLeb128Usize(buf: []const u8, start: usize) ?LebUsize {
    var result: usize = 0;
    var shift: u6 = 0;
    var i = start;
    while (i < buf.len) {
        const b = buf[i];
        i += 1;
        result |= @as(usize, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return .{ .value = result, .next = i };
        shift += 7;
        if (shift > 35) return null;
    }
    return null;
}