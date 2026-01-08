# Subtask 0061.6: Time-Series Engine Port

**Status:** In Progress (verified partial 2026-07-15)

## Objectives
- [ ] Define `TimeSeries` binary layout in WASM memory.
- [ ] Port the temporal math engine (resampling, TWA, derivative, integral).
- [ ] Support series-to-series arithmetic.
- [ ] Implement temporal predicates (where clause) in WASM.

## Dependencies
- Requires Phase 4 (Linking) for aggregation kernels.
- Requires Phase 5 (Relooper) for complex resampling loops.

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** series in wasm compiler=True; series_aot case=True
- **Notes:** Partial AOT series support via host imports; full engine port open.
- **Audit:** [true_status_audit.md](true_status_audit.md)

