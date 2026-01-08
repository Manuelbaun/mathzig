# Product

## Register

product

## Users

MathZig serves a mixed audience with the same core workflow: evaluate expressions, inspect variables, and plot results without context-switching.

- **Quant and backend developers** prototyping simulations (rocket trajectories, Lorenz attractors, time-series indicators) before embedding MathZig in production pipelines.
- **Scientists and engineers** running repeated calculations, checking matrix dimensions, and validating numeric output during modeling sessions.
- **Library integrators** stress-testing the WASM and FFI runtimes through the web console and TUI before committing to an integration.

**Context:** Users work at a desk, often across long sessions, switching between terminal and browser. They expect a REPL they can trust for daily math work: fast feedback, dense information, keyboard-first navigation. The UI is not a demo reel; it is the primary surface for proving the engine works.

## Product Purpose

MathZig is a high-performance mathematical expression engine (Zig-native, SIMD-accelerated, WASM-deployable) with interactive surfaces for evaluation, inspection, and visualization.

**Why it exists:** MathJS and similar libraries cover breadth; MathZig covers speed. The console and TUI exist so users can *work* with the engine directly: assign variables, run `plot()`, reset the VM, inspect matrix internals, and iterate at REPL speed.

**Success looks like:** A REPL people open daily. Expressions evaluate instantly. Variable state is always legible. Plots appear inline. Web and TUI share the same mental model (history, variables, prompt) even when feature sets differ.

## Brand Personality

**Precise, fast, serious.**

MathZig speaks like an engineering instrument: no hype, no hand-holding, no decorative chrome. Confidence comes from responsiveness and numeric clarity, not from marketing copy or visual flair. Errors are direct. Ready state is factual. The tool should feel like it was built by people who run their own expressions.

**Emotional goal:** Competence and control. Users should feel the engine is reliable enough to stake a workflow on.

## Anti-references

MathZig must never drift toward:

- **SaaS landing-page clichés:** hero metrics, identical card grids, gradient CTAs, "big number / small label" dashboards.
- **Generic VS Code clone:** recognizable dark-theme palette copied wholesale with no MathZig identity. IDE spatial logic is fine; cosplay is not.
- **Crypto / trading neon dashboards:** saturated accent floods, glow-heavy status chrome, urgency aesthetics.
- **Education-app pastels:** Khan Academy softness, rounded friendly UI tuned for learners not practitioners.
- **AI-generated tool UI:** glassmorphism overlays, purple gradients, bounce animations, decorative motion, side-stripe accent borders.

**Reference anchor:** MATLAB Command Window (variable inspector, plot-on-demand, command-history flow). Borrow the workflow familiarity, not the visual skin.

## Design Principles

1. **Speed is the interface.** Latency and information density communicate competence. Empty states teach; spinners are rare. Results appear where the user is already looking.

2. **REPL-first, always.** Keyboard history, prompt-at-bottom, variables-at-side. Every surface optimizes for evaluate → inspect → iterate loops, not browse → click → modal.

3. **Show computed truth inline.** Numbers, types, matrices, and plots render in the console. Modals are for deep inspection only, not default disclosure.

4. **Earned familiarity over novelty.** Use patterns practitioners already know (MATLAB, IPython, IDE sidebars). Do not reinvent affordances for flavor. Consistency across web and TUI matters more than surprise.

5. **Instrument, not showcase.** The UI serves the engine. Decoration that does not convey state or structure is noise. If it looks like a product demo, it has failed the daily-use bar.

## Accessibility & Inclusion

- **Target:** WCAG 2.1 AA for the web console.
- **Keyboard:** Full keyboard operability for sidebar actions, toolbar controls, inspector dismiss, and REPL input. Visible `:focus-visible` rings on all interactive elements.
- **Screen readers:** Semantic landmarks, dialog roles on inspector, `aria-live` for runtime status changes, labels on inputs and sliders.
- **Contrast:** Text and placeholders meet 4.5:1 minimum against their surfaces. Status colors are never the sole indicator of state.
- **Motion:** Respect `prefers-reduced-motion`. Loader and hint animations degrade gracefully.
- **TUI:** Terminal-native accessibility (screen reader via terminal emulator, keyboard-only by design). Web parity is the formal a11y commitment.