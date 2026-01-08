import { Show } from "solid-js";
import { VariablesPanel } from "../components/vars/VariablesPanel";
import { SidePanels } from "../components/panels/SidePanels";
import { Inspector } from "../components/vars/Inspector";
import { OutputStream } from "../components/repl/OutputStream";
import { InputBar } from "../components/repl/InputBar";
import { session } from "../state/session";

export function ConsolePage() {
  return (
    <>
      <Show when={session.state.status === "loading"}>
        <div
          class="absolute inset-0 z-50 flex flex-col items-center justify-center gap-3 bg-app"
          role="status"
          aria-live="polite"
          aria-busy="true"
        >
          <div class="text-sm font-semibold tracking-wide text-fg">Loading MathZig</div>
          <div class="h-1 w-40 overflow-hidden rounded-full bg-raised">
            <div class="h-full w-1/2 animate-pulse rounded-full bg-keyword" />
          </div>
          <div class="text-[11px] text-fg-secondary">Initializing WebAssembly runtime…</div>
        </div>
      </Show>

      <Show when={session.state.status === "error"}>
        <div class="absolute inset-0 z-50 flex flex-col items-center justify-center gap-2 bg-app px-6 text-center">
          <div class="text-sm font-semibold text-err">Failed to load engine</div>
          <p class="max-w-md text-[12px] text-fg-secondary">{session.state.statusMessage}</p>
          <p class="max-w-md text-[11px] text-fg-muted">
            Build WASM and copy to <code class="text-keyword">apps/console/public/mathzig_wasm.wasm</code>
          </p>
        </div>
      </Show>

      <div class="flex min-h-0 flex-1">
        <Show when={session.state.sidebarOpen}>
          <div
            class="fixed inset-x-0 top-12 bottom-0 z-[40] bg-app/70 md:hidden"
            onClick={() => session.setSidebarOpen(false)}
          />
        </Show>

        <aside
          id="app-sidebar"
          class="fixed top-12 bottom-0 left-0 z-[50] flex w-[min(300px,88vw)] -translate-x-full flex-col border-r border-line bg-app transition-transform md:static md:z-0 md:w-64 md:translate-x-0 lg:w-72"
          classList={{
            "translate-x-0": session.state.sidebarOpen,
          }}
          aria-label="REPL panels"
        >
          <div class="shrink-0">
            <VariablesPanel />
          </div>
          <SidePanels />
        </aside>

        <main class="flex min-w-0 flex-1 flex-col">
          <div class="flex min-h-0 flex-1 flex-col md:flex-row">
            <OutputStream />
            <Inspector />
          </div>
          <InputBar />
        </main>
      </div>
    </>
  );
}
