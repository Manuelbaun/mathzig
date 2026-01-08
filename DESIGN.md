---
name: MathZig Console
description: A dense, IDE-native REPL for evaluating mathematical expressions in the browser and terminal.
colors:
  hue-neutral: 255
  bg-app: "oklch(19% 0.006 255)"
  bg-panel: "oklch(23% 0.007 255)"
  bg-inset: "oklch(16% 0.005 255)"
  bg-active: "oklch(29% 0.009 255)"
  bg-overlay: "oklch(25% 0.008 255)"
  bg-raised: "oklch(21% 0.007 255)"
  border-subtle: "oklch(38% 0.010 255)"
  border-focus: "oklch(70% 0.14 215)"
  fg-primary: "oklch(90% 0.005 255)"
  fg-secondary: "oklch(68% 0.008 255)"
  fg-muted: "oklch(62% 0.007 255)"
  syntax-keyword: "oklch(76% 0.13 230)"
  syntax-number: "oklch(82% 0.11 155)"
  syntax-string: "oklch(80% 0.11 45)"
  syntax-type: "oklch(78% 0.12 195)"
  syntax-function: "oklch(86% 0.09 95)"
  syntax-variable: "oklch(80% 0.12 275)"
  syntax-operator: "oklch(84% 0.004 255)"
  syntax-comment: "oklch(60% 0.05 145)"
  status-error: "oklch(74% 0.16 22)"
  status-success: "oklch(76% 0.13 150)"
  status-warn: "oklch(82% 0.13 80)"
typography:
  body:
    fontFamily: "Inter, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  mono:
    fontFamily: "JetBrains Mono, Fira Code, Consolas, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Inter, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "0.5px"
  title:
    fontFamily: "Inter, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "13px"
    fontWeight: 600
    lineHeight: 1.3
rounded:
  sm: "3px"
  md: "6px"
  lg: "8px"
  pill: "12px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
components:
  button-ghost:
    backgroundColor: "{colors.bg-active}"
    textColor: "{colors.fg-secondary}"
    rounded: "{rounded.lg}"
    padding: "4px 8px"
  button-ghost-hover:
    backgroundColor: "{colors.bg-active}"
    textColor: "{colors.fg-primary}"
    rounded: "{rounded.lg}"
    padding: "4px 8px"
  button-ghost-danger:
    backgroundColor: "{colors.bg-active}"
    textColor: "{colors.status-error}"
    rounded: "{rounded.lg}"
    padding: "4px 8px"
  input-repl:
    backgroundColor: "transparent"
    textColor: "{colors.fg-primary}"
    typography: "mono"
    padding: "0"
  panel-header:
    backgroundColor: "{colors.bg-panel}"
    textColor: "{colors.fg-secondary}"
    typography: "label"
    padding: "10px 16px"
  list-item:
    backgroundColor: "transparent"
    textColor: "{colors.fg-primary}"
    typography: "mono"
    padding: "6px 14px"
  status-indicator:
    backgroundColor: "{colors.bg-active}"
    textColor: "{colors.fg-secondary}"
    rounded: "{rounded.pill}"
    padding: "5px 10px"
---

# Design System: MathZig Console

## Overview

**Creative North Star: "The Clear Instrument"**

MathZig Console is a workstation surface for engineers and scientists who evaluate expressions, inspect variables, and plot results without leaving a REPL mindset. The interface borrows the spatial logic of an IDE (header, sidebar, console, input bar) but strips away file-tree chrome. Density is a feature: monospace output, tight panel headers, and syntax-colored values let users scan numbers and types at speed.

The system is dark-first because the primary scene is a developer at a desk, often in a dim room, running repeated evaluations while watching console output and variable state. Surfaces use cool slate neutrals (hue 255) for clarity over long sessions; syntax hues are independent and never bleed warmth into chrome.

The web console (`apps/console`) and terminal UI (`src/tui/`) share the same mental model: history above, variables to the side, prompt below. Visual tokens in this document apply to the web surface; the TUI inherits the hierarchy through terminal colors and layout regions rather than CSS.

**Key Characteristics:**
- IDE-native three-pane layout: sidebar (260px), console (flex), input bar (fixed bottom)
- Syntax-colored output mirroring a code editor token palette
- Compact 11–13px type scale tuned for data density, not marketing display
- Tonal layering for depth; shadows reserved for modals and status glow
- REPL-first interaction: keyboard history, click-to-insert examples, variable inspector

## Colors

A restrained technical palette: cool slate surfaces (`--hue-neutral: 255`) with a full syntax spectrum for semantic coloring, not decoration. Canonical values are OKLCH design tokens carried into `apps/console` styles (and historically mirrored in the archived `web/` console).

### Primary
- **Focus Cyan** (`--border-focus`, `oklch(70% 0.14 215)`): Focus rings and interactive emphasis. The only non-syntax accent used for UI chrome.

### Secondary
- **Syntax Keyword Blue** (`--color-keyword`, `oklch(76% 0.13 230)`): Keywords, prompt symbol, slider thumbs, loader bar, REPL caret. Carries structural emphasis in code-like contexts.

### Tertiary
- **Syntax Type Aqua** (`--color-type`, `oklch(78% 0.12 195)`): Type names, matrix results, inspector badges. Used when the value's type matters more than its magnitude.

### Neutral
- **App Slate** (`--bg-app`, `oklch(19% 0.006 255)`): App background. The base canvas.
- **Panel Slate** (`--bg-panel`, `oklch(23% 0.007 255)`): Sidebar, header, input bar. One step lighter than app.
- **Console Inset** (`--bg-inset`, `oklch(16% 0.005 255)`): Main output scroller. Recessed reading surface.
- **Active Row** (`--bg-active`, `oklch(29% 0.009 255)`): Hover and selection fills.
- **Overlay Slate** (`--bg-overlay`, `oklch(25% 0.008 255)`): Inspector modal background.
- **Raised Surface** (`--bg-raised`, `oklch(21% 0.007 255)`): Plot entries and chart cells.
- **Primary Text** (`--fg-primary`, `oklch(90% 0.005 255)`): Body and result text.
- **Secondary Text** (`--fg-secondary`, `oklch(68% 0.008 255)`): Panel labels, placeholders, metadata.
- **Muted Text** (`--fg-muted`, `oklch(62% 0.007 255)`): Timestamps, collapsible markers, preview labels. Meets WCAG AA (≥4.5:1) on app, panel, and inset surfaces.
- **Subtle Border** (`--border-subtle`, `oklch(38% 0.010 255)`): Panel dividers, table cells, ghost button strokes.

### Syntax (semantic, not decorative)
- **Number Mint** (`--color-number`, `oklch(82% 0.11 155)`): Numeric literals and variable values.
- **String Apricot** (`--color-string`, `oklch(80% 0.11 45)`): String results.
- **Function Wheat** (`--color-function`, `oklch(86% 0.09 95)`): Constants and function names.
- **Variable Periwinkle** (`--color-variable`, `oklch(80% 0.12 275)`): Variable identifiers and LaTeX output.
- **Operator Neutral** (`--color-operator`, `oklch(84% 0.004 255)`): Operators (reserved for future syntax highlighting).
- **Comment Sage** (`--color-comment`, `oklch(60% 0.05 145)`): Comments (reserved for future syntax highlighting).

### Status
- **Success Green** (`--status-success`, `oklch(76% 0.13 150)`): Ready state dot, success log markers.
- **Error Coral** (`--status-error`, `oklch(74% 0.16 22)`): Error results, danger-adjacent actions.
- **Warn Amber** (`--status-warn`, `oklch(82% 0.13 80)`): Warning states (reserved).

### Named Rules
**The Syntax-Only Color Rule.** Syntax palette colors appear only on typed content (keywords, numbers, strings, types). UI chrome stays neutral slate plus Focus Cyan. Never splash syntax aqua on a button background.

**The Tonal Depth Rule.** Surface hierarchy is conveyed by background step (`inset` → `app` → `raised` → `panel` → `active`), not by colored side stripes or gradient fills on panels.

## Typography

**Display Font:** Inter (with system-ui fallback) — used sparingly; this system has no marketing display type.

**Body Font:** Inter (with -apple-system, BlinkMacSystemFont fallback)

**Label/Mono Font:** JetBrains Mono (with Fira Code, Consolas fallback)

**Character:** Inter handles UI labels and metadata with calm neutrality. JetBrains Mono carries every expression, result, and variable name. The pairing signals "tool, not brochure."

### Hierarchy
- **Display** (600, 14px, 1.3): Brand wordmark and loader title only. Rare.
- **Headline** (600, 13px, 1.3): Window titles, plot titles, inspector variable names.
- **Title** (600, 11px, 1.3, uppercase, 0.5px tracking): Panel headers ("Variables / Memory", "Quick Ref"). All-caps section labels.
- **Body** (400, 13px, 1.5): Console output, default UI text. Max ~75ch for prose blocks; data columns may run wider.
- **Label** (400–600, 10–11px, 1.3–1.6): Shortcut hints, log metadata, type badges, kbd labels. Uppercase only on panel headers and toolbar.

### Named Rules
**The Mono-for-Data Rule.** Any user-authored or computed value renders in JetBrains Mono. Inter is for chrome, never for numbers the user is evaluating.

**The Fixed Scale Rule.** Type sizes are fixed rem/px steps (9, 10, 11, 12, 13, 14). No fluid clamp headings. Sidebar and console density must not shift with viewport width.

## Elevation

Depth is tonal, not shadow-driven. Panels sit on stepped slate backgrounds; the console inset reads as recessed. Shadows appear only for floating layers: inspector modal and mobile sidebar drawer, using `color-mix` on `--bg-inset` rather than pure black.

No card elevation stack. Plot entries and log blocks use 1px `border-subtle` on `bg-raised` fills instead of drop shadows.

### Shadow Vocabulary
- **Modal lift** (`box-shadow: 0 16px 40px color-mix(in oklch, var(--bg-inset) 75%, transparent)`): Inspector window only.
- **Drawer lift** (`box-shadow: 8px 0 24px color-mix(in oklch, var(--bg-inset) 70%, transparent)`): Mobile sidebar drawer.

### Named Rules
**The Flat Panel Rule.** Sidebar sections, toolbar, and log entries are flat at rest. Elevation is a response to overlay or runtime state, never default decoration.

## Components

Tooling components optimized for scan speed and REPL flow.

### Buttons
- **Shape:** Soft corners (8px radius on ghost buttons, 12px on status pill)
- **Ghost (default):** `bg-active` fill, `border-subtle` border, `fg-secondary` text, 10px uppercase label, `4px 8px` padding
- **Hover / Focus:** Text lightens to `fg-primary`, border to `fg-secondary`. Focus ring uses `border-focus` via `:focus-visible`
- **Danger ghost:** `status-error` text, `color-mix` error border; for destructive actions (Reset VM)

### Chips
- **Type badge** (`log-meta-type`): `bg-active` background, 10px pill radius, 9px uppercase type label
- **Inspector type badge:** `bg-active` background, `syntax-type` text color

### Cards / Containers
- **Plot entry:** 6px radius, `bg-raised` background, `border-subtle` border, 10px padding
- **Chart cell:** Same treatment, `min-height: 260px` for uPlot canvas
- **Panel section:** No outer card; separated by `border-subtle` horizontal rules only
- **Internal padding:** Panel content `2px 0`; scroller `16px 20px`

### Inputs / Fields
- **REPL input:** Transparent on `bg-panel`, mono 14px, `syntax-keyword` caret, no border box
- **Placeholder:** `fg-secondary`
- **Range slider:** 4px track (`bg-active`), 12px circular thumb (`syntax-keyword`)
- **Focus:** `:focus-visible` ring on input, buttons, list items, and variable rows

### Navigation
- **Header:** 48px bar, brand left, WASM status right
- **Sidebar:** 260px fixed width; stacks Variables, Quick Ref, Plot Cheatsheet, Shortcuts
- **List items (`mz-list-item`):** Mono 11px, hover `bg-active`, click inserts expression into input
- **Mobile:** Off-canvas sidebar drawer below 768px (`sidebar_drawer.js`), 44px touch targets

### Signature Components
- **Log entry (`mz-log-entry`):** Prompt line + result + optional LaTeX + metadata row. Long output collapses via `<details>`.
- **Variable row:** Name (`syntax-variable`) left, type badge + value (`syntax-number`) right. Click opens inspector.
- **Inspector modal:** 500px centered overlay for matrix tables and series previews.
- **Status indicator:** Pill with dot + text ("Connecting…" → "Ready" / "Error").

## Do's and Don'ts

Concrete guardrails for agents extending MathZig Console.

### Do:
- **Do** use CSS custom properties from `:root` for all new surfaces and text colors.
- **Do** render computed values, expressions, and variable names in JetBrains Mono.
- **Do** keep panel headers at 11px uppercase with 0.5px letter-spacing.
- **Do** use `border-subtle` (1px) for dividers between panels, table cells, and plot frames.
- **Do** reserve `status-success`, `status-error`, and `status-warn` strictly for runtime state.
- **Do** collapse long console output with `<details>` rather than infinite scroll blocks.
- **Do** label range sliders with `<label for="id">` (see Lorenz controls pattern).

### Don't:
- **Don't** use `border-left` or `border-right` greater than 1px as a colored accent on list items, log entries, or callouts. Use background tint or full borders instead.
- **Don't** apply `backdrop-filter` blur on overlays. Use solid tinted `bg-overlay` at ~60% opacity.
- **Don't** use decorative gradients on icons, status pills, or panel headers.
- **Don't** use pure `#000` or `#fff`. Tint neutrals; brand icon uses `bg-app` on keyword fill.
- **Don't** eagerly load Plotly/KaTeX/uPlot on first paint; use on-demand loaders (`cdn_loader.js`).
- **Don't** load syntax colors onto button backgrounds or panel chrome.
- **Don't** hide the entire sidebar on mobile without providing an alternative path to variables and quick-ref commands.
- **Don't** set `outline: none` globally without `:focus-visible` replacements.
- **Don't** add marketing hero metrics, card grids, or modal-first flows for features that fit inline in the console.