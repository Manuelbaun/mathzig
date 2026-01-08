const std = @import("std");
const mathzig = @import("mathzig");
const Node = mathzig.ast.Node;
const NodeType = mathzig.ast.NodeType;

test "AST: basic equality" {
    const allocator = std.testing.allocator;
    
    const n1 = try allocator.create(Node);
    n1.* = .{ .type = .number, .data = .{ .number = 42.0 } };
    defer allocator.destroy(n1);

    const n2 = try allocator.create(Node);
    n2.* = .{ .type = .number, .data = .{ .number = 42.0 } };
    defer allocator.destroy(n2);

    const n3 = try allocator.create(Node);
    n3.* = .{ .type = .number, .data = .{ .number = 43.0 } };
    defer allocator.destroy(n3);

    try std.testing.expect(n1.equals(n2));
    try std.testing.expect(!n1.equals(n3));
}

test "AST: matrix equality" {
    const allocator = std.testing.allocator;
    
    // Matrix 1: [1, 2]
    const m1_el1 = try allocator.create(Node);
    m1_el1.* = .{ .type = .number, .data = .{ .number = 1.0 } };
    const m1_el2 = try allocator.create(Node);
    m1_el2.* = .{ .type = .number, .data = .{ .number = 2.0 } };
    
    const m1_elements = try allocator.alloc(*Node, 2);
    m1_elements[0] = m1_el1;
    m1_elements[1] = m1_el2;

    const m1 = try allocator.create(Node);
    m1.* = .{ .type = .matrix, .data = .{ .matrix = .{ .rows = 1, .cols = 2, .elements = m1_elements } } };
    defer {
        allocator.destroy(m1_el1);
        allocator.destroy(m1_el2);
        allocator.free(m1_elements);
        allocator.destroy(m1);
    }

    // Matrix 2: [1, 2]
    const m2_el1 = try allocator.create(Node);
    m2_el1.* = .{ .type = .number, .data = .{ .number = 1.0 } };
    const m2_el2 = try allocator.create(Node);
    m2_el2.* = .{ .type = .number, .data = .{ .number = 2.0 } };
    
    const m2_elements = try allocator.alloc(*Node, 2);
    m2_elements[0] = m2_el1;
    m2_elements[1] = m2_el2;

    const m2 = try allocator.create(Node);
    m2.* = .{ .type = .matrix, .data = .{ .matrix = .{ .rows = 1, .cols = 2, .elements = m2_elements } } };
    defer {
        allocator.destroy(m2_el1);
        allocator.destroy(m2_el2);
        allocator.free(m2_elements);
        allocator.destroy(m2);
    }

    try std.testing.expect(m1.equals(m2));
}

test "AST: record equality" {
    const allocator = std.testing.allocator;

    // Use the exact field type defined in Node.data.record_literal.fields
    // To avoid type mismatch errors
    const FieldType = @typeInfo(@TypeOf(@as(Node, undefined).data.record_literal.fields)).pointer.child;

    // Record 1: {a: 1}
    const r1_val = try allocator.create(Node);
    r1_val.* = .{ .type = .number, .data = .{ .number = 1.0 } };
    
    const r1_fields = try allocator.alloc(FieldType, 1);
    r1_fields[0] = .{ .key = "a", .value = r1_val };

    const r1 = try allocator.create(Node);
    r1.* = .{ .type = .record_literal, .data = .{ .record_literal = .{ .fields = r1_fields } } };
    defer {
        allocator.destroy(r1_val);
        allocator.free(r1_fields);
        allocator.destroy(r1);
    }

    // Record 2: {a: 1}
    const r2_val = try allocator.create(Node);
    r2_val.* = .{ .type = .number, .data = .{ .number = 1.0 } };
    
    const r2_fields = try allocator.alloc(FieldType, 1);
    r2_fields[0] = .{ .key = "a", .value = r2_val };

    const r2 = try allocator.create(Node);
    r2.* = .{ .type = .record_literal, .data = .{ .record_literal = .{ .fields = r2_fields } } };
    defer {
        allocator.destroy(r2_val);
        allocator.free(r2_fields);
        allocator.destroy(r2);
    }

    try std.testing.expect(r1.equals(r2));
}
