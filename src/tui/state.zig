// Math TUI - State Management
// Stores application state for the MathZig TUI

const std = @import("std");
const mathzig = @import("mathzig");
const diagnostics = @import("diagnostics");

/// Focus target for keyboard navigation
pub const Focus = enum {
    history,
    input,
    vars,
};

/// Application mode
pub const AppMode = enum {
    normal,
    inspecting,
    command,
};

/// Available commands
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    action: CommandAction,
};

pub const CommandAction = enum {
    clear, // Clear history
    help, // Show help
    quit, // Exit application
    vars, // Show all variables
    clear_vars, // Clear all variables
    pref, // Set preferred unit
    config_dump, // Export default keybindings
};

/// List of available commands
pub const commands = [_]Command{
    .{ .name = "clear", .description = "Clear command history", .action = .clear },
    .{ .name = "help", .description = "Show help information", .action = .help },
    .{ .name = "quit", .description = "Exit the application", .action = .quit },
    .{ .name = "vars", .description = "List all variables", .action = .vars },
    .{ .name = "clearvars", .description = "Clear all variables", .action = .clear_vars },
    .{ .name = "pref", .description = "Set preferred unit for its dimensions (e.g. /pref kWh)", .action = .pref },
    .{ .name = "config-dump", .description = "Export default keybindings to keybindings.yaml", .action = .config_dump },
};

/// A single entry in the command history
pub const HistoryEntry = struct {
    command: []const u8,
    result: []const u8,
    timestamp: i128,
    is_error: bool = false,
};

pub const VarListItem = struct {
    name: []const u8,
    variable: Variable,
};

/// Preview string for variable values
pub const Variable = struct {
    value_preview: []const u8,
    data_type: []const u8,
    sparkline: ?[]const u8 = null,
    rows: u32 = 0,
    cols: u32 = 0,
    is_constant: bool = false,
};

/// Main application state
pub const AppState = struct {
    allocator: std.mem.Allocator,
    mode: AppMode = .normal,
    focus: Focus = .input,
    input_buffer: std.ArrayListUnmanaged(u8),
    cursor_position: usize = 0,
    history: std.ArrayListUnmanaged(HistoryEntry),
    history_position: usize = 0,
    variables: std.StringHashMapUnmanaged(Variable),
    mathzig_ctx: *mathzig.MathZig,
    // Command mode state
    command_selected: usize = 0,
    command_matches: std.ArrayListUnmanaged(usize) = .{}, // Indices into commands array
    show_help: bool = false,
    // Inspection state
    selected_var: ?[]const u8 = null,
    vars_scroll_pos: usize = 0,
    inspector_scroll_x: usize = 0,
    inspector_scroll_y: usize = 0,
    // Variable search state
    vars_search_query: std.ArrayListUnmanaged(u8) = .{},
    is_searching_vars: bool = false,
    session_log_path: ?[]const u8 = "last_session.mzig",

    pub fn getSortedVars(self: *const AppState, allocator: std.mem.Allocator) ![]VarListItem {
        var list = std.ArrayListUnmanaged(VarListItem).empty;
        defer list.deinit(allocator);
        
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            if (self.is_searching_vars and self.vars_search_query.items.len > 0) {
                if (std.ascii.indexOfIgnoreCase(entry.key_ptr.*, self.vars_search_query.items) == null) {
                    continue;
                }
            }
            try list.append(allocator, .{ .name = entry.key_ptr.*, .variable = entry.value_ptr.* });
        }

        std.mem.sort(VarListItem, list.items, {}, struct {
            fn lessThan(_: void, a: VarListItem, b: VarListItem) bool {
                if (a.variable.is_constant != b.variable.is_constant) {
                    return !a.variable.is_constant; // User vars first (is_constant = false)
                }
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        return list.toOwnedSlice(allocator);
    }

    /// Initialize the app state
    pub fn init(allocator: std.mem.Allocator) !AppState {
        const ctx = try mathzig.MathZig.init(allocator);

        return AppState{
            .allocator = allocator,
            .input_buffer = .{},
            .history = .{},
            .variables = .{},
            .history_position = 0,
            .mathzig_ctx = ctx,
        };
    }

    pub fn logCommand(self: *AppState, command: []const u8) void {
        const path = self.session_log_path orelse return;
        const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        _ = file.deprecatedWriter().print("{s}\n", .{command}) catch {};
    }

    /// Clean up resources
    pub fn deinit(self: *AppState) void {
        self.input_buffer.deinit(self.allocator);
        for (self.history.items) |entry| {
            if (entry.command.len > 0) self.allocator.free(entry.command);
            if (entry.result.len > 0) self.allocator.free(entry.result);
        }
        self.history.deinit(self.allocator);

        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.value_preview.len > 0) {
                self.allocator.free(entry.value_ptr.value_preview);
            }
            if (entry.value_ptr.sparkline) |s| self.allocator.free(s);
        }
        self.variables.deinit(self.allocator);

        if (self.selected_var) |v| self.allocator.free(v);

        self.vars_search_query.deinit(self.allocator);
        self.command_matches.deinit(self.allocator);
        self.mathzig_ctx.deinit();
    }

    /// Set the current input value and cursor position
    pub fn setInputValue(self: *AppState, text: []const u8, cursor: usize) !void {
        self.input_buffer.clearRetainingCapacity();
        try self.input_buffer.appendSlice(self.allocator, text);
        self.cursor_position = @min(cursor, text.len);
        _ = self.checkCommandMode();
        if (self.mode == .command) {
            self.updateCommandMatches();
        }
    }

    /// Check if input starts with / and enter command mode
    pub fn checkCommandMode(self: *AppState) bool {
        if (self.input_buffer.items.len > 0 and self.input_buffer.items[0] == '/') {
            if (self.mode != .command) {
                self.mode = .command;
                self.updateCommandMatches();
            }
            return true;
        } else {
            if (self.mode == .command) {
                self.mode = .normal;
                self.command_matches.clearRetainingCapacity();
            }
            return false;
        }
    }

    /// Update command matches based on current input
    pub fn updateCommandMatches(self: *AppState) void {
        self.command_matches.clearRetainingCapacity();
        self.command_selected = 0;

        // Get the command prefix (after /)
        const input = self.input_buffer.items;
        if (input.len == 0 or input[0] != '/') return;

        const prefix = if (input.len > 1) input[1..] else "";

        // Find matching commands
        for (commands, 0..) |cmd, i| {
            if (prefix.len == 0 or std.mem.startsWith(u8, cmd.name, prefix)) {
                self.command_matches.append(self.allocator, i) catch {};
            }
        }
    }

    /// Get currently selected command
    pub fn getSelectedCommand(self: *AppState) ?Command {
        if (self.command_matches.items.len == 0) return null;
        const idx = self.command_matches.items[self.command_selected];
        return commands[idx];
    }

    /// Execute the selected command
    pub fn executeCommand(self: *AppState, action: CommandAction) void {
        switch (action) {
            .clear => {
                self.history.clearRetainingCapacity();
            },
            .help => {
                self.show_help = true;
            },
            .quit => {
                // Show quit message - actual quit is via Ctrl+C
                self.history.append(self.allocator, HistoryEntry{
                    .command = self.allocator.dupe(u8, "/quit") catch return,
                    .result = self.allocator.dupe(u8, "Press Ctrl+C to exit the application.") catch return,
                    .timestamp = std.time.nanoTimestamp(),
                    .is_error = false,
                }) catch {};
            },
            .vars => {
                // Add variable listing to history
                var buf: [512]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const writer = fbs.writer();

                writer.writeAll("Variables:\n") catch {};
                var iter = self.variables.iterator();
                while (iter.next()) |entry| {
                    writer.print("  {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.value_preview }) catch break;
                }

                const result = self.allocator.dupe(u8, fbs.getWritten()) catch return;
                self.history.append(self.allocator, HistoryEntry{
                    .command = self.allocator.dupe(u8, "/vars") catch return,
                    .result = result,
                    .timestamp = std.time.nanoTimestamp(),
                    .is_error = false,
                }) catch {
                    self.allocator.free(result);
                };
            },
            .clear_vars => {
                self.variables.clearRetainingCapacity();
                // Also need to reset the MathZig context for real cleanup
                self.history.append(self.allocator, HistoryEntry{
                    .command = self.allocator.dupe(u8, "/clearvars") catch return,
                    .result = self.allocator.dupe(u8, "All variables cleared") catch return,
                    .timestamp = std.time.nanoTimestamp(),
                    .is_error = false,
                }) catch {};
            },
            .pref => {
                // Get the unit name from the input buffer after "/pref "
                const input = self.input_buffer.items;
                if (input.len > 6) {
                    const unit_name = input[6..];
                    if (self.mathzig_ctx.unit_registry.findUnit(unit_name)) |res| {
                        self.mathzig_ctx.unit_registry.setPreferredUnit(res.unit.dimensions, res.unit.name) catch {};

                        const result = std.fmt.allocPrint(self.allocator, "Set preferred unit for {s} dimensions to {s}", .{ unit_name, res.unit.name }) catch return;
                        self.history.append(self.allocator, HistoryEntry{
                            .command = self.allocator.dupe(u8, input) catch return,
                            .result = result,
                            .timestamp = std.time.nanoTimestamp(),
                            .is_error = false,
                        }) catch {};
                    } else {
                        const result = std.fmt.allocPrint(self.allocator, "Unknown unit: {s}", .{unit_name}) catch return;
                        self.history.append(self.allocator, HistoryEntry{
                            .command = self.allocator.dupe(u8, input) catch return,
                            .result = result,
                            .timestamp = std.time.nanoTimestamp(),
                            .is_error = true,
                        }) catch {};
                    }
                }
            },
            .config_dump => {
                const yaml =
                    \\# ------------------------------------------------------------------
                    \\# Math TUI Keybindings Configuration
                    \\# ------------------------------------------------------------------
                    \\global:
                    \\  app.quit: ["<Ctrl-c>"]
                    \\  app.force_quit: ["<Ctrl-d>"]
                    \\  app.help: ["<F1>"]
                    \\  app.palette: ["<Ctrl-p>"]
                    \\  app.redraw: ["<Ctrl-r>"]
                    \\  focus.cycle: ["<Tab>"]
                    \\  focus.cycle_rev: ["<Shift-Tab>"]
                    \\  focus.history: ["<Ctrl-1>"]
                    \\  focus.input: ["<Ctrl-2>"]
                    \\  focus.vars: ["<Ctrl-3>"]
                    \\input:
                    \\  input.submit: ["<Enter>"]
                    \\  input.newline: ["<Ctrl-Enter>", "<Shift-Enter>"]
                    \\  input.autocomplete: ["<Ctrl-Space>"]
                    \\  input.clear_line: ["<Ctrl-u>"]
                    \\  input.history_prev: ["<Up>"]
                    \\  input.history_next: ["<Down>"]
                    \\list_nav:
                    \\  list.up: ["<Up>", "k"]
                    \\  list.down: ["<Down>", "j"]
                    \\history:
                    \\  history.load: ["<Enter>"]
                    \\  history.rerun: ["<Ctrl-Enter>"]
                    \\vars:
                    \\  vars.inspect: ["<Enter>"]
                    \\inspector:
                    \\  inspector.close: ["<Esc>", "q"]
                    \\
                ;

                var success = true;
                const file = std.fs.cwd().createFile("keybindings.yaml", .{}) catch blk: {
                    success = false;
                    break :blk null;
                };
                if (file) |f| {
                    defer f.close();
                    f.writeAll(yaml) catch {
                        success = false;
                    };
                }

                const command = self.allocator.dupe(u8, "/config-dump") catch return;
                const result = self.allocator.dupe(u8, if (success) "Configuration exported to keybindings.yaml" else "Error: Failed to write keybindings.yaml") catch {
                    self.allocator.free(command);
                    return;
                };

                self.history.append(self.allocator, HistoryEntry{
                    .command = command,
                    .result = result,
                    .timestamp = std.time.nanoTimestamp(),
                    .is_error = !success,
                }) catch {
                    self.allocator.free(command);
                    self.allocator.free(result);
                };
            },
        }
    }

    /// Select next command in list
    pub fn selectNextCommand(self: *AppState) void {
        if (self.command_matches.items.len == 0) return;
        self.command_selected = (self.command_selected + 1) % self.command_matches.items.len;
    }

    /// Select previous command in list
    pub fn selectPrevCommand(self: *AppState) void {
        if (self.command_matches.items.len == 0) return;
        if (self.command_selected == 0) {
            self.command_selected = self.command_matches.items.len - 1;
        } else {
            self.command_selected -= 1;
        }
    }

    /// Evaluate an expression and return the result as a string
    pub fn evaluate(self: *AppState, expression: []const u8) EvalResult {
        const result = self.mathzig_ctx.eval(expression) catch |err| {
            // Get the detailed error message from MathZig context
            const ctx_error = self.mathzig_ctx.lastError();
            const error_msg = if (ctx_error.len > 0) ctx_error else formatError(err);

            // Get the error offset for position indicator
            const error_offset = self.mathzig_ctx.getLastErrorOffset();

            // Format error with position pointer
            const formatted_error = diagnostics.formatErrorWithPointer(self.allocator, expression, error_msg, error_offset, 0) catch
                self.allocator.dupe(u8, error_msg) catch return EvalResult{ .success = false, .result_str = "" };

            return EvalResult{
                .success = false,
                .result_str = formatted_error,
                .var_name = null,
                .error_offset = error_offset,
            };
        };

        // Note: We no longer manually parse variable names here.
        // The display is updated by syncing all variables from the VM after execution.

        const res_str = formatValue(result, self.allocator, self.mathzig_ctx) catch self.allocator.dupe(u8, "err") catch return EvalResult{
            .success = false,
            .result_str = "",
            .var_name = null,
        };

        // Log to session file
        self.logCommand(expression);

        return EvalResult{
            .success = true,
            .result_str = res_str,
            .value_type = getValueType(result),
            .var_name = null,
        };
    }

    /// Update variables display from MathZig context
    pub fn syncVariables(self: *AppState) void {
        // Clear existing display variables
        // We need to free existing previews/sparklines
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.value_preview.len > 0) {
                self.allocator.free(entry.value_ptr.value_preview);
            }
            if (entry.value_ptr.sparkline) |s| self.allocator.free(s);
        }
        self.variables.clearRetainingCapacity();

        // Constants names from mathzig.zig
        const constant_names = [_][]const u8{
            "pi", "tau", "e", "phi", "SQRT2", "LN2", "LN10",
            "inf", "Infinity", "nan", "NaN",
            "speedOfLight", "planckConstant", "gravitationalConstant",
        };

        // Iterate through MathZig's variables
        var iter = self.mathzig_ctx.variables.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const index = entry.value_ptr.*;

            // Get the value from VM variables array directly
            if (index < self.mathzig_ctx.vm.variables.len) {
                const value = self.mathzig_ctx.vm.variables[index];
                const value_preview = formatValue(value, self.allocator, self.mathzig_ctx) catch self.allocator.dupe(u8, "err") catch return;
                const dtype = getValueType(value);

                var is_const = false;
                for (constant_names) |c_name| {
                    if (std.mem.eql(u8, name, c_name)) {
                        is_const = true;
                        break;
                    }
                }

                var variable = Variable{
                    .value_preview = value_preview,
                    .data_type = dtype,
                    .is_constant = is_const,
                };

                // Add sparkline for matrices or arrays if they contain numbers
                if (value.tag == .matrix) {
                    const m = value.data.matrix;
                    variable.rows = m.rows;
                    variable.cols = m.cols;

                    // If it's a vector (row or col), generate sparkline
                    if (m.rows == 1 or m.cols == 1) {
                        const data = m.data[m.offset..][0 .. m.rows * m.cols];
                        variable.sparkline = generateSparkline(self.allocator, data, 10) catch null;
                    }
                } else if (value.tag == .array) {
                    // Extract numeric data for sparkline if possible
                    var float_data = std.ArrayListUnmanaged(f64).empty;
                    defer float_data.deinit(self.allocator);

                    for (value.data.array.items) |v| {
                        if (v.tag == .number) {
                            float_data.append(self.allocator, v.data.number) catch break;
                        }
                    }

                    if (float_data.items.len > 0) {
                        variable.sparkline = generateSparkline(self.allocator, float_data.items, 10) catch null;
                    }
                } else if (value.tag == .series) {
                    const s = value.data.series;
                    // For series, we visualize the values
                    // Series stores values as aligned slice
                    // We can just use the slice directly if valid
                    const data = s.values;
                    variable.rows = @intCast(s.len);
                    variable.cols = 1;
                    variable.sparkline = generateSparkline(self.allocator, data, 10) catch null;
                }

                const name_dupe = self.allocator.dupe(u8, name) catch {
                    self.allocator.free(value_preview);
                    continue;
                };

                self.variables.put(self.allocator, name_dupe, variable) catch {
                    self.allocator.free(name_dupe);
                    self.allocator.free(value_preview);
                    continue;
                };
            }
        }
    }

    /// Add a character at the current cursor position (ASCII only for safety)
    pub fn insertChar(self: *AppState, char: u21) void {
        // Only handle ASCII characters for now (0-127)
        if (char > 127) return;
        const byte = @as(u8, @intCast(char));

        // Use a small buffer for the byte
        var buf: [1]u8 = undefined;
        buf[0] = byte;
        self.input_buffer.insertSlice(self.allocator, self.cursor_position, &buf) catch return;
        self.cursor_position += 1;
    }

    /// Delete the character before the cursor
    pub fn deleteChar(self: *AppState) void {
        if (self.cursor_position == 0) return;
        if (self.cursor_position > self.input_buffer.items.len) {
            self.cursor_position = self.input_buffer.items.len;
        }

        // Simple ASCII deletion - delete one byte
        const delete_pos = self.cursor_position - 1;
        self.input_buffer.replaceRange(self.allocator, delete_pos, 1, &.{}) catch {};
        self.cursor_position = delete_pos;
    }

    /// Delete the character after the cursor
    pub fn deleteCharForward(self: *AppState) void {
        const input_len = self.input_buffer.items.len;
        if (self.cursor_position >= input_len) return;

        self.input_buffer.replaceRange(self.allocator, self.cursor_position, 1, &.{}) catch {};
    }

    /// Move cursor left by one character
    pub fn moveCursorLeft(self: *AppState) void {
        if (self.cursor_position == 0) return;
        self.cursor_position -= 1;
    }

    /// Move cursor right by one character
    pub fn moveCursorRight(self: *AppState) void {
        const input_len = self.input_buffer.items.len;
        if (self.cursor_position >= input_len) return;
        self.cursor_position += 1;
    }

    /// Move cursor to the beginning of the line
    pub fn moveCursorToStart(self: *AppState) void {
        self.cursor_position = 0;
    }

    /// Move cursor to the end of the line
    pub fn moveCursorToEnd(self: *AppState) void {
        self.cursor_position = self.input_buffer.items.len;
    }

    /// Clear the input buffer
    pub fn clearInput(self: *AppState) void {
        self.input_buffer.clearRetainingCapacity();
        self.cursor_position = 0;
        self.history_position = 0;
    }

    /// Clear from cursor to end of line
    pub fn clearToEnd(self: *AppState) void {
        const input_len = self.input_buffer.items.len;
        if (self.cursor_position >= input_len) return;

        self.input_buffer.shrinkRetainingCapacity(self.cursor_position);
    }

    /// Clear from start to cursor
    pub fn clearToStart(self: *AppState) void {
        if (self.cursor_position == 0) return;

        const remaining = self.input_buffer.items[self.cursor_position..];
        var new_buf = std.ArrayListUnmanaged(u8).empty;
        new_buf.appendSlice(self.allocator, remaining) catch {};
        self.input_buffer.deinit(self.allocator);
        self.input_buffer = new_buf;
        self.cursor_position = 0;
    }

    /// Check if there are unmatched brackets in the input
    pub fn hasUnmatchedBrackets(self: *AppState) bool {
        const input = self.input_buffer.items;
        var stack: usize = 0;

        for (input) |byte| {
            if (byte == '(' or byte == '[' or byte == '{') {
                stack += 1;
            } else if (byte == ')' or byte == ']' or byte == '}') {
                if (stack == 0) return true;
                stack -= 1;
            }
        }

        return stack > 0;
    }

    /// Navigate history - returns previous command if exists
    pub fn navigateHistoryPrev(self: *AppState) ?[]const u8 {
        // Start from the most recent entry
        if (self.history_position == 0) {
            self.history_position = self.history.items.len;
        }

        if (self.history_position == 0) return null;

        self.history_position -= 1;
        return self.history.items[self.history_position].command;
    }

    /// Navigate history - returns next command if exists
    pub fn navigateHistoryNext(self: *AppState) ?[]const u8 {
        if (self.history_position >= self.history.items.len) return null;

        self.history_position += 1;
        if (self.history_position >= self.history.items.len) {
            // We've gone past the end - return null and reset
            self.history_position = 0;
            return null;
        }

        return self.history.items[self.history_position].command;
    }

    /// Check if we're at the start of history
    pub fn atHistoryStart(self: *AppState) bool {
        return self.history_position == 0;
    }

    /// Check if we're at the end of history
    pub fn atHistoryEnd(self: *AppState) bool {
        return self.history_position >= self.history.items.len;
    }

    /// Get history entry for autocomplete (finds prefix match)
    pub fn findHistoryForAutocomplete(self: *AppState, prefix: []const u8) ?[]const u8 {
        // Search backwards through history for a command that starts with prefix
        var i: usize = self.history.items.len;
        while (i > 0) {
            i -= 1;
            const cmd = self.history.items[i].command;
            if (cmd.len > prefix.len and std.mem.startsWith(u8, cmd, prefix)) {
                return cmd;
            }
        }
        return null;
    }

    /// Delete a variable by name
    pub fn deleteVariable(self: *AppState, name: []const u8) void {
        if (self.variables.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.value_preview);
            if (entry.value.sparkline) |s| self.allocator.free(s);
        }
        // Note: We don't remove from MathZig VM as it uses indices,
        // but it will be overwritten if a new variable is created.
    }

    /// Delete a history entry by index
    pub fn deleteHistoryEntry(self: *AppState, index: usize) void {
        if (index < self.history.items.len) {
            const entry = self.history.orderedRemove(index);
            self.allocator.free(entry.command);
            self.allocator.free(entry.result);
        }
    }
};

/// Result of an evaluation
pub const EvalResult = struct {
    success: bool,
    result_str: []const u8,
    value_type: []const u8 = "unknown",
    var_name: ?[]const u8 = null,
    error_offset: ?u32 = null, // Character offset where error occurred
};

const LengthPowerDisplay = struct { scaled_value: f64, prefix: []const u8, exp: i8 };

fn tryLengthPowerDisplay(u: mathzig.UnitValue) ?LengthPowerDisplay {
    if (u.info.dimensions.l <= 0) return null;
    if (u.info.dimensions.m != 0 or u.info.dimensions.t != 0 or u.info.dimensions.i != 0 or u.info.dimensions.k != 0 or u.info.dimensions.n != 0 or u.info.dimensions.j != 0) {
        return null;
    }

    const exp: i8 = u.info.dimensions.l;
    const prefixes = [_]struct { name: []const u8, scale: f64 }{
        .{ .name = "", .scale = 1.0 },
        .{ .name = "k", .scale = 1e3 },
        .{ .name = "M", .scale = 1e6 },
        .{ .name = "G", .scale = 1e9 },
        .{ .name = "c", .scale = 1e-2 },
        .{ .name = "m", .scale = 1e-3 },
        .{ .name = "u", .scale = 1e-6 },
        .{ .name = "n", .scale = 1e-9 },
    };

    const abs_val = @abs(u.value);
    if (abs_val == 0) return LengthPowerDisplay{ .scaled_value = 0, .prefix = "", .exp = exp };

    var best = LengthPowerDisplay{ .scaled_value = u.value, .prefix = "", .exp = exp };
    var best_score = std.math.inf(f64);

    for (prefixes) |p| {
        const denom = std.math.pow(f64, p.scale, @as(f64, @floatFromInt(exp)));
        if (denom == 0) continue;
        const scaled = u.value / denom;
        const abs_scaled = @abs(scaled);
        if (abs_scaled == 0) continue;

        var score = @abs(@log10(abs_scaled));
        if (abs_scaled >= 1 and abs_scaled < 1000) score -= 10;
        if (score < best_score) {
            best_score = score;
            best = LengthPowerDisplay{ .scaled_value = scaled, .prefix = p.name, .exp = exp };
        }
    }

    return best;
}

/// Format a MathZig Value as a display string
pub fn formatValue(value: mathzig.Value, allocator: std.mem.Allocator, ctx: ?*mathzig.MathZig) ![]const u8 {
    switch (value.tag) {
        .number => {
            const num = value.data.number;
            var buf: [64]u8 = undefined;

            // Format number nicely
            if (@abs(num - @round(num)) < 1e-10 and @abs(num) < 1e15) {
                // Integer-like: format as integer
                const int_val = @as(i64, @intFromFloat(num));
                const slice = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch return error.FormatError;
                return try allocator.dupe(u8, slice);
            } else {
                // Float
                const slice = std.fmt.bufPrint(&buf, "{d:.6}", .{num}) catch return error.FormatError;
                // Trim trailing zeros
                var end = slice.len;
                while (end > 1 and slice[end - 1] == '0') end -= 1;
                if (end > 0 and slice[end - 1] == '.') end -= 1;
                return try allocator.dupe(u8, slice[0..end]);
            }
        },
        .complex => {
            const c = value.data.complex;
            var buf: [128]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d:.4} + {d:.4}i", .{ c.re, c.im }) catch return error.FormatError;
            return try allocator.dupe(u8, slice);
        },
        .matrix => {
            const m = value.data.matrix;
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "<Matrix {d}x{d}>", .{ m.rows, m.cols }) catch return error.FormatError;
            return try allocator.dupe(u8, slice);
        },
        .unit => {
            const u = value.data.unit;
            var buf: [128]u8 = undefined;

            if (ctx) |mz| {
                const reg = &mz.unit_registry;

                // 1. Try to find the best named unit (handles preferences and exact matches)
                if (reg.findBestUnit(u.info.dimensions)) |best_name| {
                    const unit = reg.units.get(best_name).?;
                    const scaled_val = (u.value - unit.offset) / unit.scale;

                    // Format number nicely with trimming
                    var n_buf: [64]u8 = undefined;
                    const n_slice = std.fmt.bufPrint(&n_buf, "{d:.6}", .{scaled_val}) catch "err";
                    var n_end = n_slice.len;
                    while (n_end > 0 and n_slice[n_end - 1] == '0') n_end -= 1;
                    if (n_end > 0 and n_slice[n_end - 1] == '.') n_end -= 1;
                    if (n_end == 0) n_end = 1;

                    const slice = std.fmt.bufPrint(&buf, "{s} {s}", .{ n_slice[0..n_end], best_name }) catch return error.FormatError;
                    return try allocator.dupe(u8, slice);
                }

                // 2. Fallback to dimension formatting (e.g. m/s)
                if (tryLengthPowerDisplay(u)) |pretty| {
                    if (pretty.exp == 1) {
                        const slice = std.fmt.bufPrint(&buf, "{d:.6} {s}m", .{ pretty.scaled_value, pretty.prefix }) catch return error.FormatError;
                        return try allocator.dupe(u8, slice);
                    } else {
                        const slice = std.fmt.bufPrint(&buf, "{d:.6} {s}m^{d}", .{ pretty.scaled_value, pretty.prefix, pretty.exp }) catch return error.FormatError;
                        return try allocator.dupe(u8, slice);
                    }
                }

                const dim_str = u.info.dimensions.format(allocator) catch null;
                if (dim_str) |ds| {
                    defer allocator.free(ds);
                    const slice = std.fmt.bufPrint(&buf, "{d:.6} {s}", .{ u.value, ds }) catch return error.FormatError;
                    return try allocator.dupe(u8, slice);
                }
            }

            // Fallback to basic format
            const slice = std.fmt.bufPrint(&buf, "{d:.6} [unit]", .{u.value}) catch return error.FormatError;
            return try allocator.dupe(u8, slice);
        },
        .boolean => {
            return try allocator.dupe(u8, if (value.data.boolean) "true" else "false");
        },
        .string => {
            return try allocator.dupe(u8, "<string>");
        },
        .function => {
            return try allocator.dupe(u8, "<function>");
        },
        .predicate => {
            return try allocator.dupe(u8, "<predicate>");
        },
        .array => {
            return try allocator.dupe(u8, "<array>");
        },
        .undefined => {
            return try allocator.dupe(u8, "undefined");
        },
        .null_val => {
            return try allocator.dupe(u8, "null");
        },
        .err => {
            return try allocator.dupe(u8, "<error>");
        },
        .series => {
            const s = value.data.series;
            if (s.len <= 5) {
                var list = std.ArrayListUnmanaged(u8).empty;
                defer list.deinit(allocator);
                const writer = list.writer(allocator);
                try writer.writeAll("Series[");
                for (0..s.len) |i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (s.validity[i] == 0 or std.math.isNan(s.values[i])) {
                        try writer.writeAll("nan");
                    } else {
                        try writer.print("{d:.4}", .{s.values[i]});
                    }
                }
                try writer.writeByte(']');
                return list.toOwnedSlice(allocator);
            } else if (s.len <= 10) {
                var list = std.ArrayListUnmanaged(u8).empty;
                defer list.deinit(allocator);
                const writer = list.writer(allocator);
                try writer.writeAll("Series[");
                for (0..3) |i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (s.validity[i] == 0 or std.math.isNan(s.values[i])) {
                        try writer.writeAll("nan");
                    } else {
                        try writer.print("{d:.4}", .{s.values[i]});
                    }
                }
                try writer.writeAll(", ..., ");
                const last = s.len - 1;
                if (s.validity[last] == 0 or std.math.isNan(s.values[last])) {
                    try writer.writeAll("nan");
                } else {
                    try writer.print("{d:.4}", .{s.values[last]});
                }
                try writer.print("] (len={d})", .{s.len});
                return list.toOwnedSlice(allocator);
            } else {
                return std.fmt.allocPrint(allocator, "<Series len={d} [{d:.2}..{d:.2}]>", .{ s.len, s.min_ts, s.max_ts });
            }
        },
        .record => {
            return try allocator.dupe(u8, "<Record>");
        },
        .slice => {
            return try allocator.dupe(u8, "<slice>");
        },
    }
}

/// Format an error as a display string
fn formatError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidSyntax => "Error: Invalid syntax",
        error.UndefinedVariable => "Error: Undefined variable",
        error.DivisionByZero => "Error: Division by zero",
        error.InvalidOperation => "Error: Invalid operation",
        error.OutOfMemory => "Error: Out of memory",
        error.CompileError => "Error: Compilation failed (check for reserved units like 'h', 'g')",
        else => "Error: Evaluation failed",
    };
}

/// Get the type name for a value
fn getValueType(value: mathzig.Value) []const u8 {
    return switch (value.tag) {
        .number => "number",
        .complex => "complex",
        .matrix => "matrix",
        .unit => "unit",
        .boolean => "boolean",
        .string => "string",
        .function => "function",
        .array => "array",
        .undefined => "undefined",
        .null_val => "null",
        .err => "error",
        .series => "series",
        .predicate => "predicate",
        .record => "record",
        .slice => "slice",
    };
}

/// Check if a string is a valid identifier
fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;

    // First character must be letter or underscore
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    // Rest must be alphanumeric or underscore
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }

    return true;
}

pub fn formatSIDimensions(dims: mathzig.Dimensions, allocator: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    var first = true;
    const fields = [_]struct { name: []const u8, val: i8 }{
        .{ .name = "kg", .val = dims.m },
        .{ .name = "m", .val = dims.l },
        .{ .name = "s", .val = dims.t },
        .{ .name = "A", .val = dims.i },
        .{ .name = "K", .val = dims.k },
        .{ .name = "mol", .val = dims.n },
        .{ .name = "cd", .val = dims.j },
    };

    for (fields) |f| {
        if (f.val != 0) {
            if (!first) try writer.writeByte('*');
            try writer.writeAll(f.name);
            if (f.val != 1) {
                try writer.print("^{d}", .{f.val});
            }
            first = false;
        }
    }

    if (first) try writer.writeAll("1"); // Scalar

    return list.toOwnedSlice(allocator);
}

/// Generate a sparkline string for numeric data
/// Returns a string of Unicode block characters representing the data
pub fn generateSparkline(allocator: std.mem.Allocator, data: []const f64, max_width: usize) ![]const u8 {
    // Unicode block elements for sparklines (each is 3 bytes in UTF-8)
    const blocks = [_][]const u8{ " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

    if (data.len == 0) return try allocator.dupe(u8, "");

    // Find min/max
    var min_val = data[0];
    var max_val = data[0];
    var has_data = false;
    for (data) |v| {
        if (!std.math.isNan(v) and !std.math.isInf(v)) {
            if (!has_data) {
                min_val = v;
                max_val = v;
                has_data = true;
            } else {
                if (v < min_val) min_val = v;
                if (v > max_val) max_val = v;
            }
        }
    }

    if (!has_data) return try allocator.dupe(u8, "");

    const range = max_val - min_val;

    // Build result string (each Unicode char is up to 3 bytes)
    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    if (data.len <= max_width) {
        for (data) |v| {
            const bucket: usize = blk: {
                if (std.math.isNan(v) or std.math.isInf(v)) break :blk 0;
                if (range == 0) break :blk 4; // Middle if all same
                const normalized = (v - min_val) / range;
                break :blk @min(7, @as(usize, @intFromFloat(normalized * 7)));
            };
            try result.appendSlice(allocator, blocks[bucket]);
        }
    } else {
        // Subsample
        for (0..max_width) |i| {
            const start = i * data.len / max_width;
            const end = (i + 1) * data.len / max_width;
            var sum: f64 = 0;
            var count: f64 = 0;
            for (data[start..end]) |v| {
                if (!std.math.isNan(v) and !std.math.isInf(v)) {
                    sum += v;
                    count += 1;
                }
            }
            const v = if (count > 0) sum / count else 0;
            const bucket: usize = blk: {
                if (count == 0) break :blk 0;
                if (range == 0) break :blk 4;
                const normalized = (v - min_val) / range;
                break :blk @min(7, @as(usize, @intFromFloat(normalized * 7)));
            };
            try result.appendSlice(allocator, blocks[bucket]);
        }
    }

    return result.toOwnedSlice(allocator);
}
