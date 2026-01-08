# Gotchas

## Environment

- **tmp files:** always `./tmp` (repo-local), never `/tmp`.
- **macOS zig builds:** put the SDK shim first when needed:
  ```bash
  export PATH="$PWD/tools/macos-sdk-shim:$PATH"
  ```
- **Console WASM not updating:** rebuild freestanding wasm and copy to `apps/console/public/mathzig_wasm.wasm` (not only `web/`).

## Zig 0.15+

- **Stdin/stdout:** `std.fs.File.stdin()` / `stdout()` / `stderr()` — not `std.io.getStdIn()`.
- **File.Writer has no `.print()`** in 0.15.2 — use `bufPrint` + `writeAll` (see `docs/ZIG_CHEATSHEET.md`).
- **ArrayList:** prefer `ArrayListUnmanaged` + pass allocator to methods; old `.init(allocator)` patterns broke.
- **No recursion** in compiler/VM paths (bounded execution; project style).

## WASM / FFI

- **Float64Array alignment:** use `mathzig_alloc_aligned(8, …)` (or equivalent) for f64 buffers; plain `u8` alloc under `ReleaseSmall` may not be 8-byte aligned.
- **`threading.debugPrint`:** disabled on `wasm32-freestanding` to avoid `posix` compile errors.
- **FFI thread-local last value:** JS must `retain()` if it needs to hold a reference across later calls.
- **Large matrix literals:** compiler pushes all elements to the VM stack first — stack capacity must cover largest literal.

## Graphs / AOT

- **Opaque `wasm` nodes** cannot be fused — stay on multi-module `GraphRunner`.
- **Standalone AOT** hard-errors (or stubs with NaN historically for some ODE paths) when host imports are required — document limits; no silent wrong answers.
- **Fused `runBatch`:** host loop over `run()`, not a wasm `tick_batch` export.
- **Do not use `compile-graph` as editor hot-reload** — multi-module path is the hot path.

## Testing

- **Do not invent daily entrypoints** besides `bun run mz`.
- **Do not put cross-backend coverage only** in `tests/ts/parity/` — add JSON cases.
- **MathJS / rocket fails:** check quarantine in `tests/known_failures.json` before “fixing” by deleting tests.
