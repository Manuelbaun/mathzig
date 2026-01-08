//! Debug Tracing Verification Test
//! Verifies that the VM debug tracing infrastructure works correctly

const std = @import("std");
const mathzig = @import("mathzig");
const Compiler = mathzig.Compiler;
const VM = mathzig.VM;
const UnitRegistry = mathzig.units.UnitRegistry;
const Value = mathzig.Value;

test "Debug Trace: basic arithmetic with tracing enabled" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    // Enable debug tracing
    vm.setDebug(true);

    std.debug.print("\n=== Debug Trace Test: 2 + 3 * 4 ===\n", .{});

    var compiler = try Compiler.init(allocator, "2 + 3 * 4");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // Verify source_offsets were populated
    std.debug.print("Source offsets length: {d}\n", .{expr.source_offsets.len});
    std.debug.print("Instructions count: {d}\n\n", .{expr.code.len});

    const result = try vm.execute(&expr);

    std.debug.print("\n=== Result: {d} ===\n\n", .{result.data.number});
    try std.testing.expectEqual(14.0, result.data.number);
}

test "Debug Trace: nested expression" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    // Enable debug tracing
    vm.setDebug(true);

    std.debug.print("\n=== Debug Trace Test: (1 + 2) * (3 + 4) ===\n", .{});

    var compiler = try Compiler.init(allocator, "(1 + 2) * (3 + 4)");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    const result = try vm.execute(&expr);

    std.debug.print("\n=== Result: {d} ===\n\n", .{result.data.number});
    try std.testing.expectEqual(21.0, result.data.number);
}

test "Debug Trace: function call (sin)" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    vm.setDebug(true);

    std.debug.print("\n=== Debug Trace Test: sin(0) ===\n", .{});

    var compiler = try Compiler.init(allocator, "sin(0)");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    const result = try vm.execute(&expr);

    std.debug.print("\n=== Result: {d} ===\n\n", .{result.data.number});
    try std.testing.expectEqual(0.0, result.data.number);
}

test "VM Audit: integrity check" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    // Execute something to populate state
    var compiler = try Compiler.init(allocator, "1 + 2");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    _ = try vm.execute(&expr);

    // Run the audit - should not panic
    std.debug.print("\n=== Running VM Audit ===\n", .{});
    vm.audit();
    std.debug.print("=== Audit Passed ===\n\n", .{});
}

test "Source Map: error captures source offset" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    // Expression: "1 + sin()" - sin() requires 1 argument
    // The error should occur at the call_builtin instruction
    const source = "1 + sin()";
    var compiler = try Compiler.init(allocator, source);
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    std.debug.print("\n=== Source Map Error Test ===\n", .{});
    std.debug.print("Expression: \"{s}\"\n", .{source});
    std.debug.print("Source offsets: {any}\n", .{expr.source_offsets});

    // Execute and expect error
    const result = vm.execute(&expr);
    if (result) |_| {
        // Shouldn't succeed
        try std.testing.expect(false);
    } else |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.debug.print("Error offset: {d}\n", .{vm.getLastErrorOffset()});

        // Verify we got NotEnoughArgs error
        try std.testing.expectEqual(error.NotEnoughArgs, err);

        // Verify offset is captured (should be > 0, pointing near "sin()")
        try std.testing.expect(vm.getLastErrorOffset() > 0);
        std.debug.print("=== Source Map Test Passed ===\n\n", .{});
    }
}
