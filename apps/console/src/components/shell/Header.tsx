import { A, useLocation } from "@solidjs/router";
import { createEffect, createSignal, onCleanup, Show } from "solid-js";
import { session } from "../../state/session";

export function Header() {
  const loc = useLocation();
  const s = () => session.state;
  const [sessionMenuOpen, setSessionMenuOpen] = createSignal(false);
  const [confirmReset, setConfirmReset] = createSignal(false);
  let menuRoot: HTMLDivElement | undefined;

  const closeMenus = () => {
    setSessionMenuOpen(false);
    setConfirmReset(false);
  };

  createEffect(() => {
    if (!sessionMenuOpen() && !confirmReset()) return;
    const onDocClick = (e: MouseEvent) => {
      if (!menuRoot) return;
      if (!menuRoot.contains(e.target as Node)) closeMenus();
    };
    const onDocKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeMenus();
    };
    document.addEventListener("mousedown", onDocClick);
    document.addEventListener("keydown", onDocKey);
    onCleanup(() => {
      document.removeEventListener("mousedown", onDocClick);
      document.removeEventListener("keydown", onDocKey);
    });
  });

  return (
    <header class="flex min-h-12 shrink-0 flex-wrap items-center justify-between gap-2 border-b border-line bg-panel px-3 py-2 select-none sm:px-4">
      <div class="flex min-w-0 items-center gap-2.5">
        <button
          type="button"
          class="inline-flex h-10 w-10 items-center justify-center rounded-lg border border-line bg-active text-fg md:hidden"
          aria-label="Toggle panels"
          aria-expanded={s().sidebarOpen}
          onClick={() => session.setSidebarOpen(!s().sidebarOpen)}
        >
          <MenuIcon />
        </button>
        <div class="flex items-center gap-2 font-semibold text-fg">
          <div class="flex h-5 w-5 items-center justify-center rounded-sm bg-keyword font-mono text-sm font-bold text-app">
            Z
          </div>
          <span class="tracking-tight">MathZig</span>
        </div>
        <nav class="ml-2 flex items-center gap-1 text-xs" aria-label="Primary">
          <A
            href="/"
            class="rounded-md px-2.5 py-1.5 transition-colors"
            classList={{
              "bg-active text-fg": loc.pathname === "/",
              "text-fg-secondary hover:bg-raised hover:text-fg": loc.pathname !== "/",
            }}
            end
          >
            Console
          </A>
          <A
            href="/graph"
            class="rounded-md px-2.5 py-1.5 transition-colors"
            classList={{
              "bg-active text-fg": loc.pathname.startsWith("/graph"),
              "text-fg-secondary hover:bg-raised hover:text-fg": !loc.pathname.startsWith("/graph"),
            }}
          >
            Graph
          </A>
        </nav>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        {loc.pathname === "/" && (
          <div ref={menuRoot} class="relative flex flex-wrap items-center gap-1.5">
            <button
              type="button"
              class="ghost-btn"
              classList={{ "text-ok border-ok/40": s().latexMode }}
              aria-pressed={s().latexMode}
              title="Show LaTeX under numeric results"
              onClick={() => session.toggleLatex()}
            >
              LaTeX: {s().latexMode ? "ON" : "OFF"}
            </button>

            <button
              type="button"
              class="ghost-btn"
              aria-haspopup="menu"
              aria-expanded={sessionMenuOpen()}
              onClick={() => {
                setConfirmReset(false);
                setSessionMenuOpen(!sessionMenuOpen());
              }}
            >
              Session ▾
            </button>

            <Show when={sessionMenuOpen()}>
              <div
                role="menu"
                class="absolute top-full right-0 z-[60] mt-1 min-w-[11rem] rounded-md border border-line bg-panel py-1 shadow-lg"
              >
                <button
                  type="button"
                  role="menuitem"
                  class="block w-full px-3 py-2 text-left text-[12px] text-fg hover:bg-active"
                  onClick={() => {
                    session.clearOutput();
                    closeMenus();
                  }}
                >
                  Clear output
                </button>
                <button
                  type="button"
                  role="menuitem"
                  class="block w-full px-3 py-2 text-left text-[12px] text-fg hover:bg-active"
                  onClick={() => {
                    session.clearPlots();
                    closeMenus();
                  }}
                >
                  Clear plots only
                </button>
                <div class="my-1 border-t border-line" />
                <button
                  type="button"
                  role="menuitem"
                  class="block w-full px-3 py-2 text-left text-[12px] text-err hover:bg-active"
                  onClick={() => {
                    setSessionMenuOpen(false);
                    setConfirmReset(true);
                  }}
                >
                  Reset VM…
                </button>
              </div>
            </Show>

            <Show when={confirmReset()}>
              <div
                role="alertdialog"
                aria-labelledby="reset-title"
                aria-describedby="reset-desc"
                class="absolute top-full right-0 z-[70] mt-1 w-[min(18rem,90vw)] rounded-md border border-line bg-panel p-3 shadow-lg"
              >
                <p id="reset-title" class="text-[12px] font-semibold text-fg">
                  Reset the VM?
                </p>
                <p id="reset-desc" class="mt-1 text-[11px] text-fg-secondary">
                  Clears variables, history, output, and plots. This cannot be undone.
                </p>
                <div class="mt-3 flex justify-end gap-2">
                  <button type="button" class="ghost-btn" onClick={() => setConfirmReset(false)}>
                    Cancel
                  </button>
                  <button
                    type="button"
                    class="ghost-btn border-err/40 text-err"
                    onClick={() => {
                      session.fullReset();
                      closeMenus();
                    }}
                  >
                    Reset VM
                  </button>
                </div>
              </div>
            </Show>
          </div>
        )}
        <div
          class="flex items-center gap-1.5 rounded-full border border-line bg-active px-2.5 py-1 text-xs font-semibold text-fg-secondary"
          role="status"
          aria-live="polite"
        >
          <span
            class="h-2 w-2 rounded-full bg-fg-secondary"
            classList={{
              "bg-ok": s().status === "ready",
              "bg-err": s().status === "error",
              "animate-pulse bg-warn": s().status === "loading",
            }}
            aria-hidden="true"
          />
          <span>{s().statusMessage}</span>
        </div>
      </div>
    </header>
  );
}

function MenuIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
      <path d="M3 5h12M3 9h12M3 13h12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
    </svg>
  );
}
