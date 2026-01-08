# Web assets

## Graph demo (task-09 / B3 + task-17 smoke)

Live-tunable node graph driven by the **same** TypeScript sources as bun tests:

| Runtime | Graph code |
|---------|------------|
| bun tests | `src/ts/graph/*` (direct import) |
| browser  | `web/graph_bundle.js` ← built from `src/ts/graph/*` via `web/graph_entry.ts` |

No forks. Controller UI: `web/graph_controller.js` (no bun-only APIs).

### Architecture deviation (task-09 intent vs today)

task-09 specified a **static browser path** via injected `MathZigWasm` (no
bun-only APIs; pure static serve of `web/`).

**What actually shipped / what CI smokes today:**

- Compile for expr nodes goes through **`POST /api/aot_compile?params=N`** on
  `web/graph_demo_server.ts`, which shells out to the native **`zig-out/bin/mathzig`**
  binary and returns wasm bytes.
- Static-only serve (`python3 -m http.server --directory web`) can load assets
  but **cannot** Load/tick expr graphs without that API.
- Restoring a pure static `MathZigWasm` compile path is a **product decision**
  (not done in task-17). Smoke tests target the demo **as it actually works**.

### Build + serve

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
zig build                              # zig-out/bin/mathzig for AOT compile
bun tools/build_graph_bundle.ts        # → web/graph_bundle.js
bun web/graph_demo_server.ts           # http://localhost:8787/graph_demo.html
```

### Selfcheck (no playwright — bun controller logic)

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun web/graph_demo.selfcheck.ts
```

### Playwright chromium smoke (task-17 / C6)

Tagged **smoke** (like task-16 `soak`): excluded from `mz --quick`, included in
full `bun run mz` as step `browser_smoke`.

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
# needs: zig build + playwright chromium (bun install && bunx playwright install chromium)
bun tests/browser/graph_demo.smoke.ts
# or:
bun test tests/browser/graph_demo.smoke.ts
```

Asserts: zero console errors; example graph Load; tick renders output; param
slider changes next tick.

### Param slider range heuristic

Documented in `graph_controller.js` / the demo page:

- default ∈ [0, 1] → range 0..1, step 0.01  
- default ∈ (1, 10] → range 0..2×default, step 0.1  
- otherwise → default ± max(10, |default|×10)

---

## Legacy console

The browser console was moved to **`apps/console`** (SolidJS + Vite + Tailwind).

Legacy vanilla sources are archived at:

- `docs/archive/web_console_legacy/`

MathJS comparison demo:

- `docs/comparisons/mathjs_rocket_demo.html`

## Run the console

```bash
# from repo conventions / apps/console package scripts
cd apps/console && bun run dev
```

See `docs/guides/web_console.md`.

Static serve of this folder (assets only — no AOT compile API):

```bash
python3 -m http.server 8080 --directory web
```
