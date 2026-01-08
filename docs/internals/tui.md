# Terminal User Interface (TUI) Architecture

## Overview

The MathZig Terminal User Interface (TUI) provides an interactive REPL experience built with [libvaxis](https://github.com/rockorager/libvaxis), a cross-platform terminal UI library for Zig. The TUI features a split-pane layout with expression history, variable inspection, and a command input area.

## Architecture

```
src/tui/
├── main.zig          # Main widget, event handling, rendering
├── state.zig         # Application state, input buffer, variables
├── syntax.zig        # Syntax highlighting definitions
└── test_runner.zig   # Integrated test runner UI
```

### Core Components

#### MathZigWidget (`main.zig`)

The main widget that manages the TUI lifecycle:

```zig
pub const MathZigWidget = struct {
    allocator: std.mem.Allocator,
    app_state: state.AppState,
    render_arena: std.heap.ArenaAllocator,
    screen_width: u16,
    screen_height: u16,
    should_exit: bool,
    
    // UI Regions for mouse hit testing
    history_rect: Rect,
    vars_rect: Rect,
    input_rect: Rect,
};
```

**Responsibilities:**
- Initialize and manage libvaxis window
- Handle user input events (keyboard, mouse, paste)
- Render UI layout
- Coordinate with AppState for computation

#### AppState (`state.zig`)

Manages application state including:

```zig
pub const AppState = struct {
    allocator: std.mem.Allocator,
    math_context: *mathzig.MathZig,
    history: std.ArrayListUnmanaged(HistoryEntry),
    input_buffer: InputBuffer,
    cursor_position: usize,
    focus: FocusState,
    // Variable tracking
    vars_scroll_pos: usize,
    selected_var_index: usize,
    // Command mode
    command_mode: bool,
    command_buffer: []u8,
    // Help modal state
    show_help: bool,
};
```

**Key Features:**
- `InputBuffer`: Managed text input with cursor navigation
- `HistoryEntry`: Stores expression, result, and metadata
- `FocusState`: Tracks which pane has focus (history, vars, input)
- Variable sorting and filtering
- Command palette mode

#### Syntax Highlighting (`syntax.zig`)

Defines syntax highlighting rules for mathematical expressions:

```zig
pub const SyntaxTheme = struct {
    number: Style,
    operator: Style,
    function: Style,
    variable: Style,
    string: Style,
    comment: Style,
    keyword: Style,
};
```

## Layout

The TUI uses a three-pane split layout:

```
┌─ HISTORY ───────────────────┬─ VARS ────────────────────┐
│  2 + 3 * 4            14   │  x = 5                    5   │
│  (1 + 2) * (3 + 4)     21   │  y = x * 2                10  │
│  sin(pi/2)              1    │  pi                       3.141593│
│                           │  --- (constants separator) ---     │
│                           │  e                        2.718282│
├─────────────────────────────┼─────────────────────────────┤
│ INPUT > x^2 + 2*x + 1_                               │
└─────────────────────────────────────────────────────────────────┘
```

### Panes

1. **History Pane** (Left)
   - Expression history with results
   - Scrollable content
   - Selection support for variable insertion

2. **Variables Pane** (Right)
   - All variables (user-defined + constants)
   - Search/filter support
   - Selection for inspection

3. **Input Pane** (Bottom)
   - Command entry with syntax highlighting
   - Cursor navigation
   - Tab completion (planned)

## Event Handling

### Keyboard Shortcuts

#### Global Shortcuts

| Key | Action |
|-----|--------|
| `Tab` | Cycle focus (History → Input → Variables) |
| `F1` | Toggle help modal |
| `Ctrl+C` | Quit (double-tap) |
| `Ctrl+L` | Clear input |
| `/` | Open command palette |

#### Input Pane Shortcuts

| Key | Action |
|-----|--------|
| `Enter` | Evaluate expression |
| `Up/Down` | Navigate command history |
| `Left/Right` | Move cursor |
| `Ctrl+A` | Move to beginning |
| `Ctrl+E` | Move to end |
| `Ctrl+U` | Clear line before cursor |
| `Ctrl+K` | Clear line after cursor |
| `Esc` | Clear input / exit modes |

#### Variables Pane Shortcuts

| Key | Action |
|-----|--------|
| `Ctrl+F` | Toggle variable search |
| `Enter` | Inspect selected variable |
| `Up/Down` | Scroll variable list |
| `Esc` | Exit search / close inspector |

#### History Pane Shortcuts

| Key | Action |
|-----|--------|
| `Up/Down` | Navigate history entries |
| `Enter` | Recall expression to input |

#### Inspector Controls (hjkl navigation)

| Key | Action |
|-----|--------|
| `h` | Scroll left |
| `j` | Scroll down |
| `k` | Scroll up |
| `l` | Scroll right |
| `Esc` / `q` | Close inspector |

## Command Palette

Access commands by typing `/` in the input pane:

| Command | Description |
|---------|-------------|
| `/clear` | Clear command history |
| `/help` | Show help |
| `/quit` | Exit application |
| `/vars` | List all variables |
| `/clearvars` | Clear all user variables |
| `/pref <unit>` | Set preferred unit display |

## Variable Inspector

Press `Enter` on a selected variable to view detailed information:

- **Type**: Value type (Number, Matrix, Series, etc.)
- **Dimensions**: For matrices: `rows × cols`
- **Value**: Full value representation
- **Memory**: Allocation info (for complex types)

## Mouse Support

The TUI supports mouse interaction:

- **Click** on panes to focus
- **Click** on variables to select/inspect
- **Scroll** in panes (if terminal supports)
- **Paste** via mouse (automatic detection)

## Rendering

### Double-Buffering

The TUI uses a render arena for efficient screen updates:

```zig
render_arena: std.heap.ArenaAllocator,
```

Each frame:
1. Clear render arena
2. Calculate layout based on terminal size
3. Render all panes to buffer
4. Flush to terminal

### Dynamic Layout

Layout adapts to terminal size:

- Minimum: 80×24
- Dynamic pane sizing based on available width
- Automatic scrolling when content overflows

## Error Handling

Errors are displayed with:
- Red highlighting
- Error message in result column
- Error offset indicator (planned)

## Integration

### MathZig Context

The TUI creates and manages a MathZig instance:

```zig
math_context: *mathzig.MathZig,
```

All computations flow through this context.

### Cleanup

Proper resource cleanup on exit:

```zig
pub fn deinit(self: *MathZigWidget) void {
    self.render_arena.deinit();
    self.app_state.deinit();
    self.allocator.destroy(self);
}
```

## Related Documentation

- [Overview](../guides/overview.md)
- [Expression Evaluation](vm.md)
- [Bytecode Format](bytecode.md)
