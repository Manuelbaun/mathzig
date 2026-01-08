const std = @import("std");
const mathzig = @import("mathzig");
const ValueTag = mathzig.ValueTag;

test "toLaTeX eval returns strings for representative expressions" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "1 + 2 * 3",
        "1 / 2",
        "sqrt(x^2 + y^2)",
    };

    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    for (cases) |source| {
        const quoted = try std.fmt.allocPrint(allocator, "toLaTeX(\"{s}\")", .{source});
        defer allocator.free(quoted);

        const runtime = try ctx.eval(quoted);
        defer runtime.release();
        try std.testing.expectEqual(ValueTag.string, runtime.tag);
        try std.testing.expect(runtime.data.string.len > 0);
    }
}
