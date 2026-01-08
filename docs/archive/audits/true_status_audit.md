# True Task Status Audit

Generated: 2026-07-15T11:35:07Z

Verification method: static probes of code, tests, and last progress package artifacts for every **open / in-progress / partial / unknown** task (41 items). Not a fresh full `bun run mz` run.

## Summary

| Verdict | Count | Meaning |
|---|---:|---|
| DONE | 2 | Work present; close task doc |
| DONE_WITH_TAIL | 5 | Main work done; small leftover / bookkeeping |
| LIKELY_SUPERSEDED | 1 | Absorbed by later tasks; close/merge |
| SUPERSEDED | 1 | Replaced by different implementation |
| PARTIAL | 14 | Some work landed; goals incomplete |
| OPEN | 17 | Not done |
| UNKNOWN | 1 | Needs runtime repro |
| **Total audited** | **41** | |

### Headline

- **Closeable / bookkeeping:** 9 tasks (done, done-with-tail, superseded)
- **Still real work:** 32 tasks (partial + open + unknown)
- **Last full green package (2026-07-10):** zig_vm & ts_ffi 534/534; ts_wasm_vm 469 pass + **65 skip**; wasm_aot 533 pass + 1 skip

## Matrix

| Task | Claimed | True status | Evidence / notes |
|---|---|---|---|
| `0029_elementwise_power_fix` | UNKNOWN/missing status | **DONE** | epow opcode+Value.epow present=True — Feature implemented; close task header. |
| `0031_dynamic_field_access_crash` | UNKNOWN checkboxes 0/16 | **DONE** | rec_get_dyn in VM=True; parent 0012 completed=True — Crash path fixed under 0012; leftover checklist is defensive asserts (optional). |
| `0016_abi_smith_kit` | Mostly Implemented | **DONE_WITH_TAIL** | api_definition=True; abi_inspector=True; generated/exports.zig=True; classes.ts=True — Kit is real; remaining is ongoing parity maintenance. |
| `0042_wasm_implementation` | 90% | **DONE_WITH_TAIL** | mathzig_wasm.ts=True; wasm_backend.ts=True; web/mathzig_wasm.wasm=True — Only leftover checkbox: measure FFI vs WASM perf delta. |
| `0065_web_ui_componentization` | In Progress | **DONE_WITH_TAIL** | apps/console/src/components has dirs: vars, plot, shell, panels, graph, repl (Solid app) — Legacy web/index.html task largely superseded by componentized apps/console. Close task; any residual is polish. |
| `0079_1_vm_audit` | In Progress | **DONE_WITH_TAIL** | Child tasks 0079.5/.6/.7/.15/.16 all marked complete; StackOverflow error type exists — Parent audit document never closed; actionable children done. Close parent or convert remaining notes to new tasks. |
| `0079_2_wasm_backend_audit` | In Progress | **DONE_WITH_TAIL** | Child tasks 0079.9–.14 all marked complete — Parent audit open only as bookkeeping; close parent. |
| `0067_wasm_aot_bugfixes` | Todo | **LIKELY_SUPERSEDED** | 0080 complete=True; 0079_24 complete=True — Later AOT parity tasks subsume this; close or retarget residual bugs only. |
| `0058_matrix_chartjs_integration` | In Progress | **SUPERSEDED** | chart_utils.test.ts=False; plotly_refs=69; uplot_refs=15 — Console uses Plotly/uPlot, not Chart.js. Close as superseded. |
| `0000_testing` | In Progress | **PARTIAL** | requested catalogs present=['matrix_units', 'metadata_api', 'probability', 'simulations', 'timeseries_master']; total_cases=53; gatekeeper.sh=False; mz=True — Catalogs partially exist; gatekeeper replaced by bun run mz; IBP checklist inc... |
| `0000_zero_regression_infrastructure` | In Progress | **PARTIAL** | gauntlet=True; builtins cases=['builtins_comb_complex', 'builtins_linalg', 'builtins_math', 'builtins_nt', 'builtins_stats', 'builtins_trig', 'builtins_ts'] — Evergreen IBP; catalog expanded, not closed. |
| `0017_full_api_surface_testing` | In Progress | **PARTIAL** | files=['tests/ts/parity/api_surface.test.ts', 'tests/parity/cases/api_surface.json', 'tests/zig/integration/api_surface_e2e.zig']; parity_case api_surface=True — Some API surface coverage; not every generated method audited. |
| `0028_vm_memory_and_alignment_fixes` | In Progress | **PARTIAL** | Task body: ~25 checkboxes done, 3 residual failures (csv headers, sma expectation, compile-error leaks) — Core memory/alignment work landed; residual test debt. |
| `0034_series_display_improvements` | Not Started | **PARTIAL** | fancy series preview in mathzig=True; in tui=True — Some series formatting exists in mathzig/tui; task-specific abbreviated preview checklist not clearly fully met. |
| `0061_4_linking_runtime` | In Progress | **PARTIAL** | standalone flag present=True; src/wasm/runtime/=False; linked runtime wasm scaffold missing — Standalone mode started; linked shared runtime library not built. |
| `0061_6_timeseries_engine` | Planned | **PARTIAL** | series in wasm compiler=True; series_aot case=True — Partial AOT series support via host imports; full engine port open. |
| `0064_web_ui_flexible_plotting` | Todo | **PARTIAL** | console plot-related files=['plotly.ts', 'plot_parse.test.ts', 'plot_parse.ts', 'PlotHost.tsx'] — Plotting exists in apps/console; formal notebook-style history API may still be incomplete. |
| `0079_21_wasm_value_repr_perf` | In Progress | **PARTIAL** | Task file shows investigation checkboxes checked; no clear finish claim — Investigation partial; not a closed optimization. |
| `0079_8_wasm_opcode_coverage` | Todo | **PARTIAL** | UnsupportedOpcode handling present=True — Hard fail path exists; full opcode matrix / policy still a gap. |
| `0090_matrix_vector_multiply` | Open | **PARTIAL** | Value.mul vector-dim logic=False; gemv present=True — Kernel GEMV exists; MathJS dimension edge-cases may still fail. |
| `0094_complex_pow_and_trig` | Open | **PARTIAL** | Complex methods: abs,add,arg,conj,div,exp,log,mul,neg,pow,sqrt,sub — missing sin/cos/tan on Complex — pow/exp/log/abs present; trig on complex still missing for MathJS parity. |
| `0095_string_comparison_operators` | Open | **PARTIAL** | equals handles string=True; ordering ops unclear — Equality may work; relational string ops likely missing. |
| `0096_builtin_function_gauntlet_parity` | In Progress | **PARTIAL** | zeros/ones LIFO order is correct (pop cols then rows); gauntlet cases exist; last package: zig_vm 534/0, ts_ffi 534/0, ts_wasm_vm 469 pass+65 skip, wasm_aot 533 pass+1 skip — Atomic zeros/ones fix appears DONE in code. Full IBP / multi-b... |
| `0019_accumulator_array_vecdot` | Draft | **OPEN** | vecDot present=True; accumulator mentions in matrix_kernels=1 — Proposal not implemented as described. |
| `0033_test_expectation_fixes` | Not Started | **OPEN** | error_validation files=[PosixPath('tests/zig/diagnostics/error_validation.zig')]; sma_hint=tests/zig/diagnostics/error_validation.zig:144:test "VM: sma rejects non-number period" { — Small test-only task; no evidence of fix applied. |
| `0059_adaptive_ode_solver` | Not Started | **OPEN** | adaptive keywords in ode.zig=False; ode_lines=489 — Fixed-step ODE exists; adaptive solver not present. |
| `0060_ode_solver_hardening_optimization` | Not Started | **OPEN** | No dedicated hardening task artifacts beyond base ode.zig — Not started. |
| `0061_5_advanced_control_flow` | Planned | **OPEN** | relooper/CFG implementation markers=False — Not implemented (pattern matching only for simple loops). |
| `0061_7_optimizations` | Planned | **OPEN** | peephole/simd markers in wasm compiler=False — Planned WASM-specific opts not landed as a coherent task. |
| `0068_diff_matrix_and_adaptive_ode` | Todo | **OPEN** | matrixDiff/diff matrix impl=False; adaptive ODE=False — Not implemented. |
| `0073_web_worker_support` | Todo | **OPEN** | worker-named files (excl node_modules)=['libs/ggml/src/ggml-hexagon/htp/worker-pool.c', 'libs/ggml/src/ggml-hexagon/htp/worker-pool.h', 'libs/tigerbeetle/src/docs_website/src/service_worker_writer.zig', 'libs/tigerbeetle/src/docs_website... |
| `0076_execution_tracking_specialization` | Analysis Phase | **OPEN** | execution_count/specialization markers in vm=True — Analysis only; not implemented. |
| `0081_wasm_compare_releasefast_profile` | Todo | **OPEN** | wasm_compare tool=True; 0082 histogram done=False — Compare infra exists; ReleaseFast profile task itself not closed. |
| `0085_fix_round_n_decimals` | Open | **OPEN** | round handler body snippet='if (arg_count < 1) return error.NotEnoughArgs;\n                const a = (try self.pop());\n                const n = a.toNumber() orelse return error.TypeError;' — Confirmed 1-arg only (@round); 2-arg decima... |
| `0086_named_function_aliases` | Open | **OPEN** | builtin name 'add'=False; subtract/sub name=False; sample names=[] — Operator add exists; function-form aliases like add(a,b) not registered as builtins. |
| `0087_boolean_coercion_arithmetic` | Open | **OPEN** | Value.add mentions boolean=False — No boolean coercion in arithmetic add path found. |
| `0089_elementwise_function_dispatch` | Open | **OPEN** | sin handler matrix-aware=False; general elementwise dispatch=True — Unary math on matrices not generally dispatched elementwise. |
| `0091_matrix_power_operator` | Open | **OPEN** | Value.pow handles number/unit/complex only; no matrix integer power path — Not implemented. |
| `0092_matrix_division` | Open | **OPEN** | Value.div matrix/inv path=False; inv builtin=True — inv exists; A/B => A*inv(B) for matrices not clearly wired in div. |
| `0097_wasm_aot_real_standalone_matrix` | Todo | **OPEN** | standalone mode code present=True; addImport sites=6 — True zero-import standalone runtime matrix not finished. |
| `0088_fix_unit_subtraction` | Open | **UNKNOWN** | Value.sub mentions unit=True; units.json exists=True — Needs runtime repro of specific bug; cannot close from static scan. |

## Close these docs now (low/no code)

- `0016_abi_smith_kit` → **DONE_WITH_TAIL** — Kit is real; remaining is ongoing parity maintenance.
- `0029_elementwise_power_fix` → **DONE** — Feature implemented; close task header.
- `0031_dynamic_field_access_crash` → **DONE** — Crash path fixed under 0012; leftover checklist is defensive asserts (optional).
- `0042_wasm_implementation` → **DONE_WITH_TAIL** — Only leftover checkbox: measure FFI vs WASM perf delta.
- `0058_matrix_chartjs_integration` → **SUPERSEDED** — Console uses Plotly/uPlot, not Chart.js. Close as superseded.
- `0065_web_ui_componentization` → **DONE_WITH_TAIL** — Legacy web/index.html task largely superseded by componentized apps/console. Close task; any residual is polish.
- `0067_wasm_aot_bugfixes` → **LIKELY_SUPERSEDED** — Later AOT parity tasks subsume this; close or retarget residual bugs only.
- `0079_1_vm_audit` → **DONE_WITH_TAIL** — Parent audit document never closed; actionable children done. Close parent or convert remaining notes to new tasks.
- `0079_2_wasm_backend_audit` → **DONE_WITH_TAIL** — Parent audit open only as bookkeeping; close parent.

## Still real work

### P0 / focus
- `0096_builtin_function_gauntlet_parity` (**PARTIAL**) — Atomic zeros/ones fix appears DONE in code. Full IBP / multi-backend baseline still open due to ts_wasm_vm skips and remaining parity gaps.
- `0097_wasm_aot_real_standalone_matrix` (**OPEN**) — True zero-import standalone runtime matrix not finished.
- `0000_testing` (**PARTIAL**) — Catalogs partially exist; gatekeeper replaced by bun run mz; IBP checklist incomplete.
- `0000_zero_regression_infrastructure` (**PARTIAL**) — Evergreen IBP; catalog expanded, not closed.

### WASM AOT roadmap tail
- `0061_4_linking_runtime` (**PARTIAL**) — Standalone mode started; linked shared runtime library not built.
- `0061_5_advanced_control_flow` (**OPEN**) — Not implemented (pattern matching only for simple loops).
- `0061_6_timeseries_engine` (**PARTIAL**) — Partial AOT series support via host imports; full engine port open.
- `0061_7_optimizations` (**OPEN**) — Planned WASM-specific opts not landed as a coherent task.
- `0079_8_wasm_opcode_coverage` (**PARTIAL**) — Hard fail path exists; full opcode matrix / policy still a gap.
- `0097_wasm_aot_real_standalone_matrix` (**OPEN**) — True zero-import standalone runtime matrix not finished.

### MathJS defect backlog
- `0085_fix_round_n_decimals` (**OPEN**) — Confirmed 1-arg only (@round); 2-arg decimals not implemented.
- `0086_named_function_aliases` (**OPEN**) — Operator add exists; function-form aliases like add(a,b) not registered as builtins.
- `0087_boolean_coercion_arithmetic` (**OPEN**) — No boolean coercion in arithmetic add path found.
- `0088_fix_unit_subtraction` (**UNKNOWN**) — Needs runtime repro of specific bug; cannot close from static scan.
- `0089_elementwise_function_dispatch` (**OPEN**) — Unary math on matrices not generally dispatched elementwise.
- `0090_matrix_vector_multiply` (**PARTIAL**) — Kernel GEMV exists; MathJS dimension edge-cases may still fail.
- `0091_matrix_power_operator` (**OPEN**) — Not implemented.
- `0092_matrix_division` (**OPEN**) — inv exists; A/B => A*inv(B) for matrices not clearly wired in div.
- `0094_complex_pow_and_trig` (**PARTIAL**) — pow/exp/log/abs present; trig on complex still missing for MathJS parity.
- `0095_string_comparison_operators` (**PARTIAL**) — Equality may work; relational string ops likely missing.

### Solvers / UI / other
- `0059_adaptive_ode_solver` (**OPEN**) — Fixed-step ODE exists; adaptive solver not present.
- `0060_ode_solver_hardening_optimization` (**OPEN**) — Not started.
- `0068_diff_matrix_and_adaptive_ode` (**OPEN**) — Not implemented.
- `0064_web_ui_flexible_plotting` (**PARTIAL**) — Plotting exists in apps/console; formal notebook-style history API may still be incomplete.
- `0073_web_worker_support` (**OPEN**) — No mathzig_worker.js / dedicated worker integration found.
- `0076_execution_tracking_specialization` (**OPEN**) — Analysis only; not implemented.
- `0019_accumulator_array_vecdot` (**OPEN**) — Proposal not implemented as described.
- `0017_full_api_surface_testing` (**PARTIAL**) — Some API surface coverage; not every generated method audited.
- `0028_vm_memory_and_alignment_fixes` (**PARTIAL**) — Core memory/alignment work landed; residual test debt.
- `0033_test_expectation_fixes` (**OPEN**) — Small test-only task; no evidence of fix applied.
- `0034_series_display_improvements` (**PARTIAL**) — Some series formatting exists in mathzig/tui; task-specific abbreviated preview checklist not clearly fully met.
- `0081_wasm_compare_releasefast_profile` (**OPEN**) — Compare infra exists; ReleaseFast profile task itself not closed.
- `0079_21_wasm_value_repr_perf` (**PARTIAL**) — Investigation partial; not a closed optimization.

## Method limits

- Static analysis can miss runtime-only bugs (e.g. **0088** unit subtraction).
- Task docs and mission manifests remain out of date; regenerate `status_matrix.md` from this audit if desired.
- July 14 run was incomplete (baseline only); do not treat it as a full gate.
