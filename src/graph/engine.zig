//! Graph expression engines for **VM-native graph evaluator v1**.
//!
//! ## v1 engine decision (do not thrash)
//!
//! **Do NOT vendor zware/bytebox/wasmtime for v1.** Golden acceptance is
//! VM-native graph evaluator == zig_vm for scalar + matrix. MathZig already
//! has a native compiler+VM with full Value types. Pure-Zig interpreters lag
//! Zig 0.16; wasmtime is heavy C ABI.
//!
//! **v1 = in-process MathZig VM** executing `expr` / `const` / `input` nodes
//! (and dual-path `expr` on schema `type: "wasm"` nodes) with the same
//! per-tick protocol as TS (topo → evaluate nodes → host-mediated edge Values).
//! **v1 never loads or executes .wasm bytes.**
//!
//! Schema `wasm` nodes: v1 validates/parses `mathzig:node` when present;
//! execution requires an `expr` dual-path field or returns WasmPhase2Required.
//!
//! ## Port binding
//!
//! Public graph semantics use **real port names** as MathZig variables (no
//! rewrite). The TS multi-module GraphRunner rewrites ports to positional
//! `x`/`y`/`z` only as an **internal AOT boundary detail** — never part of
//! public graph JSON/manifests (see `src/wasm/abi.zig` GRAPH_ALIAS_LIMIT).
//! Graphs that already use x/y/z port names match TS simple cases identically.

const std = @import("std");
const MathZig = @import("../mathzig.zig").MathZig;
const Value = @import("../core/value.zig").Value;
const CompiledExpr = @import("../vm/bytecode.zig").CompiledExpr;
const schema = @import("schema.zig");
const abi = @import("../wasm/abi.zig");

pub const EngineError = error{
    EvalError,
    CompileError,
    WasmPhase2Required,
    /// inputs+params exceeded corpus v1 common limit (GRAPH_ALIAS_LIMIT).
    AliasLimitExceeded,
    /// @deprecated synonym retained for older call sites; prefer AliasLimitExceeded.
    TooManyPorts,
} || error{OutOfMemory};

/// Max inputs+params per expr node (corpus v1 common limit; == abi.GRAPH_ALIAS_LIMIT).
pub const MAX_PORTS: usize = abi.GRAPH_ALIAS_LIMIT;

pub const BoundPort = struct {
    name: []const u8,
    value: Value,
};

/// Engine trait (vtable-free for v1): evaluate an expression with bound ports.
pub const VmEngine = struct {
    ctx: *MathZig,

    pub fn init(ctx: *MathZig) VmEngine {
        return .{ .ctx = ctx };
    }

    /// Bind inputs then params as variables by **real names**, evaluate `expr`.
    /// Returns an owned Value (caller must release).
    pub fn evalExpr(
        self: *VmEngine,
        expr: []const u8,
        inputs: []const BoundPort,
        params: []const schema.ParamEntry,
    ) EngineError!Value {
        if (inputs.len + params.len > MAX_PORTS) return error.AliasLimitExceeded;

        for (inputs) |port| {
            self.ctx.setVariable(port.name, port.value);
        }
        for (params) |p| {
            self.ctx.setNumber(p.name, p.value);
        }

        const result = self.ctx.eval(expr) catch {
            return error.EvalError;
        };
        return result;
    }

    /// Compile once for a node; variables for ports must already exist (or will
    /// be created on first setVariable before evaluate).
    pub fn compile(self: *VmEngine, expr: []const u8) EngineError!*CompiledExpr {
        return self.ctx.compile(expr) catch error.CompileError;
    }

    pub fn evaluateCompiled(self: *VmEngine, expr: *const CompiledExpr) EngineError!Value {
        return self.ctx.evaluate(expr) catch error.EvalError;
    }

    pub fn freeCompiled(self: *VmEngine, expr: *CompiledExpr) void {
        self.ctx.freeExpr(expr);
    }

    pub fn lastError(self: *VmEngine) []const u8 {
        return self.ctx.lastError();
    }
};

test "VmEngine scalar eval with named ports" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    var engine = VmEngine.init(ctx);
    const x = Value.initNumber(7);
    const result = try engine.evalExpr("x * 2 + 1", &.{
        .{ .name = "x", .value = x },
    }, &.{});
    defer result.release();
    try std.testing.expectApproxEqAbs(@as(f64, 15), result.toNumber().?, 1e-12);
}
