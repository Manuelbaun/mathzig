# Spec 05 — CLI `compile-graph`

**Depends on:** 01–04 (04 may be partial if Zig can self-test)  
**Unblocks:** 06, hosts demos  
**Scope:** native CLI entry to emit fused `.wasm` + sidecar from graph JSON

## Goal

```bash
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm
# writes out.wasm + out.graph.json
# options: -v, --standalone (scalar subset only if standalone allows)
```

Users and hosts get a **final artifact**: one module, multi input values, multi output values.

## Todos

- [x] Subcommand `compile-graph` in `src/main.zig` (or `graph compile-fuse` — pick one name, document)
- [x] Parse graph JSON via existing `src/graph/schema.zig` (or shared schema)
- [x] Run lowerer (Zig port of fuse plan **or** shell-out not allowed in CLI — prefer Zig plan builder mirroring TS)
- [x] Compile fused module (spec 03)
- [x] Write wasm bytes + `.graph.json` sidecar
- [x] Usage/`-h` text
- [x] Integration test: compile fixture → run via bun `FusedGraphRunner` or wasmer if scalar standalone
- [x] Document in `docs/COMMANDS.md` / `docs/guides/wasm_aot_usage.md` short section

### Zig vs TS lowerer

Prefer **one** lowerer implementation for CLI:

- **Option 1:** Zig `src/graph/fuse.zig` mirroring TS (best for CLI purity)
- **Option 2:** CLI only accepts pre-built fuse IR (reject)

This plan standardizes on **Option 1** for `compile-graph`. TS lowerer (02) remains for bun tests and can share fixtures with Zig.

## Do NOTs

- Do **not** remove `mathzig compile` / `--node`.
- Do **not** make `compile-graph` the editor’s hot reload path.
- Do **not** accept free-form multi-file graphs without JSON schema validation.
- Do **not** claim `--standalone` for graphs that still need env imports; hard-error like single-expr standalone.

## Tests

| ID | Test | Expected |
|----|------|----------|
| T1 | `compile-graph -i fixtures/scalar_chain.json -o /tmp/t.wasm` | exit 0; file non-empty |
| T2 | Sidecar exists and matches custom section | JSON equal fields |
| T3 | Run fused module; outs match multi-module fixture | golden |
| T4 | Bad JSON / cycle | non-zero exit, stderr message |
| T5 | Graph with wasm-only node | non-zero exit, clear error |

```bash
zig build
./zig-out/bin/mathzig compile-graph -i tests/.../scalar_chain.json -o /tmp/fuse.wasm
bun test tests/ts/graph/fused_cli*.ts
```

## Expected outcomes

- [x] One command produces deployable single-module graph artifact  
- [x] Multi-output values described in sidecar + section  
- [x] Documented usage  
- [x] CI-able compile+run golden  

### Landed decisions

| Topic | Choice |
|-------|--------|
| Subcommand name | `compile-graph` (top-level, not under `graph`) |
| Lowerer | Zig `src/graph/fuse.zig` (Option 1; mirrors TS) |
| Default `out_mode` | `table` (Spec 01 preferred); CLI `--out-mode named_exports` |
| Sidecar | `out.wasm` → `out.graph.json` (bytes = `mathzig:graph` section) |
| TS `compileFused` | Prefer shell to CLI; golden exact-match is fallback only |
