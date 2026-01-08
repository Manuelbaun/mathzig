# Agent memory

Durable facts agents should load with [`AGENTS.md`](../../AGENTS.md).  
**Not** live status, task checklists, or session notes.

| File | Theme |
|------|--------|
| [`decisions.md`](./decisions.md) | Frozen product / engineering decisions |
| [`gotchas.md`](./gotchas.md) | Pitfalls, API traps, environment rules |
| [`testing.md`](./testing.md) | Parity / pipeline invariants (short) |
| [`toolchain.md`](./toolchain.md) | Zig, Bun, macOS, paths |

## Rules for adding a memory

1. **One durable fact per bullet** — still true next month.
2. **No live status** — pass/fail tables belong in `docs/STATUS.md` (generated).
3. **No task IDs as “current work”** — product truth is `docs/STATUS.md` + `docs/guides/capabilities.md`.
4. **No machine-absolute paths** — no `/Users/...` install roots.
5. Prefer a decision (“we always X”) over a changelog (“we fixed X on date Y”).

## What lives elsewhere

| Kind | Where |
|------|--------|
| How-to / tutorials | `docs/guides/` |
| Live criterion status | `docs/STATUS.md` |
| Short-term focus | `docs/FOCUS.md` |
| Style | `docs/MATHZIG_STYLE.md` |
| Deep Zig API notes | `docs/ZIG_CHEATSHEET.md` |
