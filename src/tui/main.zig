// Math TUI - Main Entry Point using libvaxis
// Terminal User Interface for MathZig

const std = @import("std");
const libvaxis = @import("libvaxis");
const state = @import("state.zig");
const syntax = @import("syntax.zig");
const mathzig = @import("mathzig");

const Event = libvaxis.Event;

const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    fn contains(self: Rect, col: u16, row: u16) bool {
        return col >= self.x and col < self.x + self.w and
               row >= self.y and row < self.y + self.h;
    }
};

pub const MathZigWidget = struct {
    allocator: std.mem.Allocator,
    app_state: state.AppState,
    render_arena: std.heap.ArenaAllocator,
    screen_width: u16 = 80,
    screen_height: u16 = 24,
    should_exit: bool = false,
    
    // UI Regions for mouse hit testing
    history_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    vars_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    input_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(allocator: std.mem.Allocator) !*MathZigWidget {
        const self = try allocator.create(MathZigWidget);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .app_state = try state.AppState.init(allocator),
            .render_arena = std.heap.ArenaAllocator.init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *MathZigWidget) void {
        self.render_arena.deinit();
        self.app_state.deinit();
        self.allocator.destroy(self);
    }

    pub fn handleEvent(self: *MathZigWidget, event: Event) void {
        switch (event) {
            .key_press => |key| {
                self.handleKey(key);
            },
            .key_release => {
                // Ignore key releases for now
            },
            .mouse => |mouse| {
                self.handleMouse(mouse);
            },
            .paste => |text| {
                defer self.allocator.free(text);
                self.app_state.input_buffer.insertSlice(self.allocator, self.app_state.cursor_position, text) catch {};
                self.app_state.cursor_position += text.len;
                _ = self.app_state.checkCommandMode();
            },
            .mouse_leave, .focus_in, .focus_out, .paste_start, .paste_end, .color_report, .color_scheme, .cap_kitty_keyboard, .cap_kitty_graphics, .cap_rgb, .cap_sgr_pixels, .cap_unicode, .cap_da1, .cap_color_scheme_updates, .cap_multi_cursor, .winsize => {
                // Ignore other events for now
            },
        }
    }

    fn handleMouse(self: *MathZigWidget, mouse: libvaxis.Mouse) void {
        if (mouse.col < 0 or mouse.row < 0) return;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);

        if (mouse.button == .left and mouse.type == .press) {
            if (self.input_rect.contains(col, row)) {
                self.app_state.focus = .input;
            } else if (self.history_rect.contains(col, row)) {
                self.app_state.focus = .history;
            } else if (self.vars_rect.contains(col, row)) {
                self.app_state.focus = .vars;
                
                // Variable selection
                if (row >= self.vars_rect.y + 2) {
                    const list_idx = row - self.vars_rect.y - 2;
                    const vars_idx = self.app_state.vars_scroll_pos + list_idx;
                    
                    const sorted = self.app_state.getSortedVars(self.allocator) catch return;
                    defer self.allocator.free(sorted);
                    
                    var ui_idx: usize = 0;
                    var found_sep = false;
                    for (sorted) |item| {
                         if (!found_sep and item.variable.is_constant) {
                            if (ui_idx == vars_idx) return; // Clicked separator
                            ui_idx += 1;
                            found_sep = true;
                        }
                        if (ui_idx == vars_idx) {
                            if (self.app_state.selected_var) |v| self.allocator.free(v);
                            self.app_state.selected_var = self.allocator.dupe(u8, item.name) catch return;
                            self.app_state.mode = .inspecting;
                            return;
                        }
                        ui_idx += 1;
                    }
                }
            }
        } else if (mouse.button == .wheel_up) {
             if (self.app_state.mode == .inspecting) {
                 if (self.app_state.inspector_scroll_y > 0) self.app_state.inspector_scroll_y -= 1;
             } else if (self.vars_rect.contains(col, row)) {
                 if (self.app_state.vars_scroll_pos > 0) self.app_state.vars_scroll_pos -= 1;
             } else if (self.history_rect.contains(col, row)) {
                 if (self.app_state.navigateHistoryPrev()) |cmd| {
                     self.app_state.setInputValue(cmd, cmd.len) catch {};
                 }
             }
        } else if (mouse.button == .wheel_down) {
             if (self.app_state.mode == .inspecting) {
                 self.app_state.inspector_scroll_y += 1;
             } else if (self.vars_rect.contains(col, row)) {
                 // Approximate check for end of list
                 if (self.app_state.vars_scroll_pos + 1 < self.app_state.variables.count() + 1) { 
                     self.app_state.vars_scroll_pos += 1;
                 }
             } else if (self.history_rect.contains(col, row)) {
                 if (self.app_state.navigateHistoryNext()) |cmd| {
                     self.app_state.setInputValue(cmd, cmd.len) catch {};
                 } else {
                     self.app_state.clearInput();
                 }
             }
        }
    }

    fn handleKey(self: *MathZigWidget, key: libvaxis.Key) void {
        // Double Ctrl+C to exit
        if (key.codepoint == 'c' and key.mods.ctrl) {
            if (self.app_state.input_buffer.items.len == 0) {
                self.should_exit = true;
            } else {
                self.app_state.clearInput();
                self.app_state.history.append(self.allocator, .{
                    .command = self.allocator.dupe(u8, "^C") catch return,
                    .result = self.allocator.dupe(u8, "Interrupted") catch return,
                    .timestamp = std.time.nanoTimestamp(),
                    .is_error = true,
                }) catch {};
            }
            return;
        }

        // Ctrl+D to show quit hint
        if (key.codepoint == 'd' and key.mods.ctrl) {
            self.app_state.clearInput();
            self.app_state.history.append(self.allocator, .{
                .command = self.allocator.dupe(u8, "^D") catch return,
                .result = self.allocator.dupe(u8, "Use /quit or Ctrl+C to exit") catch return,
                .timestamp = std.time.nanoTimestamp(),
                .is_error = true,
            }) catch {};
            return;
        }

        // Ctrl+L to clear input
        if (key.codepoint == 'l' and key.mods.ctrl) {
            self.app_state.clearInput();
            return;
        }

        switch (self.app_state.mode) {
            .command => self.handleCommandKey(key),
            .normal => self.handleNormalKey(key),
            .inspecting => self.handleInspectKey(key),
        }
    }

    fn handleNormalKey(self: *MathZigWidget, key: libvaxis.Key) void {
        // Ctrl+f to search variables
        if (key.codepoint == 'f' and key.mods.ctrl) {
            self.app_state.focus = .vars;
            self.app_state.is_searching_vars = !self.app_state.is_searching_vars;
            if (!self.app_state.is_searching_vars) {
                self.app_state.vars_search_query.clearRetainingCapacity();
            }
            return;
        }

        switch (key.codepoint) {
            libvaxis.Key.escape => {
                if (self.app_state.show_help) {
                    self.app_state.show_help = false;
                    return;
                }
                if (self.app_state.is_searching_vars) {
                    self.app_state.is_searching_vars = false;
                    self.app_state.vars_search_query.clearRetainingCapacity();
                } else {
                    self.app_state.clearInput();
                }
            },
            libvaxis.Key.enter => {
                if (self.app_state.focus == .vars) {
                    const sorted = self.app_state.getSortedVars(self.allocator) catch return;
                    defer self.allocator.free(sorted);
                    
                    // We need to account for the separator in the UI
                    var ui_idx: usize = 0;
                    var found_sep = false;
                    for (sorted, 0..) |item, i| {
                        if (!found_sep and item.variable.is_constant) {
                            if (ui_idx == self.app_state.vars_scroll_pos) return; // Selected separator
                            ui_idx += 1;
                            found_sep = true;
                        }
                        if (ui_idx == self.app_state.vars_scroll_pos) {
                            if (self.app_state.selected_var) |v| self.allocator.free(v);
                            self.app_state.selected_var = self.allocator.dupe(u8, item.name) catch return;
                            self.app_state.mode = .inspecting;
                            return;
                        }
                        ui_idx += 1;
                        _ = i;
                    }
                    return;
                }
                const input = self.app_state.input_buffer.items;
                if (input.len > 0) {
                    // Evaluate the expression
                    const result = self.app_state.evaluate(input);
                    const cmd = self.app_state.allocator.dupe(u8, input) catch {
                        self.app_state.allocator.free(result.result_str);
                        return;
                    };
                    
                    self.app_state.history.append(self.allocator, .{
                        .command = cmd,
                        .result = result.result_str,
                        .timestamp = std.time.nanoTimestamp(),
                        .is_error = !result.success,
                    }) catch {
                        self.app_state.allocator.free(cmd);
                        self.app_state.allocator.free(result.result_str);
                    };
                    self.app_state.syncVariables();
                    self.app_state.clearInput();
                }
            },
            libvaxis.Key.tab => {
                // Cycle focus: input -> history -> vars -> input
                self.app_state.focus = switch (self.app_state.focus) {
                    .input => .history,
                    .history => .vars,
                    .vars => .input,
                };
            },
            libvaxis.Key.up, 'k' => {
                if (self.app_state.focus == .history) {
                    if (self.app_state.navigateHistoryPrev()) |cmd| {
                        self.app_state.setInputValue(cmd, cmd.len) catch {};
                    }
                } else if (self.app_state.focus == .input) {
                    if (self.app_state.navigateHistoryPrev()) |cmd| {
                        self.app_state.setInputValue(cmd, cmd.len) catch {};
                    }
                } else if (self.app_state.focus == .vars) {
                    if (self.app_state.vars_scroll_pos > 0) {
                        self.app_state.vars_scroll_pos -= 1;
                    }
                }
            },
            libvaxis.Key.down, 'j' => {
                if (self.app_state.focus == .history) {
                    if (self.app_state.navigateHistoryNext()) |cmd| {
                        self.app_state.setInputValue(cmd, cmd.len) catch {};
                    }
                } else if (self.app_state.focus == .input) {
                    if (self.app_state.navigateHistoryNext()) |cmd| {
                        self.app_state.setInputValue(cmd, cmd.len) catch {};
                    } else {
                        self.app_state.clearInput();
                    }
                } else if (self.app_state.focus == .vars) {
                    if (self.app_state.vars_scroll_pos + 1 < self.app_state.variables.count() + 1) {
                        self.app_state.vars_scroll_pos += 1;
                    }
                }
            },
            libvaxis.Key.left, 'h' => {
                self.app_state.moveCursorLeft();
            },
            libvaxis.Key.right, 'l' => {
                self.app_state.moveCursorRight();
            },
            libvaxis.Key.backspace => {
                if (self.app_state.focus == .vars and self.app_state.is_searching_vars) {
                    if (self.app_state.vars_search_query.items.len > 0) {
                        _ = self.app_state.vars_search_query.pop();
                        self.app_state.vars_scroll_pos = 0;
                    }
                } else {
                    self.app_state.deleteChar();
                    _ = self.app_state.checkCommandMode();
                }
            },
            libvaxis.Key.delete => {
                self.app_state.deleteCharForward();
                _ = self.app_state.checkCommandMode();
            },
            libvaxis.Key.home => {
                self.app_state.moveCursorToStart();
            },
            libvaxis.Key.f1 => {
                self.app_state.show_help = !self.app_state.show_help;
            },
            else => {
                // Handle printable characters
                if (self.app_state.focus == .input) {
                    if (key.codepoint >= 32 and key.codepoint < 127) {
                        self.app_state.insertChar(key.codepoint);
                        _ = self.app_state.checkCommandMode();
                    }
                } else if (self.app_state.focus == .vars and self.app_state.is_searching_vars) {
                    if (key.codepoint >= 32 and key.codepoint < 127) {
                        self.app_state.vars_search_query.append(self.allocator, @intCast(key.codepoint)) catch {};
                        self.app_state.vars_scroll_pos = 0;
                    }
                }
            },
        }
    }

    fn handleCommandKey(self: *MathZigWidget, key: libvaxis.Key) void {
        switch (key.codepoint) {
            libvaxis.Key.escape => {
                self.app_state.mode = .normal;
                self.app_state.clearInput();
            },
            libvaxis.Key.enter => {
                if (self.app_state.getSelectedCommand()) |cmd| {
                    if (cmd.action == .quit) {
                        self.should_exit = true;
                    } else {
                        self.app_state.executeCommand(cmd.action);
                    }
                }
                self.app_state.clearInput();
            },
            libvaxis.Key.tab => {
                // Cycle through command matches
                self.app_state.selectNextCommand();
            },
            libvaxis.Key.up, 'k' => {
                self.app_state.selectPrevCommand();
            },
            libvaxis.Key.down, 'j' => {
                self.app_state.selectNextCommand();
            },
            libvaxis.Key.backspace => {
                if (self.app_state.input_buffer.items.len > 1) {
                    self.app_state.deleteChar();
                    self.app_state.updateCommandMatches();
                } else {
                    self.app_state.clearInput();
                    self.app_state.mode = .normal;
                }
            },
            libvaxis.Key.f1 => {
                self.app_state.show_help = !self.app_state.show_help;
            },
            else => {
                if (key.codepoint >= 32 and key.codepoint < 127) {
                    self.app_state.insertChar(key.codepoint);
                    self.app_state.updateCommandMatches();
                }
            },
        }
    }

    fn handleInspectKey(self: *MathZigWidget, key: libvaxis.Key) void {
        switch (key.codepoint) {
            libvaxis.Key.escape, 'q' => {
                self.app_state.mode = .normal;
                self.app_state.selected_var = null;
            },
            libvaxis.Key.up, 'k' => {
                if (self.app_state.inspector_scroll_y > 0) {
                    self.app_state.inspector_scroll_y -= 1;
                }
            },
            libvaxis.Key.down, 'j' => {
                self.app_state.inspector_scroll_y += 1;
            },
            libvaxis.Key.left, 'h' => {
                if (self.app_state.inspector_scroll_x > 0) {
                    self.app_state.inspector_scroll_x -= 1;
                }
            },
            libvaxis.Key.right, 'l' => {
                self.app_state.inspector_scroll_x += 1;
            },
            else => {},
        }
    }

    pub fn render(self: *MathZigWidget, vx: *libvaxis.Vaxis) !void {
        const win = vx.window();
        const screen = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = self.screen_width,
            .height = self.screen_height,
            .border = .{
                .where = .all,
                .style = .{ .fg = .{ .index = 8 } },
            },
        });
        screen.clear();

        const input_region = screen.child(.{
            .x_off = 0,
            .y_off = @as(i17, @intCast(self.screen_height)) - 4,
            .width = self.screen_width,
            .height = 3,
        });
        self.input_rect = .{
            .x = 0,
            .y = self.screen_height - 4,
            .w = self.screen_width,
            .h = 3,
        };

        _ = input_region.printSegment(.{
            .text = " INPUT ",
            .style = .{
                .fg = if (self.app_state.focus == .input) .{ .index = 61 } else .default,
            },
        }, .{ .row_offset = 0, .col_offset = 0 });

        const input = self.app_state.input_buffer.items;
        const cursor_pos = @min(self.app_state.cursor_position, input.len);
        const input_width = if (self.screen_width > 8) self.screen_width - 8 else 0;
        const start_offset: usize = if (input_width > 0 and cursor_pos > input_width) cursor_pos - input_width else 0;
        
        // Syntax Highlighting
        const segments = syntax.highlight(self.render_arena.allocator(), input) catch &.{};
        
        const display_len = @min(input.len - start_offset, input_width);
        const end_offset = start_offset + display_len;
        
        var current_pos: usize = 0;
        var col_off: usize = 8;
        
        for (segments) |seg| {
            const seg_len = seg.text.len;
            const seg_end = current_pos + seg_len;
            
            // Check intersection with visible window [start_offset, end_offset)
            const visible_start = @max(current_pos, start_offset);
            const visible_end = @min(seg_end, end_offset);
            
            if (visible_start < visible_end) {
                // Determine slice within segment
                const slice_start = visible_start - current_pos;
                const slice_end = visible_end - current_pos;
                
                _ = input_region.printSegment(.{
                    .text = seg.text[slice_start..slice_end],
                    .style = seg.style,
                }, .{ .row_offset = 0, .col_offset = @intCast(col_off) });
                
                col_off += (slice_end - slice_start);
            }
            
            current_pos += seg_len;
            if (current_pos >= end_offset) break;
        }

        // Show cursor as underscore when focused on input
        if (self.app_state.focus == .input and self.screen_width > 8) {
            const cursor_col = @as(u16, @intCast(@min(8 + cursor_pos - start_offset, self.screen_width - 1)));
            input_region.writeCell(cursor_col, 0, .{
                .char = .{ .grapheme = "_", .width = 1 },
                .style = .{ .fg = .{ .index = 10 }, .bg = .{ .index = 0 } },
            });
        }

        if (self.app_state.history.items.len > 0) {
            const hist_region = screen.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = self.screen_width / 2,
                .height = @as(u16, @intCast(self.screen_height)) - 5,
            });
            self.history_rect = .{
                .x = 0,
                .y = 0,
                .w = self.screen_width / 2,
                .h = self.screen_height - 5,
            };
            _ = hist_region.printSegment(.{
                .text = " HISTORY ",
                .style = .{
                    .fg = if (self.app_state.focus == .history) .{ .index = 61 } else .default,
                },
            }, .{ .row_offset = 0, .col_offset = 0 });

            var row: u16 = 2;
            const len = self.app_state.history.items.len;
            const start = if (self.app_state.history_position > len)
                if (len < 5) 0 else len - 5
            else
                self.app_state.history_position;

            for (start..self.app_state.history.items.len) |i| {
                if (row >= hist_region.height) break;
                const entry = self.app_state.history.items[i];
                const style: libvaxis.Style = if (i == self.app_state.history_position)
                    .{ .fg = .{ .index = 61 }, .reverse = true }
                else if (entry.is_error)
                    .{ .fg = .{ .index = 196 } }
                else
                    .{};

                _ = hist_region.printSegment(.{
                    .text = entry.command,
                    .style = style,
                }, .{ .row_offset = row, .col_offset = 1 });
                row += 1;

                if (entry.result.len > 0) {
                    var line_it = std.mem.splitScalar(u8, entry.result, '\n');
                    while (line_it.next()) |line| {
                        if (row >= hist_region.height) break;
                        _ = hist_region.printSegment(.{
                            .text = line,
                            .style = if (entry.is_error) .{ .fg = .{ .index = 196 } } else .{ .fg = .{ .index = 246 } },
                        }, .{ .row_offset = row, .col_offset = 1 });
                        row += 1;
                    }
                }
            }
        } else {
            // Show placeholder for empty history
            const hist_region = screen.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = self.screen_width / 2,
                .height = @as(u16, @intCast(self.screen_height)) - 5,
            });
            self.history_rect = .{
                .x = 0,
                .y = 0,
                .w = self.screen_width / 2,
                .h = self.screen_height - 5,
            };
            _ = hist_region.printSegment(.{
                .text = " HISTORY ",
                .style = .{
                    .fg = if (self.app_state.focus == .history) .{ .index = 61 } else .default,
                },
            }, .{ .row_offset = 0, .col_offset = 0 });
            _ = hist_region.printSegment(.{
                .text = "(empty)",
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .row_offset = 2, .col_offset = 1 });
            // Welcome message
            _ = hist_region.printSegment(.{
                .text = "Type an expression and",
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .row_offset = 4, .col_offset = 1 });
            _ = hist_region.printSegment(.{
                .text = "press Enter to evaluate.",
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .row_offset = 5, .col_offset = 1 });
        }

        // Vertical separator between history and vars
        if (self.screen_width > 1) {
            const sep_x = self.screen_width / 2;
            const sep_height = @as(u16, @intCast(self.screen_height)) - 5;
            var sep_row: u16 = 0;
            while (sep_row < sep_height) : (sep_row += 1) {
                screen.writeCell(sep_x, sep_row, .{
                    .char = .{ .grapheme = "│", .width = 1 },
                    .style = .{ .fg = .{ .index = 8 } },
                });
            }
        }

        const vars_region = screen.child(.{
            .x_off = @as(i17, @intCast(self.screen_width / 2)),
            .y_off = 0,
            .width = self.screen_width / 2,
            .height = @as(u16, @intCast(self.screen_height)) - 5,
        });
        self.vars_rect = .{
            .x = self.screen_width / 2,
            .y = 0,
            .w = self.screen_width / 2,
            .h = self.screen_height - 5,
        };
        _ = vars_region.printSegment(.{
            .text = " VARS ",
            .style = .{
                .fg = if (self.app_state.focus == .vars) .{ .index = 208 } else .default,
            },
        }, .{ .row_offset = 0, .col_offset = 0 });

        if (self.app_state.is_searching_vars) {
            _ = vars_region.printSegment(.{
                .text = " Search: ",
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .row_offset = 1, .col_offset = 0 });
            _ = vars_region.printSegment(.{
                .text = self.app_state.vars_search_query.items,
                .style = .{ .fg = .{ .index = 10 } },
            }, .{ .row_offset = 1, .col_offset = 9 });
            // Draw cursor for search
            const cursor_col = @as(u16, @intCast(9 + self.app_state.vars_search_query.items.len));
            if (cursor_col < vars_region.width) {
                vars_region.writeCell(cursor_col, 1, .{
                    .char = .{ .grapheme = "_", .width = 1 },
                    .style = .{ .fg = .{ .index = 10 } },
                });
            }
        }

        const sorted = self.app_state.getSortedVars(self.render_arena.allocator()) catch &.{} ;

        if (sorted.len > 0) {
            var row: u16 = 2;
            var ui_idx: usize = 0;
            var found_sep = false;
            for (sorted) |item| {
                if (!found_sep and item.variable.is_constant) {
                    // Draw separator
                    if (ui_idx >= self.app_state.vars_scroll_pos) {
                        if (row < vars_region.height) {
                            _ = vars_region.printSegment(.{
                                .text = "---",
                                .style = .{ .fg = .{ .index = 8 } },
                            }, .{ .row_offset = row, .col_offset = 1 });
                            row += 1;
                        }
                    }
                    ui_idx += 1;
                    found_sep = true;
                }

                if (ui_idx < self.app_state.vars_scroll_pos) {
                    ui_idx += 1;
                    continue;
                }
                if (row >= vars_region.height) break;

                const name = item.name;
                const var_entry = item.variable;
                const is_selected = (ui_idx == self.app_state.vars_scroll_pos and self.app_state.focus == .vars);
                
                const style: libvaxis.Style = if (is_selected)
                    .{ .fg = .{ .index = 208 }, .reverse = true }
                else
                    .{};

                _ = vars_region.printSegment(.{
                    .text = name,
                    .style = style,
                }, .{ .row_offset = row, .col_offset = 1 });
                _ = vars_region.printSegment(.{
                    .text = "=",
                }, .{ .row_offset = row, .col_offset = @as(u16, @intCast(name.len + 2)) });
                _ = vars_region.printSegment(.{
                    .text = var_entry.value_preview,
                }, .{ .row_offset = row, .col_offset = @as(u16, @intCast(name.len + 4)) });
                row += 1;
                ui_idx += 1;
            }
        } else {
            _ = vars_region.printSegment(.{
                .text = if (self.app_state.is_searching_vars) "(no matches)" else "(no variables)",
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .row_offset = 2, .col_offset = 1 });
        }

        const footer_region = screen.child(.{
            .x_off = 0,
            .y_off = @as(i17, @intCast(self.screen_height)) - 1,
            .width = self.screen_width,
            .height = 1,
        });
        _ = footer_region.printSegment(.{
            .text = " [Tab] Focus  [Enter] Eval  [Esc] Clear  [/] Commands  [Ctrl+f] Search Vars  [F1] Help  [Ctrl+C] Quit ",
            .style = .{
                .fg = .{ .index = 15 },
                .bg = .{ .index = 236 },
            },
        }, .{ .row_offset = 0, .col_offset = 0 });

        // Horizontal separator above footer
        if (self.screen_height > 1) {
            var sep_col: u16 = 0;
            while (sep_col < self.screen_width) : (sep_col += 1) {
                screen.writeCell(sep_col, @as(u16, @intCast(self.screen_height)) - 2, .{
                    .char = .{ .grapheme = "─", .width = 1 },
                    .style = .{ .fg = .{ .index = 8 } },
                });
            }
        }

        // --- Inspector Modal ---
        if (self.app_state.mode == .inspecting and self.app_state.selected_var != null) {
            const var_name = self.app_state.selected_var.?;
            const modal_width = @min(self.screen_width - 4, 60);
            const modal_height = @min(self.screen_height - 4, 15);
            const modal_x = (self.screen_width - modal_width) / 2;
            const modal_y = (self.screen_height - modal_height) / 2;

            const modal = win.child(.{
                .x_off = @as(i17, @intCast(modal_x)),
                .y_off = @as(i17, @intCast(modal_y)),
                .width = modal_width,
                .height = modal_height,
                .border = .{
                    .where = .all,
                    .style = .{ .fg = .{ .index = 14 } },
                },
            });
            modal.clear();

            _ = modal.printSegment(.{
                .text = " VARIABLE INSPECTOR ",
                .style = .{ .fg = .{ .index = 14 }, .bold = true },
            }, .{ .row_offset = 0, .col_offset = 2 });

            _ = modal.printSegment(.{
                .text = "Name: ",
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .row_offset = 2, .col_offset = 2 });
            _ = modal.printSegment(.{ .text = var_name }, .{ .row_offset = 2, .col_offset = 8 });

            if (self.app_state.mathzig_ctx.variables.get(var_name)) |idx| {
                if (idx < self.app_state.mathzig_ctx.vm.variables.len) {
                    const val = self.app_state.mathzig_ctx.vm.variables[idx];
                    
                    _ = modal.printSegment(.{
                        .text = "Type: ",
                        .style = .{ .fg = .{ .index = 8 } },
                    }, .{ .row_offset = 3, .col_offset = 2 });
                    _ = modal.printSegment(.{ .text = @tagName(val.tag) }, .{ .row_offset = 3, .col_offset = 8 });

                    _ = modal.printSegment(.{
                        .text = "Value: ",
                        .style = .{ .fg = .{ .index = 8 } },
                    }, .{ .row_offset = 4, .col_offset = 2 });
                    const preview = state.formatValue(val, self.render_arena.allocator(), self.app_state.mathzig_ctx) catch "err";
                    _ = modal.printSegment(.{ .text = preview }, .{ .row_offset = 4, .col_offset = 9 });

                    if (val.tag == .unit) {
                        const u = val.data.unit;
                        _ = modal.printSegment(.{
                            .text = "Unit: ",
                            .style = .{ .fg = .{ .index = 8 } },
                        }, .{ .row_offset = 6, .col_offset = 2 });
                        _ = modal.printSegment(.{ .text = u.info.name orelse "(anonymous)" }, .{ .row_offset = 6, .col_offset = 10 });

                        _ = modal.printSegment(.{
                            .text = "SI Base: ",
                            .style = .{ .fg = .{ .index = 8 } },
                        }, .{ .row_offset = 7, .col_offset = 2 });
                        const si_str = state.formatSIDimensions(u.info.dimensions, self.render_arena.allocator()) catch "err";
                        _ = modal.printSegment(.{ .text = si_str }, .{ .row_offset = 7, .col_offset = 11 });
                        
                        _ = modal.printSegment(.{
                            .text = "Magnitude: ",
                            .style = .{ .fg = .{ .index = 8 } },
                        }, .{ .row_offset = 8, .col_offset = 2 });
                        var mag_buf: [32]u8 = undefined;
                        const mag_txt = std.fmt.bufPrint(&mag_buf, "{d:.6}", .{u.value}) catch "err";
                        _ = modal.printSegment(.{ .text = mag_txt }, .{ .row_offset = 8, .col_offset = 13 });
                    } else if (val.tag == .matrix) {
                        const m = val.data.matrix;
                        var dim_buf: [32]u8 = undefined;
                        const dim_txt = std.fmt.bufPrint(&dim_buf, "{d} x {d}", .{ m.rows, m.cols }) catch "err";
                        _ = modal.printSegment(.{
                            .text = "Dims: ",
                            .style = .{ .fg = .{ .index = 8 } },
                        }, .{ .row_offset = 6, .col_offset = 2 });
                        _ = modal.printSegment(.{ .text = dim_txt }, .{ .row_offset = 6, .col_offset = 10 });
                    }
                }
            }

            _ = modal.printSegment(.{
                .text = " [Esc] Close ",
                .style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 14 } },
            }, .{ .row_offset = modal_height - 1, .col_offset = modal_width / 2 - 6 });
        }

        // --- Help Modal ---
        if (self.app_state.show_help) {
            const modal_width = @min(self.screen_width - 4, 60);
            const modal_height = @min(self.screen_height - 4, 18);
            const modal_x = (self.screen_width - modal_width) / 2;
            const modal_y = (self.screen_height - modal_height) / 2;

            const modal = win.child(.{
                .x_off = @as(i17, @intCast(modal_x)),
                .y_off = @as(i17, @intCast(modal_y)),
                .width = modal_width,
                .height = modal_height,
                .border = .{
                    .where = .all,
                    .style = .{ .fg = .{ .index = 11 } },
                },
            });
            modal.clear();

            _ = modal.printSegment(.{
                .text = " MATHZIG TUI HELP ",
                .style = .{ .fg = .{ .index = 11 }, .bold = true },
            }, .{ .row_offset = 0, .col_offset = 2 });

            const help_text = [_][]const u8{
                "Global Shortcuts:",
                "  Tab          Cycle focus",
                "  F1           Show this help",
                "  Ctrl+C       Quit application",
                "  /            Command palette",
                "",
                "Input Shortcuts:",
                "  Enter        Evaluate expression",
                "  Up/Down      History navigation",
                "  Ctrl+L       Clear input",
                "",
                "Variable Shortcuts:",
                "  Ctrl+f       Toggle variable search",
                "  Enter        Inspect selected variable",
                "  Up/Down      Scroll variables",
                "  Esc          Exit search / Close inspector",
            };

            for (help_text, 2..) |line, i| {
                if (i >= modal_height - 1) break;
                _ = modal.printSegment(.{
                    .text = line,
                    .style = if (std.mem.endsWith(u8, line, ":")) .{ .bold = true, .fg = .{ .index = 14 } } else .{},
                }, .{ .row_offset = @as(u16, @intCast(i)), .col_offset = 2 });
            }

            _ = modal.printSegment(.{
                .text = " [Esc/F1] Close ",
                .style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 11 } },
            }, .{ .row_offset = modal_height - 1, .col_offset = modal_width / 2 - 7 });
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tty = try libvaxis.Tty.init(&.{});
    defer tty.deinit();

    var vx = try libvaxis.Vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 2 * std.time.ns_per_s);

    const ws = libvaxis.Tty.getWinsize(tty.fd) catch libvaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };

    var widget = try MathZigWidget.init(allocator);
    defer widget.deinit();

    // Handle command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip exe
    if (args.next()) |script_path| {
        widget.app_state.mathzig_ctx.loadScript(script_path) catch {};
        widget.app_state.syncVariables();
    }

    widget.screen_width = ws.cols;
    widget.screen_height = ws.rows;
    try vx.resize(allocator, tty.writer(), ws);

    var loop = libvaxis.Loop(Event){
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();

    vx.queueRefresh();
    while (!widget.should_exit) {
        const event = loop.tryEvent() orelse loop.nextEvent();
        
        switch (event) {
            .winsize => |new_ws| {
                try vx.resize(allocator, tty.writer(), new_ws);
                widget.screen_width = new_ws.cols;
                widget.screen_height = new_ws.rows;
            },
            else => widget.handleEvent(event),
        }

        _ = widget.render_arena.reset(.retain_capacity);
        widget.render(&vx) catch {};
        vx.render(tty.writer()) catch {};
    }

    try vx.exitAltScreen(tty.writer());
}
