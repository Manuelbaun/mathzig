# Capability verification report

**Date:** 2026-07-16  
**Method:** Code + test inventory + targeted live tests (not a full `bun run mz` re-run).  
**Against:** [`capabilities.md`](./capabilities.md), [`graphs.md`](./graphs.md), [`quality.md`](./quality.md), [`STATUS.md`](../STATUS.md).

### Verdict legend

| Tag | Meaning |
|-----|---------|
| **PROVEN** | Code path exists **and** automated evidence (parity/goldens/unit tests/STATUS artifact) |
| **PRESENT** | Code/UI exists; no full behavioral re-proof in this pass |
| **RESIDUAL** | Documented incomplete / quarantined / skipped |
| **WEAK** | Claim too broad or open-task theme without clear catalog coverage |
| **UNRUN** | Would need full `mz` / long soak; not executed this pass |

---

## Evidence sources used this pass

| Source | Result |
|--------|--------|
| Tree inventory of all paths cited in capabilities | **All present** (no MISSING) |
| Parity catalog inventory | **54 files · 629 cases** (matches STATUS) |
| Catalog `skip:` counts | `ts_wasm_vm` 56, `wasm_aot` 3, `wasm_aot_standalone` 15 declared; standalone runtime budget 274 (STATUS) |
| `tests/known_failures.json` | **15** quarantine entries |
| STATUS live parity artifacts (last full-ish run) | zig_vm/ts_ffi **629/0**, ts_wasm_vm **573/56**, wasm_aot **626/3**, standalone **355/274/0** |
| STATUS strict bun gate | **PASS** unexpected_fail=0 unexpected_pass=0 (15 quarantined) |
| `bun test` standalone_skip_budget | **11 pass / 0 fail** |
| `bun test` graph_cross_runner_parity + graph_perf_tripwire | **58 pass / 0 fail** |
| Graph tick baseline parse | **7 metrics** OK from `docs/reference/graph_tick_baseline.md` |
| `zig-out/bin/mathzig` | **Present** (built binary on disk) |
| Full `bun run mz` | **UNRUN** this pass (STATUS artifacts used instead) |

---

## 1. Expression engine

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Parser → bytecode → VM | **PROVEN** | `src/parser/`, `src/vm/bytecode.zig`, `src/vm/vm.zig`; `vm_baseline` + parity |
| Value types (number/complex/matrix/unit/series/record/…) | **PROVEN** | `src/core/value.zig` + case files `complex*`, `matrix*`, `units*`, `records*`, `timeseries*`, `series_*` |
| Matrix kernels / ODE / generators / TS bindings | **PROVEN** | `src/functions/{matrix_kernels,ode,generators,timeseries_bindings}.zig` + parity themes |
| Time series modules | **PROVEN** | `src/timeseries/*` + 11 series-related case files |
| Units | **PROVEN** | `src/units/`, `units.json`, `units_aot.json`; honesty hard-error in VM `mat_create` |
| ChunkArena | **PROVEN** | `src/memory/chunk_arena.zig` |
| SIMD / hot paths | **PROVEN** (implementation) | `executeBatchSIMD` / complex SIMD in `vm.zig`; SIMD kernels in `matrix_kernels.zig` — not re-benched this pass |

---

## 2. Execution backends

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Adapters zig_vm, ts_ffi, ts_wasm_vm, wasm_aot | **PROVEN** | `tests/parity/backends/*`; pipeline runs them |
| Same catalog + `compare.ts` | **PROVEN** | 629 cases; `tests/parity/compare.ts` |
| Full green on zig_vm / ts_ffi | **PROVEN** (artifact) | STATUS: 629 pass, 0 fail |
| ts_wasm_vm partial | **PROVEN** | 56 catalog skips; artifact 573 pass / 56 skip |
| wasm_aot nearly full | **PROVEN** | **Exactly 3** catalog skips = 2-arg `round` cases (`round_decimals_*`, `gauntlet_round_arity_2`) |
| wasm_aot_standalone budgeted | **PROVEN** | Budget max_skips=274 max_fails=0; artifact 355/274/0; unit tests green |
| “Four daily backends” wording | **nuance** | Daily **host** backends are four; **full** `mz` also runs standalone (fifth). Capabilities should say that (patched). |

---

## 3. WASM AOT

| Claim | Verdict | Evidence |
|-------|---------|----------|
| `mathzig compile` / `--standalone` / `--node` | **PROVEN** | `src/main.zig` usage; `src/wasm/compiler.zig`, `abi.zig` |
| `compile-graph` | **PROVEN** | `main.zig` compile-graph path; fuse lowerer; fused TS compile |
| Host env / delegated imports | **PRESENT** | `src/ts/aot_env.ts` (not deep-audited this pass) |
| Residual 2-arg `round` | **PROVEN residual** | 3 skips with notes `UnsupportedOpcode` |
| Hosts demos | **PRESENT** | `hosts/{wasmer,wasmedge,spin,common}` |

---

## 4. Graphs (dual model)

| Claim | Verdict | Evidence |
|-------|---------|----------|
| **TS multi-module loads wasm** | **PROVEN** | `src/ts/graph/runner.ts` `WebAssembly.instantiate`; `runBatch`, `setParam` |
| **Zig `GraphRunner` is VM-native, never loads .wasm** | **PROVEN** | File header + `wasm_memory_pages = 0`; dual-path expr only |
| Fuse lowerer + fused runner | **PROVEN** | `src/graph/fuse.zig`, `src/ts/graph/fused_runner.ts`, `fused_compile.ts`; fuse tests exist |
| CLI `graph run` | **PROVEN** | `main.zig` graph subcommand → `mathzig.graph.GraphRunner.loadWithContext` |
| 12 goldens × modes | **PROVEN** | `REQUIRED_GOLDEN_FILES` length 12; all files on disk; corpus documents `native_wasm` phase-2 skip |
| Cross-runner parity tests | **PROVEN** | `bun test …graph_cross_runner_parity` **pass** this pass |
| Shared-memory non-goal | **PRESENT** (historical measure) | Documented in graph tick baseline / old B4 results; not re-measured |
| Pure-wasm interpreter phase-2 | **PROVEN residual** | `NATIVE_WASM_SKIP_ID` in corpus |
| Console `/` + `/graph` | **PROVEN** | `apps/console/src/App.tsx` routes |

**Naming fix:** Do not say “Zig GraphRunner = multi-module wasm”. Multi-module wasm is **TS** `GraphRunner`. Zig `GraphRunner` = VM-native evaluator.

---

## 5. Host bindings & codegen

| Claim | Verdict | Evidence |
|-------|---------|----------|
| `api_definition.zig` + generated bindings | **PROVEN** | `src/bindings/generated/` exists; `zig build gen-bindings` step |
| TS FFI wrapper | **PROVEN** | `src/ts/mathzig.ts` + boundary tests listed in pipeline |

---

## 6. Product surfaces

| Claim | Verdict | Evidence |
|-------|---------|----------|
| CLI binary | **PROVEN** | `zig-out/bin/mathzig` present |
| TUI | **PRESENT** | `src/tui/` |
| Console app | **PROVEN** structure | Solid routes + graph editor components |
| Progress app | **PRESENT** | `apps/progress/`; fed by pipeline `buildAppData` |
| `web/` not product UI | **PROVEN** policy | Product routes under `apps/console` |

---

## 7. Quality system

| Claim | Verdict | Evidence |
|-------|---------|----------|
| `mz` stages correctness → measure → record | **PROVEN** | `tools/testing/pipeline.ts` header + steps |
| Strict bun + quarantine | **PROVEN** | Tool + STATUS PASS + 15 entries |
| Standalone budget may only shrink | **PROVEN** | Tool comment + unit tests |
| Graph soak in full mz | **PROVEN** | pipeline step `graph_soak` |
| Graph perf tripwire in full mz | **PROVEN** | pipeline + baseline file + tests pass |
| Adversarial in gate | **PRESENT** | `tests/adversarial/corpus` s1–s4; deep tool exists (default corpus inclusion not re-traced fully) |
| Docs truth generator | **PROVEN** | `tools/status_report.ts` |

---

## 8. Language themes (catalog-backed)

| Theme | Verdict | Evidence |
|-------|---------|----------|
| Core arithmetic / logic | **PROVEN** | `core_*`, `basic`, `chained_logic`, … |
| Control flow / shadowing | **PROVEN** | `compiler`, `jump_fusion`, `shadowing` |
| Matrices + slices | **PROVEN** | `matrix_*` files; MathJS slice cases **quarantined** (residual vs MathJS) |
| Complex | **PROVEN** partial | `complex.json`, `builtins_comb_complex` (re/im/arg/conj); some `ts_wasm_vm` skips |
| Units honesty | **PROVEN** | VM rejects unit-bearing mat elements; rocket tests quarantined for that honesty |
| Records | **PROVEN** | `records.json` field access; MathJS mutation **quarantined** |
| Series / indicators | **PROVEN** | many `timeseries*` + `builtins_ts` (sma/ema/rsi/bollinger/macd) |
| User fns / sequences | **PROVEN** | `dsl_functions.json` (`f(x)=…; f(10)`) |
| ODE / simulations | **PROVEN** | `ode*`, `simulations.json` (rocket/lorenz expressions) |
| LaTeX | **PROVEN** | `src/parser/latex.zig`; `toLaTeX` parity; console log rendering |
| Matrix×vector `gemv` | **PROVEN** with residual | parity present; some **standalone** skips |
| String comparison ops (open task 0095) | **WEAK** | No dedicated parity file found; string AOT latex cases exist |
| Complex pow/trig full (open task 0094) | **WEAK / residual** | Limited complex cases; not a full pow/trig matrix |
| Matrix integer power M^n | **RESIDUAL** | Explicit quarantine (MathJS) |

---

## 9. Open `docs/tasks/*.md` (36 notes)

**Not individually re-implemented-checked.**  
`status_matrix.md` still lists many PARTIAL/open/legacy. That is **backlog noise**, not product truth.

Safe rule after this pass:

- Treat **capabilities + STATUS + parity/goldens** as truth.
- Treat open task files as **unverified historical notes** until closed against a case id or deleted.

---

## 10. Capabilities doc corrections applied after this pass

1. Clarify **four host backends** + **standalone on full mz**.  
2. Clarify **TS GraphRunner** (wasm multi) vs **Zig GraphRunner** (VM-native).  
3. Link this verification report + stamp date.  
4. Soften open-task-adjacent themes (string compare / complex pow) as residual/weak where needed.

---

## 11. What would raise confidence further

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun run mz                    # full green + fresh STATUS
bun tools/status_report.ts
bun tests/soak/graph_soak.ts  # optional longer soak
```

Optional: delete or rewrite open `docs/tasks/*` that are fully superseded by green parity themes.
