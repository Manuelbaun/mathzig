# Plan 05: Complete ABI Smith Kit

**Priority:** 🟡 High · **Effort:** 1 week · **Risk:** Low

---

## Problem Statement

The TypeScript binding layer has **dual maintenance burden**: an auto-generator (`tools/bindings/generate_bindings.ts`) and manual bindings (`src/bindings/bindings/exports.zig` + `src/bindings/generated/`). The generator is partially implemented, producing some files automatically, while manual exports continue to grow.

---

## Current State

### Manual Exports: `exports.zig`
- **68 exported C functions** (`export fn mathzig_*`)
- 622 lines covering: context management, evaluation, value management, variables, time-series, batch SIMD, matrix ops, records, WASM AOT compilation, CSV, ODE, series operations
- Uses `callconv(.c)` for cross-platform FFI compatibility

### Auto-Generated Bindings: `tools/bindings/generate_bindings.ts`
- 538 lines, reads from `src/bindings/generated/api.json` schema
- Generates TypeScript files: `symbols.ts`, `loader.ts`, `classes.ts`
- Handles type mapping (Zig → FFI → TypeScript), class generation, method wiring
- Some binding types are special-cased (Matrix, Vector, Value constructors)

### Generated Output: `src/bindings/generated/`
- Contains 9 files (auto-generated outputs for the TypeScript side)

### The Gap

| Aspect | Generator Status | Manual Status |
|--------|-----------------|---------------|
| Context create/destroy | ✅ Generated | ✅ In exports.zig |
| eval/compile/execute | ✅ Generated | ✅ In exports.zig |
| Variable get/set | ✅ Generated | ✅ In exports.zig |
| Matrix operations | ⚠️ Partial | ✅ Full in exports.zig |
| Series operations | ⚠️ Partial | ✅ Full in exports.zig |
| Record operations | ❌ Not generated | ✅ In exports.zig |
| WASM AOT compile | ❌ Not generated | ✅ In exports.zig |
| Batch SIMD | ❓ Unknown | ✅ In exports.zig |
| CSV I/O | ❌ Not generated | ✅ In exports.zig |
| ODE solver | ❌ Not generated | ✅ In exports.zig |

---

## Proposed Approach

### Phase 1: Schema Completeness (2-3 days)

Ensure `api.json` covers **all 68 exported functions**:

1. **Audit script**: Write a script that compares `api.json` entries against `grep "export fn" exports.zig` output
2. **Fill gaps**: Add missing function declarations to `api.json` for Records, WASM AOT, CSV, ODE, and batch operations
3. **Type annotations**: Ensure each function has correct arg types, return types, and binding hints

### Phase 2: Generator Enhancement (2-3 days)

Update `generate_bindings.ts` to handle:

1. **Complex return types**: Functions returning `*Record`, `*Series`, `*Matrix` need wrapper objects
2. **Buffer operations**: SIMD batch functions that take `[*]f64` / `[*]const f64` arrays
3. **String marshalling**: Functions taking `[*:0]const u8` (C strings)
4. **Opaque pointer chains**: WASM AOT compilation returns opaque WASM bytes
5. **Error handling**: Functions that may return null on failure

### Phase 3: CI Integration (1 day)

Add a verification step:

```bash
# Regenerate bindings
bun tools/bindings/generate_bindings.ts

# Check for drift
git diff --exit-code src/bindings/generated/

# If there's a diff, the regenerated output doesn't match committed files
```

This prevents manual edits to generated files from going undetected.

---

## ABI Inspector Integration

There's already an `tools/bindings/abi_inspector.zig` (28 KB) that can introspect the compiled library's exports. This could be leveraged to:

1. Auto-generate `api.json` from the actual compiled exports
2. Validate that `api.json` matches the binary
3. Detect symbol renames or signature changes automatically

### Dream Pipeline

```
exports.zig → zig build → .dylib/.wasm
                              ↓
                    abi_inspector.zig
                              ↓
                         api.json (auto)
                              ↓
                   generate_bindings.ts
                              ↓
            src/bindings/generated/*.ts
```

This would make the entire binding layer **fully automated from source**.

---

## Success Criteria

- [ ] All 68 `export fn` functions are represented in `api.json`
- [ ] Running `bun tools/bindings/generate_bindings.ts` produces working TypeScript bindings
- [ ] All existing TS tests pass with the generated bindings
- [ ] No manual edits needed to generated files
- [ ] CI step validates binding freshness
