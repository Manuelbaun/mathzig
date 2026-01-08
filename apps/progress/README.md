# MathZig Progress (`apps/progress`)

SolidJS + Vite + Tailwind dashboard for versioned progress packages: correctness, feature matrix, and performance trends.

**No MathZig WASM engine dependency.** The app reads static JSON under `public/data/` generated from `tests/artifacts/progress/`.

Sibling to [`apps/console`](../console) — same stack, separate package.

---

## Routes

| Path | Purpose |
|------|---------|
| `/` | Overview (latest package summary) |
| `/trends` | Perf trends over versions |
| `/regressions` | Pairwise regression board (`latest_compare.json`) |
| `/features` | Feature × backend matrix |
| `/versions` | Package list |
| `/versions/:id` | Package detail |

---

## Generate data

**Normal path:** `bun run mz` from the repo root always writes a progress package and refreshes dashboard data. No manual packaging step.

After every full `mz` run:

| Path | Role |
|------|------|
| `tests/artifacts/progress/packages/<version_id>/` | Append-only package (+ compare vs previous when available) |
| `tests/artifacts/progress/index.json` | Registry |
| `apps/progress/public/data/index.json` | Package list |
| `apps/progress/public/data/packages.json` | Slim packages for UI |
| `apps/progress/public/data/series.json` | Perf trends |
| `apps/progress/public/data/latest_compare.json` | Auto latest vs previous |
| `apps/progress/public/data/features_latest.json` | Latest feature matrix |

Automatic package tag / label: `{branch}__{UTC_time}__{short_sha}[__dirty]`.

### Manual rebuild (escape)

If packages exist but you only need to re-flatten app data:

```bash
bun run --cwd apps/progress app-data
# or
bun ../../tools/progress/build_app_data.ts   # from apps/progress
```

`dev` / `build` scripts also run `build_app_data.ts` first.

Without data, the UI shows that no packages are available — run `bun run mz` first. Need two full runs (with measure) before a meaningful compare pair exists.

---

## Develop

```bash
# From repo root
bun run mz                              # produce packages + public/data
bun install --cwd apps/progress
bun run --cwd apps/progress dev         # http://localhost:5174
```

`dev` uses port **5174** (console uses 5173).

---

## Build

```bash
bun run --cwd apps/progress build
bun run --cwd apps/progress preview
```

---

## Architecture

- `src/lib/data.ts` — fetch helpers for `/data/*.json`
- `src/components/` — shell, machine banner, etc.
- `src/pages/*` — routes for overview, trends, regressions, features, versions
- Data builders: `tools/progress/*` (invoked by `mz` and by this package’s scripts)

Stack: solid-js, @solidjs/router, vite, vite-plugin-solid, tailwindcss v4.

See also: [`docs/guides/testing.md`](../../docs/guides/testing.md), [`tools/README.md`](../../tools/README.md), [`AGENTS.md`](../../AGENTS.md).
