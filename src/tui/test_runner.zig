const std = @import("std");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: tui_test <input_keys.json> <output_screen.txt>\n", .{});
        std.process.exit(1);
    }

    std.debug.print("TUI headless test runner initialized\n", .{});
}
