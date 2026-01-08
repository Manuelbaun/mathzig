//! Process-wide live refcounted-handle counters (task-16 / C5).
//!
//! Incremented on successful Matrix / Series / Record construction and
//! decremented in deinit (refcount → 0). Test-only observability via
//! GraphRunner.debugStats() and direct reads — not a public product API.

const std = @import("std");

pub var live_matrix: std.atomic.Value(usize) = .init(0);
pub var live_series: std.atomic.Value(usize) = .init(0);
pub var live_record: std.atomic.Value(usize) = .init(0);

pub fn incMatrix() void {
    _ = live_matrix.fetchAdd(1, .monotonic);
}
pub fn decMatrix() void {
    _ = live_matrix.fetchSub(1, .monotonic);
}
pub fn incSeries() void {
    _ = live_series.fetchAdd(1, .monotonic);
}
pub fn decSeries() void {
    _ = live_series.fetchSub(1, .monotonic);
}
pub fn incRecord() void {
    _ = live_record.fetchAdd(1, .monotonic);
}
pub fn decRecord() void {
    _ = live_record.fetchSub(1, .monotonic);
}

pub fn snapshot() struct { matrix: usize, series: usize, record: usize, total: usize } {
    const m = live_matrix.load(.monotonic);
    const s = live_series.load(.monotonic);
    const r = live_record.load(.monotonic);
    return .{ .matrix = m, .series = s, .record = r, .total = m + s + r };
}
