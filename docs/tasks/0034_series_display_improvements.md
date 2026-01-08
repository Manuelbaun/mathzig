# Task: Improve Series Display in REPL

## Priority: Low

## Problem

Currently, Series values are displayed as `<Series len=N>` which doesn't show the actual data.

**Current:**
```
sma(data.price, 3)   => <Series len=10>
cumsum(S1)           => <Series len=5>
```

**Desired for small series:**
```
sma(data.price, 3)   => Series[152.83, 154.17, 155.37, ...]  (len=10)
cumsum(S1)           => Series[10, 30, 45, 75, 100]
```

## Subtasks

- [ ] Update `printValue()` in `mathzig.zig` for Series display
- [ ] Show first few values for small series (len ≤ 10)
- [ ] Show abbreviated format for larger series
- [ ] Include timestamp range info if useful
- [ ] Update `formatValue()` in `tui/state.zig` similarly

## Proposed Format

```
# Small series (len ≤ 5): show all values
Series[10, 20, 15, 30, 25]

# Medium series (5 < len ≤ 10): show with ellipsis
Series[150.5, 155.2, 152.8, ..., 165.5] (len=10)

# Large series (len > 10): summary only
<Series len=1000, range=[0..3600s]>
```

## Files to Modify

- `src/mathzig.zig` - `printValue()` function
- `src/tui/state.zig` - `formatValue()` function

## Status

In Progress (verified partial 2026-07-15)

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** fancy series preview in mathzig=True; in tui=True
- **Notes:** Some series formatting exists in mathzig/tui; task-specific abbreviated preview checklist not clearly fully met.
- **Audit:** [true_status_audit.md](true_status_audit.md)

