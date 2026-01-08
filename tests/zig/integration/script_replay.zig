const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;

test "Script Replay: basic arithmetic and asserts" {
    const allocator = std.testing.allocator;
    
    const script_content = "# Test script\nx = 10\ny = 20\nz = x + y\nassert(z, 30)\n\n# Unit test\nlen = 10[m]\nassert(len, 1000[cm])\n\n# Boolean test\ncheck = 1 < 2\nassert(check, true)\n";
    const path = "test_script.mzig";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = script_content });
    defer std.fs.cwd().deleteFile(path) catch {};

    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    try ctx.loadScript(path);
}

test "Run all scripts in tests/scripts/" {
    const allocator = std.testing.allocator;

    // Ensure we can open the directory
    var dir = std.fs.cwd().openDir("tests/scripts", .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open tests/scripts: {}\n", .{err});
        return; 
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".mzig")) {
            // Construct full path relative to CWD (project root)
            const path = try std.fs.path.join(allocator, &.{ "tests/scripts", entry.path });
            defer allocator.free(path);

            std.debug.print("\n=== Running script: {s} ===\n", .{path});
            
            var ctx = try MathZig.init(allocator);
            defer ctx.deinit();
            
            try ctx.loadScript(path);
        }
    }
}
