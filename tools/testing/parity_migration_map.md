# Parity Migration Map (Zig Domain Tests -> Parity Cases)

This map tracks where Zig-domain tests have parity JSON coverage.

## Parser / Compiler
- `tests/zig/parser/*` -> `tests/parity/cases/compiler.json`, `tests/parity/cases/diagnostics.json`

## DSL / Functions
- `tests/zig/dsl/*` -> `tests/parity/cases/dsl_functions.json`
- TODO: range overload + generator-specific parity vectors

## Core VM / Complex
- `tests/zig/core/*` -> `tests/parity/cases/core_arithmetic.json`, `tests/parity/cases/core_logic.json`, `tests/parity/cases/complex.json`, `tests/parity/cases/vm_baseline.json`

## Types (Units / Matrix / Records)
- `tests/zig/types/*` -> `tests/parity/cases/units.json`, `tests/parity/cases/matrix_ops.json`, `tests/parity/cases/matrix_slicing.json`, `tests/parity/cases/records.json`
- TODO: explicit unit decomposition parity vectors

## Time-Series
- `tests/zig/timeseries/*` -> `tests/parity/cases/timeseries.json`, `tests/parity/cases/timeseries_extended.json`, `tests/parity/cases/timeseries_stats.json`, `tests/parity/cases/timeseries_resampling.json`, `tests/parity/cases/timeseries_join.json`, `tests/parity/cases/timeseries_filters.json`, `tests/parity/cases/temporal.json`
- TODO: calculus scenario parity vectors

## ODE / Numerical Functions
- `tests/zig/functions/*` -> `tests/parity/cases/ode.json`, `tests/parity/cases/vector_ode.json`

## IO
- `tests/zig/io/*` -> `tests/parity/cases/csv.json`

## Diagnostics
- `tests/zig/diagnostics/*` -> TODO (error/diagnostic parity schema expansion)

## WASM Backend
- `tests/zig/backends/wasm/*` -> `tests/parity/cases/wasm_backend.json`

## Integration / Repro
- `tests/zig/integration/*`, `tests/zig/repro/*` -> TODO (promote stable repros into deterministic parity vectors)
