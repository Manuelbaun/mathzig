const std = @import("std");
const builtin = @import("builtin");
const mathzig = @import("../mathzig.zig");
const temporal = @import("../units/temporal.zig");
const Series = mathzig.timeseries.Series;
const Value = mathzig.Value;
const Record = mathzig.Record;

const is_wasm = builtin.cpu.arch.isWasm();

pub const CsvError = error{
    FileNotFound,
    InvalidHeader,
    MissingTimeColumn,
    ParseError,
    OutOfMemory,
    FileTooLarge,
};

pub const CsvOptions = struct {
    delimiter: u8 = ',',
    has_header: bool = true,
    limit: ?usize = null,
    offset: usize = 0,
};

const MappingItem = struct { name: []const u8, csv_idx: usize };

/// Reads a CSV file and returns a Record of Series.
pub fn readCsv(
    allocator: std.mem.Allocator,
    metadata_allocator: std.mem.Allocator,
    path: []const u8,
    mapping: *Record,
    options: CsvOptions,
) !*Record {
    if (comptime is_wasm) return error.ParseError;

    const content = readFileAllocC(allocator, path, 100 * 1024 * 1024) catch |err| switch (err) {
        CsvError.FileNotFound => return CsvError.FileNotFound,
        CsvError.FileTooLarge => return CsvError.FileTooLarge,
        else => return CsvError.ParseError,
    };
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');

    // 1. Parse Header
    const first_line = line_iter.next() orelse return CsvError.ParseError;
    
    var csv_headers = std.StringHashMap(usize).init(allocator);
    defer csv_headers.deinit();

    var col_it = std.mem.splitScalar(u8, first_line, options.delimiter);
    var col_idx: usize = 0;
    while (col_it.next()) |col| {
        const trimmed = std.mem.trim(u8, col, " \r\t");
        try csv_headers.put(trimmed, col_idx);
        col_idx += 1;
    }

    // 2. Map Columns
    var active_mappings = std.ArrayListUnmanaged(MappingItem).empty;
    defer active_mappings.deinit(allocator);

    var time_col_idx: ?usize = null;

    var map_iter = mapping.fields.iterator();
    while (map_iter.next()) |entry| {
        const out_name = entry.key_ptr.*;
        const csv_header = entry.value_ptr.*.data.string.toSlice();

        if (csv_headers.get(csv_header)) |idx| {
            if (std.mem.eql(u8, out_name, "time")) {
                time_col_idx = idx;
            } else {
                try active_mappings.append(allocator, .{ .name = out_name, .csv_idx = idx });
            }
        }
    }

    if (time_col_idx == null) return CsvError.MissingTimeColumn;

    // 3. Count Rows
    var count_iter = line_iter;
    var row_count: usize = 0;
    while (count_iter.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len > 0) {
            row_count += 1;
        }
    }

    if (options.limit) |lim| {
        row_count = @min(row_count, lim);
    }

    // 4. Allocate
    const result_record = try Record.init(allocator, metadata_allocator);
    errdefer result_record.release();

    const SeriesMap = struct { name: []const u8, series: *Series, csv_idx: usize };
    const series_list = try allocator.alloc(SeriesMap, active_mappings.items.len);
    defer allocator.free(series_list);

    for (active_mappings.items, 0..) |m, i| {
        const s = try Series.init(allocator, row_count, .Linear, .{});
        series_list[i] = .{ .name = m.name, .series = s, .csv_idx = m.csv_idx };
        try result_record.set(m.name, Value.initSeries(s));
        // result_record.set retained it, so we release our initial reference from init()
        s.release();
    }

    // 5. Parse Data
    var row_idx: usize = 0;
    while (line_iter.next()) |line| {
        if (row_idx >= row_count) break;
        
        const trimmed_line = std.mem.trim(u8, line, " \r\t");
        if (trimmed_line.len == 0) continue;

        var field_it = std.mem.splitScalar(u8, line, options.delimiter);
        var cur_csv_col: usize = 0;
        
        while (field_it.next()) |field| : (cur_csv_col += 1) {
            const trimmed = std.mem.trim(u8, field, " \r\t");
            
            if (cur_csv_col == time_col_idx.?) {
                const ts = temporal.parseTimestamp(trimmed) catch 0;
                for (series_list) |sm| {
                    sm.series.timestamps[row_idx] = ts;
                }
            }

            for (series_list) |sm| {
                if (cur_csv_col == sm.csv_idx) {
                    sm.series.values[row_idx] = std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
                }
            }
        }
        row_idx += 1;
    }

    // Finalize
    for (series_list) |sm| {
        sm.series.len = row_idx;
        sm.series.validate() catch {};
    }

    return result_record;
}

/// Writes a Value to a CSV file. Supports Series, Matrix, and Records.
pub fn writeCsv(
    path: []const u8,
    data: Value,
    options: CsvOptions,
) !void {
    if (comptime is_wasm) return error.ParseError;

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(std.heap.page_allocator);

    if (data.tag == .series) {
        const s = data.data.series;
        if (options.has_header) {
            try out.print(std.heap.page_allocator, "time{c}value\n", .{options.delimiter});
        }
        for (0..s.len) |i| {
            try out.print(std.heap.page_allocator, "{d:.6}{c}{d:.6}\n", .{ s.timestamps[i], options.delimiter, s.values[i] });
        }
    } else if (data.tag == .matrix) {
        const m = data.data.matrix;
        if (options.has_header) {
            for (0..m.cols) |c| {
                if (c > 0) try out.append(std.heap.page_allocator, options.delimiter);
                try out.print(std.heap.page_allocator, "col_{d}", .{c});
            }
            try out.append(std.heap.page_allocator, '\n');
        }
        for (0..m.rows) |r| {
            for (0..m.cols) |c| {
                if (c > 0) try out.append(std.heap.page_allocator, options.delimiter);
                try out.print(std.heap.page_allocator, "{d:.6}", .{m.get(@intCast(r), @intCast(c))});
            }
            try out.append(std.heap.page_allocator, '\n');
        }
    } else if (data.tag == .record) {
        const r = data.data.record;
        var keys = std.ArrayListUnmanaged([]const u8).empty;
        defer keys.deinit(std.heap.page_allocator);

        var iter = r.fields.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.tag == .series or entry.value_ptr.*.tag == .number) {
                try keys.append(std.heap.page_allocator, entry.key_ptr.*);
            }
        }

        if (keys.items.len == 0) return;

        // Sort keys for deterministic output
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        // Header
        if (options.has_header) {
            try out.appendSlice(std.heap.page_allocator, "time");
            for (keys.items) |key| {
                try out.print(std.heap.page_allocator, "{c}{s}", .{ options.delimiter, key });
            }
            try out.appendSlice(std.heap.page_allocator, "\n");
        }

        // Data
        // Find the first series to define length and timestamps
        var first_s: ?*Series = null;
        for (keys.items) |key| {
            const val = r.fields.get(key).?;
            if (val.tag == .series) {
                first_s = val.data.series;
                break;
            }
        }

        if (first_s) |fs| {
            for (0..fs.len) |i| {
                try out.print(std.heap.page_allocator, "{d:.6}", .{fs.timestamps[i]});
                for (keys.items) |key| {
                    const val = r.fields.get(key).?;
                    try out.append(std.heap.page_allocator, options.delimiter);
                    if (val.tag == .series) {
                        const s = val.data.series;
                        const v = if (i < s.len) s.values[i] else std.math.nan(f64);
                        try out.print(std.heap.page_allocator, "{d:.6}", .{v});
                    } else if (val.tag == .number) {
                        try out.print(std.heap.page_allocator, "{d:.6}", .{val.data.number});
                    }
                }
                try out.append(std.heap.page_allocator, '\n');
            }
        }
    } else {
        return error.ParseError; // Unsupported type
    }

    try writeFileC(path, out.items);
}

fn readFileAllocC(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);
    const fp = std.c.fopen(zpath.ptr, "rb") orelse return CsvError.FileNotFound;
    defer _ = std.c.fclose(fp);

    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&tmp, 1, tmp.len, fp);
        if (n == 0) break;
        if (buf.items.len + n > max_size) return CsvError.FileTooLarge;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return try buf.toOwnedSlice(allocator);
}

fn writeFileC(path: []const u8, bytes: []const u8) !void {
    const zpath = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(zpath);
    const fp = std.c.fopen(zpath.ptr, "wb") orelse return CsvError.FileNotFound;
    defer _ = std.c.fclose(fp);
    if (bytes.len == 0) return;
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) return CsvError.ParseError;
}