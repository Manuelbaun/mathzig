//! Typed load-error shape for untrusted surfaces (task-14 / C3).
//!
//! Mirrors `src/ts/graph/load_error.ts`. C2 load-error goldens consume
//! `code` (as `error_code`) and optional context (`offending`).

const std = @import("std");

/// Trust boundary phase (one of the four surfaces).
pub const Phase = enum {
    dsl,
    wire,
    manifest,
    graph_json,

    pub fn name(self: Phase) []const u8 {
        return switch (self) {
            .dsl => "dsl",
            .wire => "wire",
            .manifest => "manifest",
            .graph_json => "graph_json",
        };
    }
};

pub const Position = struct {
    byte: ?usize = null,
    line: ?u32 = null,
    col: ?u32 = null,
    /// Schema / JSON path (arena-owned when filled by callers).
    path: ?[]const u8 = null,
};

pub const Context = struct {
    node: ?[]const u8 = null,
    edge: ?[]const u8 = null,
    port: ?[]const u8 = null,
    field: ?[]const u8 = null,
};

/// Serializable failure description (not an error set — use with GraphError).
pub const LoadError = struct {
    phase: Phase,
    /// Stable code matching C2 goldens / Zig error names where applicable.
    code: []const u8,
    message: []const u8,
    position: Position = .{},
    context: Context = .{},

    pub fn offending(self: LoadError) ?[]const u8 {
        return self.context.node orelse self.context.edge orelse self.context.port orelse self.context.field;
    }
};

/// Thread-local last load error for surfaces that cannot return a struct through
/// Zig error unions (mirrors runner last_error pattern).
threadlocal var last_buf: [1024]u8 = undefined;
threadlocal var last_len: usize = 0;
threadlocal var last_phase: Phase = .graph_json;
threadlocal var last_code: [64]u8 = undefined;
threadlocal var last_code_len: usize = 0;

pub fn setLast(phase: Phase, code: []const u8, comptime fmt: []const u8, args: anytype) void {
    last_phase = phase;
    const clen = @min(code.len, last_code.len);
    @memcpy(last_code[0..clen], code[0..clen]);
    last_code_len = clen;
    const msg = std.fmt.bufPrint(&last_buf, fmt, args) catch blk: {
        const n = @min(fmt.len, last_buf.len);
        @memcpy(last_buf[0..n], fmt[0..n]);
        break :blk last_buf[0..n];
    };
    last_len = msg.len;
}

pub fn clearLast() void {
    last_len = 0;
    last_code_len = 0;
}

pub fn lastMessage() []const u8 {
    return last_buf[0..last_len];
}

pub fn lastCode() []const u8 {
    return last_code[0..last_code_len];
}

pub fn lastPhase() Phase {
    return last_phase;
}
