const std = @import("std");
const mathzig = @import("mathzig");

test "syntax error - missing parenthesis" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // "sin(2" -> missing closing paren
    // length is 5. '2' is at 4. EOF is at 5.
    // Parser expects ')' after '2'.
    _ = ctx.eval("sin(2") catch |err| {
        try std.testing.expectEqual(error.ExpectedRightParen, err);
        
        // Verify error message
        const err_msg = ctx.lastError();
        try std.testing.expectEqualStrings("Expected ')'", err_msg);

        // Verify offset
        // "sin(2" -> cursor should probably point to end or after '2'
        // 's'=0, 'i'=1, 'n'=2, '('=3, '2'=4
        // The parser advances past '2' to find ')' but finds EOF.
        // So current token is EOF, which starts at 5.
        const offset = ctx.getLastErrorOffset();
        try std.testing.expectEqual(@as(u32, 5), offset);
        return;
    };
    try std.testing.expect(false); // Should have failed
}

test "syntax error - unexpected token" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // "1 + +"
    // '1'=0, ' '=1, '+'=2, ' '=3, '+'=4
    // Second + is unary? "1 + (+...)"?
    // "1 + + 2" is valid (1 + positive 2).
    // "1 + *" is invalid.
    _ = ctx.eval("1 + *") catch {
        // Expect parse error
        // ctx.lastError() should be "Unexpected token"
        const err_msg = ctx.lastError();
        try std.testing.expectEqualStrings("Unexpected token", err_msg);
        return;
    };
    try std.testing.expect(false); // Should have failed
}
