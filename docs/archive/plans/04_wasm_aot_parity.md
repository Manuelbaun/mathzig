# Plan 04: WASM AOT Parity — Remaining Gaps

**Priority:** 🟡 High · **Effort:** 1-2 weeks · **Risk:** Medium

> **HISTORICAL / SUPERSEDED banner (2026-07-15, task-20).**  
> Phase checklists and “all 5 phases complete” language below predate stream A/B/C.
> Live AOT/parity status is **criterion-level** in [`docs/STATUS.md`](../STATUS.md)
> and [`docs/STATUS.md`](../STATUS.md). Machine-specific `file:///` links
> were replaced with repo-relative paths. Prefer `docs/tasks/archive/specs/task-01`…`task-07` + C-chain
> over this plan for residual work.

---

## Current Status — Better Than Expected

After reviewing [task 0080](../tasks/archive/0080_wasm_aot_parity_fixes.md) (archived), the WASM AOT situation was already strong relative to early roadmap drafts:

### Phases (historical checklist — not a current “plan complete” claim)
- **Phase 1:** Core arithmetic + DSL functions + diagnostics
- **Phase 2:** Complex numbers + Units
- **Phase 3:** Matrices + Records
- **Phase 4:** Temporal + Time series (7 case files)
- **Phase 5:** CSV/IO + RNG + ODE

> Residual skips, quarantine, and acceptance debt are tracked in STATUS.md / specs — not by re-opening this checklist as “complete”.

---

## Remaining Open Tasks

Despite strong phase progress, related items historically open in the [WASM AOT manifest](../missions/wasm_aot/manifest.md):

### 1. Task 0061: WASM AOT Backend Index
- Likely an organizational/documentation task for the AOT backend
- Should be reviewed and closed if the work is actually done

### 2. Task 0067: WASM AOT Bugfixes
- May contain residual bugs discovered during Phase 1-5 implementation
- Needs review to determine which bugs persist

### 3. Task 0073: Web Worker Support
- Running WASM AOT in a Web Worker for non-blocking computation
- Requires SharedArrayBuffer or message passing for data transfer
- Important for the web console experience

### 4. Task 0042: WASM Implementation Audit
- Comprehensive audit of the WASM backend
- Should be scoped to verify the Phase 1-5 completions and identify edge cases

---

## Recommended Next Steps

### Step 1: Update ROADMAP.md (30 min)
The roadmap's v0.2.0 section should reflect the Phase 1-5 completions. The `[🟡]` marker for WASM AOT should be updated.

### Step 2: Audit Tasks 0061, 0067 (1-2 hours)
Read these task files, determine what's actually remaining vs. done, and close or update them.

### Step 3: Browser Compatibility Validation (1-2 days)
The roadmap lists "Browser compatibility validation" as incomplete for v0.2.0. This means testing the WASM output in:
- Chrome, Firefox, Safari, Edge
- Different WASM feature levels (SIMD support, memory64, etc.)
- Mobile browsers (iOS Safari, Chrome Android)

### Step 4: Web Worker Support — Task 0073 (3-5 days)
This is the most significant remaining work:

```
┌──────────────────┐     postMessage     ┌──────────────────┐
│   Main Thread    │ ◄─────────────────► │   Web Worker     │
│   (UI, Charts)   │                     │   (WASM AOT VM)  │
└──────────────────┘                     └──────────────────┘
```

Key design decisions:
- **Shared memory** (SharedArrayBuffer) vs. **copy** (postMessage with transferables)
- Worker pool for parallel evaluations vs. single worker
- API shape: `worker.evaluate(expr)` → `Promise<Value>`

### Step 5: WASM Size Optimization (optional)

The current WASM binary is **320 KB** (`web/mathzig_wasm.wasm`). For a math library, this is reasonable, but could be optimized:
- Strip debug info (if any left in ReleaseSmall)
- Tree-shake unused builtins
- `wasm-opt` post-processing (already has a script: `tools/wasm/optimize_wasm.ts`)

---

## WASM AOT Architecture Overview

The WASM compiler (`src/wasm/compiler.zig`, 2,049 lines) translates MathZig bytecode to native WASM:

```
MathZig Expression → Compiler → Bytecode → WasmCompiler → .wasm binary
```

Key components:
- `WasmCompiler` struct with module builder, function discovery, variable mapping
- Type tracking stack for WASM validation
- Host import system for complex operations (GEMM, time-series)
- Support for user-defined functions, loops, and conditionals

The compiler is well-structured but at 2,049 lines, it's approaching the same monolith threshold as `vm.zig`. Consider splitting if it grows further.
