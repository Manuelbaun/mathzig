# TUI Library Comparison: libvaxis vs TUI.zig

## Executive Summary

For mathzig's TUI implementation, **libvaxis is the recommended choice** for the following reasons:

1. **Maturity & Stability**: Used in production (Ghostty terminal emulator)
2. **Protocol Coverage**: Full escape sequence support including kitty extensions
3. **Performance**: Threaded input, diff-based rendering, sync protocol
4. **Control**: Low-level access when needed for customization
5. **Cross-Platform**: Proven POSIX and Windows support

TUI.zig could be considered for rapid prototyping or when widget richness is the primary concern, but its early stage and limited protocol support make it less suitable for a terminal-based math application.

---

## Detailed Comparison

### 1. Architecture & Design Philosophy

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Philosophy | Low-level, protocol-focused | High-level, widget-focused |
| Mode | Immediate-mode with diff | Retained-mode with layouts |
| State Management | Manual | Built-in widget state |
| Event Loop | Threaded (non-blocking) | Main thread (blocking potential) |
| Target Users | Terminal/Game developers | Application developers |

**libvaxis Design:**
- Focused on correct terminal protocol implementation
- Developer manages state and rendering
- Flexible but requires more code
- Optimized for performance

**TUI.zig Design:**
- Focus on developer productivity
- Automatic layout and state management
- Composition-based widgets
- Rapid UI building

### 2. Rendering Pipeline

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Diff-based | Yes | Yes |
| Output Buffering | Yes (IoWriter) | Yes (ArrayList) |
| Style Diffing | Per-cell | Per-cell |
| Cursor Tracking | Yes | Yes |
| Sync Protocol | DECSCUSR | No |
| Batch Writes | Yes | Yes |

**libvaxis Rendering:**
```
render() → compare cells → emit only changes → buffered write
- Sync protocol prevents tearing
- Skip cells for wide characters
- Optimized cursor movement
- Kitty graphics support
```

**TUI.zig Rendering:**
```
render() → layout widgets → draw to buffer → diff → emit
- Full frame diff
- Sub-screen regions for clipping
- Drawing primitives built-in
- No sync protocol
```

### 3. Event Handling

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Threaded Input | Yes | No |
| Event Queue | 512 capacity | 256 capacity |
| Signal Handler | SIGWINCH + custom | Basic |
| Paste Support | Bracketed paste | Basic |
| Focus Events | Yes | Yes |
| Mouse | Pixel + cell | Cell-based |
| Keyboard | Full modifier support | Basic support |

**libvaxis Input:**
- Separate thread reads from TTY
- Non-blocking input processing
- Futex-based synchronization
- Grapheme cache for text

**TUI.zig Input:**
- Polling-based on main thread
- Potential for input latency
- Simpler architecture
- Less overhead

### 4. Widget System

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Built-in Widgets | 7 | 30+ |
| Widget Type | Trait-based | Trait-based |
| Composition | Manual | Built-in |
| Layout Engine | None (manual) | Flex/Grid/Box |
| Themes | No | Yes |
| Animation | No | Yes |

**libvaxis Widgets:**
- View (base widget)
- TextView
- TextInput
- Table
- ScrollView
- Scrollbar
- CodeView

**TUI.zig Widgets:**
- Basic: Text, Button, InputField, Checkbox, Radio, Switch, Slider
- Containers: FlexColumn, FlexRow, Grid, ScrollView, Card
- Complex: ListView, Table, TreeView, Tabs, Sidebar, Navbar
- Feedback: ProgressBar, Spinner, Skeleton
- Overlays: Modal, Toast, Tooltip, Alert
- Decorations: Border, Accordion, Badge, Pagination

### 5. Terminal Protocol Support

| Feature | libvaxis | TUI.zig |
|---------|----------|---------|
| ANSI Colors | Yes | Yes |
| 256 Colors | Yes | Yes |
| True Color | Yes | Yes |
| Bold/Dim | Yes | Yes |
| Italic | Yes | Yes |
| Underline | Yes | Yes |
| Strikethrough | Yes | Yes |
| Reverse | Yes | Yes |
| Blink | Yes | Yes |
| Underline Color | Yes | No |
| SGR Mouse | Yes | Yes |
| Pixel Mouse | Yes | No |
| Focus Events | Yes | Yes |
| Bracketed Paste | Yes | Yes |
| Kitty Keyboard | Yes | No |
| Kitty Graphics | Yes | No |
| Scaled Text | Yes | No |
| Hyperlinks (OSC8) | Yes | No |
| Synchronized | Yes | No |
| Terminal Title | Yes | No |
| Color Scheme | Yes | No |

### 6. Unicode Handling

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Grapheme Clusters | Yes | Limited |
| Width Methods | 3 (wcwidth, unicode, configured) | 1 (codepoint) |
| Word Wrapping | Yes | No |
| Custom Width | Yes | No |
| Terminal Query | Yes | No |

### 7. Platform Support

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Linux | Yes | Yes |
| macOS | Yes | Yes |
| Windows | ConPTY | ConPTY |
| Signal Handling | Yes | Basic |
| Raw Mode | termios | termios |
| Tests | Yes | Yes |

### 8. Performance Characteristics

| Aspect | libvaxis | TUI.zig |
|--------|----------|---------|
| Input Blocking | None (threaded) | Possible |
| Render Efficiency | High (diff) | High (diff) |
| Memory | Cell-based | Cell + widget state |
| Allocation | Minimal | More (widgets) |
| FPS Control | Manual | Built-in |
| Sync Protocol | Yes | No |

### 9. Code Complexity

**libvaxis:**
- ~5000 lines core
- Lower-level API
- More boilerplate for UIs
- Requires understanding protocols

**TUI.zig:**
- ~9000 lines core
- Higher-level API
- Less boilerplate
- Opinionated layouts

---

## Mathzig TUI Requirements Analysis

### Required Features for Mathzig

1. **Display**: Math equations, matrices, graphs
2. **Input**: Keyboard navigation, special characters
3. **Layout**: Resizable panels, split views
4. **Performance**: Smooth scrolling, responsive input
5. **Unicode**: Mathematical symbols, Greek letters
6. **Styling**: Syntax highlighting for code/math
7. **Mouse**: Selection, scrolling, tooltips

### Feature-to-Library Mapping

| Requirement | libvaxis | TUI.zig |
|-------------|----------|---------|
| Math rendering | Use raw cells | Use Text widgets |
| Matrix display | Window.print | Grid widget |
| Graph plots | Custom drawing | Image widget |
| Keyboard nav | Manual | Built-in focus |
| Scroll panels | Scroll() method | ScrollView |
| Syntax highlight | Manual style | Theme system |
| Symbol palette | Custom widget | Compose widgets |

---

## Recommendation

### Use libvaxis for mathzig because:

1. **Performance Matters**: Mathzig may need:
   - Fast rendering for graph updates
   - Responsive input for navigation
   - Efficient diffing for large displays

2. **Protocol Extensions**: Future enhancements:
   - Kitty graphics for plots/images
   - Hyperlinks for formula references
   - Scaled text for inline math

3. **Control**: Custom rendering needs:
   - Direct cell manipulation
   - Custom escape sequences
   - Protocol-level optimizations

4. **Stability**: Production quality:
   - Battle-tested in Ghostty
   - Comprehensive test coverage
   - Active maintenance

### Hybrid Approach (If Needed)

For rapid prototyping, consider:

```zig
// Phase 1: Use TUI.zig for quick UI
// Phase 2: Migrate to libvaxis for production
```

Or build a wrapper:

```zig
// Common interface
const Tui = if (use_libvaxis) @import("libvaxis_compat") else @import("tui_compat");
```

### Widget Architecture on libvaxis

Even with libvaxis, build high-level widgets:

```zig
const std = @import("std");
const vaxis = @import("libvaxis");

// Math display widget
pub const MathDisplay = struct {
    window: vaxis.Window,
    equation: []const u8,
    
    pub fn render(self: *MathDisplay) void {
        // Render math equation to window
        // Handle scroll, selection, etc.
    }
};

// Split panel layout
pub const SplitPanel = struct {
    left: vaxis.Window,
    right: vaxis.Window,
    split_ratio: f32,
    
    pub fn resize(self: *SplitPanel, winsize: vaxis.Winsize) void {
        // Calculate split position
        // Create child windows
    }
};
```

---

## Migration Considerations

### From TUI.zig to libvaxis

**TUI.zig Code:**
```zig
var app = try tui.App.init(.{});
try app.setRoot(
    tui.FlexColumn(.{
        tui.Text("Hello"),
        tui.Button("Click", onClick),
    })
);
```

**Equivalent libvaxis:**
```zig
var loop = try vaxis.Loop(Event).init();
try loop.start();
try vx.enterAltScreen(tty.writer());

const win = vx.window();
const child = win.child(.{ .width = 20, .height = 10 });
child.writeCell(0, 0, .{ .char = .{ .grapheme = "Hello" } });
// Manual button handling required
```

### Key Differences

| TUI.zig | libvaxis |
|---------|----------|
| `app.setRoot(widget)` | `vx.window()` + manual |
| `ctx.screen.putStringAt()` | `win.print()` |
| `Widget.render()` | `window.writeCell()` |
| `event_queue.pop()` | `loop.nextEvent()` |
| `requestRedraw()` | `vx.queueRefresh()` |

---

## Conclusion

**libvaxis** provides the foundation for a robust, performant TUI application. While it requires more code for UI construction, it offers:

- Superior performance through threading
- Complete terminal protocol support
- Production-grade stability
- Flexibility for custom rendering

For mathzig's TUI, combine libvaxis with a custom widget layer that provides:
- Layout management (split panels, grids)
- Text formatting (math syntax highlighting)
- Component library (buttons, inputs, panels)

This approach gives the performance and control of libvaxis while maintaining developer productivity through reusable widget abstractions.
