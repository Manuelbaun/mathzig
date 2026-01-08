const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "random functions" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // random()
        {
            const res = try ctx.eval("random()");
            const val = res.toNumber().?;
            try std.testing.expect(val >= 0 and val < 1.0);
        }

        // random(10.0)
        {
            const res = try ctx.eval("random(10.0)");
            const val = res.toNumber().?;
            if (val < 0 or val > 10.0) std.debug.print("FAIL: random(10.0) -> {d}\n", .{val});
            try std.testing.expect(val >= 0 and val <= 10.0);
        }

        // randomInt(5, 15)
        {
            const res = try ctx.eval("randomInt(5, 15)");
            const val = res.toNumber().?;
            if (val < 5 or val >= 15) std.debug.print("FAIL: randomInt(5, 15) -> {d}\n", .{val});
            try std.testing.expect(val >= 5 and val < 15);
            try std.testing.expect(val == @floor(val));
        }

        // pickRandom([1, 2, 3])
        {
            const res = try ctx.eval("pickRandom([10, 20, 30])");
            const val = res.toNumber().?;
            try std.testing.expect(val == 10 or val == 20 or val == 30);
        }
    }
}
