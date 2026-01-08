# Plan 03: Root Directory Cleanup

**Priority:** 🔴 Critical · **Effort:** 30 minutes · **Risk:** None

---

## Problem Statement

The project root contains **9 stale files** that appear to be development/debugging artifacts, not part of the project proper. This clutters `ls`, makes the repo look unfinished, and some files (screenshot, performance CSV) add unnecessary size.

---

## Inventory of Stale Files

| File | Size | Last Modified | Purpose | Action |
|------|------|---------------|---------|--------|
| `lorenz.wasm` | 930 B | Jan 23 | WASM AOT output for Lorenz attractor test | Move to `tests/artifacts/wasm/` |
| `lorenz_aot.mz` | 256 B | Jan 23 | MathZig script for Lorenz AOT | Move to `tests/artifacts/wasm/` |
| `test.wasm` | 175 B | Jan 23 | Generic test WASM output | Move to `tests/artifacts/wasm/` |
| `test_loop.mz` | 39 B | Jan 22 | Loop test script | Move to `tests/artifacts/` |
| `run_lorenz.ts` | 7,820 B | Jan 23 | Lorenz simulation runner | Move to `tests/ts/simulations/` or `tests/scripts/` |
| `run_wasm.ts` | 1,332 B | Jan 23 | WASM runner script | Move to `tests/scripts/` |
| `repro_shadowing.ts` | 641 B | Jan 24 | Bug reproduction script | Move to `tests/scripts/` or delete |
| `Bildschirmfoto 2026-01-20 um 22.45.53.png` | 110 KB | Jan 20 | Screenshot (German filename) | Move to `docs/` or delete |
| `performance_log.csv` | 18 KB | Jan 24 | Performance tracking log | Move to `tests/artifacts/performance/` |

---

## Proposed Actions

### 1. Move test outputs
```bash
mkdir -p tests/artifacts/wasm
mv lorenz.wasm lorenz_aot.mz test.wasm tests/artifacts/wasm/
mv test_loop.mz tests/artifacts/
```

### 2. Move scripts
```bash
mv run_lorenz.ts run_wasm.ts tests/scripts/
mv repro_shadowing.ts tests/scripts/  # or delete if bug is fixed
```

### 3. Move / archive other files
```bash
mv performance_log.csv tests/artifacts/performance/
mv "Bildschirmfoto 2026-01-20 um 22.45.53.png" docs/  # or delete
```

### 4. Update `.gitignore`

Add patterns to prevent future accumulation:

```gitignore
# Build artifacts that shouldn't be in root
*.wasm
*.mz
performance_log.csv

# Screenshots
*.png
!docs/**/*.png
!web/**/*.png
```

---

## Verification

After cleanup, root should only contain:

```
.gitignore     GEMINI.md    build.zig      bunfig.toml  libs/    src/    tools/
CLAUDE.md      README.md    build.zig.zon  docs/        node_modules/  tests/  web/
benchmarks/    bun.lock     package.json   tsconfig.json  tmp/
```

```bash
# Verify nothing broke
zig build test && bun test
```
