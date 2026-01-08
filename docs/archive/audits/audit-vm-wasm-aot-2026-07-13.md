# Audit: Zig VM (`src/vm/`) + WASM AOT (`src/wasm/`, `src/aot_wire.zig`)

> **Status 2026-07-14: all findings fixed or resolved.**
> A1, A2, B1, B2, B3, B5, B6, B7 and the C-items fixed in the working tree.
> A3 verified as a non-issue (codegen has a `local_tee` fallback for arbitrary
> TOS, so discovery and codegen agree). B4 turned out worse than reported:
> Zig's float `@mod` is *unspecified* for a negative divisor, and the checked-in
> parity spec (`arithmetic_mod.test.ts`) asserts Euclidean behavior — the fix
> defines `%` as Euclidean mod (`core/value.zig: euclideanMod`) across VM
> (interpreter, fast paths, builder const-fold), AOT (`generateFmodBody`) and
> both TS host envs. Bonus finds during verification: `Math.round` in
> `graph/env.ts` had the half-away-from-zero parity bug (fixed); negative
> single-element indices also trapped in AOT 1D/2D paths (fixed via
> `emitNegativeIndexWrap`); `tests/artifacts/wasm_aot/` caches compiled modules
> by expression hash — clear it when validating compiler changes.
> Verified: zig tests green (116+1 direct; the two `zig build test` "failed
> command" reports pre-exist on main — stray stdout corrupts the `--listen`
> harness), bun suite 947 pass with a failure set identical to main (17
> pre-existing), cross-backend spot checks green with a cold AOT cache.

Date: 2026-07-13. Scope: `vm/vm.zig`, `vm/bytecode.zig`, `wasm/compiler.zig`, `wasm/leb128.zig`, `aot_wire.zig` (full read); `wasm/module.zig`, `math_lib.zig` (spot). Findings ordered by severity within each section. "Verify" = strong suspicion, needs a repro before fixing.

---

## A. High severity

### A1. Heap base / data-segment overlap for complex constants and folded LaTeX strings (compiler.zig)
`ensureLinearMemoryAndHeap()` freezes the `heap_ptr` global initializer at `align8(current_data_offset)` **before codegen runs**. But codegen still appends to the data segment afterwards:

- `.push_const` complex case (compiler.zig:3509–3514) calls `module.addData` at `current_data_offset` and bumps it.
- `compileTimeToLaTeX` → `addLengthPrefixedString` (≈:1971) does the same.

Predicate constants are explicitly pre-materialized before the heap is fixed (compileUnits :713–720, with a comment saying why) — complex constants and folded strings are **not**. Any module that has linear memory *and* a complex constant places that constant at/above the frozen heap base; the first runtime allocation returns the same address and overwrites it. Corroborating smell: `emitAbiManifest` (:1209) recomputes `heap_base = align8(current_data_offset)` at manifest time, so the JSON `heap_base` can disagree with the actual `heap_ptr` global/`reset_heap` value.

**Fix direction:** pre-materialize complex constants (same loop as predicates) and hard-error / pre-fold `toLaTeX` before `ensureLinearMemoryAndHeap`; assert `current_data_offset` unchanged after codegen, or derive the global from a post-codegen patch.

### A2. Unchecked `@intFromFloat` on user-controlled values in VM builtins (vm.zig, many sites)
User expressions can pass negative/NaN/huge f64 where the VM converts with bare `@intFromFloat` — safety-checked illegal behavior (panic in Debug, UB in ReleaseFast):

- `rec_get_dyn` series index (:1300) — `series[-1]`, `series[0/0]`.
- `linspace` count (:1568), `logspace` count (:1582) — `linspace(0,1,-5)`.
- `randomInt(max)` (:2060) — `randomInt(-3)`.
- `reshape` rows/cols (:2307–2308), `identity(n)` (:2390), `zeros`/`ones` (:2403–2424), `concat` dim (:2335).

The codebase already has the right tool — `strictI64FromNumber` is used for matrix slicing (:4077) — it's just not used in `callBuiltin`. Also `zeros(1e12)` passes conversion but requests a ~8 TB alloc; a `ResultTooLarge` cap exists in the error set but is not enforced here.

**Fix direction:** one helper (`strictU32FromNumber` / reuse `strictI64FromNumber`) at every builtin conversion site; reject non-finite, negative where unsigned, and clamp against a max-elements config.

### A3. AOT `pow` fast-path/discovery mismatch → `pow_func_idx.?` unwrap panic (compiler.zig) — *verify*
Discovery decides "no pow helper needed" via `isFastPowAt` (:366–375): previous instruction is `push_const` of 2.0/3.0. Codegen's fast-pow emission (:2109–2123) additionally requires the instruction *before the constant* to be `load_var`. For `(a+b)^2` discovery skips registering pow, codegen can't take the fast path, falls into the `.pow` handler (:4949) which does `self.pow_func_idx.?` → panic (or emits nothing). The read of the 2116 region was partial — confirm whether a non-`load_var` TOS fast-pow branch exists; if not, this is a crash on a trivial expression. Same audit applies to `.mod` / `fmod_import_idx.?` (discovery presumably scans all `.mod`, lower risk).

---

## B. Medium severity

### B1. Exported `alloc` doesn't grow memory (compiler.zig:902–928)
The exported bump `alloc` just advances `heap_ptr` — no `memory.size`/`memory.grow` check, unlike internal `emitHeapAllocChecked` (:3260) which grows and traps cleanly on failure. A host writing large inputs (node-graph matrices/series into consumer heap — exactly what `force_heap` exists for) can get a pointer past the end of memory; the subsequent host-side write into `memory.buffer` throws a confusing RangeError instead. Reuse the checked-grow logic in the exported body.

### B2. `rec_get` / `rec_get_dyn` ignore the stored value-kind byte (compiler.zig:6188–6345)
`rec_create` carefully bakes each field's kind into the entry pad byte "so hosts can type the fields", but the in-module `rec_get` always `pushType(.number)`. A record field holding a matrix/complex ptr flows onward typed as scalar: `r.m * 2` compiles to `f64_mul` on a pointer value → silent garbage. VM path handles this correctly. Either read the kind byte and hard-error on non-number at compile time (kinds are statically known at rec_create sites) or propagate the static kind through the type stack.

### B3. `call_user` result always typed `.number` (compiler.zig:4030)
User function returning a matrix/complex (its body's result tag is computed and even stored for roots) is typed `.number` at every call site → same silent-pointer-as-scalar class as B2. At minimum: record each discovered function's result tag after `generateFunctionCode` and push that.

### B4. VM `@mod` vs AOT `fmod` parity (vm.zig:806 vs compiler.zig `.mod`)
VM uses Zig `@mod` (sign of divisor: `@mod(-5,3)=1`). AOT calls env `fmod` import or `math_lib.generateFmodBody` (C semantics: `fmod(-5,3)=-2`) unless those were written to Zig semantics. Check `generateFmodBody` and the TS host's `fmod` — if either is C-style, negative operands diverge between interpreter and AOT. Cheap parity test: `(-5) % 3`, `5 % -3` through both backends.

### B5. Interpreter `load_mul`/`load_sub`/`fma_var_const_const` skip tag and bounds checks (vm.zig:860–880, 1165–1185)
- `fma_var_const_const` indexes `self.variables[var_idx]` and `expr.constants[c1/c2]` unchecked. Builder caps indices at 255, but `variables.len` is caller-chosen (`max_variables`) and can be < 256 → OOB read in ReleaseFast. `.load_var` right above it *does* bounds-check — inconsistent trust model.
- `load_mul`/`load_sub` read `variables_f64[i]` without consulting `variables_tags`. Variable rebound to a matrix by the host between evals silently computes with the stale f64 mirror (`toNumber() orelse 0`) instead of erroring. The fast paths bail on non-number tags; the main interpreter should too (or bounds/tag-check like `load_var`).

### B6. `pub fn callUserFunction` looks uncompilable if ever referenced (vm.zig:368–399) — *verify*
`Value.initNumber(sub_vm.executeNumbersOnly(&func.body))` passes a `?f64` where `f64` is expected, and unlike `invokeUserSubVM` it doesn't handle the `null` bail (non-number variable encountered) at all. If this compiles today it's only because nothing references it (Zig lazy analysis) — dead code with a latent compile error and, if fixed naively, a semantic bug (null fast-path result must fall back to `execute`, not become a Value). Delete it or route it through `invokeUser`.

### B7. AOT negative slice index traps (`i32_trunc_f64_u`) (compiler.zig:5198–5211)
Row-vector slice path truncates `start_raw`/`end_raw` with `i32_trunc_f64_u`. Negative bound (`v[-2:]` — supported by the VM via `normalizeMatrixIndex`) traps the whole module instead of normalizing or erroring at compile time. Also NaN detection via `x != x` happens only for the "unbounded" sentinel; explicit NaN from arithmetic reaches trunc → trap. Divergence + poor failure mode; at least document, better: emit signed trunc + clamp like the VM.

---

## C. Low severity / notes

1. **`safeFloatToInt` NaN** (vm.zig:2629): clamps ±inf, but confirm NaN path — `NaN > max` and `NaN < min` are both false; if it falls through to `@intFromFloat`, bitwise ops on NaN input are UB in ReleaseFast. One `if (std.math.isNan(f)) return 0;` closes it.
2. **`executeNumbersFast` div negative-zero divisor**: fast path uses IEEE division; interpreter's custom `bn == 0` branch treats `-0.0` as zero → `5/(-0.0)` = `+inf` (interpreter) vs `-inf` (fast path/AOT). Only reachable with `-0` divisors; note or align.
3. **`track*` swallow OOM** (`catch {}`, vm.zig:267–295): on allocator failure the object is silently untracked → leak. Acceptable policy, but a debug counter would help.
4. **AOT `load_var_index_*` no bounds check** (compiler.zig:3562–3592): constant index beyond matrix length reads adjacent heap silently (VM errors). Known speed/safety tradeoff — worth a comment or a debug-mode range trap.
5. **`aot_wire` global mutable stashes** (`last_wire_result`, `complex_result_buf`, `key_out_buf`): single-VM assumption; not thread-safe and one-deep. Fine for current host, document the invariant. Also `ptrFromWire` accepts any finite `wire ≥ 1` — `1e300` overflows `usize` conversion (host is trusted, low risk).
6. **`recordEntryAt` O(n) per index + hashmap iteration order** (aot_wire.zig:233): host enumeration is O(n²) and order is not stable across mutation; fine for small records.
7. **Bytecode fold bookkeeping** (bytecode.zig:519–590): `tryFoldBinaryOp` trusts `pending_const_1/2` to mean "last two instructions are those pushes". Verified `emitConstant` maintains it and fold clears correctly; make sure *every* other emit path (incl. FMA peephole, patchJump) clears pendings — the FMA transform re-appends a moved `push_const` without re-registering it as pending, which is safe (conservative) but should stay that way; a regression test with `x*2+3+4` would lock the invariant.
8. **`.eq`/`.lt` on non-numeric operands silently false** (vm.zig:923–987): strings/matrices compare unequal instead of erroring; matches AOT's f64-only compare, so parity holds — just document.
9. **leb128**: correct incl. SLEB sign handling; has tests. `encodeUnsigned` accepts negative `value` via `@intCast` panic — fine.
10. **`emitFusedTick` table layout** packs f64 at 4-byte alignment with align-hint 2 — legal wasm, comment already present. Host must read with DataView, not Float64Array — worth an ABI doc note.
11. **VM stack fixed at 4096 Values (~230 KB per VM)** with `frame_ok` requiring headroom — fine, but `invokeUser` falls back to sub-VM silently when headroom is short; deep recursion cost cliff is invisible to users. Note only.

---

## What looked solid

- Import-before-defined-function index discipline in `compileUnits` is well thought out (two-phase registration, invariant documented and asserted in `module.addImport`).
- `emitHeapAllocChecked` growth path traps on failed `memory.grow` instead of returning bad pointers.
- Frame-based user calls (`invokeUserFrame`) save/restore + retain/release logic is correct including the tracked-vs-untracked result retain; comments match behavior.
- Unit dimension algebra is enforced at compile time in AOT (`combineUnitAdd` hard-errors on dim mismatch; no silent stripping — `UnitOpNotResolvable`).
- `round` half-away-from-zero emulation vs wasm `f64.nearest` parity fix is exactly right.
- Threaded dispatch, per-op stack-underflow checks, and the debug `audit()` magic-number sweeps give the interpreter good defense in depth.

## Suggested order of attack
A1 (heap overlap repro: compile any heap-using expr with a complex constant, eval, read the constant back) → A2 (mechanical, one helper) → A3/B4 parity tests → B1 → B2/B3 (same type-stack mechanism) → B5–B7.
