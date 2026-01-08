# Toolchain

## Required

- **Zig** — match project toolchain / `build.zig.zon` (project targets 0.15.x).
- **Bun** — exclusive JS/TS runtime for this repo (`bun test`, `bun run`, installs).

## Commands (common)

```bash
# Native
zig build
zig build repl
zig build test
zig build vm-baseline

# Daily gate
bun run mz

# Interpreter WASM for console
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
cp zig-out/bin/mathzig_wasm.wasm apps/console/public/

# Product UIs
bun run --cwd apps/console dev     # :5173
bun run --cwd apps/progress dev    # after mz

# Status truth
bun tools/status_report.ts
bun tools/status_report.ts --check
```

## macOS

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
```

Use when system SDK / zig linking needs the repo shim.

## Bindings

```bash
zig build gen-bindings
```

Never hand-edit `src/bindings/generated/*`.

## Worktrees (optional isolation)

For large audits, prefer a git worktree with the branch name mirrored in the path; remove the worktree after merge. Keep scratch under `./tmp` inside the worktree.

## Style reference

- Project style: `docs/MATHZIG_STYLE.md`
- Zig API pitfalls: `docs/ZIG_CHEATSHEET.md`
- External TigerStyle reference: `docs/archive/research/external/TIGER_STYLE.md`
