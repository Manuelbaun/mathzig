# Parser and Expression Compilation

The MathZig compiler converts mathematical expressions into bytecode. It uses a recursive descent parser with operator precedence.

## Parser Structure

```zig
pub const Compiler = struct {
    tokenizer: Tokenizer,
    current: Token,
    previous: Token,
    builder: BytecodeBuilder,
    source: []const u8,
    variables: std.StringHashMap(u24),
    registry: *const UnitRegistry,
    next_var_index: u24,
    had_error: bool,
    pending_var_name: []const u8,
};
```

## Token Types

```zig
pub const TokenType = enum {
    // Literals
    number,
    identifier,
    string,
    
    // Keywords
    kw_true,
    kw_false,
    kw_in,
    kw_to,
    kw_and,
    kw_or,
    kw_not,
    kw_xor,
    
    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    equal,
    equal_equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    ampersand,
    ampersand_ampersand,
    pipe,
    pipe_pipe,
    less_less,
    greater_greater,
    greater_greater_greater,
    bang,
    tilde,
    question,
    
    // Punctuation
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    semicolon,
    colon,
    apostrophe,
    complex_i,  // 'i' for complex numbers
    
    // End of file
    EOF,
};
```

## Operator Precedence

```zig
const Precedence = enum(u8) {
    none,         // Lowest
    assignment,   // =
    conditional,  // ?:
    kw_to,        // to
    or_,          // or ||
    and_,         // and &&
    bitwise_or,   // |
    bitwise_xor,  // ^^
    bitwise_and,  // &
    equality,     // == !=
    comparison,   // < > <= >=
    shift,        // << >> >>>
    term,         // + -
    factor,       // * / %
    unary,        // - ! ~ not
    power,        // ^
    postfix,      // ' () []
    primary,      // Highest
};
```

### Precedence Table

| Precedence | Operators |
|------------|-----------|
| assignment | = |
| conditional | ?: |
| or_ | or, \|\| |
| and_ | and, && |
| bitwise_or | \| |
| bitwise_xor | ^^ |
| bitwise_and | & |
| equality | ==, != |
| comparison | <, <=, >, >= |
| shift | <<, >>, >>> |
| term | +, - |
| factor | *, /, % |
| unary | -, !, ~, not |
| power | ^ |
| postfix | (), [] |

## Supported Number Notations

MathZig supports various numeric formats in expressions:

| Notation | Example | Description |
|----------|---------|-------------|
| **Decimal** | `42`, `3.14` | Standard integer and floating point |
| **Leading Dot**| `.5` | Shorthand for `0.5` |
| **Scientific** | `1e-5`, `2.5E10`| Base-10 exponentiation |
| **Hexadecimal**| `0xFF` | Base-16 (prefix `0x`) |
| **Binary** | `0b1010` | Base-2 (prefix `0b`) |
| **Imaginary** | `5i`, `2.5i` | Complex imaginary component (suffix `i`) |

## Parsing Expression Grammar

```ebnf
expression      ::= assignment
assignment      ::= identifier "=" assignment
                  | conditional
conditional     ::= logical_or "?" expression ":" logical_or
                  | logical_or
logical_or      ::= logical_and ("or" logical_and)*
logical_and     ::= bitwise_or ("and" bitwise_or)*
bitwise_or      ::= bitwise_xor ("|" bitwise_xor)*
bitwise_xor     ::= bitwise_and ("^^" bitwise_and)*
bitwise_and     ::= equality ("&" equality)*
equality        ::= comparison (("==" | "!=") comparison)*
comparison      ::= shift (("<" | "<=" | ">" | ">=") shift)*
shift           ::= term (("<<" | ">>" | ">>>") term)*
term            ::= factor (("+" | "-") factor)*
factor          ::= power (("*" | "/" | "%") power)*
power           ::= unary ("^" unary)*
unary           ::= ("-" | "!" | "~" | "not") unary
                  | postfix
postfix         ::= primary ("(" arguments? ")" | "[" expression "]")*
primary         ::= number
                  | identifier
                  | string
                  | "true" | "false"
                  | "i"  // complex i
                  | "(" expression ")"
                  | "[" matrix "]"
```

## Compilation Process

### 1. Initialize Compiler

```zig
pub fn init(allocator: std.mem.Allocator, source: []const u8) Compiler {
    var tokenizer = Tokenizer.init(source);
    const first_token = tokenizer.next();
    
    return .{
        .tokenizer = tokenizer,
        .current = first_token,
        .previous = first_token,
        .builder = BytecodeBuilder.init(allocator),
        .source = source,
        .variables = std.StringHashMap(u24).init(allocator),
        .registry = undefined,
        .next_var_index = 0,
        .had_error = false,
        .pending_var_name = "",
    };
}
```

### 2. Parse Expression

```zig
pub fn compile(self: *Self) !CompiledExpr {
    try self.expression();
    
    if (self.had_error) {
        return error.CompileError;
    }
    
    return try self.builder.build();
}

fn expression(self: *Self) CompileError!void {
    try self.parsePrecedence(.assignment);
}
```

### 3. Precedence-Based Parsing

```zig
fn parsePrecedence(self: *Self, min_prec: Precedence) CompileError!void {
    self.advance();  // Consume prefix
    
    // Parse prefix expression
    try switch (self.previous.type) {
        .number => self.number(),
        .identifier => self.identifier(),
        .lparen => self.grouping(),
        .lbracket => self.matrix(),
        .minus => self.unary(.neg),
        .bang => self.unary(.not_),
        .kw_true => self.literal(Value.initBoolean(true)),
        .kw_false => self.literal(Value.initBoolean(false)),
        .complex_i => self.complexI(),
        else => {
            self.had_error = true;
            return error.UnexpectedToken;
        },
    };
    
    // Parse infix expressions (operators)
    while (@intFromEnum(self.getInfixPrecedence()) >= @intFromEnum(min_prec)) {
        self.advance();
        try self.infix();
    }
}
```

### 4. Number Parsing

```zig
fn number(self: *Self) CompileError!void {
    const lexeme = self.previous.lexeme(self.source);
    const value = std.fmt.parseFloat(f64, lexeme) catch {
        // Try parsing as hex or binary
        if (lexeme.len > 2 and lexeme[1] == 'x') {
            const hex_value = std.fmt.parseInt(i64, lexeme[2..], 16) catch {
                self.had_error = true;
                return error.InvalidNumber;
            };
            try self.builder.emitConstant(Value.initNumber(@floatFromInt(hex_value)));
            return;
        }
        // ... binary parsing
        self.had_error = true;
        return error.InvalidNumber;
    };
    
    try self.builder.emitConstant(Value.initNumber(value));
}
```

### 5. Identifier and Variable Handling

```zig
fn identifier(self: *Self) CompileError!void {
    const name = self.previous.lexeme(self.source);
    
    // Check if it's a function call
    if (self.current.type == .lparen) {
        try self.functionCall(name);
        return;
    }
    
    // Check if it's a unit name
    if (self.registry.findUnit(name)) |res| {
        self.builder.markNonNumeric();
        const val = Value.initUnit(res.unit.scale * res.prefix_scale, 
                                   res.unit.dimensions);
        try self.builder.emitConstant(val);
        return;
    }
    
    // Check if this is assignment LHS
    if (self.current.type == .equal) {
        self.pending_var_name = name;
        return;
    }
    
    // It's a variable reference
    const var_index = self.getOrCreateVariable(name);
    try self.builder.emitWithOperand(.load_var, var_index);
}
```

### 6. Function Calls

```zig
fn functionCall(self: *Self, name: []const u8) CompileError!void {
    self.advance(); // consume '('
    
    var arg_count: u8 = 0;
    if (self.current.type != .rparen) {
        try self.expression();
        arg_count += 1;
        
        while (self.current.type == .comma) {
            self.advance();
            try self.expression();
            arg_count += 1;
        }
    }
    
    if (self.current.type != .rparen) {
        self.had_error = true;
        return error.ExpectedRightParen;
    }
    self.advance(); // consume ')'
    
    // Look up builtin function
    const func_id = getBuiltinId(name) orelse {
        self.had_error = true;
        return error.UnknownFunction;
    };
    
    // Encode function ID and arg count
    const operand: u24 = @as(u24, func_id) | (@as(u24, arg_count) << 16);
    try self.builder.emitWithOperand(.call_builtin, operand);
}
```

### 7. Assignment

```zig
fn assignment(self: *Self) CompileError!void {
    const name = self.pending_var_name;
    self.pending_var_name = "";
    
    const var_index = self.getOrCreateVariable(name);
    
    // Parse the RHS expression
    try self.parsePrecedence(.assignment);
    
    // Duplicate and store
    try self.builder.emit(.dup);
    try self.builder.emitWithOperand(.store_var, var_index);
}
```

### 8. Matrix Parsing

```zig
fn matrix(self: *Self) CompileError!void {
    self.builder.markNonNumeric();
    var rows: u32 = 0;
    var cols: u32 = 0;
    var current_row_cols: u32 = 0;
    
    if (self.current.type != .rbracket) {
        rows = 1;
        while (true) {
            try self.expression();
            current_row_cols += 1;
            
            if (self.current.type == .comma) {
                self.advance();
                continue;
            } else if (self.current.type == .semicolon) {
                if (cols == 0) cols = current_row_cols 
                else if (cols != current_row_cols) return error.CompileError;
                current_row_cols = 0;
                rows += 1;
                self.advance();
                continue;
            } else if (self.current.type == .rbracket) {
                if (cols == 0) cols = current_row_cols;
                break;
            }
        }
    }
    
    self.advance();
    
    const operand: u24 = @as(u24, @intCast(rows)) | 
                         (@as(u24, @intCast(cols)) << 12);
    try self.builder.emitWithOperand(.mat_create, operand);
}
```

## Builtin Functions

```zig
fn getBuiltinId(name: []const u8) ?u16 {
    const builtins = std.StaticStringMap(u16).initComptime(.{
        .{ "abs", @intFromEnum(BuiltinFn.abs) },
        .{ "sqrt", @intFromEnum(BuiltinFn.sqrt) },
        .{ "cbrt", @intFromEnum(BuiltinFn.cbrt) },
        .{ "exp", @intFromEnum(BuiltinFn.exp) },
        .{ "log", @intFromEnum(BuiltinFn.log) },
        .{ "ln", @intFromEnum(BuiltinFn.log) },
        .{ "log10", @intFromEnum(BuiltinFn.log10) },
        .{ "log2", @intFromEnum(BuiltinFn.log2) },
        .{ "sin", @intFromEnum(BuiltinFn.sin) },
        .{ "cos", @intFromEnum(BuiltinFn.cos) },
        .{ "tan", @intFromEnum(BuiltinFn.tan) },
        .{ "asin", @intFromEnum(BuiltinFn.asin) },
        .{ "acos", @intFromEnum(BuiltinFn.acos) },
        .{ "atan", @intFromEnum(BuiltinFn.atan) },
        .{ "atan2", @intFromEnum(BuiltinFn.atan2) },
        .{ "sinh", @intFromEnum(BuiltinFn.sinh) },
        .{ "cosh", @intFromEnum(BuiltinFn.cosh) },
        .{ "tanh", @intFromEnum(BuiltinFn.tanh) },
        .{ "floor", @intFromEnum(BuiltinFn.floor) },
        .{ "ceil", @intFromEnum(BuiltinFn.ceil) },
        .{ "round", @intFromEnum(BuiltinFn.round) },
        .{ "trunc", @intFromEnum(BuiltinFn.trunc) },
        .{ "sign", @intFromEnum(BuiltinFn.sign) },
        .{ "min", @intFromEnum(BuiltinFn.min) },
        .{ "max", @intFromEnum(BuiltinFn.max) },
        .{ "clamp", @intFromEnum(BuiltinFn.clamp) },
    });
    
    return builtins.get(name);
}
```

## Compilation Examples

### Simple Expression

```javascript
// Input: "2 + 3 * 4"
//
// Parsing:
// 1. Parse "2" -> push_const(2)
// 2. See +, precedence 4, parse term at precedence 5
// 3. Parse "3" -> push_const(3)
// 4. Parse "4" -> push_const(4)
// 5. See * -> mul
// 6. Back to +, precedence 4 >= 4 -> add
//
// Bytecode (after constant folding):
// push_const(14), halt
```

### Variable Assignment

```javascript
// Input: "x = 5 + 3"
//
// Bytecode:
// push_const(5)
// push_const(3)
// add          // 8
// dup          // duplicate for return
// store_var(x) // store 8 in x
// halt         // return 8
```

### Function Call

```javascript
// Input: "sin(3.14) + cos(0)"
//
// Bytecode:
// push_const(3.14)
// call_builtin(sin, 1)
// push_const(0)
// call_builtin(cos, 1)
// add
// halt
```

## Related Documentation

- [Overview](overview.md)
- [Bytecode Format](bytecode.md)
- [Virtual Machine](vm.md)
- [Value Types](values.md)
