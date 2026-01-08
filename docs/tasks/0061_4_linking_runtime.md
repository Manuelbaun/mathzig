# Subtask 0061.4: Linking & Runtime Library

**Status:** In Progress (verified partial 2026-07-15)

## Objectives
- [ ] Create `mathzig-runtime.wasm` containing core Zig logic.
- [ ] **Matrix Kernels:** Implement optimized `mat_add`, `mat_sub`, `mat_inv` etc. in Zig and compile to WASM.
- [ ] **Complex Math:** Port complex number arithmetic logic to the runtime library.
- [ ] **Linked Mode:** Update `WasmCompiler` to support importing these kernels instead of inlining them.
- [ ] Add CLI flags `--standalone` and `--linked`.

## Tasks
- [ ] Audit all MathZig builtins to determine which need runtime support.
- [ ] Scaffold the `src/wasm/runtime/` directory.
- [ ] Implement `mat_add` kernel.

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** standalone flag present=True; src/wasm/runtime/=False; linked runtime wasm scaffold missing
- **Notes:** Standalone mode started; linked shared runtime library not built.
- **Audit:** [true_status_audit.md](true_status_audit.md)

