const std = @import("std");
const VM = @import("../../src/vm/vm.zig").VM;
const Compiler = @import("../../src/parser/compiler.zig").Compiler;
const UnitRegistry = @import("../../src/units/unit_registry.zig").UnitRegistry;

test "DSL function with global closure collision" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    // 1. Define global 'a' = 10
    // 2. Define function f(x) = x + a
    // 3. Call f(5) -> expected 15
    const source = "a = 10\nf(x) = x + a\nf(5)";

    var compiler = try Compiler.init(allocator, source);
    compiler.registry = &registry;
    defer compiler.deinit();

    // We need to compile and execute sequentially to simulate REPL or script
    // Actually, the compiler compiles the whole string.
    // It emits bytecode for the whole sequence.
    
    var expr = try compiler.compile();
    defer expr.deinit();

    var vm = try VM.init(allocator, allocator, 64, null);
    defer vm.deinit();

    const result = try vm.execute(&expr);
    
    // We expect 15. If collision occurs (x overwrites a), it might be 5 + 5 = 10
    try std.testing.expectEqual(@as(f64, 15.0), result.toNumber().?);
}

test "DSL function simple" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    const source = "f(x) = x * 2\nf(10)";

    var compiler = try Compiler.init(allocator, source);
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    var vm = try VM.init(allocator, allocator, 64, null);
    defer vm.deinit();

    const result = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, 20.0), result.toNumber().?);
}
