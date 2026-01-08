const std = @import("std");
const testing = std.testing;
const diagnostics = @import("diagnostics");

test "formatErrorWithPointer - basic pointer" {
    const allocator = testing.allocator;
    const expr = "a = sin()";
    const err = "Not enough arguments";
    // sin is at index 4 (0:a, 1: , 2:=, 3: , 4:s, 5:i, 6:n)
    // If error offset is 4 (start of 'sin')
    const offset = 4;

    const result = try diagnostics.formatErrorWithPointer(allocator, expr, err, offset, 0);
    defer allocator.free(result);

    const expected = "    ^^^\nNot enough arguments";

    try testing.expectEqualStrings(expected, result);
}

test "formatErrorWithPointer - middle of token" {
    const allocator = testing.allocator;
    const expr = "my_var + 5";
    const err = "Unknown variable";
    // 'v' is at index 3
    const offset = 3;

    const result = try diagnostics.formatErrorWithPointer(allocator, expr, err, offset, 0);
    defer allocator.free(result);

    // Should highlight the whole "my_var"
    // "my_var" starts at 0, ends at 6
    const expected = "^^^^^^\nUnknown variable";

    try testing.expectEqualStrings(expected, result);
}

test "formatErrorWithPointer - single char" {
    const allocator = testing.allocator;
    const expr = "1 + 2";
    const err = "Error";
    const offset = 2; // '+'

    const result = try diagnostics.formatErrorWithPointer(allocator, expr, err, offset, 0);
    defer allocator.free(result);

    const expected = "  ^\nError";

    try testing.expectEqualStrings(expected, result);
}

test "formatErrorWithPointer - out of bounds" {
    const allocator = testing.allocator;
    const expr = "test";
    const err = "Error";
    const offset = 10;

    const result = try diagnostics.formatErrorWithPointer(allocator, expr, err, offset, 0);
    defer allocator.free(result);

    // Should just return error message
    try testing.expectEqualStrings(err, result);
}

test "formatErrorWithPointer - indented" {
    const allocator = testing.allocator;
    const expr = "a = sin()";
    const err = "Not enough arguments";
    const offset = 4;
    const indent = 2;

    const result = try diagnostics.formatErrorWithPointer(allocator, expr, err, offset, indent);
    defer allocator.free(result);

    const expected =
        \\      ^^^
        \\Not enough arguments
    ;

    try testing.expectEqualStrings(expected, result);
}
