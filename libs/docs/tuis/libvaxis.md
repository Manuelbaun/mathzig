# libvaxis Analysis

## Overview

libvaxis is a mature, battle-tested TUI library for Zig that has been used in production (e.g., Ghostty terminal emulator). It focuses on low-level terminal control with comprehensive escape sequence support and proper event handling.

## Architecture

### Core Components

1. **Vaxis** (`Vaxis.zig`) - Main entry point and rendering orchestrator
   - Manages screen buffer and last frame for diff-based rendering
   - Handles terminal capability detection via DA1 queries
   - Coordinates output to TTY

2. **Screen** (`Screen.zig`) - Screen buffer management
   - Linear cell array (row-major order)
   - Stores cursor position and visibility
   - Tracks mouse and cursor shapes

3. **Window** (`Window.zig`) - Viewport/region management
   - Creates sub-regions with clipping
   - Handles borders and child windows
   - Text printing with word/grapheme wrapping

4. **Loop** (`Loop.zig`) - Event loop with threading
   - Separate input thread for non-blocking I/O
   - Lock-free event queue (512 capacity)
   - Signal handler for SIGWINCH

5. **Tty** (`tty.zig`) - Terminal I/O abstraction
   - Raw mode management
   - Cross-platform (POSIX/Windows)
   - Buffered writing for performance

6. **Parser** (`Parser.zig`) - Escape sequence parser
   - State machine-based (ground, escape, csi, osc, etc.)
   - Handles mouse, keyboard, focus events
   - Grapheme caching for text

### Cell Representation

```zig
pub const Cell = struct {
    char: Character = .{},    // grapheme + width
    style: Style = .{},       // colors + attributes
    link: Hyperlink = .{},    // OSC8 hyperlinks
    image: ?Image.Placement = null,
    default: bool = false,    // clear cell
    wrapped: bool = false,    // line wrap marker
    scale: Scale = .{},       // kitty scaled text
};
```

### Style System

```zig
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,           // underline color
    ul_style: Underline = .off,     // single/double/curly/dotted/dashed
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};
```

## Rendering Pipeline

### Diff-Based Rendering

1. **Previous Frame Storage**: Maintains `screen_last` for comparison
2. **Cell-by-Cell Comparison**: Only writes changed cells
3. **Style Diffing**: Optimizes ANSI escape sequences
4. **Cursor Tracking**: Minimizes cursor movement sequences
5. **Synchronized Output**: Uses DECSCUSR (Sync) protocol

### Rendering Steps

```zig
pub fn render(self: *Vaxis, tty: *IoWriter) !void {
    // 1. Check if refresh needed (full redraw flag)
    // 2. Compare each cell with previous frame
    // 3. Only output changed cells with minimal sequences
    // 4. Use DCS for kitty graphics
    // 5. Position cursor at end
}
```

### Optimization Techniques

- **Skip Cells**: Wide character continuation cells marked as skipped
- **Style Caching**: Only emit SGR codes when style changes
- **Cursor Optimization**: Relative movement when possible
- **Batch Writing**: All output buffered before flush
- **Sync Protocol**: DECSCUSR prevents screen tearing

## Event Handling

### Threaded Input Model

```
Main Thread          Input Thread
    |                    |
    |  request event     |
    |<-------------------|
    |                    |
    |  read from TTY     |
    |------------------->|
    |  parse events      |
    |<-------------------|
```

### Event Types

- `key_press` / `key_release` - Keyboard events with modifiers
- `mouse` - Position, buttons, wheel, pixel coordinates
- `focus_in` / `focus_out` - Terminal focus events
- `paste_start` / `paste_end` - Bracketed paste markers
- `winsize` - Terminal resize
- `color_report` / `color_scheme` - Color capability responses

### Capability Detection

libvaxis queries the terminal at startup to detect:
- RGB color support
- Kitty keyboard protocol
- Kitty graphics protocol
- Unicode width methods
- SGR pixel mouse
- Color scheme updates
- Explicit width / scaled text

## Unicode Handling

### Grapheme Clusters

libvaxis uses `gwidth.zig` for display width calculation with three methods:
- **wcwidth**: Traditional fixed-width based on codepoint
- **unicode**: Terminal-reported width (via DA1 query)
- **configured**: User-specified method

### Text Wrapping

Window provides two wrapping modes:
- **grapheme**: Wrap at grapheme boundaries
- **word**: Wrap at word boundaries, avoiding breaking words

## Platform Support

### POSIX

- Raw mode via `termios`
- Signal handler for SIGWINCH
- `/dev/tty` for direct terminal access

### Windows

- ConPTY support
- Console mode management
- Unicode input handling

## Widget System

libvaxis has a minimal widget system (`widgets/`):
- **View** - Base widget trait
- **TextView** - Scrollable text display
- **TextInput** - Editable text input
- **Table** - Tabular data display
- **ScrollView** - Scrollable container
- **Scrollbar** - Scroll indicator
- **CodeView** - Code with line numbers
- **LineNumbers** - Line number gutter

The widget system is composition-based rather than retained-mode.

## Strengths

1. **Mature & Battle-Tested**: Used in Ghostty terminal emulator
2. **Comprehensive Protocol Support**: ESC, CSI, OSC, DCS sequences
3. **Thread-Safe**: Separate input thread prevents blocking
4. **Terminal Detection**: Dynamic capability queries
5. **Performance**: Diff-based rendering with sync protocol
6. **Cross-Platform**: POSIX + Windows ConPTY support
7. **Kitty Protocol**: Full support for graphics and keyboard extensions
8. **Low-Level Control**: Direct escape sequence access

## Weaknesses

1. **Minimal Widgets**: Limited built-in widget collection
2. **No Layout System**: Manual window positioning required
3. **Manual State Management**: No retained-mode widget state
4. **Complex API**: Lower-level than high-level TUI frameworks
5. **No Animation System**: Requires manual frame management
6. **No Theme System**: Styles defined inline

## Dependencies

- `zigimg` - Image loading for kitty graphics transmission
- Standard library only for most functionality

## File Structure

```
libvaxis/
├── src/
│   ├── Vaxis.zig          # Main API
│   ├── Screen.zig         # Screen buffer
│   ├── Window.zig         # Viewport/windowing
│   ├── Loop.zig           # Event loop
│   ├── Tty.zig            # Terminal I/O
│   ├── Parser.zig         # Escape sequence parser
│   ├── Cell.zig           # Cell/Style definitions
│   ├── Key.zig            # Key codes
│   ├── Mouse.zig          # Mouse events
│   ├── Image.zig          # Image handling
│   ├── ctlseqs.zig        # Control sequences constants
│   ├── gwidth.zig         # Unicode width
│   ├── tty.zig            # TTY abstraction
│   ├── unicode.zig        # Unicode utilities
│   ├── widgets/           # Widgets
│   └── vxfw/              # Framework utilities
├── examples/              # Example applications
├── build.zig
└── README.md
```

## License

MIT
