const std = @import("std");

/// Token types for the mathzig expression language
pub const TokenType = enum(u8) {
    // Literals
    number, // 123, 3.14, 1e-5, 0xFF, 0b1010
    string, // "hello", 'world'
    unit_literal, // [kg/kWh]
    identifier, // variable names, function names, unit names
    complex_i, // the 'i' suffix for imaginary numbers

    // Arithmetic operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    caret, // ^

    // Element-wise operators (for matrices)
    dot_star, // .*
    dot_slash, // ./
    dot_caret, // .^

    // Comparison operators
    equal_equal, // ==
    not_equal, // !=
    less, // <
    less_equal, // <=
    greater, // >
    greater_equal, // >=

    // Logical operators
    ampersand_ampersand, // &&
    pipe_pipe, // ||
    bang, // !

    // Bitwise operators
    ampersand, // &
    pipe, // |
    tilde, // ~
    caret_caret, // ^^
    less_less, // <<
    greater_greater, // >>
    greater_greater_greater, // >>>

    // Assignment
    equal, // =

    // Delimiters
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    lbrace, // {
    rbrace, // }
    comma, // ,
    colon, // :
    semicolon, // ;
    apostrophe, // ' (transpose)
    question, // ?
    dot, // .

    // Keywords
    kw_to, // to (unit conversion)
    kw_in, // in (unit conversion)
    kw_as, // as (unit conversion)
    kw_and, // and
    kw_or, // or
    kw_xor, // xor
    kw_not, // not
    kw_true, // true
    kw_false, // false
    kw_if, // if
    kw_else, // else
    kw_function, // function
    kw_where, // where
    kw_while, // while
    kw_for, // for
    kw_break, // break
    kw_continue, // continue
    kw_return, // return

    // Special
    eof, // End of input
    err, // Error token
};

/// A token in the input stream
pub const Token = struct {
    type: TokenType,
    start: u32, // Start position in source
    len: u16, // Length of token
    line: u32, // Line number (1-based)

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

/// Tokenizer for mathzig expressions
pub const Tokenizer = struct {
    source: []const u8,
    current: u32,
    line: u32,
    config: ?*const @import("../core/config.zig").Config,

    const keywords = std.StaticStringMap(TokenType).initComptime(.{
        .{ "to", .kw_to },
        .{ "in", .kw_in },
        .{ "as", .kw_as },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "xor", .kw_xor },
        .{ "not", .kw_not },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "function", .kw_function },
        .{ "where", .kw_where },
        .{ "while", .kw_while },
        .{ "for", .kw_for },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
        .{ "return", .kw_return },
        .{ "i", .complex_i },
    });

    pub fn init(source: []const u8) Tokenizer {
        return .{
            .source = source,
            .current = 0,
            .line = 1,
            .config = null,
        };
    }

    pub fn initWithConfig(source: []const u8, config: *const @import("../core/config.zig").Config) Tokenizer {
        return .{
            .source = source,
            .current = 0,
            .line = 1,
            .config = config,
        };
    }

    fn getRowSep(self: *Tokenizer) u8 {
        if (self.config) |c| return c.row_separator;
        return ';';
    }

    pub fn next(self: *Tokenizer) Token {
        return self.nextInternal();
    }

    fn nextInternal(self: *Tokenizer) Token {
        self.skipWhitespace();

        if (self.isAtEnd()) {
            return .{
                .type = .eof,
                .start = self.current,
                .len = 0,
                .line = self.line,
            };
        }

        const c = self.advance();

        // Identifiers and keywords
        if (isAlpha(c)) {
            return self.identifier();
        }

        // Numbers
        if (isDigit(c)) {
            return self.number();
        }

        if (c == '.' and isDigit(self.peek())) {
            return self.number();
        }

        // Prioritize custom separators
        if (c == self.getRowSep()) {
            return self.makeTokenFrom(.semicolon, self.current - 1);
        }

        // Single and multi-character tokens
        return switch (c) {
            '+' => self.makeToken(.plus),
            '-' => self.makeToken(.minus),
            '*' => self.makeToken(.star),
            '/' => self.makeToken(.slash),
            '%' => self.makeToken(.percent),
            '^' => if (self.match('^')) self.makeToken(.caret_caret) else self.makeToken(.caret),
            '(' => self.makeToken(.lparen),
            ')' => self.makeToken(.rparen),
            ']' => self.makeToken(.rbracket),
            '{' => self.makeToken(.lbrace),
            '}' => self.makeToken(.rbrace),
            ',' => self.makeToken(.comma),
            ':' => self.makeToken(.colon),
            ';' => self.makeToken(.semicolon),
            '\'' => blk: {
                if (self.isAtEnd()) break :blk self.makeToken(.apostrophe);
                // Check if it's a string starting with ' or just a transpose
                // Heuristic: if followed by alpha or digit, might be start of 'string'
                // Actually, ' is mostly used for transpose in matrix math.
                // Let's check if the previous token was an identifier or closing bracket.
                // But tokenizer doesn't know previous token.
                // Standard approach: if it looks like a string literal, tokenize as string.
                // Let's just use " for strings and ' for transpose for now to avoid ambiguity,
                // OR check if there is a closing ' on the same line.
                var i = self.current;
                var found_closing = false;
                while (i < self.source.len and self.source[i] != '\n') : (i += 1) {
                    if (self.source[i] == '\'') {
                        found_closing = true;
                        break;
                    }
                }
                if (found_closing) {
                    break :blk self.string(c);
                } else {
                    break :blk self.makeToken(.apostrophe);
                }
            },
            '?' => self.makeToken(.question),
            '.' => if (self.peek() == '*')
                blk: {
                    _ = self.advance();
                    break :blk self.makeToken(.dot_star);
                }
            else if (self.peek() == '/')
                blk: {
                    _ = self.advance();
                    break :blk self.makeToken(.dot_slash);
                }
            else if (self.peek() == '^')
                blk: {
                    _ = self.advance();
                    break :blk self.makeToken(.dot_caret);
                }
            else
                self.makeTokenFrom(.dot, self.current - 1),
            '=' => if (self.match('=')) self.makeToken(.equal_equal) else self.makeToken(.equal),
            '!' => if (self.match('=')) self.makeToken(.not_equal) else self.makeToken(.bang),
            '<' => if (self.match('=')) self.makeToken(.less_equal) else if (self.match('<')) self.makeToken(.less_less) else self.makeToken(.less),
            '>' => if (self.match('=')) self.makeToken(.greater_equal) else if (self.match('>')) (if (self.match('>')) self.makeToken(.greater_greater_greater) else self.makeToken(.greater_greater)) else self.makeToken(.greater),
            '&' => if (self.match('&')) self.makeToken(.ampersand_ampersand) else self.makeToken(.ampersand),
            '|' => if (self.match('|')) self.makeToken(.pipe_pipe) else self.makeToken(.pipe),
            '~' => self.makeToken(.tilde),
            '"' => self.string(c),
            '[' => if (self.isUnitLiteralFollows()) self.unitLiteral() else self.makeToken(.lbracket),
            else => self.errorToken(),
        };
    }

    fn isUnitLiteralFollows(self: *Tokenizer) bool {
        // Unit literals follow numbers: 10[m], 5[kg/s]
        // Dynamic access follows identifiers: r["a"], obj[key]
        // Chained indexing: r[key_a][key_b] - the second [ follows ]
        // Matrices start expressions: [1, 2, 3]

        // Check what precedes the '[' - if it's a letter (identifier) or ']', it's indexing
        const bracket_pos = self.current - 1; // Position of '['
        if (bracket_pos > 0) {
            const prev_char = self.source[bracket_pos - 1];
            if (isAlpha(prev_char) or prev_char == '_') {
                return false; // Identifier before '[' = indexing, not unit
            }
            if (prev_char == ']' or prev_char == ')') {
                return false; // Chained indexing: x[a][b] or func()[a]
            }
        }

        // Check content for unit-like syntax
        var i = self.current;
        var has_alpha = false;
        while (i < self.source.len) : (i += 1) {
            const c = self.source[i];
            if (c == ']') return has_alpha; // Only a unit if it contains at least one letter
            if (isAlpha(c)) has_alpha = true;
            if (c == '[' or c == ',' or c == ';' or c == '\n' or c == '"') return false; // Matrix, dynamic access or nested
        }
        return false;
    }

    fn unitLiteral(self: *Tokenizer) Token {
        const start = self.current - 1;
        while (!self.isAtEnd() and self.peek() != ']') {
            _ = self.advance();
        }
        if (!self.isAtEnd()) _ = self.advance(); // consume ']'
        return self.makeTokenFrom(.unit_literal, start);
    }

    fn identifier(self: *Tokenizer) Token {
        const start = self.current - 1;

        while (!self.isAtEnd() and (isAlphaNumeric(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }

        const text = self.source[start..self.current];

        // Check for keywords
        if (keywords.get(text)) |token_type| {
            return self.makeTokenFrom(token_type, start);
        }

        return self.makeTokenFrom(.identifier, start);
    }

    fn number(self: *Tokenizer) Token {
        const start = self.current - 1;

        // Check for hex/binary/octal (only if it doesn't start with '.')
        if (self.source[start] == '0' and !self.isAtEnd()) {
            const next_char = self.peek();
            if (next_char == 'x' or next_char == 'X') {
                _ = self.advance();
                while (!self.isAtEnd() and (isHexDigit(self.peek()) or self.peek() == '_')) {
                    _ = self.advance();
                }
                return self.makeTokenFrom(.number, start);
            }
            if (next_char == 'b' or next_char == 'B') {
                _ = self.advance();
                while (!self.isAtEnd() and (self.peek() == '0' or self.peek() == '1' or self.peek() == '_')) {
                    _ = self.advance();
                }
                return self.makeTokenFrom(.number, start);
            }
        }

        // Integer part
        if (isDigit(self.source[start])) {
            while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
                _ = self.advance();
            }
        }

        // Decimal part
        // If we started with '.', we are already at the decimal part.
        // If we are at a '.', we consume it and digits.
        if (self.source[start] == '.') {
            while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
                _ = self.advance();
            }
        } else if (!self.isAtEnd() and self.peek() == '.') {
            _ = self.advance(); // consume '.'
            while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
                _ = self.advance();
            }
        }

        // Exponent part
        if (!self.isAtEnd() and (self.peek() == 'e' or self.peek() == 'E')) {
            _ = self.advance();
            if (!self.isAtEnd() and (self.peek() == '+' or self.peek() == '-')) {
                _ = self.advance();
            }
            while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
                _ = self.advance();
            }
        }

        return self.makeTokenFrom(.number, start);
    }

    fn string(self: *Tokenizer, quote: u8) Token {
        const start = self.current - 1;

        while (!self.isAtEnd() and self.peek() != quote) {
            if (self.peek() == '\n') {
                self.line += 1;
            }
            if (self.peek() == '\\' and !self.isAtEnd()) {
                _ = self.advance(); // skip escape char
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            return self.errorToken(); // Unterminated string
        }

        _ = self.advance(); // closing quote
        return self.makeTokenFrom(.string, start);
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => _ = self.advance(),
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '#' => {
                    // Comment until end of line
                    while (!self.isAtEnd() and self.peek() != '\n') {
                        _ = self.advance();
                    }
                },
                else => return,
            }
        }
    }

    fn makeToken(self: *Tokenizer, token_type: TokenType) Token {
        return self.makeTokenFrom(token_type, self.current -| 1);
    }

    fn makeTokenFrom(self: *Tokenizer, token_type: TokenType, start: u32) Token {
        return .{
            .type = token_type,
            .start = start,
            .len = @intCast(self.current - start),
            .line = self.line,
        };
    }

    fn errorToken(self: *Tokenizer) Token {
        return .{
            .type = .err,
            .start = self.current -| 1,
            .len = 1,
            .line = self.line,
        };
    }

    fn advance(self: *Tokenizer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        return c;
    }

    fn peek(self: *Tokenizer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    pub fn peekNext(self: *Tokenizer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn match(self: *Tokenizer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    fn isAtEnd(self: *Tokenizer) bool {
        return self.current >= self.source.len;
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isAlphaNumeric(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }
};

// Tests
test "tokenize basic arithmetic" {
    var tokenizer = Tokenizer.init("2 + 3 * 4");

    const t1 = tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t1.type);
    try std.testing.expectEqualStrings("2", t1.lexeme("2 + 3 * 4"));

    const t2 = tokenizer.next();
    try std.testing.expectEqual(TokenType.plus, t2.type);

    const t3 = tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t3.type);

    const t4 = tokenizer.next();
    try std.testing.expectEqual(TokenType.star, t4.type);

    const t5 = tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t5.type);

    const t6 = tokenizer.next();
    try std.testing.expectEqual(TokenType.eof, t6.type);
}

test "tokenize floating point" {
    var tokenizer = Tokenizer.init("3.14 1e-5 .5");

    const t1 = tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t1.type);
    try std.testing.expectEqualStrings("3.14", t1.lexeme("3.14 1e-5 .5"));

    const t2 = tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t2.type);
    try std.testing.expectEqualStrings("1e-5", t2.lexeme("3.14 1e-5 .5"));

    const t3 = tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t3.type);
}

test "tokenize identifiers and keywords" {
    var tokenizer = Tokenizer.init("x to km");

    const t1 = tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, t1.type);

    const t2 = tokenizer.next();
    try std.testing.expectEqual(TokenType.kw_to, t2.type);

    const t3 = tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, t3.type);
}
