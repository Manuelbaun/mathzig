//! WASM AOT ABI — the single source of truth for the env-import contract
//! and boundary value encodings of AOT-compiled modules.
//!
//! Everything crossing the wasm boundary is a single `f64` on the wire; this
//! module records what that f64 MEANS per builtin so codegen, the generated
//! host env, and graph tooling agree. The wire signatures stay all-f64 (the
//! table adds meaning, not new wasm value types).
//!
//! Consumers:
//! - `WasmCompiler.registerBuiltin(Where)` — rejects builtins the table marks
//!   as unsupported instead of silently synthesizing an import.
//! - The bindings generator (`zig build gen-bindings`) — emits
//!   `src/bindings/generated/aot_abi.json` for the TS host env.
//! - The `mathzig.abi` custom section emitted into every compiled module.
//!
//! Boundary encodings (little-endian, in the module's linear memory unless
//! noted):
//! - matrix:    ptr -> [i32 rows][i32 cols][f64 data... row-major]
//! - complex:   ptr -> [f64 re][f64 im]
//! - record:    ptr -> [u32 len][u32 pad] then per entry
//!              [f64 value][u32 key_offset (data segment)][u8 value_kind + 3B pad]
//! - string (input):  ptr -> NUL-terminated bytes in the data segment
//! - string (return): ptr -> [u32 len][bytes utf-8] in linear memory (length-
//!   prefixed; modules with `result_tag=string` use this layout for eval)
//! - predicate: ptr -> [u32 op][u32 field][f64 constant][i32 left][i32 right]
//!              (24 bytes; left/right are predicate ptrs or -1)
//! - series (linear memory / Tier 4 standalone):
//!              ptr -> [u32 len][u32 pad][f64 timestamps × len][f64 values × len]
//!              (see `SeriesLayout`; total bytes = 8 + 16*len)
//! - series (env-import hybrid): HOST-side handle, f64 >= SERIES_HANDLE_BASE.
//!              The module's `mathzig.abi` custom section field `series_repr`
//!              is `"host_handle"` or `"linear_memory"` so hosts know which
//!              representation the compiled module uses.
//! - unit (result): SI magnitude as f64 on the wire; dimensional metadata is
//!              carried in the custom section as `result_unit` so hosts can
//!              re-attach the unit. Intermediate units stay SI-normalized
//!              f64s with compile-time dimension tracking (static path) or
//!              are delegated via `mathzig_call_builtin` (dynamic path).
//!
//! The arg/ret kinds below are descriptive wire semantics distilled from the
//! reference implementations (VM.callBuiltin / the parity host env); they are
//! refined as the delegated host env (workstream A1) is built out.

const std = @import("std");
const list_writer = @import("list_writer.zig");
const bytecode = @import("../vm/bytecode.zig");
const BuiltinFn = bytecode.BuiltinFn;

pub const ABI_VERSION: u32 = 1;

/// Name of the custom section carrying the module's ABI manifest.
pub const CUSTOM_SECTION_NAME = "mathzig.abi";

/// Host-side handle bases (values, not pointers). Kept here so the TS host
/// stops hard-coding them.
pub const SERIES_HANDLE_BASE: f64 = 1e9;
pub const RECORD_HANDLE_BASE: f64 = 1.5e9;
pub const MATRIX_HANDLE_BASE: f64 = 2e9;

/// How a compiled module represents series values on the wire.
/// Env-import mode currently uses host handles; standalone Tier 4 uses
/// linear memory. The custom section always records which one is active.
pub const SeriesRepresentation = enum(u8) {
    /// f64 >= SERIES_HANDLE_BASE, data lives in the host env's seriesStore.
    host_handle = 0,
    /// f64 pointer into module linear memory (SeriesLayout).
    linear_memory = 1,

    pub fn jsonName(self: SeriesRepresentation) []const u8 {
        return switch (self) {
            .host_handle => "host_handle",
            .linear_memory => "linear_memory",
        };
    }
};

// ── Graph port semantics (task-13 / C2) ──────────────────────────────────────
//
// Public graph semantics use **real manifest / GraphDefinition port names**
// on edges, in JSON, and in user-facing error messages.
//
// The positional rewrite of input/param names onto `x`/`y`/`z` is an
// **internal TypeScript AOT-lowering detail** for the multi-module
// GraphRunner wasm boundary (`src/ts/graph/runner.ts` `rewriteExprForBoundary`).
// It must never leak into graph JSON, node manifests, or public error text as
// the port model.
//
// Combined inputs + params per expr node (corpus v1 common limit):
// `GRAPH_ALIAS_LIMIT = 3`. Both TS GraphRunner and the VM-native graph
// evaluator reject excess with the named error **`AliasLimitExceeded`**.
// Raising TS AOT arity beyond three is a separate follow-up.
//
// Three execution modes (reported distinctly; do not conflate):
//   (a) ts_wasm      — TS GraphRunner (per-node AOT wasm modules)
//   (b) native_vm    — VM-native graph evaluator v1 (in-process MathZig VM)
//   (c) native_wasm  — pure-wasm node interpreter (phase-2; expected-skip)
// Mode (c) appears in the cross-runner harness only as an expected-skip bucket
// with exact skip IDs (`phase2_native_wasm_interpreter`).

/// Corpus v1 common limit: inputs+params combined per expr node.
/// Enforced by TS GraphRunner and VM-native evaluator as `AliasLimitExceeded`.
pub const GRAPH_ALIAS_LIMIT: usize = 3;

// ── Adversarial input limits (task-14 / C3) ──────────────────────────────────
//
// Documented caps for the four untrusted surfaces. Enforcement is
// **pre-allocation**: a hostile u32 length is rejected by bound-check against
// module memory size and/or these caps — never used as an alloc size.
//
// Surfaces:
//   S1 DSL parser        (`src/ts/graph/dsl.ts`) — JS string (+ optional UTF-8 bytes)
//   S2 wire-decode host  (`src/ts/aot_env.ts` readers)
//   S3 manifest/section  (`src/graph/manifest.zig` + TS section readers)
//   S4 graph JSON loader (`parseGraphDefinitionJson` / native `parseGraphDefinition`)
//
// Keep in sync with `src/ts/graph/limits.ts`.

/// Max source bytes for DSL text / graph JSON / manifest JSON (1 MiB).
pub const MAX_SOURCE_BYTES: usize = 1 << 20;
/// Max identifier / port / node-id length in chars (UTF-16 code units on TS).
pub const MAX_IDENTIFIER_LEN: usize = 256;
/// Max tokens produced by the graph DSL tokenizer.
pub const MAX_TOKEN_COUNT: usize = 100_000;
/// Max brace/bracket/paren nesting depth in DSL and JSON structural walks.
pub const MAX_NESTING_DEPTH: usize = 64;
/// Max matrix elements (rows*cols) accepted from wire or graph const values.
pub const MAX_MATRIX_ELEMENTS: usize = 1 << 20;
/// Max matrix payload bytes (elements × f64).
pub const MAX_MATRIX_BYTES: usize = MAX_MATRIX_ELEMENTS * 8;
/// Max record field entries on the wire or in graph values.
pub const MAX_RECORD_ENTRIES: usize = 4096;
/// Max series samples (timestamps/values length).
pub const MAX_SERIES_SAMPLES: usize = 1 << 20;
/// Max nodes in one GraphDefinition.
pub const MAX_GRAPH_NODES: usize = 10_000;
/// Max edges in one GraphDefinition.
pub const MAX_GRAPH_EDGES: usize = 50_000;
/// Max topo / dependency depth (guards pathological DAGs).
pub const MAX_GRAPH_DEPTH: usize = 10_000;
/// Max length-prefixed string payload from wasm linear memory.
pub const MAX_WIRE_STRING_BYTES: usize = 1 << 20;

/// Single definition of the Tier-4 / node-graph series linear-memory layout.
///
/// ```
/// ptr -> [u32 len][u32 pad=0][f64 timestamps × len][f64 values × len]
/// ```
///
/// - `len` is the number of samples.
/// - `pad` is reserved (0); keeps timestamps 8-byte aligned after the header.
/// - timestamps occupy bytes `[8, 8 + 8*len)`.
/// - values occupy bytes `[8 + 8*len, 8 + 16*len)`.
///
/// Size in bytes: `header_bytes + 2 * len * @sizeOf(f64)` = `8 + 16*len`.
/// This is the only series layout — graph value_transfer and standalone Tier 4
/// must both use these offsets (do not re-define elsewhere).
pub const SeriesLayout = struct {
    pub const header_bytes: u32 = 8;
    pub const len_offset: u32 = 0;
    pub const pad_offset: u32 = 4;
    pub const timestamps_offset: u32 = 8;

    pub fn valuesOffset(len: u32) u32 {
        return timestamps_offset + len * 8;
    }

    pub fn totalBytes(len: u32) u32 {
        return header_bytes + len * 16;
    }

    /// JSON fragment describing the layout (for custom sections / docs).
    pub const json_shape =
        \\{"header":"u32_len+u32_pad","timestamps":"f64[len]","values":"f64[len]","total_bytes":"8+16*len"}
    ;
};

/// Unit annotation embedded in `mathzig.abi` when the eval result is a unit
/// quantity. The wire value is the SI-normalized magnitude; hosts re-attach
/// dimensions/name/scale from this annotation.
pub const ResultUnitAnnotation = struct {
    /// SI base exponents: [mass, length, time, current, temp, substance, lum].
    dims: [7]i8 = .{ 0, 0, 0, 0, 0, 0, 0 },
    /// Scale factor relative to SI base (e.g. cm → 0.01). 1.0 for pure SI.
    scale: f64 = 1.0,
    /// Additive offset for affine units (degC/degF). Usually 0.
    offset: f64 = 0.0,
    /// Preferred display name when known (e.g. "m", "cm"); null if derived.
    name: ?[]const u8 = null,
};

/// Semantic kind of one f64-encoded wire value.
pub const WireKind = enum(u8) {
    number = 0,
    boolean = 1,
    matrix_ptr = 2,
    complex_ptr = 3,
    record_ptr = 4,
    string_ptr = 5,
    series_handle = 6,
    predicate_ptr = 7,
    /// Kind depends on inputs at runtime (e.g. aggregations accept a series
    /// handle or a matrix ptr; `last` returns whatever the series holds).
    any = 8,
};

/// Which standalone (`-s`) tier a builtin belongs to — i.e. when a
/// self-contained generated wasm body is (or will be) available.
/// `.unsupported` builtins require the env import in standalone mode and
/// therefore fail standalone compilation.
pub const StandaloneTier = enum(u8) {
    /// Pure scalar math — generated libm-style body (exp/log/sin exist today).
    scalar = 1,
    /// Matrix helpers operating on linear memory.
    matrix = 2,
    /// In-wasm ODE stepping.
    ode = 3,
    /// Series in linear memory.
    series = 4,
    unsupported = 255,
};

pub const Signature = struct {
    /// Canonical argument kinds (max-arity form). The wire signature of an
    /// import is still all-f64 with the arity the compiler saw at the call
    /// site; this describes what those f64s mean positionally. For variadic
    /// builtins, extra trailing args repeat the last kind.
    args: []const WireKind,
    ret: WireKind,
    /// Accepts fewer args than `args.len` (e.g. log(x) / log(x, base)).
    min_args: u8,
    /// May be emitted as `env.<name>_where` with a trailing predicate_ptr.
    where_capable: bool = false,
    tier: StandaloneTier = .unsupported,
    /// True when the AOT path must not import this builtin at all
    /// (side-effectful host I/O whose semantics can't cross the boundary).
    importable: bool = true,
};

const n = WireKind.number;
const b = WireKind.boolean;
const mat = WireKind.matrix_ptr;
const cpx = WireKind.complex_ptr;
const rec = WireKind.record_ptr;
const str = WireKind.string_ptr;
const ser = WireKind.series_handle;
const any = WireKind.any;

fn sig(args: []const WireKind, ret: WireKind, min_args: u8, tier: StandaloneTier) Signature {
    return .{ .args = args, .ret = ret, .min_args = min_args, .tier = tier };
}

fn aggSig(args: []const WireKind, ret: WireKind, min_args: u8) Signature {
    return .{ .args = args, .ret = ret, .min_args = min_args, .where_capable = true };
}

/// The exhaustive per-builtin signature table. No `else` branch on purpose:
/// adding a BuiltinFn member without categorizing it here is a compile error.
pub fn signature(f: BuiltinFn) Signature {
    return switch (f) {
        // Scalar math (1-arg unless noted)
        .abs, .cbrt, .exp, .log10, .log2, .square, .cube, .log1p, .expm1 => sig(&.{n}, n, 1, .scalar),
        .sqrt => sig(&.{ n, n }, any, 1, .scalar), // sqrt(-x) is complex on the reference path
        .log, .nthRoot => sig(&.{ n, n }, n, 1, .scalar),
        .sin, .cos, .tan, .asin, .acos, .atan => sig(&.{n}, n, 1, .scalar),
        .atan2, .hypot => sig(&.{ n, n }, n, 2, .scalar),
        .sinh, .cosh, .tanh, .sec, .csc, .cot, .asec, .acsc, .acot => sig(&.{n}, n, 1, .scalar),
        .asinh, .acosh, .atanh, .sech, .csch, .coth, .asech, .acsch, .acoth => sig(&.{n}, n, 1, .scalar),
        .floor, .ceil, .trunc, .sign => sig(&.{n}, n, 1, .scalar),
        .round => sig(&.{ n, n }, n, 1, .scalar), // round(x) / round(x, decimals)
        .clamp => sig(&.{ n, n, n }, n, 3, .scalar),
        .factorial, .gamma, .lgamma, .erf => sig(&.{n}, n, 1, .scalar),
        .combinations, .permutations => sig(&.{ n, n }, n, 2, .scalar),
        .gcd, .lcm => sig(&.{ n, n }, n, 2, .scalar),
        .isPrime => sig(&.{n}, b, 1, .scalar),
        .random => sig(&.{ n, n }, n, 0, .unsupported), // host RNG
        .randomInt => sig(&.{ n, n }, n, 1, .unsupported),
        .pickRandom => sig(&.{mat}, n, 1, .unsupported),

        // min/max/norm accept scalars, matrices or series depending on shape
        .min, .max => aggSig(&.{ any, any }, n, 1),
        .norm => sig(&.{any}, n, 1, .matrix),

        // Complex accessors — accept number or complex, return number
        .re, .im, .arg => sig(&.{cpx}, n, 1, .unsupported),
        .conj => sig(&.{cpx}, cpx, 1, .unsupported),

        // Matrix / linear algebra
        .det, .trace => sig(&.{mat}, n, 1, .matrix),
        .inv, .transpose => sig(&.{mat}, mat, 1, .matrix),
        .gemv => sig(&.{ mat, mat }, mat, 2, .matrix),
        .size => sig(&.{any}, rec, 1, .unsupported),
        .dot => sig(&.{ mat, mat }, n, 2, .matrix),
        .cross => sig(&.{ mat, mat }, mat, 2, .matrix),
        .reshape => sig(&.{ mat, n, n }, mat, 3, .matrix),
        .flatten => sig(&.{mat}, mat, 1, .matrix),
        .concat => sig(&.{ any, any, n }, any, 2, .matrix),
        .diag => sig(&.{mat}, mat, 1, .matrix),
        .identity => sig(&.{n}, mat, 1, .matrix),
        .zeros, .ones => sig(&.{ n, n }, mat, 1, .matrix),

        // Aggregations — series handle or matrix ptr in, scalar out;
        // where-capable (predicate trailing arg via env.<name>_where)
        .mean, .sum, .count, .median, .mad, .prod => aggSig(&.{any}, n, 1),
        // std/variance take an optional mode string ("biased"/"unbiased")
        .std, .variance => aggSig(&.{ any, str }, n, 1),
        .twa, .duration => aggSig(&.{ser}, n, 1),
        .agg_range => aggSig(&.{ser}, n, 1),

        // Units
        .conv => sig(&.{ any, any }, any, 2, .unsupported),
        .number => sig(&.{ any, any }, n, 1, .unsupported),
        .create_unit => .{ .args = &.{ str, any }, .ret = any, .min_args = 2, .importable = false },
        .config => .{ .args = &.{ str, str }, .ret = n, .min_args = 2, .importable = false },

        // I/O and testing — host side effects; never importable from AOT code
        .read_csv => .{ .args = &.{ str, rec }, .ret = any, .min_args = 1 },
        .write_csv => .{ .args = &.{ str, ser }, .ret = n, .min_args = 2, .importable = false },
        .assert => sig(&.{ any, any }, b, 1, .unsupported),

        // Cumulative / rolling — series in, series out
        // diff/pct_change require the period argument (see timeseries_bindings.zig).
        .cumsum, .cummax, .cummin, .dropna => sig(&.{ser}, ser, 1, .series),
        .diff, .pct_change => sig(&.{ ser, n }, ser, 2, .series),
        .rolling_sum, .rolling_mean, .rolling_min, .rolling_max, .rolling_count, .rolling_stddev => sig(&.{ ser, n }, ser, 2, .series),
        .fillna => sig(&.{ ser, any }, ser, 1, .series), // 2nd arg: fill value OR mode string
        .clip => sig(&.{ ser, n, n }, ser, 3, .series),

        // Time-series
        .series => sig(&.{ mat, mat }, ser, 1, .series),
        // derivative/integrate always return a series (calculus.zig).
        .derivative, .integrate => sig(&.{ser}, ser, 1, .series),
        .sma, .ema, .rsi => sig(&.{ ser, n }, ser, 2, .series),
        // Series: last value (number). Matrix: last row (1×cols matrix).
        .last => sig(&.{ser}, any, 1, .series),
        .asofJoin => sig(&.{ ser, ser }, ser, 2, .series),
        .resample => sig(&.{ ser, n, str }, ser, 2, .series),
        .align_ => sig(&.{ ser, ser }, ser, 2, .series),
        .head, .tail => sig(&.{ ser, n }, ser, 1, .series),
        .slice => sig(&.{ ser, n, n }, ser, 3, .series),
        .between, .since => sig(&.{ ser, n, n }, ser, 2, .series),
        .shift => sig(&.{ ser, n }, ser, 2, .series),

        // Advanced indicators — record out
        .bollinger, .macd => sig(&.{ ser, n }, rec, 1, .series),

        // Generators
        .gen_range => sig(&.{ n, n, n }, mat, 1, .matrix),
        .linspace, .logspace => sig(&.{ n, n, n }, mat, 3, .matrix),
        .now => sig(&.{}, n, 0, .unsupported),

        // ODE — deriv function referenced by name (string ptr); trajectory
        // matrix out. Host driver resolves instance.exports[name].
        .ode_solve, .ode_solve_euler => sig(&.{ str, any, mat, n }, mat, 4, .ode),

        // LaTeX — source string in; length-prefixed result string out.
        .toLaTeX => sig(&.{str}, str, 1, .unsupported),
    };
}

/// One entry of the import manifest embedded in the custom section.
/// The wire import name is `@tagName(builtin)` plus a `_where` suffix when
/// `is_where` is set (module name is always "env").
pub const ImportEntry = struct {
    builtin: BuiltinFn,
    arg_count: u8,
    is_where: bool,
};

fn wireKindJsonName(kind: WireKind) []const u8 {
    return switch (kind) {
        .number => "number",
        .boolean => "boolean",
        .matrix_ptr => "matrix_ptr",
        .complex_ptr => "complex_ptr",
        .record_ptr => "record_ptr",
        .string_ptr => "string_ptr",
        .series_handle => "series_handle",
        .predicate_ptr => "predicate_ptr",
        .any => "any",
    };
}

fn tierJsonName(tier: StandaloneTier) []const u8 {
    return switch (tier) {
        .scalar => "scalar",
        .matrix => "matrix",
        .ode => "ode",
        .series => "series",
        .unsupported => "unsupported",
    };
}

pub fn tierName(tier: StandaloneTier) []const u8 {
    return tierJsonName(tier);
}

/// Builtins that currently have an in-wasm standalone body (or lower to
/// pure wasm opcodes / helpers). Everything else hard-errors under `-s`.
/// Keep in sync with `WasmCompiler` standalone registration.
pub fn standaloneImplemented(f: BuiltinFn) bool {
    return switch (f) {
        // Inline opcodes / no import needed for the common scalar forms.
        // (min/max 2-arg are opcode-only via isOpcodeOnlyScalar; 1-arg matrix
        // reductions are not yet implemented standalone.)
        .abs, .sqrt, .floor, .ceil, .round, .trunc => true,
        // Generated poly / composed bodies (Tier 1).
        .exp, .log, .log10, .log2, .log1p, .expm1,
        .sin, .cos, .tan, .asin, .acos, .atan, .atan2,
        .sinh, .cosh, .tanh, .asinh, .acosh, .atanh,
        .sec, .csc, .cot, .asec, .acsc, .acot,
        .sech, .csch, .coth, .asech, .acsch, .acoth,
        .hypot, .sign, .clamp, .square, .cube, .cbrt, .nthRoot,
        => true,
        // Tier 2 matrix helpers with in-wasm bodies.
        .transpose, .det, .inv, .trace, .dot, .cross,
        .identity, .zeros, .ones, .diag, .flatten, .reshape,
        // count: series path only under standalone (VM rejects count(matrix)).
        .gemv, .sum, .mean, .prod, .norm, .count,
        => true,
        // Tier 3 — in-wasm ODE (static deriv name → direct call).
        .ode_solve, .ode_solve_euler => true,
        // Tier 4 — series linear memory core.
        .series, .last, .head, .tail, .cumsum, .diff,
        .rolling_mean, .sma,
        => true,
        else => false,
    };
}

/// True when the builtin is lowered without an env import even outside
/// standalone (inline opcode or always-generated body). Used by discovery
/// so RequiredRuntimeSet only tracks real dependencies.
pub fn isInlineOrAlwaysLocal(f: BuiltinFn) bool {
    return switch (f) {
        .abs, .sqrt, .floor, .ceil, .round, .trunc, .min, .max, .sin => true,
        else => false,
    };
}

/// Per-script set of runtime dependencies discovered during AOT compile.
/// Under `-s/--standalone`, every entry must resolve to an in-wasm body;
/// unresolved builtins become a hard compile error naming the builtin + tier.
pub const RequiredRuntimeSet = struct {
    builtins: std.EnumSet(BuiltinFn) = std.EnumSet(BuiltinFn).initEmpty(),
    /// Max arity seen per builtin (for variadic log/round/etc.).
    max_args: std.EnumArray(BuiltinFn, u8) = std.EnumArray(BuiltinFn, u8).initFill(0),
    where_builtins: std.EnumSet(BuiltinFn) = std.EnumSet(BuiltinFn).initEmpty(),
    needs_pow: bool = false,
    needs_fmod: bool = false,
    needs_gemm: bool = false,

    pub fn addBuiltin(self: *RequiredRuntimeSet, f: BuiltinFn, arg_count: u8, is_where: bool) void {
        self.builtins.insert(f);
        if (arg_count > self.max_args.get(f)) self.max_args.set(f, arg_count);
        if (is_where) self.where_builtins.insert(f);
    }

    /// Returns the first unresolved dependency under standalone, or null if
    /// the whole set can be satisfied with in-wasm bodies / helpers.
    pub fn firstUnresolvedStandalone(self: *const RequiredRuntimeSet) ?struct { builtin: BuiltinFn, tier: StandaloneTier, reason: []const u8 } {
        var it = self.builtins.iterator();
        while (it.next()) |f| {
            // 2-arg min/max and 1-arg abs/sqrt/floor/… are inline opcodes.
            if (isOpcodeOnlyScalar(f, self.max_args.get(f))) continue;
            if (self.where_builtins.contains(f)) {
                return .{ .builtin = f, .tier = signature(f).tier, .reason = "where-variant" };
            }
            if (!standaloneImplemented(f)) {
                return .{ .builtin = f, .tier = signature(f).tier, .reason = "no in-wasm body" };
            }
        }
        // pow/fmod/gemm are satisfied by internal helpers (Tier 1 / 2).
        _ = self.needs_pow;
        _ = self.needs_fmod;
        _ = self.needs_gemm;
        return null;
    }

    pub fn isOpcodeOnlyScalar(f: BuiltinFn, arg_count: u8) bool {
        return switch (f) {
            .abs, .floor, .ceil, .round, .trunc => true,
            .sqrt => arg_count == 1,
            .min, .max => arg_count == 2,
            else => false,
        };
    }

    /// Human-readable diagnostic for CLI / tests.
    pub fn formatUnresolved(self: *const RequiredRuntimeSet, buf: []u8) ?[]const u8 {
        const u = self.firstUnresolvedStandalone() orelse return null;
        return std.fmt.bufPrint(buf, "standalone unsupported builtin '{s}' (tier={s}, {s})", .{
            @tagName(u.builtin),
            tierName(u.tier),
            u.reason,
        }) catch null;
    }
};

/// Serialize the full AOT ABI table as JSON for the TypeScript host env
/// (`src/bindings/generated/aot_abi.json` via `zig build abi-aot`).
/// Field names are stable snake_case; every `BuiltinFn` member is included.
pub fn writeAotAbiJson(writer: anytype) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"abi_version\": {d},\n", .{ABI_VERSION});
    try writer.print("  \"custom_section\": ", .{});
    try std.json.Stringify.value(CUSTOM_SECTION_NAME, .{}, writer);
    try writer.writeAll(",\n  \"handle_bases\": {\n");
    try writer.print("    \"series\": {d},\n", .{SERIES_HANDLE_BASE});
    try writer.print("    \"record\": {d},\n", .{RECORD_HANDLE_BASE});
    try writer.print("    \"matrix\": {d}\n", .{MATRIX_HANDLE_BASE});
    try writer.writeAll("  },\n  \"series_layout\": ");
    try writer.writeAll(SeriesLayout.json_shape);
    try writer.writeAll(",\n  \"series_repr_default\": \"");
    try writer.writeAll(SeriesRepresentation.host_handle.jsonName());
    try writer.writeAll("\",\n  \"builtins\": {\n");

    const fields = std.meta.fields(BuiltinFn);
    inline for (fields, 0..) |field, i| {
        const f: BuiltinFn = @field(BuiltinFn, field.name);
        const sig_info = signature(f);
        if (i > 0) try writer.writeAll(",\n");
        try writer.writeAll("    \"");
        try writer.writeAll(field.name);
        try writer.writeAll("\": {\n");
        try writer.writeAll("      \"id\": ");
        try std.json.Stringify.value(@intFromEnum(f), .{}, writer);
        try writer.writeAll(",\n      \"args\": [");
        for (sig_info.args, 0..) |arg, j| {
            if (j > 0) try writer.writeAll(", ");
            try writer.writeAll("\"");
            try writer.writeAll(wireKindJsonName(arg));
            try writer.writeAll("\"");
        }
        try writer.writeAll("],\n      \"ret\": \"");
        try writer.writeAll(wireKindJsonName(sig_info.ret));
        try writer.writeAll("\",\n      \"min_args\": ");
        try std.json.Stringify.value(sig_info.min_args, .{}, writer);
        try writer.writeAll(",\n      \"variadic\": ");
        try std.json.Stringify.value(sig_info.min_args < sig_info.args.len, .{}, writer);
        try writer.writeAll(",\n      \"where_capable\": ");
        try std.json.Stringify.value(sig_info.where_capable, .{}, writer);
        try writer.writeAll(",\n      \"standalone_tier\": \"");
        try writer.writeAll(tierJsonName(sig_info.tier));
        try writer.writeAll("\",\n      \"supported\": ");
        try std.json.Stringify.value(sig_info.importable, .{}, writer);
        try writer.writeAll(",\n      \"fast_scalar\": ");
        const max_args: usize = if (sig_info.args.len == 0) 0 else sig_info.args.len;
        const fast = sig_info.importable and sig_info.tier == .scalar and
            (max_args == 0 or bytecode.isFastPathBuiltin(f, max_args));
        try std.json.Stringify.value(fast, .{}, writer);
        try writer.writeAll("\n    }");
    }
    try writer.writeAll("\n  }\n}\n");
}

test "every builtin has a signature (exhaustive switch is the proof)" {
    // The switch in signature() has no else branch, so this compiles only if
    // every BuiltinFn member is categorized. Touch a few entries to keep the
    // function from being lazily skipped.
    inline for (.{ BuiltinFn.abs, BuiltinFn.ode_solve, BuiltinFn.bollinger, BuiltinFn.config }) |f| {
        _ = signature(f);
    }
    try std.testing.expectEqual(WireKind.number, signature(.det).ret);
    try std.testing.expect(signature(.mean).where_capable);
    try std.testing.expect(!signature(.write_csv).importable);
}

test "series linear-memory layout offsets (single definition)" {
    // Layout: [u32 len][u32 pad][ts × len][vals × len]
    try std.testing.expectEqual(@as(u32, 8), SeriesLayout.header_bytes);
    try std.testing.expectEqual(@as(u32, 8), SeriesLayout.timestamps_offset);
    try std.testing.expectEqual(@as(u32, 8 + 3 * 8), SeriesLayout.valuesOffset(3));
    try std.testing.expectEqual(@as(u32, 8 + 3 * 16), SeriesLayout.totalBytes(3));
    try std.testing.expectEqual(@as(u32, 8), SeriesLayout.totalBytes(0));
    try std.testing.expectEqualStrings("host_handle", SeriesRepresentation.host_handle.jsonName());
    try std.testing.expectEqualStrings("linear_memory", SeriesRepresentation.linear_memory.jsonName());
}
