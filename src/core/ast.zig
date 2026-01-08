const std = @import("std");
const Value = @import("value.zig").Value;
const Opcode = @import("../vm/bytecode.zig").Opcode;

pub const NodeType = enum {
    number,
    boolean,
    variable,
    string,
    unit,
    binary_op,
    unary_op,
    function_call,
    polynomial,
    matrix,
    ternary,
    complex,
    record_literal,
    member_access,
    dynamic_access,
    function_def,
    slice,
    sequence, // Semicolon-separated expressions
    while_loop,
    for_loop,
};

pub const Node = struct {
    type: NodeType,
    start: u32 = 0,
    data: union {
        number: f64,
        boolean: bool,
        variable: []const u8,
        string: []const u8,
        unit: struct { value: f64 = 0, scale: f64, offset: f64, dimensions: @import("../units/unit_registry.zig").Dimensions, name: ?[]const u8 = null },
        binary_op: struct { op: Opcode, lhs: *Node, rhs: *Node },
        unary_op: struct { op: Opcode, expr: *Node },
        member_access: struct { object: *Node, field: []const u8 },
        dynamic_access: struct { object: *Node, keys: []*Node },
        function_call: struct { 
            name: []const u8, 
            args: []*Node, 
            arg_names: ?[]?[]const u8 = null, // Array of optional names for each argument
            predicate: ?*Node = null 
        },
        polynomial: struct { var_name: []const u8, coeffs: []f64 },
        matrix: struct { rows: u32, cols: u32, elements: []*Node },
        ternary: struct { cond: *Node, then_expr: *Node, else_expr: *Node },
        complex: struct { re: f64, im: f64 },
        record_literal: struct { fields: []const struct { key: []const u8, value: *Node } },
        function_def: struct {
            name: []const u8,
            params: [][]const u8,
            body: *Node,
        },
        slice: struct { start: ?*Node = null, end: ?*Node = null, step: ?*Node = null },
        sequence: struct { exprs: []*Node }, // All expressions; last one is the result
        while_loop: struct { cond: *Node, body: *Node },
        for_loop: struct { init: ?*Node, cond: ?*Node, post: ?*Node, body: *Node },
    },
    
    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.type) {
            .binary_op => {
                self.data.binary_op.lhs.deinit(allocator);
                self.data.binary_op.rhs.deinit(allocator);
            },
            .unary_op => {
                self.data.unary_op.expr.deinit(allocator);
            },
            .member_access => {
                self.data.member_access.object.deinit(allocator);
            },
            .dynamic_access => {
                self.data.dynamic_access.object.deinit(allocator);
                for (self.data.dynamic_access.keys) |k| {
                    k.deinit(allocator);
                }
                allocator.free(self.data.dynamic_access.keys);
            },
            .function_call => {
                for (self.data.function_call.args) |arg| {
                    arg.deinit(allocator);
                }
                if (self.data.function_call.predicate) |p| {
                    p.deinit(allocator);
                }
                allocator.free(self.data.function_call.args);
                if (self.data.function_call.arg_names) |names| {
                    allocator.free(names);
                }
            },
            .polynomial => {
                allocator.free(self.data.polynomial.coeffs);
            },
            .matrix => {
                for (self.data.matrix.elements) |el| {
                    el.deinit(allocator);
                }
                allocator.free(self.data.matrix.elements);
            },
            .ternary => {
                self.data.ternary.cond.deinit(allocator);
                self.data.ternary.then_expr.deinit(allocator);
                self.data.ternary.else_expr.deinit(allocator);
            },
            .record_literal => {
                for (self.data.record_literal.fields) |field| {
                    field.value.deinit(allocator);
                }
                allocator.free(self.data.record_literal.fields);
            },
            .function_def => {
                allocator.free(self.data.function_def.params);
                self.data.function_def.body.deinit(allocator);
            },
            .slice => {
                if (self.data.slice.start) |s| s.deinit(allocator);
                if (self.data.slice.end) |e| e.deinit(allocator);
                if (self.data.slice.step) |s| s.deinit(allocator);
            },
            .sequence => {
                for (self.data.sequence.exprs) |expr| {
                    expr.deinit(allocator);
                }
                allocator.free(self.data.sequence.exprs);
            },
            .while_loop => {
                self.data.while_loop.cond.deinit(allocator);
                self.data.while_loop.body.deinit(allocator);
            },
            .for_loop => {
                if (self.data.for_loop.init) |n| n.deinit(allocator);
                if (self.data.for_loop.cond) |n| n.deinit(allocator);
                if (self.data.for_loop.post) |n| n.deinit(allocator);
                self.data.for_loop.body.deinit(allocator);
            },
            else => {},
        }
        allocator.destroy(self);
    }

    pub fn equals(self: *const Node, other: *const Node) bool {
        if (self.type != other.type) return false;
        switch (self.type) {
            .number => return self.data.number == other.data.number,
            .boolean => return self.data.boolean == other.data.boolean,
            .variable => return std.mem.eql(u8, self.data.variable, other.data.variable),
            .string => return std.mem.eql(u8, self.data.string, other.data.string),
            .unit => return self.data.unit.scale == other.data.unit.scale and self.data.unit.dimensions.equals(other.data.unit.dimensions),
            .binary_op => return self.data.binary_op.op == other.data.binary_op.op and 
                                self.data.binary_op.lhs.equals(other.data.binary_op.lhs) and 
                                self.data.binary_op.rhs.equals(other.data.binary_op.rhs),
            .unary_op => return self.data.unary_op.op == other.data.unary_op.op and self.data.unary_op.expr.equals(other.data.unary_op.expr),
            .member_access => return std.mem.eql(u8, self.data.member_access.field, other.data.member_access.field) and
                                    self.data.member_access.object.equals(other.data.member_access.object),
            .dynamic_access => {
                if (!self.data.dynamic_access.object.equals(other.data.dynamic_access.object)) return false;
                if (self.data.dynamic_access.keys.len != other.data.dynamic_access.keys.len) return false;
                for (self.data.dynamic_access.keys, other.data.dynamic_access.keys) |k1, k2| {
                    if (!k1.equals(k2)) return false;
                }
                return true;
            },
            .function_call => {
                if (!std.mem.eql(u8, self.data.function_call.name, other.data.function_call.name)) return false;
                if (self.data.function_call.args.len != other.data.function_call.args.len) return false;
                for (self.data.function_call.args, other.data.function_call.args) |a, b| {
                    if (!a.equals(b)) return false;
                }
                
                // Compare arg_names
                if (self.data.function_call.arg_names == null and other.data.function_call.arg_names == null) {
                    // OK
                } else if (self.data.function_call.arg_names != null and other.data.function_call.arg_names != null) {
                    const names_a = self.data.function_call.arg_names.?;
                    const names_b = other.data.function_call.arg_names.?;
                    if (names_a.len != names_b.len) return false;
                    for (names_a, names_b) |na, nb| {
                        if (na == null and nb == null) continue;
                        if (na != null and nb != null) {
                            if (!std.mem.eql(u8, na.?, nb.?)) return false;
                        } else return false;
                    }
                } else return false;

                if (self.data.function_call.predicate == null and other.data.function_call.predicate == null) return true;
                if (self.data.function_call.predicate != null and other.data.function_call.predicate != null) {
                    return self.data.function_call.predicate.?.equals(other.data.function_call.predicate.?);
                }
                return false;
            },
            .polynomial => {
                if (!std.mem.eql(u8, self.data.polynomial.var_name, other.data.polynomial.var_name)) return false;
                if (self.data.polynomial.coeffs.len != other.data.polynomial.coeffs.len) return false;
                return std.mem.eql(f64, self.data.polynomial.coeffs, other.data.polynomial.coeffs);
            },
            .ternary => {
                return self.data.ternary.cond.equals(other.data.ternary.cond) and
                       self.data.ternary.then_expr.equals(other.data.ternary.then_expr) and
                       self.data.ternary.else_expr.equals(other.data.ternary.else_expr);
            },
            .complex => {
                return self.data.complex.re == other.data.complex.re and self.data.complex.im == other.data.complex.im;
            },
            .matrix => {
                if (self.data.matrix.rows != other.data.matrix.rows or self.data.matrix.cols != other.data.matrix.cols) return false;
                if (self.data.matrix.elements.len != other.data.matrix.elements.len) return false;
                for (self.data.matrix.elements, other.data.matrix.elements) |a, b| {
                    if (!a.equals(b)) return false;
                }
                return true;
            },
            .record_literal => {
                if (self.data.record_literal.fields.len != other.data.record_literal.fields.len) return false;
                for (self.data.record_literal.fields, other.data.record_literal.fields) |a, b| {
                    if (!std.mem.eql(u8, a.key, b.key)) return false;
                    if (!a.value.equals(b.value)) return false;
                }
                return true;
            },
            .function_def => {
                if (!std.mem.eql(u8, self.data.function_def.name, other.data.function_def.name)) return false;
                if (self.data.function_def.params.len != other.data.function_def.params.len) return false;
                for (self.data.function_def.params, other.data.function_def.params) |p1, p2| {
                    if (!std.mem.eql(u8, p1, p2)) return false;
                }
                return self.data.function_def.body.equals(other.data.function_def.body);
            },
            .slice => {
                if (self.data.slice.start) |s| {
                    if (other.data.slice.start) |os| {
                        if (!s.equals(os)) return false;
                    } else return false;
                } else if (other.data.slice.start != null) return false;

                if (self.data.slice.end) |e| {
                    if (other.data.slice.end) |oe| {
                        if (!e.equals(oe)) return false;
                    } else return false;
                } else if (other.data.slice.end != null) return false;

                if (self.data.slice.step) |st| {
                    if (other.data.slice.step) |ost| {
                        if (!st.equals(ost)) return false;
                    } else return false;
                } else if (other.data.slice.step != null) return false;

                return true;
            },
            .sequence => {
                if (self.data.sequence.exprs.len != other.data.sequence.exprs.len) return false;
                for (self.data.sequence.exprs, other.data.sequence.exprs) |a, b| {
                    if (!a.equals(b)) return false;
                }
                return true;
            },
            .while_loop => {
                return self.data.while_loop.cond.equals(other.data.while_loop.cond) and
                       self.data.while_loop.body.equals(other.data.while_loop.body);
            },
            .for_loop => {
                // TODO: Implement thorough equality check for for_loop if needed
                return false;
            },
        }
    }
};
