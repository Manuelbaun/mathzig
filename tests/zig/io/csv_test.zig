const std = @import("std");
const mathzig = @import("mathzig");
const VM = mathzig.VM;
const Compiler = mathzig.Compiler;
const UnitRegistry = mathzig.units.UnitRegistry;
const Value = mathzig.Value;

test "CSV read and write" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 64, null);
    defer vm.deinit();

    // 1. Create a dummy CSV file
    const csv_content = \
        "time,open,close"
        "1000,10.5,11.2"
        "2000,11.2,10.8"
        "3000,10.8,12.5"
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = "test_input.csv", .data = csv_content });
    defer std.fs.cwd().deleteFile("test_input.csv") catch {};

    // 2. Read it
    const dsl = "data = read_csv(\"test_input.csv\", {time: \"time\", val: \"close\"})";
    var compiler = try Compiler.init(allocator, dsl);
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    _ = try vm.execute(&expr);

    // 3. Write it back to a new file
    const dsl_write = "write_csv(data, \"test_output.csv\")";
    var compiler2 = try Compiler.init(allocator, dsl_write);
    compiler2.registry = &registry;
    defer compiler2.deinit();

    var expr2 = try compiler2.compile();
    defer expr2.deinit();

    _ = try vm.execute(&expr2);
    defer std.fs.cwd().deleteFile("test_output.csv") catch {};

    // 4. Verify output
    const output_content = try std.fs.cwd().readFileAlloc(allocator, "test_output.csv", 1024);
    defer allocator.free(output_content);

    // Note: read_csv returns a record where each series has the same timestamps.
    // writeCsv for a record writes one time column and then the values.
    // Expected output should have 'time' and 'val' columns.
    try std.testing.expect(std.mem.indexOf(u8, output_content, "time,val") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_content, "1000.000000,11.200000") != null);
}
