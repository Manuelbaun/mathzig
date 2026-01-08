# MathZig Strategic Roadmap

Living summary of product direction. Day-to-day truth for correctness/perf is the **`bun run mz`** pipeline and the progress dashboard (`apps/progress`), not this file.

**Version:** `0.1.0` (`src/VERSION`)

---

## Current status (2026-07)

| Area | State |
|------|--------|
| **Native VM + types** | Production path for correctness baseline |
| **Cross-backend parity** | `zig_vm`, `ts_ffi`, `ts_wasm_vm`, `wasm_aot` via JSON cases + `mz` |
| **WASM AOT** | Expression / node modules; standalone tiers for many builtins |
| **Node graphs** | Multi-module `GraphRunner` (editor) + fused `compile-graph` / `FusedGraphRunner` |
| **Compile-fuse program** | Specs 01–08 complete (`docs/archive/plans/compile-fuse/`) |
| **Product UI** | `apps/console` (REPL + `/graph`); `web/` is not product UI |
| **Progress dashboard** | `apps/progress` fed automatically by `mz` |
| **Hosts** | Wasmer / WasmEdge / Spin demos under `hosts/` |
| **Hardening / quality system** | Landed — `docs/guides/quality.md` + `docs/STATUS.md` |

Capability overview: `docs/guides/capabilities.md`. External audit snapshot: `docs/archive/audits/AUDIT_2026-07-10.md`. Live board: `docs/STATUS.md`.

---

## Strategic tracks

| Track | Priority | Where it lives |
|-------|----------|----------------|
| **Correctness gate trust** | P0 | `bun run mz`, `docs/STATUS.md`, `docs/guides/testing.md` |
| **AOT / full-value fidelity** | P0 | `src/wasm/`, parity cases, `docs/guides/wasm_aot_usage.md` |
| **Graph product (multi + fused)** | P0 | `apps/console` `/graph`, `src/graph/`, `src/ts/graph/` |
| **Performance non-regression** | P1 | `mz` measure stage + progress dashboard |
| **Language & types** | P1 | parser/VM, units, series, records |
| **Solvers / simulations** | P2 | ODE, rocket/Lorenz demos in console graphs |
| **Host packaging** | P2 | `hosts/` |

Historical material: `docs/archive/` (missions, plans, research). Prefer STATUS + guides for active work.

---

## Near-term focus

1. Keep **`mz`** green; no alternate daily test paths.  
2. Burn down residual acceptance debt (quarantine / AOT skips in STATUS).  
3. Console graph UX: multi-module edit path + fused export (already dual-model).  
4. Honest AOT standalone limits (series/ODE/IO) — document + parity, no silent stubs.  
5. Keep docs truth: `docs/README.md` + STATUS; regenerate STATUS after meaningful runs.

---

## Commands (current)

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"   # macOS if needed

# Daily correctness + perf + progress package
bun run mz

# Native
zig build
zig build repl
zig build test
zig build vm-baseline

# Interpreter WASM for console
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
cp zig-out/bin/mathzig_wasm.wasm apps/console/public/

# Product UIs
bun run --cwd apps/console dev      # :5173
bun run --cwd apps/progress dev     # :5174 (after mz)
```

---

## Related

- [`AGENTS.md`](../AGENTS.md) — agent contract + test protocol  
- [`README.md`](./README.md) — docs map  
- [`guides/capabilities.md`](./guides/capabilities.md) — what is implemented  
- [`guides/testing.md`](./guides/testing.md) — pipeline meaning + parity  
- [`guides/graphs.md`](./guides/graphs.md) — graph dual model  
- [`guides/quality.md`](./guides/quality.md) — gate / STATUS design  
- [`memory/`](./memory/) — durable decisions / gotchas  
- [`FOCUS.md`](./FOCUS.md) — what matters now  
- [`STATUS.md`](./STATUS.md) — live criterion status  
- [`../PRODUCT.md`](../PRODUCT.md) — product intent  
