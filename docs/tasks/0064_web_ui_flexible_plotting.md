# Task 0064: Flexible Plotting API & Notebook-Style History for Web UI

- **Status:** In Progress (verified partial 2026-07-15)

## Objective
Implement a robust and flexible `plot()` function in the MathZig Web REPL that supports various data types (Matrix, Series, Arrays) and configurations. Migrate the charting output from a fixed container to the command history stream, creating a linear, notebook-like experience.

## Context
Currently, `plot()` is limited to single-variable plotting in a fixed `#chart-container` at the top of the UI. Users want to plot specific columns of a matrix, compare multiple datasets, and see the charts inline with their commands (like Jupyter/Observable). We recently migrated to uPlot for better performance.

## Requirements

### 1. Unified `plot(...)` API
The `plot` command should handle multiple signatures using a flexible argument parsing strategy in the frontend or VM.

*   **Series:** `plot(mySeries)` - Plots value vs. timestamp.
*   **Matrix (Vector):** `plot(myVector)` - Plots value vs. index.
*   **Matrix (Columns):** `plot(myMatrix, {x: 0, y: [1, 2]})` - Plots columns 1 and 2 vs. column 0 on the same axis.
*   **Two Arrays:** `plot(xArray, yArray)` - Plots Y vs. X.
*   **Multiple Series/Axes:**
    *   **Same Axis:** `plot(x, [y1, y2])` - Plots both y1 and y2 against x on the left axis.
    *   **Dual Axis:** `plot(x, [ {data: y1, axis: 'left', label: 'Alt'}, {data: y2, axis: 'right', label: 'Vel'} ])`
*   **Configuration:** Support an options object for title, labels, colors.
    *   `plot(data, { title: "My Run", color: "red" })`

### 2. Notebook-Style Output
*   **Remove:** The fixed `#chart-container` at the top.
*   **Implement:** Render charts directly in the `#output` log stream as a result entry.
*   **Persist:** Ensure charts persist in the DOM as the user scrolls (uPlot is canvas-based, so this is fine, but we need to manage resize/layout).

### 3. Implementation Plan

#### Phase 1: Frontend Argument Parsing (JS)
*   Update `handleCmd` in `index.html` to parse `plot(...)` arguments more robustly.
*   Implement a lightweight parser that splits arguments by comma *respecting brackets/braces*.
*   Support resolution of variable names to their data (arrays/matrices).

#### Phase 2: Multi-Series Data Structuring
*   Logic to align datasets: Ensure all Y-series have matching length to X.
*   Handle "sparse" data if X-values differ (uPlot expects aligned data, so we might need `aligned` data builder or use `null` for missing points). *Simplification: Assume shared X for MVP.*

#### Phase 3: Dynamic uPlot Configuration
*   Builder function that takes the parsed plot definition and generates the `uPlot` options object.
*   Dynamically generate `series` array (colors, labels, widths).
*   Dynamically generate `axes` and `scales` (left/right, ranges).

#### Phase 4: Inline Chart Rendering
*   Modify `addLog` to accept a `chartConfig` object.
*   Render a unique `<div>` ID in the log.
*   Instantiate `uPlot` into that div.

## Technical Details
*   **Library:** uPlot (already integrated).
*   **Parsing:**
    *   Regex won't cut it for nested objects/arrays.
    *   We can use a simple generic "split arguments" function that counts nesting levels of `()`, `[]`, `{}`.
    *   `eval` of the args string (wrapped in `[...]`) is risky but valid for a local REPL if we sanitize or catch errors. Given this is a client-side only REPL for a dev tool, `new Function("return [" + args + "]")` might be acceptable IF variables are exposed in that scope.
    *   *Better:* Manually resolve variable names first, then construct the data object.

## Example Usage
```javascript
> t = [0, 1, 2, 3]
> y = [10, 20, 15, 25]
> plot(t, y, { title: "Test Plot" })
[Chart appears here in history]

> m = result_stage1
> plot(m, {x: 0, y: 1})  # Altitude vs Time
[Chart appears here]
```

## Success Metrics
*   User can plot a specific column of a matrix against another.
*   User can plot two separate arrays/vectors against each other.
*   Charts appear inline in the history.
*   Previous charts remain visible and interactive.

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** console plot-related files=['plotly.ts', 'plot_parse.test.ts', 'plot_parse.ts', 'PlotHost.tsx']
- **Notes:** Plotting exists in apps/console; formal notebook-style history API may still be incomplete.
- **Audit:** [true_status_audit.md](true_status_audit.md)

