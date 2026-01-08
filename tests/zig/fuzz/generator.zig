const std = @import("std");
const mathzig = @import("mathzig");
const BuiltinFn = mathzig.BuiltinFn;

pub const Generator = struct {
    allocator: std.mem.Allocator,
    random: std.Random,
    max_depth: usize = 5,
    
    const BinOp = enum { add, sub, mul, div, pow, eq, ne, lt, le, gt, ge, and_, or_ };
    const UnOp = enum { neg, not_ };

    pub const Error = error{ OutOfMemory, StackOverflow };

    pub fn init(allocator: std.mem.Allocator, random: std.Random) Generator {
        return .{
            .allocator = allocator,
            .random = random,
        };
    }

    pub fn generateExpression(self: *Generator, depth: usize) Error![]const u8 {
        if (depth >= self.max_depth or self.random.float(f32) < 0.2) {
            return self.generateTerminal();
        }

        const r = self.random.float(f32);
        if (r < 0.4) {
            return self.generateBinaryOp(depth);
        } else if (r < 0.6) {
            return self.generateUnaryOp(depth);
        } else if (r < 0.8) {
            return self.generateFunctionCall(depth);
        } else if (r < 0.9) {
            return self.generateRecordLiteral(depth);
        } else {
            return self.generateMatrixLiteral(depth);
        }
    }

    fn generateTerminal(self: *Generator) Error![]const u8 {
        const r = self.random.float(f32);
        if (r < 0.5) {
            // Number
            return std.fmt.allocPrint(self.allocator, "{d}", .{self.random.float(f64) * 100.0}) catch return error.OutOfMemory;
        } else if (r < 0.8) {
            // Variable (pre-defined in our fuzz context)
            const vars = [_][]const u8{ "x", "y", "z", "s", "m", "pi", "e", "nan", "inf" };
            return self.allocator.dupe(u8, vars[self.random.uintAtMost(usize, vars.len - 1)]) catch return error.OutOfMemory;
        } else {
            // Complex or specialized terminal
            if (self.random.boolean()) {
                return self.allocator.dupe(u8, "i") catch return error.OutOfMemory;
            } else {
                return std.fmt.allocPrint(self.allocator, "{d}i", .{self.random.float(f64) * 10.0}) catch return error.OutOfMemory;
            }
        }
    }

    fn generateBinaryOp(self: *Generator, depth: usize) Error![]const u8 {
        const ops = std.meta.tags(BinOp);
        const op = ops[self.random.uintAtMost(usize, ops.len - 1)];
        const lhs = try self.generateExpression(depth + 1);
        const rhs = try self.generateExpression(depth + 1);
        
        const op_str = switch (op) {
            .add => "+", .sub => "-", .mul => "*", .div => "/", .pow => "^",
            .eq => "==", .ne => "!=", .lt => "<", .le => "<=", .gt => ">", .ge => ">=",
            .and_ => "and", .or_ => "or",
        };

        return std.fmt.allocPrint(self.allocator, "({s} {s} {s})", .{ lhs, op_str, rhs }) catch return error.OutOfMemory;
    }

    fn generateUnaryOp(self: *Generator, depth: usize) Error![]const u8 {
        const ops = std.meta.tags(UnOp);
        const op = ops[self.random.uintAtMost(usize, ops.len - 1)];
        const expr = try self.generateExpression(depth + 1);
        
        const op_str = switch (op) {
            .neg => "-",
            .not_ => "not ",
        };

        return std.fmt.allocPrint(self.allocator, "({s}{s})", .{ op_str, expr }) catch return error.OutOfMemory;
    }

    fn generateFunctionCall(self: *Generator, depth: usize) Error![]const u8 {
        const funcs = [_]struct { name: []const u8, args: usize }{
            .{ .name = "abs", .args = 1 },
            .{ .name = "sqrt", .args = 1 },
            .{ .name = "sin", .args = 1 },
            .{ .name = "cos", .args = 1 },
            .{ .name = "log", .args = 1 },
            .{ .name = "exp", .args = 1 },
            .{ .name = "min", .args = 2 },
            .{ .name = "max", .args = 2 },
            .{ .name = "mean", .args = 1 },
            .{ .name = "sum", .args = 1 },
            .{ .name = "sma", .args = 2 },
            .{ .name = "ema", .args = 2 },
            .{ .name = "bollinger", .args = 3 },
            .{ .name = "macd", .args = 4 },
        };

        const f = funcs[self.random.uintAtMost(usize, funcs.len - 1)];
        var args_str = std.ArrayListUnmanaged(u8).empty;
        defer args_str.deinit(self.allocator);
        
        try args_str.appendSlice(self.allocator, f.name);
        try args_str.append(self.allocator, '(');

        for (0..f.args) |i| {
            const arg = try self.generateExpression(depth + 1);
            try args_str.appendSlice(self.allocator, arg);
            if (i < f.args - 1) try args_str.appendSlice(self.allocator, ", ");
        }
        try args_str.append(self.allocator, ')');

        // Occasionally add member access to function result if it might be a record
        if (std.mem.eql(u8, f.name, "bollinger") or std.mem.eql(u8, f.name, "macd")) {
            if (self.random.boolean()) {
                const fields = if (std.mem.eql(u8, f.name, "bollinger"))
                    [_][]const u8{ "upper", "middle", "lower" }
                else
                    [_][]const u8{ "macd", "signal", "histogram" };
                
                try args_str.append(self.allocator, '.');
                try args_str.appendSlice(self.allocator, fields[self.random.uintAtMost(usize, fields.len - 1)]);
            }
        }

        return args_str.toOwnedSlice(self.allocator);
    }

    fn generateRecordLiteral(self: *Generator, depth: usize) Error![]const u8 {
        const num_fields = self.random.uintAtMost(usize, 3) + 1;
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        
        try buf.append(self.allocator, '{');

        for (0..num_fields) |i| {
            var field_name_buf: [16]u8 = undefined;
            const field_name = std.fmt.bufPrint(&field_name_buf, "f{d}: ", .{i}) catch unreachable;
            try buf.appendSlice(self.allocator, field_name);
            const val = try self.generateExpression(depth + 1);
            try buf.appendSlice(self.allocator, val);
            if (i < num_fields - 1) try buf.appendSlice(self.allocator, ", ");
        }
        try buf.append(self.allocator, '}');
        
        // Occasionally add member access
        if (self.random.boolean()) {
            var member_buf: [16]u8 = undefined;
            const member_name = std.fmt.bufPrint(&member_buf, ".f{d}", .{self.random.uintLessThan(usize, num_fields)}) catch unreachable;
            try buf.appendSlice(self.allocator, member_name);
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn generateMatrixLiteral(self: *Generator, depth: usize) Error![]const u8 {
        const rows = self.random.uintAtMost(usize, 2) + 1;
        const cols = self.random.uintAtMost(usize, 2) + 1;
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        
        try buf.append(self.allocator, '[');

        for (0..rows) |r| {
            for (0..cols) |c| {
                const val = try self.generateExpression(depth + 1);
                try buf.appendSlice(self.allocator, val);
                if (c < cols - 1) try buf.appendSlice(self.allocator, ", ");
            }
            if (r < rows - 1) try buf.appendSlice(self.allocator, "; ");
        }
        try buf.append(self.allocator, ']');
        return buf.toOwnedSlice(self.allocator);
    }
};
