const std = @import("std");
const libvaxis = @import("libvaxis");

pub const TokenType = enum {
    number,
    operator,
    identifier,
    string,
    comment,
    unknown,
    whitespace,
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
    start: usize,
};

pub fn highlight(allocator: std.mem.Allocator, text: []const u8) ![]libvaxis.Segment {
    var segments = std.ArrayListUnmanaged(libvaxis.Segment).empty;
    errdefer segments.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const char = text[i];
        const start = i;
        var token_type: TokenType = .unknown;

        if (std.ascii.isWhitespace(char)) {
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            token_type = .whitespace;
        } else if (std.ascii.isDigit(char)) {
            while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.')) : (i += 1) {}
            token_type = .number;
        } else if (std.ascii.isAlphabetic(char) or char == '_') {
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
            token_type = .identifier;
        } else if (char == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            if (i < text.len) i += 1;
            token_type = .string;
        } else if (char == '#') { // Comment
            while (i < text.len) : (i += 1) {}
            token_type = .comment;
        } else {
            // Operator or single char
            const ops = "+-*/^%=(),[]{}";
            if (std.mem.indexOfScalar(u8, ops, char) != null) {
                token_type = .operator;
            }
            i += 1;
        }

        const subtext = text[start..i];
        const style = getStyle(token_type);
        try segments.append(allocator, .{ .text = subtext, .style = style });
    }

    return segments.toOwnedSlice(allocator);
}

fn getStyle(token_type: TokenType) libvaxis.Style {
    return switch (token_type) {
        .number => .{ .fg = .{ .index = 45 } }, // Cyan
        .operator => .{ .fg = .{ .index = 15 }, .bold = true }, // White Bold
        .identifier => .{ .fg = .{ .index = 226 } }, // Yellow
        .string => .{ .fg = .{ .index = 46 } }, // Green
        .comment => .{ .fg = .{ .index = 242 } }, // Gray
        .whitespace => .{} ,
        .unknown => .{} ,
    };
}