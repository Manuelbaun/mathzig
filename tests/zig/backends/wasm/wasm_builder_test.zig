const std = @import("std");
const mathzig = @import("mathzig");
const wasm = mathzig.wasm;

test "Generate simple WASM module" {
    const allocator = std.testing.allocator;
    
    var mod = wasm.module.WasmModule.init(allocator);
    defer mod.deinit();
    
    // Type: (f64, f64) -> f64
    const type_idx = try mod.addType(
        &[_]wasm.types.ValType{ .f64, .f64 },
        &[_]wasm.types.ValType{ .f64 }
    );
    
    // Function: add
    const func_idx = try mod.addFunction(type_idx);
    
    // Export: "add"
    try mod.addExport("add", .function, func_idx);
    
    // Code:
    // local.get 0
    // local.get 1
    // f64.add
    // end
    var code = std.ArrayListUnmanaged(u8).empty;
    defer code.deinit(allocator);
    const writer = code.writer(allocator);
    
    try writer.writeByte(@intFromEnum(wasm.types.Op.local_get));
    _ = try wasm.leb.encodeUnsigned(writer, @as(u32, 0));
    
    try writer.writeByte(@intFromEnum(wasm.types.Op.local_get));
    _ = try wasm.leb.encodeUnsigned(writer, @as(u32, 1));
    
    try writer.writeByte(@intFromEnum(wasm.types.Op.f64_add));
    
    // Locals: none (args are locals 0, 1)
    try mod.addCode(code.items, &[_]wasm.types.ValType{});
    
    // Write to memory buffer first
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(allocator);
    try mod.writeTo(buffer.writer(allocator));
    
    // Write to file
    const file = try std.fs.cwd().createFile("tests/artifacts/test_add.wasm", .{});
    defer file.close();
    
    try file.writeAll(buffer.items);
}
