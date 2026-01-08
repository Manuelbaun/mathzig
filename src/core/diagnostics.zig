const std = @import("std");

/// Format an error with a position pointer showing where it occurred
/// Output format:
///   a = sin()
///       ^^^
///   Error: Not enough arguments for function
pub fn formatErrorWithPointer(allocator: std.mem.Allocator, expression: []const u8, error_msg: []const u8, offset: u32, indent: usize) ![]const u8 {
    // If offset is 0 or beyond expression, just return the error message
    if (offset == 0 or offset > expression.len) {
        return try allocator.dupe(u8, error_msg);
    }

    // Find the token at the offset position (scan forward to find end of token)
    var token_end = offset;
    while (token_end < expression.len) : (token_end += 1) {
        const c = expression[token_end];
        // Stop at whitespace or operators/punctuation
        if (c == ' ' or c == '\t' or c == '(' or c == ')' or c == ',' or
            c == '+' or c == '-' or c == '*' or c == '/' or c == '^' or
            c == '=' or c == ';' or c == '[' or c == ']' or c == '{' or c == '}')
        {
            break;
        }
    }

    // Find token start (scan backward from offset)
    var token_start: u32 = offset;
    while (token_start > 0) : (token_start -= 1) {
        const c = expression[token_start - 1];
        if (c == ' ' or c == '\t' or c == '(' or c == ')' or c == ',' or
            c == '+' or c == '-' or c == '*' or c == '/' or c == '^' or
            c == '=' or c == ';' or c == '[' or c == ']' or c == '{' or c == '}')
        {
            break;
        }
    }

    // Calculate token length (minimum 1 for single character errors)
    const token_len = if (token_end > token_start) token_end - token_start else 1;

    // Build the pointer line: spaces up to token_start, then ^^^ for token length
    var pointer_line = std.ArrayListUnmanaged(u8).empty;
    defer pointer_line.deinit(allocator);

    // Add indentation + leading spaces
    try pointer_line.appendNTimes(allocator, ' ', indent + token_start);

    // Add carets for the token
    try pointer_line.appendNTimes(allocator, '^', token_len);

    // Format: "  ^^^\nError: message"
    return try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ pointer_line.items, error_msg });
}
