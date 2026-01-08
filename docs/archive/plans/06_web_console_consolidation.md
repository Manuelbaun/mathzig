# Plan 06: Web Console Consolidation

**Priority:** 🟢 Medium · **Effort:** 1 day · **Risk:** Low

---

## Problem Statement

The `web/` directory contains **4 HTML files** representing different iterations of the web console, plus an `index_old.html` legacy version. This indicates iterative prototyping without cleanup.

---

## Current File Inventory

| File | Size | Purpose |
|------|------|---------|
| `index.html` | 29 KB | **Current main console** — full REPL with variable panel, plotting, demo commands |
| `index_2.html` | 11 KB | **MathJS rocket trajectory demo** — uses `unpkg.com/mathjs` + Chart.js, not MathZig at all |
| `index_3.html` | 20 KB | **VS Code-style redesign** — dark theme with JetBrains Mono, professional IDE aesthetics |
| `index_old.html` | 68 KB | **Legacy version** — monolithic, all-in-one file from early development |

### Supporting JS Modules (Already Modularized)
| File | Size | Role |
|------|------|------|
| `mathzig_runtime.js` | 16 KB | WASM loader and MathZig API wrapper |
| `console_controller.js` | 9.6 KB | Input handling, command dispatch |
| `ui_components.js` | 17 KB | DOM component factory |
| `plotting.js` | 10 KB | Chart.js integration |
| `variables_panel.js` | 2.2 KB | Variable inspector |
| `lorenz.js` | 6.6 KB | Lorenz attractor demo |
| `rocket_sim.js` | 11.8 KB | Rocket simulation (MathZig native) |
| `app_bootstrap.js` | 1.3 KB | App initialization |
| `logging.js` | 0.7 KB | Console logging utilities |
| `runtime_controller.js` | 0.8 KB | Runtime state management |
| `types.d.ts` | 4.7 KB | TypeScript type definitions |

The JS side is already well-modularized — the problem is purely the HTML variants.

---

## Analysis of Each Variant

### `index.html` (keep as primary)
The main console with the most features. Uses modular JS imports. This is the production version.

### `index_2.html` (archive or delete)
This is a **MathJS** demo page, not a MathZig page. It loads MathJS from a CDN and implements a rocket trajectory simulation entirely in vanilla JS + MathJS. Useful as a comparison reference but doesn't belong in the web console directory.

**Recommendation:** Move to `docs/comparisons/mathjs_rocket_demo.html` or delete.

### `index_3.html` (merge into index.html or promote)
A redesigned version with excellent VS Code-inspired aesthetics:
- Dark theme with CSS custom properties
- JetBrains Mono + Inter fonts
- Professional color scheme with syntax highlighting vars
- Better visual hierarchy

**Recommendation:** If this design is preferred, promote it to `index.html`. If not, archive it.

### `index_old.html` (delete)
At 68 KB, this monolithic file pre-dates the modular JS refactoring. It has no value now that the modular version exists.

**Recommendation:** Delete.

---

## Proposed Actions

### Option A: Minimal Cleanup
```bash
# Archive comparison demos
mkdir -p docs/comparisons
mv web/index_2.html docs/comparisons/mathjs_rocket_demo.html

# Delete legacy
rm web/index_old.html

# Rename if index_3 design is preferred
# mv web/index_3.html web/index.html
```

### Option B: Full Consolidation
1. Cherry-pick the VS Code theming from `index_3.html` into `index.html`
2. Delete `index_2.html`, `index_3.html`, `index_old.html`
3. Result: single `index.html` with the best design from all variants

---

## Verification

```bash
# Serve locally and verify the console works
cd web && python3 -m http.server 8080
# Open http://localhost:8080 in browser
# Test: basic eval, plotting, variable inspector, lorenz demo
```
