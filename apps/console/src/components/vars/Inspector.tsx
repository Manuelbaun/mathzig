import { createEffect, For, onCleanup, Show } from "solid-js";
import { session } from "../../state/session";
import { ValueTag } from "../../engine/value_tags";

export function Inspector() {
  let panel: HTMLDivElement | undefined;
  let closeBtn: HTMLButtonElement | undefined;
  let previousFocus: HTMLElement | null = null;

  createEffect(() => {
    if (!session.state.inspector.open) return;

    previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;

    // Focus close control after paint; trap Tab inside the docked panel.
    queueMicrotask(() => closeBtn?.focus());

    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        session.closeInspector();
        return;
      }
      if (e.key !== "Tab" || !panel) return;
      const focusable = panel.querySelectorAll<HTMLElement>(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
      );
      if (focusable.length === 0) return;
      const first = focusable[0]!;
      const last = focusable[focusable.length - 1]!;
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    onCleanup(() => {
      window.removeEventListener("keydown", onKey);
      if (previousFocus && document.contains(previousFocus)) {
        previousFocus.focus();
      } else {
        session.requestInputFocus();
      }
    });
  });

  const body = () => {
    const d = session.state.inspector.data;
    if (!d) return null;
    const rt = session.runtime;

    switch (d.tag) {
      case ValueTag.number:
        return (
          <>
            <Row k="Value" v={d.value} accent="text-number text-lg" />
            <Row k="Raw Float" v={String(d.number)} />
          </>
        );
      case ValueTag.complex: {
        const mag = Math.sqrt((d.re || 0) ** 2 + (d.im || 0) ** 2);
        const phase = Math.atan2(d.im || 0, d.re || 0);
        return (
          <>
            <Row k="Cartesian" v={d.value} accent="text-type text-base" />
            <Row k="Polar" v={`r = ${rt.formatNumber(mag)}, θ = ${rt.formatNumber(phase)} rad`} />
            <Row k="Real" v={rt.formatNumber(d.re ?? 0)} />
            <Row k="Imaginary" v={rt.formatNumber(d.im ?? 0)} />
          </>
        );
      }
      case ValueTag.unit:
        return (
          <>
            <Row k="Value" v={d.value} accent="text-type text-base" />
            <Row k="SI Base" v={rt.formatNumber(d.number ?? 0)} />
          </>
        );
      case ValueTag.matrix: {
        const md = d.ptr ? rt.readMatrixData(d.ptr) : null;
        if (!md) return <p class="text-fg-secondary">Raw: {d.value}</p>;
        const rMax = Math.min(md.rows, 10);
        const cMax = Math.min(md.cols, 8);
        const rows: number[][] = [];
        for (let r = 0; r < rMax; r++) {
          rows.push(md.data[r]!.slice(0, cMax));
        }
        return (
          <>
            <Row k="Dimensions" v={`${md.rows} × ${md.cols}`} />
            <div class="mt-2 overflow-auto">
              <table class="w-full border-collapse font-mono text-[11px]">
                <tbody>
                  <For each={rows}>
                    {(row) => (
                      <tr>
                        <For each={row}>
                          {(cell) => (
                            <td class="border border-line px-2 py-1 text-right text-number">
                              {rt.formatNumber(cell)}
                            </td>
                          )}
                        </For>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
              <Show when={md.rows > rMax || md.cols > cMax}>
                <p class="mt-1 text-[11px] text-fg-muted">
                  Preview truncated to {rMax}×{cMax}
                </p>
              </Show>
            </div>
          </>
        );
      }
      case ValueTag.series: {
        const sd = d.seriesData || (d.ptr ? rt.readSeriesData(d.ptr) : null);
        if (!sd) return <p class="text-fg-secondary">{d.value}</p>;
        return (
          <>
            <Row k="Length" v={String(sd.len ?? sd.timestamps?.length ?? "?")} />
            <Row
              k="Sample ts"
              v={(sd.timestamps ?? []).slice(0, 5).map((n) => rt.formatNumber(n)).join(", ")}
            />
            <Row
              k="Sample vals"
              v={(sd.values ?? []).slice(0, 5).map((n) => rt.formatNumber(n)).join(", ")}
            />
          </>
        );
      }
      default:
        return <p class="font-mono text-base text-fg">{d.value}</p>;
    }
  };

  return (
    <Show when={session.state.inspector.open}>
      <aside
        ref={panel}
        role="dialog"
        aria-modal="false"
        aria-labelledby="inspector-title"
        class="flex max-h-[42vh] w-full shrink-0 flex-col border-t border-line bg-panel md:max-h-none md:w-[min(360px,40vw)] md:border-t-0 md:border-l"
      >
        <div class="flex items-center justify-between border-b border-line px-3 py-2.5">
          <div class="flex min-w-0 items-center gap-2">
            <h2 id="inspector-title" class="truncate font-mono text-sm font-semibold text-variable">
              {session.state.inspector.name}
            </h2>
            <span class="shrink-0 rounded bg-inset px-1.5 py-0.5 text-[10px] text-type">
              {session.state.inspector.data?.type}
            </span>
          </div>
          <button
            ref={closeBtn}
            type="button"
            class="ghost-btn"
            aria-label="Close variable inspector"
            onClick={() => session.closeInspector()}
          >
            Close
          </button>
        </div>
        <div class="min-h-0 flex-1 space-y-1 overflow-y-auto px-3 py-3">{body()}</div>
      </aside>
    </Show>
  );
}

function Row(props: { k: string; v: string; accent?: string }) {
  return (
    <div class="flex gap-3 border-b border-line/40 py-1.5 text-[12px]">
      <span class="w-24 shrink-0 text-fg-muted">{props.k}</span>
      <span class={`min-w-0 break-all font-mono ${props.accent ?? "text-fg"}`}>{props.v}</span>
    </div>
  );
}
