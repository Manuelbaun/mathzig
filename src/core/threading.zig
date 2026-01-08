const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch.isWasm();

pub const Pool = if (is_wasm) void else struct {
    pub fn init(_: *@This(), _: anytype) !void {}
    pub fn deinit(_: *@This()) void {}
    pub fn spawn(_: *@This(), func: anytype, args: anytype) !void {
        @call(.auto, func, args);
    }
};
pub const PoolPtr = if (is_wasm) anyopaque else *Pool;

pub const WaitGroup = struct {
    pub fn start(_: *@This()) void {}
    pub fn finish(_: *@This()) void {}
    pub fn wait(_: *@This()) void {}
};

pub fn getCpuCount() u32 {
    if (comptime is_wasm) return 1;
    if (std.c.getenv("MATHZIG_THREADS")) |raw| {
        const value = std.fmt.parseInt(u32, std.mem.sliceTo(raw, 0), 10) catch 0;
        if (value > 0) return value;
    }
    return @as(u32, @intCast(std.Thread.getCpuCount() catch 1));
}

pub fn spawn(pool: anytype, func: anytype, args: anytype) !void {
    if (comptime is_wasm) {
        @call(.auto, func, args);
        return;
    } else {
        return pool.spawn(func, args);
    }
}

pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (comptime is_wasm) return;
    std.debug.print(fmt, args);
}
