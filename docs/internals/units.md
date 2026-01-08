# MathZig Unit System

MathZig provides a powerful unit system with support for SI base units, derived units, metric prefixes, and user preferences.

## Core Concepts

Units in MathZig are defined by their **Dimensions** (exponents of base SI units) and a **Scale** factor relative to the base unit.

### Base SI Units
| Name | Dimension | Symbol |
|------|-----------|--------|
| Mass | m | kg |
| Length| l | m |
| Time | t | s |
| Current| i | A |
| Temp | k | K |
| Subs | n | mol |
| Lum | j | cd |

## Unit Display Heuristics

When displaying a value with units, MathZig uses the following priority to select the best unit name:

1.  **User Preferences**: Specifically configured units for certain dimensions.
2.  **SI Preference**: Units with a scale of 1.0 (coherent units like `s`, `J`, `W`).
3.  **Clarity**: Shorter names are preferred among matching units.
4.  **Fallback**: The first matching named unit in the registry.

## Configuring Preferences (POC)

You can set your preferred display unit for specific dimensions using the `/pref` command in the TUI:

```
/pref kWh
```

This will ensure that any energy values (like `100 W * 2 h`) are displayed in `kWh` instead of the SI default `J`.

## Ambiguity Resolution

MathZig handles ambiguities between unit names and prefixes (e.g., `h` for Hour vs Hecto) by:
- Prioritizing exact unit matches over prefix+base combinations for single-token identifiers.
- Using the SI heuristic to prefer standard symbols in output.

### Explicit Unit Syntax `[...]`

To resolve ambiguities between variables and units, or to clearly specify a unit, you can enclose units in square brackets:

```
c = 22[sm]  // 22 * s * m (Explicit units)
v = 10[m/s]
```

### Unit Decomposition

If an identifier is not a defined variable or a known single unit, MathZig attempts to decompose it into multiple units:

- `22sm` is parsed as `22 * s * m` (if `sm` is not a variable).
- `10kgm` is parsed as `10 * kg * m`.

This allows for concise unit entry without spaces, provided there are no variable naming conflicts.

## Examples

| Input | Output (Default) | Output (with Preference) |
|-------|------------------|--------------------------|
| `10m * 10m` | `100 m^2` | `100 m^2` |
| `1kW * 1h` | `3600000 J` | `1 kWh` (after `/pref kWh`) |
| `2s` | `2 s` | `2 s` |
| `22sm` | `22 s*m` | |
| `10[kg]` | `10 kg` | |
