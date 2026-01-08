# MathZig

High-performance mathematical expression engine written in Zig.

**Version:** `0.1.0` (see `src/VERSION`)

---

## What MathZig is

A numeric expression engine with a native CLI/REPL, a terminal UI, and a browser console. You write math expressions, assign variables, plot results, and build graphs of connected compute nodes.

- **Language:** arithmetic, logic, matrices, complex numbers, units, records, timeseries indicators, user functions, ODE helpers, LaTeX output.
- **Surfaces:** REPL (`zig-out/bin/mathzig`), TUI (`zig build run`), web console with plots and a graph editor (`apps/console`).
- **Embeddable:** TypeScript bindings over FFI, a portable interpreter WASM module, and AOT-compiled expression/graph modules that run in browsers, edge runtimes, and native WASM hosts.

## How it works

Every expression follows one path:

```text
source text → tokenizer/parser (src/parser/) → AST → bytecode compiler → VM execution
```

The bytecode is the single intermediate representation. Everything downstream consumes it:

| Backend | Path | Role |
|---------|------|------|
| `zig_vm` | Native VM (`src/vm/`, SIMD-aware) | **Reference** — correctness truth |
| `ts_ffi` | TS → native library via C ABI (`src/ts/mathzig.ts`) | Native embed from TypeScript |
| `ts_wasm_vm` | Interpreter WASM module | Browser / portable VM |
| `wasm_aot` | Expression → freestanding WASM (`src/wasm/`) | Deployable artifacts |

All four run the same JSON parity vectors (`tests/parity/cases/*.json`) compared by one policy (`tests/parity/compare.ts`). The Zig VM defines correct answers; every other backend must match.

**Graphs** (connected compute nodes) have two models, deliberately:

- **Multi-module** — one WASM instance per node, host-mediated edges. Used for editing: recompile one node, keep the rest. This is the console `/graph` path.
- **Fused** — `mathzig compile-graph` lowers the whole graph into one module with internal edges. Used for export/ship: one `tick` entry, fewer host round-trips.

A third runner (`src/graph/runner.zig`) evaluates graphs VM-natively in-process for CLI and goldens.

**Bindings** are generated, not hand-written: one C-ABI definition (`src/api_definition.zig`) → generated exports (`zig build gen-bindings`). No drift between FFI and docs.

**Quality** runs through one daily gate:

```bash
bun run mz    # correctness → measure → package + progress dashboard data
```

Correctness runs before measurement; known failures are quarantined visibly (`tests/known_failures.json`), and unexpected fail/pass fails the gate.

## Why

MathJS and similar libraries cover breadth; MathZig covers speed. The goal is a REPL people open daily: instant evaluation, legible variable state, inline plots — then the same engine embedded in production via FFI or shipped as WASM.

Three reasons for the shape:

1. **One IR, many hosts.** Bytecode as the shared representation is what makes native, FFI, browser, and AOT parity possible. Without it, cross-host support collapses into ad-hoc ports that drift.
2. **Correctness before speed.** The Zig VM is the baseline; perf regressions are caught by measurement, wrong answers by parity. A fast wrong answer is worthless.
3. **Honest limits.** Unsupported operations hard-error or get quarantined — no silent wrong answers, no "standalone" that quietly means "half the language."

Design intent: [`PRODUCT.md`](./PRODUCT.md). Full capability inventory: [`docs/guides/capabilities.md`](./docs/guides/capabilities.md).

---

## Quick start

### Prerequisites

- [Zig](https://ziglang.org/) (match `build.zig.zon` / local toolchain)
- [Bun](https://bun.sh/)
- On macOS, put the SDK shim first if `zig build` needs it:

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
```

### Build

```bash
# Native CLI + shared library
zig build

# REPL
zig build repl
# or
./zig-out/bin/mathzig

# TUI
zig build run

# Interpreter WASM (console / browser)
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
# also: zig build wasm   # builds + copies into web/
```

### Web console (product UI)

```bash
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
cp zig-out/bin/mathzig_wasm.wasm apps/console/public/
zig build                     # native binary for graph AOT APIs
bun install --cwd apps/console
bun run --cwd apps/console dev
```

- Console: http://localhost:5173/
- Graph editor: http://localhost:5173/graph

Full guide: [`apps/console/README.md`](./apps/console/README.md).

> `web/` holds a copied WASM artifact only. **Do not treat `web/` as the product UI.**

### Daily test pipeline (one way only)

```bash
bun run mz                    # correctness → measure → record
bun run mz where              # artifact paths
bun run mz -- --quick         # faster parity while iterating
bun run mz -- --skip-measure  # correctness + package only
```

Details: [`AGENTS.md`](./AGENTS.md), [`docs/guides/testing.md`](./docs/guides/testing.md).

### Progress dashboard

```bash
bun run mz                    # writes apps/progress/public/data/
cd apps/progress && bun run dev   # http://localhost:5174
```

---

## Native CLI (selected)

```bash
zig build   # → zig-out/bin/mathzig
```

| Command | Purpose |
|---------|---------|
| `mathzig` | Interactive REPL (no args) |
| `mathzig compile -i expr.mz -o out.wasm` | Single-expression AOT |
| `mathzig compile --node …` | Single-node module + `.node.json` |
| `mathzig compile-graph -i graph.json -o out.wasm` | Fused graph → one module + `.graph.json` |
| `mathzig graph run graph.json` | VM-native graph evaluator (in-process; no .wasm load) |

See [`docs/COMMANDS.md`](./docs/COMMANDS.md) and [`docs/guides/wasm_aot_usage.md`](./docs/guides/wasm_aot_usage.md).

---

## Repository layout

```text
.
├── AGENTS.md                 # Agent contract (CLAUDE.md / GEMINI.md → symlink)
├── PRODUCT.md                # Product intent & UI principles
├── DESIGN.md                 # Console design tokens / system
├── src/                      # Zig engine + TS bindings
│   ├── main.zig              # CLI entry (REPL, compile, graph)
│   ├── mathzig.zig           # Public Zig module root
│   ├── core/  parser/  vm/   # Values, compile, bytecode VM
│   ├── wasm/                 # AOT compiler, ABI, manifests
│   ├── graph/                # VM-native graph evaluator + fuse
│   ├── ts/                   # TS FFI/WASM + graph runners
│   ├── functions/ timeseries/ units/ memory/ io/ tui/
│   └── bindings/             # Generated C-ABI / TS artifacts
├── apps/
│   ├── console/              # Product web UI (REPL + graph)
│   └── progress/             # Progress / regression dashboard
├── tests/
│   ├── parity/cases/         # Canonical cross-backend JSON vectors
│   ├── zig/  ts/  performance/
│   └── artifacts/            # Generated (gitignored except .gitkeep)
├── tools/
│   ├── mz/                   # Daily test CLI
│   ├── testing/              # Pipeline, parity helpers, escapes
│   ├── progress/             # Package + app-data builders
│   └── bindings/ wasm/ bench/
├── hosts/                    # External AOT host examples
├── bench/                    # Feature / reference benches
└── docs/                     # STATUS, FOCUS, guides, memory, archive
```

---

## Documentation map

| Doc | Contents |
|-----|----------|
| [`docs/guides/capabilities.md`](./docs/guides/capabilities.md) | **What is implemented, how & why** |
| [`docs/STATUS.md`](./docs/STATUS.md) | **Live status** (`bun tools/status_report.ts`) |
| [`docs/FOCUS.md`](./docs/FOCUS.md) | Current short-term focus |
| [`AGENTS.md`](./AGENTS.md) | Agent contract |
| [`docs/README.md`](./docs/README.md) | Docs map |
| [`docs/guides/testing.md`](./docs/guides/testing.md) | `mz` pipeline + parity schema |
| [`docs/guides/quality.md`](./docs/guides/quality.md) | Gate, quarantine, progress |
| [`docs/guides/graphs.md`](./docs/guides/graphs.md) | Multi-module / fused / VM-native graphs |
| [`docs/COMMANDS.md`](./docs/COMMANDS.md) | Commands, artifacts, CLI flags |
| [`docs/guides/overview.md`](./docs/guides/overview.md) | Architecture & directory guide |
| [`docs/guides/web_console.md`](./docs/guides/web_console.md) | Console / graph usage |
| [`docs/guides/wasm_aot_usage.md`](./docs/guides/wasm_aot_usage.md) | Consuming AOT / fused modules |
| [`docs/ROADMAP.md`](./docs/ROADMAP.md) | Strategic summary |
| [`PRODUCT.md`](./PRODUCT.md) | Users, purpose, brand |
| [`hosts/README.md`](./hosts/README.md) | Wasmer / WasmEdge / Spin hosts |

---

## License

See [`LICENSE`](./LICENSE).
