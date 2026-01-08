# Plan 07: Future Opportunities

**Priority:** 💡 Future · **Effort:** Varies · **Risk:** Low-Medium

---

This document covers 4 longer-term opportunities that would significantly expand MathZig's capabilities and reach.

---

## 1. Lazy Evaluation / Streaming Pipeline

**Effort:** 1-2 weeks · **Impact:** High for large datasets

### Problem
All operations are currently **eager** — every time-series operation (`sma`, `ema`, `derivative`, etc.) immediately allocates and computes a full output buffer. For pipelines like:

```
ema(derivative(resample(price, 60)), 14)
```

This creates 3 intermediate Series objects, each fully materialized. For a 1M-point series, that's ~24 MB of intermediate allocations.

### Proposed Design

Add a **lazy evaluation layer** on top of the existing VM:

```zig
pub const LazyOp = union(enum) {
    source: *Series,                     // Terminal: actual data
    map: struct { input: *LazyOp, fn: MapFn },      // Element-wise transform
    window: struct { input: *LazyOp, size: u32, fn: WindowFn },  // Rolling window
    resample: struct { input: *LazyOp, period: f64, kernel: AggKernel },
};
```

**Optimization opportunities:**
- **Fusion**: `ema(derivative(x))` → single pass computing derivative + EMA simultaneously
- **Lazy slicing**: `tail(ema(x, 14), 100)` → only compute the last 114 points of EMA
- **Memory reuse**: Pipeline stages can reuse a single output buffer

### Integration
- New `LazyValue` tag in the Value enum, or a wrapper that checks `is_lazy` before materializing
- Lazy evaluation triggered by explicit `.compute()` or automatic when a scalar result is needed

---

## 2. JSON I/O Module

**Effort:** 2-3 days · **Impact:** High for data connectivity

### Problem
MathZig currently supports CSV I/O but not JSON. JSON is the universal data exchange format for web applications, APIs, and data pipelines.

### Proposed Implementation

```zig
// src/io/json.zig

/// Parse JSON array of numbers into a Series
pub fn parseJsonArray(json: []const u8, allocator: Allocator) !*Series

/// Parse JSON object into a Record
pub fn parseJsonObject(json: []const u8, allocator: Allocator) !*Record

/// Parse JSON array of objects into a Record of Series (columnar)
pub fn parseJsonTable(json: []const u8, allocator: Allocator) !*Record

/// Export a Value to JSON string
pub fn toJson(value: Value, allocator: Allocator) ![]const u8
```

### Usage from DSL
```
data = read_json("prices.json")
result = ema(data.close, 14)
write_json(result, "output.json")
```

### Implementation Notes
- Zig's `std.json` parser is available and mature
- Start with `parseJsonArray` → Series (simplest case)
- Then `parseJsonObject` → Record
- Finally `parseJsonTable` for column-oriented data (common in data science)

---

## 3. Plugin / Extension API

**Effort:** 1 week · **Impact:** High for ecosystem growth

### Problem
All builtin functions are compiled into the MathZig binary. Users cannot extend the function library without modifying Zig source. This limits adoption in specialized domains (finance, physics, biology).

### Proposed Design

#### TypeScript Side (FFI Plugin)

```typescript
// User-defined function registered via FFI
const mz = MathZig.create();

mz.registerFunction("black_scholes", (S, K, T, r, sigma) => {
    // Custom implementation in TypeScript
    const d1 = (Math.log(S / K) + (r + sigma * sigma / 2) * T) / (sigma * Math.sqrt(T));
    const d2 = d1 - sigma * Math.sqrt(T);
    return S * normalCDF(d1) - K * Math.exp(-r * T) * normalCDF(d2);
});

mz.eval("black_scholes(100, 95, 0.5, 0.05, 0.2)");
```

#### Zig Side (VM Callback)

```zig
pub const ExternalFunction = struct {
    name: []const u8,
    arity: u8,
    callback: *const fn (args: []const f64) f64,
};

// In VM.callBuiltin:
if (self.external_functions.get(name)) |ext_fn| {
    return ext_fn.callback(args);
}
```

### Challenges
- FFI callback from Zig → TypeScript requires careful stack management
- WASM plugins would need a different mechanism (host imports)
- Type safety across the boundary

---

## 4. Documentation Website

**Effort:** 1-2 days · **Impact:** High for adoption

### Problem
MathZig has excellent internal documentation (165 files in `docs/`) but no public-facing website. This is a barrier to adoption.

### Proposed Approach

**Tool: [mdBook](https://rust-lang.github.io/mdBook/)** — perfect for Zig projects, Markdown-native, lightweight.

```bash
# Install
cargo install mdbook

# Initialize
cd docs && mdbook init --title "MathZig" .

# Build
mdbook build  # outputs to docs/book/
```

### Content Structure (maps to existing docs)

```
SUMMARY.md
├── Getting Started
│   ├── guides/overview.md
│   └── Quick Start (from README.md)
├── User Guide
│   ├── guides/guide_timeseries.md
│   ├── guides/ode_solver.md
│   ├── guides/generators.md
│   └── guides/optimization.md
├── API Reference
│   └── reference/api.md
├── Internals
│   ├── internals/vm.md
│   ├── internals/bytecode.md
│   ├── internals/compiler.md
│   ├── internals/memory.md
│   └── internals/ffi.md
├── Web Console
│   └── guides/web_console.md
└── Comparisons
    └── comparisons/mathjs_vs_mathzig_comparison.md
```

Most of the content already exists — it's primarily a matter of creating `SUMMARY.md` and adjusting relative links.

### Hosting Options
- **GitHub Pages**: Free, auto-deploy from `gh-pages` branch
- **Cloudflare Pages**: Free, faster CDN
- **Self-hosted**: `web/docs/` alongside the web console

---

## Priority Matrix

| Opportunity | Effort | Impact | Dependencies |
|-------------|--------|--------|--------------|
| Documentation Website | 1-2 days | 🟢 High (adoption) | None |
| JSON I/O | 2-3 days | 🟢 High (connectivity) | None |
| Plugin API | 1 week | 🟡 Medium (ecosystem) | FFI layer stable |
| Lazy Evaluation | 1-2 weeks | 🟡 Medium (performance) | Requires careful design |

**Recommended order:** Docs Website → JSON I/O → Plugin API → Lazy Evaluation
