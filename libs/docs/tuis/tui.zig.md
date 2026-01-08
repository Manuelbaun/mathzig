# TUI.zig Analysis

## Overview

TUI.zig is a high-level, widget-rich TUI framework for Zig focusing on developer productivity. It provides a comprehensive widget system with retained-mode rendering, layout engines, and theming support. It's designed for building complex terminal applications quickly.

## Architecture

### Core Modules

1. **App** (`app.zig`) - Application runner and main loop
   - Event loop with FPS control
   - Root widget management
   - Event queue processing
   - Animation system integration

2. **Terminal** (`core/terminal.zig`) - Terminal control
   - Raw mode management
   - Escape sequence constants
   - Capability queries

3. **Screen** (`core/screen.zig`) - Screen buffer
   - Cell grid with read/write access
   - Sub-screen regions for clipping
   - Drawing primitives (lines, boxes, fills)

4. **Renderer** (`core/renderer.zig`) - Rendering engine
   - Diff-based rendering
   - Full render mode option
   - Render statistics

5. **Event System** (`event/`) - Input handling
   - Event queue for buffered processing
   - Input parsing and key mapping
   - Mouse event support

6. **Layout Engine** (`layout/`) - Widget positioning
   - Flex layouts (row/column)
   - Box model constraints
   - Rectangular regions

7. **Widget System** (`widgets/`) - 30+ built-in widgets
   - Text, Button, InputField
   - List, Table, TreeView
   - Modal, Tabs, ScrollView
   - And many more...

8. **Styling** (`style/`) - Visual theming
   - Colors (ANSI, 256, RGB)
   - Style merging and diffing
   - Theme system with defaults

## Rendering Architecture

### Retained-Mode Rendering

TUI.zig uses retained-mode UI with diff-based updates:

```
┌─────────────────┐
│   Root Widget   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Layout Phase  │  ← Calculate widget bounds
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Render Phase   │  ← Draw widgets to screen buffer
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    Diff Phase   │  ← Compare with previous frame
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Output Phase  │  ← Write ANSI sequences to terminal
└─────────────────┘
```

### Screen Buffer

```zig
pub const Screen = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,           // Row-major grid
    width: u16,
    height: u16,
    cursor_x: u16,
    cursor_y: u16,
    current_style: Style,
};
```

### Diff-Based Renderer

```zig
pub const Renderer = struct {
    prev_buffer: ?Screen,    // Previous frame for comparison
    output_buffer: std.ArrayListUnmanaged(u8),
    current_style: Style,
    last_x: u16,
    last_y: u16,
    cells_drawn: usize,
    cells_skipped: usize,
};
```

## Widget System

### Base Widget Trait

```zig
pub fn Widget(comptime T: type) type {
    return struct {
        ptr: *T,
        // render(ctx: *RenderContext) void
        // handleEvent(event: Event) EventResult
        // sizeHint() SizeHint
        // layout_widget(bounds: Rect) void
        // isFocusable() bool
        // setFocus(focused: bool) void
    };
}
```

### StatefulWidget

```zig
pub const StatefulWidget = struct {
    id: WidgetId,
    state: WidgetState,      // focused, hovered, pressed, disabled, visible, dirty
    bounds: Rect,
    user_data: ?*anyopaque,
};
```

### WidgetState Flags

```zig
pub const WidgetState = packed struct {
    focused: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
    visible: bool,
    dirty: bool,
};
```

### Available Widgets (30+)

**Basic:**
- Text - Static text display
- Button - Clickable button with label
- InputField - Single-line text input
- TextArea - Multi-line text editing
- Checkbox - Boolean checkbox
- Radio - Radio button group
- Switch - Toggle switch
- Slider - Numeric slider

**Containers:**
- FlexColumn - Vertical flex layout
- FlexRow - Horizontal flex layout
- Grid - Grid layout
- ScrollView - Scrollable container
- Container - Basic container
- SizedBox - Fixed-size container
- Center - Center alignment
- Padding - Padding wrapper
- Margin - Margin wrapper

**Complex:**
- ListView - Scrollable list
- Table - Tabular data
- TreeView - Hierarchical data
- Tabs - Tabbed interface
- Sidebar - Navigation sidebar
- Navbar - Top navigation
- Statusbar - Bottom status
- Menu - Dropdown menu

**Decorations:**
- Border - Border container
- Card - Card-style container
- Accordion - Collapsible sections
- Alert - Alert messages
- Modal - Modal dialogs
- Toast - Toast notifications
- Tooltip - Hover tooltips

**Feedback:**
- ProgressBar - Progress indicator
- Spinner - Loading spinner
- Skeleton - Loading placeholder

**Other:**
- Image - Image display
- Separator - Horizontal/vertical separator
- Breadcrumb - Navigation breadcrumb
- Pagination - Page navigation
- Badge - Label badge
- Pagination - Page controls

## Layout System

### Flex Layout

```zig
pub const FlexColumn = struct {
    children: []const anytype,
    gap: u16 = 0,
    main_axis_alignment: Alignment = .start,
    cross_axis_alignment: Alignment = .stretch,
    // ...
};

pub const FlexRow = struct {
    children: []const anytype,
    gap: u16 = 0,
    // ...
};
```

### Box Model

```zig
pub const Box = struct {
    content: Rect,
    padding: Rect,
    border: Rect,
    margin: Rect,
};
```

### Rect Type

```zig
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};
```

## Style System

### Style Definition

```zig
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attributes = .{},
    
    pub const Attributes = packed struct {
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        underline: bool = false,
        blink: bool = false,
        reverse: bool = false,
        hidden: bool = false,
        strikethrough: bool = false,
        double_underline: bool = false,
        curly_underline: bool = false,
        dotted_underline: bool = false,
        dashed_underline: bool = false,
        overline: bool = false,
    };
};
```

### Color System

```zig
pub const Color = union(enum) {
    default,
    basic: BasicColor,       // 8 basic colors
    palette: u8,             // 256 color palette
    truecolor: [3]u8,        // 24-bit RGB
    hex: u32,                // Hex color
};
```

### Border Styles

```zig
pub const BorderStyle = enum {
    none,
    single,
    double,
    rounded,
    thick,
    dashed,
    dotted,
    ascii,
};
```

### Theme System

```zig
pub const Theme = struct {
    name: []const u8,
    primary: Color,
    background: Color,
    foreground: Color,
    // ... extensive color palette
};
```

## Event System

### Event Types

```zig
pub const Event = union(enum) {
    key: KeyEvent,
    mouse: MouseEvent,
    resize: ResizeEvent,
    focus: FocusEvent,
    custom: T,  // User-defined
};
```

### Key Events

```zig
pub const KeyEvent = struct {
    key: Key,              // Character or special key
    modifiers: Modifiers,  // ctrl, alt, shift
    text: ?[]const u8,     // Raw text for simple keys
};
```

### Mouse Events

```zig
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: MouseButton,
    modifiers: Modifiers,
    is_drag: bool,
};
```

## Animation System

```zig
pub const Animation = struct {
    start_time: i128,
    duration: i128,
    easing: EasingFunction,
    on_frame: fn(state: *anyopaque, progress: f32) void,
};

pub const FpsCounter = struct {
    frame_count: u64,
    last_time_ns: i128,
    current_fps: f32,
};
```

## Application Lifecycle

```zig
pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    term: ?Terminal,
    screen: ?Screen,
    renderer: ?Renderer,
    state: AppState,        // uninitialized, running, paused, stopping, stopped
    root: ?*anyopaque,      // Type-erased root widget
    event_queue: EventQueue,
    needs_redraw: bool,
    should_quit: bool,
};
```

### App States

```zig
pub const AppState = enum {
    uninitialized,
    running,
    paused,
    stopping,
    stopped,
};
```

### Configuration

```zig
pub const AppConfig = struct {
    theme: Theme = Theme.default_theme,
    alternate_screen: bool = true,
    hide_cursor: bool = true,
    enable_mouse: bool = true,
    enable_paste: bool = true,
    enable_focus: bool = true,
    target_fps: u16 = 60,
    tick_rate_ms: u16 = 16,
    poll_timeout_ms: u16 = 10,
};
```

## Platform Support

### POSIX

- Raw mode via `termios`
- Signal handling for resize
- Non-blocking I/O

### Windows

- ConPTY support
- Console API integration

## Strengths

1. **Widget-Rich**: 30+ built-in widgets for rapid development
2. **Layout Engine**: Flexbox-like layout system
3. **Theme System**: Built-in theming with customization
4. **Retained Mode**: Efficient diff-based rendering
5. **Animation Support**: Frame-based animation system
6. **Developer Experience**: Comptime widget composition
7. **Focus Management**: Built-in keyboard navigation
8. **Comprehensive Styling**: Colors, attributes, borders, themes

## Weaknesses

1. **Less Mature**: Newer library, less battle-tested
2. **No Terminal Detection**: No dynamic capability queries
3. **Minimal Protocol Support**: Basic escape sequences only
4. **No Threaded Input**: Input on main thread could block
5. **No Kitty Protocol**: No graphics/keyboard extensions
6. **Higher-Level**: Less control over terminal output
7. **Unicode Complexity**: Uses codepoint-based width

## File Structure

```
tui.zig/
├── src/
│   ├── tui.zig              # Main entry point / re-exports
│   ├── app.zig              # Application runner
│   ├── core/
│   │   ├── terminal.zig     # Terminal control
│   │   ├── screen.zig       # Screen buffer
│   │   ├── cell.zig         # Cell representation
│   │   └── renderer.zig     # Rendering engine
│   ├── event/
│   │   ├── events.zig       # Event types
│   │   └── input.zig        # Input parsing
│   ├── layout/
│   │   ├── layout.zig       # Layout system
│   │   ├── box.zig          # Box model
│   │   └── flex.zig         # Flex layouts
│   ├── widgets/
│   │   ├── widget.zig       # Base widget trait
│   │   ├── text.zig
│   │   ├── button.zig
│   │   ├── input_field.zig
│   │   ├── list_view.zig
│   │   ├── table.zig
│   │   ├── scroll_view.zig
│   │   ├── tabs.zig
│   │   ├── modal.zig
│   │   └── ... (30+ more)
│   ├── style/
│   │   ├── style.zig        # Style definitions
│   │   ├── color.zig        # Color system
│   │   └── theme.zig        # Theme system
│   ├── unicode/
│   │   ├── unicode.zig      # Unicode utilities
│   │   └── width.zig        # Display width
│   ├── animation/
│   │   └── animation.zig    # Animation system
│   └── platform/
│       └── platform.zig     # Platform abstraction
├── examples/
├── build.zig
└── README.md
```

## Dependencies

- Standard library only
- No external dependencies

## Version

0.1.0 (early stage)

## Comparison Summary

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Maturity | Production-ready (Ghostty) | Early stage |
| Widgets | Minimal (7) | 30+ |
| Layout | Manual | Flex/Grid |
| Rendering | Diff-based | Diff-based |
| Animation | Manual | Built-in |
| Theming | No | Yes |
| Threads | Yes (input) | No |
| Protocol | Full CSI/OSC/DCS | Basic |
| Kitty Graphics | Yes | No |
| Terminal Detection | Yes | No |
| Focus | Manual | Built-in |
| License | MIT | ?
