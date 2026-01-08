# Bytecode Format and Instructions

MathZig compiles expressions to a compact bytecode format that can be efficiently interpreted by the virtual machine. The bytecode uses a stack-based architecture with 64-bit instructions.

## Instruction Format

Each instruction is a 64-bit packed struct:

```zig
pub const Instruction = packed struct {
    opcode: Opcode,    // 8-bit operation code
    operand: u24 = 0,  // 24-bit operand (constants, variables, jumps)
};
```

### Instruction Layout

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Instruction Layout                              │
├───────────┬─────────────────────────────────────────────────────────────────┤
│ Opcode    │                          Operand                                │
│ (8 bits)  │                         (24 bits)                                │
└───────────┴─────────────────────────────────────────────────────────────────┘
```

The 24-bit operand encodes:
- Constant pool indices (0 to 16,777,215)
- Variable indices (0 to 255)
- Jump offsets (0 to 16,777,215)
- Combined indices for superinstructions

## Opcodes

### Stack Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `push_const` | constant_index | Push constant from pool |
| `pop` | - | Discard top of stack |
| `dup` | - | Duplicate top of stack |

### Variable Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `load_var` | variable_index | Load variable by index |
| `store_var` | variable_index | Store to variable by index |

### Arithmetic Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `add` | - | a + b |
| `sub` | - | a - b |
| `mul` | - | a * b |
| `div` | - | a / b |
| `mod` | - | a % b |
| `pow` | - | a ^ b |
| `neg` | - | -a |
| `pos` | - | +a (no-op for numbers) |

### Comparison Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `eq` | - | a == b |
| `ne` | - | a != b |
| `lt` | - | a < b |
| `le` | - | a <= b |
| `gt` | - | a > b |
| `ge` | - | a >= b |

### Logical Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `and_` | - | a && b |
| `or_` | - | a \|\| b |
| `not_` | - | !a |

### Bitwise Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `band` | - | a & b |
| `bor` | - | a \| b |
| `bxor` | - | a ^^ b |
| `bnot` | - | ~a |
| `shl` | - | a << b |
| `shr` | - | a >> b |

### Function Calls

| Opcode | Operand | Description |
|--------|---------|-------------|
| `call` | arg_count | Call function |
| `call_user` | func_id (8) \| arg_count (8) | Call user-defined function |
| `def_user` | const_index | Define user function |
| `call_builtin` | func_id (16) \| arg_count (8) | Call builtin function |
| `call_builtin_where` | func_id (16) \| arg_count (8) | Call builtin with predicate |

### Specialized Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `eval_poly` | var_idx (8) \| coeff_start (8) \| coeff_count (8) | Polynomial evaluation |
| `fma` | - | Fused Multiply-Add: a * b + c |
| `fma_var_const_const` | var_idx (8) \| c1_idx (8) \| c2_idx (8) | x * c1 + c2 |

### Matrix Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `mat_create` | rows (12) \| cols (12) | Create matrix |
| `mat_index` | - | **DEAD / legacy.** Never emitted. Superseded by `get_index` (and fused `load_var_index_*`). Retained in the enum for bytecode ordinal stability only. AOT returns `UnsupportedOpcode`; do not emit. |
| `emul` | - | Element-wise multiplication |
| `ediv` | - | Element-wise division |
| `epow` | - | Element-wise power |

### Record Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `rec_create` | field_count | Create record |
| `rec_get` | const_string_index | Get field from record |
| `rec_get_dyn` | - | Dynamic record field access |

### Slice/Index Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `make_slice` | - | Create slice (pops step, end, start) |
| `get_index` | key_count | Get value by index/slice |

### Unit Operations

| Opcode | Operand | Description |
|--------|---------|-------------|
| `unit_create` | unit_id | Create unit value |
| `unit_convert` | target_unit_id | Convert units |

### Control Flow

| Opcode | Operand | Description |
|--------|---------|-------------|
| `jmp` | offset | Unconditional jump |
| `jmp_if_false` | offset | Jump if top of stack is false |
| `jmp_if_true` | offset | Jump if top of stack is true |

### Special

| Opcode | Operand | Description |
|--------|---------|-------------|
| `halt` | - | Stop execution, return TOS |
| `nop` | - | No operation |

## Compiled Expression Structure

```zig
pub const CompiledExpr = struct {
    code: []Instruction,           // Bytecode instructions
    constants: []Value,            // All constants used
    constants_f64: []f64,          // f64 constants for fast-path
    max_stack: u16,                // Max stack depth needed
    is_number_only: bool,          // Enables fast-path execution
    owns_memory: bool = true,
    allocator: std.mem.Allocator,
};
```

## Bytecode Builder

```zig
pub const BytecodeBuilder = struct {
    code: std.ArrayListUnmanaged(Instruction),
    constants: std.ArrayListUnmanaged(Value),
    allocator: std.mem.Allocator,
    is_number_only: bool,
    
    pub fn init(allocator: std.mem.Allocator) BytecodeBuilder
    pub fn emit(self: *BytecodeBuilder, opcode: Opcode) !void
    pub fn emitWithOperand(self: *BytecodeBuilder, opcode: Opcode, operand: u24) !void
    pub fn emitConstant(self: *BytecodeBuilder, value: Value) !void
    pub fn build(self: *BytecodeBuilder) !CompiledExpr
};
```

## Example: Expression Compilation

### Source Expression

```javascript
x * 0.5 + 2.0
```

### Compilation Steps

```
1. load_var(x)      // Push variable x value
2. push_const(0)    // Push constant 0.5
3. mul              // x * 0.5
4. push_const(1)    // Push constant 2.0
5. add              // (x * 0.5) + 2.0
6. halt             // Return result
```

### Bytecode (with peephole optimization)

With FMA fusion optimization:
```
1. load_var(x)      // Push x
2. push_const(0)    // Push 0.5
3. push_const(1)    // Push 2.0
4. fma_var_const_const  // x * 0.5 + 2.0 (single instruction)
5. halt
```

## Constant Folding

The compiler performs constant folding at compile time:

```javascript
// Original: 2 + 3 * 4
// After folding: 2 + 12 = 14

Bytecode:
1. push_const(14)   // Folded result
2. halt
```

## Superinstructions

Superinstructions combine common instruction sequences into single instructions:

### FMA Fusion

```javascript
// Pattern: load_var, push_const, push_const, mul, add
// Becomes: fma_var_const_const

// Before: x * a + b
load_var(x)      // 1 instruction
push_const(a)    // 1 instruction
push_const(b)    // 1 instruction
mul              // 1 instruction
add              // 1 instruction
// Total: 5 instructions

// After: fma_var_const_const
fma_var_const_const(var_idx, c1_idx, c2_idx)
// Total: 1 instruction (5x reduction)
```

### Superinstruction Encoding

```zig
// fma_var_const_const operand encoding (24 bits):
┌───────────────────┬───────────────────┬───────────────────┐
│  var_idx (8 bits) │  c1_idx (8 bits)  │  c2_idx (8 bits)  │
└───────────────────┴───────────────────┴───────────────────┘
```

## Polynomial Evaluation

Special `eval_poly` instruction for efficient polynomial evaluation:

```javascript
// Polynomial: 25*x^5 - 35*x^4 - 15*x^3 + 40*x^2 - 15*x + 1
// Horner's method: (((((25*x - 35)*x - 15)*x + 40)*x - 15)*x + 1

Bytecode:
1. eval_poly(var_idx, coeff_start=0, coeff_count=6)
2. halt

// Coefficients: [25, -35, -15, 40, -15, 1]
```

## Operand Encoding for Different Instructions

### Variable Access

```zig
// load_var, store_var: operand = variable_index (8 bits)
Instruction.initWithOperand(.load_var, var_index);
```

### Constants

```zig
// push_const: operand = constant_pool_index (24 bits)
Instruction.initWithOperand(.push_const, constant_index);
```

### Function Calls

```zig
// call_builtin: operand = func_id (16 bits) | arg_count (8 bits)
const operand: u24 = @as(u24, func_id) | (@as(u24, arg_count) << 16);
Instruction.initWithOperand(.call_builtin, operand);
```

### Jumps

```zig
// jmp, jmp_if_false, jmp_if_true: operand = byte_offset
Instruction.initWithOperand(.jmp, offset);
```

### Matrix Creation

```zig
// mat_create: operand = rows (12 bits) | cols (12 bits)
const operand: u24 = @as(u24, @intCast(rows)) | (@as(u24, @intCast(cols)) << 12);
Instruction.initWithOperand(.mat_create, operand);
```

## Bytecode Verification

```zig
test "bytecode builder" {
    const allocator = std.testing.allocator;
    
    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();
    
    // Build: 2 + 3
    try builder.emitConstant(Value.initNumber(2));
    try builder.emitConstant(Value.initNumber(3));
    try builder.emit(.add);
    
    var expr = try builder.build();
    defer expr.deinit();
    
    // Constant folding should reduce to: push 5, halt
    try std.testing.expectEqual(@as(usize, 2), expr.code.len);
    try std.testing.expectEqual(@as(usize, 1), expr.constants.len);  // Only 5
}
```

## Related Documentation

- [Overview](overview.md)
- [Value Types](values.md)
- [Virtual Machine](vm.md)
- [Parser and Compiler](compiler.md)
